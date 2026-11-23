//! Ports hẹp của template, không đưa IAM limiter/password hoặc handle `SQLx` vào use case.

use crate::{error::ApplicationError, ports::LockedSession};
use chrono::{DateTime, Utc};
use iot_domain::{
    identity::{AuditRecord, SessionProof},
    template::ValidatedTemplate,
    template_snapshot::{PublishedTemplate, TemplateSnapshot},
    workspace::WorkspaceSnapshot,
};
use std::future::Future;
use uuid::Uuid;

/// Hash adapter chỉ nhận canonical content; không biết session/password hoặc truy vấn DB.
pub trait TemplateDigest: Clone + Send + Sync {
    /// Băm SHA256 canonical snapshot bytes, trả đúng32 byte; không log nội dung schema.
    fn content_digest(&self, canonical: &[u8]) -> [u8; 32];
}

/// Ý định publish do application tạo sau current auth/CAS, không nhận version/actor từ body client.
pub struct NewTemplateVersion {
    pub template_version_id: Uuid,
    pub version_number: i32,
    /// Revision draft đã validate trước khi root chuyển sang PUBLISHED; lấy dưới root lock.
    pub source_revision: i64,
    /// Revision được ghi lên root sau khi publication commit.
    pub published_root_revision: i64,
    pub content_digest: [u8; 32],
    pub published_by_user_id: Uuid,
    pub published_at: DateTime<Utc>,
}

/// Một unit of work sở hữu mọi lock/draft/version/audit đến commit, không callback network.
pub trait TemplateTransaction: Send {
    /// Load immutable content chỉ bằng tenant/version ID, không lấy name/model từ root đã có thể đổi.
    fn load_published_version(
        &mut self,
        workspace_id: Uuid,
        version_id: Uuid,
    ) -> impl Future<
        Output = Result<iot_domain::template_snapshot::TemplateVersionSnapshot, ApplicationError>,
    > + Send;
    /// Khóa User/session bằng cùng IAM resolver; trả snapshot để domain authorize full session/context.
    fn lock_actor(
        &mut self,
        proof: &SessionProof,
    ) -> impl Future<Output = Result<LockedSession, ApplicationError>> + Send;
    /// Khóa Workspace và current member/grant sau User; snapshot không tự cấp quyền cho caller.
    fn lock_scope(
        &mut self,
        workspace_id: Uuid,
        user_id: Uuid,
    ) -> impl Future<Output = Result<WorkspaceSnapshot, ApplicationError>> + Send;
    /// Lấy clock DB mới sau mọi lock wait để session hết hạn trong lúc chờ bị từ chối.
    fn template_now(
        &mut self,
    ) -> impl Future<Output = Result<DateTime<Utc>, ApplicationError>> + Send;
    /// Khóa root theo W/id và load toàn draft normalized dưới cùng fence; foreign ID không lookup global.
    fn lock_template(
        &mut self,
        workspace_id: Uuid,
        template_id: Uuid,
    ) -> impl Future<Output = Result<TemplateSnapshot, ApplicationError>> + Send;
    /// Insert root và children từ aggregate đã kiểm; không dùng published definition làm mutable draft.
    fn insert_template(
        &mut self,
        workspace_id: Uuid,
        template_id: Uuid,
        actor_id: Uuid,
        draft: &ValidatedTemplate,
        now: DateTime<Utc>,
    ) -> impl Future<Output = Result<TemplateSnapshot, ApplicationError>> + Send;
    /// CAS root revision rồi replace children theo thứ tự FK; failure rollback cả draft cũ và metadata.
    fn replace_draft(
        &mut self,
        before: &TemplateSnapshot,
        draft: &ValidatedTemplate,
        next_revision: i64,
        now: DateTime<Utc>,
    ) -> impl Future<Output = Result<TemplateSnapshot, ApplicationError>> + Send;
    /// Đọc số version lớn nhất dưới template lock; application kiểm overflow trước cấp số kế tiếp.
    fn latest_version_number(
        &mut self,
        workspace_id: Uuid,
        template_id: Uuid,
    ) -> impl Future<Output = Result<i32, ApplicationError>> + Send;
    /// Persist immutable snapshot và root publication CAS trong cùng transaction có marker0013.
    fn publish_template(
        &mut self,
        before: &TemplateSnapshot,
        version: &NewTemplateVersion,
    ) -> impl Future<Output = Result<PublishedTemplate, ApplicationError>> + Send;
    /// Append required audit cùng transaction template; lỗi không được nuốt hoặc commit mutation một phần.
    fn append_template_audit(
        &mut self,
        audit: AuditRecord,
    ) -> impl Future<Output = Result<(), ApplicationError>> + Send;
    /// Consume transaction khi commit; lost ACK giữ `CommitUnknown` và không tự tạo version mới để retry.
    fn commit_template(self) -> impl Future<Output = Result<(), ApplicationError>> + Send;
}

/// Factory template riêng, dùng transaction vật lý cùng pool nhưng không ép use case phụ thuộc port password/limiter.
pub trait TemplateStore: Clone + Send + Sync {
    type Transaction: TemplateTransaction;
    /// Bắt đầu unit of work, không đọc cấu hình/env hoặc mở quyền DB mới.
    fn begin_template(
        &self,
    ) -> impl Future<Output = Result<Self::Transaction, ApplicationError>> + Send;
}
