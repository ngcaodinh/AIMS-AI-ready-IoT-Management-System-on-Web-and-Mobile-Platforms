//! Policy reset account tạm: Admin workspace không có quyền reset account global đã kích hoạt.

use crate::identity::AccountStatus;
use chrono::{DateTime, Duration, Utc};
use uuid::Uuid;

/// Origin chỉ workflow tạo account tạm mới được ghi; legacy unknown không được tự suy là origin này.
pub const TEMPORARY_ACCOUNT_ORIGIN: &str = "ADMIN_TEMPORARY_V1";

/// Snapshot được đọc dưới target User và workspace/member fences, không chứa verifier.
pub struct PasswordResetTarget {
    pub user_id: Uuid,
    pub account_status: AccountStatus,
    pub must_change_password: bool,
    pub activated_at: Option<DateTime<Utc>>,
    pub known_temporary_origin: bool,
    pub only_workspace_id: Option<Uuid>,
    pub membership_present: bool,
    pub membership_revision: i64,
}

/// Lỗi policy giữ nguyên ngữ nghĩa protected/revision/authority cho transport ánh xạ.
#[derive(Debug, PartialEq, Eq)]
pub enum PasswordResetFailure {
    GlobalAccountProtected,
    StaleRevision,
    Forbidden,
    RateLimited { retry_after_seconds: i64 },
}

impl PasswordResetTarget {
    /**
     * Bảo vệ account global trước reset bằng current origin, activation và phạm vi membership.
     * Input
     * Param: `workspace_id` — tenant Admin đã được admit trong cùng transaction.
     * Param: `expected_revision` — If-Match của membership cần reset, phải dương và hiện hành.
     * Output: cho phép reset; không tự thay credential hoặc tạo password.
     * # Errors
     * Từ chối protected account, membership không còn hoặc revision cũ.
     */
    pub fn authorize(
        &self,
        workspace_id: Uuid,
        expected_revision: i64,
    ) -> Result<(), PasswordResetFailure> {
        if !self.membership_present {
            return Err(PasswordResetFailure::Forbidden);
        }
        if self.account_status != AccountStatus::Active
            || !self.must_change_password
            || self.activated_at.is_some()
            || !self.known_temporary_origin
            || self.only_workspace_id != Some(workspace_id)
        {
            return Err(PasswordResetFailure::GlobalAccountProtected);
        }
        if expected_revision <= 0 || self.membership_revision != expected_revision {
            return Err(PasswordResetFailure::StaleRevision);
        }
        Ok(())
    }
}

/**
 * Kiểm sliding quota reset từ durable admissions để các instance không có counter riêng.
 * Input
 * Param: recent — tối đa5 mốc reset thành công trong15 phút, do adapter đọc dưới cùng fence.
 * Param: now — clock DB hiện hành sau khóa.
 * Output: cho phép admission tiếp theo hoặc thời gian chờ giây, không làm trượt cửa sổ do retry.
 * # Errors
 * Rate limit khi đã có5 reset chưa hết15 phút.
 */
pub fn admit_reset(
    recent: &[DateTime<Utc>],
    now: DateTime<Utc>,
) -> Result<(), PasswordResetFailure> {
    let cutoff = now - Duration::minutes(15);
    let current: Vec<_> = recent.iter().filter(|stamp| **stamp > cutoff).collect();
    if current.len() < 5 {
        return Ok(());
    }
    let oldest = current.into_iter().min().copied().unwrap_or(now);
    let remaining = oldest + Duration::minutes(15) - now;
    let retry_after_seconds =
        (remaining.num_seconds() + i64::from(remaining.subsec_nanos() > 0)).max(1);
    Err(PasswordResetFailure::RateLimited {
        retry_after_seconds,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Dựng account tạm tổng hợp đủ điều kiện, không gắn với DB hoặc credential thật.
    fn target(workspace_id: Uuid) -> PasswordResetTarget {
        PasswordResetTarget {
            user_id: Uuid::new_v4(),
            account_status: AccountStatus::Active,
            must_change_password: true,
            activated_at: None,
            known_temporary_origin: true,
            only_workspace_id: Some(workspace_id),
            membership_present: true,
            membership_revision: 3,
        }
    }

    /// NULL activation của legacy unknown và membership ngoài tenant đều không mở quyền reset.
    #[test]
    fn rejects_activated_unknown_and_multi_workspace_accounts() {
        let workspace = Uuid::new_v4();
        let mut account = target(workspace);
        assert_eq!(account.authorize(workspace, 3), Ok(()));
        account.known_temporary_origin = false;
        assert_eq!(
            account.authorize(workspace, 3),
            Err(PasswordResetFailure::GlobalAccountProtected)
        );
        account.known_temporary_origin = true;
        account.activated_at = DateTime::from_timestamp(1_700_000_000, 0);
        assert_eq!(
            account.authorize(workspace, 3),
            Err(PasswordResetFailure::GlobalAccountProtected)
        );
        account.activated_at = None;
        account.only_workspace_id = None;
        assert_eq!(
            account.authorize(workspace, 3),
            Err(PasswordResetFailure::GlobalAccountProtected)
        );
    }

    /// CAS và current membership vẫn bắt buộc dù account chưa kích hoạt và đúng origin.
    #[test]
    fn rejects_stale_revision_and_missing_membership() {
        let workspace = Uuid::new_v4();
        let mut account = target(workspace);
        assert_eq!(
            account.authorize(workspace, 2),
            Err(PasswordResetFailure::StaleRevision)
        );
        account.membership_present = false;
        assert_eq!(
            account.authorize(workspace, 3),
            Err(PasswordResetFailure::Forbidden)
        );
    }

    /// Reset thứ6 bị chặn; mốc đúng15 phút không còn chiếm quota và retry không gia hạn admission.
    #[test]
    fn sliding_budget_reopens_at_exact_boundary() {
        let now = DateTime::from_timestamp(1_700_000_000, 0).unwrap();
        let recent = vec![now; 5];
        assert_eq!(
            admit_reset(&recent, now),
            Err(PasswordResetFailure::RateLimited {
                retry_after_seconds: 900
            })
        );
        assert_eq!(
            admit_reset(&recent, now + Duration::seconds(899)),
            Err(PasswordResetFailure::RateLimited {
                retry_after_seconds: 1
            })
        );
        assert_eq!(admit_reset(&recent, now + Duration::seconds(900)), Ok(()));
        assert_eq!(admit_reset(&recent[..4], now), Ok(()));
    }
}
