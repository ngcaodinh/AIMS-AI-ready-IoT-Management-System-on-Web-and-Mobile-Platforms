//! Lỗi use case độc lập với SQLSTATE/HTTP và không mang dữ liệu nhạy cảm.

use iot_domain::identity::AccessFailure;
use std::fmt;

/// Kết quả business/infrastructure đã lọc; `CommitUnknown` không được tự replay mutation.
#[derive(Debug, PartialEq, Eq)]
pub enum ApplicationError {
    InvalidCredentials,
    RateLimited { retry_after_seconds: i64 },
    SessionInvalid,
    PasswordChangeRequired,
    Forbidden,
    Conflict,
    InvalidInput,
    TimezoneInvalid,
    TemplateInvalid(iot_domain::template::TemplateValidation),
    DeviceOwnerInvalid,
    DeviceModelMismatch,
    DeviceModelUnsupported,
    DeviceExists,
    ResourceNotFound,
    ImmutableSchema,
    Unavailable,
    CommitUnknown,
    InvitationUnavailable,
    InvitationRecipientMismatch,
    GlobalAccountProtected,
    StaleRevision,
    LastAdminRequired,
}

impl fmt::Display for ApplicationError {
    /// In mã lỗi cố định, không đưa SQL/credential hoặc nội dung request vào chẩn đoán.
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "{self:?}")
    }
}
impl std::error::Error for ApplicationError {}

impl From<AccessFailure> for ApplicationError {
    /// Ánh xạ lý do domain từ chối quyền sang lỗi use case, không phụ thuộc framework transport.
    fn from(failure: AccessFailure) -> Self {
        match failure {
            AccessFailure::SessionInvalid => Self::SessionInvalid,
            AccessFailure::ContextMismatch => Self::Conflict,
            AccessFailure::PasswordChangeRequired => Self::PasswordChangeRequired,
            AccessFailure::Forbidden => Self::Forbidden,
        }
    }
}
