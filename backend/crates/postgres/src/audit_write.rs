//! Serialize metadata audit bằng enum/bool/counter; không nhận JSON hoặc chuỗi từ request.

use iot_domain::{
    audit_write::AuditDetail, membership::MembershipStatus, workspace::WorkspaceRole,
};

/// Ánh xạ role domain sang literal hữu hạn để metadata không chứa chuỗi người dùng cung cấp.
fn role_value(role: WorkspaceRole) -> &'static str {
    match role {
        WorkspaceRole::Admin => "ADMIN",
        WorkspaceRole::User => "USER",
    }
}

/// Ánh xạ trạng thái membership vào snapshot audit, độc lập account global.
fn status_value(status: MembershipStatus) -> &'static str {
    match status {
        MembershipStatus::Active => "ACTIVE",
        MembershipStatus::Suspended => "SUSPENDED",
        MembershipStatus::Removed => "REMOVED",
    }
}

/**
 * Dựng JSON allowlist từ kiểu hữu hạn, tránh serialize payload/credential hoặc tên riêng vào audit.
 * Input
 * Param: detail — metadata của mutation đã được application authorize và thực thi trong transaction.
 * Param: `has_actor` — actor có identity đã biết; false chỉ biểu thị anonymous failed login.
 * Output: JSON hợp lệ để bind sang jsonb; không chèn giá trị vào cú pháp SQL.
 */
pub(crate) fn redacted_metadata(detail: &AuditDetail, has_actor: bool) -> String {
    let fields = match detail {
        AuditDetail::DeviceRegistered {
            template_version_id,
            actuator_count,
            ..
        } => format!(
            r#", "template_version_id":"{template_version_id}","actuator_count":{actuator_count}"#
        ),
        AuditDetail::LoginSucceeded { limited, .. } => format!(r#", "limited":{limited}"#),
        AuditDetail::PasswordChanged { .. }
        | AuditDetail::TemporaryPasswordReset { .. }
        | AuditDetail::TemporaryAccountCreated { .. } => r#", "secret_changed":true"#.to_owned(),
        AuditDetail::MembershipResetAdmitted {
            revision_before,
            revision_after,
            ..
        }
        | AuditDetail::InvitationRevoked {
            revision_before,
            revision_after,
            ..
        }
        | AuditDetail::TemplateDraftChanged {
            revision_before,
            revision_after,
            ..
        } => format!(r#", "revision_before":{revision_before},"revision_after":{revision_after}"#),
        AuditDetail::TemplatePublished {
            template_id,
            version_number,
            revision_before,
            revision_after,
            ..
        } => format!(
            r#", "template_id":"{template_id}","version_number":{version_number},"revision_before":{revision_before},"revision_after":{revision_after}"#
        ),
        AuditDetail::PreferencesChanged {
            revision_before,
            revision_after,
            timezone_changed,
            ..
        } => format!(
            r#", "revision_before":{revision_before},"revision_after":{revision_after},"timezone_changed":{timezone_changed}"#
        ),
        AuditDetail::InvitationCreated { role, .. }
        | AuditDetail::MembershipCreated { role, .. } => {
            format!(r#", "role":"{}""#, role_value(*role))
        }
        AuditDetail::InvitationAccepted {
            grant_generation, ..
        } => format!(r#", "grant_generation":{grant_generation}"#),
        AuditDetail::MembershipChanged(member) => format!(
            r#", "revision_before":{},"revision_after":{},"authorization_version_before":{},"authorization_version_after":{},"role_before":"{}","role_after":"{}","status_before":"{}","status_after":"{}","alias_changed":{}"#,
            member.revision_before,
            member.revision_after,
            member.authorization_version_before,
            member.authorization_version_after,
            role_value(member.role_before),
            role_value(member.role_after),
            status_value(member.status_before),
            status_value(member.status_after),
            member.alias_changed
        ),
        _ => String::new(),
    };
    // SUCCESS của use case đồng bộ chỉ là local COMMITTED, không hứa board/provider success.
    let result = if detail.outcome() == "FAILURE" {
        "DENIED"
    } else {
        "COMMITTED"
    };
    let actor_type = if has_actor { "USER" } else { "ANONYMOUS" };
    format!(
        r#"{{"schema_version":1,"phase":"MUTATION","result":"{result}","actor_type":"{actor_type}"{fields}}}"#
    )
}
