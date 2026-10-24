use iot_domain::preferences::{DisplayTimezone, PreferenceFailure, PreferenceSnapshot};
use uuid::Uuid;

/// Default legacy không tạo dữ liệu; timezone exact text và cận an toàn được kiểm tại constructor.
#[test]
fn legacy_defaults_and_timezone_shape_are_explicit() {
    let preference = PreferenceSnapshot::legacy(Uuid::new_v4());
    assert_eq!(preference.display_timezone, "UTC");
    assert_eq!(preference.revision, 1);
    assert!(DisplayTimezone::new("").is_none());
    assert!(DisplayTimezone::new(" \n ").is_none());
    assert!(DisplayTimezone::new("Asia/Ho\0Chi_Minh").is_none());
    assert_eq!(
        DisplayTimezone::new("Asia/Ho_Chi_Minh").unwrap().as_str(),
        "Asia/Ho_Chi_Minh"
    );
}

/// CAS không last-write-wins hoặc wrap counter; policy domain không tự xác nhận timezone có trong IANA.
#[test]
fn preference_revision_is_checked_before_transition() {
    let mut preference = PreferenceSnapshot::legacy(Uuid::new_v4());
    let timezone = DisplayTimezone::new("Asia/Ho_Chi_Minh").unwrap();
    assert_eq!(
        preference.change(&timezone, 0),
        Err(PreferenceFailure::StaleRevision)
    );
    let next = preference.change(&timezone, 1).unwrap();
    assert_eq!(next.display_timezone, "Asia/Ho_Chi_Minh");
    assert_eq!(next.revision, 2);
    assert_eq!(
        next.change(&timezone, 1),
        Err(PreferenceFailure::StaleRevision)
    );
    preference.revision = i64::MAX;
    assert_eq!(
        preference.change(&timezone, i64::MAX),
        Err(PreferenceFailure::RevisionExhausted)
    );
}
