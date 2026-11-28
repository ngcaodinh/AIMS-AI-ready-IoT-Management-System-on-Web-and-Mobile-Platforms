//! Kiểm registry đọc lại session sau lúc chờ khóa root, kể cả khi kết quả schema là lỗi nghiệp vụ.

use chrono::{DateTime, Duration, TimeZone, Utc};
use iot_application::{
    device::DeviceService,
    device_ports::{DeviceStore, DeviceTransaction, LockedActorSession},
    error::ApplicationError,
    template_ports::TemplateDigest,
};
use iot_domain::{
    device::{ApprovedDeviceModels, DeviceDraft, DevicePin, DeviceRecord, RegisteredDevice},
    identity::{
        AccountStatus, ActorAccountSnapshot, AuditRecord, ClientType, SessionProof,
        SessionSnapshot,
    },
    template_snapshot::TemplateVersionSnapshot,
    workspace::{WorkspaceRole, WorkspaceSnapshot},
};
use std::{
    future::Future,
    pin::pin,
    sync::{Arc, Mutex},
    task::{Context, Poll, Waker},
};
use uuid::Uuid;

const USER_ID: Uuid = Uuid::from_u128(1);
const WORKSPACE_ID: Uuid = Uuid::from_u128(2);
const VERSION_ID: Uuid = Uuid::from_u128(3);

/// Poll các port spy đồng bộ; Pending báo test đã vô tình thêm I/O chưa được điều khiển.
fn run<F: Future>(future: F) -> F::Output {
    match pin!(future).poll(&mut Context::from_waker(Waker::noop())) {
        Poll::Ready(result) => result,
        Poll::Pending => panic!("unexpected asynchronous spy operation"),
    }
}

/// Clock lúc actor khóa session; mọi session spy hết hạn sau mốc này một giờ.
fn locked_at() -> DateTime<Utc> {
    Utc.timestamp_opt(1_700_000_000, 0).unwrap()
}

/// Spy giữ thứ tự port đã chạm để test chứng minh clock được đọc trước khi trả lỗi schema.
#[derive(Clone)]
struct SpyStore {
    schema_error: fn() -> ApplicationError,
    clock_after_wait: Result<DateTime<Utc>, fn() -> ApplicationError>,
    calls: Arc<Mutex<Vec<&'static str>>>,
}

struct SpyTransaction(SpyStore);

#[derive(Clone)]
struct UnusedDigest;

impl TemplateDigest for UnusedDigest {
    /// Ca lỗi schema phải kết thúc trước digest; gọi tới đây làm test thất bại ngay.
    fn content_digest(&self, _canonical: &[u8]) -> [u8; 32] {
        panic!("digest reached after a failed schema lookup")
    }
}

impl DeviceStore for SpyStore {
    type Transaction = SpyTransaction;

    /// Mở transaction spy dùng chung nhật ký port với store của test.
    async fn begin_device(&self) -> Result<SpyTransaction, ApplicationError> {
        Ok(SpyTransaction(self.clone()))
    }
}

impl DeviceTransaction for SpyTransaction {
    /// Registration expiry cases must stop before serial recovery.
    async fn recover_device(
        &mut self,
        _workspace_id: Uuid,
        _serial: &str,
    ) -> Result<Option<DeviceRecord>, ApplicationError> {
        panic!("unexpected serial recovery lookup")
    }

    /// Cấp session Android ACTIVE còn hạn tại thời điểm khóa để chỉ cô lập kiểm tra sau lúc chờ.
    async fn lock_device_actor(
        &mut self,
        _proof: &SessionProof,
        owner: Option<Uuid>,
    ) -> Result<LockedActorSession, ApplicationError> {
        assert_eq!(owner, Some(USER_ID));
        Ok(LockedActorSession {
            account: ActorAccountSnapshot {
                user_id: USER_ID,
                status: AccountStatus::Active,
                must_change_password: false,
            },
            session: SessionSnapshot {
                session_id: Uuid::from_u128(4),
                user_id: USER_ID,
                auth_context_id: Uuid::from_u128(5),
                client_type: ClientType::Android,
                limited: false,
                expires_at: locked_at() + Duration::hours(1),
                revoked_at: None,
            },
            observed_at: locked_at(),
        })
    }

    /// Trả membership Admin hiện hành để registry đi tới bước đọc schema trong cùng transaction.
    async fn lock_device_scope(
        &mut self,
        workspace_id: Uuid,
        user_id: Uuid,
    ) -> Result<WorkspaceSnapshot, ApplicationError> {
        Ok(WorkspaceSnapshot {
            workspace_id,
            user_id,
            workspace_active: true,
            membership_active: true,
            grant_active: true,
            role: WorkspaceRole::Admin,
            grant_generation: 1,
            workspace_authorization_version: 1,
            membership_authorization_version: 1,
        })
    }

    /// Giữ nguyên tên đã canonical để draft hợp lệ đi tới bước owner và schema.
    async fn normalize_device_name(&mut self, name: &str) -> Result<String, ApplicationError> {
        Ok(name.to_owned())
    }

    /// Owner luôn hiện hành; ca này chỉ kiểm thứ tự sau lúc chờ khóa root.
    async fn owner_is_current(
        &mut self,
        _workspace_id: Uuid,
        _owner_id: Uuid,
    ) -> Result<bool, ApplicationError> {
        Ok(true)
    }

    /// Mô phỏng lúc chờ khóa root rồi trả lỗi schema đã cấu hình, ghi nhận thứ tự gọi.
    async fn registration_schema(
        &mut self,
        _workspace_id: Uuid,
        _version_id: Uuid,
    ) -> Result<TemplateVersionSnapshot, ApplicationError> {
        self.0.calls.lock().unwrap().push("schema");
        Err((self.0.schema_error)())
    }

    /// Read-only schema path không được dùng trong registry mutation.
    async fn device_pin(
        &mut self,
        _workspace_id: Uuid,
        _device_id: Uuid,
    ) -> Result<DevicePin, ApplicationError> {
        panic!("unexpected device pin lookup")
    }

    /// Read-only schema path không được dùng trong registry mutation.
    async fn pinned_schema(
        &mut self,
        _workspace_id: Uuid,
        _version_id: Uuid,
    ) -> Result<TemplateVersionSnapshot, ApplicationError> {
        panic!("unexpected pinned schema lookup")
    }

    /// Trả clock sau lúc chờ khóa hoặc lỗi đọc clock giả lập, ghi nhận lần đọc để chứng minh session được kiểm lại.
    async fn device_now(&mut self) -> Result<DateTime<Utc>, ApplicationError> {
        self.0.calls.lock().unwrap().push("clock");
        self.0.clock_after_wait.map_err(|failure| failure())
    }

    /// Lỗi schema phải dừng trước insert; panic báo registry đã ghi sau lỗi.
    async fn insert_registered_device(
        &mut self,
        _workspace_id: Uuid,
        _device_id: Uuid,
        _draft: &DeviceDraft,
        _now: DateTime<Utc>,
    ) -> Result<RegisteredDevice, ApplicationError> {
        panic!("unexpected registry write after a failed schema lookup")
    }

    /// Lỗi schema phải dừng trước audit thành công.
    async fn append_device_audit(&mut self, _audit: AuditRecord) -> Result<(), ApplicationError> {
        panic!("unexpected registry audit after a failed schema lookup")
    }

    /// Lỗi schema phải dừng trước commit để không phát receipt.
    async fn commit_device(self) -> Result<(), ApplicationError> {
        panic!("unexpected commit after a failed schema lookup")
    }
}

/**
 * Gọi register thật với schema lỗi cấu hình và kết quả đọc clock sau lúc chờ.
 *
 * # Input
 * Param: schema_error — hàm tạo kết quả nghiệp vụ mà registry port trả sau lúc chờ khóa root.
 * Param: clock_after_wait — clock mới đọc hoặc lỗi đọc clock sau lúc chờ, quyết định session còn hạn hay fail-closed.
 *
 * # Output
 * Trả cặp lỗi cuối của register cùng thứ tự port đã được gọi.
 */
fn register_after_wait_with_clock(
    schema_error: fn() -> ApplicationError,
    clock_after_wait: Result<DateTime<Utc>, fn() -> ApplicationError>,
) -> (ApplicationError, Vec<&'static str>) {
    let store = SpyStore {
        schema_error,
        clock_after_wait,
        calls: Arc::default(),
    };
    let service = DeviceService::new(
        store.clone(),
        UnusedDigest,
        ApprovedDeviceModels::new(vec!["TEST_MODEL".into()]).unwrap(),
    );
    let proof = SessionProof {
        token_digest: [0; 32],
        expected_context: None,
    };
    let draft = DeviceDraft {
        serial_number: "SERIAL-001".into(),
        name: "Device".into(),
        model: "TEST_MODEL".into(),
        template_version_id: VERSION_ID,
        owner_user_id: USER_ID,
    };
    let error = run(service.register(&proof, WORKSPACE_ID, draft, Uuid::from_u128(6)))
        .err()
        .expect("failed schema lookup must reject registration");
    let calls = store.calls.lock().unwrap().clone();
    (error, calls)
}

/**
 * Gọi register thật với schema lỗi cấu hình và clock hợp lệ sau lúc chờ.
 *
 * # Input
 * Param: schema_error — hàm tạo kết quả nghiệp vụ mà registry port trả sau lúc chờ khóa root.
 * Param: clock_after_wait — clock mới đọc sau lúc chờ, quyết định session còn hạn hay không.
 *
 * # Output
 * Trả cặp lỗi cuối của register cùng thứ tự port đã được gọi.
 */
fn register_after_wait(
    schema_error: fn() -> ApplicationError,
    clock_after_wait: DateTime<Utc>,
) -> (ApplicationError, Vec<&'static str>) {
    register_after_wait_with_clock(schema_error, Ok(clock_after_wait))
}

/// Session hết hạn trong lúc chờ root phải thắng phân loại draft nội tenant.
#[test]
fn expired_session_wins_over_draft_template_status() {
    let (error, calls) = register_after_wait(
        || ApplicationError::DeviceTemplateNotPublished,
        locked_at() + Duration::hours(2),
    );
    assert_eq!(error, ApplicationError::SessionExpired);
    assert_eq!(calls, ["schema", "clock"]);
}

/// Session hết hạn trong lúc chờ root cũng thắng lỗi not-found chung.
#[test]
fn expired_session_wins_over_template_not_found() {
    let (error, calls) = register_after_wait(
        || ApplicationError::ResourceNotFound,
        locked_at() + Duration::hours(2),
    );
    assert_eq!(error, ApplicationError::SessionExpired);
    assert_eq!(calls, ["schema", "clock"]);
}

/// Session còn hạn sau lúc chờ giữ nguyên kết quả schema, gồm draft nội tenant và not-found.
#[test]
fn live_session_preserves_schema_failure() {
    let schema_errors: [fn() -> ApplicationError; 3] = [
        || ApplicationError::DeviceTemplateNotPublished,
        || ApplicationError::ResourceNotFound,
        || ApplicationError::Unavailable,
    ];
    for schema_error in schema_errors {
        let (error, calls) = register_after_wait(schema_error, locked_at());
        assert_eq!(error, schema_error());
        assert_eq!(calls, ["schema", "clock"]);
    }
}

/// Lỗi đọc clock sau lúc chờ trên kết quả draft nội tenant phải fail-closed và truyền lỗi clock.
#[test]
fn clock_failure_overrides_draft_template_status() {
    let clock_errors: [fn() -> ApplicationError; 2] = [
        || ApplicationError::Unavailable,
        || ApplicationError::Conflict,
    ];
    for clock_error in clock_errors {
        let (error, calls) = register_after_wait_with_clock(
            || ApplicationError::DeviceTemplateNotPublished,
            Err(clock_error),
        );
        assert_eq!(error, clock_error());
        assert_eq!(calls, ["schema", "clock"]);
    }
}

/// Lỗi đọc clock sau lúc chờ vẫn giữ nguyên phân loại của lỗi storage chung từ schema lookup.
#[test]
fn clock_failure_preserves_generic_storage_error() {
    let cases: [(fn() -> ApplicationError, fn() -> ApplicationError); 2] = [
        (
            || ApplicationError::Conflict,
            || ApplicationError::Unavailable,
        ),
        (
            || ApplicationError::Unavailable,
            || ApplicationError::Conflict,
        ),
    ];
    for (schema_error, clock_error) in cases {
        let (error, calls) = register_after_wait_with_clock(schema_error, Err(clock_error));
        assert_eq!(error, schema_error());
        assert_eq!(calls, ["schema", "clock"]);
    }
}
