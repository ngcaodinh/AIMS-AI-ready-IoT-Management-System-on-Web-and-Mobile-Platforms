//! HTTP adapter riêng cho publish template; router mountable này không được gắn mặc định vào Auth Lab.

use super::{HttpError, HttpState, no_store, require_empty_body, security, sessions};
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
use serde_json::{Value, json};
use std::sync::Arc;
use uuid::Uuid;

/// Dependency cho publish router đã xác thực, được composition chọn mount riêng.
#[derive(Clone)]
pub struct TemplateHttpState<S, C> {
    auth: HttpState,
    templates: Arc<TemplateService<S, C>>,
}

impl<S: TemplateStore, C: TemplateDigest> TemplateHttpState<S, C> {
    /** Tạo state bằng auth và TemplateService cùng authority database do composition cấp; không tự đọc env hoặc mở pool. */
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

/** Publish draft đúng If-Match sau khi kiểm session/CSRF hiện hành và workspace selector. */
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
    let expected_revision = super::members::parse_if_match_revision(&headers)?;
    require_empty_body(request).await?;

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
        (Some(index), TemplateField::SafeValue) => format!("/streams/{index}"),
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

/** Tạo PublishResponse từ snapshot mà chính transaction publication vừa ghi. */
fn publish_response(published: &PublishedTemplate) -> Result<Value, HttpError> {
    let content = published.content.draft();
    let streams = content
        .streams
        .iter()
        .map(project_stream)
        .collect::<Result<Vec<_>, _>>()?;
    let mut commands = Vec::new();
    for stream in &content.streams {
        if let Some(safe_value) = &stream.safe_value {
            commands.push(json!({
                "type": "SET_VALUE",
                "stream": stream.key,
                "safeValue": stream_value_json(safe_value)?,
            }));
        }
    }
    let version = json!({
        "id": published.template_version_id,
        "workspaceId": published.workspace_id,
        "templateId": published.template_id,
        "version": published.version_number,
        "schemaVersion": 1,
        "status": "PUBLISHED",
        "name": content.name,
        "model": content.model,
        "streams": streams,
        "commands": commands,
        "sourceRevision": published.source_revision,
        "publishedAt": published.published_at.to_rfc3339_opts(SecondsFormat::AutoSi, true),
    });
    Ok(json!({
        "templateId": published.template_id,
        "revision": published.published_root_revision,
        "version": version,
    }))
}

/** Chiếu stream đã validate mà không tự tạo default hoặc lộ field chỉ dành cho storage. */
fn project_stream(stream: &StreamDraft) -> Result<Value, HttpError> {
    let mut value = json!({
        "key": stream.key,
        "type": stream_type_name(stream.data_type),
        "channelKind": channel_kind_name(stream.channel_kind),
        "direction": direction_name(stream.direction),
        "unit": stream.unit.as_deref(),
    });
    if let Some(minimum) = stream.minimum {
        value["min"] = json!(minimum);
    }
    if let Some(maximum) = stream.maximum {
        value["max"] = json!(maximum);
    }
    if stream.data_type == StreamType::Enum {
        let values = stream
            .enum_values
            .iter()
            .map(stream_value_json)
            .collect::<Result<Vec<_>, _>>()?;
        value["enumValues"] = json!(values);
    }
    Ok(value)
}

/** Serialize scalar domain thành JSON scalar và giữ nguyên literal decimal chính xác. */
fn stream_value_json(value: &StreamValue) -> Result<Value, HttpError> {
    match value {
        StreamValue::Number(number) => {
            serde_json::from_str(number.json_number()).map_err(|_| HttpError::unavailable())
        }
        StreamValue::Boolean(value) => Ok(json!(value)),
        StreamValue::Text(value) => Ok(json!(value)),
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
    use super::{ApplicationError, map_publish_error, publish_response};
    use chrono::Utc;
    use iot_domain::{
        template::{ChannelKind, StreamDirection, StreamDraft, StreamType, TemplateDraft},
        template_snapshot::PublishedTemplate,
    };
    use uuid::Uuid;

    /// Request thua publish race cùng revision phải ánh xạ thành response 412 của contract.
    #[test]
    fn stale_publish_maps_to_version_conflict() {
        let error = map_publish_error(ApplicationError::StaleRevision);
        assert_eq!(error.status, 412);
        assert_eq!(error.code, "VERSION_CONFLICT");
    }

    /// Wire DTO keeps the revision copied into the snapshot separate from the committed root revision.
    #[test]
    fn publish_response_keeps_source_and_root_revisions_distinct() {
        let content = TemplateDraft {
            name: "Revision probe".into(),
            model: "SYNTHETIC".into(),
            description: None,
            streams: vec![StreamDraft {
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
            }],
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

        let response = match publish_response(&published) {
            Ok(response) => response,
            Err(_) => panic!("validated scalar mapping succeeds"),
        };
        assert_eq!(response["version"]["sourceRevision"], 3);
        assert_eq!(response["revision"], 4);
    }
}
