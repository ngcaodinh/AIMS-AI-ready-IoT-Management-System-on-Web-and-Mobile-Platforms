//! Preference chính chủ: authorization và CAS/audit cùng transaction, không cần workspace selector.

use crate::{
    error::ApplicationError,
    identity::IdentityService,
    ports::{IdentitySecurity, IdentityStore, IdentityTransaction},
};
use chrono::{DateTime, Utc};
use iot_domain::{
    audit_write::AuditDetail,
    identity::{AuditRecord, SessionProof},
    preferences::{DisplayTimezone, PreferenceFailure, PreferenceSnapshot},
};
use std::future::Future;
use uuid::Uuid;

pub trait PreferenceTransaction: IdentityTransaction {
    /// Khóa preference sau current User; thiếu row trả UTC/1 mà không INSERT khi GET.
    fn lock_preferences(
        &mut self,
        user_id: Uuid,
    ) -> impl Future<Output = Result<PreferenceSnapshot, ApplicationError>> + Send;
    /// Lấy clock mới sau preference lock để session hết hạn trong lúc chờ không được admit.
    fn preferences_now(
        &mut self,
    ) -> impl Future<Output = Result<DateTime<Utc>, ApplicationError>> + Send;
    /// Tra exact timezone trong catalog engine bằng parameter binding, không parse SQL time expression.
    fn preference_timezone_exists(
        &mut self,
        timezone: &str,
    ) -> impl Future<Output = Result<bool, ApplicationError>> + Send;
    /// Materialize UTC/1 nếu thiếu rồi CAS snapshot mới; caller rollback khi audit lỗi.
    fn save_preferences(
        &mut self,
        before: &PreferenceSnapshot,
        after: &PreferenceSnapshot,
        now: DateTime<Utc>,
    ) -> impl Future<Output = Result<(), ApplicationError>> + Send;
}

impl From<PreferenceFailure> for ApplicationError {
    /// Giữ lỗi CAS riêng với lỗi miền counter để transport không biến overflow thành thành công.
    fn from(failure: PreferenceFailure) -> Self {
        match failure {
            PreferenceFailure::StaleRevision => Self::StaleRevision,
            PreferenceFailure::RevisionExhausted => Self::Unavailable,
        }
    }
}

impl<S: IdentityStore, C: IdentitySecurity> IdentityService<S, C>
where
    S::Transaction: PreferenceTransaction,
{
    /**
     * Đọc preference của principal hiện hành, bao gồm default legacy không ghi ngầm khi GET.
     * Input
     * Param: proof — full session/context chính chủ, không nhận target userId để tránh account override.
     * Output: snapshot chỉ timezone/revision/identity sau read commit.
     * # Errors
     * Invalid/limited/expired/context mismatch hoặc storage/commit chưa rõ, không cấp quyền Admin global.
     */
    pub async fn get_preferences(
        &self,
        proof: &SessionProof,
    ) -> Result<PreferenceSnapshot, ApplicationError> {
        let mut transaction = self.store.begin().await?;
        let locked = transaction.lock_session(proof).await?;
        let principal =
            locked
                .session
                .authorize(&locked.account, proof, locked.observed_at, false)?;
        let snapshot = transaction.lock_preferences(principal.user_id()).await?;
        let now = transaction.preferences_now().await?;
        locked
            .session
            .authorize(&locked.account, proof, now, false)?;
        if snapshot.user_id != principal.user_id() {
            return Err(ApplicationError::Unavailable);
        }
        transaction.commit().await?;
        Ok(snapshot)
    }

    /**
     * Đổi timezone hiển thị bằng CAS chính chủ và required audit, không reschedule rule hoặc sửa instant.
     * Input
     * Param: proof — full session/context chính chủ được kiểm lại sau lock wait.
     * Param: timezone — exact name có shape hợp lệ, còn phải tra catalog qua port.
     * Param: `expected_revision` — If-Match preference đã đọc, không phải user/session revision.
     * Param: `correlation_id` — UUID audit liên kết, không raw timezone hoặc hồ sơ.
     * Output: snapshot mới sau commit; revision tăng kể cả cùng giá trị.
     * # Errors
     * Invalid timezone, stale CAS, current authority hoặc storage/unknown commit; lỗi audit rollback cả materialization.
     */
    pub async fn update_preferences(
        &self,
        proof: &SessionProof,
        timezone: &DisplayTimezone,
        expected_revision: i64,
        correlation_id: Uuid,
    ) -> Result<PreferenceSnapshot, ApplicationError> {
        let mut transaction = self.store.begin().await?;
        let locked = transaction.lock_session(proof).await?;
        let principal =
            locked
                .session
                .authorize(&locked.account, proof, locked.observed_at, false)?;
        let before = transaction.lock_preferences(principal.user_id()).await?;
        let now = transaction.preferences_now().await?;
        locked
            .session
            .authorize(&locked.account, proof, now, false)?;
        if before.user_id != principal.user_id() {
            return Err(ApplicationError::Unavailable);
        }
        let after = before.change(timezone, expected_revision)?;
        if !transaction
            .preference_timezone_exists(timezone.as_str())
            .await?
        {
            return Err(ApplicationError::TimezoneInvalid);
        }
        transaction.save_preferences(&before, &after, now).await?;
        transaction
            .append_audit(AuditRecord {
                workspace_id: None,
                actor_user_id: Some(principal.user_id()),
                session_id: Some(principal.session_id()),
                detail: AuditDetail::PreferencesChanged {
                    user_id: principal.user_id(),
                    revision_before: before.revision,
                    revision_after: after.revision,
                    timezone_changed: before.display_timezone != after.display_timezone,
                },
                client_type: principal.client_type(),
                correlation_id,
            })
            .await?;
        transaction.commit().await?;
        Ok(after)
    }
}
