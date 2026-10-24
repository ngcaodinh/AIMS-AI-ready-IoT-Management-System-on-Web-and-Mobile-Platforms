//! Claim/settle close outbox bằng native lease CAS; không mang JSON hoặc transaction vào core.

use crate::{PgIdentityStore, commit_error, storage_error};
use iot_application::{error::ApplicationError, outbox::CloseOutboxStore};
use iot_domain::outbox::{
    ClaimOptions, ClaimedCloseIntent, CloseConsumer, CloseIntent, LeaseReceipt, RetryDelay,
};
use sqlx::{Row, postgres::PgRow};
use uuid::Uuid;

impl CloseOutboxStore for PgIdentityStore {
    /// Claim giữ khóa consumption đến khi đọc xong metadata typed và commit; lỗi schema/version rollback cả batch.
    async fn claim_close_intents(
        &self,
        consumer: CloseConsumer,
        options: ClaimOptions,
    ) -> Result<Vec<ClaimedCloseIntent>, ApplicationError> {
        let mut transaction = self.pool.begin().await.map_err(storage_error)?;
        // Hàm native dùng SKIP LOCKED và tăng generation; mọi giá trị là bind, tên consumer là enum server.
        let claims = sqlx::query(
            "SELECT claimed_event_id,claimed_generation FROM public.claim_outbox($1,$2,$3)",
        )
        .bind(consumer.code())
        .bind(options.lease_seconds())
        .bind(options.batch_limit())
        .fetch_all(&mut *transaction)
        .await
        .map_err(storage_error)?;
        let mut result = Vec::with_capacity(claims.len());
        for claim in claims {
            let event_id = claim.try_get("claimed_event_id").map_err(storage_error)?;
            let generation = claim.try_get("claimed_generation").map_err(storage_error)?;
            let receipt = LeaseReceipt::new(event_id, consumer, generation)
                .ok_or(ApplicationError::Unavailable)?;
            // Chỉ đọc trường allowlist, không SELECT payload thô; join bằng cả event/consumer/generation vừa claim.
            let row = sqlx::query("SELECT event.workspace_id,event.event_type,event.payload_schema_version,(SELECT count(*) FROM jsonb_object_keys(event.payload)) AS field_count,jsonb_typeof(event.payload->'userId') AS user_type,event.payload->>'userId' AS user_id,jsonb_typeof(event.payload->'sessionId') AS session_type,event.payload->>'sessionId' AS session_id,jsonb_typeof(event.payload->'workspaceId') AS workspace_type,event.payload->>'workspaceId' AS payload_workspace_id,jsonb_typeof(event.payload->'membershipAuthorizationVersion') AS version_type,event.payload->>'membershipAuthorizationVersion' AS authorization_version,consumption.lease_until,consumption.attempt_count FROM public.outbox_events event JOIN public.outbox_consumptions consumption ON consumption.outbox_event_id=event.outbox_event_id WHERE event.outbox_event_id=$1 AND consumption.consumer_code=$2 AND consumption.lease_generation=$3 AND consumption.state='PROCESSING'")
                .bind(event_id).bind(consumer.code()).bind(generation).fetch_one(&mut *transaction).await.map_err(storage_error)?;
            let intent = decode_intent(&row, consumer)?;
            result.push(ClaimedCloseIntent {
                receipt,
                intent,
                lease_until: row.try_get("lease_until").map_err(storage_error)?,
                attempt_count: row.try_get("attempt_count").map_err(storage_error)?,
            });
        }
        transaction.commit().await.map_err(commit_error)?;
        Ok(result)
    }

    /// Native UPDATE kiểm đồng thời state, epoch và clock sau lock; chỉ trả bool khi commit đã xác nhận.
    async fn complete_close_intent(&self, receipt: LeaseReceipt) -> Result<bool, ApplicationError> {
        let mut transaction = self.pool.begin().await.map_err(storage_error)?;
        // Bind receipt không chứa quyền user; DB worker role là boundary riêng, không grant từ request.
        let completed = sqlx::query_scalar("SELECT public.complete_outbox($1,$2,$3)")
            .bind(receipt.event_id())
            .bind(receipt.consumer().code())
            .bind(receipt.generation())
            .fetch_one(&mut *transaction)
            .await
            .map_err(storage_error)?;
        transaction.commit().await.map_err(commit_error)?;
        Ok(completed)
    }

    /// Nhả lease bằng CAS và clock DB, giữ nguyên attempt/generation để stale worker không reset hàng đã takeover.
    async fn retry_close_intent(
        &self,
        receipt: LeaseReceipt,
        delay: RetryDelay,
    ) -> Result<bool, ApplicationError> {
        let mut transaction = self.pool.begin().await.map_err(storage_error)?;
        // Khóa identity trước, rồi statement clock phía dưới mới chạy; UPDATE đơn lẻ có thể xét WHERE trước lúc chờ.
        sqlx::query("SELECT 1 FROM public.outbox_consumptions WHERE outbox_event_id=$1 AND consumer_code=$2 FOR UPDATE")
            .bind(receipt.event_id()).bind(receipt.consumer().code())
            .execute(&mut *transaction).await.map_err(storage_error)?;
        // Delay giây được bind, không nhận timestamp client; lease hết hoặc terminal không được reschedule.
        let changed = sqlx::query("UPDATE public.outbox_consumptions SET state='RETRY_WAIT',available_at=clock_timestamp()+make_interval(secs=>$4),lease_until=NULL WHERE outbox_event_id=$1 AND consumer_code=$2 AND state='PROCESSING' AND lease_generation=$3 AND lease_until>clock_timestamp()")
            .bind(receipt.event_id()).bind(receipt.consumer().code()).bind(receipt.generation()).bind(delay.seconds())
            .execute(&mut *transaction).await.map_err(storage_error)?.rows_affected()==1;
        transaction.commit().await.map_err(commit_error)?;
        Ok(changed)
    }
}

/**
 * Giải mã allowlist và kiểm scope/schema trước khi phát intent; payload không là nguồn authority mở quyền.
 * Input
 * Param: row — projection DB của event immutable vừa claim.
 * Param: consumer — pipeline server đã chọn, quyết định shape exact tương ứng.
 * Output: close intent không JSON/secret; Errors: Unavailable nếu schema/type/scope sai, rollback claim.
 */
fn decode_intent(row: &PgRow, consumer: CloseConsumer) -> Result<CloseIntent, ApplicationError> {
    let schema: i32 = row
        .try_get("payload_schema_version")
        .map_err(storage_error)?;
    let event_type: String = row.try_get("event_type").map_err(storage_error)?;
    let fields: i64 = row.try_get("field_count").map_err(storage_error)?;
    let workspace: Option<Uuid> = row.try_get("workspace_id").map_err(storage_error)?;
    if schema != 1 {
        return Err(ApplicationError::Unavailable);
    }
    let user_id = payload_uuid(row, "user_type", "user_id")?;
    match consumer {
        CloseConsumer::Session
            if event_type == "SESSION_REVOKED" && workspace.is_none() && fields == 2 =>
        {
            Ok(CloseIntent::Session {
                user_id,
                session_id: payload_uuid(row, "session_type", "session_id")?,
            })
        }
        CloseConsumer::Workspace if event_type == "MEMBERSHIP_AUTHORITY_CHANGED" && fields == 3 => {
            let workspace_id = payload_uuid(row, "workspace_type", "payload_workspace_id")?;
            let kind: Option<String> = row.try_get("version_type").map_err(storage_error)?;
            let text: Option<String> = row
                .try_get("authorization_version")
                .map_err(storage_error)?;
            let version = text
                .and_then(|value| value.parse::<i64>().ok())
                .filter(|value| *value > 0);
            if workspace != Some(workspace_id) || kind.as_deref() != Some("number") {
                return Err(ApplicationError::Unavailable);
            }
            Ok(CloseIntent::Workspace {
                workspace_id,
                user_id,
                membership_authorization_version: version.ok_or(ApplicationError::Unavailable)?,
            })
        }
        _ => Err(ApplicationError::Unavailable),
    }
}

/**
 * Chặn JSON scalar sai kiểu/nil để registry không đóng nhầm selector tổng quát.
 * Input
 * Param: row — projection event đang giữ khóa consumption.
 * Param: `type_column` — tên alias SQL literal nội bộ mô tả kiểu JSON.
 * Param: `value_column` — alias SQL literal chứa text UUID, không raw JSON.
 * Output: UUID khác nil; Errors: Unavailable với shape/type/UUID sai.
 */
fn payload_uuid(
    row: &PgRow,
    type_column: &str,
    value_column: &str,
) -> Result<Uuid, ApplicationError> {
    let kind: Option<String> = row.try_get(type_column).map_err(storage_error)?;
    let text: Option<String> = row.try_get(value_column).map_err(storage_error)?;
    if kind.as_deref() != Some("string") {
        return Err(ApplicationError::Unavailable);
    }
    text.and_then(|value| value.parse::<Uuid>().ok())
        .filter(|value| !value.is_nil())
        .ok_or(ApplicationError::Unavailable)
}
