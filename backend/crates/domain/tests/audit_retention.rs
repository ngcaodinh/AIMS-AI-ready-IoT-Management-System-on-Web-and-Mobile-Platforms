//! Retention dùng UTC và batch hữu hạn; không cần DB hoặc đồng hồ hệ thống trong policy test.

use chrono::{TimeDelta, TimeZone, Utc};
use iot_domain::audit_retention::{AuditRetentionRun, BatchLimit};
use uuid::Uuid;

/// Run đóng cutoff một lần theo720 giờ UTC; event đúng cutoff không bị xóa.
#[test]
fn fixed_run_keeps_exact_cutoff_and_uses_absolute_utc_duration() {
    let started_at = Utc.with_ymd_and_hms(2026, 11, 2, 12, 0, 0).unwrap();
    let run = AuditRetentionRun::new(Uuid::new_v4(), started_at).unwrap();
    assert_eq!(run.cutoff(), started_at - TimeDelta::hours(720));
    assert!(!run.is_expired(run.cutoff()));
    assert!(run.is_expired(run.cutoff() - TimeDelta::microseconds(1)));
    assert!(!run.is_expired(run.cutoff() + TimeDelta::microseconds(1)));
}

/// Batch cấm zero/unbounded để job không giữ khóa và transaction vô hạn.
#[test]
fn batch_limit_rejects_unbounded_or_empty_work() {
    assert!(BatchLimit::new(0).is_none());
    assert!(BatchLimit::new(-1).is_none());
    assert!(BatchLimit::new(1001).is_none());
    assert_eq!(BatchLimit::new(1).unwrap().get(), 1);
    assert_eq!(BatchLimit::new(1000).unwrap().get(), 1000);
}
