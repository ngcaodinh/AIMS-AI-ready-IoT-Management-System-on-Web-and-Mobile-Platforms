//! HTTP adapter riêng cho publish template; router mountable này không được gắn mặc định vào Auth Lab.

use super::{
    HttpError, HttpState, no_store, require_empty_body_without_json_parse, security, sessions,
};
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
};
use serde::Serialize;
use serde_json::value::RawValue;
use std::sync::Arc;
use uuid::Uuid;

/// Dependency cho publish router đã xác thực, được composition chọn mount riêng.
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

/** Tạo publish router độc lập để composition root tự chọn nơi mount; Auth Lab không nhận route này tự động. */
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
    min: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    max: Option<f64>,
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
        min: stream.minimum,
        max: stream.maximum,
        enum_values,
    })
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
    use chrono::Utc;
    use iot_application::template::TemplateService;
    use iot_domain::{
        template::{
            ChannelKind, StreamDirection, StreamDraft, StreamType, StreamValue, TemplateDraft,
        },
        template_snapshot::PublishedTemplate,
        template_value::DecimalLiteral,
    };
    use iot_postgres::PgIdentityStore;
    use sqlx::postgres::PgPoolOptions;
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
}
