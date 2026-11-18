//! Session bootstrap và picker dùng current authority; không sử dụng profile/cursor như capability.

use super::{
    HttpError, HttpState, allowed_fields, no_store, read_json, require_empty_body, security,
    session_headers, string_field,
};
use axum::{
    Json, Router,
    extract::{Path, RawQuery, Request, State},
    http::{HeaderMap, HeaderValue, StatusCode},
    response::{IntoResponse, Response},
    routing::{get, post},
};
use iot_application::auth_read::{SessionInspection, WorkspaceDetail};
use iot_domain::{
    identity::{ClientType, SessionProof},
    input::{validate_current_password, validate_new_password},
    workspace::{WorkspaceRole, WorkspaceSummary},
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use uuid::Uuid;

/** Lắp route chỉ thuộc auth/bootstrap; không mở resource/device trước chọn workspace. */
pub(super) fn routes() -> Router<HttpState> {
    Router::new()
        .route("/api/v1/me", get(me))
        .route("/api/v1/workspaces", get(workspaces))
        .route("/api/v1/workspaces/{id}", get(workspace))
        .route("/api/v1/auth/logout", post(logout))
        .route("/api/v1/auth/password", post(change_password))
        .fallback(protected_unavailable)
}

/**
 * Áp session/limited guard cho resource chưa được bàn giao; full session nhận404, không tạo dữ liệu giả.
 * Input: state và headers mạng; Output: chỉ lỗi chuẩn, không query device/dashboard khi module chưa có.
 */
async fn protected_unavailable(
    State(state): State<HttpState>,
    headers: HeaderMap,
) -> Result<Response, HttpError> {
    let (_, _, session) = inspect(&state, &headers, false, false).await?;
    Err(if session.limited {
        HttpError::code(403, "PASSWORD_CHANGE_REQUIRED")
    } else {
        HttpError::code(404, "RESOURCE_NOT_FOUND")
    })
}

/** Resolve credential source trước current session admission; discovery chỉ dành /me thiếu hẳn header. */
pub(super) async fn inspect(
    state: &HttpState,
    headers: &HeaderMap,
    discovery: bool,
    revocation: bool,
) -> Result<(SessionProof, ClientType, SessionInspection), HttpError> {
    let (token, transport) = security::credential(headers)?;
    let context = security::context(headers)?;
    if transport == ClientType::Android && context.is_some() {
        return Err(HttpError::validation(400, "/", "FORMAT"));
    }
    let proof = state.auth.session_proof(&token, context);
    let session = if revocation {
        state.auth.inspect_logout(&proof, transport).await?
    } else {
        state
            .auth
            .inspect_session(&proof, transport, discovery && context.is_none())
            .await?
    };
    // Context mismatch được core trả trước origin/CSRF; GET cùng origin không đòi Origin mà browser thường bỏ.
    security::check_read_origin(headers, &state.origin)?;
    Ok((proof, transport, session))
}

/** GET /me trả năm field cho full, còn limited chỉ error+metadata; không tự nhận login intent của client. */
async fn me(State(state): State<HttpState>, headers: HeaderMap) -> Result<Response, HttpError> {
    let (_, transport, session) = inspect(&state, &headers, true, false).await?;
    let mut response = if let Some(profile) = session.profile {
        Json(json!({"id":profile.user_id,"email":profile.email,"mustChangePassword":false,"displayTimezone":profile.display_timezone,"preferencesRevision":profile.preferences_revision})).into_response()
    } else {
        HttpError::code(403, "PASSWORD_CHANGE_REQUIRED").into_response()
    };
    no_store(&mut response);
    if transport == ClientType::Web {
        session_headers(&state, &mut response, session.context_id)?;
    }
    Ok(response)
}

/** Xác minh origin và tag CSRF constant-time chỉ cho ambient cookie, trước mọi mutation. */
pub(super) fn check_mutation(
    state: &HttpState,
    headers: &HeaderMap,
    transport: ClientType,
    session: &SessionInspection,
) -> Result<(), HttpError> {
    if transport == ClientType::Web {
        security::check_origin(headers, &state.origin, true)?;
        let tag = security::single_header(headers, "x-csrf-token")?.ok_or_else(HttpError::csrf)?;
        if !security::verify(
            &state.signing_key,
            b"csrf-v1:",
            session.context_id.as_bytes(),
            tag,
        ) {
            return Err(HttpError::csrf());
        }
    }
    Ok(())
}

/** Logout clear đúng cookie và đóng socket local chỉ sau revoke+audit commit; expired/revoked vẫn idempotent. */
async fn logout(
    State(state): State<HttpState>,
    headers: HeaderMap,
    request: Request,
) -> Result<Response, HttpError> {
    require_empty_body(request).await?;
    if !security::has_credential(&headers)? {
        security::check_read_origin(&headers, &state.origin)?;
        let mut response = StatusCode::NO_CONTENT.into_response();
        no_store(&mut response);
        return Ok(response);
    }
    let (proof, transport, session) = inspect(&state, &headers, false, true).await?;
    check_mutation(&state, &headers, transport, &session)?;
    let correlation_id = Uuid::new_v4();
    state
        .auth
        .logout(&proof, correlation_id)
        .await
        .map_err(|error| HttpError::from(error).correlated(correlation_id))?;
    state.realtime.close_session(session.session_id).await;
    Ok(mutation_success(transport))
}

/**
 * Đổi password chính chủ sau validation policy; không retry tự động khi commit UNKNOWN.
 * Input
 * Param: state — service/crypto và exact-origin policy, không nhận authority từ body.
 * Param: headers — bearer hoặc cookie/context/CSRF theo transport đã kiểm.
 * Param: request — JSON currentPassword/newPassword, không log hoặc ép kiểu.
 * Output:204 sau commit và clear cookie đúng transport.
 * Errors:422 `LENGTH/FORMAT/SAME_AS_CURRENT` trước DB, hoặc lỗi auth/storage an toàn của service.
 */
async fn change_password(
    State(state): State<HttpState>,
    headers: HeaderMap,
    request: Request,
) -> Result<Response, HttpError> {
    let fields = read_json(request).await?;
    allowed_fields(&fields, &["currentPassword", "newPassword"])?;
    let current = string_field(&fields, "currentPassword", "/currentPassword")?;
    let new = string_field(&fields, "newPassword", "/newPassword")?;
    validate_current_password(current, "/currentPassword")
        .map_err(|error| HttpError::validation(422, error.path, error.code))?;
    validate_new_password(new, "/newPassword")
        .map_err(|error| HttpError::validation(422, error.path, error.code))?;
    if current == new {
        return Err(HttpError::validation(
            422,
            "/newPassword",
            "SAME_AS_CURRENT",
        ));
    }
    let (proof, transport, session) = inspect(&state, &headers, false, false).await?;
    check_mutation(&state, &headers, transport, &session)?;
    let correlation_id = Uuid::new_v4();
    state
        .auth
        .change_password(&proof, current.to_owned(), new.to_owned(), correlation_id)
        .await
        .map_err(|error| HttpError::from(error).correlated(correlation_id))?;
    Ok(mutation_success(transport))
}

/** Trả204 và clear cookie đúng tuple chỉ ở mutation đã commit; App không có cookie/header Web. */
fn mutation_success(transport: ClientType) -> Response {
    let mut response = StatusCode::NO_CONTENT.into_response();
    no_store(&mut response);
    if transport == ClientType::Web {
        response.headers_mut().insert(
            "set-cookie",
            HeaderValue::from_static(
                "iot_session=; Path=/api/v1; Secure; HttpOnly; SameSite=Lax; Max-Age=0",
            ),
        );
    }
    response
}

/** Projection summary duy nhất cho picker/detail; Input: summary đã current admission, không authority cho request sau. */
fn summary_json(summary: &WorkspaceSummary) -> Value {
    json!({"id":summary.workspace_id,"name":summary.name,"status":"ACTIVE","role":match summary.role { WorkspaceRole::Admin => "ADMIN", WorkspaceRole::User => "USER" },"revision":summary.revision})
}

/// Cursor có chữ ký, bound account/filter ACTIVE/sort UUID/limit và authority fingerprint; không chứa secret.
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Cursor {
    version: u8,
    user_id: Uuid,
    after: Uuid,
    limit: i64,
    authority: String,
    expires_at: i64,
}

/** Parse query bằng URI parser chuẩn; Input: raw query chưa tin cậy. Errors: unknown/duplicate/filter ngoài scope. */
fn page_query(raw: Option<&str>) -> Result<(i64, Option<String>), HttpError> {
    // Query được decode bởi extractor chuẩn, không tự diễn giải percent encoding để tránh ambiguity.
    let axum::extract::Query(pairs) = axum::extract::Query::<Vec<(String, String)>>::try_from_uri(
        &format!("/?{}", raw.unwrap_or(""))
            .parse()
            .map_err(|_| HttpError::validation(422, "/", "FORMAT"))?,
    )
    .map_err(|_| HttpError::validation(422, "/", "FORMAT"))?;
    let mut seen = std::collections::HashSet::new();
    let mut limit = 20_i64;
    let mut cursor = None;
    for (key, value) in pairs {
        if !seen.insert(key.clone()) {
            return Err(HttpError::validation(422, "/", "FORMAT"));
        }
        match key.as_str() {
            "limit" => {
                limit = value
                    .parse()
                    .map_err(|_| HttpError::validation(422, "/limit", "RANGE"))?;
            }
            "cursor" => cursor = Some(value),
            "status" if value == "ACTIVE" => {}
            "includeHistorical" if value == "false" => {}
            _ => return Err(HttpError::validation(422, "/", "UNSUPPORTED_VALUE")),
        }
    }
    if !(1..=100).contains(&limit) {
        return Err(HttpError::validation(422, "/limit", "RANGE"));
    }
    Ok((limit, cursor))
}

/** Verify cursor trước khi query tiếp; Input: value opaque và state key. Errors:400 không echo cursor. */
fn decode_cursor(state: &HttpState, value: &str) -> Result<Cursor, HttpError> {
    let invalid = || HttpError::code(400, "CURSOR_INVALID");
    let (payload, tag) = value.split_once('.').ok_or_else(invalid)?;
    if !security::verify(
        &state.signing_key,
        b"workspace-active-uuid-v1:",
        payload.as_bytes(),
        tag,
    ) {
        return Err(invalid());
    }
    let bytes = security::decode_hex(payload).ok_or_else(invalid)?;
    let cursor: Cursor = serde_json::from_slice(&bytes).map_err(|_| invalid())?;
    if cursor.version != 1 || cursor.expires_at <= chrono::Utc::now().timestamp() {
        return Err(invalid());
    }
    Ok(cursor)
}

/** Picker luôn current session; quyền đổi giữa trang trả `CURSOR_INVALID` thay vì tiếp tục từ snapshot cũ. */
async fn workspaces(
    State(state): State<HttpState>,
    headers: HeaderMap,
    RawQuery(query): RawQuery,
) -> Result<Response, HttpError> {
    let (proof, _, session) = inspect(&state, &headers, false, false).await?;
    if session.limited {
        return Err(HttpError::code(403, "PASSWORD_CHANGE_REQUIRED"));
    }
    let (limit, encoded) = page_query(query.as_deref())?;
    let cursor = encoded
        .as_deref()
        .map(|value| decode_cursor(&state, value))
        .transpose()?;
    if cursor
        .as_ref()
        .is_some_and(|cursor| cursor.user_id != session.user_id || cursor.limit != limit)
    {
        return Err(HttpError::code(400, "CURSOR_INVALID"));
    }
    let page = state
        .auth
        .workspace_page(&proof, cursor.as_ref().map(|cursor| cursor.after), limit)
        .await?;
    if cursor
        .as_ref()
        .is_some_and(|cursor| cursor.authority != page.authority_fingerprint)
    {
        return Err(HttpError::code(400, "CURSOR_INVALID"));
    }
    let next =
        if page.items.len() == usize::try_from(limit).map_err(|_| HttpError::unavailable())? {
            let last = page.items.last().ok_or_else(HttpError::unavailable)?;
            let cursor = Cursor {
                version: 1,
                user_id: session.user_id,
                after: last.workspace_id,
                limit,
                authority: page.authority_fingerprint,
                expires_at: session.expires_at.timestamp(),
            };
            let payload = security::encode_hex(
                &serde_json::to_vec(&cursor).map_err(|_| HttpError::unavailable())?,
            );
            Some(format!(
                "{payload}.{}",
                security::sign(
                    &state.signing_key,
                    b"workspace-active-uuid-v1:",
                    payload.as_bytes()
                )
            ))
        } else {
            None
        };
    let items: Vec<Value> = page.items.iter().map(summary_json).collect();
    let mut response = Json(json!({"items":items,"nextCursor":next})).into_response();
    no_store(&mut response);
    Ok(response)
}

/** Recheck membership trước detail; selector UUID không tự cấp quyền, body trả đầy đủ contract065. */
async fn workspace(
    State(state): State<HttpState>,
    headers: HeaderMap,
    Path(id): Path<String>,
) -> Result<Response, HttpError> {
    let (proof, _, session) = inspect(&state, &headers, false, false).await?;
    if session.limited {
        return Err(HttpError::code(403, "PASSWORD_CHANGE_REQUIRED"));
    }
    let workspace_id =
        Uuid::parse_str(&id).map_err(|_| HttpError::code(404, "RESOURCE_NOT_FOUND"))?;
    if security::single_header(&headers, "x-workspace-id")?
        .is_some_and(|value| Uuid::parse_str(value).ok() != Some(workspace_id))
    {
        return Err(HttpError::code(403, "FORBIDDEN"));
    }
    let detail = state.auth.workspace_detail(&proof, workspace_id).await?;
    let mut response = Json(detail_json(&detail)).into_response();
    no_store(&mut response);
    Ok(response)
}

/** Serialize detail allowlist; Input: detail do application trả sau current rights, không gồm private fields. */
fn detail_json(detail: &WorkspaceDetail) -> Value {
    let mut body = summary_json(&detail.summary);
    for (key, value) in [
        ("description", json!(detail.description)),
        ("defaultTimezone", json!(detail.default_timezone)),
        ("creatorId", json!(detail.creator_id)),
        ("membershipStatus", json!("ACTIVE")),
        ("authzVersion", json!(detail.authorization_version)),
        ("membershipRevision", json!(detail.membership_revision)),
        (
            "membershipAuthzVersion",
            json!(detail.membership_authorization_version),
        ),
        ("createdAt", json!(detail.created_at)),
        ("archivedAt", json!(detail.archived_at)),
    ] {
        body[key] = value;
    }
    body
}

#[cfg(test)]
mod tests {
    use super::{Cursor, decode_cursor, mutation_success, page_query};
    use crate::http::{HttpState, security};
    use iot_domain::identity::ClientType;

    /** Đối chiếu Set-Cookie từ response builder logout thật với OpenAPI để bắt lệch wire contract. */
    #[test]
    fn web_logout_response_matches_openapi_set_cookie_exactly() {
        let openapi: serde_json::Value =
            serde_json::from_str(include_str!("../../../contracts/openapi/auth.v1.json")).unwrap();
        let expected_cookie = openapi
            .pointer(
                "/paths/~1api~1v1~1auth~1logout/post/responses/204/headers/Set-Cookie/schema/const",
            )
            .and_then(serde_json::Value::as_str)
            .expect("OpenAPI must define the logout clear-cookie value");
        let web_response = mutation_success(ClientType::Web);
        assert_eq!(web_response.status(), axum::http::StatusCode::NO_CONTENT);
        assert_eq!(web_response.headers()["set-cookie"], expected_cookie);

        let app_response = mutation_success(ClientType::Android);
        assert!(app_response.headers().get("set-cookie").is_none());
    }

    /** Query chuẩn decode cursor đúng một lần, giới hạn1–100 và không nhận duplicate/historical ngoài scope. */
    #[test]
    fn pagination_query_has_explicit_shape_and_limits() {
        assert_eq!(page_query(None).ok(), Some((20, None)));
        assert_eq!(
            page_query(Some("limit=1&cursor=a%2Eb")).ok(),
            Some((1, Some("a.b".to_owned())))
        );
        assert!(page_query(Some("limit=1&limit=2")).is_err());
        assert!(page_query(Some("limit=0")).is_err());
        assert!(page_query(Some("includeHistorical=true")).is_err());
        assert_eq!(
            page_query(Some("limit=100&status=ACTIVE")).ok(),
            Some((100, None))
        );
        for query in [
            "limit=101",
            "status=SUSPENDED",
            "status=REMOVED",
            "sort=name",
            "limit=-1",
        ] {
            assert!(page_query(Some(query)).is_err());
        }
    }

    /** Ký cursor tổng hợp trong RAM bằng đúng namespace production, không phát key hoặc payload qua diagnostic.
     * Input
     * Param: state — HttpState test dùng pool lazy, không kết nối database.
     * Param: expires_at — Unix timestamp để kiểm boundary hết hạn không cần chờ24giờ.
     * Param: version — wire version cần kiểm policy compatibility.
     * Output: opaque cursor hợp lệ về chữ ký, authority/user/limit chỉ là selector tổng hợp.
     */
    fn signed_cursor(state: &HttpState, expires_at: i64, version: u8) -> String {
        let cursor = Cursor {
            version,
            user_id: uuid::Uuid::from_u128(1),
            after: uuid::Uuid::from_u128(2),
            limit: 20,
            authority: "synthetic-authority-fingerprint".to_owned(),
            expires_at,
        };
        let payload = security::encode_hex(&serde_json::to_vec(&cursor).unwrap());
        let tag = security::sign(
            &state.signing_key,
            b"workspace-active-uuid-v1:",
            payload.as_bytes(),
        );
        format!("{payload}.{tag}")
    }

    /** Kiểm chữ ký/version/expiry trước mọi query; future cursor là positive control của cùng verifier.
     * Pool lazy và password service thật chỉ dựng state, không có DB hoặc session fixture.
     */
    #[tokio::test]
    async fn signed_cursor_rejects_expiry_boundary_and_version_before_query() {
        let pool = sqlx::postgres::PgPoolOptions::new()
            .connect_lazy("postgresql://test@127.0.0.1:1/unused")
            .unwrap();
        let state = HttpState::new(pool, [19; 32], "http://localhost:5173")
            .await
            .unwrap();
        let timestamp = chrono::Utc::now().timestamp();
        let future = signed_cursor(&state, timestamp + 60, 1);
        assert!(decode_cursor(&state, &future).is_ok());
        for encoded in [
            signed_cursor(&state, timestamp - 1, 1),
            signed_cursor(&state, timestamp, 1),
            signed_cursor(&state, timestamp + 60, 2),
            format!("{future}0"),
        ] {
            let error = decode_cursor(&state, &encoded)
                .err()
                .expect("invalid cursor must be rejected");
            assert_eq!(error.status, 400);
            assert_eq!(error.code, "CURSOR_INVALID");
            assert_eq!(error.details, serde_json::json!({}));
        }
    }
}
