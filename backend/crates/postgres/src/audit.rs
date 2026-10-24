//! Query audit allowlist theo current-authorized workspace; index workspace/time/UUID phục vụ keyset.

use crate::{PgUnitOfWork, storage_error};
use chrono::{DateTime, Utc};
use iot_application::{error::ApplicationError, ports::AuditReadTransaction};
use iot_domain::audit::{AuditCursor, AuditEntry};
use sqlx::Row;
use uuid::Uuid;

impl AuditReadTransaction for PgUnitOfWork {
    /// Lấy clock sau khi giữ parent/member fence để expiry không bị bỏ qua khi chờ khóa.
    async fn audit_now(&mut self) -> Result<DateTime<Utc>, ApplicationError> {
        sqlx::query_scalar("SELECT clock_timestamp()")
            .fetch_one(&mut *self.transaction)
            .await
            .map_err(storage_error)
    }
    /// Bind scope/cutoff/keyset cùng query; không có branch workspace NULL để Admin tenant đọc global auth.
    async fn list_audit(
        &mut self,
        workspace_id: Uuid,
        cutoff: DateTime<Utc>,
        before: Option<&AuditCursor>,
        limit: i64,
    ) -> Result<Vec<AuditEntry>, ApplicationError> {
        let rows=sqlx::query("SELECT audit_event_id,workspace_id,actor_user_id,event_type,outcome,occurred_at,created_at,resource_type,resource_id FROM audit_events WHERE workspace_id=$1 AND created_at>=$2 AND ($3::timestamptz IS NULL OR (created_at,audit_event_id)<($3,$4)) ORDER BY created_at DESC,audit_event_id DESC LIMIT $5")
            .bind(workspace_id).bind(cutoff).bind(before.map(|cursor|cursor.created_at)).bind(before.map(|cursor|cursor.audit_event_id))
            .bind(limit).fetch_all(&mut *self.transaction).await.map_err(storage_error)?;
        let mut entries = Vec::with_capacity(rows.len());
        for row in rows {
            entries.push(AuditEntry {
                audit_event_id: row.try_get("audit_event_id").map_err(storage_error)?,
                workspace_id: row.try_get("workspace_id").map_err(storage_error)?,
                actor_user_id: row.try_get("actor_user_id").map_err(storage_error)?,
                event_type: row.try_get("event_type").map_err(storage_error)?,
                outcome: row.try_get("outcome").map_err(storage_error)?,
                occurred_at: row.try_get("occurred_at").map_err(storage_error)?,
                created_at: row.try_get("created_at").map_err(storage_error)?,
                resource_type: row.try_get("resource_type").map_err(storage_error)?,
                resource_id: row.try_get("resource_id").map_err(storage_error)?,
            });
        }
        Ok(entries)
    }
}
