//! Registry wire. Tạo identity cloud và khả năng đã pin, tách riêng provisioning và presence.

use super::{
    HttpError, HttpState,
    template_wire::{self, CommandOutput, field_error},
    templates::{api_error, exact_uuid, json_response, scope},
};
use axum::{
    Router,
    extract::{Query, Request, State, rejection::QueryRejection},
    http::{HeaderMap, StatusCode},
    response::Response,
    routing::get,
};
use chrono::{DateTime, Utc};
use iot_application::error::ApplicationError;
use iot_domain::{
    device::{DeviceDraft, DeviceRecord, valid_device_serial},
    template::TemplateDraft,
};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

/**
 * Đăng ký POST registry và GET recovery exact để caller dùng sau mất response.
 *
 * # Output
 * Router có hai endpoint; handlers tự yêu cầu session/workspace và mutation CSRF thích hợp.
 */
pub(super) fn routes() -> Router<HttpState> {
    Router::new().route("/api/v1/devices", get(recover).post(register))
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct DeviceDto<'a> {
    id: Uuid,
    workspace_id: Uuid,
    owner_id: Uuid,
    template_version_id: Uuid,
    serial: &'a str,
    name: &'a str,
    model: &'a str,
    room: Option<&'a str>,
    tags: [&'a str; 0],
    lifecycle: &'a str,
    connectivity: &'a str,
    last_seen: Option<DateTime<Utc>>,
    firmware_version: Option<&'a str>,
    firmware_digest: Option<&'a str>,
    hardware_revision: Option<&'a str>,
    credential_status: &'a str,
    maintenance: &'a str,
    capabilities: Vec<CommandOutput<'a>>,
    revision: i64,
    created_at: DateTime<Utc>,
    updated_at: DateTime<Utc>,
}

impl<'a> DeviceDto<'a> {
    /**
     * Dựng DTO từ registry đã lưu và schema immutable đúng pin.
     *
     * # Input
     * Param: device — metadata persisted, không phải dữ liệu body ban đầu.
     * Param: template — content đã xác minh từ version UUID của device.
     *
     * # Output
     * DTO response không chứa escrow, credential principal hoặc secret.
     *
     * # Errors
     * Cấu hình đã lưu không serialize được sẽ trả lỗi dependency đã lọc.
     */
    fn from_record(
        device: &'a DeviceRecord,
        template: &'a TemplateDraft,
    ) -> Result<Self, HttpError> {
        Ok(Self {
            id: device.pin.device_id,
            workspace_id: device.pin.workspace_id,
            owner_id: device.pin.owner_user_id,
            template_version_id: device.pin.template_version_id,
            serial: &device.serial_number,
            name: &device.name,
            model: &device.model,
            room: None,
            tags: [],
            lifecycle: &device.lifecycle,
            connectivity: &device.connectivity,
            last_seen: device.last_seen,
            firmware_version: device.firmware_version.as_deref(),
            firmware_digest: device.firmware_digest.as_deref(),
            hardware_revision: device.hardware_revision.as_deref(),
            credential_status: &device.credential_status,
            maintenance: &device.maintenance,
            capabilities: template_wire::capabilities(template)?,
            revision: device.revision,
            created_at: device.created_at,
            updated_at: device.updated_at,
        })
    }
}

#[derive(Serialize)]
struct NextStep {
    #[serde(rename = "type")]
    step_type: &'static str,
    methods: [&'static str; 2],
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct RegisteredDto<'a> {
    #[serde(flatten)]
    device: DeviceDto<'a>,
    next_step: NextStep,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct RecoveryPage<'a> {
    items: Vec<DeviceDto<'a>>,
    next_cursor: Option<String>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct RecoveryQuery {
    serial: String,
}

/// Map lỗi registry thành code public, giữ cùng lỗi duplicate ở mọi workspace.
/**
 * Ánh xạ lỗi registry thành mã API ổn định mà không lộ natural key hoặc tenant khác.
 *
 * # Input
 * Param: error — lỗi use case đã loại dữ liệu SQL/request.
 *
 * # Output
 * HTTP error tương ứng với duplicate, owner, model, draft pin hoặc authority/storage.
 */
fn registration_error(error: ApplicationError) -> HttpError {
    match error {
        ApplicationError::DeviceExists => HttpError::code(409, "DEVICE_EXISTS"),
        ApplicationError::DeviceOwnerInvalid => HttpError::code(422, "OWNER_INVALID"),
        ApplicationError::DeviceModelMismatch | ApplicationError::DeviceModelUnsupported => {
            HttpError::code(422, "MODEL_MISMATCH")
        }
        ApplicationError::DeviceTemplateNotPublished => {
            HttpError::code(422, "TEMPLATE_NOT_PUBLISHED")
        }
        other => api_error(other),
    }
}

/**
 * Đăng ký device dưới current Admin, exact published pin và active owner.
 *
 * # Input
 * Param: state — application services và session authority của composition.
 * Param: headers — credential, workspace và CSRF boundary chưa được tin cậy.
 * Param: request — JSON strict chỉ nhận serial/name/model/templateVersionId/ownerId.
 *
 * # Output
 * HTTP 201 receipt sau commit cùng capability từ đúng version đã pin.
 *
 * # Errors
 * Validation, quyền/CSRF, model/owner, duplicate hoặc lỗi dependency đã lọc.
 */
async fn register(
    State(state): State<HttpState>,
    headers: HeaderMap,
    request: Request,
) -> Result<Response, HttpError> {
    let scope = scope(&state, &headers, true).await?;
    let fields = template_wire::read_fields(request).await?;
    fields.allow(
        &["serial", "name", "model", "templateVersionId", "ownerId"],
        "",
    )?;
    let serial = fields.required::<String>("serial", "")?;
    if !valid_device_serial(&serial) {
        return Err(field_error(422, "VALIDATION_ERROR", "/serial", "FORMAT"));
    }
    let draft = DeviceDraft {
        serial_number: serial,
        name: fields.required("name", "")?,
        model: fields.required("model", "")?,
        template_version_id: exact_uuid(
            &fields.required::<String>("templateVersionId", "")?,
            "/templateVersionId",
            422,
        )?,
        owner_user_id: exact_uuid(&fields.required::<String>("ownerId", "")?, "/ownerId", 422)?,
    };
    let correlation = Uuid::new_v4();
    let (receipt, schema) = state
        .devices
        .register_with_schema(&scope.proof, scope.workspace_id, draft, correlation)
        .await
        .map_err(|error| registration_error(error).correlated(correlation))?;
    let device = DeviceRecord::from(receipt);
    Ok(json_response(
        StatusCode::CREATED,
        RegisteredDto {
            device: DeviceDto::from_record(&device, schema.draft())?,
            next_step: NextStep {
                step_type: "SELECT_SETUP_METHOD",
                methods: ["USB", "QR_BLE"],
            },
        },
    ))
}

/**
 * Khôi phục receipt theo serial exact để caller đối soát response bị mất.
 *
 * # Input
 * Param: state — application services và authority của composition.
 * Param: headers — session/workspace selector chưa được tin cậy.
 * Param: query — serial exact; lookup luôn giới hạn current workspace/Admin.
 *
 * # Output
 * Trang zero-or-one device metadata từ version UUID đã pin; không xác nhận tenant khác.
 *
 * # Errors
 * Query/serial sai dạng, authority hoặc lỗi storage đã lọc.
 */
async fn recover(
    State(state): State<HttpState>,
    headers: HeaderMap,
    query: Result<Query<RecoveryQuery>, QueryRejection>,
) -> Result<Response, HttpError> {
    let scope = scope(&state, &headers, false).await?;
    let Query(query) = query.map_err(|_| HttpError::validation(422, "/serial", "FORMAT"))?;
    if !valid_device_serial(&query.serial) {
        return Err(HttpError::validation(422, "/serial", "FORMAT"));
    }
    let device = state
        .devices
        .recover(&scope.proof, scope.workspace_id, &query.serial)
        .await
        .map_err(registration_error)?;
    let items = device
        .as_ref()
        .map(|(device, schema)| DeviceDto::from_record(device, schema.draft()))
        .transpose()?
        .into_iter()
        .collect();
    Ok(json_response(
        StatusCode::OK,
        RecoveryPage {
            items,
            next_cursor: None,
        },
    ))
}
