//! Kiểm audit thật bằng allowlist độc lập; không xuất row/metadata vào evidence.

use super::{ApplicationError, PgPool, ProbeConfig};
use serde_json::Value;
use sqlx::Row;
use std::collections::BTreeSet;

/// Manifest độc lập của11 điểm audit hiện có; không gồm row seed hoặc provider chưa triển khai.
const EVENTS: [&str; 12] = [
    "LOGIN_FAILED",
    "LOGIN_SUCCEEDED",
    "LOGOUT",
    "PASSWORD_CHANGE_FAILED",
    "PASSWORD_CHANGED",
    "WORKSPACE_CREATED",
    "INVITATION_CREATED",
    "INVITATION_ACCEPTED",
    "TEMPORARY_PASSWORD_RESET",
    "MEMBERSHIP_RESET_ADMITTED",
    "MEMBERSHIP_CHANGED",
    "REALTIME_TICKET_ISSUED",
];

/**
 * Kiểm allowlist, revision và semantics no-op/diff độc lập writer để bắt thiếu metadata hoặc lọt PII.
 * Input
 * Param: event — action nằm trong manifest probe.
 * Param: metadata — JSON đã parse từ row synthetic, không được log trong lỗi.
 * Param: `has_actor` — row có principal đã biết hay anonymous.
 * Param: outcome — kết quả storage phải khớp semantic DENIED/COMMITTED.
 * Output: thành công khi đủ đúng allowlist; Errors: Conflict không chứa nội dung row.
 */
fn validate_metadata(
    event: &str,
    metadata: &Value,
    has_actor: bool,
    outcome: &str,
) -> Result<(), ApplicationError> {
    let object = metadata.as_object().ok_or(ApplicationError::Conflict)?;
    let failed = matches!(event, "LOGIN_FAILED" | "PASSWORD_CHANGE_FAILED");
    if has_actor == (event == "LOGIN_FAILED") {
        return Err(ApplicationError::Conflict);
    }
    if metadata["schema_version"] != 1
        || metadata["phase"] != "MUTATION"
        || metadata["result"] != if failed { "DENIED" } else { "COMMITTED" }
        || metadata["actor_type"] != if has_actor { "USER" } else { "ANONYMOUS" }
        || outcome != if failed { "FAILURE" } else { "SUCCESS" }
    {
        return Err(ApplicationError::Conflict);
    }
    let extra: &[&str] = match event {
        "LOGIN_SUCCEEDED" => &["limited"],
        "PASSWORD_CHANGED" | "TEMPORARY_PASSWORD_RESET" => &["secret_changed"],
        "MEMBERSHIP_RESET_ADMITTED" => &["revision_before", "revision_after"],
        "INVITATION_CREATED" => &["role"],
        "INVITATION_ACCEPTED" => &["grant_generation"],
        "MEMBERSHIP_CHANGED" => &[
            "revision_before",
            "revision_after",
            "authorization_version_before",
            "authorization_version_after",
            "role_before",
            "role_after",
            "status_before",
            "status_after",
            "alias_changed",
            "noOp",
            "diff",
        ],
        _ => &[],
    };
    if object.len() != 4 + extra.len() || extra.iter().any(|key| !object.contains_key(*key)) {
        return Err(ApplicationError::Conflict);
    }
    // Key hợp lệ vẫn phải có value hữu hạn; không chỉ blacklist tên secret ở lớp ngoài.
    for (key, value) in object {
        let valid = match key.as_str() {
            "schema_version" => value == 1,
            "phase" => value == "MUTATION",
            "result" => value == "COMMITTED" || value == "DENIED",
            "actor_type" => value == "USER" || value == "ANONYMOUS",
            "limited" | "alias_changed" | "noOp" => value.is_boolean(),
            "diff" => value.as_array().is_some_and(|fields| {
                let mut observed = BTreeSet::new();
                fields.iter().all(|field| {
                    field.as_str().is_some_and(|name| {
                        matches!(name, "role" | "status" | "alias") && observed.insert(name)
                    })
                })
            }),
            "secret_changed" => value == true,
            "revision_before"
            | "revision_after"
            | "authorization_version_before"
            | "authorization_version_after"
            | "grant_generation" => value.as_i64().is_some_and(|number| number > 0),
            "role" | "role_before" | "role_after" => value == "ADMIN" || value == "USER",
            "status_before" | "status_after" => {
                value == "ACTIVE" || value == "SUSPENDED" || value == "REMOVED"
            }
            _ => false,
        };
        if !valid {
            return Err(ApplicationError::Conflict);
        }
    }
    if matches!(event, "MEMBERSHIP_CHANGED" | "MEMBERSHIP_RESET_ADMITTED")
        && metadata["revision_after"].as_i64()
            != metadata["revision_before"]
                .as_i64()
                .and_then(|value| value.checked_add(1))
    {
        return Err(ApplicationError::Conflict);
    }
    if event == "MEMBERSHIP_CHANGED" {
        let fields = metadata["diff"]
            .as_array()
            .ok_or(ApplicationError::Conflict)?;
        let changed: BTreeSet<&str> = fields
            .iter()
            .map(|field| field.as_str().ok_or(ApplicationError::Conflict))
            .collect::<Result<_, _>>()?;
        let role_changed = metadata["role_before"] != metadata["role_after"];
        let status_changed = metadata["status_before"] != metadata["status_after"];
        // Chỉ thay đổi quyền role/status mới tăng authzVersion; alias/no-op chỉ tăng revision.
        let authorization_version_delta = if role_changed || status_changed { 1 } else { 0 };
        let expected_authorization_version = metadata["authorization_version_before"]
            .as_i64()
            .and_then(|version| version.checked_add(authorization_version_delta));
        if metadata["noOp"] != changed.is_empty()
            || changed.contains("role") != role_changed
            || changed.contains("status") != status_changed
            || metadata["alias_changed"].as_bool() != Some(changed.contains("alias"))
            || metadata["authorization_version_after"].as_i64() != expected_authorization_version
        {
            return Err(ApplicationError::Conflict);
        }
    }
    Ok(())
}

/**
 * Kiểm toàn bộ event đã build có resource/reason/metadata an toàn sau workflow thực.
 * Input
 * Param: pool — role probe chỉ đọc rows synthetic của correlation hiện hành.
 * Param: config — correlation và IDs tổng hợp, không phải dữ liệu người dùng.
 * Param: checks — chỉ thêm tên kiểm sau khi mọi row đạt; không ghi row hoặc secret.
 * Output: thành công hoặc lỗi invariant đã lọc.
 */
pub(super) async fn verify(
    pool: &PgPool,
    config: &ProbeConfig,
    checks: &mut Vec<&'static str>,
) -> Result<(), ApplicationError> {
    // Chỉ đọc manifest đã biết và correlation do launcher sinh; không scan audit của người dùng.
    let rows = sqlx::query("SELECT event_type,workspace_id,resource_type,resource_id,reason_code,outcome,actor_user_id,redacted_diff::text AS metadata FROM audit_events WHERE correlation_id=$1 AND event_type=ANY($2)")
        .bind(config.run_id).bind(EVENTS.as_slice()).fetch_all(pool).await.map_err(|_|ApplicationError::Unavailable)?;
    let mut observed = BTreeSet::new();
    for row in rows {
        let event: String = row
            .try_get("event_type")
            .map_err(|_| ApplicationError::Unavailable)?;
        let resource_type: Option<String> = row
            .try_get("resource_type")
            .map_err(|_| ApplicationError::Unavailable)?;
        let resource_id: Option<String> = row
            .try_get("resource_id")
            .map_err(|_| ApplicationError::Unavailable)?;
        let workspace: Option<uuid::Uuid> = row
            .try_get("workspace_id")
            .map_err(|_| ApplicationError::Unavailable)?;
        let reason: Option<String> = row
            .try_get("reason_code")
            .map_err(|_| ApplicationError::Unavailable)?;
        let metadata: Option<String> = row
            .try_get("metadata")
            .map_err(|_| ApplicationError::Unavailable)?;
        let expected = match event.as_str() {
            "LOGIN_FAILED" => (None, "INVALID_CREDENTIALS", false),
            "LOGIN_SUCCEEDED" => (Some("SESSION"), "CREDENTIALS_VERIFIED", false),
            "LOGOUT" => (Some("SESSION"), "SELF_LOGOUT", false),
            "PASSWORD_CHANGE_FAILED" => (Some("USER"), "INVALID_CREDENTIALS", false),
            "PASSWORD_CHANGED" => (Some("USER"), "SELF_PASSWORD_CHANGED", false),
            "WORKSPACE_CREATED" => (Some("WORKSPACE"), "WORKSPACE_CREATED", true),
            "INVITATION_CREATED" => (Some("INVITATION"), "INVITATION_ISSUED", true),
            "INVITATION_ACCEPTED" => (Some("INVITATION"), "INVITATION_ACCEPTED", true),
            "TEMPORARY_PASSWORD_RESET" => (Some("USER"), "ADMIN_TEMPORARY_RESET", false),
            "MEMBERSHIP_RESET_ADMITTED" => (Some("MEMBERSHIP"), "TEMPORARY_RESET_ADMITTED", true),
            "MEMBERSHIP_CHANGED" => (Some("MEMBERSHIP"), "MEMBERSHIP_PATCHED", true),
            "REALTIME_TICKET_ISSUED" => (Some("WEBSOCKET_TICKET"), "REALTIME_TICKET_ISSUED", true),
            _ => return Err(ApplicationError::Conflict),
        };
        if resource_type.as_deref() != expected.0
            || reason.as_deref() != Some(expected.1)
            || workspace.is_some() != expected.2
            || resource_id
                .as_ref()
                .is_some_and(|id| uuid::Uuid::parse_str(id).is_err())
            || resource_type.is_some() != resource_id.is_some()
        {
            return Err(ApplicationError::Conflict);
        }
        let metadata: Value = serde_json::from_str(&metadata.ok_or(ApplicationError::Conflict)?)
            .map_err(|_| ApplicationError::Conflict)?;
        let actor: Option<uuid::Uuid> = row
            .try_get("actor_user_id")
            .map_err(|_| ApplicationError::Unavailable)?;
        let outcome: String = row
            .try_get("outcome")
            .map_err(|_| ApplicationError::Unavailable)?;
        validate_metadata(&event, &metadata, actor.is_some(), &outcome)?;
        observed.insert(event);
    }
    if observed.len() != EVENTS.len() {
        return Err(ApplicationError::Conflict);
    }
    checks.push("PASS: original twelve IAM audit variants persist typed resource/reason and bounded redacted metadata without private text");
    Ok(())
}
