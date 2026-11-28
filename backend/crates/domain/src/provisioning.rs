//! Metadata operation credential cho phép đọc theo scope, tách khỏi dữ liệu bàn giao.

use chrono::{DateTime, Utc};
use uuid::Uuid;

/// Hai cách bàn giao có quyền claim khác nhau dù cùng tạo broker credential.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DeliveryMode {
    UsbOneTime,
    EnrollmentBle,
}

/// Trục cấu hình broker độc lập với việc client đã consume quyền lấy bản sao secret.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ProvisioningStatus {
    Pending,
    Ready,
    Failed,
}

/// Chỉ AVAILABLE trong cửa sổ escrow có thể consume; CLAIMED bền vững sau hết TTL.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DeliveryStatus {
    Pending,
    Available,
    Claimed,
    Expired,
    Unavailable,
}

/// Metadata allowlist cho polling và replay, không chứa ciphertext, verifier hoặc username.
pub struct CredentialOperation {
    pub operation_id: Uuid,
    pub device_id: Uuid,
    pub delivery_mode: DeliveryMode,
    pub status: ProvisioningStatus,
    pub delivery_status: DeliveryStatus,
    pub escrow_expires_at: DateTime<Utc>,
    pub claimed_at: Option<DateTime<Utc>>,
    pub error_code: Option<String>,
    pub retry_count: u32,
}

impl CredentialOperation {
    /// Dùng metadata deadline để poll tránh hiển thị AVAILABLE sau hết hạn ngay cả khi cleanup đang chạy.
    #[must_use]
    pub fn delivery_at(&self, now: DateTime<Utc>) -> DeliveryStatus {
        if self.claimed_at.is_none()
            && matches!(
                self.delivery_status,
                DeliveryStatus::Pending | DeliveryStatus::Available
            )
            && now >= self.escrow_expires_at
        {
            DeliveryStatus::Expired
        } else {
            self.delivery_status
        }
    }
}
