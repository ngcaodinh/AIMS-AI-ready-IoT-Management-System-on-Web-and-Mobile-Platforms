//! Ports registry giữ auth, published pin, runtime, actuator và audit trong một unit of work.

use crate::error::ApplicationError;
use chrono::{DateTime, Utc};
use iot_domain::{
    device::{DeviceDraft, DevicePin, RegisteredDevice},
    identity::{ActorAccountSnapshot, AuditRecord, SessionProof, SessionSnapshot},
    template_snapshot::TemplateVersionSnapshot,
    workspace::WorkspaceSnapshot,
};
use std::future::Future;
use uuid::Uuid;

/// Snapshot khóa cho registry gồm trạng thái actor, session và clock sau khóa.
pub struct LockedActorSession {
    pub account: ActorAccountSnapshot,
    pub session: SessionSnapshot,
    pub observed_at: DateTime<Utc>,
}

/// Boundary riêng cho registry, không nhận pool, password, broker hoặc handle transaction vật lý.
pub trait DeviceTransaction: Send {
    /**
     * Khóa User actor và owner theo UUID tăng dần trước Workspace, rồi load session hiện hành.
     * Input
     * Param: proof — session/context chưa được tin cậy.
     * Param: owner — Some khi đăng ký, None khi chỉ đọc; không cấp quyền từ UUID này.
     * Output: session/account dưới fence hoặc lỗi quyền/storage.
     */
    fn lock_device_actor(
        &mut self,
        proof: &SessionProof,
        owner: Option<Uuid>,
    ) -> impl Future<Output = Result<LockedActorSession, ApplicationError>> + Send;
    /**
     * Khóa scope sau User để membership/grant không đổi giữa authorization và truy cập device.
     * Input
     * Param: `workspace_id` — tenant selector chưa được cấp quyền.
     * Param: `user_id` — actor lấy từ session resolver, không từ body.
     * Output: snapshot current membership/grant; Errors: quyền/storage.
     */
    fn lock_device_scope(
        &mut self,
        workspace_id: Uuid,
        user_id: Uuid,
    ) -> impl Future<Output = Result<WorkspaceSnapshot, ApplicationError>> + Send;
    /**
     * Chuẩn hóa tên NFC để caller kiểm length trên canonical text, giữ nguyên serial identity.
     * Input
     * Param: name — tên từ input chưa được tin cậy.
     * Output: tên NFC; Errors: text/storage không hợp lệ.
     */
    fn normalize_device_name(
        &mut self,
        name: &str,
    ) -> impl Future<Output = Result<String, ApplicationError>> + Send;
    /**
     * Kiểm eligibility hiện hành dưới User/Workspace fence, không suy quyền từ FK tồn tại.
     * Input
     * Param: `workspace_id` — tenant đã được actor authorize.
     * Param: `owner_id` — target User đã được khóa trước Workspace.
     * Output: true khi account/member ACTIVE và current grant còn hiệu lực; Errors: storage.
     */
    fn owner_is_current(
        &mut self,
        workspace_id: Uuid,
        owner_id: Uuid,
    ) -> impl Future<Output = Result<bool, ApplicationError>> + Send;
    /**
     * Khóa root để chặn pin mới khi ARCHIVED, giữ version cũ hợp lệ khi root đang có draft mới.
     * Input
     * Param: `workspace_id` — scope đã kiểm quyền Admin.
     * Param: `version_id` — published selector chỉ được resolve trong scope đó.
     * Output: immutable snapshot; Errors: not-found hoặc storage.
     */
    fn registration_schema(
        &mut self,
        workspace_id: Uuid,
        version_id: Uuid,
    ) -> impl Future<Output = Result<TemplateVersionSnapshot, ApplicationError>> + Send;
    /**
     * Resolve pin tối thiểu trong tenant để application kiểm assignment trước khi đọc schema.
     * Input
     * Param: `workspace_id` — tenant current member đã authorize.
     * Param: `device_id` — selector chưa được tin cậy, không dùng làm authority.
     * Output: identity/owner/pin dưới fence; Errors: not-found hoặc storage.
     */
    fn device_pin(
        &mut self,
        workspace_id: Uuid,
        device_id: Uuid,
    ) -> impl Future<Output = Result<DevicePin, ApplicationError>> + Send;
    /**
     * Đọc immutable content sau khi assignment đã được kiểm, không lấy version từ client để cấp quyền.
     * Input
     * Param: `workspace_id` — current tenant của device.
     * Param: `version_id` — version lấy từ device pin đã resolve.
     * Output: snapshot published; Errors: not-found hoặc storage.
     */
    fn pinned_schema(
        &mut self,
        workspace_id: Uuid,
        version_id: Uuid,
    ) -> impl Future<Output = Result<TemplateVersionSnapshot, ApplicationError>> + Send;
    /// Clock mới sau mọi lock wait, không dùng clock đã cũ trước khi chờ scope/root.
    fn device_now(
        &mut self,
    ) -> impl Future<Output = Result<DateTime<Utc>, ApplicationError>> + Send;
    /**
     * Ghi registry REGISTERED/runtime UNKNOWN và actuator từ writable capabilities cùng transaction.
     * Input
     * Param: `workspace_id` — tenant đã được current Admin authorize.
     * Param: `device_id` — UUID do application cấp, không lấy từ request.
     * Param: draft — input đã validate shape/model/owner/template.
     * Param: now — server admission timestamp, không timestamp client.
     * Output: registry receipt chưa commit; Errors: duplicate serial hoặc storage, không partial commit.
     */
    fn insert_registered_device(
        &mut self,
        workspace_id: Uuid,
        device_id: Uuid,
        draft: &DeviceDraft,
        now: DateTime<Utc>,
    ) -> impl Future<Output = Result<RegisteredDevice, ApplicationError>> + Send;
    /**
     * Ghi required audit typed cùng mutation để sink failure rollback toàn bộ aggregate.
     * Input
     * Param: audit — actor/scope từ principal, detail chỉ chứa ID/counter allowlist.
     * Output: thành công khi đã append trong transaction hiện hành; Errors: audit/storage.
     */
    fn append_device_audit(
        &mut self,
        audit: AuditRecord,
    ) -> impl Future<Output = Result<(), ApplicationError>> + Send;
    /// Commit một lần trước khi phát receipt; lỗi ACK giữ `CommitUnknown`, không tự tạo device mới.
    fn commit_device(self) -> impl Future<Output = Result<(), ApplicationError>> + Send;
}

/// Factory dùng writer được composition cấp sẵn, không auto-grant hoặc đọc env/secret.
pub trait DeviceStore: Clone + Send + Sync {
    type Transaction: DeviceTransaction;
    /// Mở unit of work registry; drop trước commit phải rollback cả device/runtime/actuator/audit.
    fn begin_device(
        &self,
    ) -> impl Future<Output = Result<Self::Transaction, ApplicationError>> + Send;
}
