//! Biên identity và assignment registry; fixture không giả bằng chứng board hoặc broker.

use iot_domain::{
    device::{ApprovedDeviceModels, DeviceDraft, DevicePin, DeviceValidation},
    workspace::{WorkspaceAdmission, WorkspaceRole},
};
use uuid::Uuid;

/// Tạo input synthetic với serial canonical, không credential hoặc hardware do client tự nhận.
fn draft(serial: &str, name: &str) -> DeviceDraft {
    DeviceDraft {
        serial_number: serial.into(),
        name: name.into(),
        model: "ESP32".into(),
        template_version_id: Uuid::new_v4(),
        owner_user_id: Uuid::new_v4(),
    }
}

/// Serial phân biệt hoa/thường và không được sửa identity bằng trim/casefold.
#[test]
fn serial_validation_preserves_identity_and_boundaries() {
    for serial in ["", " A", "A ", "_A", "é", "A/B", "A\n", "A\0"] {
        assert!(matches!(
            draft(serial, "Name").validate(),
            Err(DeviceValidation::SerialInvalid)
        ));
    }
    assert!(draft(&"A".repeat(64), "Name").validate().is_ok());
    assert!(draft(&"A".repeat(65), "Name").validate().is_err());
    for serial in ["A", "a", "A-._:9"] {
        assert_eq!(
            draft(serial, "Name").validate().unwrap().serial_number,
            serial
        );
    }
}

/// Cận tên đếm Unicode scalar sau chuẩn hóa, không byte và không đặt reported value từ safeValue.
#[test]
fn names_trim_and_enforce_scalar_lengths() {
    assert_eq!(
        draft("A", "  Thiết bị  ").validate().unwrap().name,
        "Thiết bị"
    );
    assert!(draft("A", &"ế".repeat(100)).validate().is_ok());
    assert!(draft("A", &"ế".repeat(101)).validate().is_err());
    assert!(draft("A", " \t\n ").validate().is_err());
}

/// Exact snapshot equality không thay thế allowlist bootstrap; policy rỗng phải đóng.
#[test]
fn model_policy_requires_approved_exact_snapshot() {
    assert!(ApprovedDeviceModels::new(vec![]).is_err());
    let policy = ApprovedDeviceModels::new(vec!["ESP32".into()]).unwrap();
    assert!(policy.validate("ESP32", "ESP32").is_ok());
    assert_eq!(
        policy.validate("esp32", "ESP32"),
        Err(DeviceValidation::ModelMismatch)
    );
    assert_eq!(
        policy.validate("OTHER", "OTHER"),
        Err(DeviceValidation::ModelUnsupported)
    );
}

/// USER đúng owner vẫn không được dùng pin của workspace khác; Admin cũng phải khớp tenant.
#[test]
fn schema_access_requires_current_scope_and_assignment() {
    let workspace = Uuid::new_v4();
    let owner = Uuid::new_v4();
    let pin = DevicePin {
        workspace_id: workspace,
        device_id: Uuid::new_v4(),
        owner_user_id: owner,
        template_version_id: Uuid::new_v4(),
    };
    let mut admission = WorkspaceAdmission {
        workspace_id: workspace,
        user_id: owner,
        role: WorkspaceRole::User,
        grant_generation: 1,
        workspace_authorization_version: 1,
        membership_authorization_version: 1,
    };
    assert!(pin.permits_schema(&admission));
    admission.user_id = Uuid::new_v4();
    assert!(!pin.permits_schema(&admission));
    admission.role = WorkspaceRole::Admin;
    assert!(pin.permits_schema(&admission));
    admission.workspace_id = Uuid::new_v4();
    assert!(!pin.permits_schema(&admission));
}
