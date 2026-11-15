use chrono::{TimeDelta, TimeZone, Utc};
use iot_domain::{
    identity::{
        AccessFailure, AccountSnapshot, AccountStatus, ClientType, LoginAdmission, LoginWindow,
        SecretString, SessionProof, SessionSnapshot,
    },
    workspace::{WorkspaceDraft, WorkspaceRole, WorkspaceSnapshot},
};
use uuid::Uuid;

/** Giữ ranh giới cookie/bearer theo contract; metadata IOS/Android không làm bearer trở thành cookie Web. */
#[test]
fn client_metadata_matches_only_its_credential_transport() {
    for stored in [ClientType::Web, ClientType::Android, ClientType::Ios] {
        for transport in [ClientType::Web, ClientType::Android, ClientType::Ios] {
            assert_eq!(
                stored.matches_transport(transport),
                (stored == ClientType::Web) == (transport == ClientType::Web)
            );
        }
    }
}

/// Kiểm ranh giới failure5/6 và expiry đúng900 giây để rule không phụ thuộc PostgreSQL.
#[test]
fn limiter_preserves_five_failures_and_reopens_at_exact_expiry() {
    let start = Utc.timestamp_opt(1_700_000_000, 0).unwrap();
    let mut window = LoginWindow {
        failures: 0,
        started_at: None,
    };
    for count in 1..=5 {
        match window.admit(start) {
            LoginAdmission::Allowed { next_failure, .. } => window = next_failure,
            LoginAdmission::Limited { .. } => panic!("failure budget closed too early"),
        }
        assert_eq!(window.failures, count);
    }
    assert!(matches!(
        window.admit(start + TimeDelta::milliseconds(899_001)),
        LoginAdmission::Limited {
            retry_after_seconds: 1
        }
    ));
    assert!(matches!(
        window.admit(start + TimeDelta::seconds(900)),
        LoginAdmission::Allowed {
            next_failure: LoginWindow { failures: 1, .. },
            expired: true
        }
    ));
}

/// Context mismatch được ưu tiên trước limited guard; expiry/disabled/revoked không tạo principal.
#[test]
fn session_authorization_checks_current_authority_and_context_before_limited() {
    let now = Utc.timestamp_opt(1_700_000_000, 0).unwrap();
    let user = Uuid::new_v4();
    let context = Uuid::new_v4();
    let mut account = AccountSnapshot {
        user_id: user,
        password_verifier: SecretString::new(String::new()),
        status: AccountStatus::Active,
        must_change_password: true,
    };
    let mut session = SessionSnapshot {
        session_id: Uuid::new_v4(),
        user_id: user,
        auth_context_id: context,
        client_type: ClientType::Web,
        limited: true,
        expires_at: now + TimeDelta::hours(24),
        revoked_at: None,
    };
    let mut proof = SessionProof {
        token_digest: [0; 32],
        expected_context: Some(Uuid::new_v4()),
    };
    assert!(matches!(
        session.authorize(&account, &proof, now, false),
        Err(AccessFailure::ContextMismatch)
    ));
    proof.expected_context = Some(context);
    assert!(matches!(
        session.authorize(&account, &proof, now, false),
        Err(AccessFailure::PasswordChangeRequired)
    ));
    assert!(session.authorize(&account, &proof, now, true).is_ok());
    assert!(matches!(
        session.authorize(&account, &proof, session.expires_at, true),
        Err(AccessFailure::SessionInvalid)
    ));
    account.status = AccountStatus::Disabled;
    assert!(matches!(
        session.authorize(&account, &proof, now, true),
        Err(AccessFailure::SessionInvalid)
    ));
    account.status = AccountStatus::Active;
    session.revoked_at = Some(now);
    assert!(matches!(
        session.authorize(&account, &proof, now, true),
        Err(AccessFailure::SessionInvalid)
    ));
}

/// Dù có quyền khác ở tenantA, principal không được dùng snapshot tenantB hoặc grant đã revoke.
#[test]
fn workspace_policy_rejects_foreign_member_stale_grant_and_insufficient_role() {
    let now = Utc::now();
    let user = Uuid::new_v4();
    let account = AccountSnapshot {
        user_id: user,
        password_verifier: SecretString::new(String::new()),
        status: AccountStatus::Active,
        must_change_password: false,
    };
    let session = SessionSnapshot {
        session_id: Uuid::new_v4(),
        user_id: user,
        auth_context_id: Uuid::new_v4(),
        client_type: ClientType::Android,
        limited: false,
        expires_at: now + TimeDelta::hours(24),
        revoked_at: None,
    };
    let proof = SessionProof {
        token_digest: [0; 32],
        expected_context: None,
    };
    let principal = session.authorize(&account, &proof, now, false).unwrap();
    let mut workspace = WorkspaceSnapshot {
        workspace_id: Uuid::new_v4(),
        user_id: user,
        workspace_active: true,
        membership_active: true,
        grant_active: true,
        role: WorkspaceRole::User,
        grant_generation: 1,
        workspace_authorization_version: 1,
        membership_authorization_version: 1,
    };
    assert!(workspace.authorize(&principal, false).is_ok());
    assert!(matches!(
        workspace.authorize(&principal, true),
        Err(AccessFailure::Forbidden)
    ));
    assert!(workspace.authorize_audit(&principal).is_err());
    workspace.role = WorkspaceRole::Admin;
    workspace.workspace_active = false;
    assert!(workspace.authorize_audit(&principal).is_ok());
    assert!(workspace.authorize(&principal, true).is_err());
    workspace.grant_active = false;
    assert!(workspace.authorize_audit(&principal).is_err());
    workspace.workspace_active = true;
    assert!(matches!(
        workspace.authorize(&principal, false),
        Err(AccessFailure::Forbidden)
    ));
    workspace.grant_active = true;
    workspace.user_id = Uuid::new_v4();
    assert!(matches!(
        workspace.authorize(&principal, false),
        Err(AccessFailure::Forbidden)
    ));
}

/// Cận tên/mô tả áp dụng trước DB; credential không xuất hiện qua Debug của domain value.
#[test]
fn draft_and_secret_values_preserve_boundary_contracts() {
    assert!(WorkspaceDraft::new("  ", None, "UTC").is_none());
    assert!(WorkspaceDraft::new(&"a".repeat(101), None, "UTC").is_none());
    assert!(WorkspaceDraft::new("valid", Some(&"a".repeat(501)), "UTC").is_none());
    let secret = SecretString::new(Uuid::new_v4().to_string());
    assert!(!format!("{secret:?}").contains(secret.expose()));
}
