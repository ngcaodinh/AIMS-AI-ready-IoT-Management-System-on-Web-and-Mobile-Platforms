//! Policy IAM thuần; clock và dữ liệu đã khóa do application/adapter cung cấp.

use chrono::{DateTime, TimeDelta, Utc};
use std::fmt;
use uuid::Uuid;

/// Chuỗi nhạy cảm chỉ được mở ở boundary cần dùng; Debug không chứa nội dung.
pub struct SecretString(String);

impl SecretString {
    /**
     * Nhận quyền sở hữu chuỗi để tránh tự động lộ qua Debug của DTO.
     * Input
     * Param: value — credential/verifier do boundary tin cậy cung cấp; không tự sinh entropy.
     * Output: giá trị được che trong chẩn đoán, không phải cơ chế mã hóa bộ nhớ.
     */
    #[must_use]
    pub fn new(value: String) -> Self {
        Self(value)
    }

    /// Mở chuỗi tại crypto/transport boundary; caller không được log hoặc lưu plaintext.
    #[must_use]
    pub fn expose(&self) -> &str {
        &self.0
    }
}

impl fmt::Debug for SecretString {
    /// Che giá trị trong lỗi/test/DTO để chẩn đoán không vô tình phát capability.
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("SecretString([REDACTED])")
    }
}

/// Loại client không phải role hoặc bằng chứng thiết bị đáng tin cậy.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ClientType {
    Web,
    Android,
    Ios,
}

impl ClientType {
    /**
     * Đối chiếu kênh credential để metadata Android/IOS dùng chung bearer và Web chỉ dùng cookie.
     * Input
     * Param: transport — loại kênh đã tách từ header; không chứng thực hệ điều hành hoặc cấp quyền.
     * Output: true khi hai loại cùng dùng cookie hoặc cùng dùng bearer theo OQ-AUTH-007.
     */
    #[must_use]
    pub fn matches_transport(self, transport: Self) -> bool {
        (self == Self::Web) == (transport == Self::Web)
    }
}

/// Trạng thái account toàn cục, độc lập với membership từng tenant.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AccountStatus {
    Active,
    Disabled,
}

/// Lý do từ chối quyền thuần; application ánh xạ sang lỗi use case, adapter không quyết định HTTP.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AccessFailure {
    SessionInvalid,
    SessionExpired,
    SessionRevoked,
    ContextMismatch,
    PasswordChangeRequired,
    Forbidden,
}

/// Dữ liệu account đọc dưới User fence; verifier luôn che khi Debug.
#[derive(Debug)]
pub struct AccountSnapshot {
    pub user_id: Uuid,
    pub password_verifier: SecretString,
    pub status: AccountStatus,
    pub must_change_password: bool,
}

/// Selector chưa xác thực; digest không tự cấp quyền, `expected_context` chỉ chống nhầm phiên Web.
pub struct SessionProof {
    pub token_digest: [u8; 32],
    pub expected_context: Option<Uuid>,
}

/// Session admission bất biến đọc dưới khóa; revoked/expiry vẫn phải kiểm từng use case.
pub struct SessionSnapshot {
    pub session_id: Uuid,
    pub user_id: Uuid,
    pub auth_context_id: Uuid,
    pub client_type: ClientType,
    pub limited: bool,
    pub expires_at: DateTime<Utc>,
    pub revoked_at: Option<DateTime<Utc>>,
}

/// Principal không cho caller tự dựng bằng trường public; chỉ domain authorization mới tạo được.
pub struct Principal {
    user_id: Uuid,
    session_id: Uuid,
    client_type: ClientType,
}

impl Principal {
    /// Lấy identity account đã được policy xác thực để scope query/command tiếp theo.
    #[must_use]
    pub fn user_id(&self) -> Uuid {
        self.user_id
    }
    /// Lấy identity session đã xác thực để audit binding, không phải raw token.
    #[must_use]
    pub fn session_id(&self) -> Uuid {
        self.session_id
    }
    /// Lấy metadata transport từ session đã lưu để ghi audit nhất quán.
    #[must_use]
    pub fn client_type(&self) -> ClientType {
        self.client_type
    }
}

impl SessionSnapshot {
    /**
     * Cho phép thu hồi đúng session đã nhận diện kể cả expired/revoked/disabled, để logout idempotent.
     * Input
     * Param: account — account cùng User fence; identity phải khớp session.
     * Param: proof — context Web phải khớp trước bất kỳ mutation/clear-cookie ở transport.
     * Output: principal chỉ dùng revoke, không cấp quyền đọc workspace.
     * # Errors
     * `SessionInvalid` nếu identity sai; `ContextMismatch` nếu cookie/context không cùng phiên.
     */
    pub fn authorize_revocation(
        &self,
        account: &AccountSnapshot,
        proof: &SessionProof,
    ) -> Result<Principal, AccessFailure> {
        if self.user_id != account.user_id {
            return Err(AccessFailure::SessionInvalid);
        }
        if self.client_type == ClientType::Web
            && proof.expected_context != Some(self.auth_context_id)
        {
            return Err(AccessFailure::ContextMismatch);
        }
        Ok(Principal {
            user_id: self.user_id,
            session_id: self.session_id,
            client_type: self.client_type,
        })
    }
    /**
     * Kiểm toàn bộ authority hiện hành trước khi tạo principal, không phụ thuộc database hay middleware.
     * Input
     * Param: account — account cùng User fence; identity phải khớp session.
     * Param: proof — context chưa tin cậy; Web phải khớp trước limited guard.
     * Param: now — thời gian được lấy sau khi nhận khóa để không bỏ sót expiry trong lúc chờ.
     * Param: `allow_limited` — chỉ bật cho use case phục hồi như đổi mật khẩu.
     * Output: principal đã xác thực hoặc lý do từ chối; không tạo quyền workspace tại đây.
     * # Errors
     * `SessionInvalid` nếu account/identity không còn hợp lệ, `SessionRevoked` nếu phiên đã thu hồi,
     * `SessionExpired` nếu hết hạn, hoặc lỗi context/limited; không chứa dữ liệu nhạy cảm.
     */
    pub fn authorize(
        &self,
        account: &AccountSnapshot,
        proof: &SessionProof,
        now: DateTime<Utc>,
        allow_limited: bool,
    ) -> Result<Principal, AccessFailure> {
        if self.user_id != account.user_id || account.status != AccountStatus::Active {
            return Err(AccessFailure::SessionInvalid);
        }
        // Chỉ phân biệt revoked/expired sau khi account của session vẫn hợp lệ; session sai/disabled giữ lỗi tổng quát.
        if self.revoked_at.is_some() {
            return Err(AccessFailure::SessionRevoked);
        }
        if self.expires_at <= now {
            return Err(AccessFailure::SessionExpired);
        }
        if self.client_type == ClientType::Web
            && proof.expected_context != Some(self.auth_context_id)
        {
            return Err(AccessFailure::ContextMismatch);
        }
        if !allow_limited && (self.limited || account.must_change_password) {
            return Err(AccessFailure::PasswordChangeRequired);
        }
        Ok(Principal {
            user_id: self.user_id,
            session_id: self.session_id,
            client_type: self.client_type,
        })
    }
}

/// Cửa sổ failure fixed-window theo contract5 lần/15phút, không reset bởi đăng nhập thành công.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct LoginWindow {
    pub failures: i32,
    pub started_at: Option<DateTime<Utc>>,
}

/// Quyết định thuần; adapter chỉ lưu cửa sổ do application chọn dưới bucket lock.
pub enum LoginAdmission {
    Allowed {
        next_failure: LoginWindow,
        expired: bool,
    },
    Limited {
        retry_after_seconds: i64,
    },
}

impl LoginWindow {
    /**
     * Tính rate admission từ snapshot đã khóa; failure thứ5 được chấp nhận ghi, request thứ6 bị chặn.
     * Input
     * Param: now — clock quan sát sau bucket lock; expiry đúng mốc900 giây được mở cửa sổ mới.
     * Output: cửa sổ cần ghi nếu credential sai, hoặc Retry-After làm tròn lên tối thiểu1 giây.
     */
    #[must_use]
    pub fn admit(self, now: DateTime<Utc>) -> LoginAdmission {
        // 900 giây là15 phút theo contract; TimeDelta là duration tuyệt đối, không ngày lịch DST.
        let expired = self
            .started_at
            .is_some_and(|start| now >= start + TimeDelta::seconds(900));
        let failures = if expired { 0 } else { self.failures };
        if failures >= 5 {
            return LoginAdmission::Limited {
                retry_after_seconds: self
                    .started_at
                    .map_or(900, |start| 900 - (now - start).num_seconds())
                    .max(1),
            };
        }
        LoginAdmission::Allowed {
            next_failure: Self {
                failures: failures + 1,
                started_at: if expired {
                    Some(now)
                } else {
                    self.started_at.or(Some(now))
                },
            },
            expired,
        }
    }
}

/// Hàng session mới do use case tạo; adapter chỉ bind digest, không thấy token gốc.
pub struct NewSession {
    pub session_id: Uuid,
    pub user_id: Uuid,
    pub token_digest: [u8; 32],
    pub auth_context_id: Uuid,
    pub limited: bool,
    pub client_type: ClientType,
    pub issued_at: DateTime<Utc>,
    pub expires_at: DateTime<Utc>,
}

/// Credential chỉ phát sau commit; `SecretString` bảo vệ mọi Debug của kết quả.
#[derive(Debug)]
pub struct IssuedSession {
    pub token: SecretString,
    pub session_id: Uuid,
    pub user_id: Uuid,
    pub auth_context_id: Uuid,
    pub limited: bool,
    pub expires_at: DateTime<Utc>,
}

/// Audit giữ actor/scope đã xác thực; detail hữu hạn không nhận raw payload hoặc secret.
pub struct AuditRecord {
    pub workspace_id: Option<Uuid>,
    pub actor_user_id: Option<Uuid>,
    pub session_id: Option<Uuid>,
    pub detail: crate::audit_write::AuditDetail,
    pub client_type: ClientType,
    pub correlation_id: Uuid,
}

/// Phạm vi revoke do use case chọn; không nhận session/user identity từ body HTTP.
pub enum SessionRevocation {
    Current { user_id: Uuid, session_id: Uuid },
    AllForUser { user_id: Uuid },
}
