//! Orchestration lời mời: current authority trước replay; raw capability chỉ phát một lần sau commit.

use crate::{
    error::ApplicationError,
    identity::IdentityService,
    invitation_ports::{
        InvitationClaim, InvitationReceipt, InvitationReceiptScope, InvitationTransaction,
    },
    ports::{IdentitySecurity, IdentityStore, IdentityTransaction, WorkspaceTransaction},
};
use chrono::Duration;
use iot_domain::audit_write::AuditDetail;
use iot_domain::{
    idempotency::IdempotencyKey,
    identity::{AuditRecord, SessionProof},
    input::normalize_email,
    invitation::{
        InvitationFailure, InvitationSnapshot, IssuedInvitation, invitation_request_bytes,
    },
    workspace::WorkspaceRole,
};
use uuid::Uuid;

impl<S: IdentityStore, C: IdentitySecurity> IdentityService<S, C>
where
    S::Transaction: InvitationTransaction,
{
    /**
     * Tạo lời mời email-bound24h và receipt cùng audit; không gửi email tự động.
     * Input
     * Param: proof — full session của Admin hiện hành; context Web phải khớp.
     * Param: `workspace_id` — selector cần kiểm quyền, không tự cấp authority.
     * Param: email — người nhận được chuẩn hóa theo cùng policy đăng nhập.
     * Param: role — role workspace hữu hạn dự định cấp khi accept.
     * Param: key — intent key bắt buộc; replay cùng body chỉ trả metadata.
     * Param: `correlation_id` — định danh audit không secret.
     * Output: lời mời sau commit; token None khi replay, lỗi không tiết lộ credential.
     * # Errors
     * Validation, current authority, conflict hoặc storage đã lọc; commit chưa rõ không trả token.
     */
    pub async fn create_invitation(
        &self,
        proof: &SessionProof,
        workspace_id: Uuid,
        email: &str,
        role: WorkspaceRole,
        key: &IdempotencyKey,
        correlation_id: Uuid,
    ) -> Result<IssuedInvitation, ApplicationError> {
        let email_normalized =
            normalize_email(email).map_err(|_| ApplicationError::InvalidInput)?;
        let mut transaction = self.store.begin().await?;
        let locked = transaction.lock_session(proof).await?;
        let principal =
            locked
                .session
                .authorize(&locked.account, proof, locked.observed_at, false)?;
        let admission = transaction
            .lock_workspace(workspace_id, principal.user_id())
            .await?
            .authorize(&principal, true)?;
        let now = transaction.invitation_now().await?;
        locked
            .session
            .authorize(&locked.account, proof, now, false)?;
        let key_digest = self.security.token_digest(key.expose());
        let request_digest = self
            .security
            .request_digest(&invitation_request_bytes(email, role));
        let scope = InvitationReceiptScope::Create(workspace_id);
        match transaction
            .reserve_invitation_receipt(scope, principal.user_id(), key_digest, request_digest, now)
            .await?
        {
            InvitationClaim::Reserved => {}
            InvitationClaim::Existing {
                request_digest: stored,
                result,
            } => {
                if stored != request_digest {
                    return Err(ApplicationError::Conflict);
                }
                let result = result.ok_or(ApplicationError::Conflict)?;
                if result.workspace_id != workspace_id {
                    return Err(ApplicationError::Unavailable);
                }
                let metadata = transaction
                    .invitation_metadata(workspace_id, result.invitation_id)
                    .await?;
                transaction.commit().await?;
                return Ok(metadata.issued(None));
            }
        }
        let email_digest = self.security.bucket_digest(&email_normalized)?;
        let generation = transaction
            .prepare_invitation(workspace_id, &email_normalized, email_digest, now)
            .await?;
        let (token, token_digest) = self.security.issue_token();
        let invitation = InvitationSnapshot {
            workspace_id,
            invitation_id: Uuid::new_v4(),
            email_normalized,
            role,
            issuer_user_id: principal.user_id(),
            issuer_grant_generation: admission.grant_generation,
            issuer_authorization_version: admission.membership_authorization_version,
            admission_generation: generation,
            issued_at: now,
            expires_at: now + Duration::hours(24),
            terminal: false,
        };
        transaction
            .insert_invitation(&invitation, email_digest, token_digest)
            .await?;
        transaction
            .append_audit(AuditRecord {
                workspace_id: Some(workspace_id),
                actor_user_id: Some(principal.user_id()),
                session_id: Some(principal.session_id()),
                detail: AuditDetail::InvitationCreated {
                    invitation_id: invitation.invitation_id,
                    role,
                },
                client_type: principal.client_type(),
                correlation_id,
            })
            .await?;
        transaction
            .complete_invitation_receipt(
                scope,
                principal.user_id(),
                key_digest,
                &InvitationReceipt {
                    workspace_id,
                    invitation_id: invitation.invitation_id,
                    grant_generation: None,
                },
            )
            .await?;
        transaction.commit().await?;
        Ok(invitation.issued(Some(token)))
    }

    /**
     * Consume lời mời bằng account đúng email, tạo grant mới và audit trong cùng commit.
     * Input
     * Param: proof — full session của người nhận; không chấp nhận account tạm chưa đổi password.
     * Param: token — capability256bit chỉ được hash trước lookup, không ghi log/receipt.
     * Param: key — key bắt buộc cho retry accept; replay cần đúng grant hiện hành.
     * Param: `correlation_id` — định danh liên kết audit, không mang email/token.
     * Output: workspace đã tham gia; recipient mismatch/unavailable/conflict hoặc lỗi storage an toàn.
     * # Errors
     * Recipient mismatch, unavailable, current authority, conflict hoặc lỗi storage đã lọc.
     */
    pub async fn accept_invitation(
        &self,
        proof: &SessionProof,
        token: &str,
        key: &IdempotencyKey,
        correlation_id: Uuid,
    ) -> Result<Uuid, ApplicationError> {
        if token.len() != 64 || !token.bytes().all(|byte| byte.is_ascii_hexdigit()) {
            return Err(ApplicationError::InvitationUnavailable);
        }
        let digest = self.security.token_digest(token);
        let mut transaction = self.store.begin().await?;
        let (workspace_id, issuer_id) = transaction
            .invitation_hint(digest)
            .await?
            .ok_or(ApplicationError::InvitationUnavailable)?;
        // Hint chỉ chọn khóa: cả session lẫn invitation được đọc lại, không cấp quyền từ lookup trước khóa.
        transaction.lock_invitation_users(proof, issuer_id).await?;
        let locked = transaction.lock_session(proof).await?;
        let context = transaction
            .lock_invitation(digest, locked.account.user_id)
            .await?;
        let principal =
            locked
                .session
                .authorize(&locked.account, proof, context.observed_at, false)?;
        let key_digest = self.security.token_digest(key.expose());
        let scope = InvitationReceiptScope::Accept;
        match transaction
            .reserve_invitation_receipt(
                scope,
                principal.user_id(),
                key_digest,
                digest,
                context.observed_at,
            )
            .await?
        {
            InvitationClaim::Reserved => {}
            InvitationClaim::Existing {
                request_digest,
                result,
            } => {
                if request_digest != digest {
                    return Err(ApplicationError::Conflict);
                }
                let result = result.ok_or(ApplicationError::Conflict)?;
                if result.workspace_id != workspace_id
                    || result.invitation_id != context.snapshot.invitation_id
                {
                    return Err(ApplicationError::Unavailable);
                }
                let admission = transaction
                    .lock_workspace(workspace_id, principal.user_id())
                    .await?
                    .authorize(&principal, false)?;
                if Some(admission.grant_generation) != result.grant_generation {
                    return Err(ApplicationError::Forbidden);
                }
                return transaction.commit().await.map(|()| workspace_id);
            }
        }
        context
            .snapshot
            .authorize_recipient(
                &context.recipient_email,
                context.observed_at,
                context.admission_generation,
                &context.issuer,
            )
            .map_err(|failure| match failure {
                InvitationFailure::RecipientMismatch => {
                    ApplicationError::InvitationRecipientMismatch
                }
                InvitationFailure::Unavailable => ApplicationError::InvitationUnavailable,
            })?;
        let generation = transaction
            .consume_invitation(&context.snapshot, principal.user_id(), context.observed_at)
            .await?;
        transaction
            .append_audit(AuditRecord {
                workspace_id: Some(workspace_id),
                actor_user_id: Some(principal.user_id()),
                session_id: Some(principal.session_id()),
                detail: AuditDetail::InvitationAccepted {
                    invitation_id: context.snapshot.invitation_id,
                    grant_generation: generation,
                },
                client_type: principal.client_type(),
                correlation_id,
            })
            .await?;
        transaction
            .complete_invitation_receipt(
                scope,
                principal.user_id(),
                key_digest,
                &InvitationReceipt {
                    workspace_id,
                    invitation_id: context.snapshot.invitation_id,
                    grant_generation: Some(generation),
                },
            )
            .await?;
        transaction.commit().await?;
        Ok(workspace_id)
    }
}
