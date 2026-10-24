//! Literal số template không mất precision khi ENUM so sánh theo giá trị JSONB.

use iot_domain::template_value::DecimalLiteral;

/// Số khác cách viết phải có cùng identity, trong khi integer lớn vẫn giữ khác biệt từng đơn vị.
#[test]
fn decimal_identity_preserves_precision_and_normalizes_equivalent_notation() {
    let one = DecimalLiteral::new("1").unwrap();
    for text in ["1.0", "10e-1", "0.01e2", "1e+0000"] {
        assert_eq!(one, DecimalLiteral::new(text).unwrap());
    }
    assert_eq!(DecimalLiteral::new("-0.000e7").unwrap().json_number(), "0");
    assert_eq!(
        DecimalLiteral::new("100.10").unwrap().json_number(),
        "1001e-1"
    );
    assert_ne!(
        DecimalLiteral::new("9007199254740992"),
        DecimalLiteral::new("9007199254740993")
    );
    assert_eq!(
        DecimalLiteral::new("9007199254740993")
            .unwrap()
            .json_number(),
        "9007199254740993"
    );
    assert!(DecimalLiteral::new("1e1000").is_some());
}

/// Chặn cú pháp không phải JSON number và giá trị vượt miền JSONB numeric, không chấp nhận NaN/Infinity.
#[test]
fn rejects_invalid_json_numbers_and_postgresql_numeric_overflow() {
    for text in [
        "",
        "+1",
        "01",
        "-01",
        ".1",
        "1.",
        "1e",
        "1e+",
        "1e1e1",
        " 1",
        "1 ",
        "NaN",
        "Infinity",
        "-Infinity",
        "1_000",
        "--1",
        "1e131072",
        "1e-16384",
    ] {
        assert!(
            DecimalLiteral::new(text).is_none(),
            "unexpected number: {text}"
        );
    }
    assert!(DecimalLiteral::new("1e131071").is_some());
    assert!(DecimalLiteral::new("1e-16383").is_some());
}

/// NUMBER dùng float8 hữu hạn, còn ENUM numeric giữ decimal exact và không bị ép theo float8.
#[test]
fn float_projection_rejects_overflow_and_underflow_without_changing_literal() {
    assert_eq!(
        DecimalLiteral::new("1.25").unwrap().finite_float(),
        Some(1.25)
    );
    assert_eq!(DecimalLiteral::new("0").unwrap().finite_float(), Some(0.0));
    assert_eq!(DecimalLiteral::new("1e1000").unwrap().finite_float(), None);
    assert_eq!(DecimalLiteral::new("1e-1000").unwrap().finite_float(), None);
    assert_eq!(
        DecimalLiteral::new("-1e-1000").unwrap().finite_float(),
        None
    );
    assert!(
        DecimalLiteral::new("5e-324")
            .unwrap()
            .finite_float()
            .is_some()
    );
}
