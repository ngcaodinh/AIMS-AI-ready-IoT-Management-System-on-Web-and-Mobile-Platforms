//! Receipt tạo member dùng bảng scoped hiện hành; không lưu mật khẩu/token hoặc hồ sơ.

use crate::{PgUnitOfWork, storage_error};
use chrono::{DateTime, Utc};
use iot_application::{
    error::ApplicationError,
    member_creation_ports::{MemberCreationClaim, MemberCreationReceiptKey},
};
use iot_domain::member_creation::MemberCreationOutcome;
use sqlx::Row;
use uuid::Uuid;

impl PgUnitOfWork {
    /**
     * Reserve intent24h dưới current User/Workspace locks, decode projection khi replay.
     * Input
     * Param: key — tenant/actor/digest thuộc principal đã authorize.
     * Param: `request_digest` — hash raw request để khác body bị Conflict ở application.
     * Param: now — admission clock sau khóa; chỉ xóa receipt đúng key đã hết hạn.
     * Output: Reserved hoặc snapshot result không secret; storage/shape lỗi fail closed.
     */
    pub(crate) async fn reserve_member_creation_receipt(
        &mut self,
        key: MemberCreationReceiptKey,
        request_digest: [u8; 32],
        now: DateTime<Utc>,
    ) -> Result<MemberCreationClaim, ApplicationError> {
        // Mọi selector/value bind; route namespace là literal application-owned, không nội suy input.
        sqlx::query("DELETE FROM workspace_idempotency_records WHERE workspace_id=$1 AND user_id=$2 AND route_key='MEMBER_CREATE_V1' AND key_digest=$3 AND expires_at<=$4").bind(key.workspace_id).bind(key.actor_id).bind(key.key_digest.as_slice()).bind(now).execute(&mut *self.transaction).await.map_err(storage_error)?;
        let inserted=sqlx::query("INSERT INTO workspace_idempotency_records(workspace_id,idempotency_record_id,user_id,route_key,key_digest,request_digest,admitted_at,expires_at,state) VALUES($1,$2,$3,'MEMBER_CREATE_V1',$4,$5,$6,$6+interval '24 hours','IN_PROGRESS') ON CONFLICT DO NOTHING").bind(key.workspace_id).bind(Uuid::new_v4()).bind(key.actor_id).bind(key.key_digest.as_slice()).bind(request_digest.as_slice()).bind(now).execute(&mut *self.transaction).await.map_err(storage_error)?.rows_affected();
        if inserted == 1 {
            return Ok(MemberCreationClaim::Reserved);
        }
        let row=sqlx::query("SELECT request_digest,state,response_status,sanitized_result->>'kind' AS kind,sanitized_result->>'resourceId' AS resource_id,(sanitized_result->>'expiresAt')::timestamptz AS expires_at FROM workspace_idempotency_records WHERE workspace_id=$1 AND user_id=$2 AND route_key='MEMBER_CREATE_V1' AND key_digest=$3 FOR UPDATE").bind(key.workspace_id).bind(key.actor_id).bind(key.key_digest.as_slice()).fetch_one(&mut *self.transaction).await.map_err(storage_error)?;
        let outcome = match row
            .try_get::<String, _>("state")
            .map_err(storage_error)?
            .as_str()
        {
            "IN_PROGRESS" => None,
            "COMPLETED" => {
                let id = Uuid::parse_str(
                    &row.try_get::<String, _>("resource_id")
                        .map_err(storage_error)?,
                )
                .map_err(|_| ApplicationError::Unavailable)?;
                let status: Option<i32> = row.try_get("response_status").map_err(storage_error)?;
                let expires: Option<DateTime<Utc>> =
                    row.try_get("expires_at").map_err(storage_error)?;
                Some(
                    match (
                        row.try_get::<String, _>("kind")
                            .map_err(storage_error)?
                            .as_str(),
                        status,
                        expires,
                    ) {
                        ("CREATED", Some(201), None) => {
                            MemberCreationOutcome::Created { user_id: id }
                        }
                        ("INVITATION", Some(202), Some(expires_at)) => {
                            MemberCreationOutcome::Invitation {
                                invitation_id: id,
                                expires_at,
                            }
                        }
                        _ => return Err(ApplicationError::Unavailable),
                    },
                )
            }
            _ => return Err(ApplicationError::Unavailable),
        };
        let digest: Vec<u8> = row.try_get("request_digest").map_err(storage_error)?;
        Ok(MemberCreationClaim::Existing {
            request_digest: digest
                .try_into()
                .map_err(|_| ApplicationError::Unavailable)?,
            outcome,
        })
    }

    /**
     * Complete receipt với projection typed, cùng commit graph và required audit.
     * Input
     * Param: key — selector cùng bước reserve, không nhận route tùy ý.
     * Param: outcome — loại resource/UUID/expiry; không chứa raw secret hoặc alias/email.
     * Output: hoàn tất hoặc Conflict; mất ACK commit do lớp transaction phân loại.
     */
    pub(crate) async fn complete_member_creation_receipt(
        &mut self,
        key: MemberCreationReceiptKey,
        outcome: &MemberCreationOutcome,
    ) -> Result<(), ApplicationError> {
        let (kind, id, status, expires) = match outcome {
            MemberCreationOutcome::Created { user_id } => ("CREATED", *user_id, 201, None),
            MemberCreationOutcome::Invitation {
                invitation_id,
                expires_at,
            } => ("INVITATION", *invitation_id, 202, Some(*expires_at)),
        };
        // JSON chỉ có literal enum/UUID/clock; jsonb_strip_nulls bỏ expiry không áp dụng cho account.
        let changed=sqlx::query("UPDATE workspace_idempotency_records SET state='COMPLETED',response_status=$4,sanitized_result=jsonb_strip_nulls(jsonb_build_object('kind',$5::text,'resourceId',$6::uuid::text,'expiresAt',$7::timestamptz)) WHERE workspace_id=$1 AND user_id=$2 AND route_key='MEMBER_CREATE_V1' AND key_digest=$3 AND state='IN_PROGRESS'").bind(key.workspace_id).bind(key.actor_id).bind(key.key_digest.as_slice()).bind(status).bind(kind).bind(id).bind(expires).execute(&mut *self.transaction).await.map_err(storage_error)?.rows_affected();
        if changed != 1 {
            return Err(ApplicationError::Conflict);
        }
        Ok(())
    }
}
