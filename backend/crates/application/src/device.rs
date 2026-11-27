//! Use case registry và schema assignment; không làm broker I/O hoặc nâng trạng thái ONLINE.

use crate::{
    device_ports::{DeviceStore, DeviceTransaction},
    error::ApplicationError,
    template_ports::TemplateDigest,
};
use iot_domain::{
    audit_write::AuditDetail,
    device::{ApprovedDeviceModels, DeviceDraft, DeviceValidation, RegisteredDevice},
    identity::{AuditRecord, SessionProof},
    template_snapshot::TemplateVersionSnapshot,
};
use uuid::Uuid;

/// Composition phải truyền policy model đã duyệt; không cho template tự quyết model phần cứng hợp lệ.
pub struct DeviceService<S, C> {
    store: S,
    digest: C,
    models: ApprovedDeviceModels,
}

impl From<DeviceValidation> for ApplicationError {
    /// Phân loại lỗi ổn định cho transport, không phản chiếu serial hoặc metadata tenant khác.
    fn from(failure: DeviceValidation) -> Self {
        match failure {
            DeviceValidation::SerialInvalid | DeviceValidation::NameInvalid => Self::InvalidInput,
            DeviceValidation::ModelUnsupported => Self::DeviceModelUnsupported,
            DeviceValidation::ModelMismatch => Self::DeviceModelMismatch,
        }
    }
}

impl<S: DeviceStore, C: TemplateDigest> DeviceService<S, C> {
    /**
     * Dựng registry service từ các port và policy đã duyệt, không tự cấp model hoặc mở kết nối.
     * Input
     * Param: store — factory giữ một transaction xuyên suốt auth và aggregate.
     * Param: digest — SHA256 canonical published content.
     * Param: models — allowlist bootstrap được composition chịu trách nhiệm phê duyệt.
     * Output: service không phụ thuộc `SQLx`/Tokio hoặc crypto implementation.
     */
    #[must_use]
    pub const fn new(store: S, digest: C, models: ApprovedDeviceModels) -> Self {
        Self {
            store,
            digest,
            models,
        }
    }

    /**
     * Kiểm digest từ immutable rows trước sử dụng schema để không phát cấu hình thiếu hoặc sai snapshot.
     * Input
     * Param: schema — content và digest do persistence port trả về.
     * Output: thành công khi khớp; Errors: Unavailable nếu persisted content hỏng.
     */
    fn verify_digest(&self, schema: &TemplateVersionSnapshot) -> Result<(), ApplicationError> {
        if self
            .digest
            .content_digest(&schema.content.canonical_bytes())
            != schema.content_digest
        {
            return Err(ApplicationError::Unavailable);
        }
        Ok(())
    }

    /**
     * Admin đăng ký device cùng runtime/actuators/audit, chỉ trả receipt sau commit được xác nhận.
     * Input
     * Param: proof — full session/context của actor, phải còn hạn sau mọi lock wait.
     * Param: `workspace_id` — selector tenant được authorize qua current membership.
     * Param: draft — input registry, không có metadata hardware/firmware hoặc credential.
     * Param: `correlation_id` — trace required audit, không chứa raw serial/name.
     * Output: registry receipt REGISTERED/UNKNOWN không có credential ACTIVE.
     * # Errors
     * Quyền, owner invalid, model invalid, duplicate serial, storage hoặc `CommitUnknown`.
     * Side effects: một commit gồm registry/runtime/actuator/audit, không provisioning network.
     */
    pub async fn register(
        &self,
        proof: &SessionProof,
        workspace_id: Uuid,
        mut draft: DeviceDraft,
        correlation_id: Uuid,
    ) -> Result<RegisteredDevice, ApplicationError> {
        let mut transaction = self.store.begin_device().await?;
        let locked = transaction
            .lock_device_actor(proof, Some(draft.owner_user_id))
            .await?;
        let principal =
            locked
                .session
                .authorize_actor(&locked.account, proof, locked.observed_at, false)?;
        transaction
            .lock_device_scope(workspace_id, principal.user_id())
            .await?
            .authorize(&principal, true)?;
        // Kiểm NFC trước cận scalar; không thêm dependency hoặc chuẩn hóa serial làm đổi natural key.
        draft.name = transaction.normalize_device_name(&draft.name).await?;
        let draft = draft.validate()?;
        if !transaction
            .owner_is_current(workspace_id, draft.owner_user_id)
            .await?
        {
            return Err(ApplicationError::DeviceOwnerInvalid);
        }
        let schema = transaction
            .registration_schema(workspace_id, draft.template_version_id)
            .await?;
        self.verify_digest(&schema)?;
        self.models
            .validate(&draft.model, &schema.content.draft().model)?;
        // User/Workspace/root fences giữ quyền ổn định; clock phải mới sau khi đã chờ toàn bộ khóa.
        let now = transaction.device_now().await?;
        locked
            .session
            .authorize_actor(&locked.account, proof, now, false)?;
        let device_id = Uuid::new_v4();
        let receipt = transaction
            .insert_registered_device(workspace_id, device_id, &draft, now)
            .await?;
        /* Unique(serial) có thể chờ transaction của tenant khác dù mọi User/Workspace fence đã giữ.
         * Đọc lại clock sau INSERT để rollback registry nếu session hết hạn trong lúc chờ uniqueness. */
        let now = transaction.device_now().await?;
        let principal = locked
            .session
            .authorize_actor(&locked.account, proof, now, false)?;
        transaction
            .append_device_audit(AuditRecord {
                workspace_id: Some(workspace_id),
                actor_user_id: Some(principal.user_id()),
                session_id: Some(principal.session_id()),
                detail: AuditDetail::DeviceRegistered {
                    device_id,
                    template_version_id: draft.template_version_id,
                    actuator_count: receipt.actuator_count,
                },
                client_type: principal.client_type(),
                correlation_id,
            })
            .await?;
        transaction.commit_device().await?;
        Ok(receipt)
    }

    /**
     * Đọc schema qua assigned device/current pin, không cho USER dùng version UUID để đọc toàn tenant.
     * Input
     * Param: proof — full session/context hiện hành của Admin hoặc owner.
     * Param: `workspace_id` — tenant ACTIVE cần kiểm membership/grant hiện hành.
     * Param: `device_id` — selector trong tenant, không owner hoặc version do client tự khai.
     * Output: immutable published snapshot đúng pin.
     * # Errors
     * Not-found chung cho foreign/unassigned, quyền/storage.
     */
    pub async fn schema(
        &self,
        proof: &SessionProof,
        workspace_id: Uuid,
        device_id: Uuid,
    ) -> Result<TemplateVersionSnapshot, ApplicationError> {
        let mut transaction = self.store.begin_device().await?;
        let locked = transaction.lock_device_actor(proof, None).await?;
        let principal =
            locked
                .session
                .authorize_actor(&locked.account, proof, locked.observed_at, false)?;
        let admission = transaction
            .lock_device_scope(workspace_id, principal.user_id())
            .await?
            .authorize(&principal, false)?;
        let pin = transaction.device_pin(workspace_id, device_id).await?;
        if !pin.permits_schema(&admission) {
            return Err(ApplicationError::ResourceNotFound);
        }
        let schema = transaction
            .pinned_schema(workspace_id, pin.template_version_id)
            .await?;
        self.verify_digest(&schema)?;
        let now = transaction.device_now().await?;
        locked
            .session
            .authorize_actor(&locked.account, proof, now, false)?;
        transaction.commit_device().await?;
        Ok(schema)
    }
}
