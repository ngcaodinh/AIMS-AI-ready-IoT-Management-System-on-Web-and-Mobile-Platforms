//! State transition membership thuần; không cấp quyền global hoặc hồi sinh grant đã remove.

use crate::workspace::WorkspaceRole;
use uuid::Uuid;

/// Trạng thái theo workspace, độc lập account global ACTIVE/DISABLED.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MembershipStatus {
    Active,
    Suspended,
    Removed,
}

/// Phân biệt trường vắng với explicit null của PATCH alias.
#[derive(Clone, Default)]
pub enum AliasChange {
    #[default]
    Unchanged,
    Set(Option<String>),
}

/// Patch không nhận user/workspace/global status; transport phải reject unknown fields trước khi dựng.
#[derive(Clone, Default)]
pub struct MembershipPatch {
    pub role: Option<WorkspaceRole>,
    pub status: Option<MembershipStatus>,
    pub alias: AliasChange,
}

/// Trạng thái member và đủ dữ liệu current aggregate để bảo vệ last capable Admin.
#[derive(Clone)]
pub struct MembershipSnapshot {
    pub workspace_id: Uuid,
    pub user_id: Uuid,
    pub role: WorkspaceRole,
    pub status: MembershipStatus,
    pub alias: Option<String>,
    pub revision: i64,
    pub authorization_version: i64,
    pub grant_generation: i64,
    pub account_capable: bool,
    pub other_capable_admin_count: i64,
}

/// Lỗi transition không phụ thuộc SQLSTATE hoặc HTTP status.
#[derive(Debug, PartialEq, Eq)]
pub enum MembershipFailure {
    InvalidPatch,
    StaleRevision,
    LastAdminRequired,
    RejoinRequired,
    RevisionExhausted,
}

impl MembershipSnapshot {
    /**
     * Tính trạng thái kế tiếp sau CAS và last Admin; không cho PATCH thay invitation khi rejoin.
     * Input
     * Param: patch — các trường thực sự hiện diện, alias null khác trường vắng.
     * Param: `expected_revision` — revision người sửa đã đọc; phải khớp current row dưới khóa.
     * Output: snapshot kế tiếp; role/status change tăng auth version, mọi patch tăng revision.
     * # Errors
     * Empty patch, stale CAS, mất last capable Admin, rejoin trái workflow hoặc counter hết miền.
     */
    pub fn apply(
        &self,
        patch: &MembershipPatch,
        expected_revision: i64,
    ) -> Result<Self, MembershipFailure> {
        if expected_revision <= 0 || expected_revision != self.revision {
            return Err(MembershipFailure::StaleRevision);
        }
        if patch.role.is_none()
            && patch.status.is_none()
            && matches!(patch.alias, AliasChange::Unchanged)
        {
            return Err(MembershipFailure::InvalidPatch);
        }
        if self.status == MembershipStatus::Removed {
            return Err(MembershipFailure::RejoinRequired);
        }
        let mut next = self.clone();
        next.role = patch.role.unwrap_or(self.role);
        next.status = patch.status.unwrap_or(self.status);
        if let AliasChange::Set(alias) = &patch.alias {
            next.alias.clone_from(alias);
        }
        // Chỉ Admin ACTIVE với account capable được tính; không coi account tạm/disabled là người bàn giao quyền.
        if self.account_capable
            && self.status == MembershipStatus::Active
            && self.role == WorkspaceRole::Admin
            && (next.role != WorkspaceRole::Admin || next.status != MembershipStatus::Active)
            && self.other_capable_admin_count == 0
        {
            return Err(MembershipFailure::LastAdminRequired);
        }
        next.revision = self
            .revision
            .checked_add(1)
            .ok_or(MembershipFailure::RevisionExhausted)?;
        if next.role != self.role || next.status != self.status {
            next.authorization_version = self
                .authorization_version
                .checked_add(1)
                .ok_or(MembershipFailure::RevisionExhausted)?;
        }
        Ok(next)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    /// Dựng Admin duy nhất đang capable để kiểm policy mà không cần storage.
    fn admin() -> MembershipSnapshot {
        MembershipSnapshot {
            workspace_id: Uuid::new_v4(),
            user_id: Uuid::new_v4(),
            role: WorkspaceRole::Admin,
            status: MembershipStatus::Active,
            alias: Some("alias".to_owned()),
            revision: 4,
            authorization_version: 7,
            grant_generation: 1,
            account_capable: true,
            other_capable_admin_count: 0,
        }
    }
    /// Không cho role/status transition làm mất Admin capable cuối hoặc bỏ qua stale revision.
    #[test]
    fn protects_last_admin_and_revision() {
        let current = admin();
        let patch = MembershipPatch {
            role: Some(WorkspaceRole::User),
            ..MembershipPatch::default()
        };
        assert!(matches!(
            current.apply(&patch, 4),
            Err(MembershipFailure::LastAdminRequired)
        ));
        assert!(matches!(
            current.apply(&patch, 3),
            Err(MembershipFailure::StaleRevision)
        ));
        assert!(matches!(
            current.apply(&MembershipPatch::default(), 4),
            Err(MembershipFailure::InvalidPatch)
        ));
    }
    /// Explicit null xóa alias; alias-only không tăng auth version hoặc thay grant.
    #[test]
    fn alias_presence_preserves_authority_and_clear_semantics() {
        let current = admin();
        let patch = MembershipPatch {
            alias: AliasChange::Set(None),
            ..MembershipPatch::default()
        };
        let next = current.apply(&patch, 4).unwrap();
        assert!(next.alias.is_none());
        assert_eq!(
            (
                next.revision,
                next.authorization_version,
                next.grant_generation
            ),
            (5, 7, 1)
        );
    }
    /// Suspend/resume giữ grant; REMOVED không được PATCH ACTIVE để revive authority cũ.
    #[test]
    fn status_changes_advance_authority_and_removed_requires_reinvite() {
        let mut current = admin();
        current.other_capable_admin_count = 1;
        let patch = MembershipPatch {
            status: Some(MembershipStatus::Suspended),
            ..MembershipPatch::default()
        };
        let next = current.apply(&patch, 4).unwrap();
        assert_eq!((next.authorization_version, next.grant_generation), (8, 1));
        current.status = MembershipStatus::Removed;
        assert!(matches!(
            current.apply(
                &MembershipPatch {
                    status: Some(MembershipStatus::Active),
                    ..MembershipPatch::default()
                },
                4
            ),
            Err(MembershipFailure::RejoinRequired)
        ));
    }

    /// Cùng account có thể mang role khác nhau theo tenant; patch chỉ tạo snapshot mới cho tenant đích.
    #[test]
    fn role_patch_changes_only_the_target_workspace_membership() {
        let mut workspace_a = admin();
        workspace_a.role = WorkspaceRole::User;
        workspace_a.other_capable_admin_count = 1;
        let mut workspace_b = workspace_a.clone();
        workspace_b.workspace_id = Uuid::new_v4();
        workspace_b.role = WorkspaceRole::Admin;

        let updated_a = workspace_a
            .apply(
                &MembershipPatch {
                    role: Some(WorkspaceRole::Admin),
                    ..MembershipPatch::default()
                },
                workspace_a.revision,
            )
            .unwrap();

        assert_eq!(updated_a.user_id, workspace_b.user_id);
        assert_ne!(updated_a.workspace_id, workspace_b.workspace_id);
        assert_eq!(updated_a.role, WorkspaceRole::Admin);
        assert_eq!(workspace_b.role, WorkspaceRole::Admin);
        assert_eq!(workspace_b.revision, 4);
        assert_eq!(workspace_b.authorization_version, 7);
    }
}
