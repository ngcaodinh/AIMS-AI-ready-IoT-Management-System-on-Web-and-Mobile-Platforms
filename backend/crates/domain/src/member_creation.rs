//! Tạo member phân biệt account mới với invitation; không mang secret vào receipt hoặc Debug.

use crate::{
    identity::SecretString,
    input::{normalize_email, normalize_member_display_name},
    workspace::WorkspaceRole,
};
use chrono::{DateTime, Utc};
use uuid::Uuid;

/// Request đã validate; alias là tên riêng của tenant, không là profile global.
pub struct MemberCreationRequest {
    raw_email: String,
    email_normalized: String,
    display_name: String,
    role: WorkspaceRole,
}

impl MemberCreationRequest {
    /**
     * Xác thực email và canonicalize displayName trước khi mở transaction hoặc hash password.
     * Input
     * Param: email — raw email cần normalize theo policy account hiện hành.
     * Param: `display_name` — alias tenant cần trim, NFC và giới hạn1–100 code point theo contract.
     * Param: role — ADMIN/USER dự định cấp trong tenant.
     * Output: request hợp lệ hoặc None; không tạo account hoặc cấp quyền.
     */
    #[must_use]
    pub fn new(email: &str, display_name: &str, role: WorkspaceRole) -> Option<Self> {
        let email_normalized = normalize_email(email).ok()?;
        let display_name = normalize_member_display_name(display_name).ok()?;
        Some(Self {
            raw_email: email.to_owned(),
            email_normalized,
            display_name,
            role,
        })
    }

    /// Trả email canonical cho unique lookup; không dùng làm audit metadata hoặc metric label.
    #[must_use]
    pub fn email_normalized(&self) -> &str {
        &self.email_normalized
    }

    /**
     * Trả alias tenant đã trim và chuẩn hóa NFC để ghi Membership mới và tạo fingerprint ổn định.
     * Alias này thuộc Membership, không thay đổi tên hồ sơ toàn cục của account hiện hữu.
     */
    #[must_use]
    pub fn display_name(&self) -> &str {
        &self.display_name
    }

    /// Trả role workspace đã được decode ở boundary, không là quyền global.
    #[must_use]
    pub const fn role(&self) -> WorkspaceRole {
        self.role
    }

    /**
     * Mã hóa intent tạo member để cùng idempotency key không thể đổi email, alias hoặc role.
     * Namespace và length-prefix giữ ranh giới field; email giữ nguyên raw input còn alias dùng
     * giá trị đã trim/NFC để retry chỉ khác khoảng trắng ngoài biên vẫn cùng intent.
     * Output: byte sequence ổn định để fingerprint; không chứa secret.
     */
    #[must_use]
    pub fn request_bytes(&self) -> Vec<u8> {
        let mut bytes = b"member-create:v1\0".to_vec();
        for value in [&self.raw_email, &self.display_name] {
            bytes.extend_from_slice(&(value.len() as u128).to_be_bytes());
            bytes.extend_from_slice(value.as_bytes());
        }
        bytes.push(if self.role == WorkspaceRole::Admin {
            1
        } else {
            2
        });
        bytes
    }
}

/// Kết quả không secret đủ cho receipt; invitation chưa tạo membership trong tenant.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum MemberCreationOutcome {
    Created {
        user_id: Uuid,
    },
    Invitation {
        invitation_id: Uuid,
        expires_at: DateTime<Utc>,
    },
}

/// Response một lần; secret là password nếu Created hoặc accept token nếu Invitation, None khi replay.
pub struct IssuedMemberCreation {
    pub workspace_id: Uuid,
    pub outcome: MemberCreationOutcome,
    pub secret: Option<SecretString>,
}
