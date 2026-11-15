//! Validation thuần ở boundary auth; không phụ thuộc HTTP, DB hoặc crate mới.

/// Lỗi validation an toàn để ánh xạ sang HTTP mà không phản chiếu dữ liệu người dùng.
#[derive(Debug, PartialEq, Eq)]
pub struct FieldError {
    /// Đường dẫn JSON của trường sai để client gắn lỗi vào đúng control.
    pub path: &'static str,
    /// Mã lỗi ổn định theo contract, không chứa dữ liệu đầu vào.
    pub code: &'static str,
}

/**
 * Chuẩn hóa email đăng nhập theo OQ-AUTH-001 bằng cách cắt whitespace ASCII ngoài biên, hạ chữ hoa
 * ASCII rồi kiểm tra local-part dạng dot-atom và nhãn DNS; nhờ đó lookup nhất quán mà không gộp dấu
 * chấm hoặc `+tag` thành account khác. Địa chỉ Unicode, sai cấu trúc hoặc vượt cận bị từ chối an toàn.
 *
 * # Input
 * Param: email — chuỗi từ request cần xác thực và chuẩn hóa tại biên backend.
 *
 * # Output
 * Email ASCII đã chuẩn hóa dùng cho lookup và ràng buộc duy nhất.
 *
 * # Errors
 * Trả `FieldError` với path `/email` và mã `FORMAT` hoặc `LENGTH` nếu đầu vào không hợp lệ.
 */
pub fn normalize_email(email: &str) -> Result<String, FieldError> {
    let normalized = email
        .trim_matches(|character: char| character.is_ascii_whitespace())
        .to_ascii_lowercase();
    if !normalized.is_ascii() {
        return Err(FieldError {
            path: "/email",
            code: "FORMAT",
        });
    }
    let Some((local, domain)) = normalized.split_once('@') else {
        return Err(FieldError {
            path: "/email",
            code: "FORMAT",
        });
    };
    // Giới hạn tổng 254 byte và local-part 64 byte theo contract email ASCII.
    if normalized.len() > 254 || local.len() > 64 {
        return Err(FieldError {
            path: "/email",
            code: "LENGTH",
        });
    }
    // Baseline hỗ trợ địa chỉ ASCII dạng dot-atom và domain DNS; không tự diễn giải Unicode/quoted email.
    let local_valid = !local.is_empty()
        && !local.starts_with('.')
        && !local.ends_with('.')
        && !local.contains("..")
        && local
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || b".!#$%&'*+-/=?^_`{|}~".contains(&byte));
    // Domain phải có nhãn DNS không rỗng; giới hạn 63 byte áp dụng riêng từng nhãn.
    let domain_valid = domain.contains('.')
        && domain.split('.').all(|label| {
            !label.is_empty()
                && label.len() <= 63
                && !label.starts_with('-')
                && !label.ends_with('-')
                && label
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
        });
    if !local_valid || !domain_valid {
        return Err(FieldError {
            path: "/email",
            code: "FORMAT",
        });
    }
    Ok(normalized)
}

/**
 * Kiểm độ dài mật khẩu tại biên request để áp dụng cùng giới hạn với contract đăng nhập mà vẫn giữ
 * nguyên chuỗi người dùng chọn; đếm Unicode scalar thay vì byte hoặc đơn vị UTF-16, không trim khoảng trắng.
 *
 * # Input
 * Param: password — chuỗi nguyên bản cần kiểm tra; hàm không lưu hoặc biến đổi chuỗi này.
 * Param: path — đường dẫn trường trong payload để lỗi được gắn đúng vị trí.
 *
 * # Output
 * Trả `()` khi mật khẩu đăng nhập có từ9 đến128 Unicode scalar; composition mới không khóa credential legacy.
 *
 * # Errors
 * Trả `FieldError` với mã `LENGTH` và path do caller cung cấp khi mật khẩu ngoài giới hạn.
 */
pub fn validate_password(password: &str, path: &'static str) -> Result<(), FieldError> {
    validate_password_length(password, path, 9)
}

/**
 * Kiểm credential hiện hành theo contract đổi mật khẩu, không áp quy tắc tạo mới lên mật khẩu đã lưu.
 * # Input
 * Param: password — chuỗi hiện tại giữ nguyên để verify hash, không trim/normalize.
 * Param: path — vị trí field để trả lỗi an toàn.
 * # Output
 * Trả `()` khi có1–128 Unicode scalar.
 * # Errors
 * `FieldError` LENGTH khi ngoài giới hạn; không chứa giá trị đầu vào.
 */
pub fn validate_current_password(password: &str, path: &'static str) -> Result<(), FieldError> {
    validate_password_length(password, path, 1)
}

/**
 * Áp policy tạo/đổi password do user yêu cầu, không thay đổi nội dung trước khi băm.
 * # Input
 * Param: password — credential mới, chỉ giữ trong RAM.
 * Param: path — vị trí newPassword hoặc temporaryPassword trong boundary tương ứng.
 * # Output
 * Trả `()` khi9–128 scalar, có Unicode Uppercase/Lowercase và số ASCII0–9.
 * # Errors
 * LENGTH khi sai độ dài, FORMAT khi thiếu thành phần; không yêu cầu ký tự đặc biệt.
 */
pub fn validate_new_password(password: &str, path: &'static str) -> Result<(), FieldError> {
    validate_password(password, path)?;
    // Dùng Unicode binary properties để chữ tiếng Việt cũng được nhận; số0–9 thống nhất cả ba runtime.
    if !password.chars().any(char::is_uppercase)
        || !password.chars().any(char::is_lowercase)
        || !password.as_bytes().iter().any(u8::is_ascii_digit)
    {
        return Err(FieldError {
            path,
            code: "FORMAT",
        });
    }
    Ok(())
}

/**
 * Dùng chung kiểm độ dài để login/current/new không lệch cách đếm scalar hoặc tự trim.
 * # Input
 * Param: password — input nguyên chuỗi, không lưu hoặc đưa vào lỗi.
 * Param: path — field nhận lỗi LENGTH.
 * Param: minimum — cận1 cho credential hiện tại hoặc9 cho login/new theo contract.
 * # Output
 * Trả `()` khi trong khoảng minimum–128.
 * # Errors
 * LENGTH nếu input vượt cận; không panic trên dữ liệu người dùng.
 */
fn validate_password_length(
    password: &str,
    path: &'static str,
    minimum: usize,
) -> Result<(), FieldError> {
    if !(minimum..=128).contains(&password.chars().count()) {
        return Err(FieldError {
            path,
            code: "LENGTH",
        });
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{normalize_email, validate_password};

    /**
     * Bảo vệ định danh account khỏi bị gộp bằng cách kiểm tra bỏ whitespace ASCII ngoài biên,
     * hạ case ASCII, giữ dấu chấm/`+tag` và từ chối cú pháp sai.
     */
    #[test]
    fn email_canonicalization_preserves_identity_parts() {
        assert_eq!(
            normalize_email("\t Member.Name+tag@Example.Test \r\n").as_deref(),
            Ok("member.name+tag@example.test")
        );
        assert!(normalize_email("thànhviên@example.test").is_err());
        assert!(normalize_email("member..name@example.test").is_err());
        assert!(normalize_email("member@-invalid.test").is_err());
        assert!(normalize_email("member@exa mple.test").is_err());
    }

    /**
     * Giữ giới hạn địa chỉ nhất quán giữa validation, lookup và unique key bằng cách xác nhận
     * giá trị đúng cận được nhận, còn vượt một đơn vị bị trả `LENGTH`.
     */
    #[test]
    fn email_lengths_match_contract_boundaries() {
        assert!(normalize_email(&format!("{}@example.test", "a".repeat(64))).is_ok());
        assert_eq!(
            normalize_email(&format!("{}@example.test", "a".repeat(65)))
                .unwrap_err()
                .code,
            "LENGTH"
        );
        let email = format!(
            "{}@{}.{}.{}.test",
            "a".repeat(64),
            "b".repeat(63),
            "c".repeat(63),
            "d".repeat(56)
        );
        assert_eq!(email.len(), 254);
        assert!(normalize_email(&email).is_ok());
        assert_eq!(
            normalize_email(&format!("a{email}")).unwrap_err().code,
            "LENGTH"
        );
    }

    /**
     * Ngăn client/backend lệch cách đếm hoặc âm thầm đổi credential bằng cách kiểm tra hai cận,
     * emoji và khoảng trắng theo Unicode scalar, đồng thời giữ nguyên input.
     */
    #[test]
    fn passwords_preserve_scalar_and_whitespace_boundaries() {
        assert!(validate_password(&"a".repeat(8), "/password").is_err());
        assert!(validate_password(&"a".repeat(9), "/password").is_ok());
        assert!(validate_password(&"a".repeat(128), "/password").is_ok());
        assert!(validate_password(&"a".repeat(129), "/password").is_err());
        assert!(validate_password(&"🔒".repeat(12), "/password").is_ok());
        assert!(validate_password(" abcdefghij ", "/password").is_ok());
        assert!(validate_password("abcdefgh", "/password").is_err());
    }
}
