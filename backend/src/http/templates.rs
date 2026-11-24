//! HTTP adapter cho publish template, dùng chung `HttpState`, `PgIdentityStore` và `CryptoService` với router chính.

use super::{
    HttpError, HttpState, no_store, require_empty_body_without_json_parse, security, sessions,
};
use crate::adapters::security::CryptoService;
use axum::{
    Json, Router,
    extract::{Path, Request, State},
    http::{HeaderMap, StatusCode},
    middleware::map_response,
    response::{IntoResponse, Response},
    routing::post,
};
use chrono::SecondsFormat;
use iot_application::{
    error::ApplicationError,
    template::TemplateService,
    template_ports::{TemplateDigest, TemplateStore},
};
use iot_domain::{
    template::{
        ChannelKind, StreamDirection, StreamDraft, StreamType, StreamValue, TemplateField,
        TemplateIssueReason, TemplateValidation,
    },
    template_snapshot::PublishedTemplate,
    template_value::DecimalLiteral,
};
use iot_postgres::PgIdentityStore;
use serde::Serialize;
use serde_json::value::RawValue;
use std::sync::Arc;
use uuid::Uuid;

/// Dependency cho publish router đã xác thực, dùng chung auth/store/digest của server composition.
#[derive(Clone)]
pub struct TemplateHttpState<S, C> {
    auth: HttpState,
    templates: Arc<TemplateService<S, C>>,
}

impl<S: TemplateStore, C: TemplateDigest> TemplateHttpState<S, C> {
    /** Tạo state bằng auth và `TemplateService` cùng authority database do composition cấp; không tự đọc env hoặc mở pool. */
    #[must_use]
    pub fn new(auth: HttpState, templates: TemplateService<S, C>) -> Self {
        Self {
            auth,
            templates: Arc::new(templates),
        }
    }
}

impl TemplateHttpState<PgIdentityStore, CryptoService> {
    /**
     * Dựng state cho route template từ `HttpState` dùng chung pool, `PgIdentityStore` và `CryptoService`.
     *
     * # Input
     * Param: `auth` — state HTTP chính đã khởi tạo sẵn `TemplateService`.
     *
     * # Output
     * `TemplateHttpState` dùng chung kết nối DB, khóa ký và digest SHA-256 với router chính.
     */
    pub(super) fn from_http_state(auth: HttpState) -> Self {
        let templates = Arc::clone(&auth.templates);
        Self { auth, templates }
    }
}

/** Tạo publish router `POST /api/v1/templates/{templateId}/publish` cùng middleware `no-store` để gắn vào router server hoặc test riêng. */
pub fn template_router<S, C>(state: TemplateHttpState<S, C>) -> Router
where
    S: TemplateStore + 'static,
    C: TemplateDigest + 'static,
{
    Router::new()
        .route(
            "/api/v1/templates/{templateId}/publish",
            post(publish::<S, C>),
        )
        .layer(map_response(no_store_template_response))
        .with_state(state)
}

/** Publish draft đúng `If-Match` sau khi kiểm session/CSRF hiện hành và workspace selector. */
async fn publish<S, C>(
    State(state): State<TemplateHttpState<S, C>>,
    headers: HeaderMap,
    Path(template_value): Path<String>,
    request: Request,
) -> Result<Response, HttpError>
where
    S: TemplateStore + 'static,
    C: TemplateDigest + 'static,
{
    let template_id =
        Uuid::parse_str(&template_value).map_err(|_| HttpError::code(404, "RESOURCE_NOT_FOUND"))?;
    let workspace_value = security::single_header(&headers, "x-workspace-id")?
        .ok_or_else(|| HttpError::validation(400, "/headers/X-Workspace-Id", "REQUIRED"))?;
    let workspace_id = Uuid::parse_str(workspace_value)
        .map_err(|_| HttpError::validation(400, "/headers/X-Workspace-Id", "FORMAT"))?;

    let (proof, transport, session) =
        sessions::inspect(&state.auth, &headers, false, false).await?;
    if session.limited {
        return Err(HttpError::code(403, "PASSWORD_CHANGE_REQUIRED"));
    }
    sessions::check_mutation(&state.auth, &headers, transport, &session)?;
    let expected_revision = validate_publish_preconditions(&headers, request).await?;

    let correlation_id = Uuid::new_v4();
    let published = state
        .templates
        .publish(
            &proof,
            workspace_id,
            template_id,
            expected_revision,
            correlation_id,
        )
        .await
        .map_err(|error| map_publish_error(error).correlated(correlation_id))?;
    let body = publish_response(&published).map_err(|error| error.correlated(correlation_id))?;
    let mut response = (StatusCode::OK, Json(body)).into_response();
    no_store(&mut response);
    Ok(response)
}

/**
 * Kiểm header `If-Match` và bodyless publish sau auth/CSRF; mọi body JSON khác rỗng đều trả 422 không parse.
 *
 * # Input
 * Param: headers — header map đã qua xác thực session/CSRF.
 * Param: request — request mạng cần đọc tối đa 64 KiB để bảo đảm rỗng.
 *
 * # Output
 * Trả `expected_revision` dương từ `If-Match` khi body hợp lệ (vắng hoặc 0 byte).
 */
async fn validate_publish_preconditions(
    headers: &HeaderMap,
    request: Request,
) -> Result<i64, HttpError> {
    let expected_revision = super::members::parse_if_match_revision(headers)?;
    require_empty_body_without_json_parse(request).await?;
    Ok(expected_revision)
}

/** Ánh xạ lỗi application sang status/code publish đã chốt và vẫn giữ redaction của scope. */
fn map_publish_error(error: ApplicationError) -> HttpError {
    match error {
        ApplicationError::StaleRevision => HttpError::code(412, "VERSION_CONFLICT"),
        ApplicationError::ImmutableSchema => HttpError::code(409, "IMMUTABLE_SCHEMA"),
        ApplicationError::Forbidden => HttpError::code(403, "FORBIDDEN"),
        ApplicationError::ResourceNotFound => HttpError::code(404, "RESOURCE_NOT_FOUND"),
        ApplicationError::TemplateInvalid(validation) => map_template_validation(validation),
        other => HttpError::from(other),
    }
}

/** Ánh xạ lỗi domain sang JSON Pointer/code ổn định mà không trả lại giá trị bị từ chối. */
fn map_template_validation(validation: TemplateValidation) -> HttpError {
    let path = match (validation.stream_index, validation.field) {
        (None, TemplateField::Name) => "/name".to_owned(),
        (None, TemplateField::Model) => "/model".to_owned(),
        (None, TemplateField::Streams) => "/streams".to_owned(),
        (Some(index), TemplateField::Key) => format!("/streams/{index}/key"),
        (Some(index), TemplateField::Unit) => format!("/streams/{index}/unit"),
        (Some(index), TemplateField::Minimum) => format!("/streams/{index}/min"),
        (Some(index), TemplateField::Maximum) => format!("/streams/{index}/max"),
        (Some(index), TemplateField::EnumValues) => format!("/streams/{index}/enumValues"),
        (Some(index), TemplateField::Direction) => format!("/streams/{index}/direction"),
        // `TemplateField::SafeValue` và các field stream còn lại ánh xạ về `/streams/{index}`.
        (Some(index), _) => format!("/streams/{index}"),
        (None, _) => "/".to_owned(),
    };
    let code = match validation.reason {
        TemplateIssueReason::Required => "REQUIRED",
        TemplateIssueReason::InvalidPattern => "FORMAT",
        TemplateIssueReason::Duplicate => "DUPLICATE",
        TemplateIssueReason::InvalidBounds => "RANGE",
        TemplateIssueReason::Incompatible => "INCOMPATIBLE",
        TemplateIssueReason::InvalidValue => "INVALID_VALUE",
    };
    HttpError::field_validation(422, path, code)
}

/// Wire DTO phản hồi publish; serialize trực tiếp để giữ token decimal chính xác qua `RawValue`.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct PublishResponsePayload<'a> {
    template_id: Uuid,
    revision: i64,
    version: PublishedVersionPayload<'a>,
}

/// Snapshot immutable của một lần publish mới, luôn mang `sourceRevision` nguyên dương.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct PublishedVersionPayload<'a> {
    id: Uuid,
    workspace_id: Uuid,
    template_id: Uuid,
    version: i32,
    schema_version: u8,
    status: &'static str,
    name: &'a str,
    model: &'a str,
    streams: Vec<PublishedStreamPayload<'a>>,
    commands: Vec<PublishedCommandPayload<'a>>,
    source_revision: i64,
    published_at: String,
}

/// Định nghĩa stream trên wire cho snapshot đã publish; `enumValues` giữ nguyên phần tử đã kiểm.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct PublishedStreamPayload<'a> {
    key: &'a str,
    #[serde(rename = "type")]
    data_type: &'static str,
    channel_kind: &'static str,
    direction: &'static str,
    unit: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    min: Option<Box<RawValue>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    max: Option<Box<RawValue>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    enum_values: Option<Vec<Box<RawValue>>>,
}

/// Lệnh `SET_VALUE` được chiếu từ stream ghi được cùng `safeValue` decimal chính xác.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct PublishedCommandPayload<'a> {
    #[serde(rename = "type")]
    command_type: &'static str,
    stream: &'a str,
    safe_value: Box<RawValue>,
}

/** Tạo `PublishResponsePayload` từ snapshot mà chính transaction publication vừa ghi. */
fn publish_response(
    published: &PublishedTemplate,
) -> Result<PublishResponsePayload<'_>, HttpError> {
    let content = published.content.draft();
    let streams = content
        .streams
        .iter()
        .map(project_stream)
        .collect::<Result<Vec<_>, _>>()?;
    let mut commands = Vec::new();
    for stream in &content.streams {
        if let Some(safe_value) = &stream.safe_value {
            commands.push(PublishedCommandPayload {
                command_type: "SET_VALUE",
                stream: &stream.key,
                safe_value: stream_value_json(safe_value)?,
            });
        }
    }
    let version = PublishedVersionPayload {
        id: published.template_version_id,
        workspace_id: published.workspace_id,
        template_id: published.template_id,
        version: published.version_number,
        schema_version: 1,
        status: "PUBLISHED",
        name: &content.name,
        model: &content.model,
        streams,
        commands,
        source_revision: published.source_revision,
        published_at: published
            .published_at
            .to_rfc3339_opts(SecondsFormat::AutoSi, true),
    };
    Ok(PublishResponsePayload {
        template_id: published.template_id,
        revision: published.published_root_revision,
        version,
    })
}

/** Chiếu stream đã validate mà không tự tạo default hoặc lộ field chỉ dành cho storage. */
fn project_stream(stream: &StreamDraft) -> Result<PublishedStreamPayload<'_>, HttpError> {
    let enum_values = if stream.data_type == StreamType::Enum {
        Some(
            stream
                .enum_values
                .iter()
                .map(stream_value_json)
                .collect::<Result<Vec<_>, _>>()?,
        )
    } else {
        None
    };
    Ok(PublishedStreamPayload {
        key: &stream.key,
        data_type: stream_type_name(stream.data_type),
        channel_kind: channel_kind_name(stream.channel_kind),
        direction: direction_name(stream.direction),
        unit: stream.unit.as_deref(),
        min: bound_value_json(stream.minimum)?,
        max: bound_value_json(stream.maximum)?,
        enum_values,
    })
}

/** Chuyển biên số hữu hạn qua `DecimalLiteral::from_finite_f64` thành JSON token thô đồng nhất với bộ kiểm publish. */
fn bound_value_json(bound: Option<f64>) -> Result<Option<Box<RawValue>>, HttpError> {
    bound
        .map(|value| {
            let literal =
                DecimalLiteral::from_finite_f64(value).ok_or_else(HttpError::unavailable)?;
            RawValue::from_string(literal.json_number().to_owned())
                .map_err(|_| HttpError::unavailable())
        })
        .transpose()
}

/** Serialize scalar domain thành JSON token thô và giữ nguyên literal decimal chính xác không cần `arbitrary_precision`. */
fn stream_value_json(value: &StreamValue) -> Result<Box<RawValue>, HttpError> {
    match value {
        StreamValue::Number(number) => RawValue::from_string(number.json_number().to_owned())
            .map_err(|_| HttpError::unavailable()),
        StreamValue::Boolean(value) => {
            serde_json::value::to_raw_value(value).map_err(|_| HttpError::unavailable())
        }
        StreamValue::Text(value) => {
            serde_json::value::to_raw_value(value).map_err(|_| HttpError::unavailable())
        }
    }
}

/** Đổi datatype domain hữu hạn sang literal contract đã chốt. */
const fn stream_type_name(value: StreamType) -> &'static str {
    match value {
        StreamType::Number => "NUMBER",
        StreamType::Boolean => "BOOLEAN",
        StreamType::String => "STRING",
        StreamType::Enum => "ENUM",
    }
}

/** Đổi channel kind độc lập đã chấp nhận, không suy diễn từ direction. */
const fn channel_kind_name(value: ChannelKind) -> &'static str {
    match value {
        ChannelKind::Telemetry => "TELEMETRY",
        ChannelKind::State => "STATE",
    }
}

/** Đổi quyền đọc/ghi độc lập với channel kind. */
const fn direction_name(value: StreamDirection) -> &'static str {
    match value {
        StreamDirection::Read => "READ",
        StreamDirection::Write => "WRITE",
        StreamDirection::ReadWrite => "READ_WRITE",
    }
}

/** Áp dụng no-store cho response thành công, lỗi và fallback trong scope này. */
async fn no_store_template_response(mut response: Response) -> Response {
    no_store(&mut response);
    response
}

#[cfg(test)]
mod tests {
    use super::{
        ApplicationError, TemplateHttpState, map_publish_error, publish_response, template_router,
        validate_publish_preconditions,
    };
    use crate::{
        adapters::security::{CryptoService, PasswordService},
        http::HttpState,
    };
    use axum::{
        body::Body,
        extract::Request,
        http::{HeaderMap, HeaderValue, StatusCode},
    };
    use chrono::{DateTime, TimeDelta, Utc};
    use iot_application::{
        ports::LockedSession,
        template::TemplateService,
        template_ports::{NewTemplateVersion, TemplateDigest, TemplateStore, TemplateTransaction},
    };
    use iot_domain::{
        identity::{
            AccountSnapshot, AccountStatus, AuditRecord, ClientType, SecretString, SessionProof,
            SessionSnapshot,
        },
        template::{
            ChannelKind, StreamDirection, StreamDraft, StreamType, StreamValue, TemplateDraft,
            ValidatedTemplate,
        },
        template_snapshot::{
            PublishedTemplate, TemplateSnapshot, TemplateStatus, TemplateVersionSnapshot,
        },
        template_value::DecimalLiteral,
        workspace::{WorkspaceRole, WorkspaceSnapshot},
    };
    use iot_postgres::PgIdentityStore;
    use sha2::{Digest, Sha256};
    use sqlx::postgres::PgPoolOptions;
    use std::{
        collections::HashMap,
        future::ready,
        sync::{Arc, Mutex},
    };
    use tower::ServiceExt;
    use uuid::Uuid;

    /// Request thua publish race cùng revision phải ánh xạ thành response 412 của contract.
    #[test]
    fn stale_publish_maps_to_version_conflict() {
        let error = map_publish_error(ApplicationError::StaleRevision);
        assert_eq!(error.status, 412);
        assert_eq!(error.code, "VERSION_CONFLICT");
    }

    /// Wire DTO giữ tách biệt `sourceRevision` của snapshot với `revision` root sau commit và bảo toàn số chính xác.
    #[test]
    fn publish_response_keeps_source_and_root_revisions_distinct() {
        let content = TemplateDraft {
            name: "Revision probe".into(),
            model: "SYNTHETIC".into(),
            description: None,
            streams: vec![
                StreamDraft {
                    key: "temperature".into(),
                    display_name: "Temperature".into(),
                    channel_kind: ChannelKind::Telemetry,
                    data_type: StreamType::Number,
                    direction: StreamDirection::Read,
                    unit: None,
                    minimum: None,
                    maximum: None,
                    string_max_length: None,
                    enum_values: vec![],
                    safe_value: None,
                },
                StreamDraft {
                    key: "precision".into(),
                    display_name: "Precision".into(),
                    channel_kind: ChannelKind::State,
                    data_type: StreamType::Number,
                    direction: StreamDirection::ReadWrite,
                    unit: None,
                    minimum: Some(0.0),
                    maximum: Some(10_000_000_000_000_000.0),
                    string_max_length: None,
                    enum_values: vec![],
                    safe_value: Some(StreamValue::Number(
                        DecimalLiteral::new("9007199254740993").unwrap(),
                    )),
                },
            ],
        }
        .validate()
        .expect("synthetic publish response fixture is a valid draft");
        let published = PublishedTemplate {
            workspace_id: Uuid::new_v4(),
            template_id: Uuid::new_v4(),
            template_version_id: Uuid::new_v4(),
            version_number: 2,
            source_revision: 3,
            published_root_revision: 4,
            published_at: Utc::now(),
            content_digest: [0; 32],
            content,
        };

        let Ok(payload) = publish_response(&published) else {
            panic!("validated scalar mapping succeeds");
        };
        let raw_json = serde_json::to_string(&payload).expect("serialize publish payload");
        assert!(raw_json.contains("\"safeValue\":9007199254740993"));
        let response: serde_json::Value =
            serde_json::from_str(&raw_json).expect("parse serialized publish payload");
        assert_eq!(response["version"]["sourceRevision"], 3);
        assert_eq!(response["revision"], 4);
    }

    /// Bodyless publish phải từ chối mọi body JSON khác rỗng gồm JSON hỏng bằng 422 không parse JSON.
    #[tokio::test]
    async fn bodyless_publish_rejects_malformed_json_with_422_without_parsing() {
        let oversize = " ".repeat(65_537);
        for (content_type, body, expected_status) in [
            (Some("application/json"), "{", 422_u16),
            (Some("application/json"), "{}", 422_u16),
            (Some("text/plain"), "{", 415_u16),
            (None, "{", 415_u16),
            (Some("application/json"), oversize.as_str(), 413_u16),
        ] {
            let mut headers = HeaderMap::new();
            headers.insert("if-match", HeaderValue::from_static("\"1\""));
            let mut builder =
                Request::post("/api/v1/templates/00000000-0000-4000-8000-0000000000b1/publish");
            if let Some(mime) = content_type {
                builder = builder.header("content-type", mime);
            }
            let request = builder.body(Body::from(body.to_owned())).unwrap();
            let error = validate_publish_preconditions(&headers, request)
                .await
                .expect_err("non-empty publish body must be rejected");
            assert_eq!(error.status, expected_status);
            assert_eq!(error.code, "VALIDATION_ERROR");
        }

        let mut headers = HeaderMap::new();
        headers.insert("if-match", HeaderValue::from_static("\"7\""));
        let empty = Request::post("/api/v1/templates/00000000-0000-4000-8000-0000000000b1/publish")
            .header("content-type", "application/json")
            .body(Body::empty())
            .unwrap();
        assert_eq!(
            validate_publish_preconditions(&headers, empty).await.ok(),
            Some(7)
        );
    }

    /// Route publish trên `template_router` từ chối selector hỏng và thiếu credential trước khi chạm DB, luôn gắn `no-store`.
    #[tokio::test]
    async fn publish_route_enforces_selectors_and_credentials_before_storage() {
        let pool = PgPoolOptions::new()
            .connect_lazy("postgres://localhost/iot_template_http_boundary_test")
            .unwrap();
        let auth = HttpState::new(pool.clone(), [7; 32], "http://localhost:5173")
            .await
            .unwrap();
        let crypto = CryptoService::new(PasswordService::default(), [7; 32])
            .await
            .unwrap();
        let templates = TemplateService::new(PgIdentityStore::new(pool), crypto);
        let router = template_router(TemplateHttpState::new(auth, templates));

        let unauthenticated = router
            .clone()
            .oneshot(
                Request::post("/api/v1/templates/00000000-0000-4000-8000-0000000000b1/publish")
                    .header("x-workspace-id", "00000000-0000-4000-8000-0000000000a1")
                    .header("if-match", "\"1\"")
                    .header("content-type", "application/json")
                    .body(Body::from("{"))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(unauthenticated.status(), StatusCode::UNAUTHORIZED);
        assert_eq!(unauthenticated.headers()["cache-control"], "no-store");

        let bad_template = router
            .oneshot(
                Request::post("/api/v1/templates/not-a-uuid/publish")
                    .header("x-workspace-id", "00000000-0000-4000-8000-0000000000a1")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(bad_template.status(), StatusCode::NOT_FOUND);
        assert_eq!(bad_template.headers()["cache-control"], "no-store");
    }

    #[derive(Clone, Default)]
    struct ShaDigest;

    impl TemplateDigest for ShaDigest {
        fn content_digest(&self, canonical: &[u8]) -> [u8; 32] {
            Sha256::digest(canonical).into()
        }
    }

    struct MemoryState {
        workspace_id: Uuid,
        user_id: Uuid,
        session_id: Uuid,
        auth_context_id: Uuid,
        now: DateTime<Utc>,
        templates: HashMap<Uuid, TemplateSnapshot>,
        versions: HashMap<Uuid, TemplateVersionSnapshot>,
        audits: usize,
    }

    #[derive(Clone)]
    struct MemoryStore {
        state: Arc<Mutex<MemoryState>>,
    }

    struct MemoryTx {
        state: Arc<Mutex<MemoryState>>,
    }

    // Store trong bộ nhớ dùng `std::future::ready` thay cho `async fn` không có `.await` để giữ contract trait async mà không thêm suppression hay await giả.
    impl TemplateStore for MemoryStore {
        type Transaction = MemoryTx;

        fn begin_template(
            &self,
        ) -> impl Future<Output = Result<Self::Transaction, ApplicationError>> + Send {
            ready(Ok(MemoryTx {
                state: Arc::clone(&self.state),
            }))
        }
    }

    impl TemplateTransaction for MemoryTx {
        fn load_published_version(
            &mut self,
            workspace_id: Uuid,
            version_id: Uuid,
        ) -> impl Future<Output = Result<TemplateVersionSnapshot, ApplicationError>> + Send
        {
            let result = {
                let guard = self.state.lock().expect("memory store lock");
                guard
                    .versions
                    .get(&version_id)
                    .filter(|version| version.workspace_id == workspace_id)
                    .cloned()
            };
            ready(result.ok_or(ApplicationError::ResourceNotFound))
        }

        fn lock_actor(
            &mut self,
            _proof: &SessionProof,
        ) -> impl Future<Output = Result<LockedSession, ApplicationError>> + Send {
            let guard = self.state.lock().expect("memory store lock");
            let account = AccountSnapshot {
                user_id: guard.user_id,
                password_verifier: SecretString::new("synthetic-hash".into()),
                status: AccountStatus::Active,
                must_change_password: false,
            };
            let session = SessionSnapshot {
                session_id: guard.session_id,
                user_id: guard.user_id,
                auth_context_id: guard.auth_context_id,
                client_type: ClientType::Web,
                limited: false,
                expires_at: guard.now + TimeDelta::minutes(10),
                revoked_at: None,
            };
            let observed_at = guard.now;
            drop(guard);
            ready(Ok(LockedSession {
                account,
                session,
                observed_at,
            }))
        }

        fn lock_scope(
            &mut self,
            workspace_id: Uuid,
            user_id: Uuid,
        ) -> impl Future<Output = Result<WorkspaceSnapshot, ApplicationError>> + Send {
            let guard = self.state.lock().expect("memory store lock");
            let valid = workspace_id == guard.workspace_id && user_id == guard.user_id;
            drop(guard);
            if !valid {
                return ready(Err(ApplicationError::ResourceNotFound));
            }
            ready(Ok(WorkspaceSnapshot {
                workspace_id,
                user_id,
                workspace_active: true,
                membership_active: true,
                grant_active: true,
                role: WorkspaceRole::Admin,
                grant_generation: 1,
                workspace_authorization_version: 1,
                membership_authorization_version: 1,
            }))
        }

        fn template_now(
            &mut self,
        ) -> impl Future<Output = Result<DateTime<Utc>, ApplicationError>> + Send {
            ready(Ok(self.state.lock().expect("memory store lock").now))
        }

        fn lock_template(
            &mut self,
            workspace_id: Uuid,
            template_id: Uuid,
        ) -> impl Future<Output = Result<TemplateSnapshot, ApplicationError>> + Send {
            let result = {
                let guard = self.state.lock().expect("memory store lock");
                guard
                    .templates
                    .get(&template_id)
                    .filter(|snapshot| snapshot.workspace_id == workspace_id)
                    .cloned()
            };
            ready(result.ok_or(ApplicationError::ResourceNotFound))
        }

        fn insert_template(
            &mut self,
            workspace_id: Uuid,
            template_id: Uuid,
            _actor_id: Uuid,
            draft: &ValidatedTemplate,
            now: DateTime<Utc>,
        ) -> impl Future<Output = Result<TemplateSnapshot, ApplicationError>> + Send {
            let snapshot = TemplateSnapshot {
                workspace_id,
                template_id,
                revision: 1,
                status: TemplateStatus::Draft,
                draft: draft.clone(),
                created_at: now,
                updated_at: now,
            };
            self.state
                .lock()
                .expect("memory store lock")
                .templates
                .insert(template_id, snapshot.clone());
            ready(Ok(snapshot))
        }

        fn replace_draft(
            &mut self,
            before: &TemplateSnapshot,
            draft: &ValidatedTemplate,
            next_revision: i64,
            now: DateTime<Utc>,
        ) -> impl Future<Output = Result<TemplateSnapshot, ApplicationError>> + Send {
            let updated = TemplateSnapshot {
                workspace_id: before.workspace_id,
                template_id: before.template_id,
                revision: next_revision,
                status: TemplateStatus::Draft,
                draft: draft.clone(),
                created_at: before.created_at,
                updated_at: now,
            };
            self.state
                .lock()
                .expect("memory store lock")
                .templates
                .insert(before.template_id, updated.clone());
            ready(Ok(updated))
        }

        fn latest_version_number(
            &mut self,
            workspace_id: Uuid,
            template_id: Uuid,
        ) -> impl Future<Output = Result<i32, ApplicationError>> + Send {
            let guard = self.state.lock().expect("memory store lock");
            ready(Ok(guard
                .versions
                .values()
                .filter(|version| {
                    version.workspace_id == workspace_id && version.template_id == template_id
                })
                .map(|version| version.version_number)
                .max()
                .unwrap_or(0)))
        }

        fn publish_template(
            &mut self,
            before: &TemplateSnapshot,
            version: &NewTemplateVersion,
        ) -> impl Future<Output = Result<PublishedTemplate, ApplicationError>> + Send {
            let mut guard = self.state.lock().expect("memory store lock");
            let mut updated = before.clone();
            updated.status = TemplateStatus::Published;
            updated.revision = version.published_root_revision;
            updated.updated_at = version.published_at;
            guard.templates.insert(before.template_id, updated);
            guard.versions.insert(
                version.template_version_id,
                TemplateVersionSnapshot {
                    workspace_id: before.workspace_id,
                    template_id: before.template_id,
                    template_version_id: version.template_version_id,
                    version_number: version.version_number,
                    source_revision: Some(version.source_revision),
                    published_root_revision: Some(version.published_root_revision),
                    published_at: version.published_at,
                    published_by_user_id: version.published_by_user_id,
                    content_digest: version.content_digest,
                    content: before.draft.clone(),
                },
            );
            drop(guard);
            ready(Ok(PublishedTemplate {
                workspace_id: before.workspace_id,
                template_id: before.template_id,
                template_version_id: version.template_version_id,
                version_number: version.version_number,
                source_revision: version.source_revision,
                published_root_revision: version.published_root_revision,
                published_at: version.published_at,
                content_digest: version.content_digest,
                content: before.draft.clone(),
            }))
        }

        fn append_template_audit(
            &mut self,
            _audit: AuditRecord,
        ) -> impl Future<Output = Result<(), ApplicationError>> + Send {
            self.state.lock().expect("memory store lock").audits += 1;
            ready(Ok(()))
        }

        fn commit_template(self) -> impl Future<Output = Result<(), ApplicationError>> + Send {
            ready(Ok(()))
        }
    }

    fn setup_memory_service() -> (
        TemplateService<MemoryStore, ShaDigest>,
        Arc<Mutex<MemoryState>>,
        SessionProof,
        Uuid,
    ) {
        let workspace_id = Uuid::new_v4();
        let user_id = Uuid::new_v4();
        let auth_context_id = Uuid::new_v4();
        let state = Arc::new(Mutex::new(MemoryState {
            workspace_id,
            user_id,
            session_id: Uuid::new_v4(),
            auth_context_id,
            now: Utc::now(),
            templates: HashMap::new(),
            versions: HashMap::new(),
            audits: 0,
        }));
        let proof = SessionProof {
            token_digest: [9; 32],
            expected_context: Some(auth_context_id),
        };
        let service = TemplateService::new(
            MemoryStore {
                state: Arc::clone(&state),
            },
            ShaDigest,
        );
        (service, state, proof, workspace_id)
    }

    fn seed_legacy_pin_and_draft(
        state: &Arc<Mutex<MemoryState>>,
        workspace_id: Uuid,
        legacy_content: ValidatedTemplate,
    ) -> (Uuid, Uuid, [u8; 32]) {
        let legacy_version_id = Uuid::new_v4();
        let legacy_draft_id = Uuid::new_v4();
        let legacy_digest = ShaDigest.content_digest(&legacy_content.canonical_bytes());
        let mut guard = state.lock().expect("memory store lock");
        let user_id = guard.user_id;
        let now = guard.now;
        guard.versions.insert(
            legacy_version_id,
            TemplateVersionSnapshot {
                workspace_id,
                template_id: legacy_draft_id,
                template_version_id: legacy_version_id,
                version_number: 1,
                source_revision: None,
                published_root_revision: None,
                published_at: now,
                published_by_user_id: user_id,
                content_digest: legacy_digest,
                content: legacy_content.clone(),
            },
        );
        guard.templates.insert(
            legacy_draft_id,
            TemplateSnapshot {
                workspace_id,
                template_id: legacy_draft_id,
                revision: 1,
                status: TemplateStatus::Draft,
                draft: legacy_content,
                created_at: now,
                updated_at: now,
            },
        );
        drop(guard);
        (legacy_version_id, legacy_draft_id, legacy_digest)
    }

    fn legacy_mixed_draft(name: &str) -> TemplateDraft {
        TemplateDraft {
            name: name.into(),
            model: "LEGACY_MODEL".into(),
            description: None,
            streams: vec![
                StreamDraft {
                    key: "setpoint".into(),
                    display_name: "Setpoint".into(),
                    channel_kind: ChannelKind::State,
                    data_type: StreamType::Number,
                    direction: StreamDirection::Write,
                    unit: None,
                    minimum: Some(0.0),
                    maximum: Some(1.0),
                    string_max_length: None,
                    enum_values: vec![],
                    safe_value: Some(StreamValue::Number(
                        DecimalLiteral::new("1.0000000000000001").unwrap(),
                    )),
                },
                StreamDraft {
                    key: "legacy_mode".into(),
                    display_name: "Legacy Mode".into(),
                    channel_kind: ChannelKind::State,
                    data_type: StreamType::Enum,
                    direction: StreamDirection::Read,
                    unit: None,
                    minimum: None,
                    maximum: None,
                    string_max_length: None,
                    enum_values: vec![
                        StreamValue::Number(DecimalLiteral::new("1").unwrap()),
                        StreamValue::Text("1".into()),
                    ],
                    safe_value: None,
                },
            ],
        }
    }

    /// Pin legacy (`max=1`, `safeValue=1.0000000000000001`, enum `[1, "1"]`, tên chưa trim) vẫn đọc được digest, còn draft vượt biên thập phân bị chặn 422 trước publish và sửa được qua `replace`.
    #[tokio::test]
    async fn legacy_pin_loads_while_sub_ulp_draft_fails_publish_until_repaired() {
        let (service, state, proof, workspace_id) = setup_memory_service();
        let legacy_content = legacy_mixed_draft("  Room  ")
            .validate()
            .expect("legacy persisted shape stays readable");
        let (legacy_version_id, legacy_draft_id, legacy_digest) =
            seed_legacy_pin_and_draft(&state, workspace_id, legacy_content);

        let loaded_pin = service
            .get_version(&proof, workspace_id, legacy_version_id)
            .await
            .expect("legacy pinned snapshot reads cleanly");
        assert_eq!(loaded_pin.content_digest, legacy_digest);
        assert_eq!(loaded_pin.source_revision, None);

        let mut sub_ulp_only = legacy_mixed_draft("Room");
        sub_ulp_only.streams.truncate(1);
        let replaced = service
            .replace(
                &proof,
                workspace_id,
                legacy_draft_id,
                1,
                sub_ulp_only.clone(),
                Uuid::new_v4(),
            )
            .await
            .expect("legacy sub-ULP draft stays repairable");
        assert_eq!(replaced.revision, 2);

        let publish_err = service
            .publish(&proof, workspace_id, legacy_draft_id, 2, Uuid::new_v4())
            .await
            .expect_err("sub-ULP overflow safeValue fails at publish before commit");
        assert_eq!(map_publish_error(publish_err).status, 422);

        sub_ulp_only.streams[0].safe_value =
            Some(StreamValue::Number(DecimalLiteral::new("1").unwrap()));
        let ready = service
            .replace(
                &proof,
                workspace_id,
                legacy_draft_id,
                2,
                sub_ulp_only,
                Uuid::new_v4(),
            )
            .await
            .expect("replace repairs safeValue");
        assert_eq!(ready.revision, 3);
        let published = service
            .publish(&proof, workspace_id, legacy_draft_id, 3, Uuid::new_v4())
            .await
            .expect("repaired draft publishes cleanly");
        assert_eq!(published.version_number, 2);
    }

    /// Draft có tên chưa chuẩn hóa đọc/sửa được, bị chặn 422 trước publish nếu chưa sửa, còn ghi mới chuẩn hóa NFC/trim đồng nhất response và digest.
    #[tokio::test]
    async fn noncanonical_draft_name_blocks_publish_while_canonical_writes_align_digest_and_response()
     {
        let (service, state, proof, workspace_id) = setup_memory_service();
        let legacy_content = legacy_mixed_draft("  Room  ")
            .validate()
            .expect("legacy persisted shape stays readable");
        let (_, legacy_draft_id, _) =
            seed_legacy_pin_and_draft(&state, workspace_id, legacy_content);

        let loaded_draft = service
            .get(&proof, workspace_id, legacy_draft_id)
            .await
            .expect("legacy stored draft stays readable");
        assert_eq!(loaded_draft.draft.draft().name, "  Room  ");

        let publish_err = service
            .publish(&proof, workspace_id, legacy_draft_id, 1, Uuid::new_v4())
            .await
            .expect_err("noncanonical draft name must fail before publish commit");
        let mapped = map_publish_error(publish_err);
        assert_eq!(mapped.status, 422);
        assert_eq!(mapped.code, "VALIDATION_ERROR");

        let mut repaired = legacy_mixed_draft("  Pho\u{0300}ng  ");
        repaired.streams.truncate(1);
        repaired.streams[0].safe_value =
            Some(StreamValue::Number(DecimalLiteral::new("1").unwrap()));
        let created = service
            .create(&proof, workspace_id, repaired, Uuid::new_v4())
            .await
            .expect("create normalizes name to NFC/trim");
        assert_eq!(created.draft.draft().name, "Ph\u{00f2}ng");

        let published = service
            .publish(&proof, workspace_id, created.template_id, 1, Uuid::new_v4())
            .await
            .expect("canonical trimmed NFC draft publishes");
        assert_eq!(published.content.draft().name, "Ph\u{00f2}ng");
        let Ok(wire) = publish_response(&published) else {
            panic!("validated published response succeeds");
        };
        assert_eq!(wire.version.name, "Ph\u{00f2}ng");
        assert_eq!(
            ShaDigest.content_digest(&published.content.canonical_bytes()),
            published.content_digest
        );
        assert_eq!(state.lock().expect("memory store lock").audits, 2);
    }

    /// Điểm giữa `ryu` tại cả hai đầu `min`/`max` phải bị chặn trước khi ghi DB và khi bằng biên thì JSON wire phát đúng cùng token.
    #[tokio::test]
    async fn ryu_midpoint_bounds_align_precommit_rejection_and_wire_emission() {
        // IEEE-754 binary64 chính xác của ±1_234_567_890_123_456.25; `ryu` phát dạng rút gọn ±12345678901234562e-1.
        const RYU_MIDPOINT_LOWER_F64: f64 = f64::from_bits(0xc311_8b54_f22a_eb01);
        const RYU_MIDPOINT_UPPER_F64: f64 = f64::from_bits(0x4311_8b54_f22a_eb01);

        let (service, state, proof, workspace_id) = setup_memory_service();
        let mut upper_draft = legacy_mixed_draft("Midpoint Probe");
        upper_draft.streams.truncate(1);
        upper_draft.streams[0].minimum = Some(RYU_MIDPOINT_LOWER_F64);
        upper_draft.streams[0].maximum = Some(RYU_MIDPOINT_UPPER_F64);
        upper_draft.streams[0].safe_value = Some(StreamValue::Number(
            DecimalLiteral::new("1234567890123456.25").unwrap(),
        ));
        let legacy_upper = upper_draft.clone().validate().expect("legacy load allowed");
        let (_, draft_id, _) = seed_legacy_pin_and_draft(&state, workspace_id, legacy_upper);

        let err = service
            .publish(&proof, workspace_id, draft_id, 1, Uuid::new_v4())
            .await
            .expect_err("upper midpoint above ryu wire max rejects precommit");
        assert_eq!(map_publish_error(err).status, 422);
        {
            let guard = state.lock().expect("memory store lock");
            assert_eq!(guard.templates[&draft_id].revision, 1);
            assert_eq!(guard.versions.len(), 1);
            assert_eq!(guard.audits, 0);
        }

        let mut lower_draft = upper_draft.clone();
        lower_draft.streams[0].safe_value = Some(StreamValue::Number(
            DecimalLiteral::new("-1234567890123456.25").unwrap(),
        ));
        service
            .replace(
                &proof,
                workspace_id,
                draft_id,
                1,
                lower_draft,
                Uuid::new_v4(),
            )
            .await
            .expect("replace stores draft at lower midpoint");
        let lower_err = service
            .publish(&proof, workspace_id, draft_id, 2, Uuid::new_v4())
            .await
            .expect_err("lower midpoint below ryu wire min rejects precommit");
        assert_eq!(map_publish_error(lower_err).status, 422);

        upper_draft.streams[0].safe_value = Some(StreamValue::Number(
            DecimalLiteral::new("1234567890123456.2").unwrap(),
        ));
        service
            .replace(
                &proof,
                workspace_id,
                draft_id,
                2,
                upper_draft,
                Uuid::new_v4(),
            )
            .await
            .expect("replace aligns safeValue with wire max");
        let published = service
            .publish(&proof, workspace_id, draft_id, 3, Uuid::new_v4())
            .await
            .expect("exact ryu boundary equality publishes");
        let Ok(payload) = publish_response(&published) else {
            panic!("validated scalar mapping succeeds");
        };
        let raw_json = serde_json::to_string(&payload).expect("serialize publish payload");
        assert!(raw_json.contains("\"min\":-12345678901234562e-1"));
        assert!(raw_json.contains("\"max\":12345678901234562e-1"));
        assert!(raw_json.contains("\"safeValue\":12345678901234562e-1"));
    }
}
