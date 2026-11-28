//! Kiểm thứ tự admission của resource service bằng spy port, không thay bằng chứng PostgreSQL/HTTP.

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
        AccessFailure, AccountStatus, ActorAccountSnapshot, AuditRecord, ClientType, SessionProof,
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
const DEVICE_ID: Uuid = Uuid::from_u128(3);

/// Poll các port spy đồng bộ; Pending báo test đã vô tình thêm I/O chưa được điều khiển.
fn run<F: Future>(future: F) -> F::Output {
    match pin!(future).poll(&mut Context::from_waker(Waker::noop())) {
        Poll::Ready(result) => result,
        Poll::Pending => panic!("unexpected asynchronous spy operation"),
    }
}

/// Clock cố định để mọi session spy còn hạn, tránh denial vì expiry che lỗi membership guard.
fn now() -> DateTime<Utc> {
    Utc.timestamp_opt(1_700_000_000, 0).unwrap()
}

/** Giữ thứ tự lỗi của session khi device chỉ nhận trạng thái actor. */
#[test]
fn credential_free_actor_admission_preserves_error_precedence() {
    let observed_at = now();
    let auth_context_id = Uuid::from_u128(5);
    let session_id = Uuid::from_u128(4);
    let mut account = ActorAccountSnapshot {
        user_id: USER_ID,
        status: AccountStatus::Disabled,
        must_change_password: true,
    };
    let mut session = SessionSnapshot {
        session_id,
        user_id: USER_ID,
        auth_context_id,
        client_type: ClientType::Web,
        limited: true,
        expires_at: observed_at,
        revoked_at: Some(observed_at),
    };
    let mut proof = SessionProof {
        token_digest: [0; 32],
        expected_context: None,
    };
    let decide =
        |session: &SessionSnapshot, account: &ActorAccountSnapshot, proof: &SessionProof| {
            session
                .authorize_actor(account, proof, observed_at, false)
                .map(|principal| {
                    (
                        principal.user_id(),
                        principal.session_id(),
                        principal.client_type(),
                    )
                })
        };

    assert_eq!(
        decide(&session, &account, &proof),
        Err(AccessFailure::SessionInvalid)
    );
    account.status = AccountStatus::Active;
    account.user_id = Uuid::from_u128(6);
    assert_eq!(
        decide(&session, &account, &proof),
        Err(AccessFailure::SessionInvalid)
    );
    account.user_id = USER_ID;
    assert_eq!(
        decide(&session, &account, &proof),
        Err(AccessFailure::SessionRevoked)
    );
    session.revoked_at = None;
    assert_eq!(
        decide(&session, &account, &proof),
        Err(AccessFailure::SessionExpired)
    );
    session.expires_at += Duration::seconds(1);
    assert_eq!(
        decide(&session, &account, &proof),
        Err(AccessFailure::ContextMismatch)
    );
    proof.expected_context = Some(auth_context_id);
    account.must_change_password = false;
    assert_eq!(
        decide(&session, &account, &proof),
        Err(AccessFailure::PasswordChangeRequired)
    );
    session.limited = false;
    account.must_change_password = true;
    assert_eq!(
        decide(&session, &account, &proof),
        Err(AccessFailure::PasswordChangeRequired)
    );
    account.must_change_password = false;
    assert_eq!(
        decide(&session, &account, &proof),
        Ok((USER_ID, session_id, ClientType::Web))
    );
}

#[derive(Default)]
struct Observations {
    membership_active: bool,
    grant_active: bool,
    pin_reads: usize,
    schema_reads: usize,
}

#[derive(Clone, Default)]
struct SpyStore(Arc<Mutex<Observations>>);

struct SpyTransaction(SpyStore);

#[derive(Clone)]
struct UnusedDigest;

impl TemplateDigest for UnusedDigest {
    /// Ca deny phải kết thúc trước content digest; gọi tới đây làm test thất bại ngay.
    fn content_digest(&self, _canonical: &[u8]) -> [u8; 32] {
        panic!("digest reached before denied resource admission")
    }
}

impl DeviceStore for SpyStore {
    type Transaction = SpyTransaction;

    /// Tạo spy dùng cùng observation để đếm query kể cả khi transaction bị drop vì lỗi.
    async fn begin_device(&self) -> Result<SpyTransaction, ApplicationError> {
        Ok(SpyTransaction(self.clone()))
    }
}

impl DeviceTransaction for SpyTransaction {
    /**
     * Giữ test admission tách khỏi recovery; panic nếu use case vô tình gọi port này.
     *
     * # Panics
     * Luôn panic vì mọi test trong module này phải kiểm tra scope admission, không tra serial.
     */
    async fn recover_device(
        &mut self,
        _workspace_id: Uuid,
        _serial: &str,
    ) -> Result<Option<DeviceRecord>, ApplicationError> {
        panic!("unexpected serial lookup")
    }

    /// Cấp full Android session ACTIVE còn hạn cho actor cố định để chỉ cô lập workspace admission.
    async fn lock_device_actor(
        &mut self,
        _proof: &SessionProof,
        owner: Option<Uuid>,
    ) -> Result<LockedActorSession, ApplicationError> {
        assert!(owner.is_none());
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
                expires_at: now() + Duration::hours(24),
                revoked_at: None,
            },
            observed_at: now(),
        })
    }

    /** Trả quyền hiện hành của đúng actor/tenant selector, không dùng snapshot picker trước đó.
     * Input
     * Param: workspace_id — tenant resource đang được chọn trong request.
     * Param: user_id — actor phải do session resolver cấp.
     * Output: snapshot hiện tại để production domain authorize trước mọi resource port.
     */
    async fn lock_device_scope(
        &mut self,
        workspace_id: Uuid,
        user_id: Uuid,
    ) -> Result<WorkspaceSnapshot, ApplicationError> {
        assert_eq!((workspace_id, user_id), (WORKSPACE_ID, USER_ID));
        let observed = self.0.0.lock().unwrap();
        Ok(WorkspaceSnapshot {
            workspace_id,
            user_id,
            workspace_active: true,
            membership_active: observed.membership_active,
            grant_active: observed.grant_active,
            role: WorkspaceRole::User,
            grant_generation: 1,
            workspace_authorization_version: 1,
            membership_authorization_version: 1,
        })
    }

    /// Đếm trước khi trả not-found để positive control phân biệt admission thành công với deny trước query.
    async fn device_pin(
        &mut self,
        _workspace_id: Uuid,
        _device_id: Uuid,
    ) -> Result<DevicePin, ApplicationError> {
        self.0.0.lock().unwrap().pin_reads += 1;
        Err(ApplicationError::ResourceNotFound)
    }

    /// Đếm trước lỗi để query content ngoài admission không bị che bởi kết quả lỗi giống nhau.
    async fn pinned_schema(
        &mut self,
        _workspace_id: Uuid,
        _version_id: Uuid,
    ) -> Result<TemplateVersionSnapshot, ApplicationError> {
        self.0.0.lock().unwrap().schema_reads += 1;
        Err(ApplicationError::ResourceNotFound)
    }

    /// Đọc schema không được đi qua normalize của registry mutation.
    async fn normalize_device_name(&mut self, _name: &str) -> Result<String, ApplicationError> {
        panic!("unexpected registry normalization")
    }

    /// Đọc schema không được truy cập quyền target owner của registry mutation.
    async fn owner_is_current(
        &mut self,
        _workspace_id: Uuid,
        _owner_id: Uuid,
    ) -> Result<bool, ApplicationError> {
        panic!("unexpected registry owner lookup")
    }

    /// Đọc schema không được thay đường pin bằng template version do caller đưa vào.
    async fn registration_schema(
        &mut self,
        _workspace_id: Uuid,
        _version_id: Uuid,
    ) -> Result<TemplateVersionSnapshot, ApplicationError> {
        panic!("unexpected registration schema lookup")
    }

    /// Những ca này dừng trước khi đọc content, nên clock sau content chưa được phép gọi.
    async fn device_now(&mut self) -> Result<DateTime<Utc>, ApplicationError> {
        panic!("unexpected post-resource clock")
    }

    /// Read-only admission không được ghi registry hoặc tạo device khác để né deny.
    async fn insert_registered_device(
        &mut self,
        _workspace_id: Uuid,
        _device_id: Uuid,
        _draft: &DeviceDraft,
        _now: DateTime<Utc>,
    ) -> Result<RegisteredDevice, ApplicationError> {
        panic!("unexpected registry write")
    }

    /// Denied read không được phát audit mutation qua registry port.
    async fn append_device_audit(&mut self, _audit: AuditRecord) -> Result<(), ApplicationError> {
        panic!("unexpected registry audit")
    }

    /// Các ca lỗi phải kết thúc trước commit, không biến lỗi quyền thành read thành công.
    async fn commit_device(self) -> Result<(), ApplicationError> {
        panic!("unexpected denied-read commit")
    }
}

/** Gọi production service với full session, trả lỗi typed và số lần resource port thật được chạm.
 * Input
 * Param: membership_active — current membership vừa đọc dưới scope fence.
 * Param: grant_active — current grant vừa đọc, độc lập với item picker đã cache.
 * Output: lỗi admission/resource cùng counter pin/content để kiểm thứ tự authorize.
 */
fn inspect(membership_active: bool, grant_active: bool) -> (ApplicationError, usize, usize) {
    let store = SpyStore::default();
    {
        let mut observed = store.0.lock().unwrap();
        observed.membership_active = membership_active;
        observed.grant_active = grant_active;
    }
    let service = DeviceService::new(
        store.clone(),
        UnusedDigest,
        ApprovedDeviceModels::new(vec!["TEST_MODEL".into()]).unwrap(),
    );
    let proof = SessionProof {
        token_digest: [0; 32],
        expected_context: None,
    };
    let error = run(service.schema(&proof, WORKSPACE_ID, DEVICE_ID))
        .err()
        .expect("denied or missing spy resource");
    let observed = store.0.lock().unwrap();
    (error, observed.pin_reads, observed.schema_reads)
}

/// Full session không membership hiện hành bị từ chối trước pin/content query của workspace B.
#[test]
fn foreign_workspace_is_denied_before_any_resource_query() {
    assert_eq!(inspect(false, false), (ApplicationError::Forbidden, 0, 0));
}

/// Current membership bị suspend thắng snapshot picker cũ dù grant record vẫn còn ACTIVE.
#[test]
fn suspended_membership_is_denied_before_any_resource_query() {
    assert_eq!(inspect(false, true), (ApplicationError::Forbidden, 0, 0));
}

/// Membership ACTIVE với grant đã revoke vẫn không được truy cập pin hoặc content.
#[test]
fn revoked_grant_is_denied_before_any_resource_query() {
    assert_eq!(inspect(true, false), (ApplicationError::Forbidden, 0, 0));
}

/// Positive control chứng minh spy chạy được resource path khi domain admission cho phép.
#[test]
fn active_membership_and_grant_reach_the_resource_port() {
    assert_eq!(
        inspect(true, true),
        (ApplicationError::ResourceNotFound, 1, 0)
    );
}
