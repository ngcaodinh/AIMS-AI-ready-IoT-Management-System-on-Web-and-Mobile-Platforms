//! Adapter PostgreSQL: giữ SQL, MVCC fences và transaction; không sở hữu policy đăng nhập.

mod audit;
mod audit_retention;
mod audit_write;
mod auth_read;
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

use iot_application::{
    auth_diagnostics::{AuthDiagnostics, AuthTimingOutcome, AuthTimingSpan},
    error::ApplicationError,
};
pub use observability::AuditFailureCounts;
use sqlx::{PgPool, Postgres, Transaction};
use std::sync::Arc;

/// Factory unit of work dùng pool được composition root cung cấp, không tự tìm config secret.
#[derive(Clone)]
pub struct PgIdentityStore {
    pool: PgPool,
    audit_failure_counters: Arc<observability::AuditFailureCounters>,
    diagnostics: Option<Arc<dyn AuthDiagnostics>>,
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
            diagnostics: None,
        }
    }

    /**
     * Nhận sink tùy chọn từ composition để đo auth, không đổi pool hoặc quyền DB đã cấp.
     * Input
     * Param: `diagnostics` — observer chỉ nhận enum/duration, không nhận identity, SQL hoặc error thô.
     * Output: store giữ chung sink qua clone; constructor mặc định vẫn disabled.
     */
    #[must_use]
    pub fn with_diagnostics(mut self, diagnostics: Arc<dyn AuthDiagnostics>) -> Self {
        self.diagnostics = Some(diagnostics);
        self
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
    diagnostics: Option<Arc<dyn AuthDiagnostics>>,
    // Guard kết thúc trước commit chỉ ghi Abandoned; không xác nhận server đã xử lý rollback/nhả lock.
    fenced_work: Option<AuthTimingSpan>,
}

/**
 * Hoàn tất stage theo Result quan sát được và giữ nguyên lỗi nghiệp vụ, kể cả `CommitUnknown`.
 * Input
 * Param: `span` — guard đang giữ chỗ của chính stage vừa kết thúc.
 * Param: `result` — kết quả đã lọc lỗi ở boundary hiện có, không được sửa bởi telemetry.
 * Output: nguyên Result đầu vào; callback chỉ ghi Completed hoặc Error, không authority auth.
 * # Errors
 * Trả nguyên lỗi đầu vào, không phân loại UNKNOWN thành rejection hoặc retryable.
 */
fn complete_auth_stage<T>(
    span: AuthTimingSpan,
    result: Result<T, ApplicationError>,
) -> Result<T, ApplicationError> {
    span.finish(if result.is_ok() {
        AuthTimingOutcome::Completed
    } else {
        AuthTimingOutcome::Error
    });
    result
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
    use iot_application::auth_diagnostics::{AuthDiagnostics, AuthTimingOutcome, AuthTimingStage};
    use std::{
        process::{Child, Command, Stdio},
        sync::{Arc, Mutex},
        time::{Duration, Instant},
    };

    /// Observer test chỉ giữ stage/outcome để phát hiện finish thiếu, trùng hoặc phân loại UNKNOWN sai.
    #[derive(Default)]
    struct TestDiagnostics(Mutex<Vec<(AuthTimingStage, AuthTimingOutcome)>>);

    /// Handle test con do đúng test này tạo; cả panic/timeout đều phải thu hồi tiến trình trước khi thoát.
    struct OwnedTestChild(Child);

    impl Drop for OwnedTestChild {
        /// Dừng và reap đúng owned handle; không tra process toàn máy hoặc kill PID lấy từ metadata.
        fn drop(&mut self) {
            /* Child có thể đã exit/reap nên kill/wait được phép báo lỗi; cleanup best effort không
            panic khi đang unwind. Test vẫn FAIL qua status/timeout, không dùng cleanup để đổi verdict. */
            let _ = self.0.kill();
            let _ = self.0.wait();
        }
    }

    impl AuthDiagnostics for TestDiagnostics {
        /**
         * Mở span trong generation cố định của test, không cần runtime hoặc kết nối PostgreSQL.
         * Input
         * Param: `_stage` — stage hữu hạn, không ảnh hưởng quyền mở window test.
         * Output: generation1 để kiểm callback hoàn tất đúng vòng đời.
         */
        fn start_span(&self, _stage: AuthTimingStage) -> Option<u64> {
            Some(1)
        }

        /**
         * Thu callback để test quan sát outcome chính xác thay vì chỉ kiểm giá trị Result.
         * Input
         * Param: `window_id` — generation phải thuộc span đã mở.
         * Param: `stage` — ranh giới kỹ thuật cần giữ nguyên.
         * Param: `outcome` — trạng thái hoàn tất thực tế do adapter phát.
         * Param: `_elapsed` — duration không dùng làm ngưỡng hiệu năng trong unit test.
         * Side effects: thêm một callback vào bộ nhớ test, không I/O.
         */
        fn finish_span(
            &self,
            window_id: u64,
            stage: AuthTimingStage,
            outcome: AuthTimingOutcome,
            _elapsed: Duration,
        ) {
            assert_eq!(window_id, 1);
            self.0.lock().unwrap().push((stage, outcome));
        }
    }
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

    /// Diagnostic phải giữ nguyên giá trị thành công và Error UNKNOWN, không biến nó thành rejection.
    #[test]
    fn timing_completion_preserves_application_result() {
        use iot_application::auth_diagnostics::{AuthTimingSpan, AuthTimingStage};
        let observer = Arc::new(TestDiagnostics::default());
        let sink: Arc<dyn AuthDiagnostics> = observer.clone();
        let span = AuthTimingSpan::start(Some(&sink), AuthTimingStage::CommitAck);
        assert!(matches!(
            super::complete_auth_stage::<()>(span, Err(super::ApplicationError::CommitUnknown)),
            Err(super::ApplicationError::CommitUnknown)
        ));
        let span = AuthTimingSpan::start(Some(&sink), AuthTimingStage::AccountAcquire);
        assert_eq!(super::complete_auth_stage(span, Ok(7)).unwrap(), 7);
        assert_eq!(
            *observer.0.lock().unwrap(),
            vec![
                (AuthTimingStage::CommitAck, AuthTimingOutcome::Error),
                (
                    AuthTimingStage::AccountAcquire,
                    AuthTimingOutcome::Completed
                ),
            ]
        );
    }

    /// Store mặc định không đo; clone opt-in cùng sink phải thấy pool-closed Error mà không kết nối mạng.
    #[test]
    fn diagnostics_are_opt_in_and_shared_across_store_clones() {
        const MARKER: &str = "auth-diagnostics-isolated";
        // Marker chỉ điều phối own test invocation; không đọc environment variable để nhận diện child.
        let isolated = std::env::args().any(
            // So sánh argv nội bộ do test cha cấp; không thu thập hoặc in argument khác.
            |argument| argument == MARKER,
        );
        if !isolated {
            let deadline = Instant::now() + Duration::from_secs(5);
            /* Không kế thừa/copy environment máy. SystemRoot literal chỉ để Windows chạy process;
            constructor options chỉ chạy trong child này, không có PG variables hoặc passfile. */
            let mut child = OwnedTestChild(
                Command::new(std::env::current_exe().unwrap())
                    .args([
                        "--exact",
                        "tests::diagnostics_are_opt_in_and_shared_across_store_clones",
                        "--skip",
                        MARKER,
                    ])
                    .env_clear()
                    .env("SystemRoot", r"C:\Windows")
                    .stdin(Stdio::null())
                    .stdout(Stdio::null())
                    .stderr(Stdio::null())
                    .spawn()
                    .unwrap(),
            );
            loop {
                // RAII thu hồi child cả khi try_wait lỗi hoặc assertion timeout/status panic.
                assert!(Instant::now() < deadline, "Isolated store test timed out");
                if let Some(status) = child.0.try_wait().unwrap() {
                    assert!(status.success(), "Isolated store test failed");
                    break;
                }
                std::thread::sleep(Duration::from_millis(10));
            }
            return;
        }
        // Helper runtime doc(hidden) của SQLx0.8.6 chỉ dùng trong test; không thêm Tokio dependency mới.
        sqlx::test_block_on(async {
            use iot_application::ports::IdentityStore;
            // Lazy/min0 không mở connection; đóng trước begin để test chỉ kiểm pool-closed trong RAM.
            let pool = sqlx::postgres::PgPoolOptions::new()
                .min_connections(0)
                .max_connections(1)
                .connect_lazy_with(sqlx::postgres::PgConnectOptions::new_without_pgpass());
            pool.close().await;
            let store = super::PgIdentityStore::new(pool);
            assert!(store.diagnostics.is_none());
            assert!(matches!(
                store.begin().await,
                Err(super::ApplicationError::Unavailable)
            ));
            let observer = Arc::new(TestDiagnostics::default());
            let sink: Arc<dyn AuthDiagnostics> = observer.clone();
            let store = store.with_diagnostics(sink.clone());
            let peer = store.clone();
            assert!(Arc::ptr_eq(store.diagnostics.as_ref().unwrap(), &sink));
            assert!(Arc::ptr_eq(peer.diagnostics.as_ref().unwrap(), &sink));
            assert!(matches!(
                store.begin().await,
                Err(super::ApplicationError::Unavailable)
            ));
            assert!(matches!(
                peer.begin().await,
                Err(super::ApplicationError::Unavailable)
            ));
            assert_eq!(
                *observer.0.lock().unwrap(),
                vec![
                    (AuthTimingStage::PoolAcquire, AuthTimingOutcome::Error),
                    (AuthTimingStage::PoolAcquire, AuthTimingOutcome::Error),
                ]
            );
        });
    }
}
