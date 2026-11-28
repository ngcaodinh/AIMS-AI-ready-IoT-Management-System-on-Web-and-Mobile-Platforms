//! PostgreSQL poll dùng allowlist cột và tenant/actor từ phiên đã authorize.

use crate::{PgUnitOfWork, storage_error};
use iot_application::{error::ApplicationError, provisioning::ProvisioningPollTransaction};
use iot_domain::provisioning::{
    CredentialOperation, DeliveryMode, DeliveryStatus, ProvisioningStatus,
};
use sqlx::{Row, postgres::PgRow};
use uuid::Uuid;

/**
 * Chuyển projection cột metadata sang enum đóng để state DB lạ không được coi là sẵn sàng.
 *
 * # Input
 * Param: row — hàng từ SELECT allowlist, không chứa secret hoặc ciphertext.
 *
 * # Output
 * Metadata operation đã parse hoặc `Unavailable` khi trạng thái ngoài contract.
 *
 * # Errors
 * Kiểu/cột sai hoặc retry count âm trả lỗi storage/application đã lọc.
 */
fn operation_metadata(row: &PgRow) -> Result<CredentialOperation, ApplicationError> {
    let delivery_mode = match row
        .try_get::<&str, _>("delivery_channel")
        .map_err(storage_error)?
    {
        "USB_ONE_TIME" => DeliveryMode::UsbOneTime,
        "ENROLLMENT_BLE" => DeliveryMode::EnrollmentBle,
        _ => return Err(ApplicationError::Unavailable),
    };
    let status = match row.try_get::<&str, _>("state").map_err(storage_error)? {
        "PENDING" => ProvisioningStatus::Pending,
        "READY" => ProvisioningStatus::Ready,
        "FAILED" => ProvisioningStatus::Failed,
        _ => return Err(ApplicationError::Unavailable),
    };
    let delivery_status = match row
        .try_get::<&str, _>("delivery_status")
        .map_err(storage_error)?
    {
        "PENDING" => DeliveryStatus::Pending,
        "AVAILABLE" => DeliveryStatus::Available,
        "CLAIMED" => DeliveryStatus::Claimed,
        "EXPIRED" => DeliveryStatus::Expired,
        "UNAVAILABLE" => DeliveryStatus::Unavailable,
        _ => return Err(ApplicationError::Unavailable),
    };
    let retries: i32 = row.try_get("retry_count").map_err(storage_error)?;
    Ok(CredentialOperation {
        operation_id: row
            .try_get("provisioning_operation_id")
            .map_err(storage_error)?,
        device_id: row.try_get("device_id").map_err(storage_error)?,
        delivery_mode,
        status,
        delivery_status,
        escrow_expires_at: row.try_get("expires_at").map_err(storage_error)?,
        claimed_at: row.try_get("claimed_at").map_err(storage_error)?,
        error_code: row.try_get("error_code").map_err(storage_error)?,
        retry_count: u32::try_from(retries).map_err(|_| ApplicationError::Unavailable)?,
    })
}

impl ProvisioningPollTransaction for PgUnitOfWork {
    /**
     * Đọc operation của đúng initiator trong workspace hiện hành, chỉ lấy cột poll được phép.
     *
     * # Input
     * Param: workspace_id — tenant đã current-Admin-authorize.
     * Param: actor_id — initiator từ session đã khóa, không lấy từ query/body.
     * Param: operation_id — UUID selector không cấp authority.
     *
     * # Output
     * Metadata operation; selector thiếu, foreign hoặc initiator khác cùng trả not-found.
     *
     * # Errors
     * Storage hoặc not-found; câu SQL bind cả ba selector và không đọc cột secret.
     */
    async fn credential_operation(
        &mut self,
        workspace_id: Uuid,
        actor_id: Uuid,
        operation_id: Uuid,
    ) -> Result<CredentialOperation, ApplicationError> {
        let row = sqlx::query("SELECT provisioning_operation_id,device_id,delivery_channel,state,delivery_status,expires_at,claimed_at,error_code,retry_count
            FROM provisioning_operations WHERE workspace_id=$1 AND actor_user_id=$2 AND provisioning_operation_id=$3")
            .bind(workspace_id).bind(actor_id).bind(operation_id)
            .fetch_optional(&mut *self.transaction).await.map_err(storage_error)?
            .ok_or(ApplicationError::ResourceNotFound)?;
        operation_metadata(&row)
    }
}
