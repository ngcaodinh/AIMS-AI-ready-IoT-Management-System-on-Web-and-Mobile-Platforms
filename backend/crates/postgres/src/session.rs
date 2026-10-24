//! Persist credential/revocation intent cùng transaction; không gửi side effect ngoài DB trước commit.

use crate::{PgUnitOfWork, storage_error};
use chrono::{DateTime, Utc};
use iot_application::{error::ApplicationError, ports::SessionMutationTransaction};
use iot_domain::identity::{SecretString, SessionProof, SessionRevocation};
use sqlx::Row;
use uuid::Uuid;

impl SessionMutationTransaction for PgUnitOfWork {
    /// Lookup email bind digest để application chọn bucket trước User lock; chưa cấp authority.
    async fn session_email(&mut self, proof: &SessionProof) -> Result<String, ApplicationError> {
        sqlx::query_scalar("SELECT account.email_normalized FROM sessions session_row JOIN users account USING(user_id) WHERE session_row.token_digest=$1")
            .bind(proof.token_digest.as_slice()).fetch_optional(&mut *self.transaction).await.map_err(storage_error)?.ok_or(ApplicationError::SessionInvalid)
    }

    /// Thay PHC dưới User fence; first-password-change ghi provenance và activation, không nhận raw password.
    async fn replace_password(
        &mut self,
        user_id: Uuid,
        verifier: &SecretString,
        activated_at: DateTime<Utc>,
    ) -> Result<(), ApplicationError> {
        // CASE đọc giá trị OLD của UPDATE: chỉ ghi activation cho account đang must-change chưa activated.
        sqlx::query("UPDATE users SET password_hash=$2,activated_at=CASE WHEN must_change_password THEN coalesce(activated_at,$3) ELSE activated_at END,activation_provenance=CASE WHEN must_change_password AND activated_at IS NULL THEN 'SELF_PASSWORD_CHANGE' ELSE activation_provenance END,must_change_password=false WHERE user_id=$1")
            .bind(user_id).bind(verifier.expose()).bind(activated_at).execute(&mut *self.transaction).await.map_err(storage_error)?;
        Ok(())
    }

    /// Revoke sessions/tickets và CAS installation binding rồi ghi close outbox trong cùng unit of work.
    async fn revoke_capabilities(
        &mut self,
        scope: SessionRevocation,
        now: DateTime<Utc>,
    ) -> Result<usize, ApplicationError> {
        let (user_id, session_id) = match scope {
            SessionRevocation::Current {
                user_id,
                session_id,
            } => (user_id, Some(session_id)),
            SessionRevocation::AllForUser { user_id } => (user_id, None),
        };
        // User đã khóa ở resolver; khóa session theo UUID để protocol thống nhất với batch revoke khác.
        sqlx::query("SELECT session_id FROM sessions WHERE user_id=$1 AND ($2::uuid IS NULL OR session_id=$2) ORDER BY session_id FOR UPDATE")
            .bind(user_id).bind(session_id).fetch_all(&mut *self.transaction).await.map_err(storage_error)?;
        let rows=sqlx::query("UPDATE sessions SET revoked_at=$3 WHERE user_id=$1 AND ($2::uuid IS NULL OR session_id=$2) AND revoked_at IS NULL RETURNING session_id")
            .bind(user_id).bind(session_id).bind(now).fetch_all(&mut *self.transaction).await.map_err(storage_error)?;
        let changed = rows.len();
        let mut sessions = Vec::<Uuid>::with_capacity(changed);
        for row in rows {
            sessions.push(row.try_get("session_id").map_err(storage_error)?);
        }
        if sessions.is_empty() {
            return Ok(0);
        }
        // Binding CAS theo cả User+Session để logout S1 không tháo installation vừa rebind sang S2.
        sqlx::query("UPDATE push_installations SET active_user_id=NULL,active_session_id=NULL,enabled=false,binding_generation=binding_generation+1,updated_at=$3 WHERE active_user_id=$1 AND active_session_id=ANY($2)")
            .bind(user_id).bind(&sessions).bind(now).execute(&mut *self.transaction).await.map_err(storage_error)?;
        sqlx::query("UPDATE websocket_tickets SET revoked_at=$3 WHERE user_id=$1 AND session_id=ANY($2) AND revoked_at IS NULL")
            .bind(user_id).bind(&sessions).bind(now).execute(&mut *self.transaction).await.map_err(storage_error)?;
        for session in sessions {
            let event_id = Uuid::new_v4();
            // Chỉ identity không secret vào payload; global event-key unique giúp worker retry không nhân đôi intent.
            sqlx::query("INSERT INTO outbox_events(outbox_event_id,event_key,event_type,payload_schema_version,payload,created_at) VALUES($1,$2,'SESSION_REVOKED',1,jsonb_build_object('sessionId',$3::uuid::text,'userId',$4::uuid::text),$5)")
                .bind(event_id).bind(format!("session-revoked:{session}")).bind(session).bind(user_id).bind(now)
                .execute(&mut *self.transaction).await.map_err(storage_error)?;
            sqlx::query("INSERT INTO outbox_consumptions(outbox_event_id,consumer_code,available_at) VALUES($1,'REALTIME_SESSION_CLOSE',$2)")
                .bind(event_id).bind(now).execute(&mut *self.transaction).await.map_err(storage_error)?;
        }
        Ok(changed)
    }
}
