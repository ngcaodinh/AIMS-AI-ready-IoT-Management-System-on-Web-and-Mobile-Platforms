//! Route đọc metadata cho operation credential. Producers lifecycle/cleanup có gate riêng.

use super::{
    HttpError, HttpState,
    templates::{api_error, exact_uuid, json_response, scope},
};
use axum::{
    Router,
    extract::{Path, State},
    http::{HeaderMap, StatusCode},
    response::Response,
    routing::get,
};
use chrono::{DateTime, Utc};
use iot_domain::provisioning::{
    CredentialOperation, DeliveryMode, DeliveryStatus, ProvisioningStatus,
};
use serde::Serialize;
use uuid::Uuid;

/**
 * Đăng ký GET poll metadata; không có route tạo operation, phát secret hoặc gọi broker.
 *
 * # Output
 * Router có duy nhất endpoint poll được bảo vệ bởi session, workspace, Admin và initiator scope.
 */
pub(super) fn routes() -> Router<HttpState> {
    Router::new().route("/api/v1/provisioning-operations/{id}", get(poll))
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct OperationDto<'a> {
    kind: &'static str,
    operation_id: Uuid,
    device_id: Uuid,
    delivery_mode: &'static str,
    status: &'static str,
    delivery_status: &'static str,
    secret_available: bool,
    escrow_expires_at: DateTime<Utc>,
    claimed_at: Option<DateTime<Utc>>,
    error_code: Option<&'a str>,
    retry_count: u32,
}

impl<'a> OperationDto<'a> {
    /**
     * Chiếu STATUS/CREDENTIAL allowlist, tính availability theo DB clock và trạng thái giao nhận.
     *
     * # Input
     * Param: operation — metadata đã lọc từ application, không mang secret.
     * Param: now — clock DB sau query dùng kiểm TTL.
     *
     * # Output
     * DTO metadata; không serial hóa ciphertext, verifier hoặc credential material.
     */
    fn new(operation: &'a CredentialOperation, now: DateTime<Utc>) -> Self {
        let delivery = operation.delivery_at(now);
        Self {
            kind: "CREDENTIAL",
            operation_id: operation.operation_id,
            device_id: operation.device_id,
            delivery_mode: match operation.delivery_mode {
                DeliveryMode::UsbOneTime => "USB_ONE_TIME",
                DeliveryMode::EnrollmentBle => "ENROLLMENT_BLE",
            },
            status: match operation.status {
                ProvisioningStatus::Pending => "PENDING",
                ProvisioningStatus::Ready => "READY",
                ProvisioningStatus::Failed => "FAILED",
            },
            delivery_status: match delivery {
                DeliveryStatus::Pending => "PENDING",
                DeliveryStatus::Available => "AVAILABLE",
                DeliveryStatus::Claimed => "CLAIMED",
                DeliveryStatus::Expired => "EXPIRED",
                DeliveryStatus::Unavailable => "UNAVAILABLE",
            },
            secret_available: operation.status == ProvisioningStatus::Ready
                && delivery == DeliveryStatus::Available
                && operation.claimed_at.is_none(),
            escrow_expires_at: operation.escrow_expires_at,
            claimed_at: operation.claimed_at,
            error_code: operation.error_code.as_deref(),
            retry_count: operation.retry_count,
        }
    }
}

#[derive(Serialize)]
struct MetadataResponse<'a> {
    kind: &'static str,
    operation: OperationDto<'a>,
}

/**
 * Đọc operation cho current Admin initiator và trả đúng discriminator của poll contract.
 *
 * # Input
 * Param: state — read-only poll service và các secret transport trong RAM.
 * Param: headers — credential/workspace selector chưa được tin cậy.
 * Param: id — operation UUID trong path, không tự cấp quyền.
 *
 * # Output
 * HTTP 200 STATUS/CREDENTIAL metadata, không query hoặc trả escrow.
 *
 * # Errors
 * Session/workspace/Admin/initiator, UUID sai dạng hoặc storage đã lọc.
 */
async fn poll(
    State(state): State<HttpState>,
    headers: HeaderMap,
    Path(id): Path<String>,
) -> Result<Response, HttpError> {
    let scope = scope(&state, &headers, false).await?;
    let id = exact_uuid(&id, "/id", 400)?;
    let (operation, now) = state
        .provisioning
        .poll(&scope.proof, scope.workspace_id, id)
        .await
        .map_err(api_error)?;
    Ok(json_response(
        StatusCode::OK,
        MetadataResponse {
            kind: "STATUS",
            operation: OperationDto::new(&operation, now),
        },
    ))
}
