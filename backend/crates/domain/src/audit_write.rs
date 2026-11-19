//! Manifest audit cho use case đã build; kiểu hữu hạn không nhận secret hoặc free text.

use crate::{
    membership::{MembershipSnapshot, MembershipStatus},
    workspace::WorkspaceRole,
};
use uuid::Uuid;

/// Hai series vận hành hữu hạn; không dùng email, digest hoặc correlation làm metric label.
#[derive(Clone, Copy)]
pub enum FailureAuditKind {
    Login,
    PasswordChange,
}

/// Metadata member không chứa alias/email; diff chỉ nêu tên trường đã đổi.
#[derive(Debug)]
pub struct MembershipAudit {
    pub user_id: Uuid,
    pub revision_before: i64,
    pub revision_after: i64,
    pub authorization_version_before: i64,
    pub authorization_version_after: i64,
    pub role_before: WorkspaceRole,
    pub role_after: WorkspaceRole,
    pub status_before: MembershipStatus,
    pub status_after: MembershipStatus,
    pub alias_changed: bool,
    pub no_op: bool,
    pub diff: Vec<&'static str>,
}

impl MembershipAudit {
    /**
     * Chụp transition đã authorize, chỉ ghi tên trường đổi và không sao chép hồ sơ riêng.
     * Input
     * Param: before — member dưới khóa trước CAS.
     * Param: after — member cùng identity sau transition hợp lệ.
     * Output: ID/enum/counter, cờ no-op và diff allowlist; không giữ nội dung alias/email.
     */
    #[must_use]
    pub fn between(before: &MembershipSnapshot, after: &MembershipSnapshot) -> Self {
        let mut diff = Vec::with_capacity(3);
        if before.role != after.role {
            diff.push("role");
        }
        if before.status != after.status {
            diff.push("status");
        }
        if before.alias != after.alias {
            diff.push("alias");
        }
        Self {
            user_id: before.user_id,
            revision_before: before.revision,
            revision_after: after.revision,
            authorization_version_before: before.authorization_version,
            authorization_version_after: after.authorization_version,
            role_before: before.role,
            role_after: after.role,
            status_before: before.status,
            status_after: after.status,
            alias_changed: before.alias != after.alias,
            no_op: diff.is_empty(),
            diff,
        }
    }
}

/// Mỗi variant là một điểm audit đã triển khai; không có API nhận JSON, tên, email hoặc credential.
#[derive(Debug)]
pub enum AuditDetail {
    DeviceRegistered {
        device_id: Uuid,
        template_version_id: Uuid,
        actuator_count: u64,
    },
    LoginFailed,
    LoginSucceeded {
        session_id: Uuid,
        limited: bool,
    },
    Logout {
        session_id: Uuid,
    },
    PasswordChangeFailed {
        user_id: Uuid,
    },
    PasswordChanged {
        user_id: Uuid,
    },
    WorkspaceCreated {
        workspace_id: Uuid,
    },
    InvitationCreated {
        invitation_id: Uuid,
        role: WorkspaceRole,
    },
    InvitationAccepted {
        invitation_id: Uuid,
        grant_generation: i64,
    },
    InvitationRevoked {
        invitation_id: Uuid,
        revision_before: i64,
        revision_after: i64,
    },
    TemporaryAccountCreated {
        user_id: Uuid,
    },
    MembershipCreated {
        user_id: Uuid,
        role: WorkspaceRole,
    },
    PreferencesChanged {
        user_id: Uuid,
        revision_before: i64,
        revision_after: i64,
        timezone_changed: bool,
    },
    TemplateCreated {
        template_id: Uuid,
    },
    TemplateDraftChanged {
        template_id: Uuid,
        revision_before: i64,
        revision_after: i64,
    },
    TemplatePublished {
        template_id: Uuid,
        template_version_id: Uuid,
        version_number: i32,
        revision_before: i64,
        revision_after: i64,
    },
    TemporaryPasswordReset {
        user_id: Uuid,
    },
    MembershipLastAdminDenied {
        user_id: Uuid,
    },
    MembershipResetAdmitted {
        user_id: Uuid,
        revision_before: i64,
        revision_after: i64,
    },
    MembershipChanged(MembershipAudit),
    RealtimeTicketIssued {
        ticket_id: Uuid,
    },
}

impl AuditDetail {
    /// Chọn action từ manifest nội bộ; client không thể gán event tùy ý qua chuỗi request.
    #[must_use]
    pub const fn event_type(&self) -> &'static str {
        match self {
            Self::DeviceRegistered { .. } => "DEVICE_REGISTERED",
            Self::LoginFailed => "LOGIN_FAILED",
            Self::LoginSucceeded { .. } => "LOGIN_SUCCEEDED",
            Self::Logout { .. } => "LOGOUT",
            Self::PasswordChangeFailed { .. } => "PASSWORD_CHANGE_FAILED",
            Self::PasswordChanged { .. } => "PASSWORD_CHANGED",
            Self::WorkspaceCreated { .. } => "WORKSPACE_CREATED",
            Self::InvitationCreated { .. } => "INVITATION_CREATED",
            Self::InvitationAccepted { .. } => "INVITATION_ACCEPTED",
            Self::InvitationRevoked { .. } => "INVITATION_REVOKED",
            Self::TemporaryAccountCreated { .. } => "TEMPORARY_ACCOUNT_CREATED",
            Self::MembershipCreated { .. } => "MEMBERSHIP_CREATED",
            Self::PreferencesChanged { .. } => "PREFERENCES_CHANGED",
            Self::TemplateCreated { .. } => "TEMPLATE_CREATED",
            Self::TemplateDraftChanged { .. } => "TEMPLATE_DRAFT_CHANGED",
            Self::TemplatePublished { .. } => "TEMPLATE_PUBLISHED",
            Self::TemporaryPasswordReset { .. } => "TEMPORARY_PASSWORD_RESET",
            Self::MembershipLastAdminDenied { .. } => "MEMBERSHIP_LAST_ADMIN_DENIED",
            Self::MembershipResetAdmitted { .. } => "MEMBERSHIP_RESET_ADMITTED",
            Self::MembershipChanged(_) => "MEMBERSHIP_CHANGED",
            Self::RealtimeTicketIssued { .. } => "REALTIME_TICKET_ISSUED",
        }
    }

    /// Giữ enum storage hiện hành; SUCCESS của mutation chỉ nói commit DB, không chứng nhận thiết bị.
    #[must_use]
    pub const fn outcome(&self) -> &'static str {
        match self {
            Self::LoginFailed
            | Self::PasswordChangeFailed { .. }
            | Self::MembershipLastAdminDenied { .. } => "FAILURE",
            _ => "SUCCESS",
        }
    }

    /// Lý do hữu hạn không chứa lỗi provider, email hoặc nội dung người dùng nhập.
    #[must_use]
    pub const fn reason_code(&self) -> &'static str {
        match self {
            Self::DeviceRegistered { .. } => "DEVICE_REGISTRY_CREATED",
            Self::LoginFailed | Self::PasswordChangeFailed { .. } => "INVALID_CREDENTIALS",
            Self::LoginSucceeded { .. } => "CREDENTIALS_VERIFIED",
            Self::Logout { .. } => "SELF_LOGOUT",
            Self::PasswordChanged { .. } => "SELF_PASSWORD_CHANGED",
            Self::WorkspaceCreated { .. } => "WORKSPACE_CREATED",
            Self::InvitationCreated { .. } => "INVITATION_ISSUED",
            Self::InvitationAccepted { .. } => "INVITATION_ACCEPTED",
            Self::InvitationRevoked { .. } => "ADMIN_INVITATION_REVOKED",
            Self::TemporaryAccountCreated { .. } => "ADMIN_TEMPORARY_CREATE",
            Self::MembershipCreated { .. } => "MEMBERSHIP_ADMITTED",
            Self::PreferencesChanged { .. } => "SELF_PREFERENCES_CHANGED",
            Self::TemplateCreated { .. } => "TEMPLATE_CREATED",
            Self::TemplateDraftChanged { .. } => "TEMPLATE_DRAFT_REPLACED",
            Self::TemplatePublished { .. } => "TEMPLATE_PUBLISHED",
            Self::TemporaryPasswordReset { .. } => "ADMIN_TEMPORARY_RESET",
            Self::MembershipLastAdminDenied { .. } => "LAST_ADMIN_REQUIRED",
            Self::MembershipResetAdmitted { .. } => "TEMPORARY_RESET_ADMITTED",
            Self::MembershipChanged(_) => "MEMBERSHIP_PATCHED",
            Self::RealtimeTicketIssued { .. } => "REALTIME_TICKET_ISSUED",
        }
    }

    /// Resource chỉ là snapshot lịch sử; anonymous failure không được dựng account identity giả.
    #[must_use]
    pub const fn resource(&self) -> Option<(&'static str, Uuid)> {
        match self {
            Self::DeviceRegistered { device_id, .. } => Some(("DEVICE", *device_id)),
            Self::LoginFailed => None,
            Self::LoginSucceeded { session_id, .. } | Self::Logout { session_id } => {
                Some(("SESSION", *session_id))
            }
            Self::PasswordChangeFailed { user_id }
            | Self::PasswordChanged { user_id }
            | Self::TemporaryPasswordReset { user_id, .. }
            | Self::TemporaryAccountCreated { user_id }
            | Self::PreferencesChanged { user_id, .. } => Some(("USER", *user_id)),
            Self::WorkspaceCreated { workspace_id } => Some(("WORKSPACE", *workspace_id)),
            Self::InvitationCreated { invitation_id, .. }
            | Self::InvitationAccepted { invitation_id, .. }
            | Self::InvitationRevoked { invitation_id, .. } => Some(("INVITATION", *invitation_id)),
            Self::MembershipChanged(member) => Some(("MEMBERSHIP", member.user_id)),
            Self::MembershipResetAdmitted { user_id, .. }
            | Self::MembershipCreated { user_id, .. }
            | Self::MembershipLastAdminDenied { user_id } => Some(("MEMBERSHIP", *user_id)),
            Self::RealtimeTicketIssued { ticket_id } => Some(("WEBSOCKET_TICKET", *ticket_id)),
            Self::TemplateCreated { template_id }
            | Self::TemplateDraftChanged { template_id, .. } => Some(("TEMPLATE", *template_id)),
            Self::TemplatePublished {
                template_version_id,
                ..
            } => Some(("TEMPLATE_VERSION", *template_version_id)),
        }
    }

    /// Khóa scope theo action; global credential evidence không được gán workspace để đọc qua tenant audit.
    #[must_use]
    pub const fn is_workspace_scoped(&self) -> bool {
        matches!(
            self,
            Self::WorkspaceCreated { .. }
                | Self::DeviceRegistered { .. }
                | Self::InvitationCreated { .. }
                | Self::InvitationAccepted { .. }
                | Self::InvitationRevoked { .. }
                | Self::MembershipCreated { .. }
                | Self::MembershipChanged(_)
                | Self::MembershipLastAdminDenied { .. }
                | Self::MembershipResetAdmitted { .. }
                | Self::RealtimeTicketIssued { .. }
                | Self::TemplateCreated { .. }
                | Self::TemplateDraftChanged { .. }
                | Self::TemplatePublished { .. }
        )
    }
}
