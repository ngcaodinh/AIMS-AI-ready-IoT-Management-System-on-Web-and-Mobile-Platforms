//! Port thuộc application: mô tả atomic workflow, không trả PgPool/PgRow hoặc `SQLx` Transaction.

use crate::error::ApplicationError;
use chrono::{DateTime, Utc};
use iot_domain::{
    identity::{
        AccountSnapshot, AuditRecord, LoginWindow, NewSession, SecretString, SessionProof,
        SessionSnapshot,
    },
    workspace::{WorkspaceDraft, WorkspaceSnapshot, WorkspaceSummary},
};
use std::future::Future;
use uuid::Uuid;

/// Bản đọc User/Session cùng fence và clock lấy sau khóa, không phải principal được tin sẵn.
pub struct LockedSession {
    pub account: AccountSnapshot,
    pub session: SessionSnapshot,
    pub observed_at: DateTime<Utc>,
}

/// Port crypto: implementation nằm ngoài application; toàn bộ chuỗi nhạy cảm che Debug.
pub trait IdentitySecurity: Clone + Send + Sync {
    /// Băm mật khẩu đã validate; lỗi tài nguyên không được biến thành credential hợp lệ.
    fn hash_password(
        &self,
        password: SecretString,
    ) -> impl Future<Output = Result<SecretString, ApplicationError>> + Send;
    /// Kiểm input nguyên bản với PHC hoặc dummy verifier cùng chi phí; không log hai đầu vào.
    fn verify_password(
        &self,
        password: SecretString,
        verifier: SecretString,
    ) -> impl Future<Output = Result<bool, ApplicationError>> + Send;
    /// Lấy bản sao dummy verifier được chuẩn bị một lần để unknown email vẫn đi qua hasher.
    fn dummy_verifier(&self) -> SecretString;
    /// HMAC email chuẩn hóa bằng key ổn định chung giữa các instance, không lưu raw email trong limiter.
    /// # Errors
    /// Unavailable khi adapter không thể tạo MAC, không đổi sang digest không có khóa.
    fn bucket_digest(&self, email: &str) -> Result<[u8; 32], ApplicationError>;
    /// Sinh capability256 bit và digest của nó; raw token chỉ đi tới client sau commit.
    fn issue_token(&self) -> (SecretString, [u8; 32]);
    /// Chuyển raw token thành lookup digest trước khi gửi vào storage, không tự xác thực session.
    fn token_digest(&self, token: &str) -> [u8; 32];
    /// Hash request canonical bytes để same key/different body không được nhận cached result khác intent.
    fn request_digest(&self, payload: &[u8]) -> [u8; 32];
}

/// Unit of work sở hữu transaction vật lý; bỏ handle chưa commit phải rollback mọi mutation.
pub trait IdentityTransaction: Send {
    /// Tạo/khóa shared bucket cả với email chưa tồn tại; trả clock quan sát sau khóa.
    fn lock_login_bucket(
        &mut self,
        digest: [u8; 32],
    ) -> impl Future<Output = Result<(LoginWindow, DateTime<Utc>), ApplicationError>> + Send;
    /// Khóa User theo email sau bucket để password change/disable không chen giữa verify và session commit.
    fn lock_account(
        &mut self,
        email: &str,
    ) -> impl Future<Output = Result<Option<AccountSnapshot>, ApplicationError>> + Send;
    /// Ghi counter/window đã được domain tính, trong cùng bucket fence.
    fn save_login_window(
        &mut self,
        digest: [u8; 32],
        window: LoginWindow,
    ) -> impl Future<Output = Result<(), ApplicationError>> + Send;
    /// Insert session chỉ có digest; TTL và identity do application quyết định, DB kiểm lại invariant.
    fn insert_session(
        &mut self,
        session: &NewSession,
    ) -> impl Future<Output = Result<(), ApplicationError>> + Send;
    /// Resolve proof bằng khóa User→Session; trả snapshot để domain kiểm context/expiry/limited hiện hành.
    fn lock_session(
        &mut self,
        proof: &SessionProof,
    ) -> impl Future<Output = Result<LockedSession, ApplicationError>> + Send;
    /// Audit bắt buộc cùng unit of work; lỗi phải làm caller dừng và rollback mutation.
    fn append_audit(
        &mut self,
        audit: AuditRecord,
    ) -> impl Future<Output = Result<(), ApplicationError>> + Send;
    /// Commit tiêu thụ handle; mất ACK trả `CommitUnknown`, không tự phát credential hoặc replay.
    fn commit(self) -> impl Future<Output = Result<(), ApplicationError>> + Send;
}

/// Factory unit of work; failure audit dùng đường ghi riêng sau khi limiter đã commit.
pub trait IdentityStore: Clone + Send + Sync {
    type Transaction: IdentityTransaction;
    /// Mở unit of work mới; không trả transaction cụ thể của framework ra application.
    fn begin(&self) -> impl Future<Output = Result<Self::Transaction, ApplicationError>> + Send;
    /// Ghi failure audit độc lập; lỗi không được rollback counter chống brute force đã commit.
    fn record_failed_login(
        &self,
        audit: AuditRecord,
    ) -> impl Future<Output = Result<(), ApplicationError>> + Send;
    /// Tăng counter vận hành hữu hạn khi failure audit lỗi; không I/O, không ảnh hưởng kết quả từ chối.
    fn observe_failed_audit(&self, kind: iot_domain::audit_write::FailureAuditKind);
}

/// Port tenant mở rộng unit of work IAM để authorization và mutation không bị tách transaction.
pub trait WorkspaceTransaction: IdentityTransaction {
    /// Tra catalog timezone bằng tham số bind; không tự diễn giải timezone từ input thành SQL.
    fn timezone_exists(
        &mut self,
        timezone: &str,
    ) -> impl Future<Output = Result<bool, ApplicationError>> + Send;
    /// Lưu aggregate Workspace+ADMIN+grant1 atomically; DB serialize creator quota5 dưới User fence.
    fn insert_workspace(
        &mut self,
        workspace_id: Uuid,
        creator_id: Uuid,
        draft: &WorkspaceDraft,
    ) -> impl Future<Output = Result<(), ApplicationError>> + Send;
    /// Picker chỉ chọn ACTIVE workspace/membership/current grant; giới hạn và keyset do use case kiểm.
    fn list_workspaces(
        &mut self,
        user_id: Uuid,
        after: Option<Uuid>,
        limit: i64,
    ) -> impl Future<Output = Result<Vec<WorkspaceSummary>, ApplicationError>> + Send;
    /// Khóa parent→membership/grant đúng scope; trả snapshot cho domain quyết định quyền.
    fn lock_workspace(
        &mut self,
        workspace_id: Uuid,
        user_id: Uuid,
    ) -> impl Future<Output = Result<WorkspaceSnapshot, ApplicationError>> + Send;
}

/// Mutation credential/session bổ sung trên cùng unit of work, không tách revoke/audit/outbox thành commit riêng.
pub trait SessionMutationTransaction: IdentityTransaction {
    /// Lookup email để chọn bucket→User lock order; chưa cấp authority và phải resolve lại session sau khóa.
    fn session_email(
        &mut self,
        proof: &SessionProof,
    ) -> impl Future<Output = Result<String, ApplicationError>> + Send;
    /// Cập nhật PHC và bỏ limited flag theo principal chính chủ; không nhận raw password vào storage.
    fn replace_password(
        &mut self,
        user_id: Uuid,
        verifier: &SecretString,
        activated_at: DateTime<Utc>,
    ) -> impl Future<Output = Result<(), ApplicationError>> + Send;
    /// Revoke phiên/tickets, CAS push binding và ghi durable close outbox cùng transaction; trả số phiên mới revoke.
    fn revoke_capabilities(
        &mut self,
        scope: iot_domain::identity::SessionRevocation,
        now: DateTime<Utc>,
    ) -> impl Future<Output = Result<usize, ApplicationError>> + Send;
}

/// Read port audit nằm trong cùng transaction authorization; không có phương thức đọc global auth audit.
pub trait AuditReadTransaction: WorkspaceTransaction {
    /// Clock sau mọi workspace/member locks; dùng recheck expiry và cutoff ingestion, không dựa clock trước lock wait.
    fn audit_now(&mut self)
    -> impl Future<Output = Result<DateTime<Utc>, ApplicationError>> + Send;
    /// Trả projection allowlist đúng workspace, cutoff và keyset; không SELECT raw diff hoặc credential.
    fn list_audit(
        &mut self,
        workspace_id: Uuid,
        cutoff: DateTime<Utc>,
        before: Option<&iot_domain::audit::AuditCursor>,
        limit: i64,
    ) -> impl Future<Output = Result<Vec<iot_domain::audit::AuditEntry>, ApplicationError>> + Send;
}

/// Ticket consume cùng unit of work; application không được mở socket trước khi commit winner.
pub trait RealtimeTransaction: WorkspaceTransaction {
    /// Persist ticket digest/binding đã tạo từ current session và workspace admission.
    fn insert_ticket(
        &mut self,
        ticket: &iot_domain::realtime::NewWebSocketTicket,
    ) -> impl Future<Output = Result<(), ApplicationError>> + Send;
    /// CAS consume một lần, recheck Session/User/Workspace/Membership/grant/version dưới cùng fence.
    fn consume_ticket(
        &mut self,
        digest: [u8; 32],
    ) -> impl Future<
        Output = Result<Option<iot_domain::realtime::RealtimeBinding>, ApplicationError>,
    > + Send;
}

/// Kết quả lưu trữ receipt; application quyết định mismatch/pending/replay và current authorization.
pub enum WorkspaceCreationClaim {
    Reserved,
    Existing {
        request_digest: [u8; 32],
        workspace_id: Option<Uuid>,
    },
}

/// Receipt global theo User/route/key; cùng transaction với create aggregate và required audit.
pub trait WorkspaceCreationTransaction: WorkspaceTransaction {
    /// Dưới User fence, thay receipt hết24h và insert `IN_PROGRESS` hoặc trả receipt hiện hành, không raw key.
    fn reserve_workspace_creation(
        &mut self,
        user_id: Uuid,
        key_digest: [u8; 32],
        request_digest: [u8; 32],
        now: DateTime<Utc>,
    ) -> impl Future<Output = Result<WorkspaceCreationClaim, ApplicationError>> + Send;
    /// Chốt minimal sanitized result chỉ workspaceId, không credential/raw response tùy ý.
    fn complete_workspace_creation(
        &mut self,
        user_id: Uuid,
        key_digest: [u8; 32],
        workspace_id: Uuid,
    ) -> impl Future<Output = Result<(), ApplicationError>> + Send;
}
