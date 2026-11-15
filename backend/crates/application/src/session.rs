//! Use case thu hồi và thay credential: policy ở core, SQL/side-effect intent ở adapter transaction.

use crate::{
    error::ApplicationError,
    identity::IdentityService,
    ports::{IdentitySecurity, IdentityStore, IdentityTransaction, SessionMutationTransaction},
};
use iot_domain::audit_write::AuditDetail;
use iot_domain::{
    identity::{AuditRecord, LoginAdmission, SecretString, SessionProof, SessionRevocation},
    input::{validate_current_password, validate_new_password},
};
use uuid::Uuid;

impl<S: IdentityStore, C: IdentitySecurity> IdentityService<S, C>
where
    S::Transaction: SessionMutationTransaction,
{
    /**
     * Revoke đúng credential hiện tại, idempotent với revoked/expired session đã nhận diện.
     * Input
     * Param: proof — token digest/context từ transport; không nhận sessionId do body tự khai.
     * Param: `correlation_id` — identity request để audit; audit chỉ ghi một lần chuyển trạng thái.
     * Output: hoàn thành sau commit; durable outbox không tự chứng minh socket bên ngoài đã đóng.
     * # Errors
     * `SessionInvalid` với token unknown; `Conflict` khi context sai; lỗi storage không giả thành logout thành công.
     */
    pub async fn logout(
        &self,
        proof: &SessionProof,
        correlation_id: Uuid,
    ) -> Result<(), ApplicationError> {
        let mut transaction = self.store.begin().await?;
        let locked = transaction.lock_session(proof).await?;
        let principal = locked
            .session
            .authorize_revocation(&locked.account, proof)?;
        let changed = transaction
            .revoke_capabilities(
                SessionRevocation::Current {
                    user_id: principal.user_id(),
                    session_id: principal.session_id(),
                },
                locked.observed_at,
            )
            .await?;
        if changed > 0 {
            transaction
                .append_audit(AuditRecord {
                    workspace_id: None,
                    actor_user_id: Some(principal.user_id()),
                    session_id: Some(principal.session_id()),
                    detail: AuditDetail::Logout {
                        session_id: principal.session_id(),
                    },
                    client_type: principal.client_type(),
                    correlation_id,
                })
                .await?;
        }
        transaction.commit().await
    }

    /**
     * Xác minh password hiện hành dưới bucket→User fence rồi thay PHC/revoke mọi phiên/audit cùng commit.
     * Input
     * Param: proof — session chính chủ, limited được dùng cho phục hồi nhưng phải còn hiệu lực.
     * Param: `current_password` — credential nguyên bản1–128 cần verify và tính vào limiter khi sai.
     * Param: `new_password` — credential mới9–128 scalar có hoa/thường/số; không trim hoặc đưa raw value vào storage.
     * Param: `correlation_id` — identity audit không secret, không tự replay khi commit ACK unknown.
     * Output: hoàn thành sau commit; caller phải đăng nhập mới, không nâng limited session tại chỗ.
     * # Errors
     * Validation, invalid credentials, rate limit, revoked/context mismatch hoặc required-audit/storage failure.
     */
    pub async fn change_password(
        &self,
        proof: &SessionProof,
        current_password: String,
        new_password: String,
        correlation_id: Uuid,
    ) -> Result<(), ApplicationError> {
        validate_current_password(&current_password, "/currentPassword").map_err(
            // Giữ lỗi domain an toàn cho caller ngoài HTTP, không phản chiếu credential hiện tại.
            |_| ApplicationError::InvalidInput,
        )?;
        validate_new_password(&new_password, "/newPassword").map_err(
            // Chặn credential mới sai policy trước transaction, không đưa raw password vào lỗi.
            |_| ApplicationError::InvalidInput,
        )?;
        // Service vẫn giữ invariant khi được gọi ngoài HTTP; không chiếm transaction/hash cho giá trị không đổi.
        if current_password == new_password {
            return Err(ApplicationError::InvalidInput);
        }
        let mut transaction = self.store.begin().await?;
        let email = transaction.session_email(proof).await?;
        let digest = self.security.bucket_digest(&email)?;
        let (window, _) = transaction.lock_login_bucket(digest).await?;
        let locked = transaction.lock_session(proof).await?;
        let principal =
            locked
                .session
                .authorize(&locked.account, proof, locked.observed_at, true)?;
        // Kiểm email lại sau User fence để lookup cũ không chọn nhầm bucket nếu account email đổi.
        if transaction.session_email(proof).await? != email {
            return Err(ApplicationError::Conflict);
        }
        let next_failure = match window.admit(locked.observed_at) {
            LoginAdmission::Allowed { next_failure, .. } => next_failure,
            LoginAdmission::Limited {
                retry_after_seconds,
            } => {
                return Err(ApplicationError::RateLimited {
                    retry_after_seconds,
                });
            }
        };
        let matches = self
            .security
            .verify_password(
                SecretString::new(current_password),
                locked.account.password_verifier,
            )
            .await?;
        if !matches {
            transaction.save_login_window(digest, next_failure).await?;
            transaction.commit().await?;
            // Cùng quy tắc failed login: audit hỏng không được phục hồi failure budget đã commit.
            let failure_audit = self
                .store
                .record_failed_login(AuditRecord {
                    workspace_id: None,
                    actor_user_id: Some(principal.user_id()),
                    session_id: Some(principal.session_id()),
                    detail: AuditDetail::PasswordChangeFailed {
                        user_id: principal.user_id(),
                    },
                    client_type: principal.client_type(),
                    correlation_id,
                })
                .await;
            if failure_audit.is_err() {
                self.store.observe_failed_audit(
                    iot_domain::audit_write::FailureAuditKind::PasswordChange,
                );
            }
            return Err(ApplicationError::InvalidCredentials);
        }
        let verifier = self
            .security
            .hash_password(SecretString::new(new_password))
            .await?;
        /* Thu hồi đầy đủ capability trước khi UPDATE password: trigger DB cũng revoke session,
         * nếu để trigger chạy trước thì adapter mất danh sách chuyển trạng thái để tạo close intent.
         * Cả hai bước cùng unit of work nên password/audit lỗi vẫn rollback mọi revocation. */
        transaction
            .revoke_capabilities(
                SessionRevocation::AllForUser {
                    user_id: principal.user_id(),
                },
                locked.observed_at,
            )
            .await?;
        transaction
            .replace_password(principal.user_id(), &verifier, locked.observed_at)
            .await?;
        transaction
            .append_audit(AuditRecord {
                workspace_id: None,
                actor_user_id: Some(principal.user_id()),
                session_id: Some(principal.session_id()),
                detail: AuditDetail::PasswordChanged {
                    user_id: principal.user_id(),
                },
                client_type: principal.client_type(),
                correlation_id,
            })
            .await?;
        transaction.commit().await
    }
}
