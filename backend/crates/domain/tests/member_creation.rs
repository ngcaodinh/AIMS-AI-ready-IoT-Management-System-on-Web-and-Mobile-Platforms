use iot_domain::{member_creation::MemberCreationRequest, workspace::WorkspaceRole};

/// Email được canonical hóa, alias workspace được trim/NFC và tên rỗng/NUL bị từ chối.
#[test]
fn canonicalizes_workspace_alias_and_rejects_invalid_identity() {
    let request = MemberCreationRequest::new(
        " New@Example.invalid ",
        "  Tên riêng  ",
        WorkspaceRole::User,
    )
    .unwrap();
    assert_eq!(request.email_normalized(), "new@example.invalid");
    assert_eq!(request.display_name(), "Tên riêng");
    let decomposed =
        MemberCreationRequest::new("a@example.invalid", "  Te\u{0302}n  ", WorkspaceRole::User)
            .unwrap();
    assert_eq!(decomposed.display_name(), "Tên");
    assert!(MemberCreationRequest::new("invalid", "Name", WorkspaceRole::User).is_none());
    assert!(MemberCreationRequest::new("a@example.invalid", " \n ", WorkspaceRole::User).is_none());
    assert!(MemberCreationRequest::new("a@example.invalid", "a\0b", WorkspaceRole::User).is_none());
}

/// Fingerprint phân biệt email raw, alias thực và role, nhưng bỏ qua khoảng trắng ngoài alias đã chuẩn hóa.
#[test]
fn request_fingerprint_tracks_raw_email_alias_and_role() {
    let request =
        MemberCreationRequest::new("a@example.invalid", "bc", WorkspaceRole::User).unwrap();
    let spaced =
        MemberCreationRequest::new(" a@example.invalid", "bc", WorkspaceRole::User).unwrap();
    let trimmed_alias =
        MemberCreationRequest::new("a@example.invalid", "  bc  ", WorkspaceRole::User).unwrap();
    let renamed =
        MemberCreationRequest::new("a@example.invalid", "c", WorkspaceRole::User).unwrap();
    let elevated =
        MemberCreationRequest::new("a@example.invalid", "bc", WorkspaceRole::Admin).unwrap();
    assert_ne!(request.request_bytes(), spaced.request_bytes());
    assert_eq!(request.request_bytes(), trimmed_alias.request_bytes());
    assert_ne!(request.request_bytes(), renamed.request_bytes());
    assert_ne!(request.request_bytes(), elevated.request_bytes());
}
