//! Tạo account mới hoặc invitation theo email; không tự join account đã tồn tại.

use crate::{
    error::ApplicationError,
    identity::IdentityService,
    invitation_ports::InvitationTransaction,
    member_creation_ports::{
        MemberCreationClaim, MemberCreationReceiptKey, MemberCreationTransaction,
    },
    ports::{IdentitySecurity, IdentityStore, IdentityTransaction, WorkspaceTransaction},
};
use chrono::{DateTime, Duration, Utc};
use iot_domain::{
    audit_write::AuditDetail,
    idempotency::IdempotencyKey,
    identity::{AuditRecord, Principal, SecretString, SessionProof},
    invitation::InvitationSnapshot,
    member_creation::{IssuedMemberCreation, MemberCreationOutcome, MemberCreationRequest},
    workspace::WorkspaceAdmission,
};
use uuid::Uuid;

/// Authority/clock đã khóa dùng chung khi issue invitation qua tiện ích tạo member.
struct CreationContext<'a> {
    principal: &'a Principal,
    admission: &'a WorkspaceAdmission,
    now: DateTime<Utc>,
    correlation_id: Uuid,
}

impl<S: IdentityStore, C: IdentitySecurity> IdentityService<S, C>
where
    S::Transaction: MemberCreationTransaction,
{
    /**
     * Tạo member cho email mới hoặc lời mời24h cho account đã có, bảo vệ profile global.
     * Input
     * Param: proof — full session/context cần kiểm current Admin dưới lock.
     * Param: `workspace_id` — selector tenant phải ACTIVE, không tự cấp quyền.
     * Param: request — email/displayName/role đã validate, alias chỉ áp cho member mới.
     * Param: key — intent ổn định; retry khác body bị Conflict và không phát lại secret.
     * Param: `correlation_id` — UUID audit không mang nội dung riêng.
     * Output: outcome và secret một lần chỉ sau commit; replay chỉ metadata.
     * # Errors
     * Current authority, conflict/storage hoặc `CommitUnknown`; không trả credential trước commit chắc chắn.
     */
    pub async fn create_member(
        &self,
        proof: &SessionProof,
        workspace_id: Uuid,
        request: &MemberCreationRequest,
        key: &IdempotencyKey,
        correlation_id: Uuid,
    ) -> Result<IssuedMemberCreation, ApplicationError> {
        self.authorize_member_creation(proof, workspace_id).await?;
        // Preflight đã đóng: request không có quyền không chiếm Argon2; hash vẫn ngoài mutation transaction.
        let (password, _) = self.security.issue_token();
        let verifier = self
            .security
            .hash_password(SecretString::new(password.expose().to_owned()))
            .await?;
        let email_digest = self.security.bucket_digest(request.email_normalized())?;
        let mut transaction = self.store.begin().await?;
        transaction.lock_creation_email(email_digest).await?;
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
        let receipt = MemberCreationReceiptKey {
            workspace_id,
            actor_id: principal.user_id(),
            key_digest: self.security.token_digest(key.expose()),
        };
        match transaction
            .reserve_member_creation(
                receipt,
                self.security.request_digest(&request.request_bytes()),
                now,
            )
            .await?
        {
            MemberCreationClaim::Reserved => {}
            MemberCreationClaim::Existing {
                request_digest,
                outcome,
            } => {
                if request_digest != self.security.request_digest(&request.request_bytes()) {
                    return Err(ApplicationError::Conflict);
                }
                let outcome = outcome.ok_or(ApplicationError::Conflict)?;
                transaction.commit().await?;
                return Ok(IssuedMemberCreation {
                    workspace_id,
                    outcome,
                    secret: None,
                });
            }
        }
        let (outcome, secret) = if transaction
            .creation_account_exists(request.email_normalized())
            .await?
        {
            self.create_member_invitation(
                &mut transaction,
                request,
                email_digest,
                &CreationContext {
                    principal: &principal,
                    admission: &admission,
                    now,
                    correlation_id,
                },
            )
            .await?
        } else {
            let user_id = Uuid::new_v4();
            transaction
                .insert_temporary_member(workspace_id, user_id, request, &verifier, now)
                .await?;
            Self::audit_created_member(
                &mut transaction,
                &CreationContext {
                    principal: &principal,
                    admission: &admission,
                    now,
                    correlation_id,
                },
                user_id,
                request.role(),
            )
            .await?;
            (MemberCreationOutcome::Created { user_id }, password)
        };
        transaction
            .complete_member_creation(receipt, &outcome)
            .await?;
        transaction.commit().await?;
        Ok(IssuedMemberCreation {
            workspace_id,
            outcome,
            secret: Some(secret),
        })
    }

    /**
     * Kiểm quyền trước chi phí Argon2 nhưng không giữ transaction trong lúc chờ CPU.
     * Input
     * Param: proof — session/context phải full và còn hiệu lực sau mọi lock wait.
     * Param: `workspace_id` — tenant cần current Admin và trạng thái ACTIVE.
     * Output: đóng read transaction thành công; không cấp admission có thể tái dùng để ghi.
     * # Errors
     * Session/limited/foreign/USER bị từ chối trước hash; caller vẫn phải reauthorize ở final fences.
     */
    async fn authorize_member_creation(
        &self,
        proof: &SessionProof,
        workspace_id: Uuid,
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
        let now = transaction.invitation_now().await?;
        locked
            .session
            .authorize(&locked.account, proof, now, false)?;
        transaction.commit().await
    }

    /**
     * Tạo invitation cho account đã có mà không sửa credential, alias hoặc autojoin.
     * Input
     * Param: transaction — unit of work đang giữ email/User/Workspace fences và receipt.
     * Param: request — email/role đích; displayName không áp lên account cũ.
     * Param: `email_digest` — HMAC cùng email đã khóa để chọn admission fence.
     * Param: context — principal/current admission và clock lấy sau khóa.
     * Output: outcome/token chưa phát ra ngoài; caller phải complete receipt và commit trước response.
     * # Errors
     * Conflict khi member/pending invite còn tồn tại hoặc lỗi required audit/storage.
     */
    async fn create_member_invitation(
        &self,
        transaction: &mut S::Transaction,
        request: &MemberCreationRequest,
        email_digest: [u8; 32],
        context: &CreationContext<'_>,
    ) -> Result<(MemberCreationOutcome, SecretString), ApplicationError> {
        let generation = transaction
            .prepare_invitation(
                context.admission.workspace_id,
                request.email_normalized(),
                email_digest,
                context.now,
            )
            .await?;
        let (token, token_digest) = self.security.issue_token();
        let invitation = InvitationSnapshot {
            workspace_id: context.admission.workspace_id,
            invitation_id: Uuid::new_v4(),
            email_normalized: request.email_normalized().to_owned(),
            role: request.role(),
            issuer_user_id: context.principal.user_id(),
            issuer_grant_generation: context.admission.grant_generation,
            issuer_authorization_version: context.admission.membership_authorization_version,
            admission_generation: generation,
            issued_at: context.now,
            expires_at: context.now + Duration::hours(24),
            terminal: false,
        };
        transaction
            .insert_invitation(&invitation, email_digest, token_digest)
            .await?;
        transaction
            .append_audit(AuditRecord {
                workspace_id: Some(context.admission.workspace_id),
                actor_user_id: Some(context.principal.user_id()),
                session_id: Some(context.principal.session_id()),
                detail: AuditDetail::InvitationCreated {
                    invitation_id: invitation.invitation_id,
                    role: request.role(),
                },
                client_type: context.principal.client_type(),
                correlation_id: context.correlation_id,
            })
            .await?;
        Ok((
            MemberCreationOutcome::Invitation {
                invitation_id: invitation.invitation_id,
                expires_at: invitation.expires_at,
            },
            token,
        ))
    }
    /**
     * Tách credential evidence global với admission tenant để Admin không đọc sự kiện credential qua workspace.
     * Input
     * Param: transaction — cùng unit of work vừa insert account/member/grant.
     * Param: context — current actor/admission/correlation đã authorize.
     * Param: `user_id` — identity account mới, không raw email hoặc password.
     * Param: role — quyền workspace vừa cấp, không authority global.
     * Output: hai audit cùng transaction; lỗi bất kỳ làm caller rollback toàn graph.
     */
    async fn audit_created_member(
        transaction: &mut S::Transaction,
        context: &CreationContext<'_>,
        user_id: Uuid,
        role: iot_domain::workspace::WorkspaceRole,
    ) -> Result<(), ApplicationError> {
        // Global credential evidence không được lộ qua tenant audit; admission tenant không có credential metadata.
        for (scope, detail) in [
            (None, AuditDetail::TemporaryAccountCreated { user_id }),
            (
                Some(context.admission.workspace_id),
                AuditDetail::MembershipCreated { user_id, role },
            ),
        ] {
            transaction
                .append_audit(AuditRecord {
                    workspace_id: scope,
                    actor_user_id: Some(context.principal.user_id()),
                    session_id: Some(context.principal.session_id()),
                    detail,
                    client_type: context.principal.client_type(),
                    correlation_id: context.correlation_id,
                })
                .await?;
        }
        Ok(())
    }
}
