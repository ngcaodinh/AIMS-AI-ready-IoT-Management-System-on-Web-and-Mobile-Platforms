//! Use case audit yêu cầu current Admin, không dùng resource snapshot hoặc picker cũ làm quyền.

use crate::{
    error::ApplicationError,
    identity::IdentityService,
    ports::{
        AuditReadTransaction, IdentitySecurity, IdentityStore, IdentityTransaction,
        WorkspaceTransaction,
    },
};
use chrono::TimeDelta;
use iot_domain::{
    audit::{AuditCursor, AuditEntry},
    identity::SessionProof,
};
use uuid::Uuid;

impl<S: IdentityStore, C: IdentitySecurity> IdentityService<S, C>
where
    S::Transaction: AuditReadTransaction,
{
    /**
     * Đọc lịch sử tenant khi principal vẫn là Admin hiện hành, với cutoff30 ngày không chờ purge.
     * Input
     * Param: proof — credential/context phải qua current session policy.
     * Param: `workspace_id` — selector chưa tin cậy, phải có ACTIVE ADMIN membership/current grant.
     * Param: before — tuple cuối trang trước; HTTP adapter phải xác minh chữ ký và scope cursor.
     * Param: limit — số hàng1–100, không cho unlimited hoặc đọc global auth audit.
     * Output: projection audit allowlist thuộc đúng tenant, không chứa diff/raw payload.
     * # Errors
     * Validation, session/context/limited failure, forbidden hoặc storage error đã lọc.
     */
    pub async fn list_audit(
        &self,
        proof: &SessionProof,
        workspace_id: Uuid,
        before: Option<&AuditCursor>,
        limit: i64,
    ) -> Result<Vec<AuditEntry>, ApplicationError> {
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
            .authorize_audit(&principal)?;
        let now = transaction.audit_now().await?;
        locked
            .session
            .authorize(&locked.account, proof, now, false)?;
        // Logical retention áp trong read dù purge chậm; scope/cutoff/cursor đều được adapter bind.
        let entries = transaction
            .list_audit(workspace_id, now - TimeDelta::days(30), before, limit)
            .await?;
        transaction.commit().await?;
        Ok(entries)
    }
}
