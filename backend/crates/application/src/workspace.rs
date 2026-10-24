//! Workspace use case giữ session authorization và mutation trong cùng unit of work.

use crate::{
    error::ApplicationError,
    identity::IdentityService,
    ports::{
        IdentitySecurity, IdentityStore, IdentityTransaction, WorkspaceCreationClaim,
        WorkspaceCreationTransaction, WorkspaceTransaction,
    },
};
use iot_domain::audit_write::AuditDetail;
use iot_domain::{
    idempotency::{IdempotencyKey, workspace_request_bytes},
    identity::{AuditRecord, SessionProof},
    workspace::{WorkspaceAdmission, WorkspaceDraft, WorkspaceSummary},
};
use uuid::Uuid;

impl<S: IdentityStore, C: IdentitySecurity> IdentityService<S, C>
where
    S::Transaction: WorkspaceTransaction,
{
    /**
     * Tạo aggregate workspace với Admin/grant và audit cùng commit; role không lấy từ request.
     * Input
     * Param: proof — session hiện hành cần resolver và domain policy kiểm lại.
     * Param: name — tên workspace1–100 scalar sau trim.
     * Param: description — mô tả tùy chọn tối đa500 scalar.
     * Param: timezone — tên timezone cần catalog adapter kiểm tồn tại.
     * Param: key — intent key ổn định của client, chỉ digest vào receipt; retry phải dùng lại cùng key/body.
     * Param: `correlation_id` — định danh audit không secret.
     * Output: UUID sau commit hoặc lỗi validation/quota/quyền/storage.
     * # Errors
     * Trả lỗi từ chối hoặc lỗi đã mô tả ở trên; không chứa dữ liệu nhạy cảm.
     */
    pub async fn create_workspace(
        &self,
        proof: &SessionProof,
        name: &str,
        description: Option<&str>,
        timezone: &str,
        key: &IdempotencyKey,
        correlation_id: Uuid,
    ) -> Result<Uuid, ApplicationError>
    where
        S::Transaction: WorkspaceCreationTransaction,
    {
        let draft = WorkspaceDraft::new(name, description, timezone)
            .ok_or(ApplicationError::InvalidInput)?;
        let mut transaction = self.store.begin().await?;
        let locked = transaction.lock_session(proof).await?;
        let principal =
            locked
                .session
                .authorize(&locked.account, proof, locked.observed_at, false)?;
        let key_digest = self.security.token_digest(key.expose());
        let request_digest =
            self.security
                .request_digest(&workspace_request_bytes(name, description, timezone));
        match transaction
            .reserve_workspace_creation(
                principal.user_id(),
                key_digest,
                request_digest,
                locked.observed_at,
            )
            .await?
        {
            WorkspaceCreationClaim::Reserved => {}
            WorkspaceCreationClaim::Existing {
                request_digest: stored,
                workspace_id,
            } => {
                if stored != request_digest {
                    return Err(ApplicationError::Conflict);
                }
                let workspace_id = workspace_id.ok_or(ApplicationError::Conflict)?;
                // Cached result không vượt current auth: tenant suspended hoặc membership mất quyền phải bị chặn.
                transaction
                    .lock_workspace(workspace_id, principal.user_id())
                    .await?
                    .authorize(&principal, false)?;
                transaction.commit().await?;
                return Ok(workspace_id);
            }
        }
        if !transaction.timezone_exists(&draft.timezone).await? {
            return Err(ApplicationError::InvalidInput);
        }
        let workspace_id = Uuid::new_v4();
        transaction
            .insert_workspace(workspace_id, principal.user_id(), &draft)
            .await?;
        transaction
            .append_audit(AuditRecord {
                workspace_id: Some(workspace_id),
                actor_user_id: Some(principal.user_id()),
                session_id: Some(principal.session_id()),
                detail: AuditDetail::WorkspaceCreated { workspace_id },
                client_type: principal.client_type(),
                correlation_id,
            })
            .await?;
        transaction
            .complete_workspace_creation(principal.user_id(), key_digest, workspace_id)
            .await?;
        transaction.commit().await?;
        Ok(workspace_id)
    }

    /**
     * Picker đọc theo current session/membership, không tự mở scope hoặc trả dữ liệu tenant khác.
     * Input
     * Param: proof — full session đã chọn context; limited bị domain từ chối.
     * Param: after — identity cuối trang; HTTP adapter phải ký cursor trước khi phát cho client.
     * Param: limit — số hàng1–100, không cho unlimited.
     * Output: summary theo UUID; quyền phải kiểm lại trong request tiếp theo.
     * # Errors
     * Trả lỗi từ chối hoặc lỗi đã mô tả ở trên; không chứa dữ liệu nhạy cảm.
     */
    pub async fn list_workspaces(
        &self,
        proof: &SessionProof,
        after: Option<Uuid>,
        limit: i64,
    ) -> Result<Vec<WorkspaceSummary>, ApplicationError> {
        if !(1..=100).contains(&limit) {
            return Err(ApplicationError::InvalidInput);
        }
        let mut transaction = self.store.begin().await?;
        let locked = transaction.lock_session(proof).await?;
        let principal =
            locked
                .session
                .authorize(&locked.account, proof, locked.observed_at, false)?;
        let summaries = transaction
            .list_workspaces(principal.user_id(), after, limit)
            .await?;
        transaction.commit().await?;
        Ok(summaries)
    }

    /**
     * Kiểm authority hiện hành trong request này; mutation khác phải giữ cùng transaction tới commit.
     * Input
     * Param: proof — credential/context cần resolve lại, không nhận principal do client dựng.
     * Param: `workspace_id` — selector tenant chưa được tin cậy.
     * Param: `require_admin` — use case quyết định có cần Admin, không dựa role request.
     * Output: admission snapshot hoặc forbidden, không là capability cho request tương lai.
     * # Errors
     * Trả lỗi từ chối hoặc lỗi đã mô tả ở trên; không chứa dữ liệu nhạy cảm.
     */
    pub async fn admit_workspace(
        &self,
        proof: &SessionProof,
        workspace_id: Uuid,
        require_admin: bool,
    ) -> Result<WorkspaceAdmission, ApplicationError> {
        let mut transaction = self.store.begin().await?;
        let locked = transaction.lock_session(proof).await?;
        let principal =
            locked
                .session
                .authorize(&locked.account, proof, locked.observed_at, false)?;
        let workspace = transaction
            .lock_workspace(workspace_id, principal.user_id())
            .await?;
        let admission = workspace.authorize(&principal, require_admin)?;
        transaction.commit().await?;
        Ok(admission)
    }
}
