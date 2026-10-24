//! Receipt lời mời tách namespace global/scoped, chỉ lưu projection không chứa capability.

use crate::{PgUnitOfWork, storage_error};
use chrono::{DateTime, Utc};
use iot_application::{
    error::ApplicationError,
    invitation_ports::{InvitationClaim, InvitationReceipt, InvitationReceiptScope},
};
use sqlx::Row;
use uuid::Uuid;

impl PgUnitOfWork {
    /**
     * Reserve receipt dưới User/Workspace fences đã giữ, thay hàng hết hạn đúng namespace.
     * Input
     * Param: scope — route create scoped hoặc accept global do use case cố định.
     * Param: `actor_id` — account đã xác thực trong transaction.
     * Param: `key_digest` — digest intent key, không có raw key.
     * Param: `request_digest` — fingerprint body để chặn retry khác intent.
     * Param: now — clock admission đã lấy sau khóa.
     * Output: reserved hoặc receipt hiện hành đã decode allowlist; lỗi shape fail closed.
     */
    pub(crate) async fn reserve_invitation(
        &mut self,
        scope: InvitationReceiptScope,
        actor_id: Uuid,
        key_digest: [u8; 32],
        request_digest: [u8; 32],
        now: DateTime<Utc>,
    ) -> Result<InvitationClaim, ApplicationError> {
        // Các câu SQL là literal cố định theo enum; toàn bộ identity/digest/time đều bind.
        let (inserted, row) = match scope {
            InvitationReceiptScope::Create(workspace_id) => {
                sqlx::query("DELETE FROM workspace_idempotency_records WHERE workspace_id=$1 AND user_id=$2 AND route_key='INVITATION_CREATE_V1' AND key_digest=$3 AND expires_at<=$4")
                    .bind(workspace_id).bind(actor_id).bind(key_digest.as_slice()).bind(now).execute(&mut *self.transaction).await.map_err(storage_error)?;
                let count=sqlx::query("INSERT INTO workspace_idempotency_records(workspace_id,idempotency_record_id,user_id,route_key,key_digest,request_digest,admitted_at,expires_at,state) VALUES($1,$2,$3,'INVITATION_CREATE_V1',$4,$5,$6,$6+interval '24 hours','IN_PROGRESS') ON CONFLICT DO NOTHING")
                    .bind(workspace_id).bind(Uuid::new_v4()).bind(actor_id).bind(key_digest.as_slice()).bind(request_digest.as_slice()).bind(now).execute(&mut *self.transaction).await.map_err(storage_error)?.rows_affected();
                let row = if count == 0 {
                    Some(sqlx::query("SELECT request_digest,state,response_status,sanitized_result->>'workspaceId' AS workspace_id,sanitized_result->>'invitationId' AS invitation_id,sanitized_result->>'grantGeneration' AS grant_generation FROM workspace_idempotency_records WHERE workspace_id=$1 AND user_id=$2 AND route_key='INVITATION_CREATE_V1' AND key_digest=$3 FOR UPDATE")
                    .bind(workspace_id).bind(actor_id).bind(key_digest.as_slice()).fetch_one(&mut *self.transaction).await.map_err(storage_error)?)
                } else {
                    None
                };
                (count, row)
            }
            InvitationReceiptScope::Accept => {
                sqlx::query("DELETE FROM global_idempotency_records WHERE user_id=$1 AND route_key='INVITATION_ACCEPT_V1' AND key_digest=$2 AND expires_at<=$3")
                    .bind(actor_id).bind(key_digest.as_slice()).bind(now).execute(&mut *self.transaction).await.map_err(storage_error)?;
                let count=sqlx::query("INSERT INTO global_idempotency_records(user_id,route_key,key_digest,request_digest,admitted_at,expires_at,state) VALUES($1,'INVITATION_ACCEPT_V1',$2,$3,$4,$4+interval '24 hours','IN_PROGRESS') ON CONFLICT DO NOTHING")
                    .bind(actor_id).bind(key_digest.as_slice()).bind(request_digest.as_slice()).bind(now).execute(&mut *self.transaction).await.map_err(storage_error)?.rows_affected();
                let row = if count == 0 {
                    Some(sqlx::query("SELECT request_digest,state,response_status,sanitized_result->>'workspaceId' AS workspace_id,sanitized_result->>'invitationId' AS invitation_id,sanitized_result->>'grantGeneration' AS grant_generation FROM global_idempotency_records WHERE user_id=$1 AND route_key='INVITATION_ACCEPT_V1' AND key_digest=$2 FOR UPDATE")
                    .bind(actor_id).bind(key_digest.as_slice()).fetch_one(&mut *self.transaction).await.map_err(storage_error)?)
                } else {
                    None
                };
                (count, row)
            }
        };
        if inserted == 1 {
            return Ok(InvitationClaim::Reserved);
        }
        let row = row.ok_or(ApplicationError::Unavailable)?;
        let digest: Vec<u8> = row.try_get("request_digest").map_err(storage_error)?;
        let state: String = row.try_get("state").map_err(storage_error)?;
        let result = match state.as_str() {
            "IN_PROGRESS" => None,
            "COMPLETED" => {
                let expected_status = match scope {
                    InvitationReceiptScope::Create(_) => 201,
                    InvitationReceiptScope::Accept => 200,
                };
                if row
                    .try_get::<Option<i32>, _>("response_status")
                    .map_err(storage_error)?
                    != Some(expected_status)
                {
                    return Err(ApplicationError::Unavailable);
                }
                let workspace: String = row.try_get("workspace_id").map_err(storage_error)?;
                let invitation: String = row.try_get("invitation_id").map_err(storage_error)?;
                let generation: Option<String> =
                    row.try_get("grant_generation").map_err(storage_error)?;
                Some(InvitationReceipt {
                    workspace_id: Uuid::parse_str(&workspace)
                        .map_err(|_| ApplicationError::Unavailable)?,
                    invitation_id: Uuid::parse_str(&invitation)
                        .map_err(|_| ApplicationError::Unavailable)?,
                    grant_generation: generation
                        .map(|value| {
                            value
                                .parse::<i64>()
                                .map_err(|_| ApplicationError::Unavailable)
                        })
                        .transpose()?,
                })
            }
            _ => return Err(ApplicationError::Unavailable),
        };
        Ok(InvitationClaim::Existing {
            request_digest: digest
                .try_into()
                .map_err(|_| ApplicationError::Unavailable)?,
            result,
        })
    }

    /**
     * Chốt receipt sau mutation/audit trong cùng transaction, chỉ dùng UUID/generation allowlist.
     * Input
     * Param: scope — namespace cùng bước reserve, không tự chuyển namespace khi conflict.
     * Param: `actor_id` — account sở hữu intent.
     * Param: `key_digest` — digest cùng key đã reserve.
     * Param: result — projection không token/email/password.
     * Output: hoàn thành hoặc conflict nếu receipt không còn pending.
     */
    pub(crate) async fn complete_invitation(
        &mut self,
        scope: InvitationReceiptScope,
        actor_id: Uuid,
        key_digest: [u8; 32],
        result: &InvitationReceipt,
    ) -> Result<(), ApplicationError> {
        // Không nhận raw response JSON; query chỉ dựng đúng ba trường không secret.
        let changed=match scope {
            InvitationReceiptScope::Create(workspace_id)=>sqlx::query("UPDATE workspace_idempotency_records SET state='COMPLETED',response_status=201,sanitized_result=jsonb_build_object('workspaceId',$4::uuid::text,'invitationId',$5::uuid::text) WHERE workspace_id=$1 AND user_id=$2 AND route_key='INVITATION_CREATE_V1' AND key_digest=$3 AND state='IN_PROGRESS'")
                .bind(workspace_id).bind(actor_id).bind(key_digest.as_slice()).bind(result.workspace_id).bind(result.invitation_id).execute(&mut *self.transaction).await.map_err(storage_error)?.rows_affected(),
            InvitationReceiptScope::Accept=>sqlx::query("UPDATE global_idempotency_records SET state='COMPLETED',response_status=200,sanitized_result=jsonb_build_object('workspaceId',$3::uuid::text,'invitationId',$4::uuid::text,'grantGeneration',$5::bigint) WHERE user_id=$1 AND route_key='INVITATION_ACCEPT_V1' AND key_digest=$2 AND state='IN_PROGRESS'")
                .bind(actor_id).bind(key_digest.as_slice()).bind(result.workspace_id).bind(result.invitation_id).bind(result.grant_generation).execute(&mut *self.transaction).await.map_err(storage_error)?.rows_affected(),
        };
        if changed != 1 {
            return Err(ApplicationError::Conflict);
        }
        Ok(())
    }
}
