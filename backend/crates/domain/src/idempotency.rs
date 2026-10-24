//! Idempotency intent của client; không sinh key mới khi retry cùng một ý định.

use crate::identity::SecretString;

/// Key không derive Debug để không bị log; storage chỉ nhận digest qua crypto port.
pub struct IdempotencyKey(SecretString);

impl IdempotencyKey {
    /**
     * Kiểm contract16–128 byte ASCII trước khi mở transaction, giữ nguyên giá trị client để hash.
     * Input
     * Param: value — key ổn định cho một intent; không tự trim hoặc sinh lại khi retry.
     * Output: key hợp lệ hoặc None, không cấp quyền và không thay thế session/current membership.
     */
    #[must_use]
    pub fn new(value: &str) -> Option<Self> {
        (value.is_ascii() && (16..=128).contains(&value.len()))
            .then(|| Self(SecretString::new(value.to_owned())))
    }
    /// Mở key chỉ tại crypto boundary; caller không được log hoặc lưu raw value.
    #[must_use]
    pub fn expose(&self) -> &str {
        self.0.expose()
    }
}

/**
 * Encode semantic request theo length-prefix để None/rỗng hoặc field chứa delimiter không nhập nhằng.
 * Input
 * Param: name — giá trị tên gốc trong request, trước trim; đổi nội dung phải conflict khi dùng lại key.
 * Param: description — None khác Some chuỗi rỗng, không tự normalize body.
 * Param: timezone — giá trị timezone gốc, không bị đưa vào SQL interpolation.
 * Output: canonical byte sequence version1 dùng hash request, không chứa credential.
 */
#[must_use]
pub fn workspace_request_bytes(name: &str, description: Option<&str>, timezone: &str) -> Vec<u8> {
    let mut encoded = b"workspace-create:v1\0".to_vec();
    for field in [Some(name), description, Some(timezone)] {
        encoded.push(u8::from(field.is_some()));
        if let Some(value) = field {
            encoded.extend_from_slice(&(value.len() as u64).to_be_bytes());
            encoded.extend_from_slice(value.as_bytes());
        }
    }
    encoded
}
