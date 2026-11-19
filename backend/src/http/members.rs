//! Route member giữ workspace scope từ selector tới admission, query và projection.

use super::{HttpError, HttpState, no_store, security, sessions};
use axum::{
    Json, Router,
    extract::{Path, RawQuery, Request, State},
    http::{HeaderMap, StatusCode},
    response::{IntoResponse, Response},
    routing::{get, patch},
};
use chrono::Utc;
use iot_application::{
    auth_read::SessionInspection, error::ApplicationError, membership::MembershipListItem,
};
use iot_domain::{
    idempotency::IdempotencyKey,
    identity::SessionProof,
    input::{normalize_email, normalize_member_display_name},
    member_creation::{MemberCreationOutcome, MemberCreationRequest},
    membership::{AliasChange, MembershipPatch, MembershipStatus},
    workspace::WorkspaceRole,
};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};
use uuid::Uuid;

/// Cursor giữ keyset cùng scope/filter và quyền hiện hành; chữ ký mới là nguồn tin cậy.
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct MemberCursor {
    version: u8,
    user_id: Uuid,
    workspace_id: Uuid,
    after_user_id: Uuid,
    status: String,
    sort: String,
    limit: i64,
    authority: String,
    expires_at: i64,
}

/// Tham số list đã parse, không mang raw query vào application hoặc SQL.
struct MemberQuery {
    status: MembershipStatus,
    limit: i64,
    cursor: Option<String>,
}

/** Lắp route chuẩn và alias cũ vào cùng service, validator và policy membership. */
pub(super) fn routes() -> Router<HttpState> {
    Router::new()
        .route("/api/v1/users", get(users_alias).post(create_user))
        .route("/api/v1/users/{id}", patch(users_member_patch_alias))
        .route("/api/v1/workspaces/{id}/members", get(workspace_members))
        .route(
            "/api/v1/workspaces/{id}/members/{userId}",
            patch(workspace_member_patch),
        )
}

/**
 * PATCH route chuẩn kiểm path/header cùng scope trước khi dùng chung application mutation.
 * Input
 * Param: state — auth service chứa policy CAS, last Admin và audit transaction.
 * Param: headers — credential, context, CSRF và workspace header chưa tin cậy.
 * Param: `workspace_value` — workspace UUID dạng chuỗi từ URL, chưa tự cấp quyền cho actor.
 * Param: `target_value` — user UUID dạng chuỗi từ URL, chỉ chọn membership trong workspace đã authorize.
 * Param: request — JSON patch có giới hạn kích thước và schema allowlist.
 * Output: MembershipDTO sau commit với no-store.
 * Errors
 * Path/header mismatch, thiếu revision, quyền/session, transition, CAS hoặc storage.
 */
async fn workspace_member_patch(
    State(state): State<HttpState>,
    headers: HeaderMap,
    Path((workspace_value, target_value)): Path<(String, String)>,
    request: Request,
) -> Result<Response, HttpError> {
    let workspace_id = Uuid::parse_str(&workspace_value)
        .map_err(|_| HttpError::code(404, "RESOURCE_NOT_FOUND"))?;
    let target_id =
        Uuid::parse_str(&target_value).map_err(|_| HttpError::code(404, "RESOURCE_NOT_FOUND"))?;
    if let Some(header_workspace) = security::single_header(&headers, "x-workspace-id")? {
        let header_workspace = Uuid::parse_str(header_workspace)
            .map_err(|_| HttpError::validation(400, "/workspaceId", "FORMAT"))?;
        if header_workspace != workspace_id {
            // Header chỉ là selector phụ; không được ghi đè workspace path đã định tuyến request.
            return Err(HttpError::code(403, "WORKSPACE_MISMATCH"));
        }
    }
    patch_member_request(state, headers, request, workspace_id, target_id, false).await
}

/**
 * PATCH alias bắt buộc X-Workspace-Id và đổi đúng tên status theo contract tương thích.
 * Input
 * Param: state — auth service chứa policy CAS, last Admin và audit transaction.
 * Param: headers — credential, context, CSRF và workspace selector chưa tin cậy.
 * Param: id — userId membership target, không phải account-global mutation.
 * Param: request — JSON patch theo schema alias có giới hạn kích thước.
 * Output: cùng MembershipDTO/error semantics với route chuẩn, có no-store.
 * Errors
 * Thiếu/sai workspace, quyền/session, transition, CAS hoặc storage.
 */
async fn users_member_patch_alias(
    State(state): State<HttpState>,
    headers: HeaderMap,
    Path(id): Path<String>,
    request: Request,
) -> Result<Response, HttpError> {
    let target_id = Uuid::parse_str(&id).map_err(|_| HttpError::code(404, "RESOURCE_NOT_FOUND"))?;
    let workspace_id = security::single_header(&headers, "x-workspace-id")?
        .ok_or_else(|| HttpError::code(400, "WORKSPACE_REQUIRED"))?
        .parse::<Uuid>()
        .map_err(|_| HttpError::validation(400, "/workspaceId", "FORMAT"))?;
    patch_member_request(state, headers, request, workspace_id, target_id, true).await
}

/**
 * Thực hiện PATCH qua cùng auth/CAS service cho hai route mà không lộ dữ liệu ngoài MembershipDTO.
 * Input
 * Param: state — service và khóa ký của process.
 * Param: headers — session/context/CSRF cùng If-Match cần xác minh.
 * Param: request — body JSON mạng cần kiểm MIME, size và field allowlist.
 * Param: `workspace_id` — tenant scope từ route/header, vẫn phải authorize lại.
 * Param: `target_id` — membership cần cập nhật trong tenant đó.
 * Param: alias_route — chọn đúng tên status của schema alias; không mở rộng field allowlist.
 * Output: DTO allowlist sau transaction commit, response luôn no-store.
 * Errors
 * Thiếu revision, dữ liệu sai, mất quyền, last Admin, transition, CAS hoặc lỗi transaction.
 */
async fn patch_member_request(
    state: HttpState,
    headers: HeaderMap,
    request: Request,
    workspace_id: Uuid,
    target_id: Uuid,
    alias_route: bool,
) -> Result<Response, HttpError> {
    let (proof, transport, session) = sessions::inspect(&state, &headers, false, false).await?;
    if session.limited {
        return Err(HttpError::code(403, "PASSWORD_CHANGE_REQUIRED"));
    }
    sessions::check_mutation(&state, &headers, transport, &session)?;
    // Application re-locks actor/session/workspace/target để quyền còn hiện hành tại lúc CAS.
    let expected_revision = member_if_match(&headers)?;
    let fields = super::read_json(request).await?;
    let patch = parse_member_patch(&fields, alias_route)?;
    let correlation_id = Uuid::new_v4();
    let member = state
        .auth
        .patch_member(
            &proof,
            workspace_id,
            target_id,
            expected_revision,
            &patch,
            correlation_id,
        )
        .await
        .map_err(|error| map_patch_error(error).correlated(correlation_id))?;
    let mut response = (StatusCode::OK, Json(membership_json(&member))).into_response();
    no_store(&mut response);
    Ok(response)
}

/**
 * Parse đúng một revision quote từ If-Match để CAS không nhận wildcard hoặc nhiều version.
 * Input
 * Param: headers — header map đã được HTTP framework phân tách, vẫn có thể thiếu/mơ hồ.
 * Output: revision dương có thể lưu trong i64.
 * Errors
 * Thiếu trả428; header lặp, sai pattern hoặc tràn miền trả400 FORMAT.
 */
fn member_if_match(headers: &HeaderMap) -> Result<i64, HttpError> {
    let value = security::single_header(headers, "if-match")?
        .ok_or_else(|| HttpError::code(428, "PRECONDITION_REQUIRED"))?;
    let revision = value
        .strip_prefix('"')
        .and_then(|value| value.strip_suffix('"'))
        .filter(|value| {
            !value.is_empty()
                && !value.starts_with('0')
                && value.bytes().all(|byte| byte.is_ascii_digit())
        })
        .ok_or_else(|| HttpError::validation(400, "/headers/If-Match", "FORMAT"))?;
    revision
        .parse::<i64>()
        .ok()
        .filter(|revision| *revision > 0)
        .ok_or_else(|| HttpError::validation(400, "/headers/If-Match", "FORMAT"))
}

/**
 * Validate body PATCH theo allowlist route, chuẩn hóa alias và giữ explicit null khác field vắng.
 * Input
 * Param: fields — object strict JSON từ read_json, không có duplicate key.
 * Param: alias_route — route cũ dùng membershipStatus; route chuẩn dùng status.
 * Output: domain patch không chứa workspace/user selector do client tự khai.
 * Errors
 * Field ngoài schema, enum sai, alias sai type/độ dài hoặc patch rỗng.
 */
fn parse_member_patch(
    fields: &Map<String, Value>,
    alias_route: bool,
) -> Result<MembershipPatch, HttpError> {
    let status_key = if alias_route {
        "membershipStatus"
    } else {
        "status"
    };
    let allowed = if alias_route {
        &["role", "membershipStatus", "alias"][..]
    } else {
        &["role", "status", "alias"][..]
    };
    super::allowed_fields(fields, allowed)?;
    if fields.is_empty() {
        return Err(HttpError::validation(422, "/", "FORMAT"));
    }

    let role = match fields.get("role") {
        None => None,
        Some(value) => {
            let value = value
                .as_str()
                .ok_or_else(|| HttpError::validation(422, "/role", "TYPE"))?;
            Some(match value {
                "ADMIN" => WorkspaceRole::Admin,
                "USER" => WorkspaceRole::User,
                _ => return Err(HttpError::validation(422, "/role", "ENUM")),
            })
        }
    };
    let status = match fields.get(status_key) {
        None => None,
        Some(value) => {
            let value = value
                .as_str()
                .ok_or_else(|| HttpError::validation(422, status_path(alias_route), "TYPE"))?;
            Some(match value {
                "ACTIVE" => MembershipStatus::Active,
                "SUSPENDED" => MembershipStatus::Suspended,
                "REMOVED" => MembershipStatus::Removed,
                _ => {
                    return Err(HttpError::validation(422, status_path(alias_route), "ENUM"));
                }
            })
        }
    };
    let alias = match fields.get("alias") {
        None => AliasChange::Unchanged,
        Some(Value::Null) => AliasChange::Set(None),
        Some(Value::String(value)) => {
            let value = normalize_member_display_name(value)
                .map_err(|error| HttpError::validation(422, "/alias", error.code))?;
            AliasChange::Set(Some(value))
        }
        Some(_) => return Err(HttpError::validation(422, "/alias", "TYPE")),
    };
    Ok(MembershipPatch {
        role,
        status,
        alias,
    })
}

/**
 * Trả JSON Pointer đúng tên field của route để lỗi validation khớp wire schema.
 * Input
 * Param: alias_route — chọn route alias có property membershipStatus.
 * Output: path ổn định cho lỗi type/enum status.
 */
fn status_path(alias_route: bool) -> &'static str {
    if alias_route {
        "/membershipStatus"
    } else {
        "/status"
    }
}

/**
 * Ánh xạ policy PATCH sang lỗi contract, giữ stale/last-admin/transition phân biệt.
 * Input
 * Param: error — lỗi application đã loại SQL và dữ liệu request.
 * Output: status/code allowlist của MemberErrorEnvelope.
 */
fn map_patch_error(error: ApplicationError) -> HttpError {
    match error {
        ApplicationError::Forbidden => HttpError::code(403, "FORBIDDEN"),
        ApplicationError::ResourceNotFound => HttpError::code(404, "RESOURCE_NOT_FOUND"),
        ApplicationError::StaleRevision => HttpError::code(412, "VERSION_CONFLICT"),
        ApplicationError::LastAdminRequired => HttpError::code(409, "LAST_ADMIN_REQUIRED"),
        ApplicationError::InvalidTransition => HttpError::code(409, "INVALID_TRANSITION"),
        ApplicationError::InvalidInput => HttpError::validation(422, "/", "FORMAT"),
        other => HttpError::from(other),
    }
}

/**
 * GET alias yêu cầu workspace header để tuyệt đối không liệt kê account toàn cục.
 * Input
 * Param: state — service auth và signing key của process.
 * Param: headers — credential, auth context và workspace selector chưa tin cậy.
 * Param: raw_query — filter/cursor/page size từ request.
 * Output: trang member đã được application kiểm Admin trong tenant được chọn.
 * Errors
 * Thiếu/sai workspace, session không hợp lệ, limited session, query hoặc storage.
 */
async fn users_alias(
    State(state): State<HttpState>,
    headers: HeaderMap,
    RawQuery(raw_query): RawQuery,
) -> Result<Response, HttpError> {
    let (proof, _, session) = sessions::inspect(&state, &headers, false, false).await?;
    if session.limited {
        return Err(HttpError::code(403, "PASSWORD_CHANGE_REQUIRED"));
    }
    let workspace_id = security::single_header(&headers, "x-workspace-id")?
        .ok_or_else(|| HttpError::code(400, "WORKSPACE_REQUIRED"))?
        .parse::<Uuid>()
        .map_err(|_| HttpError::validation(400, "/workspaceId", "FORMAT"))?;
    members_page(state, proof, session, workspace_id, raw_query.as_deref()).await
}

/**
 * Tạo account tạm hoặc invitation theo nhánh service, chỉ phát secret một lần sau commit.
 * Input
 * Param: state — auth service, crypto và khóa ký trong process.
 * Param: headers — credential/context/CSRF và workspace selector chưa tin cậy.
 * Param: request — JSON email/displayName/role có giới hạn64 KiB.
 * Output: 201 MembershipDTO + temporaryPassword hoặc202 invitation metadata + token, đều no-store.
 * Errors
 * Session/quyền/CSRF, validation, member/invitation conflict hoặc storage/commit uncertainty.
 */
async fn create_user(
    State(state): State<HttpState>,
    headers: HeaderMap,
    request: Request,
) -> Result<Response, HttpError> {
    let (proof, transport, session) = sessions::inspect(&state, &headers, false, false).await?;
    if session.limited {
        return Err(HttpError::code(403, "PASSWORD_CHANGE_REQUIRED"));
    }
    sessions::check_mutation(&state, &headers, transport, &session)?;
    let workspace_id = security::single_header(&headers, "x-workspace-id")?
        .ok_or_else(|| HttpError::code(400, "WORKSPACE_REQUIRED"))?
        .parse::<Uuid>()
        .map_err(|_| HttpError::validation(400, "/workspaceId", "FORMAT"))?;

    let fields = super::read_json(request).await?;
    super::allowed_fields(&fields, &["email", "displayName", "role"])?;
    let email = super::string_field(&fields, "email", "/email")?;
    let display_name = super::string_field(&fields, "displayName", "/displayName")?;
    let role = match super::string_field(&fields, "role", "/role")? {
        "ADMIN" => WorkspaceRole::Admin,
        "USER" => WorkspaceRole::User,
        _ => return Err(HttpError::validation(422, "/role", "ENUM")),
    };
    let email = normalize_email(email)
        .map_err(|error| HttpError::validation(422, error.path, error.code))?;
    let display_name = normalize_member_display_name(display_name)
        .map_err(|error| HttpError::validation(422, error.path, error.code))?;
    let creation = MemberCreationRequest::new(&email, &display_name, role)
        .ok_or_else(|| HttpError::validation(422, "/displayName", "FORMAT"))?;

    // Route không nhận Idempotency-Key; key ngẫu nhiên nội bộ chỉ cô lập receipt, không replay secret khi client retry.
    let key_value = Uuid::new_v4().to_string();
    let key = IdempotencyKey::new(&key_value).ok_or_else(HttpError::unavailable)?;
    let correlation_id = Uuid::new_v4();
    let issued = state
        .auth
        .create_member(&proof, workspace_id, &creation, &key, correlation_id)
        .await
        .map_err(|error| map_create_error(error).correlated(correlation_id))?;
    let secret = issued.secret.as_ref().ok_or_else(HttpError::unavailable)?;
    let (status, body) = match &issued.outcome {
        MemberCreationOutcome::Created { user_id } => (
            StatusCode::CREATED,
            json!({
                "membership": {
                    "workspaceId": issued.workspace_id,
                    "userId": user_id,
                    "email": creation.email_normalized(),
                    "alias": creation.display_name(),
                    "role": role_name(creation.role()),
                    "status": "ACTIVE",
                    "authzVersion": 1,
                    "revision": 1,
                },
                "temporaryPassword": secret.expose(),
            }),
        ),
        MemberCreationOutcome::Invitation {
            invitation_id,
            expires_at,
        } => (
            StatusCode::ACCEPTED,
            json!({
                "invitation": {
                    "id": invitation_id,
                    "workspaceId": issued.workspace_id,
                    "role": role_name(creation.role()),
                    "expiresAt": expires_at,
                },
                "invitationToken": secret.expose(),
            }),
        ),
    };
    let mut response = (status, Json(body)).into_response();
    no_store(&mut response);
    Ok(response)
}

/**
 * GET scoped route kiểm path/header trước khi đọc trang trong tenant đã chỉ định.
 * Input
 * Param: state — service auth và signing key của process.
 * Param: headers — credential, auth context và workspace header tùy chọn.
 * Param: id — UUID workspace trên path, chưa tự cấp quyền truy cập.
 * Param: raw_query — filter/cursor/page size từ request.
 * Output: trang member chỉ trong workspace hiện hành.
 * Errors
 * Path/header mismatch, session không hợp lệ, limited session, query hoặc storage.
 */
async fn workspace_members(
    State(state): State<HttpState>,
    headers: HeaderMap,
    Path(id): Path<String>,
    RawQuery(raw_query): RawQuery,
) -> Result<Response, HttpError> {
    let (proof, _, session) = sessions::inspect(&state, &headers, false, false).await?;
    if session.limited {
        return Err(HttpError::code(403, "PASSWORD_CHANGE_REQUIRED"));
    }
    let workspace_id =
        Uuid::parse_str(&id).map_err(|_| HttpError::code(404, "RESOURCE_NOT_FOUND"))?;
    if security::single_header(&headers, "x-workspace-id")?
        .is_some_and(|value| Uuid::parse_str(value).ok() != Some(workspace_id))
    {
        return Err(HttpError::code(403, "WORKSPACE_MISMATCH"));
    }
    members_page(state, proof, session, workspace_id, raw_query.as_deref()).await
}

/**
 * Đọc đúng trang membership sau khi app recheck session/Admin cùng transaction với query tenant.
 * Input
 * Param: state — service auth và key HMAC chỉ tồn tại trong process.
 * Param: proof — credential/context đã phân tách, được application resolve lại.
 * Param: session — metadata session vừa kiểm để ràng buộc actor và hạn cursor.
 * Param: `workspace_id` — selector đã parse, vẫn chưa được coi là authority.
 * Param: `raw_query` — query mạng cần parse nghiêm trước khi dùng.
 * Output: trang MembershipDTO allowlist với Cache-Control no-store.
 * Errors
 * Cursor sai/trễ hạn, thiếu quyền, session hết hạn, query sai hoặc lỗi storage.
 */
async fn members_page(
    state: HttpState,
    proof: SessionProof,
    session: SessionInspection,
    workspace_id: Uuid,
    raw_query: Option<&str>,
) -> Result<Response, HttpError> {
    let query = parse_member_query(raw_query)?;
    let cursor = query
        .cursor
        .as_deref()
        .map(|value| decode_cursor(&state, value))
        .transpose()?;
    if cursor.as_ref().is_some_and(|cursor| {
        cursor.user_id != session.user_id
            || cursor.workspace_id != workspace_id
            || cursor.status != status_name(query.status)
            || cursor.sort != "USER_ID_ASC"
            || cursor.limit != query.limit
    }) {
        return Err(HttpError::code(400, "CURSOR_INVALID"));
    }
    let page = state
        .auth
        .list_members(
            &proof,
            workspace_id,
            query.status,
            cursor.as_ref().map(|cursor| cursor.after_user_id),
            query.limit,
        )
        .await
        .map_err(map_list_error)?;
    if cursor
        .as_ref()
        .is_some_and(|cursor| cursor.authority != page.authority_fingerprint)
    {
        return Err(HttpError::code(400, "CURSOR_INVALID"));
    }
    let next_cursor = if page.has_more {
        let last = page.items.last().ok_or_else(HttpError::unavailable)?;
        Some(encode_cursor(
            &state,
            &session,
            workspace_id,
            query.status,
            query.limit,
            last.user_id,
            &page.authority_fingerprint,
        )?)
    } else {
        None
    };
    let items: Vec<Value> = page.items.iter().map(membership_json).collect();
    let mut response = Json(json!({"items":items,"nextCursor":next_cursor})).into_response();
    no_store(&mut response);
    Ok(response)
}

/**
 * Parse query theo allowlist, từ chối key trùng và chặn filter/page sai trước application work.
 * Input
 * Param: raw — query string mạng, có thể vắng ở trang mặc định.
 * Output: status, limit và cursor đã kiểm cấu trúc.
 * Errors
 * Duplicate/unknown key, status ngoài enum, limit ngoài1–100 hoặc cursor rỗng.
 */
fn parse_member_query(raw: Option<&str>) -> Result<MemberQuery, HttpError> {
    // Dùng URI parser chuẩn để một cách decode query được áp dụng cho mọi key, tránh percent-encoding mơ hồ.
    let axum::extract::Query(pairs) = axum::extract::Query::<Vec<(String, String)>>::try_from_uri(
        &format!("/?{}", raw.unwrap_or(""))
            .parse()
            .map_err(|_| HttpError::validation(422, "/", "FORMAT"))?,
    )
    .map_err(|_| HttpError::validation(422, "/", "FORMAT"))?;
    let mut seen = std::collections::HashSet::new();
    let mut status = MembershipStatus::Active;
    let mut limit = 20_i64;
    let mut cursor = None;
    for (key, value) in pairs {
        if !seen.insert(key.clone()) {
            return Err(HttpError::validation(422, "/", "FORMAT"));
        }
        match key.as_str() {
            "status" => {
                status = match value.as_str() {
                    "ACTIVE" => MembershipStatus::Active,
                    "SUSPENDED" => MembershipStatus::Suspended,
                    "REMOVED" => MembershipStatus::Removed,
                    _ => return Err(HttpError::validation(422, "/status", "ENUM")),
                };
            }
            "limit" => {
                limit = value
                    .parse()
                    .map_err(|_| HttpError::validation(422, "/limit", "RANGE"))?;
            }
            "cursor" if !value.is_empty() => cursor = Some(value),
            "cursor" => return Err(HttpError::code(400, "CURSOR_INVALID")),
            _ => return Err(HttpError::validation(422, "/", "UNSUPPORTED_VALUE")),
        }
    }
    if !(1..=100).contains(&limit) {
        return Err(HttpError::validation(422, "/limit", "RANGE"));
    }
    Ok(MemberQuery {
        status,
        limit,
        cursor,
    })
}

/**
 * Xác minh HMAC, payload và hạn dùng trước khi lấy keyset từ cursor.
 * Input
 * Param: state — signing key chỉ tồn tại trong process.
 * Param: value — cursor opaque chưa tin cậy.
 * Output: cursor đã xác thực chữ ký và thời hạn.
 * Errors
 * CURSOR_INVALID nếu chữ ký, payload hoặc hạn dùng không hợp lệ.
 */
fn decode_cursor(state: &HttpState, value: &str) -> Result<MemberCursor, HttpError> {
    let invalid = || HttpError::code(400, "CURSOR_INVALID");
    if value.len() > 4096 {
        return Err(invalid());
    }
    let (payload, tag) = value.split_once('.').ok_or_else(invalid)?;
    // HMAC kiểm toàn vẹn trước parse để dữ liệu client sửa không thể chọn tenant/filter/keyset tùy ý.
    if !security::verify(
        &state.signing_key,
        b"workspace-members-v1:",
        payload.as_bytes(),
        tag,
    ) {
        return Err(invalid());
    }
    let bytes = security::decode_hex(payload).ok_or_else(invalid)?;
    let cursor: MemberCursor = serde_json::from_slice(&bytes).map_err(|_| invalid())?;
    if cursor.version != 1 || cursor.expires_at <= Utc::now().timestamp() {
        return Err(invalid());
    }
    Ok(cursor)
}

/**
 * Phát cursor opaque sau khi query commit; chữ ký khóa selector, filter và authority.
 * Input
 * Param: state — signing key của process, không trả ra response.
 * Param: session — actor và expiry đã xác thực.
 * Param: `workspace_id` — tenant page hiện tại.
 * Param: status — filter đã parse.
 * Param: limit — page size đã giới hạn.
 * Param: `after_user_id` — khóa member cuối cùng đã trả.
 * Param: authority — fingerprint admission trong transaction hiện tại.
 * Output: cursor hex payload kèm HMAC để client gửi lại, không phải capability.
 * Errors
 * Lỗi serialize payload hoặc tạo header an toàn.
 */
fn encode_cursor(
    state: &HttpState,
    session: &SessionInspection,
    workspace_id: Uuid,
    status: MembershipStatus,
    limit: i64,
    after_user_id: Uuid,
    authority: &str,
) -> Result<String, HttpError> {
    let cursor = MemberCursor {
        version: 1,
        user_id: session.user_id,
        workspace_id,
        after_user_id,
        status: status_name(status).to_owned(),
        sort: "USER_ID_ASC".to_owned(),
        limit,
        authority: authority.to_owned(),
        expires_at: session.expires_at.timestamp(),
    };
    let payload =
        security::encode_hex(&serde_json::to_vec(&cursor).map_err(|_| HttpError::unavailable())?);
    Ok(format!(
        "{payload}.{}",
        security::sign(
            &state.signing_key,
            b"workspace-members-v1:",
            payload.as_bytes()
        )
    ))
}

/**
 * Chỉ serialize field MembershipDTO theo contract, không lộ account global hoặc credential.
 * Input
 * Param: item — projection đã được query trong workspace được phép.
 * Output: JSON object allowlist cho một membership.
 */
fn membership_json(item: &MembershipListItem) -> Value {
    json!({
        "workspaceId": item.workspace_id,
        "userId": item.user_id,
        "email": item.email,
        "alias": item.alias,
        "role": match item.role {
            iot_domain::workspace::WorkspaceRole::Admin => "ADMIN",
            iot_domain::workspace::WorkspaceRole::User => "USER",
        },
        "status": status_name(item.status),
        "authzVersion": item.authorization_version,
        "revision": item.revision,
    })
}

/**
 * Ánh xạ trạng thái domain hữu hạn sang enum wire trong contract.
 * Input
 * Param: status — trạng thái membership đã decode từ storage.
 * Output: literal status ổn định cho response/cursor.
 */
fn status_name(status: MembershipStatus) -> &'static str {
    match status {
        MembershipStatus::Active => "ACTIVE",
        MembershipStatus::Suspended => "SUSPENDED",
        MembershipStatus::Removed => "REMOVED",
    }
}

/**
 * Ánh xạ role workspace hữu hạn sang literal wire, không suy quyền account global.
 * Input
 * Param: role — role đã parse từ enum contract.
 * Output: chuỗi `ADMIN` hoặc `USER` dùng trong MembershipDTO/invitation.
 */
fn role_name(role: WorkspaceRole) -> &'static str {
    match role {
        WorkspaceRole::Admin => "ADMIN",
        WorkspaceRole::User => "USER",
    }
}

/**
 * Giữ route list trả403 FORBIDDEN theo contract thay vì 404 mặc định của API bootstrap.
 * Input
 * Param: error — lỗi application đã lọc, không chứa SQL/input nhạy cảm.
 * Output: HTTP error allowlist; Forbidden được giữ đúng status cho endpoint member.
 */
fn map_list_error(error: ApplicationError) -> HttpError {
    match error {
        ApplicationError::Forbidden => HttpError::code(403, "FORBIDDEN"),
        other => HttpError::from(other),
    }
}

/**
 * Ánh xạ lỗi create thành mã membership cụ thể mà không nhầm lỗi current auth-context.
 * Input
 * Param: error — lỗi use case đã loại storage detail.
 * Output: HTTP error theo MemberErrorEnvelope; member/invitation duplicate giữ mã phân biệt.
 */
fn map_create_error(error: ApplicationError) -> HttpError {
    match error {
        ApplicationError::MemberExists => HttpError::code(409, "MEMBER_EXISTS"),
        ApplicationError::InvitationExists => HttpError::code(409, "INVITATION_EXISTS"),
        ApplicationError::Forbidden => HttpError::code(403, "FORBIDDEN"),
        other => HttpError::from(other),
    }
}
