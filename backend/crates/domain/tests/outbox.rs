//! Lease policy thuần bảo vệ batch hữu hạn và receipt generation, không cần executor/DB.

use iot_domain::outbox::{ClaimOptions, CloseConsumer, LeaseReceipt, RetryDelay};
use uuid::Uuid;

/// Lease1…300 giây và batch1…1000 khớp native claim, không cho LIMIT NULL/unbounded qua core.
#[test]
fn claim_bounds_match_native_operation() {
    for (seconds, limit) in [(0, 1), (301, 1), (1, 0), (1, 1001)] {
        assert!(ClaimOptions::new(seconds, limit).is_none());
    }
    let options = ClaimOptions::new(300, 1000).unwrap();
    assert_eq!(
        (options.lease_seconds(), options.batch_limit()),
        (300, 1000)
    );
    assert!(ClaimOptions::new(1, 1).is_some());
    assert!(RetryDelay::new(0).is_none());
    assert!(RetryDelay::new(301).is_none());
    assert_eq!(RetryDelay::new(300).unwrap().seconds(), 300);
}

/// Receipt không nhận event nil/generation0; consumer không là chuỗi tùy ý do request điều khiển.
#[test]
fn receipt_requires_event_and_positive_epoch() {
    let consumer = CloseConsumer::Session;
    assert!(LeaseReceipt::new(Uuid::nil(), consumer, 1).is_none());
    assert!(LeaseReceipt::new(Uuid::new_v4(), consumer, 0).is_none());
    assert!(LeaseReceipt::new(Uuid::new_v4(), consumer, -1).is_none());
    let event = Uuid::new_v4();
    let receipt = LeaseReceipt::new(event, consumer, i64::MAX).unwrap();
    assert_eq!(
        (receipt.event_id(), receipt.consumer(), receipt.generation()),
        (event, consumer, i64::MAX)
    );
    assert_eq!(consumer.code(), "REALTIME_SESSION_CLOSE");
    assert_eq!(CloseConsumer::Workspace.code(), "REALTIME_WORKSPACE_CLOSE");
}
