//! Contract audit: global/anonymous không bị gán scope giả, metadata member không giữ alias.

use iot_domain::{
    audit_write::{AuditDetail, MembershipAudit},
    membership::{MembershipSnapshot, MembershipStatus},
    workspace::WorkspaceRole,
};
use uuid::Uuid;

/// Audit template chỉ chứa identity/revision/version, scope theo workspace và không sao chép schema người dùng.
#[test]
fn template_audit_separates_root_and_published_version() {
    let template_id = Uuid::new_v4();
    let version_id = Uuid::new_v4();
    let details = [
        AuditDetail::TemplateCreated { template_id },
        AuditDetail::TemplateDraftChanged {
            template_id,
            revision_before: 1,
            revision_after: 2,
        },
        AuditDetail::TemplatePublished {
            template_id,
            template_version_id: version_id,
            version_number: 1,
            revision_before: 2,
            revision_after: 3,
        },
    ];
    for detail in &details {
        assert!(detail.is_workspace_scoped());
        assert_eq!(detail.outcome(), "SUCCESS");
    }
    assert_eq!(details[0].resource(), Some(("TEMPLATE", template_id)));
    assert_eq!(details[1].resource(), Some(("TEMPLATE", template_id)));
    assert_eq!(
        details[2].resource(),
        Some(("TEMPLATE_VERSION", version_id))
    );
    assert_eq!(details[2].event_type(), "TEMPLATE_PUBLISHED");
}

/// Failed login anonymous không tạo resource account giả hoặc trả lý do tiết lộ email tồn tại.
#[test]
fn anonymous_failure_has_no_fabricated_resource() {
    let detail = AuditDetail::LoginFailed;
    assert_eq!(detail.resource(), None);
    assert_eq!(detail.reason_code(), "INVALID_CREDENTIALS");
    assert_eq!(detail.outcome(), "FAILURE");
}

/// Session evidence liên kết ID phiên đã cấp, không dùng token hoặc account làm khóa resource.
#[test]
fn session_events_reference_only_persisted_identity() {
    let session_id = Uuid::new_v4();
    let detail = AuditDetail::LoginSucceeded {
        session_id,
        limited: true,
    };
    assert_eq!(detail.resource(), Some(("SESSION", session_id)));
    assert_eq!(detail.event_type(), "LOGIN_SUCCEEDED");
    assert_eq!(detail.outcome(), "SUCCESS");
}

/// Mật khẩu toàn account không thành lịch sử tenant; workspace chỉ nhận admission của membership.
#[test]
fn password_reset_separates_global_credential_and_local_admission() {
    let user_id = Uuid::new_v4();
    let global = AuditDetail::TemporaryPasswordReset { user_id };
    let local = AuditDetail::MembershipResetAdmitted {
        user_id,
        revision_before: 1,
        revision_after: 2,
    };
    assert!(!global.is_workspace_scoped());
    assert!(local.is_workspace_scoped());
    assert_eq!(global.resource(), Some(("USER", user_id)));
    assert_eq!(local.resource(), Some(("MEMBERSHIP", user_id)));
}

/// Tạo credential toàn cục không lộ vào tenant audit; tenant chỉ biết member/role đã admit.
#[test]
fn temporary_account_create_separates_global_and_workspace_evidence() {
    let user_id = Uuid::new_v4();
    let global = AuditDetail::TemporaryAccountCreated { user_id };
    let local = AuditDetail::MembershipCreated {
        user_id,
        role: WorkspaceRole::User,
    };
    assert!(!global.is_workspace_scoped());
    assert!(local.is_workspace_scoped());
    assert_eq!(global.resource(), Some(("USER", user_id)));
    assert_eq!(local.resource(), Some(("MEMBERSHIP", user_id)));
}

/// Snapshot audit chỉ giữ transition enum/revision và cờ alias; không giữ nội dung tên riêng.
#[test]
fn membership_evidence_keeps_transition_without_private_alias() {
    let before = MembershipSnapshot {
        workspace_id: Uuid::new_v4(),
        user_id: Uuid::new_v4(),
        role: WorkspaceRole::User,
        status: MembershipStatus::Active,
        alias: Some("synthetic private alias".into()),
        revision: 3,
        authorization_version: 2,
        grant_generation: 1,
        account_capable: true,
        other_capable_admin_count: 1,
    };
    let mut after = before.clone();
    after.alias = None;
    after.revision = 4;
    let audit = MembershipAudit::between(&before, &after);
    assert!(audit.alias_changed);
    assert_eq!(audit.revision_before, 3);
    assert_eq!(audit.revision_after, 4);
    assert_eq!(
        audit.authorization_version_before,
        audit.authorization_version_after
    );
    assert!(!format!("{audit:?}").contains("synthetic private alias"));
}
