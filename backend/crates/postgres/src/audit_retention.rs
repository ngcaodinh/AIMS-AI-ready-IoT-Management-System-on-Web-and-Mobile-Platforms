//! Physical unit of work audit purge; mọi query bind, result commit cùng DELETE và không chạm IAM parent.

use crate::{PgIdentityStore, PgUnitOfWork, commit_error, storage_error};
use chrono::{DateTime, Utc};
use iot_application::{
    audit_retention::{AuditRetentionStore, AuditRetentionTransaction},
    error::ApplicationError,
};
use iot_domain::audit_retention::{AuditRetentionBatch, AuditRetentionRun, BatchLimit};
use sqlx::Row;
use uuid::Uuid;

impl AuditRetentionStore for PgIdentityStore {
    type Transaction = PgUnitOfWork;
    /**
     * Mở transaction worker retention trên pool đã được cấp quyền, không tự grant hoặc dùng owner credential.
     * Output: unit of work không sink/`FencedWork`, giữ worker tách khỏi measurement auth.
     * Errors: storage được lọc như trước, không thay đổi transaction/rollback policy.
     */
    async fn begin_retention(&self) -> Result<PgUnitOfWork, ApplicationError> {
        Ok(PgUnitOfWork {
            transaction: self.pool.begin().await.map_err(storage_error)?,
            // Worker retention có vòng đời riêng; không trộn sample với auth batch của lab.
            diagnostics: None,
            fenced_work: None,
        })
    }
}

impl AuditRetentionTransaction for PgUnitOfWork {
    /// Server default đóng cutoff lần đầu; ON CONFLICT giữ cutoff cũ khi restart cùng run ID.
    async fn start_run(&mut self, run_id: Uuid) -> Result<AuditRetentionRun, ApplicationError> {
        sqlx::query("INSERT INTO audit_retention_runs(run_id) VALUES($1) ON CONFLICT DO NOTHING")
            .bind(run_id)
            .execute(&mut *self.transaction)
            .await
            .map_err(storage_error)?;
        self.load_run(run_id).await
    }

    /// Advisory transaction lock có namespace riêng; hash collision chỉ serialize thêm, không cấp quyền hoặc mất dữ liệu.
    async fn lock_batch(&mut self, batch_id: Uuid) -> Result<(), ApplicationError> {
        sqlx::query("SELECT pg_advisory_xact_lock(hashtextextended('audit-retention-batch:'||$1::uuid::text,0))")
            .bind(batch_id).execute(&mut *self.transaction).await.map_err(storage_error)?;
        Ok(())
    }

    /// Đọc cutoff immutable sau khóa; clock lùi hoặc cutoff chưa đủ tuổi không được purge.
    async fn load_run(&mut self, run_id: Uuid) -> Result<AuditRetentionRun, ApplicationError> {
        let cutoff:DateTime<Utc>=sqlx::query_scalar("SELECT cutoff FROM audit_retention_runs WHERE run_id=$1 AND cutoff<=clock_timestamp()-interval '720 hours'")
            .bind(run_id).fetch_optional(&mut *self.transaction).await.map_err(storage_error)?.ok_or(ApplicationError::Conflict)?;
        AuditRetentionRun::restore(run_id, cutoff).ok_or(ApplicationError::Unavailable)
    }

    /// Result-only ledger không có placeholder; same-batch contender chờ advisory lock rồi đọc result gốc.
    async fn batch(
        &mut self,
        batch_id: Uuid,
    ) -> Result<Option<AuditRetentionBatch>, ApplicationError> {
        let row=sqlx::query("SELECT run_id,batch_limit,removed_count,completed_at FROM audit_retention_batches WHERE batch_id=$1")
            .bind(batch_id).fetch_optional(&mut *self.transaction).await.map_err(storage_error)?;
        row.map(|row| {
            Ok(AuditRetentionBatch {
                batch_id,
                run_id: row.try_get("run_id").map_err(storage_error)?,
                limit: BatchLimit::new(row.try_get("batch_limit").map_err(storage_error)?)
                    .ok_or(ApplicationError::Unavailable)?,
                removed_count: row.try_get("removed_count").map_err(storage_error)?,
                completed_at: row.try_get("completed_at").map_err(storage_error)?,
            })
        })
        .transpose()
    }

    /// Khóa audit theo tuple ổn định và skip row đang giữ; chỉ xóa expired audit, không cascade session hay evidence parent.
    async fn purge_audit(
        &mut self,
        cutoff: DateTime<Utc>,
        limit: BatchLimit,
    ) -> Result<i32, ApplicationError> {
        sqlx::query_scalar("WITH candidates AS (SELECT audit_event_id FROM audit_events WHERE created_at<$1 ORDER BY created_at,audit_event_id LIMIT $2 FOR UPDATE SKIP LOCKED), deleted AS (DELETE FROM audit_events audit USING candidates WHERE audit.audit_event_id=candidates.audit_event_id RETURNING 1) SELECT count(*)::integer FROM deleted")
            .bind(cutoff).bind(limit.get()).fetch_one(&mut *self.transaction).await.map_err(storage_error)
    }

    /// INSERT result đã hoàn tất sau DELETE cùng transaction; lỗi permission/storage rollback toàn bộ batch.
    async fn complete_batch(
        &mut self,
        batch_id: Uuid,
        run_id: Uuid,
        limit: BatchLimit,
        removed_count: i32,
    ) -> Result<AuditRetentionBatch, ApplicationError> {
        let completed_at=sqlx::query_scalar("INSERT INTO audit_retention_batches(batch_id,run_id,batch_limit,removed_count) VALUES($1,$2,$3,$4) RETURNING completed_at")
            .bind(batch_id).bind(run_id).bind(limit.get()).bind(removed_count).fetch_one(&mut *self.transaction).await.map_err(storage_error)?;
        Ok(AuditRetentionBatch {
            batch_id,
            run_id,
            limit,
            removed_count,
            completed_at,
        })
    }

    /// Giữ cùng classifier `CommitUnknown` với unit of work khác; retry phải giữ batch ID để resolve durable result.
    async fn commit_retention(self) -> Result<(), ApplicationError> {
        self.transaction.commit().await.map_err(commit_error)
    }
}
