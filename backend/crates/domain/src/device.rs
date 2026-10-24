//! Registry cloud và quyền đọc schema theo pin; không coi đăng ký là bằng chứng firmware đã chạy.

use crate::workspace::{WorkspaceAdmission, WorkspaceRole};
use chrono::{DateTime, Utc};
use uuid::Uuid;

/// Lỗi hữu hạn không mang serial, metadata hoặc identity của tenant khác.
#[derive(Debug, PartialEq, Eq)]
pub enum DeviceValidation {
    SerialInvalid,
    NameInvalid,
    ModelUnsupported,
    ModelMismatch,
}

/// Model đã qua bootstrap `PoC`, truyền tường minh từ composition; không có default cho phép tất cả.
pub struct ApprovedDeviceModels(Vec<String>);

impl ApprovedDeviceModels {
    /**
     * Nhận allowlist được operator phê duyệt để registry không nhận model tùy ý từ template.
     * Input
     * Param: models — mã model exact đã có bằng chứng bootstrap, không lấy từ request.
     * Output: policy đóng.
     * # Errors
     * `ModelUnsupported` nếu rỗng hoặc có mã rỗng.
     */
    pub fn new(models: Vec<String>) -> Result<Self, DeviceValidation> {
        if models.is_empty() || models.iter().any(|model| model.trim().is_empty()) {
            return Err(DeviceValidation::ModelUnsupported);
        }
        Ok(Self(models))
    }

    /**
     * Kiểm snapshot và allowlist độc lập, tránh template tự khai model làm bằng chứng phần cứng.
     * Input
     * Param: requested — mã trong intent registry.
     * Param: published — mã model của snapshot published đã resolve đúng tenant.
     * Output: hợp lệ khi exact match và thuộc allowlist.
     * # Errors
     * Mismatch hoặc unsupported khi model chưa được phép.
     */
    pub fn validate(&self, requested: &str, published: &str) -> Result<(), DeviceValidation> {
        if requested != published {
            return Err(DeviceValidation::ModelMismatch);
        }
        if !self.0.iter().any(|model| model == requested) {
            return Err(DeviceValidation::ModelUnsupported);
        }
        Ok(())
    }
}

/// Input registry không có workspace, hardware, firmware, credential hoặc trạng thái client tự khai.
#[derive(Clone)]
pub struct DeviceDraft {
    pub serial_number: String,
    pub name: String,
    pub model: String,
    pub template_version_id: Uuid,
    pub owner_user_id: Uuid,
}

impl DeviceDraft {
    /**
     * Kiểm shape registry sau khi adapter chuẩn hóa tên NFC; serial giữ exact byte theo OQ-DEVICE-001.
     * Input
     * Param: self — input có tên NFC, được trim tại đây; UUID chỉ là selector cần authorize riêng.
     * Output: draft hợp lệ.
     * # Errors
     * `SerialInvalid`/`NameInvalid`, không phản chiếu nội dung đầu vào.
     */
    pub fn validate(mut self) -> Result<Self, DeviceValidation> {
        let serial = self.serial_number.as_bytes();
        if !(1..=64).contains(&serial.len())
            || !serial[0].is_ascii_alphanumeric()
            || !serial
                .iter()
                .all(|byte| byte.is_ascii_alphanumeric() || b"._:-".contains(byte))
        {
            return Err(DeviceValidation::SerialInvalid);
        }
        self.name = self.name.trim().to_owned();
        if !(1..=100).contains(&self.name.chars().count()) {
            return Err(DeviceValidation::NameInvalid);
        }
        Ok(self)
    }
}

/// Projection identity tối thiểu để resolve schema; không đưa verifier hoặc provisioning escrow ra ngoài.
#[derive(Debug)]
pub struct DevicePin {
    pub workspace_id: Uuid,
    pub device_id: Uuid,
    pub owner_user_id: Uuid,
    pub template_version_id: Uuid,
}

impl DevicePin {
    /**
     * Giới hạn đọc schema theo assignment hiện hành và đúng workspace trước khi load published content.
     * Input
     * Param: admission — quyền member hiện hành đã resolve cùng transaction, không role client gửi.
     * Output: true khi Admin trong tenant hoặc owner; false dùng cùng not-found cho foreign/unassigned.
     */
    #[must_use]
    pub fn permits_schema(&self, admission: &WorkspaceAdmission) -> bool {
        self.workspace_id == admission.workspace_id
            && (admission.role == WorkspaceRole::Admin || self.owner_user_id == admission.user_id)
    }
}

/// Biên nhận registry sau commit; transport còn phải dựng `DeviceDTO` theo contract, không có secret.
pub struct RegisteredDevice {
    pub pin: DevicePin,
    pub serial_number: String,
    pub name: String,
    pub model: String,
    pub created_at: DateTime<Utc>,
    pub actuator_count: u64,
}
