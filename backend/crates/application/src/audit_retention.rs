//! Job nội bộ audit retention; không đưa quyền purge vào `IdentityService` hoặc route user.

use crate::error::ApplicationError;
use chrono::{DateTime, Utc};
use iot_domain::audit_retention::{AuditRetentionBatch, AuditRetentionRun, BatchLimit};
use std::future::Future;
use uuid::Uuid;

/// Transaction port riêng cho worker; không yêu cầu session/user và không trả framework handle ra core.
pub trait AuditRetentionTransaction: Send {
    /// Tạo hoặc resume cùng run ID; cutoff phải được server đóng một lần và lưu immutable.
    fn start_run(
        &mut self,
        run_id: Uuid,
    ) -> impl Future<Output = Result<AuditRetentionRun, ApplicationError>> + Send;
    /// Serialize batch ID đến commit để same-intent retry không DELETE hai lần.
    fn lock_batch(
        &mut self,
        batch_id: Uuid,
    ) -> impl Future<Output = Result<(), ApplicationError>> + Send;
    /// Đọc run/cutoff durable và chặn clock chưa cho phép purge dữ liệu đủ tuổi.
    fn load_run(
        &mut self,
        run_id: Uuid,
    ) -> impl Future<Output = Result<AuditRetentionRun, ApplicationError>> + Send;
    /// Đọc result immutable đã có; thiếu result mới được phép thực hiện DELETE.
    fn batch(
        &mut self,
        batch_id: Uuid,
    ) -> impl Future<Output = Result<Option<AuditRetentionBatch>, ApplicationError>> + Send;
    /// Xóa tối đa limit audit trước cutoff; tuyệt đối không xóa session/ticket/binding theo cùng batch.
    fn purge_audit(
        &mut self,
        cutoff: DateTime<Utc>,
        limit: BatchLimit,
    ) -> impl Future<Output = Result<i32, ApplicationError>> + Send;
    /// Ghi result cùng transaction DELETE; failure phải rollback cả audit đã xóa.
    fn complete_batch(
        &mut self,
        batch_id: Uuid,
        run_id: Uuid,
        limit: BatchLimit,
        removed_count: i32,
    ) -> impl Future<Output = Result<AuditRetentionBatch, ApplicationError>> + Send;
    /// Commit chỉ sau khi result durable; mất ACK không được tự xử lý batch ID khác.
    fn commit_retention(self) -> impl Future<Output = Result<(), ApplicationError>> + Send;
}

/// Worker store phải được composition cấp pool quyền retention riêng, không dùng runtime request role.
pub trait AuditRetentionStore: Clone + Send + Sync {
    type Transaction: AuditRetentionTransaction;
    /// Bắt đầu unit of work nội bộ; adapter không tự đọc config/env hoặc cấp quyền DB.
    fn begin_retention(
        &self,
    ) -> impl Future<Output = Result<Self::Transaction, ApplicationError>> + Send;
}

/// Service purge tách khỏi actor/session API; caller vận hành giữ run/batch IDs để retry an toàn.
pub struct AuditRetentionService<S> {
    store: S,
}

impl<S: AuditRetentionStore> AuditRetentionService<S> {
    /**
     * Nhận store worker đã được composition/operator cấp quyền, không tự mở kết nối hoặc nâng quyền.
     * Input
     * Param: store — port riêng cho retention, không là authority từ user request.
     * Output: service nội bộ giữ atomic batch/result boundary.
     */
    #[must_use]
    pub const fn new(store: S) -> Self {
        Self { store }
    }

    /**
     * Bắt đầu hoặc resume cùng run ID để cutoff không trôi sau restart.
     * Input
     * Param: `run_id` — UUID intent do coordinator giữ bền vững, không nhận nil.
     * Output: run/cutoff sau commit; không có dữ liệu audit hoặc secret trong kết quả.
     * # Errors
     * `InvalidInput` với UUID nil; storage/`CommitUnknown` khi chưa biết metadata đã commit.
     */
    pub async fn start_run(&self, run_id: Uuid) -> Result<AuditRetentionRun, ApplicationError> {
        if run_id.is_nil() {
            return Err(ApplicationError::InvalidInput);
        }
        let mut transaction = self.store.begin_retention().await?;
        let run = transaction.start_run(run_id).await?;
        transaction.commit_retention().await?;
        Ok(run)
    }

    /**
     * Xóa một batch audit và commit result cùng DELETE; retry cùng ID chỉ trả result gốc.
     * Input
     * Param: `run_id` — run đã start/resume, không tạo cutoff tùy ý trong request purge.
     * Param: `batch_id` — UUID ổn định của batch; khác body phải conflict, không DELETE thêm.
     * Param: limit — số row tối đa1…1000 để giới hạn thời gian giữ khóa.
     * Output: result sau commit; count0 không chứng nhận run drain nếu row khác còn locked.
     * # Errors
     * `InvalidInput`, Conflict với mismatch/unknown run, storage hoặc `CommitUnknown`; không tự retry intent mới.
     */
    pub async fn purge_batch(
        &self,
        run_id: Uuid,
        batch_id: Uuid,
        limit: i32,
    ) -> Result<AuditRetentionBatch, ApplicationError> {
        let limit = BatchLimit::new(limit).ok_or(ApplicationError::InvalidInput)?;
        if run_id.is_nil() || batch_id.is_nil() {
            return Err(ApplicationError::InvalidInput);
        }
        let mut transaction = self.store.begin_retention().await?;
        transaction.lock_batch(batch_id).await?;
        let run = transaction.load_run(run_id).await?;
        if let Some(result) = transaction.batch(batch_id).await? {
            if result.run_id != run_id || result.limit != limit {
                return Err(ApplicationError::Conflict);
            }
            transaction.commit_retention().await?;
            return Ok(result);
        }
        let removed = transaction.purge_audit(run.cutoff(), limit).await?;
        let result = transaction
            .complete_batch(batch_id, run_id, limit, removed)
            .await?;
        transaction.commit_retention().await?;
        Ok(result)
    }
}
