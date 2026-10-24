//! Port lời mời giữ receipt, grant và audit trong một unit of work; không lộ `SQLx`.

use crate::{error::ApplicationError, ports::WorkspaceTransaction};
use chrono::{DateTime, Utc};
use iot_domain::{
    identity::SessionProof,
    invitation::{InvitationIssuer, InvitationSnapshot},
};
use std::future::Future;
use uuid::Uuid;

/// Namespace do use case quyết định theo route, không nhận tên bảng/route từ client.
#[derive(Clone, Copy)]
pub enum InvitationReceiptScope {
    Create(Uuid),
    Accept,
}

/// Projection allowlist của receipt; generation gắn replay accept với đúng lần tham gia.
pub struct InvitationReceipt {
    pub workspace_id: Uuid,
    pub invitation_id: Uuid,
    pub grant_generation: Option<i64>,
}

/// Receipt trùng key phải so body trước khi dùng projection; pending không có kết quả.
pub enum InvitationClaim {
    Reserved,
    Existing {
        request_digest: [u8; 32],
        result: Option<InvitationReceipt>,
    },
}

/// Context đã đọc dưới User→Workspace→Membership/fence→Invitation locks.
pub struct LockedInvitation {
    pub snapshot: InvitationSnapshot,
    pub issuer: InvitationIssuer,
    pub admission_generation: i64,
    pub recipient_email: String,
    pub observed_at: DateTime<Utc>,
}

pub trait InvitationTransaction: WorkspaceTransaction {
    /// Tra hint bất biến để chọn thứ tự User locks; chưa xác thực hay consume capability.
    fn invitation_hint(
        &mut self,
        digest: [u8; 32],
    ) -> impl Future<Output = Result<Option<(Uuid, Uuid)>, ApplicationError>> + Send;
    /// Khóa actor/issuer theo UUID tăng dần trước mọi Workspace; session sẽ được kiểm lại sau khóa.
    fn lock_invitation_users(
        &mut self,
        proof: &SessionProof,
        issuer_id: Uuid,
    ) -> impl Future<Output = Result<(), ApplicationError>> + Send;
    /// Lấy clock mới sau fence; không dùng `transaction_timestamp` làm admission clock.
    fn invitation_now(
        &mut self,
    ) -> impl Future<Output = Result<DateTime<Utc>, ApplicationError>> + Send;
    /// Reserve đúng namespace/actor/key, thay receipt hết24h; không lưu raw key/token.
    fn reserve_invitation_receipt(
        &mut self,
        scope: InvitationReceiptScope,
        actor_id: Uuid,
        key_digest: [u8; 32],
        request_digest: [u8; 32],
        now: DateTime<Utc>,
    ) -> impl Future<Output = Result<InvitationClaim, ApplicationError>> + Send;
    /// Complete projection invitation/workspace/generation, không nhận arbitrary JSON hoặc raw secret.
    fn complete_invitation_receipt(
        &mut self,
        scope: InvitationReceiptScope,
        actor_id: Uuid,
        key_digest: [u8; 32],
        result: &InvitationReceipt,
    ) -> impl Future<Output = Result<(), ApplicationError>> + Send;
    /// Đọc metadata đúng workspace/id cho replay create sau current Admin admission.
    fn invitation_metadata(
        &mut self,
        workspace_id: Uuid,
        invitation_id: Uuid,
    ) -> impl Future<Output = Result<InvitationSnapshot, ApplicationError>> + Send;
    /// Khóa email fence, đánh dấu pending đã hết hạn, từ chối membership chưa REMOVED.
    fn prepare_invitation(
        &mut self,
        workspace_id: Uuid,
        email: &str,
        email_digest: [u8; 32],
        now: DateTime<Utc>,
    ) -> impl Future<Output = Result<i64, ApplicationError>> + Send;
    /// Insert snapshot và digest do application tạo; unique pending là hàng rào thứ hai.
    fn insert_invitation(
        &mut self,
        invitation: &InvitationSnapshot,
        email_digest: [u8; 32],
        token_digest: [u8; 32],
    ) -> impl Future<Output = Result<(), ApplicationError>> + Send;
    /// Khóa context sau User fences; đọc email principal và current issuer/fence tại đúng workspace.
    fn lock_invitation(
        &mut self,
        digest: [u8; 32],
        recipient_id: Uuid,
    ) -> impl Future<Output = Result<LockedInvitation, ApplicationError>> + Send;
    /// CAS consume và tạo/rejoin membership bằng grant mới; không resume membership SUSPENDED.
    fn consume_invitation(
        &mut self,
        invitation: &InvitationSnapshot,
        recipient_id: Uuid,
        now: DateTime<Utc>,
    ) -> impl Future<Output = Result<i64, ApplicationError>> + Send;
}
