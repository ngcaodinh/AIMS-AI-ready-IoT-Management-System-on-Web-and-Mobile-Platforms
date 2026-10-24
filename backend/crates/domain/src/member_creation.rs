//! Tạo member phân biệt account mới với invitation; không mang secret vào receipt hoặc Debug.

use crate::{identity::SecretString, input::normalize_email, workspace::WorkspaceRole};
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
     * Xác thực email và displayName bắt buộc trước khi mở transaction hoặc hash password.
     * Input
     * Param: email — raw email cần normalize theo policy account hiện hành.
     * Param: `display_name` — alias tenant, giữ exact text; không blank/NUL, không tự đặt max chưa có contract.
     * Param: role — ADMIN/USER dự định cấp trong tenant.
     * Output: request hợp lệ hoặc None; không tạo account hoặc cấp quyền.
     */
    #[must_use]
    pub fn new(email: &str, display_name: &str, role: WorkspaceRole) -> Option<Self> {
        let email_normalized = normalize_email(email).ok()?;
        if display_name.trim().is_empty() || display_name.contains('\0') {
            return None;
        }
        Some(Self {
            raw_email: email.to_owned(),
            email_normalized,
            display_name: display_name.to_owned(),
            role,
        })
    }

    /// Trả email canonical cho unique lookup; không dùng làm audit metadata hoặc metric label.
    #[must_use]
    pub fn email_normalized(&self) -> &str {
        &self.email_normalized
    }

    /// Trả alias nguyên bản chỉ để ghi Membership mới, không sửa account đã tồn tại.
    #[must_use]
    pub fn display_name(&self) -> &str {
        &self.display_name
    }

    /// Trả role workspace đã được decode ở boundary, không là quyền global.
    #[must_use]
    pub const fn role(&self) -> WorkspaceRole {
        self.role
    }

    /// Encode raw body có length-prefix và namespace để cùng key không thể đổi email/alias/role.
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
