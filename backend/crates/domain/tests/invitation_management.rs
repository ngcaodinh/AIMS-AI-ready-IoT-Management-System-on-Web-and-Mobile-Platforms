use chrono::{DateTime, Duration, Utc};
use iot_domain::{
    invitation_management::{InvitationMetadata, InvitationStatus, RevokeDecision, RevokeFailure},
    workspace::WorkspaceRole,
};
use uuid::Uuid;

/// Fixture metadata không chứa token hoặc digest, chỉ dữ liệu được Admin phép xem.
fn invitation() -> InvitationMetadata {
    let now = DateTime::<Utc>::from_timestamp(1_700_000_000, 0).unwrap();
    InvitationMetadata {
        workspace_id: Uuid::new_v4(),
        invitation_id: Uuid::new_v4(),
        email_normalized: "recipient@example.invalid".to_owned(),
        role: WorkspaceRole::User,
        issued_at: now,
        expires_at: now + Duration::hours(24),
        used_at: None,
        revoked_at: None,
        expired_at: None,
        revision: 1,
    }
}

/// Expiry theo clock không cần cron materialize, cutoff exclusive giống accept.
#[test]
fn metadata_status_uses_current_deadline_and_terminal_evidence() {
    let mut row = invitation();
    assert_eq!(row.status(row.issued_at), InvitationStatus::Pending);
    assert_eq!(row.status(row.expires_at), InvitationStatus::Expired);
    row.revoked_at = Some(row.issued_at);
    assert_eq!(row.status(row.expires_at), InvitationStatus::Revoked);
}

/// Revoke CAS chỉ pending; current revoked no-op, used Conflict và stale không sửa row.
#[test]
fn revoke_preserves_terminal_truth_and_revision() {
    let mut row = invitation();
    assert_eq!(
        row.revoke(1, row.issued_at),
        Ok(RevokeDecision::Revoke { next_revision: 2 })
    );
    assert_eq!(
        row.revoke(2, row.issued_at),
        Err(RevokeFailure::StaleRevision)
    );
    assert_eq!(
        row.revoke(1, row.expires_at),
        Err(RevokeFailure::Unavailable)
    );
    row.revoked_at = Some(row.issued_at);
    row.revision = 2;
    assert_eq!(row.revoke(2, row.issued_at), Ok(RevokeDecision::Noop));
    row.revoked_at = None;
    row.used_at = Some(row.issued_at);
    assert_eq!(row.revoke(1, row.issued_at), Err(RevokeFailure::Used));
}

/// Counter hết miền hoặc clock lùi không tạo token terminal giả.
#[test]
fn revoke_rejects_overflow_and_future_issue() {
    let mut row = invitation();
    assert_eq!(
        row.revoke(1, row.issued_at - Duration::microseconds(1)),
        Err(RevokeFailure::Unavailable)
    );
    row.revision = i64::MAX;
    assert_eq!(
        row.revoke(i64::MAX, row.issued_at),
        Err(RevokeFailure::RevisionExhausted)
    );
}
