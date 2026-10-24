//! Member mutation chỉ đổi authority trong một workspace, không revoke global account/session.

use crate::{
    error::ApplicationError,
    identity::IdentityService,
    ports::{IdentitySecurity, IdentityStore, IdentityTransaction, WorkspaceTransaction},
};
use chrono::{DateTime, Utc};
use iot_domain::audit_write::AuditDetail;
use iot_domain::{
    identity::{AuditRecord, SessionProof},
    membership::{MembershipFailure, MembershipPatch, MembershipSnapshot},
};
use std::future::Future;
use uuid::Uuid;

/// Email dùng HMAC admission fence nội bộ; caller transport chỉ nhận projection snapshot riêng.
pub struct LockedMembership {
    pub snapshot: MembershipSnapshot,
    pub email_normalized: String,
}

/// Unit of work member giữ current Admin/CAS/scoped cleanup/audit trong cùng physical transaction.
pub trait MembershipTransaction: WorkspaceTransaction {
    /// Khóa actor/target User theo UUID tăng dần trước Workspace; resolver phải kiểm proof lại.
    fn lock_member_subjects(
        &mut self,
        proof: &SessionProof,
        target_id: Uuid,
    ) -> impl Future<Output = Result<(), ApplicationError>> + Send;
    /// Khóa target membership đúng tenant và đếm other capable Admin dưới parent fence.
    fn lock_member(
        &mut self,
        workspace_id: Uuid,
        target_id: Uuid,
    ) -> impl Future<Output = Result<LockedMembership, ApplicationError>> + Send;
    /// Lấy admission clock mới sau khóa để session đã hết hạn trong lock wait không được ghi.
    fn membership_now(
        &mut self,
    ) -> impl Future<Output = Result<DateTime<Utc>, ApplicationError>> + Send;
    /// Persist state/revision/auth version bằng CAS, không thay grant hoặc global account.
    fn save_member(
        &mut self,
        before: &MembershipSnapshot,
        after: &MembershipSnapshot,
        now: DateTime<Utc>,
    ) -> impl Future<Output = Result<(), ApplicationError>> + Send;
    /// Vô hiệu capability/pending work đúng scope; dispatched/unknown giữ cho reconciliation.
    fn invalidate_member_authority(
        &mut self,
        before: &MembershipSnapshot,
        after: &MembershipSnapshot,
        email_digest: [u8; 32],
        now: DateTime<Utc>,
    ) -> impl Future<Output = Result<(), ApplicationError>> + Send;
}

impl From<MembershipFailure> for ApplicationError {
    /// Giữ nguyên lý do last Admin/CAS/rejoin cho transport, không lộ storage metadata.
    fn from(failure: MembershipFailure) -> Self {
        match failure {
            MembershipFailure::InvalidPatch => Self::InvalidInput,
            MembershipFailure::StaleRevision => Self::StaleRevision,
            MembershipFailure::LastAdminRequired => Self::LastAdminRequired,
            MembershipFailure::RejoinRequired => Self::Conflict,
            MembershipFailure::RevisionExhausted => Self::Unavailable,
        }
    }
}

impl<S: IdentityStore, C: IdentitySecurity> IdentityService<S, C>
where
    S::Transaction: MembershipTransaction,
{
    /**
     * Đổi role/status/alias bằng current Admin và CAS, giữ global session và quyền tenant khác.
     * Input
     * Param: proof — full session/context phải còn current Admin trong workspace đích.
     * Param: `workspace_id` — tenant selector cần authorize trước mọi mutation.
     * Param: `target_id` — thành viên thuộc đúng tenant, không là account global patch.
     * Param: `expected_revision` — If-Match hiện hành của membership.
     * Param: patch — tối thiểu một trường; alias null có nghĩa xóa alias.
     * Param: `correlation_id` — identity audit/outbox không chứa secret.
     * Output: snapshot nội bộ sau commit; HTTP adapter phải dùng DTO allowlist.
     * # Errors
     * Current authority, stale revision, last Admin, rejoin trái workflow hoặc storage/unknown commit.
     */
    pub async fn update_member(
        &self,
        proof: &SessionProof,
        workspace_id: Uuid,
        target_id: Uuid,
        expected_revision: i64,
        patch: &MembershipPatch,
        correlation_id: Uuid,
    ) -> Result<MembershipSnapshot, ApplicationError> {
        if expected_revision <= 0 {
            return Err(ApplicationError::InvalidInput);
        }
        let mut transaction = self.store.begin().await?;
        transaction.lock_member_subjects(proof, target_id).await?;
        let locked = transaction.lock_session(proof).await?;
        let principal =
            locked
                .session
                .authorize(&locked.account, proof, locked.observed_at, false)?;
        transaction
            .lock_workspace(workspace_id, principal.user_id())
            .await?
            .authorize(&principal, true)?;
        let member = transaction.lock_member(workspace_id, target_id).await?;
        let next = member.snapshot.apply(patch, expected_revision)?;
        let now = transaction.membership_now().await?;
        locked
            .session
            .authorize(&locked.account, proof, now, false)?;
        let digest = self.security.bucket_digest(&member.email_normalized)?;
        transaction
            .save_member(&member.snapshot, &next, now)
            .await?;
        // Alias-only không đổi authority; không đóng socket hoặc hủy tác vụ khi chỉ đổi tên hiển thị.
        if next.authorization_version != member.snapshot.authorization_version {
            transaction
                .invalidate_member_authority(&member.snapshot, &next, digest, now)
                .await?;
        }
        transaction
            .append_audit(AuditRecord {
                workspace_id: Some(workspace_id),
                actor_user_id: Some(principal.user_id()),
                session_id: Some(principal.session_id()),
                detail: AuditDetail::MembershipChanged(
                    iot_domain::audit_write::MembershipAudit::between(&member.snapshot, &next),
                ),
                client_type: principal.client_type(),
                correlation_id,
            })
            .await?;
        transaction.commit().await?;
        Ok(next)
    }
}
