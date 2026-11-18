//! Ticket storage và CAS native PostgreSQL; không trả raw ticket hoặc authority sau khi transaction lỗi.

use crate::{PgIdentityStore, PgUnitOfWork, commit_error, storage_error};
use iot_application::{
    error::ApplicationError,
    ports::{RealtimeSessionStore, RealtimeTransaction},
};
use iot_domain::realtime::{NewWebSocketTicket, RealtimeBinding};
use sqlx::{PgConnection, Postgres, Row, pool::PoolConnection, query_scalar};
use std::collections::HashSet;
use std::time::Duration;
use uuid::Uuid;

// $1 luôn bind mảng UUID lấy từ registry; DB clock và trạng thái account là authority của session.
const ACTIVE_REALTIME_SESSIONS_QUERY: &str = "SELECT session.session_id FROM public.sessions AS session JOIN public.users AS account ON account.user_id=session.user_id WHERE session.session_id=ANY($1) AND session.revoked_at IS NULL AND session.expires_at>clock_timestamp() AND account.account_status='ACTIVE'";
// Hai giá trị theo mili giây được giới hạn riêng cho handshake, không thay cấu hình dùng chung của pool.
const REALTIME_HANDSHAKE_STATEMENT_TIMEOUT: &str = "2000ms";
const REALTIME_HANDSHAKE_LOCK_TIMEOUT: &str = "1000ms";
// Ngân sách transaction đồng bộ với handshake; close riêng vẫn được chờ trước khi worker trả quota.
const REALTIME_HANDSHAKE_TRANSACTION_TIMEOUT: Duration = Duration::from_secs(3);
const REALTIME_HANDSHAKE_CHECKOUT_CLOSE_TIMEOUT: Duration = Duration::from_secs(2);
// Tên setting là literal tĩnh; thời lượng vẫn bind để không ghép dữ liệu vào SQL.
const SET_REALTIME_HANDSHAKE_TIMEOUTS_QUERY: &str =
    "SELECT set_config('statement_timeout', $1, true), set_config('lock_timeout', $2, true)";

impl RealtimeSessionStore for PgIdentityStore {
    /**
     * Consume ticket trong transaction có timeout riêng và giữ checkout tới khi COMMIT/ROLLBACK cùng đóng xong.
     * Input
     * Param: digest — SHA-256 digest đã được application tính từ ticket có định dạng hợp lệ.
     * Output: binding nếu consume thắng và commit thành công; None nếu ticket hết hạn/đã dùng/không có.
     * Errors: lỗi query/rollback/commit/close được chuẩn hóa; lỗi commit không chắc chắn giữ `CommitUnknown`.
     * Side effects: dùng checkout riêng, đặt timeout transaction-local, rollback nhánh không thắng và đóng checkout.
     */
    async fn consume_realtime_ticket(
        &self,
        digest: [u8; 32],
    ) -> Result<Option<RealtimeBinding>, ApplicationError> {
        let mut connection = self.pool.acquire().await.map_err(storage_error)?;
        let transaction_result =
            tokio::time::timeout(REALTIME_HANDSHAKE_TRANSACTION_TIMEOUT, async {
                // Checkout nằm ngoài future có timeout để sau khi hủy query vẫn có thể close tường minh.
                sqlx::query("BEGIN")
                    .execute(&mut *connection)
                    .await
                    .map_err(storage_error)?;
                if let Err(operation_error) =
                    apply_realtime_handshake_timeouts(&mut connection).await
                {
                    let rollback_result = sqlx::query("ROLLBACK")
                        .execute(&mut *connection)
                        .await
                        .map_err(storage_error);
                    return match rollback_result {
                        Err(rollback_error) => Err(rollback_error),
                        Ok(_) => Err(operation_error),
                    };
                }

                let ticket_result = consume_ticket_on_connection(&mut *connection, digest).await;
                // Chỉ commit khi CAS thắng; nhánh không thắng/lỗi phải rollback trước khi close checkout.
                match ticket_result {
                    Ok(Some(binding)) => sqlx::query("COMMIT")
                        .execute(&mut *connection)
                        .await
                        .map(|_| Some(binding))
                        .map_err(commit_error),
                    Ok(None) => sqlx::query("ROLLBACK")
                        .execute(&mut *connection)
                        .await
                        .map(|_| None)
                        .map_err(storage_error),
                    Err(operation_error) => {
                        match sqlx::query("ROLLBACK").execute(&mut *connection).await {
                            Ok(_) => Err(operation_error),
                            Err(rollback_error) => Err(storage_error(rollback_error)),
                        }
                    }
                }
            })
            .await
            .unwrap_or(Err(ApplicationError::CommitUnknown));

        // Timeout chỉ hủy transaction borrow; checkout còn thuộc method và explicit close kết thúc trước khi trả.
        let close_result = close_realtime_handshake_checkout(connection).await;
        match transaction_result {
            Err(operation_error) => Err(operation_error),
            Ok(binding) => close_result.map(|()| binding),
        }
    }

    /**
     * Lọc session registry theo DB clock và trạng thái account; không dùng positive cache cho quyền.
     * Input
     * Param: session_ids — ID của các socket trên instance gọi, bind bằng array UUID.
     * Output: subset còn session/account active; phiên hết hạn hoặc bị revoke bị loại ngay.
     * Errors: lỗi SQL được chuẩn hóa thành unavailable, không trả SQL hoặc connection detail.
     */
    async fn active_realtime_sessions(
        &self,
        session_ids: Vec<Uuid>,
    ) -> Result<HashSet<Uuid>, ApplicationError> {
        if session_ids.is_empty() {
            return Ok(HashSet::new());
        }
        // DB clock là nguồn expiry; query chỉ xét ID từ registry instance này, không quét hoặc xuất session khác.
        let active = query_scalar::<_, Uuid>(ACTIVE_REALTIME_SESSIONS_QUERY)
            .bind(session_ids)
            .fetch_all(&self.pool)
            .await
            .map_err(storage_error)?;
        Ok(active.into_iter().collect())
    }

    /**
     * Kiểm session trước ACK với timeout transaction-local rồi đóng checkout trước khi route nhả quota.
     * Input
     * Param: session_id — session đã lấy từ binding ticket được consume trong cùng handshake.
     * Output: true nếu session/account còn active theo clock DB; false nếu query không trả session này.
     * Errors: lỗi query hoặc đóng connection được chuẩn hóa thành unavailable, không lộ SQL/detail.
     * Side effects: checkout một connection riêng, rollback nếu query lỗi và đợi close trước khi future trả về.
     */
    async fn active_realtime_session_for_handshake(
        &self,
        session_id: Uuid,
    ) -> Result<bool, ApplicationError> {
        let mut connection = self.pool.acquire().await.map_err(storage_error)?;
        let transaction_result =
            tokio::time::timeout(REALTIME_HANDSHAKE_TRANSACTION_TIMEOUT, async {
                sqlx::query("BEGIN")
                    .execute(&mut *connection)
                    .await
                    .map_err(storage_error)?;
                apply_realtime_handshake_timeouts(&mut connection).await?;
                let active_result = query_scalar::<_, Uuid>(ACTIVE_REALTIME_SESSIONS_QUERY)
                    .bind(vec![session_id])
                    .fetch_all(&mut *connection)
                    .await
                    .map(|active| active.contains(&session_id))
                    .map_err(storage_error);

                match active_result {
                    Ok(is_active) => sqlx::query("COMMIT")
                        .execute(&mut *connection)
                        .await
                        .map(|_| is_active)
                        .map_err(storage_error),
                    Err(operation_error) => {
                        match sqlx::query("ROLLBACK").execute(&mut *connection).await {
                            Ok(_) => Err(operation_error),
                            Err(rollback_error) => Err(storage_error(rollback_error)),
                        }
                    }
                }
            })
            .await
            .unwrap_or(Err(ApplicationError::Unavailable));

        // Timeout hủy thao tác transaction nhưng checkout còn sống ở đây cho đến explicit close hoặc discard.
        let close_result = close_realtime_handshake_checkout(connection).await;
        match (transaction_result, close_result) {
            (Err(query_error), _) => Err(query_error),
            (Ok(is_active), Ok(())) => Ok(is_active),
            (Ok(_), Err(close_error)) => Err(close_error),
        }
    }
}

/**
 * Đóng hoặc discard checkout theo deadline để route chỉ nhả DB quota sau khi pool slot đã được giải phóng.
 * Input
 * Param: connection — checkout riêng của handshake, không còn được mượn bởi transaction future.
 * Errors: lỗi hoặc timeout close thành `Unavailable`; SQLx close future bị drop sẽ loại raw connection khỏi pool.
 * Side effects: chờ explicit close tối đa hai giây, giữ pool permit trong thời gian close.
 */
async fn close_realtime_handshake_checkout(
    connection: PoolConnection<Postgres>,
) -> Result<(), ApplicationError> {
    // SQLx giữ pool permit trong `PoolConnection::close`; nếu hết giới hạn, drop future làm rơi floating checkout.
    match tokio::time::timeout(
        REALTIME_HANDSHAKE_CHECKOUT_CLOSE_TIMEOUT,
        connection.close(),
    )
    .await
    {
        Ok(Ok(())) => Ok(()),
        Ok(Err(_)) | Err(_) => Err(ApplicationError::Unavailable),
    }
}

/**
 * Giới hạn thời gian khóa và câu lệnh trong transaction của handshake để DB tự hủy chờ kéo dài.
 * Input
 * Param: connection — checkout riêng đang ở trong transaction trước khi đọc hoặc consume ticket.
 * Errors: lỗi đặt timeout được chuẩn hóa thành lỗi storage để caller rollback và đóng checkout.
 */
async fn apply_realtime_handshake_timeouts(
    connection: &mut PgConnection,
) -> Result<(), ApplicationError> {
    sqlx::query(SET_REALTIME_HANDSHAKE_TIMEOUTS_QUERY)
        .bind(REALTIME_HANDSHAKE_STATEMENT_TIMEOUT)
        .bind(REALTIME_HANDSHAKE_LOCK_TIMEOUT)
        .execute(&mut *connection)
        .await
        .map_err(storage_error)?;
    Ok(())
}

/**
 * Đọc binding chỉ sau CAS consume trong cùng checkout transaction để không phát authority cho ticket replay.
 * Input
 * Param: connection — checkout đang ở trạng thái transaction sau `BEGIN`.
 * Param: digest — digest ticket được truyền bằng bind, không ghép vào SQL.
 * Output: binding của ticket thắng hoặc None khi CAS không thắng.
 * Errors: lỗi query/row mapping được chuẩn hóa; caller chịu trách nhiệm rollback và đóng checkout khi lỗi.
 */
async fn consume_ticket_on_connection(
    connection: &mut PgConnection,
    digest: [u8; 32],
) -> Result<Option<RealtimeBinding>, ApplicationError> {
    // Function PostgreSQL kiểm current versions và expiry; giữ CAS, quyền và binding trong cùng transaction.
    // Digest chỉ đi qua bind; không lắp raw ticket vào SQL hoặc lỗi.
    let consumed: bool = sqlx::query_scalar("SELECT public.consume_websocket_ticket($1)")
        .bind(digest.as_slice())
        .fetch_one(&mut *connection)
        .await
        .map_err(storage_error)?;
    if !consumed {
        return Ok(None);
    }
    let row=sqlx::query("SELECT workspace_id,user_id,session_id,grant_generation,workspace_authorization_version,membership_authorization_version FROM websocket_tickets WHERE ticket_digest=$1")
        .bind(digest.as_slice()).fetch_one(&mut *connection).await.map_err(storage_error)?;
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

impl RealtimeTransaction for PgUnitOfWork {
    /// Bind đủ tenant/principal/current grant/auth-version; TTL được schema kiểm lại.
    async fn insert_ticket(&mut self, ticket: &NewWebSocketTicket) -> Result<(), ApplicationError> {
        sqlx::query("INSERT INTO websocket_tickets(ticket_id,ticket_digest,workspace_id,user_id,session_id,grant_generation,workspace_authorization_version,membership_authorization_version,issued_at,expires_at) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10)")
            .bind(ticket.ticket_id).bind(ticket.digest.as_slice()).bind(ticket.workspace_id).bind(ticket.user_id).bind(ticket.session_id).bind(ticket.grant_generation)
            .bind(ticket.workspace_authorization_version).bind(ticket.membership_authorization_version).bind(ticket.issued_at).bind(ticket.expires_at)
            .execute(&mut *self.transaction).await.map_err(storage_error)?;
        Ok(())
    }
}
