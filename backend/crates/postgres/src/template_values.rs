//! Decode/encode scalar qua projection typed và bind SQL, không phụ thuộc JSON framework trong core.

use crate::storage_error;
use iot_application::error::ApplicationError;
use iot_domain::{
    template::{ChannelKind, StreamDirection, StreamType, StreamValue},
    template_value::DecimalLiteral,
};
use sqlx::{Row, postgres::PgRow};

/**
 * Chuyển scalar domain đã kiểm sang tag/text để query CASE/`to_jsonb` bind mà không ghép JSON string thủ công.
 * Input
 * Param: value — NUMBER exact, BOOLEAN hoặc STRING; không object/array/null.
 * Output: literal type và text, adapter vẫn bind cả hai làm giá trị SQL.
 */
pub(super) fn scalar_parts(value: &StreamValue) -> (&'static str, String) {
    match value {
        StreamValue::Number(number) => ("NUMBER", number.json_number().to_owned()),
        StreamValue::Boolean(value) => ("BOOLEAN", value.to_string()),
        StreamValue::Text(text) => ("STRING", text.clone()),
    }
}

/**
 * Decode scalar từ typeof/text projection, không SELECT JSON object hoặc làm tròn số ENUM.
 * Input
 * Param: row — alias `value_type`/`value_text` của enum/safe value cùng tenant.
 * Output: scalar typed; Errors: Unavailable nếu persisted value sai shape/type/numeric range.
 */
pub(super) fn scalar(row: &PgRow) -> Result<StreamValue, ApplicationError> {
    let kind: String = row.try_get("value_type").map_err(storage_error)?;
    let text: String = row.try_get("value_text").map_err(storage_error)?;
    match kind.as_str() {
        "number" => DecimalLiteral::new(&text)
            .map(StreamValue::Number)
            .ok_or(ApplicationError::Unavailable),
        "string" => Ok(StreamValue::Text(text)),
        "boolean" => match text.as_str() {
            "true" => Ok(StreamValue::Boolean(true)),
            "false" => Ok(StreamValue::Boolean(false)),
            _ => Err(ApplicationError::Unavailable),
        },
        _ => Err(ApplicationError::Unavailable),
    }
}

/// Restore datatype hữu hạn; giá trị DB lạ fail-closed, không tự coi STRING là fallback an toàn.
pub(super) fn stream_type(text: &str) -> Result<StreamType, ApplicationError> {
    match text {
        "NUMBER" => Ok(StreamType::Number),
        "BOOLEAN" => Ok(StreamType::Boolean),
        "STRING" => Ok(StreamType::String),
        "ENUM" => Ok(StreamType::Enum),
        _ => Err(ApplicationError::Unavailable),
    }
}

/// Restore hướng đọc/ghi độc lập với phân loại kênh, không tự sinh capability từ direction.
pub(super) fn direction(text: &str) -> Result<StreamDirection, ApplicationError> {
    match text {
        "READ" => Ok(StreamDirection::Read),
        "WRITE" => Ok(StreamDirection::Write),
        "READ_WRITE" => Ok(StreamDirection::ReadWrite),
        _ => Err(ApplicationError::Unavailable),
    }
}

/// Restore channel kind bắt buộc từ snapshot, không đoán từ datatype hoặc direction.
pub(super) fn channel_kind(text: &str) -> Result<ChannelKind, ApplicationError> {
    match text {
        "TELEMETRY" => Ok(ChannelKind::Telemetry),
        "STATE" => Ok(ChannelKind::State),
        _ => Err(ApplicationError::Unavailable),
    }
}

/// Literal hữu hạn cho cột datatype; chỉ dùng làm bind value, không identifier SQL.
pub(super) const fn stream_type_code(value: StreamType) -> &'static str {
    match value {
        StreamType::Number => "NUMBER",
        StreamType::Boolean => "BOOLEAN",
        StreamType::String => "STRING",
        StreamType::Enum => "ENUM",
    }
}

/// Literal hữu hạn cho direction, độc lập channel kind và current authorization.
pub(super) const fn direction_code(value: StreamDirection) -> &'static str {
    match value {
        StreamDirection::Read => "READ",
        StreamDirection::Write => "WRITE",
        StreamDirection::ReadWrite => "READ_WRITE",
    }
}

/// Literal hữu hạn theo ADR004, không dùng direction làm default channel kind.
pub(super) const fn channel_kind_code(value: ChannelKind) -> &'static str {
    match value {
        ChannelKind::Telemetry => "TELEMETRY",
        ChannelKind::State => "STATE",
    }
}
