//! SQL IAM có bind tham số; khóa và clock lấy sau khóa thuộc trách nhiệm adapter.

use crate::{PgIdentityStore, PgUnitOfWork, commit_error, storage_error};
use chrono::{DateTime, Utc};
use iot_application::{
    error::ApplicationError,
    ports::{IdentityStore, IdentityTransaction, LockedSession},
};
use iot_domain::identity::{
    AccountSnapshot, AccountStatus, AuditRecord, ClientType, LoginWindow, NewSession, SecretString,
    SessionProof, SessionSnapshot,
};
use sqlx::{Row, postgres::PgRow};
use uuid::Uuid;

/**
 * Decode enum client hữu hạn; dữ liệu không đúng schema phải fail closed thay vì coi như App.
 * Input
 * Param: value — text lấy từ PostgreSQL session, không phải input HTTP.
 * Output: loại client hoặc unavailable nếu enum storage không hợp lệ.
 */
fn parse_client(value: &str) -> Result<ClientType, ApplicationError> {
    match value {
        "WEB" => Ok(ClientType::Web),
        "ANDROID" => Ok(ClientType::Android),
        _ => Err(ApplicationError::Unavailable),
    }
}

/// Ánh xạ enum domain sang literal bind của schema, không nối vào câu SQL.
pub(crate) fn client_value(client: ClientType) -> &'static str {
    match client {
        ClientType::Web => "WEB",
        ClientType::Android => "ANDROID",
    }
}

/**
 * Decode account không đưa `PgRow` qua port hoặc lộ verifier trong lỗi.
 * Input
 * Param: row — hàng đọc dưới User fence, gồm credential và trạng thái hiện hành.
 * Output: snapshot domain hoặc lỗi mapping đã lọc.
 */
fn account_snapshot(row: &PgRow) -> Result<AccountSnapshot, ApplicationError> {
    let status: String = row.try_get("account_status").map_err(storage_error)?;
    Ok(AccountSnapshot {
        user_id: row.try_get("user_id").map_err(storage_error)?,
        password_verifier: SecretString::new(row.try_get("password_hash").map_err(storage_error)?),
        status: match status.as_str() {
            "ACTIVE" => AccountStatus::Active,
            "DISABLED" => AccountStatus::Disabled,
            _ => return Err(ApplicationError::Unavailable),
        },
        must_change_password: row.try_get("must_change_password").map_err(storage_error)?,
    })
}

impl IdentityStore for PgIdentityStore {
    type Transaction = PgUnitOfWork;

    /// Đếm degraded failure-audit độc lập DB, không label theo identity hoặc thực hiện I/O khi sink hỏng.
    fn observe_failed_audit(&self, kind: iot_domain::audit_write::FailureAuditKind) {
        self.audit_failure_counters.increment(kind);
    }

    /// Bắt đầu transaction thật trên pool; application chỉ giữ handle của port, không biết `SQLx`.
    async fn begin(&self) -> Result<PgUnitOfWork, ApplicationError> {
        Ok(PgUnitOfWork {
            transaction: self.pool.begin().await.map_err(storage_error)?,
        })
    }

    /// Ghi failure audit bằng transaction riêng sau limiter commit; lỗi không tác động counter đã lưu.
    async fn record_failed_login(&self, audit: AuditRecord) -> Result<(), ApplicationError> {
        let mut unit = self.begin().await?;
        unit.append_audit(audit).await?;
        unit.commit().await
    }
}

impl IdentityTransaction for PgUnitOfWork {
    /// Upsert rồi khóa bucket bind digest; clock riêng sau FOR UPDATE tránh thời gian cũ khi chờ fence.
    async fn lock_login_bucket(
        &mut self,
        digest: [u8; 32],
    ) -> Result<(LoginWindow, DateTime<Utc>), ApplicationError> {
        // ON CONFLICT cùng row identity serialize email chưa có User trên nhiều instance.
        sqlx::query(
            "INSERT INTO login_attempt_buckets(email_digest) VALUES($1) ON CONFLICT DO NOTHING",
        )
        .bind(digest.as_slice())
        .execute(&mut *self.transaction)
        .await
        .map_err(storage_error)?;
        let row=sqlx::query("SELECT failure_count,window_started_at FROM login_attempt_buckets WHERE email_digest=$1 FOR UPDATE")
            .bind(digest.as_slice()).fetch_one(&mut *self.transaction).await.map_err(storage_error)?;
        let now = sqlx::query_scalar("SELECT clock_timestamp()")
            .fetch_one(&mut *self.transaction)
            .await
            .map_err(storage_error)?;
        Ok((
            LoginWindow {
                failures: row.try_get("failure_count").map_err(storage_error)?,
                started_at: row.try_get("window_started_at").map_err(storage_error)?,
            },
            now,
        ))
    }

    /// Khóa User theo email đã normalize sau bucket; input luôn bind để không thể chèn SQL.
    async fn lock_account(
        &mut self,
        email: &str,
    ) -> Result<Option<AccountSnapshot>, ApplicationError> {
        let row=sqlx::query("SELECT user_id,password_hash,account_status,must_change_password FROM users WHERE email_normalized=$1 FOR UPDATE")
            .bind(email).fetch_optional(&mut *self.transaction).await.map_err(storage_error)?;
        row.as_ref().map(account_snapshot).transpose()
    }

    /// Lưu đúng cửa sổ domain đã tính dưới cùng khóa; không tự reset counter vì login success.
    async fn save_login_window(
        &mut self,
        digest: [u8; 32],
        window: LoginWindow,
    ) -> Result<(), ApplicationError> {
        // Count và start cùng UPDATE để coherence CHECK không quan sát trạng thái trung gian.
        sqlx::query("UPDATE login_attempt_buckets SET failure_count=$2,window_started_at=$3 WHERE email_digest=$1")
            .bind(digest.as_slice()).bind(window.failures).bind(window.started_at).execute(&mut *self.transaction).await.map_err(storage_error)?;
        Ok(())
    }

    /// Chỉ bind digest và thời điểm do application quyết định; schema kiểm TTL và identity lần nữa.
    async fn insert_session(&mut self, session: &NewSession) -> Result<(), ApplicationError> {
        sqlx::query("INSERT INTO sessions(session_id,user_id,token_digest,auth_context_id,limited,client_type,issued_at,expires_at) VALUES($1,$2,$3,$4,$5,$6,$7,$8)")
            .bind(session.session_id).bind(session.user_id).bind(session.token_digest.as_slice()).bind(session.auth_context_id).bind(session.limited)
            .bind(client_value(session.client_type)).bind(session.issued_at).bind(session.expires_at).execute(&mut *self.transaction).await.map_err(storage_error)?;
        Ok(())
    }

    /// Resolve identity rồi khóa User→Session; chỉ trả snapshot, domain quyết định quyền/context/limited.
    async fn lock_session(
        &mut self,
        proof: &SessionProof,
    ) -> Result<LockedSession, ApplicationError> {
        // Lookup đầu không cấp authority; đọc lại toàn bộ trạng thái sau khóa để tránh TOCTOU.
        let user_id: Uuid =
            sqlx::query_scalar("SELECT user_id FROM sessions WHERE token_digest=$1")
                .bind(proof.token_digest.as_slice())
                .fetch_optional(&mut *self.transaction)
                .await
                .map_err(storage_error)?
                .ok_or(ApplicationError::SessionInvalid)?;
        let account=sqlx::query("SELECT user_id,password_hash,account_status,must_change_password FROM users WHERE user_id=$1 FOR UPDATE")
            .bind(user_id).fetch_one(&mut *self.transaction).await.map_err(storage_error)?;
        let session=sqlx::query("SELECT session_id,user_id,auth_context_id,limited,client_type,revoked_at,expires_at FROM sessions WHERE token_digest=$1 AND user_id=$2 FOR UPDATE")
            .bind(proof.token_digest.as_slice()).bind(user_id).fetch_one(&mut *self.transaction).await.map_err(storage_error)?;
        // SELECT expression có thể chạy trước khi nhận row lock; clock phải là statement riêng sau FOR UPDATE.
        let observed_at = sqlx::query_scalar("SELECT clock_timestamp()")
            .fetch_one(&mut *self.transaction)
            .await
            .map_err(storage_error)?;
        Ok(LockedSession {
            account: account_snapshot(&account)?,
            session: SessionSnapshot {
                session_id: session.try_get("session_id").map_err(storage_error)?,
                user_id: session.try_get("user_id").map_err(storage_error)?,
                auth_context_id: session.try_get("auth_context_id").map_err(storage_error)?,
                client_type: parse_client(
                    &session
                        .try_get::<String, _>("client_type")
                        .map_err(storage_error)?,
                )?,
                limited: session.try_get("limited").map_err(storage_error)?,
                expires_at: session.try_get("expires_at").map_err(storage_error)?,
                revoked_at: session.try_get("revoked_at").map_err(storage_error)?,
            },
            observed_at,
        })
    }

    /// Bind audit typed cùng mutation; resource chỉ snapshot, metadata hữu hạn và lỗi insert rollback unit of work.
    async fn append_audit(&mut self, audit: AuditRecord) -> Result<(), ApplicationError> {
        // Manifest chặn caller vô tình đưa audit credential global vào route đọc Admin của tenant.
        if audit.workspace_id.is_some() != audit.detail.is_workspace_scoped() {
            return Err(ApplicationError::Unavailable);
        }
        // Manifest hiện chỉ anonymous failed login hoặc user đã xác thực; SYSTEM/API_KEY cần variant riêng khi build.
        if audit.actor_user_id.is_none()
            != matches!(
                &audit.detail,
                iot_domain::audit_write::AuditDetail::LoginFailed
            )
        {
            return Err(ApplicationError::Unavailable);
        }
        let resource = audit.detail.resource();
        let metadata =
            crate::audit_write::redacted_metadata(&audit.detail, audit.actor_user_id.is_some());
        // Tất cả giá trị đều bind; ::jsonb kiểm encoding từ writer hữu hạn, không nhận raw request JSON.
        sqlx::query("INSERT INTO audit_events(audit_event_id,workspace_id,actor_user_id,session_id,event_type,outcome,correlation_id,client_type,resource_type,resource_id,reason_code,redacted_diff) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12::jsonb)")
            .bind(Uuid::new_v4()).bind(audit.workspace_id).bind(audit.actor_user_id).bind(audit.session_id).bind(audit.detail.event_type())
            .bind(audit.detail.outcome()).bind(audit.correlation_id).bind(client_value(audit.client_type))
            .bind(resource.map(|(kind, _)|kind)).bind(resource.map(|(_,id)|id.to_string()))
            .bind(audit.detail.reason_code()).bind(metadata)
            .execute(&mut *self.transaction).await.map_err(storage_error)?;
        Ok(())
    }

    /// Commit vật lý chỉ tại port terminal; phân loại reject chắc chắn khác mất ACK chưa rõ outcome.
    async fn commit(self) -> Result<(), ApplicationError> {
        self.transaction.commit().await.map_err(commit_error)
    }
}
