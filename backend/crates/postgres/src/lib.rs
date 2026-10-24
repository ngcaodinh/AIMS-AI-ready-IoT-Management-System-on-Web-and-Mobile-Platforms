//! Adapter PostgreSQL: giữ SQL, MVCC fences và transaction; không sở hữu policy đăng nhập.

mod audit;
mod audit_retention;
mod audit_write;
pub mod connection;
mod device;
mod idempotency;
mod identity;
mod invitation;
mod invitation_management;
mod invitation_receipts;
mod member_creation;
mod member_creation_receipts;
mod membership;
mod membership_effects;
mod observability;
mod outbox;
mod password_reset;
mod preferences;
mod realtime;
mod session;
mod subjects;
mod template;
mod template_draft;
mod template_publish;
mod template_values;
mod template_version;
mod workspace;

use iot_application::error::ApplicationError;
pub use observability::AuditFailureCounts;
use sqlx::{PgPool, Postgres, Transaction};
use std::sync::Arc;

/// Factory unit of work dùng pool được composition root cung cấp, không tự tìm config secret.
#[derive(Clone)]
pub struct PgIdentityStore {
    pool: PgPool,
    audit_failure_counters: Arc<observability::AuditFailureCounters>,
}

impl PgIdentityStore {
    /**
     * Nhận pool đã cấu hình quyền/timeout, không nhận URL secret hoặc đọc `.env`.
     * Input
     * Param: pool — `SQLx` pool thuộc role writer đã được operator giới hạn quyền.
     * Output: adapter cho application ports; không làm I/O lúc dựng.
     */
    #[must_use]
    pub fn new(pool: PgPool) -> Self {
        Self {
            pool,
            audit_failure_counters: Arc::default(),
        }
    }

    /// Trả hai counter không PII để composition/operator quan sát audit sink down; không đọc DB hoặc env.
    #[must_use]
    pub fn failed_audit_counts(&self) -> AuditFailureCounts {
        self.audit_failure_counters.snapshot()
    }
}

/// Handle chỉ adapter thấy `SQLx`; Drop trước commit được `SQLx` rollback, không lộ ra application.
pub struct PgUnitOfWork {
    transaction: Transaction<'static, Postgres>,
}

/**
 * Lọc lỗi storage trước khi qua port; không mang SQL/detail/row chứa verifier lên use case.
 * Input
 * Param: error — lỗi `SQLx` nội bộ; chỉ đọc SQLSTATE và tên constraint cố định.
 * Output: conflict cho uniqueness/serialization/quota/lastAdmin; lỗi còn lại unavailable.
 */
fn storage_error(error: sqlx::Error) -> ApplicationError {
    if let sqlx::Error::Database(database) = error {
        if matches!(
            database.code().as_deref(),
            Some("23505" | "40001" | "40P01")
        ) || matches!(
            database.constraint(),
            Some("ck_workspace_creator_quota" | "ck_workspaces_capable_admin")
        ) {
            return ApplicationError::Conflict;
        }
    }
    ApplicationError::Unavailable
}

/**
 * Phân biệt server xác nhận reject với mất ACK sau COMMIT để không replay một mutation đã thành công.
 * Input
 * Param: error — lỗi ở riêng bước commit, không phải truy vấn thường.
 * Output: lỗi server đã lọc khi kết quả chắc chắn reject; `CommitUnknown` với lỗi transport/protocol.
 */
fn commit_error(error: sqlx::Error) -> ApplicationError {
    if error
        .as_database_error()
        .is_some_and(|database| definite_commit_rejection(database.code().as_deref()))
    {
        storage_error(error)
    } else {
        ApplicationError::CommitUnknown
    }
}

/**
 * Chỉ nhận mã server xác nhận reject đã biết; SQLSTATE08007/40003 và mã lạ giữ outcome UNKNOWN.
 * Input
 * Param: code — SQLSTATE của lỗi COMMIT, None với transport/protocol failure.
 * Output: True khi có thể coi transaction bị reject, không tự suy từ việc có server error.
 */
fn definite_commit_rejection(code: Option<&str>) -> bool {
    matches!(
        code,
        Some(
            "23502" | "23503" | "23505" | "23514" | "40001" | "40P01" | "25P02" | "42501" | "P0001"
        )
    )
}

#[cfg(test)]
mod tests {
    use super::definite_commit_rejection;
    /// Mã unknown do server gửi vẫn không được chuyển thành retryable rejection.
    #[test]
    fn commit_resolution_unknown_is_not_a_definite_rejection() {
        for code in [None, Some("08007"), Some("40003"), Some("XX000")] {
            assert!(!definite_commit_rejection(code));
        }
        for code in ["23514", "23505", "40001", "40P01"] {
            assert!(definite_commit_rejection(Some(code)));
        }
    }
}
