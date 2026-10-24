//! Decorator kiểm chi phí hash và cửa sổ revoke; vẫn delegate crypto thật, không thay policy password.

use iot_platform_backend::{
    adapters::security::CryptoService,
    application::{error::ApplicationError, ports::IdentitySecurity},
    domain::identity::SecretString,
};
use std::sync::{
    Arc,
    atomic::{AtomicU64, Ordering},
};
use tokio::sync::Barrier;

#[derive(Clone)]
pub(super) struct HashProbeSecurity {
    inner: CryptoService,
    pub(super) calls: Arc<AtomicU64>,
    pause: Option<(Arc<Barrier>, Arc<Barrier>)>,
}

impl HashProbeSecurity {
    /// Bọc crypto thật và đếm mỗi yêu cầu hash, không đếm verify/dummy initialization.
    pub(super) fn new(inner: CryptoService) -> Self {
        Self {
            inner,
            calls: Arc::default(),
            pause: None,
        }
    }

    /// Dựng barrier kiểm revoke sau preflight; caller phải release sau khi mutate quyền hiện hành.
    pub(super) fn paused(inner: CryptoService) -> (Self, Arc<Barrier>, Arc<Barrier>) {
        let entered = Arc::new(Barrier::new(2));
        let release = Arc::new(Barrier::new(2));
        (
            Self {
                inner,
                calls: Arc::default(),
                pause: Some((entered.clone(), release.clone())),
            },
            entered,
            release,
        )
    }
}

impl IdentitySecurity for HashProbeSecurity {
    /// Đếm input password được gửi đến hasher; optional barrier chỉ dùng kiểm TOCTOU trước delegate thật.
    async fn hash_password(
        &self,
        password: SecretString,
    ) -> Result<SecretString, ApplicationError> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        if let Some((entered, release)) = &self.pause {
            entered.wait().await;
            release.wait().await;
        }
        self.inner.hash_password(password).await
    }
    /// Verify password/verifier bằng crypto thật để test không thay credential policy.
    async fn verify_password(
        &self,
        password: SecretString,
        verifier: SecretString,
    ) -> Result<bool, ApplicationError> {
        self.inner.verify_password(password, verifier).await
    }
    /// Trả dummy verifier của delegate để unknown login giữ cùng chi phí.
    fn dummy_verifier(&self) -> SecretString {
        self.inner.dummy_verifier()
    }
    /// HMAC email bằng cùng key của hai instance để test không tạo fence giả riêng process.
    fn bucket_digest(&self, email: &str) -> Result<[u8; 32], ApplicationError> {
        self.inner.bucket_digest(email)
    }
    /// Sinh capability thật và digest, không lưu raw value trong instrumentation.
    fn issue_token(&self) -> (SecretString, [u8; 32]) {
        self.inner.issue_token()
    }
    /// Chuyển token input sang digest bằng delegate, không xác thực hoặc log secret.
    fn token_digest(&self, token: &str) -> [u8; 32] {
        self.inner.token_digest(token)
    }
    /// Băm body bytes bằng delegate để same-key guard dùng nguyên encoding production.
    fn request_digest(&self, payload: &[u8]) -> [u8; 32] {
        self.inner.request_digest(payload)
    }
}
