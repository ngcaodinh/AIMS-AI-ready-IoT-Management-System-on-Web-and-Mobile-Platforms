//! Reset tạm thuộc quyền workspace Admin; credential global được bảo vệ bằng domain policy và User fences.

use crate::{
    error::ApplicationError,
    identity::IdentityService,
    ports::{
        IdentitySecurity, IdentityStore, IdentityTransaction, SessionMutationTransaction,
        WorkspaceTransaction,
    },
};
use chrono::{DateTime, Utc};
use iot_domain::audit_write::AuditDetail;
use iot_domain::{
    identity::{AuditRecord, SecretString, SessionProof, SessionRevocation},
    password_reset::{PasswordResetFailure, PasswordResetTarget, admit_reset},
};
use std::future::Future;
use uuid::Uuid;

/// Kết quả chỉ phát một lần sau commit, không lưu plaintext password vào receipt hoặc audit.
pub struct ResetPasswordResult {
    pub temporary_password: SecretString,
    pub membership_revision: i64,
}

/// Port reset giữ current authorization, revocation, ledger và audit trong cùng transaction vật lý.
pub trait PasswordResetTransaction: SessionMutationTransaction + WorkspaceTransaction {
    /// Khóa actor/target theo UUID tăng dần trước Workspace; chưa cấp authority từ session hint.
    fn lock_reset_subjects(
        &mut self,
        proof: &SessionProof,
        target_id: Uuid,
    ) -> impl Future<Output = Result<(), ApplicationError>> + Send;
    /// Đọc target/origin/activation/membership scopes dưới User+Workspace fences; không trả PHC.
    fn password_reset_target(
        &mut self,
        workspace_id: Uuid,
        target_id: Uuid,
    ) -> impl Future<Output = Result<PasswordResetTarget, ApplicationError>> + Send;
    /// Trả clock statement mới sau khóa, không dùng thời điểm BEGIN cho expiry/rate admission.
    fn password_reset_now(
        &mut self,
    ) -> impl Future<Output = Result<DateTime<Utc>, ApplicationError>> + Send;
    /// Đọc tối đa5 admission đúng workspace/actor/target trong15 phút để policy kiểm sliding quota.
    fn recent_password_resets(
        &mut self,
        workspace_id: Uuid,
        actor_id: Uuid,
        target_id: Uuid,
        now: DateTime<Utc>,
    ) -> impl Future<Output = Result<Vec<DateTime<Utc>>, ApplicationError>> + Send;
    /// Thay PHC và tăng membership revision bằng CAS; giữ origin/activation và must-change=true.
    fn replace_temporary_password(
        &mut self,
        workspace_id: Uuid,
        target_id: Uuid,
        expected_revision: i64,
        verifier: &SecretString,
    ) -> impl Future<Output = Result<i64, ApplicationError>> + Send;
    /// Ghi successful admission trong cùng transaction; failed/reset rollback không chiếm quota.
    fn record_password_reset(
        &mut self,
        workspace_id: Uuid,
        actor_id: Uuid,
        target_id: Uuid,
        now: DateTime<Utc>,
    ) -> impl Future<Output = Result<(), ApplicationError>> + Send;
}

impl From<PasswordResetFailure> for ApplicationError {
    /// Ánh xạ lỗi policy reset sang application, giữ protected/CAS/quota khác storage failure.
    fn from(failure: PasswordResetFailure) -> Self {
        match failure {
            PasswordResetFailure::GlobalAccountProtected => Self::GlobalAccountProtected,
            PasswordResetFailure::StaleRevision => Self::StaleRevision,
            PasswordResetFailure::Forbidden => Self::Forbidden,
            PasswordResetFailure::RateLimited {
                retry_after_seconds,
            } => Self::RateLimited {
                retry_after_seconds,
            },
        }
    }
}

impl<S: IdentityStore, C: IdentitySecurity> IdentityService<S, C>
where
    S::Transaction: PasswordResetTransaction,
{
    /**
     * Reset account tạm đủ điều kiện, buộc đổi password và revoke capability atomically trước phát secret.
     * Input
     * Param: proof — full session/context Admin phải còn quyền trong workspace hiện hành.
     * Param: `workspace_id` — tenant selector chưa được tin trước admission.
     * Param: `target_id` — account thành viên cần reset; không nhận global status từ body.
     * Param: `expected_revision` — If-Match của membership, tăng sau reset để chặn concurrent intent cũ.
     * Param: `correlation_id` — identity audit không chứa credential/email.
     * Output: password tạm CSPRNG và revision mới sau commit.
     * # Errors
     * Protected account, stale revision, quota/current authority hoặc storage/unknown commit; không trả secret khi lỗi.
     */
    pub async fn reset_temporary_password(
        &self,
        proof: &SessionProof,
        workspace_id: Uuid,
        target_id: Uuid,
        expected_revision: i64,
        correlation_id: Uuid,
    ) -> Result<ResetPasswordResult, ApplicationError> {
        if expected_revision <= 0 {
            return Err(ApplicationError::InvalidInput);
        }
        let mut transaction = self.store.begin().await?;
        transaction.lock_reset_subjects(proof, target_id).await?;
        let locked = transaction.lock_session(proof).await?;
        let principal =
            locked
                .session
                .authorize(&locked.account, proof, locked.observed_at, false)?;
        transaction
            .lock_workspace(workspace_id, principal.user_id())
            .await?
            .authorize(&principal, true)?;
        let target = transaction
            .password_reset_target(workspace_id, target_id)
            .await?;
        target.authorize(workspace_id, expected_revision)?;
        let now = transaction.password_reset_now().await?;
        locked
            .session
            .authorize(&locked.account, proof, now, false)?;
        let recent = transaction
            .recent_password_resets(workspace_id, principal.user_id(), target_id, now)
            .await?;
        admit_reset(&recent, now)?;
        // Reset cũng tạo password đạt9–128/hoa/thường/số, tách khỏi chính sách capability phiên.
        let temporary_password = self.security.issue_temporary_password()?;
        let verifier = self
            .security
            .hash_password(SecretString::new(temporary_password.expose().to_owned()))
            .await?;
        // Hasher có thể xếp hàng; expiry phải kiểm lại sau hash trước khi bắt đầu mutation.
        let now = transaction.password_reset_now().await?;
        locked
            .session
            .authorize(&locked.account, proof, now, false)?;
        transaction
            .revoke_capabilities(SessionRevocation::AllForUser { user_id: target_id }, now)
            .await?;
        let membership_revision = transaction
            .replace_temporary_password(workspace_id, target_id, expected_revision, &verifier)
            .await?;
        transaction
            .record_password_reset(workspace_id, principal.user_id(), target_id, now)
            .await?;
        transaction
            .append_audit(AuditRecord {
                workspace_id: Some(workspace_id),
                actor_user_id: Some(principal.user_id()),
                session_id: Some(principal.session_id()),
                detail: AuditDetail::MembershipResetAdmitted {
                    user_id: target_id,
                    revision_before: expected_revision,
                    revision_after: membership_revision,
                },
                client_type: principal.client_type(),
                correlation_id,
            })
            .await?;
        // Credential evidence toàn account chỉ nằm global; local audit phía trên không chứa secret hoặc session list.
        transaction
            .append_audit(AuditRecord {
                workspace_id: None,
                actor_user_id: Some(principal.user_id()),
                session_id: Some(principal.session_id()),
                detail: AuditDetail::TemporaryPasswordReset { user_id: target_id },
                client_type: principal.client_type(),
                correlation_id,
            })
            .await?;
        transaction.commit().await?;
        Ok(ResetPasswordResult {
            temporary_password,
            membership_revision,
        })
    }
}
