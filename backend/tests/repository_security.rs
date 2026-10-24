use iot_platform_backend::{
    adapters::security::{PasswordService, email_bucket_digest, generate_token},
    application::error::ApplicationError,
};
use sha2::{Digest, Sha256};

/// Chứng minh token có entropy độc lập và mọi Debug đều che capability.
#[test]
fn session_tokens_are_independent_and_redacted() {
    let first = generate_token();
    let second = generate_token();
    assert_ne!(first.expose(), second.expose());
    assert_eq!(first.expose().len(), 64);
    assert_eq!(Sha256::digest(first.expose().as_bytes()).len(), 32);
    assert!(!format!("{first:?}").contains(first.expose()));
    assert_eq!(
        email_bucket_digest(&[1; 32], "a@example.invalid")
            .unwrap()
            .len(),
        32
    );
    assert_ne!(
        email_bucket_digest(&[1; 32], "a@example.invalid"),
        email_bucket_digest(&[2; 32], "a@example.invalid")
    );
}

/// Kiểm sai credential, verifier hỏng và salt ngẫu nhiên để tránh coi lỗi storage như đăng nhập hợp lệ.
#[tokio::test]
async fn password_hashing_distinguishes_mismatch_and_storage_failure() {
    let hasher = PasswordService::default();
    let password = generate_token();
    let verifier = hasher.hash(password.expose().to_owned()).await.unwrap();
    assert!(verifier.starts_with("$argon2id$"));
    assert!(
        hasher
            .verify(password.expose().to_owned(), verifier.clone())
            .await
            .unwrap()
    );
    assert!(
        !hasher
            .verify(generate_token().expose().to_owned(), verifier.clone())
            .await
            .unwrap()
    );
    assert_eq!(
        hasher
            .verify(password.expose().to_owned(), "invalid-phc".into())
            .await,
        Err(ApplicationError::Unavailable)
    );
    assert_ne!(
        hasher.hash(password.expose().to_owned()).await.unwrap(),
        verifier
    );
    // PHC khác cost bị từ chối trước allocation, không tự tin mọi verifier trong storage đều an toàn.
    let altered = verifier.replace("m=19456", "m=19457");
    assert_eq!(
        hasher.verify(password.expose().to_owned(), altered).await,
        Err(ApplicationError::Unavailable)
    );
}
