//! Persist credential/revocation intent cùng transaction; không gửi side effect ngoài DB trước commit.

use crate::{PgUnitOfWork, storage_error};
use chrono::{DateTime, Utc};
use iot_application::{
    auth_diagnostics::{AuthTimingSpan, AuthTimingStage},
    error::ApplicationError,
    ports::SessionMutationTransaction,
};
use iot_domain::identity::{LoginWindow, SecretString, SessionProof, SessionRevocation};
use sqlx::Row;
use uuid::Uuid;

impl SessionMutationTransaction for PgUnitOfWork {
    /// Resolve User ID bất biến để chọn limiter trước User lock; quyền được xác minh lại sau khi khóa.
    async fn session_user_id(&mut self, proof: &SessionProof) -> Result<Uuid, ApplicationError> {
        // Token digest được bind; lookup chỉ chọn bucket, còn lock_session xác thực lại User→Session.
        sqlx::query_scalar("SELECT user_id FROM sessions WHERE token_digest=$1")
            .bind(proof.token_digest.as_slice())
            .fetch_optional(&mut *self.transaction)
            .await
            .map_err(storage_error)?
            .ok_or(ApplicationError::SessionInvalid)
    }

    /**
     * Khóa bucket đổi mật khẩu riêng theo User ID trước User→Session fence để chia sẻ giới hạn giữa mọi session.
     * Input
     * Param: user_id — identity nội bộ lấy từ session digest, sau đó được đối chiếu lại dưới khóa.
     * Output: snapshot fixed-window đang giữ khóa đến commit hoặc rollback transaction.
     * Errors: lỗi storage/mapping được lọc thành lỗi persistence chung.
     */
    async fn lock_password_change_bucket(
        &mut self,
        user_id: Uuid,
    ) -> Result<LoginWindow, ApplicationError> {
        let bucket_span =
            AuthTimingSpan::start(self.diagnostics.as_ref(), AuthTimingStage::BucketAcquire);
        // Upsert và FOR UPDATE trên khóa user_id tuần tự hóa cùng account mà không dùng bucket đăng nhập.
        let acquired = async {
            sqlx::query(
                "INSERT INTO password_change_attempt_buckets(user_id) VALUES($1) ON CONFLICT DO NOTHING",
            )
            .bind(user_id)
            .execute(&mut *self.transaction)
            .await
            .map_err(storage_error)?;
            sqlx::query(
                "SELECT failure_count,window_started_at FROM password_change_attempt_buckets WHERE user_id=$1 FOR UPDATE",
            )
            .bind(user_id)
            .fetch_one(&mut *self.transaction)
            .await
            .map_err(storage_error)
        }
        .await;
        if acquired.is_ok() {
            // Giữ cùng định nghĩa thời gian fenced-work như limiter đăng nhập sau khi đã khóa row.
            self.fenced_work = Some(AuthTimingSpan::start(
                self.diagnostics.as_ref(),
                AuthTimingStage::FencedWork,
            ));
        }
        let row = crate::complete_auth_stage(bucket_span, acquired)?;
        Ok(LoginWindow {
            failures: row.try_get("failure_count").map_err(storage_error)?,
            started_at: row.try_get("window_started_at").map_err(storage_error)?,
        })
    }

    /**
     * Lưu fixed-window do application tính trong cùng transaction đang khóa bucket đổi mật khẩu.
     * Input
     * Param: user_id — khóa User ổn định của bucket đã acquire.
     * Param: window — số failure và mốc đầu do LoginWindow.admit quyết định.
     * Output: hoàn tất khi state limiter đã được ghi; schema kiểm tra miền và tính nhất quán.
     * Errors: lỗi storage được lọc thành lỗi persistence chung.
     */
    async fn save_password_change_window(
        &mut self,
        user_id: Uuid,
        window: LoginWindow,
    ) -> Result<(), ApplicationError> {
        // UPDATE bind User ID và ghi count/start cùng lúc để coherence CHECK không thấy state trung gian.
        sqlx::query("UPDATE password_change_attempt_buckets SET failure_count=$2,window_started_at=$3 WHERE user_id=$1")
            .bind(user_id)
            .bind(window.failures)
            .bind(window.started_at)
            .execute(&mut *self.transaction)
            .await
            .map_err(storage_error)?;
        Ok(())
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
