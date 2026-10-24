//! Ticket storage và CAS native PostgreSQL; không trả raw ticket hoặc authority sau khi transaction lỗi.

use crate::{PgUnitOfWork, storage_error};
use iot_application::{error::ApplicationError, ports::RealtimeTransaction};
use iot_domain::realtime::{NewWebSocketTicket, RealtimeBinding};
use sqlx::Row;

impl RealtimeTransaction for PgUnitOfWork {
    /// Bind đủ tenant/principal/current grant/auth-version; TTL được schema kiểm lại.
    async fn insert_ticket(&mut self, ticket: &NewWebSocketTicket) -> Result<(), ApplicationError> {
        sqlx::query("INSERT INTO websocket_tickets(ticket_id,ticket_digest,workspace_id,user_id,session_id,grant_generation,workspace_authorization_version,membership_authorization_version,issued_at,expires_at) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10)")
            .bind(ticket.ticket_id).bind(ticket.digest.as_slice()).bind(ticket.workspace_id).bind(ticket.user_id).bind(ticket.session_id).bind(ticket.grant_generation)
            .bind(ticket.workspace_authorization_version).bind(ticket.membership_authorization_version).bind(ticket.issued_at).bind(ticket.expires_at)
            .execute(&mut *self.transaction).await.map_err(storage_error)?;
        Ok(())
    }

    /// Native helper lấy User→Workspace fence rồi CAS; chỉ đọc binding khi chính transaction đã consume thắng.
    async fn consume_ticket(
        &mut self,
        digest: [u8; 32],
    ) -> Result<Option<RealtimeBinding>, ApplicationError> {
        // Function đã kiểm current versions và expiry; không tách CAS/check quyền thành hai transaction.
        let consumed: bool = sqlx::query_scalar("SELECT public.consume_websocket_ticket($1)")
            .bind(digest.as_slice())
            .fetch_one(&mut *self.transaction)
            .await
            .map_err(storage_error)?;
        if !consumed {
            return Ok(None);
        }
        let row=sqlx::query("SELECT workspace_id,user_id,session_id,grant_generation,workspace_authorization_version,membership_authorization_version FROM websocket_tickets WHERE ticket_digest=$1")
            .bind(digest.as_slice()).fetch_one(&mut *self.transaction).await.map_err(storage_error)?;
        Ok(Some(RealtimeBinding {
            workspace_id: row.try_get("workspace_id").map_err(storage_error)?,
            user_id: row.try_get("user_id").map_err(storage_error)?,
            session_id: row.try_get("session_id").map_err(storage_error)?,
            grant_generation: row.try_get("grant_generation").map_err(storage_error)?,
            workspace_authorization_version: row
                .try_get("workspace_authorization_version")
                .map_err(storage_error)?,
            membership_authorization_version: row
                .try_get("membership_authorization_version")
                .map_err(storage_error)?,
        }))
    }
}
