//! Receipt atomic cho workspace create; global namespace không dùng workspace NULL trong composite key.

use crate::{PgUnitOfWork, storage_error};
use chrono::{DateTime, Utc};
use iot_application::{
    error::ApplicationError,
    ports::{WorkspaceCreationClaim, WorkspaceCreationTransaction},
};
use sqlx::Row;
use uuid::Uuid;

impl WorkspaceCreationTransaction for PgUnitOfWork {
    /// Reserve receipt dưới User fence đã giữ; expiry chỉ xóa đúng User/route/key trước insert mới.
    async fn reserve_workspace_creation(
        &mut self,
        user_id: Uuid,
        key_digest: [u8; 32],
        request_digest: [u8; 32],
        now: DateTime<Utc>,
    ) -> Result<WorkspaceCreationClaim, ApplicationError> {
        // TTL24h theo contract; User fence serialize cả quota và retry, không chia check/act qua pool query.
        sqlx::query("DELETE FROM global_idempotency_records WHERE user_id=$1 AND route_key='WORKSPACE_CREATE_V1' AND key_digest=$2 AND expires_at<=$3")
            .bind(user_id).bind(key_digest.as_slice()).bind(now).execute(&mut *self.transaction).await.map_err(storage_error)?;
        let inserted=sqlx::query("INSERT INTO global_idempotency_records(user_id,route_key,key_digest,request_digest,admitted_at,expires_at,state) VALUES($1,'WORKSPACE_CREATE_V1',$2,$3,$4,$4+interval '24 hours','IN_PROGRESS') ON CONFLICT DO NOTHING")
            .bind(user_id).bind(key_digest.as_slice()).bind(request_digest.as_slice()).bind(now).execute(&mut *self.transaction).await.map_err(storage_error)?.rows_affected();
        if inserted == 1 {
            return Ok(WorkspaceCreationClaim::Reserved);
        }
        let row=sqlx::query("SELECT request_digest,state,response_status,sanitized_result->>'workspaceId' AS workspace_id FROM global_idempotency_records WHERE user_id=$1 AND route_key='WORKSPACE_CREATE_V1' AND key_digest=$2 FOR UPDATE")
            .bind(user_id).bind(key_digest.as_slice()).fetch_one(&mut *self.transaction).await.map_err(storage_error)?;
        let digest: Vec<u8> = row.try_get("request_digest").map_err(storage_error)?;
        let state: String = row.try_get("state").map_err(storage_error)?;
        let workspace_id = match state.as_str() {
            "IN_PROGRESS" => None,
            "COMPLETED" => {
                if row
                    .try_get::<Option<i32>, _>("response_status")
                    .map_err(storage_error)?
                    != Some(201)
                {
                    return Err(ApplicationError::Unavailable);
                }
                let value: String = row.try_get("workspace_id").map_err(storage_error)?;
                Some(Uuid::parse_str(&value).map_err(|_| ApplicationError::Unavailable)?)
            }
            _ => return Err(ApplicationError::Unavailable),
        };
        Ok(WorkspaceCreationClaim::Existing {
            request_digest: digest
                .try_into()
                .map_err(|_| ApplicationError::Unavailable)?,
            workspace_id,
        })
    }
    /// Complete receipt chỉ khi còn `IN_PROGRESS` của đúng actor/route/key, cùng commit với aggregate/audit.
    async fn complete_workspace_creation(
        &mut self,
        user_id: Uuid,
        key_digest: [u8; 32],
        workspace_id: Uuid,
    ) -> Result<(), ApplicationError> {
        let changed=sqlx::query("UPDATE global_idempotency_records SET state='COMPLETED',response_status=201,sanitized_result=jsonb_build_object('workspaceId',$3::uuid::text) WHERE user_id=$1 AND route_key='WORKSPACE_CREATE_V1' AND key_digest=$2 AND state='IN_PROGRESS'")
            .bind(user_id).bind(key_digest.as_slice()).bind(workspace_id).execute(&mut *self.transaction).await.map_err(storage_error)?.rows_affected();
        if changed != 1 {
            return Err(ApplicationError::Conflict);
        }
        Ok(())
    }
}
