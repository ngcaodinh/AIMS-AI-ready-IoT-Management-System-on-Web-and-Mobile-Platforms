//! Literal số chính xác cho template ENUM; không dùng float làm identity hoặc đưa JSON framework vào core.

/// Chuỗi JSON number canonical bảo toàn decimal; các cách viết cùng giá trị có cùng identity.
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct DecimalLiteral(String);

impl DecimalLiteral {
    /**
     * Kiểm cú pháp JSON number và chuẩn hóa hệ số/số mũ bằng chuỗi để không mất integer precision.
     * Input
     * Param: text — token số nguyên bản, không bao gồm khoảng trắng hoặc dấu nháy JSON string.
     * Output: literal exact trong miền numeric PostgreSQL hoặc None khi syntax/range không phù hợp.
     * Không tính toán bằng float; cận131072 chữ số phần nguyên/16383 phần thập phân theo PostgreSQL 17 đã công bố.
     */
    #[must_use]
    pub fn new(text: &str) -> Option<Self> {
        let negative = text.starts_with('-');
        let unsigned = text.strip_prefix('-').unwrap_or(text);
        let (mantissa, exponent) = match unsigned.split_once(['e', 'E']) {
            Some((mantissa, exponent)) => (mantissa, exponent.parse::<i64>().ok()?),
            None => (unsigned, 0),
        };
        let (whole, fraction) = match mantissa.split_once('.') {
            Some((whole, fraction)) if !fraction.is_empty() => (whole, fraction),
            Some(_) => return None,
            None => (mantissa, ""),
        };
        if whole.is_empty()
            || !whole.bytes().all(|byte| byte.is_ascii_digit())
            || !fraction.bytes().all(|byte| byte.is_ascii_digit())
            || (whole.len() > 1 && whole.starts_with('0'))
        {
            return None;
        }
        let joined = format!("{whole}{fraction}");
        let significant = joined.trim_start_matches('0');
        if significant.is_empty() {
            // JSONB equality không phân biệt âm0 hoặc số chữ số0; giữ một identity duy nhất.
            return Some(Self("0".to_owned()));
        }
        let digits = significant.trim_end_matches('0');
        let trailing = i64::try_from(significant.len() - digits.len()).ok()?;
        let scale = i64::try_from(fraction.len()).ok()?;
        let exponent = exponent.checked_sub(scale)?.checked_add(trailing)?;
        let integer_digits = i64::try_from(digits.len()).ok()?.checked_add(exponent)?;
        if integer_digits > 131_072 || exponent < -16_383 {
            return None;
        }
        let sign = if negative { "-" } else { "" };
        let canonical = if exponent == 0 {
            format!("{sign}{digits}")
        } else {
            format!("{sign}{digits}e{exponent}")
        };
        Some(Self(canonical))
    }

    /// Trả JSON number đã kiểm, không có dấu nháy hoặc cú pháp SQL; adapter vẫn phải bind khi ghi JSONB.
    #[must_use]
    pub fn json_number(&self) -> &str {
        &self.0
    }

    /**
     * Chiếu sang float8 cho bounds của kênh NUMBER; identity ENUM vẫn dùng decimal exact.
     * Output: float hữu hạn khác0 với literal khác0, hoặc None khi overflow/underflow.
     * Projection không thay đổi literal lưu trữ; không dùng giá trị này để dedupe ENUM.
     */
    #[must_use]
    pub fn finite_float(&self) -> Option<f64> {
        let value = self.0.parse::<f64>().ok()?;
        (value.is_finite() && (value != 0.0 || self.0 == "0")).then_some(value)
    }
}
