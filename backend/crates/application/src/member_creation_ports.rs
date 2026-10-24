//! Ports tạo member giữ account/membership/invitation/receipt/audit cùng unit of work.

use crate::{error::ApplicationError, invitation_ports::InvitationTransaction};
use chrono::{DateTime, Utc};
use iot_domain::{
    identity::SecretString,
    member_creation::{MemberCreationOutcome, MemberCreationRequest},
};
use std::future::Future;
use uuid::Uuid;

/// Namespace/actor của intent được application xác thực, không lấy authority từ receipt.
#[derive(Clone, Copy)]
pub struct MemberCreationReceiptKey {
    pub workspace_id: Uuid,
    pub actor_id: Uuid,
    pub key_digest: [u8; 32],
}

/// Kết quả reserve không có secret; pending row chỉ tồn tại trong transaction chưa commit.
pub enum MemberCreationClaim {
    Reserved,
    Existing {
        request_digest: [u8; 32],
        outcome: Option<MemberCreationOutcome>,
    },
}

pub trait MemberCreationTransaction: InvitationTransaction {
    /// Lấy global email creation fence trước User/Workspace, digest HMAC ổn định giữa các instance.
    fn lock_creation_email(
        &mut self,
        email_digest: [u8; 32],
    ) -> impl Future<Output = Result<(), ApplicationError>> + Send;
    /// Lookup tồn tại dưới email fence; không đọc verifier hoặc thay account đã có.
    fn creation_account_exists(
        &mut self,
        email: &str,
    ) -> impl Future<Output = Result<bool, ApplicationError>> + Send;
    /// Reserve scoped `MEMBER_CREATE_V1`; chỉ xóa receipt đúng key đã hết24h.
    fn reserve_member_creation(
        &mut self,
        key: MemberCreationReceiptKey,
        request_digest: [u8; 32],
        now: DateTime<Utc>,
    ) -> impl Future<Output = Result<MemberCreationClaim, ApplicationError>> + Send;
    /// Insert account tạm và member/grant1; PHC là dữ liệu nhạy cảm, không raw password.
    fn insert_temporary_member(
        &mut self,
        workspace_id: Uuid,
        user_id: Uuid,
        request: &MemberCreationRequest,
        verifier: &SecretString,
        now: DateTime<Utc>,
    ) -> impl Future<Output = Result<(), ApplicationError>> + Send;
    /// Ghi projection outcome hữu hạn cùng mutation/audit; không lưu email/alias/token/password.
    fn complete_member_creation(
        &mut self,
        key: MemberCreationReceiptKey,
        outcome: &MemberCreationOutcome,
    ) -> impl Future<Output = Result<(), ApplicationError>> + Send;
}
