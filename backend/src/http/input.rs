//! JSON strict đệ quy để duplicate key không bị ghi đè trước khi validation field chạy.

use serde::{
    Deserialize, Deserializer,
    de::{MapAccess, SeqAccess, Visitor},
};
use serde_json::{Map, Number, Value};
use std::fmt;

pub(super) struct StrictValue(pub Value);

impl<'de> Deserialize<'de> for StrictValue {
    /** Parse mọi JSON shape trước validation root; Input: deserializer có recursion limit của `serde_json`. */
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        deserializer.deserialize_any(JsonVisitor)
    }
}

struct JsonVisitor;

impl<'de> Visitor<'de> for JsonVisitor {
    type Value = StrictValue;
    /** Mô tả lỗi parser tĩnh; không lộ nội dung input trong HTTP response. */
    fn expecting(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("valid JSON without duplicate object fields")
    }
    /** Nhận boolean đúng kiểu để boundary field phân biệt TYPE, không coerce thành chuỗi. */
    fn visit_bool<E: serde::de::Error>(self, value: bool) -> Result<Self::Value, E> {
        Ok(StrictValue(Value::Bool(value)))
    }
    /** Giữ integer âm để validator trả TYPE thay vì đổi credential đầu vào. */
    fn visit_i64<E: serde::de::Error>(self, value: i64) -> Result<Self::Value, E> {
        Ok(StrictValue(Value::Number(Number::from(value))))
    }
    /** Giữ integer không dấu đúng giá trị trong JSON. */
    fn visit_u64<E: serde::de::Error>(self, value: u64) -> Result<Self::Value, E> {
        Ok(StrictValue(Value::Number(Number::from(value))))
    }
    /** Từ chối non-finite number; Input: value parser số, không tự nhận NaN/Infinity ngoài JSON. */
    fn visit_f64<E: serde::de::Error>(self, value: f64) -> Result<Self::Value, E> {
        Number::from_f64(value)
            .map(|number| StrictValue(Value::Number(number)))
            .ok_or_else(|| E::custom("invalid JSON number"))
    }
    /** Giữ chuỗi nguyên bản, không trim password hay normalize Unicode tại parser. */
    fn visit_str<E: serde::de::Error>(self, value: &str) -> Result<Self::Value, E> {
        Ok(StrictValue(Value::String(value.to_owned())))
    }
    /** Nhận quyền sở hữu chuỗi do parser cấp để không tạo bản sao password không cần thiết. */
    fn visit_string<E: serde::de::Error>(self, value: String) -> Result<Self::Value, E> {
        Ok(StrictValue(Value::String(value)))
    }
    /** Giữ null để required và wrong type có mã khác nhau theo fixture. */
    fn visit_unit<E: serde::de::Error>(self) -> Result<Self::Value, E> {
        Ok(StrictValue(Value::Null))
    }
    /** Parse array đệ quy trước khi root/field validator trả TYPE; duplicate nested vẫn là malformed. */
    fn visit_seq<A: SeqAccess<'de>>(self, mut array: A) -> Result<Self::Value, A::Error> {
        let mut values = Vec::new();
        while let Some(StrictValue(value)) = array.next_element()? {
            values.push(value);
        }
        Ok(StrictValue(Value::Array(values)))
    }
    /** Chặn duplicate ở mọi cấp; Input: map chưa tin cậy, không lấy last key thắng. */
    fn visit_map<A: MapAccess<'de>>(self, mut map: A) -> Result<Self::Value, A::Error> {
        let mut fields = Map::new();
        while let Some(key) = map.next_key::<String>()? {
            if fields.contains_key(&key) {
                return Err(serde::de::Error::custom("duplicate field"));
            }
            let StrictValue(value) = map.next_value()?;
            fields.insert(key, value);
        }
        Ok(StrictValue(Value::Object(fields)))
    }
}
