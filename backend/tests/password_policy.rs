//! Oracle password tổng hợp dùng chung Web/Dart/Rust; không gọi DB hoặc ghi credential.

use iot_domain::input::{
    normalize_email, validate_current_password, validate_new_password, validate_password,
};
use serde_json::Value;

/** Kiểm cả ba vai trò password bằng cùng fixture để client/server không lệch Unicode, độ dài hoặc composition. */
#[test]
fn shared_password_policy_matches_each_boundary() {
    let fixture: Value = serde_json::from_str(include_str!(
        "../../contracts/fixtures/auth/password-policy.json"
    ))
    .unwrap();
    for case in fixture["cases"].as_array().unwrap() {
        let password = case["password"].as_str().unwrap();
        let actual = [
            ("loginError", validate_password(password, "/password")),
            (
                "currentError",
                validate_current_password(password, "/currentPassword"),
            ),
            ("newError", validate_new_password(password, "/newPassword")),
        ];
        for (field, result) in actual {
            assert_eq!(
                result.err().map(|error| error.code),
                case[field].as_str(),
                "{}:{field}",
                case["id"]
            );
        }
    }
}

/** Kiểm đủ cận scalar bằng emoji để bắt việc đếm UTF-8/UTF-16 hoặc normalize credential trước policy. */
#[test]
fn unicode_password_boundaries_preserve_original_scalar_sequence() {
    for length in [0, 1, 8, 9, 128, 129] {
        let password = "🔒".repeat(length);
        assert_eq!(
            validate_password(&password, "/password").is_ok(),
            (9..=128).contains(&length),
            "login scalar length {length}"
        );
        assert_eq!(
            validate_current_password(&password, "/currentPassword").is_ok(),
            (1..=128).contains(&length),
            "current scalar length {length}"
        );
    }
    for length in [8, 9, 128, 129] {
        let password = format!("Aa1{}", "🔒".repeat(length - 3));
        assert_eq!(
            validate_new_password(&password, "/newPassword").is_ok(),
            (9..=128).contains(&length),
            "new scalar length {length}"
        );
    }
    // Hai chuỗi tương đương NFC có số scalar khác nhau; normalize sẽ đổi kết quả ở cận9.
    let decomposed = "Aa1e\u{301}xxxx";
    let composed = "Aa1éxxxx";
    assert_eq!(decomposed.chars().count(), 9);
    assert_eq!(composed.chars().count(), 8);
    assert!(validate_password(decomposed, "/password").is_ok());
    assert!(validate_current_password(decomposed, "/currentPassword").is_ok());
    assert!(validate_new_password(decomposed, "/newPassword").is_ok());
    assert_eq!(
        validate_password(composed, "/password").unwrap_err().code,
        "LENGTH"
    );
    assert_eq!(
        validate_new_password(composed, "/newPassword")
            .unwrap_err()
            .code,
        "LENGTH"
    );
}

/** Cùng oracle email OQ001 kiểm ASCII trim/case và Unicode rejection, giữ dot/+tag để khóa identity không bị gộp. */
#[test]
fn shared_email_policy_canonicalizes_only_approved_identity_equivalents() {
    let fixture: Value = serde_json::from_str(include_str!(
        "../../contracts/fixtures/auth/email-policy.json"
    ))
    .unwrap();
    assert_eq!(fixture["policyVersion"], 1);
    let mut keys = std::collections::HashSet::new();
    let mut accepted = 0;
    for case in fixture["cases"].as_array().unwrap() {
        let result = normalize_email(case["email"].as_str().unwrap());
        match result {
            Ok(canonical) => {
                assert!(case["error"].is_null(), "{}", case["id"]);
                assert_eq!(
                    Some(canonical.as_str()),
                    case["canonical"].as_str(),
                    "{}",
                    case["id"]
                );
                keys.insert(canonical);
                accepted += 1;
            }
            Err(error) => {
                assert_eq!(Some(error.code), case["error"].as_str(), "{}", case["id"]);
                assert_eq!(error.path, "/email");
            }
        }
    }
    // Sáu input hợp lệ có ba biến thể cùng canonical key và ba identity dot/+tag/plain khác nhau.
    assert_eq!(accepted, 6);
    assert_eq!(keys.len(), 4);
}
