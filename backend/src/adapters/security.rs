//! Hash có giới hạn tài nguyên và capability ngẫu nhiên; không có khóa hardcode.

use argon2::{Argon2, PasswordHash, PasswordHasher, PasswordVerifier, password_hash::SaltString};
use hmac::{Hmac, Mac};
use iot_application::{error::ApplicationError, ports::IdentitySecurity};
use iot_domain::identity::SecretString;
use rand::{RngCore, rngs::OsRng};
use sha2::{Digest, Sha256};
use std::{sync::Arc, time::Duration};
use tokio::sync::Semaphore;

/// Sinh256 bit entropy bằng OS CSPRNG; core chỉ nhận `SecretString`, không biết RNG implementation.
#[must_use]
pub fn generate_token() -> SecretString {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut bytes = [0_u8; 32];
    OsRng.fill_bytes(&mut bytes);
    // Hex giữ đủ256 bit entropy; chỉ mã hóa byte ngẫu nhiên, không thay bằng UUID/PRNG thời gian.
    SecretString::new(
        bytes
            .iter()
            .flat_map(|byte| {
                [
                    char::from(HEX[usize::from(byte >> 4)]),
                    char::from(HEX[usize::from(byte & 15)]),
                ]
            })
            .collect(),
    )
}

/// Password hasher dùng hai slot; permit sống trong blocking task kể cả caller bị cancel.
#[derive(Clone)]
pub struct PasswordService {
    slots: Arc<Semaphore>,
}

impl Default for PasswordService {
    /// Giới hạn hai phép Argon2id đồng thời cho `PoC`, tránh blocking pool tăng RAM vô hạn.
    fn default() -> Self {
        Self {
            slots: Arc::new(Semaphore::new(2)),
        }
    }
}

impl PasswordService {
    /**
     * Băm Argon2id ngoài executor I/O với salt riêng; không giữ DB transaction khi chuẩn bị mật khẩu mới.
     * Input
     * Param: password — mật khẩu đã validate, được chuyển quyền sở hữu vào blocking task.
     * Output: PHC verifier; Errors: unavailable khi queue quá 5 giây hoặc hasher lỗi.
     * # Errors
     * Trả lỗi từ chối hoặc lỗi đã mô tả ở trên; không chứa dữ liệu nhạy cảm.
     */
    pub async fn hash(&self, password: String) -> Result<String, ApplicationError> {
        let permit =
            tokio::time::timeout(Duration::from_secs(5), self.slots.clone().acquire_owned())
                .await
                .map_err(|_| ApplicationError::Unavailable)?
                .map_err(|_| ApplicationError::Unavailable)?;
        // Permit nằm trong closure để timeout/cancel không giải phóng sớm ngân sách RAM của Argon2.
        tokio::task::spawn_blocking(move || {
            let _permit = permit;
            Argon2::default()
                .hash_password(password.as_bytes(), &SaltString::generate(&mut OsRng))
                .map(|hash| hash.to_string())
                .map_err(|_| ApplicationError::Unavailable)
        })
        .await
        .map_err(|_| ApplicationError::Unavailable)?
    }

    /**
     * Kiểm credential bằng PHC đã chọn dưới fence, phân biệt sai password với verifier hỏng.
     * Input
     * Param: password — input nguyên bản; không trim hoặc đổi Unicode.
     * Param: verifier — PHC từ storage tin cậy hoặc dummy verifier cùng chi phí.
     * Output: đúng/sai; Errors: unavailable khi storage verifier hỏng hoặc hết budget.
     * # Errors
     * Trả lỗi từ chối hoặc lỗi đã mô tả ở trên; không chứa dữ liệu nhạy cảm.
     */
    pub async fn verify(
        &self,
        password: String,
        verifier: String,
    ) -> Result<bool, ApplicationError> {
        let permit =
            tokio::time::timeout(Duration::from_secs(5), self.slots.clone().acquire_owned())
                .await
                .map_err(|_| ApplicationError::Unavailable)?
                .map_err(|_| ApplicationError::Unavailable)?;
        tokio::task::spawn_blocking(move || {
            let _permit = permit;
            let parsed = PasswordHash::new(&verifier).map_err(|_| ApplicationError::Unavailable)?;
            /* PHC có thể yêu cầu chi phí riêng; semaphore chỉ giới hạn số job, không giới hạn RAM/job.
             * PoC chỉ nhận policy Argon2id v1.3 m19456KiB/t2/p1/output32byte đã pin của hasher này;
             * legacy verifier khác policy phải qua migration được kiểm, không tự chạy tham số tùy ý từ storage. */
            if parsed.algorithm.as_str()!="argon2id" || parsed.version!=Some(19) ||
                parsed.params.get_decimal("m")!=Some(19_456) || parsed.params.get_decimal("t")!=Some(2) ||
                parsed.params.get_decimal("p")!=Some(1) || parsed.hash.as_ref().map(argon2::password_hash::Output::len)!=Some(32) {
                return Err(ApplicationError::Unavailable);
            }
            match Argon2::default().verify_password(password.as_bytes(), &parsed) {
                Ok(()) => Ok(true),
                Err(argon2::password_hash::Error::Password) => Ok(false),
                Err(_) => Err(ApplicationError::Unavailable),
            }
        })
        .await
        .map_err(|_| ApplicationError::Unavailable)?
    }
}

/**
 * HMAC email chuẩn hóa để limiter không lưu địa chỉ hay digest dễ dò bằng dictionary.
 * Input
 * Param: key — khóa 256 bit do deployment cấp, chung giữa các instance và ổn định qua restart.
 * Param: email — email đã qua `normalize_email`.
 * Output: bucket identity 32 byte; Errors: unavailable nếu khởi tạo MAC lỗi.
 * # Errors
 * Trả lỗi từ chối hoặc lỗi đã mô tả ở trên; không chứa dữ liệu nhạy cảm.
 */
pub fn email_bucket_digest(key: &[u8; 32], email: &str) -> Result<Vec<u8>, ApplicationError> {
    let mut mac = Hmac::<Sha256>::new_from_slice(key).map_err(|_| ApplicationError::Unavailable)?;
    mac.update(email.as_bytes());
    Ok(mac.finalize().into_bytes().to_vec())
}

/// Implementation crypto của application port; key/dummy verifier không được derive Debug.
#[derive(Clone)]
pub struct CryptoService {
    passwords: PasswordService,
    limiter_key: [u8; 32],
    dummy_verifier: Arc<SecretString>,
}

impl CryptoService {
    /**
     * Chuẩn bị dummy verifier một lần; key phải do deployment cấp ổn định giữa các replica/restart.
     * Input
     * Param: passwords — hasher có semaphore dùng chung trong process.
     * Param: `limiter_key` — key `HMAC256bit` do launcher/secret manager cung cấp, không tự đọc env.
     * Output: adapter crypto hoặc unavailable nếu khởi tạo verifier lỗi.
     * # Errors
     * Trả lỗi từ chối hoặc lỗi đã mô tả ở trên; không chứa dữ liệu nhạy cảm.
     */
    pub async fn new(
        passwords: PasswordService,
        limiter_key: [u8; 32],
    ) -> Result<Self, ApplicationError> {
        let verifier = passwords.hash(generate_token().expose().to_owned()).await?;
        Ok(Self {
            passwords,
            limiter_key,
            dummy_verifier: Arc::new(SecretString::new(verifier)),
        })
    }
}

impl IdentitySecurity for CryptoService {
    /// Chuyển secret vào bounded hasher; PHC trả về core vẫn được che Debug.
    async fn hash_password(
        &self,
        password: SecretString,
    ) -> Result<SecretString, ApplicationError> {
        Ok(SecretString::new(
            self.passwords.hash(password.expose().to_owned()).await?,
        ))
    }
    /// Kiểm password/verifier ngoài executor I/O; lỗi verifier không biến thành success.
    async fn verify_password(
        &self,
        password: SecretString,
        verifier: SecretString,
    ) -> Result<bool, ApplicationError> {
        self.passwords
            .verify(password.expose().to_owned(), verifier.expose().to_owned())
            .await
    }
    /// Cấp bản sao dummy PHC cho unknown email; không trả raw dummy password.
    fn dummy_verifier(&self) -> SecretString {
        SecretString::new(self.dummy_verifier.expose().to_owned())
    }
    /// HMAC email bằng key deployment, không dùng SHA256 email dễ bị dictionary attack.
    fn bucket_digest(&self, email: &str) -> Result<[u8; 32], ApplicationError> {
        email_bucket_digest(&self.limiter_key, email)?
            .try_into()
            .map_err(|_| ApplicationError::Unavailable)
    }
    /// Trả token CSPRNG và SHA256 digest; application quyết định thời điểm phát sau commit.
    fn issue_token(&self) -> (SecretString, [u8; 32]) {
        let token = generate_token();
        let digest = self.token_digest(token.expose());
        (token, digest)
    }
    /// Băm capability entropy cao để lookup, không coi digest là chứng cứ session còn quyền.
    fn token_digest(&self, token: &str) -> [u8; 32] {
        Sha256::digest(token.as_bytes()).into()
    }
    /// Hash canonical request bytes để body guard độc lập JSON key order/HTTP formatting.
    fn request_digest(&self, payload: &[u8]) -> [u8; 32] {
        Sha256::digest(payload).into()
    }
}

impl iot_application::template_ports::TemplateDigest for CryptoService {
    /// Băm SHA256 canonical snapshot bytes đã validate, không dùng HMAC limiter hoặc log nội dung template.
    fn content_digest(&self, canonical: &[u8]) -> [u8; 32] {
        Sha256::digest(canonical).into()
    }
}
