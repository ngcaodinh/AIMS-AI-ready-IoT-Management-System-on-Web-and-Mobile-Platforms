//! HTTP adapter cho IAM; business rule vẫn thuộc application/domain, không mở CORS ambient.

mod input;
mod members;
mod realtime;
mod security;
mod sessions;

use crate::adapters::security::{CryptoService, PasswordService};
use axum::{
    Json, Router,
    body::to_bytes,
    extract::{Request, State},
    http::{HeaderMap, HeaderValue, StatusCode},
    response::{IntoResponse, Response},
    routing::post,
};
use iot_application::{
    auth_diagnostics::AuthDiagnostics, error::ApplicationError, identity::IdentityService,
};
use iot_domain::{
    identity::ClientType,
    input::{normalize_email, validate_password},
};
use iot_postgres::PgIdentityStore;
use serde_json::{Map, Value, json};
use sqlx::PgPool;
use std::sync::Arc;
use uuid::Uuid;

pub(super) type AuthService = IdentityService<PgIdentityStore, CryptoService>;

/// State composition có key chỉ trong memory; không derive Debug hoặc đọc environment.
#[derive(Clone)]
pub struct HttpState {
    pub(super) auth: AuthService,
    realtime: realtime::RealtimeHub,
    pub(super) signing_key: Arc<[u8; 32]>,
    pub(super) origin: Arc<str>,
}

impl HttpState {
    /**
     * Dựng state mặc định không đo, chỉ nhận cấu hình từ composition thay vì tự đọc environment.
     * Input
     * Param: `pool` — writer pool đã cấu hình quyền và timeout, không chứa quyền owner mới.
     * Param: `signing_key` — key auth256bit trong RAM, không dùng chung key measurement.
     * Param: `origin` — exact Web origin để bảo vệ transport/CSRF.
     * Output: state auth với diagnostics disabled, giữ API constructor hiện có.
     * # Errors
     * Cấu hình origin hoặc crypto không hợp lệ.
     */
    pub async fn new(
        pool: PgPool,
        signing_key: [u8; 32],
        origin: &str,
    ) -> Result<Self, ApplicationError> {
        Self::new_with_diagnostics(pool, signing_key, origin, None).await
    }

    /**
     * Dựng state opt-in bằng cùng observer cho hasher/store, không đổi crypto hoặc auth policy.
     * Input
     * Param: `pool` — pool composition đã cấp cho auth writer.
     * Param: `signing_key` — key auth trong RAM, không xuất qua observer.
     * Param: `origin` — Web origin phải qua validation hiện có.
     * Param: `diagnostics` — optional sink; None giữ default-off, sink phải inactive trong startup.
     * Output: state cùng observer qua clones; quota handshake DB lấy từ pool và chừa một connection cho auth/reconcile.
     * # Errors
     * Origin/crypto cấu hình không hợp lệ, giữ mapping hiện có và không log key hoặc SQL.
     */
    pub async fn new_with_diagnostics(
        pool: PgPool,
        signing_key: [u8; 32],
        origin: &str,
        diagnostics: Option<Arc<dyn AuthDiagnostics>>,
    ) -> Result<Self, ApplicationError> {
        security::validate_origin(origin).map_err(|_| ApplicationError::InvalidInput)?;
        let mut passwords = PasswordService::default();
        // Chừa một kết nối tối đa cho login/logout và reconciler; cap realtime không vượt hai truy vấn đồng thời.
        let handshake_db_capacity =
            realtime::handshake_db_capacity(pool.options().get_max_connections());
        let mut store = PgIdentityStore::new(pool);
        if let Some(sink) = diagnostics {
            passwords = passwords.with_diagnostics(sink.clone());
            store = store.with_diagnostics(sink);
        }
        let crypto = CryptoService::new(passwords, signing_key).await?;
        Ok(Self {
            auth: IdentityService::new(store, crypto),
            realtime: realtime::RealtimeHub::with_handshake_db_capacity(handshake_db_capacity),
            signing_key: Arc::new(signing_key),
            origin: Arc::from(origin),
        })
    }
}

/// Error envelope allowlist; không giữ nguyên SQL/input/header trong lỗi.
pub(super) struct HttpError {
    status: u16,
    code: &'static str,
    details: Value,
    retry_after: Option<i64>,
    correlation_id: Uuid,
}

impl HttpError {
    /** Tạo validation theo path/code cố định; không đưa field value chưa tin cậy vào response. */
    fn validation(status: u16, path: &'static str, code: &'static str) -> Self {
        Self {
            status,
            code: "VALIDATION_ERROR",
            details: json!({"fieldErrors":[{"path":path,"code":code}]}),
            retry_after: None,
            correlation_id: Uuid::new_v4(),
        }
    }
    /** Lỗi dependency chung; không phân biệt lỗi DB/hasher/commit cho client. */
    fn unavailable() -> Self {
        Self::code(503, "SERVICE_UNAVAILABLE")
    }
    /** Lỗi chung cho credential vắng, unknown, malformed hoặc transport không khớp. */
    fn session_invalid() -> Self {
        Self::session_expired()
    }
    /** Lỗi cho session đã nhận diện nhưng hết hạn theo clock server. */
    fn session_expired() -> Self {
        Self::code(401, "SESSION_EXPIRED")
    }
    /** Lỗi cho session đã nhận diện và thu hồi; không trả thêm metadata về session. */
    fn session_revoked() -> Self {
        Self::code(401, "SESSION_REVOKED")
    }
    /** Context sai phải từ chối trước profile hoặc side effect. */
    fn context_mismatch() -> Self {
        Self::code(409, "AUTH_CONTEXT_MISMATCH")
    }
    /** Từ chối origin/CSRF bằng cùng mã bảo vệ mutation. */
    fn csrf() -> Self {
        Self::code(403, "CSRF_INVALID")
    }
    /** Tạo error không mang dữ liệu; Input: status/code là literal allowlist của adapter. */
    fn code(status: u16, code: &'static str) -> Self {
        Self {
            status,
            code,
            details: json!({}),
            retry_after: None,
            correlation_id: Uuid::new_v4(),
        }
    }

    /** Giữ cùng request identity với audit core; Input: UUID không secret do adapter sinh. */
    pub(super) fn correlated(mut self, correlation_id: Uuid) -> Self {
        self.correlation_id = correlation_id;
        self
    }
}

impl From<ApplicationError> for HttpError {
    /** Giữ mapping domain/infrastructure; commit UNKNOWN không phát credential và không tự replay. */
    fn from(error: ApplicationError) -> Self {
        match error {
            ApplicationError::InvalidCredentials => Self::code(401, "AUTH_INVALID"),
            ApplicationError::RateLimited {
                retry_after_seconds,
            } => Self {
                retry_after: Some(retry_after_seconds),
                ..Self::code(429, "RATE_LIMITED")
            },
            ApplicationError::SessionInvalid => Self::session_invalid(),
            ApplicationError::SessionExpired => Self::session_expired(),
            ApplicationError::SessionRevoked => Self::session_revoked(),
            ApplicationError::PasswordChangeRequired => Self::code(403, "PASSWORD_CHANGE_REQUIRED"),
            ApplicationError::Conflict => Self::context_mismatch(),
            // Tách lỗi rejoin để không làm mất mã auth-context mismatch của phiên Web.
            ApplicationError::InvalidTransition => Self::code(409, "INVALID_TRANSITION"),
            // Route FEAT066 cũ vẫn nhận mã conflict tổng quát; FEAT003 mới ánh xạ riêng ở handler.
            ApplicationError::MemberExists | ApplicationError::InvitationExists => {
                Self::context_mismatch()
            }
            ApplicationError::Forbidden | ApplicationError::ResourceNotFound => {
                Self::code(404, "RESOURCE_NOT_FOUND")
            }
            ApplicationError::InvalidInput => Self::validation(422, "/", "FORMAT"),
            _ => Self::unavailable(),
        }
    }
}

impl IntoResponse for HttpError {
    /** Serialize error cùng correlation mới; không phản chiếu message hoặc header tùy ý từ client. */
    fn into_response(self) -> Response {
        let message = if self.code == "AUTH_INVALID" {
            "Thông tin đăng nhập không hợp lệ."
        } else if self.code == "VALIDATION_ERROR" {
            "Thông tin đăng nhập hoặc giá trị chưa hợp lệ."
        } else {
            "Không thể hoàn tất yêu cầu. Vui lòng kiểm tra trạng thái và thử lại."
        };
        let mut response = (StatusCode::from_u16(self.status).unwrap_or(StatusCode::INTERNAL_SERVER_ERROR), Json(json!({"error":{"code":self.code,"message":message,"details":self.details,"correlationId":self.correlation_id}}))).into_response();
        no_store(&mut response);
        if let Some(seconds) = self.retry_after {
            if let Ok(value) = HeaderValue::from_str(&seconds.to_string()) {
                response.headers_mut().insert("retry-after", value);
            }
        }
        response
    }
}

/** Gắn no-store và nosniff mọi response auth, bao gồm error. Input: response đã serialize. */
pub(super) fn no_store(response: &mut Response) {
    response
        .headers_mut()
        .insert("cache-control", HeaderValue::from_static("no-store"));
    response.headers_mut().insert(
        "x-content-type-options",
        HeaderValue::from_static("nosniff"),
    );
}

/** Đọc JSON có cận64KiB; Input: request mạng. Errors:415 MIME,413 size,400 malformed/duplicate. */
pub(super) async fn read_json(request: Request) -> Result<Map<String, Value>, HttpError> {
    let content_type = security::single_header(request.headers(), "content-type")?.unwrap_or("");
    if !content_type
        .split(';')
        .next()
        .is_some_and(|mime| mime.trim().eq_ignore_ascii_case("application/json"))
    {
        return Err(HttpError::validation(415, "", "CONTENT_TYPE"));
    }
    let bytes = to_bytes(request.into_body(), 65_536)
        .await
        .map_err(|_| HttpError::validation(413, "", "BODY_TOO_LARGE"))?;
    let input::StrictValue(value) = serde_json::from_slice(&bytes).map_err(|error| {
        HttpError::validation(
            400,
            "",
            if error.to_string().starts_with("duplicate field") {
                "DUPLICATE_FIELD"
            } else {
                "MALFORMED_JSON"
            },
        )
    })?;
    match value {
        Value::Object(fields) => Ok(fields),
        _ => Err(HttpError::validation(422, "", "TYPE")),
    }
}

/**
 * Chặn body trên mutation bodyless theo cùng giới hạn và phân biệt MIME đã dùng cho logout.
 * Input
 * Param: request — request mạng chưa tin cậy; chỉ đọc content type và tối đa64KiB body.
 * Output: Ok khi body vắng hoặc dài0 byte.
 * Errors: 413 quá lớn, 415 MIME không hỗ trợ, 400 JSON hỏng/duplicate, 422 JSON hợp lệ nhưng body bị cấm.
 */
pub(super) async fn require_empty_body(request: Request) -> Result<(), HttpError> {
    let content_type =
        security::single_header(request.headers(), "content-type")?.map(str::to_owned);
    let bytes = to_bytes(request.into_body(), 65_536)
        .await
        .map_err(|_| HttpError::code(413, "VALIDATION_ERROR"))?;
    if bytes.is_empty() {
        return Ok(());
    }
    if !content_type.as_deref().is_some_and(|value| {
        value
            .split(';')
            .next()
            .is_some_and(|mime| mime.trim().eq_ignore_ascii_case("application/json"))
    }) {
        return Err(HttpError::code(415, "VALIDATION_ERROR"));
    }
    serde_json::from_slice::<input::StrictValue>(&bytes)
        .map_err(|_| HttpError::code(400, "VALIDATION_ERROR"))?;
    Err(HttpError::code(422, "VALIDATION_ERROR"))
}

/** Lấy field chuỗi strict; Input: fields JSON, key/path cố định. Không coerce null/number/bool. */
pub(super) fn string_field<'a>(
    fields: &'a Map<String, Value>,
    key: &str,
    path: &'static str,
) -> Result<&'a str, HttpError> {
    fields
        .get(key)
        .ok_or_else(|| HttpError::validation(422, path, "REQUIRED"))?
        .as_str()
        .ok_or_else(|| HttpError::validation(422, path, "TYPE"))
}

/** Reject field ngoài contract; Input: fields chưa tin cậy, allowed là allowlist nội bộ. */
pub(super) fn allowed_fields(
    fields: &Map<String, Value>,
    allowed: &[&str],
) -> Result<(), HttpError> {
    if fields.keys().any(|key| !allowed.contains(&key.as_str())) {
        return Err(HttpError::validation(422, "", "UNKNOWN_FIELD"));
    }
    Ok(())
}

/** Login strict→origin→core; sau commit session/audit trả cookie cho Web, bearer cho Android/IOS theo OQ007. */
async fn login(
    State(state): State<HttpState>,
    headers: HeaderMap,
    request: Request,
) -> Result<Response, HttpError> {
    // Browser khai Android/IOS vẫn phải qua Origin trước DB; clientType chỉ là metadata/transport.
    security::check_origin(&headers, &state.origin, false)?;
    if security::has_credential(&headers)?
        && security::single_header(&headers, "authorization")?.is_some()
    {
        // Login có thể thay account cookie cũ; mixed cookie/bearer vẫn bị từ chối trước session mutation.
        let _ = security::credential(&headers)?;
    }
    let fields = read_json(request).await?;
    allowed_fields(&fields, &["email", "password", "clientType"])?;
    let email = string_field(&fields, "email", "/email")?;
    let password = string_field(&fields, "password", "/password")?;
    let client = match string_field(&fields, "clientType", "/clientType")? {
        "WEB" => ClientType::Web,
        "ANDROID" => ClientType::Android,
        "IOS" => ClientType::Ios,
        _ => {
            return Err(HttpError::validation(422, "/clientType", "ENUM"));
        }
    };
    security::check_origin(&headers, &state.origin, client == ClientType::Web)?;
    let email = normalize_email(email)
        .map_err(|error| HttpError::validation(422, error.path, error.code))?;
    validate_password(password, "/password")
        .map_err(|error| HttpError::validation(422, error.path, error.code))?;
    let correlation_id = Uuid::new_v4();
    let issued = state
        .auth
        .login(&email, password.to_owned(), client, correlation_id)
        .await
        .map_err(|error| HttpError::from(error).correlated(correlation_id))?;
    let mut body = json!({"me":{"id":issued.user_id,"email":email,"mustChangePassword":issued.limited},"expiresAt":issued.expires_at,"limited":issued.limited});
    if client != ClientType::Web {
        body["token"] = json!(issued.token.expose());
    }
    let mut response = Json(body).into_response();
    no_store(&mut response);
    if client == ClientType::Web {
        let remaining = (issued.expires_at - chrono::Utc::now())
            .num_seconds()
            .clamp(0, 86_400);
        if remaining == 0 {
            return Err(HttpError::session_expired());
        }
        let cookie = format!(
            "iot_session={}; Secure; HttpOnly; SameSite=Lax; Path=/api/v1; Max-Age={remaining}",
            issued.token.expose()
        );
        response.headers_mut().insert(
            "set-cookie",
            HeaderValue::from_str(&cookie).map_err(|_| HttpError::unavailable())?,
        );
        session_headers(&state, &mut response, issued.auth_context_id)?;
    }
    Ok(response)
}

/** Cấp context/CSRF bound phiên; Input: context lấy từ Session đã xác thực, response không được cache. */
pub(super) fn session_headers(
    state: &HttpState,
    response: &mut Response,
    context: Uuid,
) -> Result<(), HttpError> {
    response.headers_mut().insert(
        "x-auth-context-id",
        HeaderValue::from_str(&context.to_string()).map_err(|_| HttpError::unavailable())?,
    );
    let csrf = security::sign(&state.signing_key, b"csrf-v1:", context.as_bytes());
    response.headers_mut().insert(
        "x-csrf-token",
        HeaderValue::from_str(&csrf).map_err(|_| HttpError::unavailable())?,
    );
    Ok(())
}

/**
 * Tạo auth router và chạy DB reconciler cho socket của instance này.
 * Input: state dùng chung auth/pool/key và registry local do composition root khởi tạo.
 * Side effects: một reconciler bounded được spawn; task kết thúc khi state/router được drop.
 */
pub fn auth_router(state: HttpState) -> Router {
    state.realtime.start_reconciliation(state.auth.clone());
    sessions::routes()
        .merge(members::routes())
        .merge(realtime::routes())
        .route("/api/v1/auth/login", post(login))
        .with_state(state)
}
