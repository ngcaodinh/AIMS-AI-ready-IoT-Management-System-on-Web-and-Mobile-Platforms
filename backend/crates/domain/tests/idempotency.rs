use iot_domain::idempotency::{IdempotencyKey, workspace_request_bytes};

/// Cận key là16–128 ASCII byte; không chấp nhận Unicode hoặc tự trim input để gộp intent khác.
#[test]
fn keys_preserve_exact_ascii_identity_and_length_limits() {
    assert!(IdempotencyKey::new(&"a".repeat(15)).is_none());
    assert!(IdempotencyKey::new(&"a".repeat(16)).is_some());
    assert!(IdempotencyKey::new(&"a".repeat(128)).is_some());
    assert!(IdempotencyKey::new(&"a".repeat(129)).is_none());
    assert!(IdempotencyKey::new(&"đ".repeat(16)).is_none());
}

/// Prefix độ dài và presence giữ None/rỗng/field boundary riêng, không ghép request bằng delimiter dễ nhập nhằng.
#[test]
fn canonical_request_preserves_body_semantics() {
    assert_ne!(
        workspace_request_bytes("same", None, "UTC"),
        workspace_request_bytes("same", Some(""), "UTC")
    );
    assert_ne!(
        workspace_request_bytes("a:b", Some("c"), "UTC"),
        workspace_request_bytes("a", Some("b:c"), "UTC")
    );
    assert_ne!(
        workspace_request_bytes(" name", None, "UTC"),
        workspace_request_bytes("name", None, "UTC")
    );
    assert_eq!(
        workspace_request_bytes("same", Some("body"), "UTC"),
        workspace_request_bytes("same", Some("body"), "UTC")
    );
}
