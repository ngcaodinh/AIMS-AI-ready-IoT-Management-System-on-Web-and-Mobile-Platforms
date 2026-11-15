//! Ranh giới credential/origin/CSRF; không suy authority từ header tự khai của client.

use super::HttpError;
use axum::http::{HeaderMap, Uri};
use hmac::{Hmac, Mac};
use iot_domain::identity::ClientType;
use sha2::Sha256;
use uuid::Uuid;

/** Lấy đúng một header UTF-8; Input: headers chưa tin cậy, name là tên nội bộ. Errors:400 nếu mơ hồ. */
pub(super) fn single_header<'a>(
    headers: &'a HeaderMap,
    name: &str,
) -> Result<Option<&'a str>, HttpError> {
    let mut values = headers.get_all(name).iter();
    let value = values.next();
    if values.next().is_some() {
        return Err(HttpError::validation(400, "/", "FORMAT"));
    }
    value
        .map(|value| {
            value
                .to_str()
                .map_err(|_| HttpError::validation(400, "/", "FORMAT"))
        })
        .transpose()
}

/** Chốt origin không có path/query/userinfo; chỉ localhost được phép HTTP trong lab loopback. */
pub(super) fn validate_origin(origin: &str) -> Result<(), HttpError> {
    let uri: Uri = origin.parse().map_err(|_| HttpError::unavailable())?;
    let valid_scheme = uri.scheme_str() == Some("https")
        || (uri.scheme_str() == Some("http") && uri.host() == Some("localhost"));
    if !valid_scheme
        || uri.authority().is_none()
        || uri
            .authority()
            .is_some_and(|authority| authority.as_str().contains('@'))
        || uri.path() != "/"
        || uri.query().is_some()
        || origin.ends_with('/')
    {
        return Err(HttpError::unavailable());
    }
    Ok(())
}

/** Kiểm origin chính xác kể cả browser khai Android; Web thiếu Origin chỉ fallback Referer HTTPS. */
pub(super) fn check_origin(headers: &HeaderMap, origin: &str, web: bool) -> Result<(), HttpError> {
    let supplied = single_header(headers, "origin")?;
    let fetch_site = single_header(headers, "sec-fetch-site")?;
    let referer = single_header(headers, "referer")?;
    if fetch_site.is_some_and(|site| site != "same-origin" && site != "none") {
        return Err(HttpError::csrf());
    }
    if let Some(supplied) = supplied {
        if supplied != origin {
            return Err(HttpError::csrf());
        }
    } else if web || fetch_site.is_some() || referer.is_some() {
        // Không cho HTTP Referer lab biến thành fallback production; Origin lab vẫn có thể khớp trực tiếp.
        if !origin.starts_with("https://")
            || !referer.is_some_and(|value| value.starts_with(&format!("{origin}/")))
        {
            return Err(HttpError::csrf());
        }
    }
    Ok(())
}

/** Kiểm request đọc: Origin nếu có phải khớp, Fetch Metadata cấm cross-site; GET không bắt HTTPS Referer fallback. */
pub(super) fn check_read_origin(headers: &HeaderMap, origin: &str) -> Result<(), HttpError> {
    if single_header(headers, "origin")?.is_some_and(|value| value != origin)
        || single_header(headers, "sec-fetch-site")?
            .is_some_and(|value| value != "same-origin" && value != "none")
    {
        return Err(HttpError::csrf());
    }
    Ok(())
}

/** Phân biệt credential vắng mặt với sai định dạng để logout anonymous idempotent không clear cookie. */
pub(super) fn has_credential(headers: &HeaderMap) -> Result<bool, HttpError> {
    Ok(single_header(headers, "authorization")?.is_some()
        || single_header(headers, "cookie")?.is_some_and(|cookie| {
            cookie
                .split(';')
                .any(|part| part.trim().starts_with("iot_session="))
        }))
}

/** Tách credential từ headers mạng; trả cookie Web hoặc kênh bearer chung Android/IOS, không chứng thực OS/quyền. */
pub(super) fn credential(headers: &HeaderMap) -> Result<(String, ClientType), HttpError> {
    let authorization = single_header(headers, "authorization")?;
    let cookie = single_header(headers, "cookie")?;
    let mut cookies = cookie
        .into_iter()
        .flat_map(|value| value.split(';'))
        .filter_map(
            // Chỉ lấy cookie phiên chính xác; các cookie theme không được dùng làm credential.
            |part| part.trim().strip_prefix("iot_session="),
        );
    let session = cookies.next();
    if cookies.next().is_some() || (session.is_some() && authorization.is_some()) {
        return Err(HttpError::validation(400, "", "TYPE"));
    }
    let (token, transport) = if let Some(token) = session {
        (token, ClientType::Web)
    } else if let Some(value) = authorization {
        // Header bearer không mang OS; Android chỉ đại diện kênh, metadata IOS được đối chiếu sau lookup.
        (
            value
                .strip_prefix("Bearer ")
                .ok_or_else(HttpError::session_invalid)?,
            ClientType::Android,
        )
    } else {
        return Err(HttpError::session_invalid());
    };
    // Capability do CSPRNG hiện hành phát dưới dạng 64 hex; chặn token/control/header quá dài trước lookup.
    if token.len() != 64 || !token.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return Err(HttpError::session_invalid());
    }
    Ok((token.to_owned(), transport))
}

/** HMAC tách namespace CSRF/cursor; Input: key riêng deployment, purpose và payload không được log. */
pub(super) fn sign(key: &[u8; 32], purpose: &[u8], payload: &[u8]) -> String {
    // HMAC chấp nhận key mọi độ dài; mảng32 byte bảo đảm constructor không lỗi.
    let mut mac = Hmac::<Sha256>::new_from_slice(key).expect("32-byte HMAC key is valid");
    mac.update(purpose);
    mac.update(payload);
    encode_hex(&mac.finalize().into_bytes())
}

/** Mã hóa byte thành hex cho header/cursor; Input: bytes không được ghi log. Output: ASCII có cận hữu hạn. */
pub(super) fn encode_hex(bytes: &[u8]) -> String {
    const DIGITS: &[u8; 16] = b"0123456789abcdef";
    let mut text = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        text.push(char::from(DIGITS[usize::from(byte >> 4)]));
        text.push(char::from(DIGITS[usize::from(byte & 15)]));
    }
    text
}

/** Xác minh tag constant-time; Input: purpose/payload phải giống khi ký, tag là hex chưa tin cậy. */
pub(super) fn verify(key: &[u8; 32], purpose: &[u8], payload: &[u8], tag: &str) -> bool {
    let Some(bytes) = decode_hex(tag) else {
        return false;
    };
    let Ok(mut mac) = Hmac::<Sha256>::new_from_slice(key) else {
        return false;
    };
    mac.update(purpose);
    mac.update(payload);
    mac.verify_slice(&bytes).is_ok()
}

/** Decode hex có cận; Input: text từ header/cursor. Output: None khi lẻ, ngoài hex hoặc quá8KiB. */
pub(super) fn decode_hex(text: &str) -> Option<Vec<u8>> {
    if text.len() > 8192 || text.len() % 2 != 0 {
        return None;
    }
    text.as_bytes()
        .chunks_exact(2)
        .map(
            // Ghép hai nibble đã kiểm; không chấp nhận byte ngoài ASCII hex.
            |pair| {
                u8::try_from(
                    char::from(pair[0]).to_digit(16)? * 16 + char::from(pair[1]).to_digit(16)?,
                )
                .ok()
            },
        )
        .collect()
}

/** Parse context duy nhất; Input: headers mạng. Output: UUID hoặc None chỉ cho discovery/App. */
pub(super) fn context(headers: &HeaderMap) -> Result<Option<Uuid>, HttpError> {
    single_header(headers, "x-auth-context-id")?
        .map(
            // Header sai shape không được biến thành discovery thiếu context.
            |value| Uuid::parse_str(value).map_err(|_| HttpError::context_mismatch()),
        )
        .transpose()
}

#[cfg(test)]
mod tests {
    use super::*;

    /** GET browser cùng origin không có Origin được đọc; POST Web vẫn yêu cầu Origin hoặc HTTPS fallback. */
    #[test]
    fn browser_get_and_mutation_have_distinct_origin_requirements() {
        let mut headers = HeaderMap::new();
        headers.insert("sec-fetch-site", "same-origin".parse().unwrap());
        headers.insert("referer", "http://localhost:5173/login".parse().unwrap());
        assert!(check_read_origin(&headers, "http://localhost:5173").is_ok());
        assert!(check_origin(&headers, "http://localhost:5173", true).is_err());
        headers.insert("origin", "http://localhost:5173".parse().unwrap());
        assert!(check_origin(&headers, "http://localhost:5173", true).is_ok());
    }

    /** Tag CSRF không dùng làm chữ ký cursor; thay payload hoặc key đều bị từ chối. */
    #[test]
    fn signatures_are_bound_to_purpose_payload_and_key() {
        let key = [3; 32];
        let tag = sign(&key, b"csrf-v1:", b"synthetic-context");
        assert!(verify(&key, b"csrf-v1:", b"synthetic-context", &tag));
        assert!(!verify(
            &key,
            b"workspace-active-uuid-v1:",
            b"synthetic-context",
            &tag
        ));
        assert!(!verify(&key, b"csrf-v1:", b"another-context", &tag));
        assert!(!verify(&[4; 32], b"csrf-v1:", b"synthetic-context", &tag));
    }
}
