//! Metadata lời mời chỉ dành cho current Admin; không chứa bearer token hoặc digest.

use crate::workspace::WorkspaceRole;
use chrono::{DateTime, Utc};
use uuid::Uuid;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum InvitationStatus {
    Pending,
    Used,
    Revoked,
    Expired,
}

/// Projection metadata allowlist; snapshot issuer authority nội bộ không được serialize vào danh sách.
pub struct InvitationMetadata {
    pub workspace_id: Uuid,
    pub invitation_id: Uuid,
    pub email_normalized: String,
    pub role: WorkspaceRole,
    pub issued_at: DateTime<Utc>,
    pub expires_at: DateTime<Utc>,
    pub used_at: Option<DateTime<Utc>>,
    pub revoked_at: Option<DateTime<Utc>>,
    pub expired_at: Option<DateTime<Utc>>,
    pub revision: i64,
}

/// Keyset nội bộ, transport phải ký và bind workspace/filter trước khi nhận từ client.
pub struct InvitationCursor {
    pub issued_at: DateTime<Utc>,
    pub invitation_id: Uuid,
}

/// Metadata cùng trạng thái đã tính bằng clock server tại lần đọc; không phải signed transport cursor.
pub struct InvitationView {
    pub metadata: InvitationMetadata,
    pub status: InvitationStatus,
}

/// Trang bounded; cursor chỉ là continuation nội bộ và không tự chứng minh workspace/filter hoặc quyền.
pub struct InvitationPage {
    pub entries: Vec<InvitationView>,
    pub next_cursor: Option<InvitationCursor>,
}

#[derive(Debug, PartialEq, Eq)]
pub enum RevokeDecision {
    Noop,
    Revoke { next_revision: i64 },
}
#[derive(Debug, PartialEq, Eq)]
pub enum RevokeFailure {
    Used,
    StaleRevision,
    Unavailable,
    RevisionExhausted,
}

impl InvitationMetadata {
    /**
     * Xác định trạng thái hiển thị từ terminal evidence và deadline, không chờ cron expire.
     * Input
     * Param: now — DB clock sau current authority/row locks, không event time từ client.
     * Output: trạng thái metadata; không cấp quyền nhận lời mời hoặc mutate.
     */
    #[must_use]
    pub fn status(&self, now: DateTime<Utc>) -> InvitationStatus {
        if self.used_at.is_some() {
            InvitationStatus::Used
        } else if self.revoked_at.is_some() {
            InvitationStatus::Revoked
        } else if self.expired_at.is_some() || now >= self.expires_at {
            InvitationStatus::Expired
        } else {
            InvitationStatus::Pending
        }
    }

    /**
     * Admit revoke bằng CAS và terminal truth; used phải Conflict dù caller mang revision cũ.
     * Input
     * Param: `expected_revision` — If-Match dương phải khớp row dưới lock.
     * Param: now — admission clock sau khóa, dùng cả expiry/future-issue guard.
     * Output: no-op nếu đã revoked đúng revision hoặc revision tiếp theo cho pending.
     * # Errors
     * Used/stale/unavailable/overflow; không thay account, credential, grant hoặc audit.
     */
    pub fn revoke(
        &self,
        expected_revision: i64,
        now: DateTime<Utc>,
    ) -> Result<RevokeDecision, RevokeFailure> {
        if self.used_at.is_some() {
            return Err(RevokeFailure::Used);
        }
        if expected_revision <= 0 || expected_revision != self.revision {
            return Err(RevokeFailure::StaleRevision);
        }
        if self.revoked_at.is_some() {
            return Ok(RevokeDecision::Noop);
        }
        if self.expired_at.is_some() || now >= self.expires_at || now < self.issued_at {
            return Err(RevokeFailure::Unavailable);
        }
        Ok(RevokeDecision::Revoke {
            next_revision: self
                .revision
                .checked_add(1)
                .ok_or(RevokeFailure::RevisionExhausted)?,
        })
    }
}
