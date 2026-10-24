//! Admin quản trị metadata/revoke; token/digest không đi qua response và CAS không đổi truth đã dùng.

use crate::{
    error::ApplicationError,
    identity::IdentityService,
    invitation_ports::InvitationTransaction,
    ports::{IdentitySecurity, IdentityStore, IdentityTransaction, WorkspaceTransaction},
};
use chrono::{DateTime, Utc};
use iot_domain::{
    audit_write::AuditDetail,
    identity::{AuditRecord, SessionProof},
    invitation_management::{
        InvitationCursor, InvitationMetadata, InvitationPage, InvitationStatus, InvitationView,
        RevokeDecision, RevokeFailure,
    },
};
use std::future::Future;
use uuid::Uuid;

pub trait InvitationManagementTransaction: InvitationTransaction {
    /// Metadata scoped/keyset bounded dưới Workspace fence; status dùng clock đã lấy sau locks.
    fn list_invitation_metadata(
        &mut self,
        workspace_id: Uuid,
        status: Option<InvitationStatus>,
        cursor: Option<&InvitationCursor>,
        limit: i64,
        now: DateTime<Utc>,
    ) -> impl Future<Output = Result<Vec<InvitationMetadata>, ApplicationError>> + Send;
    /// Khóa đúng workspace/id cho get/revoke, không đưa token/digest vào projection.
    fn lock_invitation_metadata(
        &mut self,
        workspace_id: Uuid,
        invitation_id: Uuid,
    ) -> impl Future<Output = Result<InvitationMetadata, ApplicationError>> + Send;
    /// CAS pending revoke, để trigger tăng revision; trả revision engine xác nhận, không tự SET version.
    fn revoke_invitation_row(
        &mut self,
        workspace_id: Uuid,
        invitation_id: Uuid,
        expected_revision: i64,
        now: DateTime<Utc>,
    ) -> impl Future<Output = Result<i64, ApplicationError>> + Send;
}

impl From<RevokeFailure> for ApplicationError {
    /// Giữ Used409, CAS stale và capability unavailable riêng để transport ánh xạ theo route.
    fn from(failure: RevokeFailure) -> Self {
        match failure {
            RevokeFailure::Used => Self::Conflict,
            RevokeFailure::StaleRevision => Self::StaleRevision,
            RevokeFailure::Unavailable => Self::InvitationUnavailable,
            RevokeFailure::RevisionExhausted => Self::Unavailable,
        }
    }
}

impl<S: IdentityStore, C: IdentitySecurity> IdentityService<S, C>
where
    S::Transaction: InvitationManagementTransaction,
{
    /**
     * Đọc trang metadata invitation bằng current Admin, không phát bearer capability.
     * Input
     * Param: proof — full session/context cần resolve và authorize dưới User fence.
     * Param: `workspace_id` — selector tenant phải ACTIVE và actor là current Admin.
     * Param: status — filter trạng thái hữu hạn, expiry tính bằng server clock.
     * Param: cursor — issued-at/ID keyset nội bộ; HTTP phải ký/bind selector trước khi truyền vào.
     * Param: limit —1…100 row, overfetch1 để biết có trang sau.
     * Output: trang metadata/trạng thái và continuation nội bộ, không raw token/digest.
     * # Errors
     * Invalid limit, current authority hoặc storage; không có quyền đọc global invitation.
     */
    pub async fn list_invitations(
        &self,
        proof: &SessionProof,
        workspace_id: Uuid,
        status: Option<InvitationStatus>,
        cursor: Option<&InvitationCursor>,
        limit: i64,
    ) -> Result<InvitationPage, ApplicationError> {
        if !(1..=100).contains(&limit) {
            return Err(ApplicationError::InvalidInput);
        }
        let mut transaction = self.store.begin().await?;
        let locked = transaction.lock_session(proof).await?;
        let principal =
            locked
                .session
                .authorize(&locked.account, proof, locked.observed_at, false)?;
        transaction
            .lock_workspace(workspace_id, principal.user_id())
            .await?
            .authorize(&principal, true)?;
        let now = transaction.invitation_now().await?;
        locked
            .session
            .authorize(&locked.account, proof, now, false)?;
        let mut rows = transaction
            .list_invitation_metadata(workspace_id, status, cursor, limit + 1, now)
            .await?;
        let next_cursor =
            if rows.len() > usize::try_from(limit).map_err(|_| ApplicationError::InvalidInput)? {
                rows.pop();
                rows.last().map(|row| InvitationCursor {
                    issued_at: row.issued_at,
                    invitation_id: row.invitation_id,
                })
            } else {
                None
            };
        let entries = rows
            .into_iter()
            .map(|metadata| InvitationView {
                status: metadata.status(now),
                metadata,
            })
            .collect();
        transaction.commit().await?;
        Ok(InvitationPage {
            entries,
            next_cursor,
        })
    }

    /**
     * Đọc metadata một invitation bằng composite scope, dùng cùng authorization với list/revoke.
     * Input
     * Param: proof — full session/context của current Admin.
     * Param: `workspace_id` — tenant ACTIVE phải có membership Admin hiện hành.
     * Param: `invitation_id` — identity cần đọc trong đúng tenant, không phải accept token.
     * Output: metadata/trạng thái sau clock sau row lock; không có capability hoặc issuer authority snapshot.
     * # Errors
     * Authority, unavailable hoặc storage; foreign ID không làm lộ tenant khác.
     */
    pub async fn get_invitation(
        &self,
        proof: &SessionProof,
        workspace_id: Uuid,
        invitation_id: Uuid,
    ) -> Result<InvitationView, ApplicationError> {
        let mut transaction = self.store.begin().await?;
        let locked = transaction.lock_session(proof).await?;
        let principal =
            locked
                .session
                .authorize(&locked.account, proof, locked.observed_at, false)?;
        transaction
            .lock_workspace(workspace_id, principal.user_id())
            .await?
            .authorize(&principal, true)?;
        let metadata = transaction
            .lock_invitation_metadata(workspace_id, invitation_id)
            .await?;
        let now = transaction.invitation_now().await?;
        locked
            .session
            .authorize(&locked.account, proof, now, false)?;
        let status = metadata.status(now);
        transaction.commit().await?;
        Ok(InvitationView { metadata, status })
    }

    /**
     * Thu hồi pending invitation bằng CAS, required audit và native version cùng commit.
     * Input
     * Param: proof — full current Admin, không dùng quyền issuer đã chụp lúc tạo.
     * Param: `workspace_id` — tenant ACTIVE của invitation đích.
     * Param: `invitation_id` — identity metadata, không accept token/digest.
     * Param: `expected_revision` — If-Match phải khớp row dưới lock.
     * Param: `correlation_id` — UUID audit không mang email/token.
     * Output: hoàn thành sau commit; current revoked là no-op không audit mới.
     * # Errors
     * Lời mời đã dùng, stale revision, expired/unavailable, authority hoặc storage/unknown commit.
     */
    pub async fn revoke_invitation(
        &self,
        proof: &SessionProof,
        workspace_id: Uuid,
        invitation_id: Uuid,
        expected_revision: i64,
        correlation_id: Uuid,
    ) -> Result<(), ApplicationError> {
        let mut transaction = self.store.begin().await?;
        let locked = transaction.lock_session(proof).await?;
        let principal =
            locked
                .session
                .authorize(&locked.account, proof, locked.observed_at, false)?;
        transaction
            .lock_workspace(workspace_id, principal.user_id())
            .await?
            .authorize(&principal, true)?;
        let metadata = transaction
            .lock_invitation_metadata(workspace_id, invitation_id)
            .await?;
        let now = transaction.invitation_now().await?;
        locked
            .session
            .authorize(&locked.account, proof, now, false)?;
        if let RevokeDecision::Revoke { next_revision } = metadata.revoke(expected_revision, now)? {
            if transaction
                .revoke_invitation_row(workspace_id, invitation_id, metadata.revision, now)
                .await?
                != next_revision
            {
                return Err(ApplicationError::Unavailable);
            }
            transaction
                .append_audit(AuditRecord {
                    workspace_id: Some(workspace_id),
                    actor_user_id: Some(principal.user_id()),
                    session_id: Some(principal.session_id()),
                    detail: AuditDetail::InvitationRevoked {
                        invitation_id,
                        revision_before: metadata.revision,
                        revision_after: next_revision,
                    },
                    client_type: principal.client_type(),
                    correlation_id,
                })
                .await?;
        }
        transaction.commit().await
    }
}
