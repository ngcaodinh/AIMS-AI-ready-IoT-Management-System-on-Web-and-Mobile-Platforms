use iot_domain::{member_creation::MemberCreationRequest, workspace::WorkspaceRole};

/// Email được canonical hóa, alias giữ nguyên và boundary từ chối tên blank/NUL.
#[test]
fn validates_identity_without_changing_workspace_alias() {
    let request = MemberCreationRequest::new(
        " New@Example.invalid ",
        "  Tên riêng  ",
        WorkspaceRole::User,
    )
    .unwrap();
    assert_eq!(request.email_normalized(), "new@example.invalid");
    assert_eq!(request.display_name(), "  Tên riêng  ");
    assert!(MemberCreationRequest::new("invalid", "Name", WorkspaceRole::User).is_none());
    assert!(MemberCreationRequest::new("a@example.invalid", " \n ", WorkspaceRole::User).is_none());
    assert!(MemberCreationRequest::new("a@example.invalid", "a\0b", WorkspaceRole::User).is_none());
}

/// Receipt fingerprint phân biệt field boundary, raw normalization và role để retry khác intent bị chặn.
#[test]
fn request_encoding_is_unambiguous_and_preserves_raw_body() {
    let request =
        MemberCreationRequest::new("a@example.invalid", "bc", WorkspaceRole::User).unwrap();
    let spaced =
        MemberCreationRequest::new(" a@example.invalid", "bc", WorkspaceRole::User).unwrap();
    let renamed =
        MemberCreationRequest::new("a@example.invalid", "c", WorkspaceRole::User).unwrap();
    let elevated =
        MemberCreationRequest::new("a@example.invalid", "bc", WorkspaceRole::Admin).unwrap();
    assert_ne!(request.request_bytes(), spaced.request_bytes());
    assert_ne!(request.request_bytes(), renamed.request_bytes());
    assert_ne!(request.request_bytes(), elevated.request_bytes());
}
