//! Scope tenant và validation workspace không phụ thuộc storage/framework.

use crate::identity::{AccessFailure, Principal};
use uuid::Uuid;

/// Vai trò workspace hữu hạn; không có global role suy ra từ account.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum WorkspaceRole {
    Admin,
    User,
}

/// Đầu vào đã validate về hình dạng; tồn tại timezone cần catalog port kiểm riêng.
pub struct WorkspaceDraft {
    pub name: String,
    pub description: Option<String>,
    pub timezone: String,
}

impl WorkspaceDraft {
    /**
     * Chặn tên rỗng/ngoài cận và mô tả quá dài trước khi mở transaction mutation.
     * Input
     * Param: name — tên cần trim và kiểm1–100 Unicode scalar theo contract.
     * Param: description — mô tả tùy chọn tối đa500 scalar.
     * Param: timezone — tên timezone cần adapter kiểm tồn tại, không SQL interpolation.
     * Output: draft có shape hợp lệ hoặc None; không nhận creator/role từ request.
     */
    pub fn new(name: &str, description: Option<&str>, timezone: &str) -> Option<Self> {
        let name = name.trim();
        if !(1..=100).contains(&name.chars().count())
            || description.is_some_and(|text| text.chars().count() > 500)
            || timezone.is_empty()
            || timezone.len() > 100
        {
            return None;
        }
        Some(Self {
            name: name.to_owned(),
            description: description.map(str::to_owned),
            timezone: timezone.to_owned(),
        })
    }
}

/// Projection picker; không được tái sử dụng như authority cho mutation khác.
#[derive(Debug)]
pub struct WorkspaceSummary {
    pub workspace_id: Uuid,
    pub name: String,
    pub role: WorkspaceRole,
    pub revision: i64,
}

/// Snapshot được adapter đọc dưới parent/membership locks, phải qua domain policy trước khi dùng.
pub struct WorkspaceSnapshot {
    pub workspace_id: Uuid,
    pub user_id: Uuid,
    pub workspace_active: bool,
    pub membership_active: bool,
    pub grant_active: bool,
    pub role: WorkspaceRole,
    pub grant_generation: i64,
    pub workspace_authorization_version: i64,
    pub membership_authorization_version: i64,
}

/// Kết quả admission của một request, không là credential/cache quyền cho request tương lai.
#[derive(Debug)]
pub struct WorkspaceAdmission {
    pub workspace_id: Uuid,
    pub user_id: Uuid,
    pub role: WorkspaceRole,
    pub grant_generation: i64,
    pub workspace_authorization_version: i64,
    pub membership_authorization_version: i64,
}

impl WorkspaceSnapshot {
    /**
     * Giao quyền chỉ khi scope thuộc đúng principal và mọi trạng thái/grant còn hiệu lực.
     * Input
     * Param: principal — principal được session policy xác thực trong cùng transaction.
     * Param: `require_admin` — bật cho hành động đặc quyền; không nhận role tự khai từ request.
     * Output: admission hoặc forbidden chung, không tiết lộ tenant khác.
     * # Errors
     * Trả lỗi từ chối hoặc lỗi đã mô tả ở trên; không chứa dữ liệu nhạy cảm.
     */
    pub fn authorize(
        &self,
        principal: &Principal,
        require_admin: bool,
    ) -> Result<WorkspaceAdmission, AccessFailure> {
        if !self.workspace_active {
            return Err(AccessFailure::Forbidden);
        }
        self.authorize_membership(principal, require_admin)
    }

    /**
     * Cho current Admin đọc audit kể cả tenant SUSPENDED/ARCHIVED theo FEAT-TN-040; không mở mutation/live data.
     * Input
     * Param: principal — full session/account đã xác thực; membership/grant vẫn phải hiện hành.
     * Output: admission chỉ cho use case audit.
     * # Errors
     * Forbidden khi thiếu quyền hoặc sai principal.
     */
    pub fn authorize_audit(
        &self,
        principal: &Principal,
    ) -> Result<WorkspaceAdmission, AccessFailure> {
        self.authorize_membership(principal, true)
    }

    /**
     * Kiểm identity, membership và grant chung cho live admission hoặc read audit allowlisted.
     * Input
     * Param: principal — identity từ session policy cùng transaction.
     * Param: `require_admin` — đặc quyền do use case domain chọn, không lấy từ client.
     * Output: admission hiện hành; Errors: Forbidden không tiết lộ tenant khác.
     */
    fn authorize_membership(
        &self,
        principal: &Principal,
        require_admin: bool,
    ) -> Result<WorkspaceAdmission, AccessFailure> {
        if self.user_id != principal.user_id()
            || !self.membership_active
            || !self.grant_active
            || (require_admin && self.role != WorkspaceRole::Admin)
        {
            return Err(AccessFailure::Forbidden);
        }
        Ok(WorkspaceAdmission {
            workspace_id: self.workspace_id,
            user_id: self.user_id,
            role: self.role,
            grant_generation: self.grant_generation,
            workspace_authorization_version: self.workspace_authorization_version,
            membership_authorization_version: self.membership_authorization_version,
        })
    }
}
