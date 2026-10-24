//! Orchestration IAM: application quyết định policy và commit; storage/crypto đi qua port.

use crate::{
    error::ApplicationError,
    ports::{IdentitySecurity, IdentityStore, IdentityTransaction},
};
use chrono::TimeDelta;
use iot_domain::audit_write::AuditDetail;
use iot_domain::{
    identity::{
        AccountStatus, AuditRecord, ClientType, IssuedSession, LoginAdmission, LoginWindow,
        NewSession, SecretString, SessionProof,
    },
    input::{normalize_email, validate_password},
};
use uuid::Uuid;

/// Use case không biết PostgreSQL/SQLx/Tokio; hai adapter được nối tại composition root.
#[derive(Clone)]
pub struct IdentityService<S, C> {
    pub(crate) store: S,
    pub(crate) security: C,
}

impl<S: IdentityStore, C: IdentitySecurity> IdentityService<S, C> {
    /**
     * Nhận các port đã khởi tạo thay vì tự mở DB hoặc tự chọn implementation crypto.
     * Input
     * Param: store — factory atomic unit of work và failure-audit writer.
     * Param: security — adapter hashing/capability/limiter key dùng chung giữa các instance.
     * Output: use case có thể kiểm bằng port giả hoặc adapter thật mà không đổi business rule.
     */
    pub fn new(store: S, security: C) -> Self {
        Self { store, security }
    }

    /**
     * Chuyển token transport thành proof chưa xác thực; không dùng như authority trước resolver.
     * Input
     * Param: token — cookie/bearer đã tách tại transport boundary.
     * Param: `expected_context` — context Web đã chấp nhận; App dùng None.
     * Output: digest/context để storage khóa snapshot và domain kiểm lại quyền.
     */
    pub fn session_proof(&self, token: &str, expected_context: Option<Uuid>) -> SessionProof {
        SessionProof {
            token_digest: self.security.token_digest(token),
            expected_context,
        }
    }

    /**
     * Đăng nhập theo policy domain dưới bucket→User fence; chỉ trả secret sau session+audit commit.
     * Input
     * Param: email — địa chỉ chưa tin cậy cần normalize ASCII theo contract.
     * Param: password — chuỗi nguyên bản; không trim, không thay Unicode.
     * Param: `client_type` — metadata transport; không cấp role/workspace từ client.
     * Param: `correlation_id` — identity request không secret cho audit/đối soát.
     * Output: credential sau commit; Errors: validation, invalid credentials, rate limit hoặc storage.
     * # Errors
     * Trả lỗi từ chối hoặc lỗi đã mô tả ở trên; không chứa dữ liệu nhạy cảm.
     */
    pub async fn login(
        &self,
        email: &str,
        password: String,
        client_type: ClientType,
        correlation_id: Uuid,
    ) -> Result<IssuedSession, ApplicationError> {
        let email = normalize_email(email).map_err(|_| ApplicationError::InvalidInput)?;
        validate_password(&password, "/password").map_err(|_| ApplicationError::InvalidInput)?;
        let digest = self.security.bucket_digest(&email)?;
        let mut transaction = self.store.begin().await?;
        let (window, now) = transaction.lock_login_bucket(digest).await?;
        let (next_failure, expired) = match window.admit(now) {
            LoginAdmission::Allowed {
                next_failure,
                expired,
            } => (next_failure, expired),
            LoginAdmission::Limited {
                retry_after_seconds,
            } => {
                return Err(ApplicationError::RateLimited {
                    retry_after_seconds,
                });
            }
        };
        let account = transaction.lock_account(&email).await?;
        let verifier = account.as_ref().map_or_else(
            || self.security.dummy_verifier(),
            |account| SecretString::new(account.password_verifier.expose().to_owned()),
        );
        let matches = self
            .security
            .verify_password(SecretString::new(password), verifier)
            .await?;
        let active = account
            .as_ref()
            .is_some_and(|account| account.status == AccountStatus::Active);
        if !matches || !active {
            transaction.save_login_window(digest, next_failure).await?;
            // Limiter commit trước failure audit: audit unavailable không được mở lại ngân sách brute force.
            transaction.commit().await?;
            let failure_audit = self
                .store
                .record_failed_login(AuditRecord {
                    workspace_id: None,
                    // Lookup email chưa xác thực chủ account; không ghi người bị đoán password thành actor đã đăng nhập.
                    actor_user_id: None,
                    session_id: None,
                    detail: AuditDetail::LoginFailed,
                    client_type,
                    correlation_id,
                })
                .await;
            if failure_audit.is_err() {
                self.store
                    .observe_failed_audit(iot_domain::audit_write::FailureAuditKind::Login);
            }
            return Err(ApplicationError::InvalidCredentials);
        }
        let account = account.ok_or(ApplicationError::Unavailable)?;
        let (token, token_digest) = self.security.issue_token();
        let session = NewSession {
            session_id: Uuid::new_v4(),
            user_id: account.user_id,
            token_digest,
            auth_context_id: Uuid::new_v4(),
            limited: account.must_change_password,
            client_type,
            issued_at: now,
            expires_at: now + TimeDelta::hours(24),
        };
        transaction.insert_session(&session).await?;
        // Success không reset failure còn hiệu lực; chỉ dọn khi fixed-window đã thực sự hết hạn.
        if expired {
            transaction
                .save_login_window(
                    digest,
                    LoginWindow {
                        failures: 0,
                        started_at: None,
                    },
                )
                .await?;
        }
        transaction
            .append_audit(AuditRecord {
                workspace_id: None,
                actor_user_id: Some(account.user_id),
                session_id: Some(session.session_id),
                detail: AuditDetail::LoginSucceeded {
                    session_id: session.session_id,
                    limited: session.limited,
                },
                client_type,
                correlation_id,
            })
            .await?;
        transaction.commit().await?;
        Ok(IssuedSession {
            token,
            session_id: session.session_id,
            user_id: session.user_id,
            auth_context_id: session.auth_context_id,
            limited: session.limited,
            expires_at: session.expires_at,
        })
    }
}
