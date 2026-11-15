//! Test orchestration bằng port trong bộ nhớ; không mô phỏng PostgreSQL hoặc chứng nhận engine.

use chrono::{TimeZone, Utc};
use iot_application::{
    error::ApplicationError,
    identity::IdentityService,
    ports::{IdentitySecurity, IdentityStore, IdentityTransaction, LockedSession},
};
use iot_domain::identity::{
    AccountSnapshot, AccountStatus, AuditRecord, ClientType, LoginWindow, NewSession, SecretString,
    SessionProof,
};
use std::{
    future::Future,
    pin::pin,
    sync::{Arc, Mutex},
    task::{Context, Poll, Waker},
};
use uuid::Uuid;

/**
 * Thực thi use case với adapter fake đồng bộ mà không thêm Tokio vào core.
 * Input
 * Param: future — future chỉ dùng các fake port hoàn tất ngay trong poll đầu tiên.
 * Output: kết quả use case; panic nếu test adapter vô tình đưa I/O vào unit test.
 */
fn run<F: Future>(future: F) -> F::Output {
    let waker = Waker::noop();
    match pin!(future).poll(&mut Context::from_waker(waker)) {
        Poll::Ready(result) => result,
        Poll::Pending => panic!("unit port unexpectedly yielded"),
    }
}

/// Storage giả giữ staged writes riêng để test required audit rollback và commit ACK unknown.
#[derive(Clone)]
struct MemoryStore(Arc<Mutex<State>>);
#[derive(Clone)]
struct State {
    window: LoginWindow,
    sessions: usize,
    audits: usize,
    commits: usize,
    failure_audit_attempts: usize,
    failure_audit_warnings: usize,
    failure_audit_actor: Option<Uuid>,
    fail_required_audit: bool,
    fail_failure_audit: bool,
    lose_commit_ack: bool,
    session_client_type: Option<ClientType>,
    audit_client_type: Option<ClientType>,
    lookup_emails: Vec<String>,
}
struct MemoryTransaction {
    store: MemoryStore,
    staged: State,
}

impl MemoryStore {
    /// Tạo storage fake trống, không dùng credential hoặc dữ liệu của DB thật.
    fn new() -> Self {
        Self(Arc::new(Mutex::new(State {
            window: LoginWindow {
                failures: 0,
                started_at: None,
            },
            sessions: 0,
            audits: 0,
            commits: 0,
            failure_audit_attempts: 0,
            failure_audit_warnings: 0,
            failure_audit_actor: None,
            fail_required_audit: false,
            fail_failure_audit: false,
            lose_commit_ack: false,
            session_client_type: None,
            audit_client_type: None,
            lookup_emails: Vec::new(),
        })))
    }
}

impl IdentityStore for MemoryStore {
    type Transaction = MemoryTransaction;
    /// Lưu warning counter độc lập với transaction đã commit để kiểm degraded audit sink.
    fn observe_failed_audit(&self, _kind: iot_domain::audit_write::FailureAuditKind) {
        self.0.lock().unwrap().failure_audit_warnings += 1;
    }
    /// Snapshot staged writes để bỏ transaction chưa commit không thay đổi state dùng chung.
    fn begin(&self) -> impl Future<Output = Result<MemoryTransaction, ApplicationError>> + Send {
        std::future::ready({
            Ok(MemoryTransaction {
                store: self.clone(),
                staged: self.0.lock().unwrap().clone(),
            })
        })
    }
    /// Lỗi failure audit được quan sát độc lập với counter đã commit; không âm thầm phục hồi counter.
    fn record_failed_login(
        &self,
        audit: AuditRecord,
    ) -> impl Future<Output = Result<(), ApplicationError>> + Send {
        std::future::ready({
            let mut state = self.0.lock().unwrap();
            state.failure_audit_attempts += 1;
            state.failure_audit_actor = audit.actor_user_id;
            if state.fail_failure_audit {
                Err(ApplicationError::Unavailable)
            } else {
                state.audits += 1;
                Ok(())
            }
        })
    }
}

impl IdentityTransaction for MemoryTransaction {
    /// Trả cửa sổ staged và clock cố định để unit test không phụ thuộc đồng hồ hệ điều hành.
    fn lock_login_bucket(
        &mut self,
        _digest: [u8; 32],
    ) -> impl Future<Output = Result<(LoginWindow, chrono::DateTime<Utc>), ApplicationError>> + Send
    {
        std::future::ready({
            Ok((
                self.staged.window,
                Utc.timestamp_opt(1_700_000_000, 0).unwrap(),
            ))
        })
    }
    /** Cấp account fake cố định và ghi lookup key đã canonicalize để kiểm mọi biến thể cùng identity.
     * Input
     * Param: email — key application chuyển sau validation, chỉ lưu trong ledger RAM tổng hợp của test.
     * Output: cùng account nil UUID; xác minh password vẫn do crypto port quyết định.
     */
    fn lock_account(
        &mut self,
        email: &str,
    ) -> impl Future<Output = Result<Option<AccountSnapshot>, ApplicationError>> + Send {
        std::future::ready({
            self.staged.lookup_emails.push(email.to_owned());
            Ok(Some(AccountSnapshot {
                user_id: Uuid::nil(),
                password_verifier: SecretString::new("synthetic-verifier".into()),
                status: AccountStatus::Active,
                must_change_password: false,
            }))
        })
    }
    /// Ghi failure vào staged state, chưa quan sát được từ store trước commit.
    fn save_login_window(
        &mut self,
        _digest: [u8; 32],
        window: LoginWindow,
    ) -> impl Future<Output = Result<(), ApplicationError>> + Send {
        std::future::ready({
            self.staged.window = window;
            Ok(())
        })
    }
    /** Ghi count và client_type vào staged state để kiểm commit atomic cùng metadata IOS/Android/Web.
     * Input
     * Param: session — session tổng hợp do application tạo sau verify; chỉ giữ metadata không secret.
     * Output: hoàn tất staging; store chưa thấy thay đổi trước commit.
     */
    fn insert_session(
        &mut self,
        session: &NewSession,
    ) -> impl Future<Output = Result<(), ApplicationError>> + Send {
        std::future::ready({
            self.staged.sessions += 1;
            self.staged.session_client_type = Some(session.client_type);
            Ok(())
        })
    }
    /// Fake không cấp session authority ngoài login test; mọi proof đều fail closed.
    fn lock_session(
        &mut self,
        _proof: &SessionProof,
    ) -> impl Future<Output = Result<LockedSession, ApplicationError>> + Send {
        std::future::ready(Err(ApplicationError::SessionInvalid))
    }
    /** Stage audit metadata hoặc inject required-audit failure để kiểm rollback session.
     * Input
     * Param: audit — audit tổng hợp từ use case, chỉ lưu metadata client để đối chiếu session.
     * Output: hoàn tất staging hoặc Unavailable theo cấu hình failure fake.
     */
    fn append_audit(
        &mut self,
        audit: AuditRecord,
    ) -> impl Future<Output = Result<(), ApplicationError>> + Send {
        std::future::ready({
            if self.staged.fail_required_audit {
                Err(ApplicationError::Unavailable)
            } else {
                self.staged.audits += 1;
                self.staged.audit_client_type = Some(audit.client_type);
                Ok(())
            }
        })
    }
    /// Áp dụng staged state một lần; mất ACK được giả lập sau apply để kiểm không phát token hoặc replay.
    fn commit(mut self) -> impl Future<Output = Result<(), ApplicationError>> + Send {
        std::future::ready({
            self.staged.commits += 1;
            let lose_ack = self.staged.lose_commit_ack;
            *self.store.0.lock().unwrap() = self.staged;
            if lose_ack {
                Err(ApplicationError::CommitUnknown)
            } else {
                Ok(())
            }
        })
    }
}

/** Login IOS giữ metadata riêng xuyên session/audit commit, TTL24h giống Android và credential chỉ có sau ACK. */
#[test]
fn ios_login_commits_matching_session_and_audit_metadata() {
    let store = MemoryStore::new();
    let service = IdentityService::new(
        store.clone(),
        FakeSecurity {
            valid: true,
            expected_password: None,
        },
    );
    let issued = run(service.login(
        "unit@example.invalid",
        "synthetic-password-Aa1".to_owned(),
        ClientType::Ios,
        Uuid::new_v4(),
    ))
    .unwrap();
    assert_eq!(
        issued.expires_at,
        Utc.timestamp_opt(1_700_000_000, 0).unwrap() + chrono::TimeDelta::hours(24)
    );
    assert!(!issued.limited);
    assert!(!issued.token.expose().is_empty());
    let state = store.0.lock().unwrap();
    assert_eq!(state.sessions, 1);
    assert_eq!(state.audits, 1);
    assert_eq!(state.commits, 1);
    assert_eq!(state.session_client_type, Some(ClientType::Ios));
    assert_eq!(state.audit_client_type, Some(ClientType::Ios));
}

/// Crypto fake chỉ điều khiển outcome orchestration, không được đưa vào composition production.
#[derive(Clone)]
struct FakeSecurity {
    valid: bool,
    expected_password: Option<&'static str>,
}
impl IdentitySecurity for FakeSecurity {
    /// Fake trả marker đã che để contract hashing không kéo implementation crypto vào core test.
    fn hash_password(
        &self,
        _password: SecretString,
    ) -> impl Future<Output = Result<SecretString, ApplicationError>> + Send {
        std::future::ready(Ok(SecretString::new("synthetic-verifier".into())))
    }
    /**
     * Giả lập verify tại ranh giới crypto để test outcome và xác nhận use case giữ nguyên credential.
     *
     * # Input
     * Param: password — password tổng hợp được use case chuyển tới port verify.
     * Param: _verifier — verifier giả; không thực hiện băm hoặc so khớp hash thật.
     *
     * # Output
     * Trả valid đã chọn và từ chối nếu password khác giá trị case yêu cầu.
     */
    fn verify_password(
        &self,
        password: SecretString,
        _verifier: SecretString,
    ) -> impl Future<Output = Result<bool, ApplicationError>> + Send {
        std::future::ready(Ok(self.valid
            && self.expected_password.is_none_or(
                // Chỉ nhận credential nguyên bản của case khi test có đặt giá trị đối chứng.
                |expected| password.expose() == expected,
            )))
    }
    /// Unknown account dùng cùng interface, không làm test phụ thuộc PHC encoding.
    fn dummy_verifier(&self) -> SecretString {
        SecretString::new("synthetic-dummy".into())
    }
    /// Bucket identity tổng hợp duy nhất cho một unit test, không dùng cho engine concurrency test.
    fn bucket_digest(&self, _email: &str) -> Result<[u8; 32], ApplicationError> {
        Ok([7; 32])
    }
    /// Credential tổng hợp được che Debug để chỉ kiểm thời điểm phát, không kiểm entropy tại unit layer.
    fn issue_token(&self) -> (SecretString, [u8; 32]) {
        (SecretString::new(Uuid::new_v4().to_string()), [8; 32])
    }
    /// Lookup fake không cấp principal; port storage vẫn từ chối mọi session proof.
    fn token_digest(&self, _token: &str) -> [u8; 32] {
        [8; 32]
    }
    /// Marker cho test orchestration login không dùng body guard; không thay kiểm SHA256 ở adapter thật.
    fn request_digest(&self, _payload: &[u8]) -> [u8; 32] {
        [9; 32]
    }
}

/** Mật khẩu tạm có composition mới nhưng capability phiên vẫn giữ định dạng token cũ, không giảm entropy nguồn. */
#[test]
fn generated_temporary_password_obeys_new_policy() {
    let security = FakeSecurity {
        valid: true,
        expected_password: None,
    };
    let password = security.issue_temporary_password().unwrap();
    assert!(iot_domain::input::validate_new_password(password.expose(), "/password").is_ok());
    let random_suffix = password.expose().strip_prefix("Aa1").unwrap();
    assert!(Uuid::parse_str(random_suffix).is_ok());
    let (token, _) = security.issue_token();
    assert!(Uuid::parse_str(token.expose()).is_ok());
}

/// Required audit failure bỏ cả staged session; không có commit hoặc credential thành công.
#[test]
fn success_audit_failure_rolls_back_session() {
    let store = MemoryStore::new();
    store.0.lock().unwrap().fail_required_audit = true;
    let service = IdentityService::new(
        store.clone(),
        FakeSecurity {
            valid: true,
            expected_password: None,
        },
    );
    assert!(matches!(
        run(service.login(
            "unit@example.invalid",
            Uuid::new_v4().to_string(),
            ClientType::Android,
            Uuid::new_v4()
        )),
        Err(ApplicationError::Unavailable)
    ));
    let state = store.0.lock().unwrap();
    assert_eq!(state.sessions, 0);
    assert_eq!(state.commits, 0);
}

/// Failure audit unavailable không làm mất counter và không đổi public invalid-credential outcome.
#[test]
fn failure_audit_error_preserves_committed_counter() {
    let store = MemoryStore::new();
    store.0.lock().unwrap().fail_failure_audit = true;
    let service = IdentityService::new(
        store.clone(),
        FakeSecurity {
            valid: false,
            expected_password: None,
        },
    );
    assert!(matches!(
        run(service.login(
            "unit@example.invalid",
            Uuid::new_v4().to_string(),
            ClientType::Android,
            Uuid::new_v4()
        )),
        Err(ApplicationError::InvalidCredentials)
    ));
    let state = store.0.lock().unwrap();
    assert_eq!(state.window.failures, 1);
    assert_eq!(state.sessions, 0);
    assert_eq!(state.failure_audit_attempts, 1);
    assert_eq!(state.failure_audit_warnings, 1);
    assert_eq!(state.failure_audit_actor, None);
}

/// COMMIT đã áp nhưng mất ACK không được phát credential hoặc tự chạy transaction lần hai.
#[test]
fn lost_commit_ack_returns_unknown_without_issuing_credential() {
    let store = MemoryStore::new();
    store.0.lock().unwrap().lose_commit_ack = true;
    let service = IdentityService::new(
        store.clone(),
        FakeSecurity {
            valid: true,
            expected_password: None,
        },
    );
    assert!(matches!(
        run(service.login(
            "unit@example.invalid",
            Uuid::new_v4().to_string(),
            ClientType::Android,
            Uuid::new_v4()
        )),
        Err(ApplicationError::CommitUnknown)
    ));
    let state = store.0.lock().unwrap();
    assert_eq!(state.sessions, 1);
    assert_eq!(state.commits, 1);
}

/** Giữ khoảng trắng đầu/cuối của password tổng hợp đến port verify để credential cũ không bị đổi nghĩa. */
#[test]
fn login_passes_password_whitespace_unchanged_to_verifier() {
    let store = MemoryStore::new();
    let password = "  synthetic-password  ";
    let service = IdentityService::new(
        store.clone(),
        FakeSecurity {
            valid: true,
            expected_password: Some(password),
        },
    );
    assert!(
        run(service.login(
            "unit@example.invalid",
            password.to_owned(),
            ClientType::Android,
            Uuid::new_v4(),
        ))
        .is_ok()
    );
    assert_eq!(store.0.lock().unwrap().sessions, 1);
}

/** Cả ba input tương đương OQ001 tới đúng lookup key và account, còn Unicode bị chặn trước storage. */
#[test]
fn login_email_equivalents_use_the_same_account_lookup_key() {
    let store = MemoryStore::new();
    let service = IdentityService::new(
        store.clone(),
        FakeSecurity {
            valid: true,
            expected_password: None,
        },
    );
    for email in [
        "member.name+tag@example.test",
        "MeMbEr.NaMe+TaG@EXAMPLE.TEST",
        "\t\n\u{c}\r Member.Name+Tag@Example.Test \t\n\u{c}\r",
    ] {
        let issued = run(service.login(
            email,
            "synthetic-password-Aa1".to_owned(),
            ClientType::Android,
            Uuid::new_v4(),
        ))
        .unwrap();
        assert_eq!(issued.user_id, Uuid::nil());
    }
    for email in [
        "thànhviên@example.test",
        "\u{a0}member@example.test\u{a0}",
        "\u{b}member@example.test\u{b}",
    ] {
        assert!(matches!(
            run(service.login(
                email,
                "synthetic-password-Aa1".to_owned(),
                ClientType::Android,
                Uuid::new_v4()
            )),
            Err(ApplicationError::InvalidInput)
        ));
    }
    let state = store.0.lock().unwrap();
    assert_eq!(state.lookup_emails, vec!["member.name+tag@example.test"; 3]);
    assert_eq!(state.sessions, 3);
    assert_eq!(state.commits, 3);
}
