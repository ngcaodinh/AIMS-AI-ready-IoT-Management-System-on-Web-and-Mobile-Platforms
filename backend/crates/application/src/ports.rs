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
use std::collections::HashSet;
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
    /**
     * Cấp token invitation theo wire format base64url không padding, tách biệt token phiên dạng hex.
     * Output: chuỗi entropy256 bit cùng digest để lưu; caller chỉ phát raw token sau commit.
     * # Errors
     * `Unavailable` nếu adapter không hỗ trợ định dạng invitation an toàn.
     */
    fn issue_member_invitation_token(&self) -> Result<(SecretString, [u8; 32]), ApplicationError> {
        Err(ApplicationError::Unavailable)
    }
    /**
     * Sinh mật khẩu tạm từ một capability CSPRNG mới, dùng riêng với token phiên.
     * Prefix chỉ bảo đảm thành phần hoa/thường/số, không được tính là entropy hoặc credential độc lập.
     * # Output
     * Password có toàn bộ random suffix nguyên vẹn, chỉ được phát sau commit của caller.
     * # Errors
     * Unavailable nếu adapter sinh output không đáp ứng policy9–128; không băm/phát mật khẩu yếu.
     */
    fn issue_temporary_password(&self) -> Result<SecretString, ApplicationError> {
        let (random, _) = self.issue_token();
        let password = SecretString::new(format!("Aa1{}", random.expose()));
        iot_domain::input::validate_new_password(password.expose(), "/temporaryPassword").map_err(
            // Lỗi của adapter không được phản chiếu password hoặc phát credential không đạt policy.
            |_| ApplicationError::Unavailable,
        )?;
        Ok(password)
    }
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
    /// Resolve User ID để chọn limiter đổi mật khẩu trước User lock; chưa cấp authority và phải khóa lại session.
    fn session_user_id(
        &mut self,
        proof: &SessionProof,
    ) -> impl Future<Output = Result<Uuid, ApplicationError>> + Send;
    /// Khóa bucket riêng theo User ID để các lần sai dùng chung ngân sách giữa session và instance.
    fn lock_password_change_bucket(
        &mut self,
        user_id: Uuid,
    ) -> impl Future<Output = Result<LoginWindow, ApplicationError>> + Send;
    /// Ghi cửa sổ lỗi mật khẩu riêng trong transaction đang giữ bucket; thành công không xóa failure còn hạn.
    fn save_password_change_window(
        &mut self,
        user_id: Uuid,
        window: LoginWindow,
    ) -> impl Future<Output = Result<(), ApplicationError>> + Send;
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

/// Ticket issuance nằm cùng workspace authorization/audit unit of work.
pub trait RealtimeTransaction: WorkspaceTransaction {
    /**
     * Lưu digest và binding của ticket trong cùng unit of work để capability chỉ được trả sau commit.
     * # Input
     * Param: ticket — digest không thể đảo ngược cùng session/workspace/authz version đã được application admit.
     * # Output
     * Hoàn tất khi ticket được ghi trong transaction hiện hành.
     * # Errors
     * Lỗi constraint hoặc storage được adapter chuẩn hóa; transaction không được commit ticket dở dang.
     */
    fn insert_ticket(
        &mut self,
        ticket: &iot_domain::realtime::NewWebSocketTicket,
    ) -> impl Future<Output = Result<(), ApplicationError>> + Send;
}

/// Read port theo dõi session đang mở socket; kết quả chỉ dùng để đóng local connection đã cũ.
pub trait RealtimeSessionStore: Clone + Send + Sync {
    /**
     * Consume ticket nguyên tử và chỉ trả khi kết quả commit hoặc rollback đã xác định.
     * Input
     * Param: digest — SHA-256 digest của capability, không chứa ticket thô.
     * Output: binding đã commit nếu ticket còn hiệu lực; None nếu ticket không tồn tại hoặc đã dùng.
     * Errors: lỗi storage/commit đã chuẩn hóa; adapter phải hoàn tất hoặc loại checkout trước khi trả.
     */
    fn consume_realtime_ticket(
        &self,
        digest: [u8; 32],
    ) -> impl Future<
        Output = Result<Option<iot_domain::realtime::RealtimeBinding>, ApplicationError>,
    > + Send;

    /**
     * Trả các session trong danh sách còn active theo clock DB, không cấp quyền nghiệp vụ.
     * Input
     * Param: session_ids — tập ID lấy từ registry cục bộ, không đến từ request hoặc client.
     * Output: subset chưa revoke, chưa hết hạn và account còn active.
     * Errors: lỗi storage đã được adapter lọc; caller đóng local sockets fail-closed.
     */
    fn active_realtime_sessions(
        &self,
        session_ids: Vec<Uuid>,
    ) -> impl Future<Output = Result<HashSet<Uuid>, ApplicationError>> + Send;

    /**
     * Kiểm tra một session trước ACK và chỉ trả sau khi adapter hoàn tất checkout riêng.
     * Input
     * Param: session_id — session lấy từ binding vừa consume, không đến từ frame hoặc query client.
     * Output: true nếu session/account còn active theo clock DB; false nếu đã revoke/hết hạn.
     * Errors: lỗi storage đã chuẩn hóa; adapter phải trả hoặc loại checkout trước khi caller nhả quota.
     */
    fn active_realtime_session_for_handshake(
        &self,
        session_id: Uuid,
    ) -> impl Future<Output = Result<bool, ApplicationError>> + Send;
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
