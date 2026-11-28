//! Adapter wire template. Số JSON giữ nguyên token cho đến validation và không coerce scalar.

use super::{HttpError, security};
use axum::{body::to_bytes, extract::Request};
use iot_domain::{
    template::{
        ChannelKind, StreamDirection, StreamDraft, StreamType, StreamValue, TemplateDraft,
        TemplateField, TemplateIssueReason, TemplateValidation, ValidatedTemplate,
        normalize_template_name,
    },
    template_value::DecimalLiteral,
};
use serde::{
    Deserialize, Deserializer, Serialize,
    de::{DeserializeOwned, MapAccess, Visitor},
};
use serde_json::{
    json,
    value::{RawValue, to_raw_value},
};
use std::{
    collections::{BTreeMap, BTreeSet},
    fmt,
};

pub(super) struct Fields(BTreeMap<String, Box<RawValue>>);
struct FieldsVisitor;

impl<'de> Deserialize<'de> for Fields {
    /// Đọc object strict nhưng giữ token số thay vì parse float trước kiểm miền cấu hình.
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        deserializer.deserialize_map(FieldsVisitor)
    }
}

impl<'de> Visitor<'de> for FieldsVisitor {
    type Value = Fields;

    /// Thông báo shape tĩnh để lỗi không chứa giá trị do client cấp.
    fn expecting(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("a JSON object with unique keys")
    }

    /// Bắt duplicate cả khi key dùng escape khác và giữ raw scalar theo bytes UTF-8.
    fn visit_map<M: MapAccess<'de>>(self, mut access: M) -> Result<Fields, M::Error> {
        let mut output = BTreeMap::new();
        while let Some((key, value)) = access.next_entry()? {
            if output.insert(key, value).is_some() {
                return Err(serde::de::Error::custom("duplicate field"));
            }
        }
        Ok(Fields(output))
    }
}

/// Dựng lỗi field bằng path do adapter cấp, loại bỏ input value và lỗi parser gốc.
pub(super) fn field_error(
    status: u16,
    envelope: &'static str,
    path: &str,
    code: &'static str,
) -> HttpError {
    let mut error = HttpError::code(status, envelope);
    error.details = json!({"fieldErrors":[{"path":path,"code":code}]});
    error
}

/// Đọc JSON UTF-8 tối đa64 KiB; giữ overflow số hợp lệ về cú pháp cho validation 422.
pub(super) async fn read_fields(request: Request) -> Result<Fields, HttpError> {
    let mime = security::single_header(request.headers(), "content-type")?.unwrap_or("");
    if !mime
        .split(';')
        .next()
        .is_some_and(|part| part.trim().eq_ignore_ascii_case("application/json"))
    {
        return Err(HttpError::validation(415, "", "CONTENT_TYPE"));
    }
    let bytes = to_bytes(request.into_body(), 65_536)
        .await
        .map_err(|_| HttpError::validation(413, "", "BODY_TOO_LARGE"))?;
    let raw = serde_json::from_slice::<Box<RawValue>>(&bytes)
        .map_err(|_| HttpError::validation(400, "", "MALFORMED_JSON"))?;
    object(&raw, "")
}

/// Đọc object ở boundary và phân biệt field lặp với kiểu JSON sai.
fn object(raw: &RawValue, path: &str) -> Result<Fields, HttpError> {
    serde_json::from_str(raw.get()).map_err(|error| {
        if error.to_string().starts_with("duplicate field") {
            field_error(400, "VALIDATION_ERROR", path, "DUPLICATE_FIELD")
        } else {
            field_error(422, "VALIDATION_ERROR", path, "TYPE")
        }
    })
}

impl Fields {
    /// Kiểm allowlist theo shape. Chỉ echo path/tên field đã biết để không tiết lộ input tự khai.
    pub(super) fn allow(&self, allowed: &[&str], path: &str) -> Result<(), HttpError> {
        for key in self.0.keys() {
            if !allowed.contains(&key.as_str()) {
                let error_path = match key.as_str() {
                    "safeValue" | "workspaceId" => format!("{path}/{key}"),
                    _ => path.to_owned(),
                };
                return Err(field_error(422, "VALIDATION_ERROR", &error_path, "UNKNOWN"));
            }
        }
        Ok(())
    }

    /// Đọc field tùy chọn; present null vẫn qua kiểm kiểu và không trở thành vắng.
    fn optional<T: DeserializeOwned>(
        &self,
        key: &str,
        parent: &str,
    ) -> Result<Option<T>, HttpError> {
        self.0
            .get(key)
            .map(|value| {
                serde_json::from_str(value.get()).map_err(|_| {
                    field_error(422, "VALIDATION_ERROR", &format!("{parent}/{key}"), "TYPE")
                })
            })
            .transpose()
    }

    /// Đọc field bắt buộc với path chuẩn; không suy giá trị khi field không truyền.
    pub(super) fn required<T: DeserializeOwned>(
        &self,
        key: &str,
        parent: &str,
    ) -> Result<T, HttpError> {
        self.optional(key, parent)?.ok_or_else(|| {
            field_error(
                422,
                "VALIDATION_ERROR",
                &format!("{parent}/{key}"),
                "REQUIRED",
            )
        })
    }

    /// Giữ literal gốc cho default/bounds/safeValue để kiểm type và precision trước persist.
    fn raw(&self, key: &str) -> Option<&RawValue> {
        self.0.get(key).map(Box::as_ref)
    }
}

/// Chuẩn hóa tên NFC sau trim và đo Unicode code points theo OQ-TEMPLATE-001.
fn normalized_name(input: String) -> Result<String, HttpError> {
    normalize_template_name(&input)
        .map_err(|_| field_error(422, "VALIDATION_ERROR", "/name", "FORMAT"))
}

/// Kiểm canonical model ID ở mức wire; policy model triển khai nằm ngoài parser.
fn model_id(model: String) -> Result<String, HttpError> {
    if !(1..=64).contains(&model.chars().count())
        || model.trim() != model
        || model.chars().any(char::is_control)
    {
        return Err(field_error(422, "VALIDATION_ERROR", "/model", "FORMAT"));
    }
    Ok(model)
}

/// Chuyển direction hữu hạn mà không chọn channel kind thay caller.
fn direction(token: &str) -> Option<StreamDirection> {
    match token {
        "READ" => Some(StreamDirection::Read),
        "WRITE" => Some(StreamDirection::Write),
        "READ_WRITE" => Some(StreamDirection::ReadWrite),
        _ => None,
    }
}

/// Chuyển channel kind hữu hạn mà không chọn direction thay caller.
fn channel_kind(token: &str) -> Option<ChannelKind> {
    match token {
        "TELEMETRY" => Some(ChannelKind::Telemetry),
        "STATE" => Some(ChannelKind::State),
        _ => None,
    }
}

/// Ánh xạ mode chỉ tới trục đúng theo token; trục bổ sung luôn phải có mặt.
fn axes(input: &Fields, path: &str) -> Result<(ChannelKind, StreamDirection), HttpError> {
    let kind: Option<String> = input.optional("channelKind", path)?;
    let direction_token: Option<String> = input.optional("direction", path)?;
    let mode: Option<String> = input.optional("mode", path)?;
    let (kind, direction_token) =
        match (kind.as_deref(), direction_token.as_deref(), mode.as_deref()) {
            (kind, direction_token, None) => (kind, direction_token),
            (Some(kind), None, Some(mode)) if direction(mode).is_some() => (Some(kind), Some(mode)),
            (None, Some(direction_token), Some(mode)) if channel_kind(mode).is_some() => {
                (Some(mode), Some(direction_token))
            }
            _ => {
                return Err(field_error(
                    422,
                    "VALIDATION_ERROR",
                    &format!("{path}/mode"),
                    "FORMAT",
                ));
            }
        };
    let kind = kind.ok_or_else(|| {
        field_error(
            422,
            "VALIDATION_ERROR",
            &format!("{path}/channelKind"),
            "REQUIRED",
        )
    })?;
    let direction_token = direction_token.ok_or_else(|| {
        field_error(
            422,
            "VALIDATION_ERROR",
            &format!("{path}/direction"),
            "REQUIRED",
        )
    })?;
    Ok((
        channel_kind(kind).ok_or_else(|| {
            field_error(
                422,
                "VALIDATION_ERROR",
                &format!("{path}/channelKind"),
                "FORMAT",
            )
        })?,
        direction(direction_token).ok_or_else(|| {
            field_error(
                422,
                "VALIDATION_ERROR",
                &format!("{path}/direction"),
                "FORMAT",
            )
        })?,
    ))
}

/// Decode scalar exact, không đọc object/array/null như safeValue hoặc default.
fn scalar(raw: &RawValue, path: &str) -> Result<StreamValue, HttpError> {
    let raw = raw.get();
    match raw.as_bytes().first() {
        Some(b'"') => serde_json::from_str(raw).map(StreamValue::Text).ok(),
        Some(b't') => Some(StreamValue::Boolean(true)),
        Some(b'f') => Some(StreamValue::Boolean(false)),
        Some(b'-' | b'0'..=b'9') => DecimalLiteral::new(raw).map(StreamValue::Number),
        _ => None,
    }
    .ok_or_else(|| field_error(422, "STREAM_INVALID", path, "INVALID_VALUE"))
}

/// Parse optional bound finite từ JSON number gốc để overflow hợp lệ cú pháp trả lỗi stream.
fn bound(input: &Fields, name: &str, path: &str) -> Result<Option<f64>, HttpError> {
    let Some(raw) = input.raw(name) else {
        return Ok(None);
    };
    DecimalLiteral::new(raw.get())
        .and_then(|value| value.finite_float())
        .map(Some)
        .ok_or_else(|| {
            field_error(
                422,
                "STREAM_INVALID",
                &format!("{path}/{name}"),
                "INVALID_BOUNDS",
            )
        })
}

/// Đọc stream mới và bảo toàn metadata nội bộ của cùng key khi wire không biểu diễn field đó.
fn stream(
    raw: &RawValue,
    index: usize,
    previous: Option<&TemplateDraft>,
) -> Result<StreamDraft, HttpError> {
    let path = format!("/streams/{index}");
    let input = object(raw, &path)?;
    input.allow(
        &[
            "key",
            "type",
            "channelKind",
            "direction",
            "mode",
            "unit",
            "min",
            "max",
            "enumValues",
            "default",
        ],
        &path,
    )?;
    let key: String = input.required("key", &path)?;
    let (channel_kind, direction) = axes(&input, &path)?;
    let data_type = match input.required::<String>("type", &path)?.as_str() {
        "NUMBER" => StreamType::Number,
        "BOOLEAN" => StreamType::Boolean,
        "STRING" => StreamType::String,
        "ENUM" => StreamType::Enum,
        _ => {
            return Err(field_error(
                422,
                "STREAM_INVALID",
                &format!("{path}/type"),
                "FORMAT",
            ));
        }
    };
    let unit = input.optional::<Option<String>>("unit", &path)?.flatten();
    if unit.as_ref().is_some_and(|value| {
        data_type != StreamType::Number || !(1..=32).contains(&value.chars().count())
    }) {
        return Err(field_error(
            422,
            "STREAM_INVALID",
            &format!("{path}/unit"),
            "INCOMPATIBLE",
        ));
    }
    let minimum = bound(&input, "min", &path)?;
    let maximum = bound(&input, "max", &path)?;
    if data_type == StreamType::Number
        && direction != StreamDirection::Read
        && (minimum.is_none() || maximum.is_none())
    {
        let missing = if minimum.is_none() { "min" } else { "max" };
        return Err(field_error(
            422,
            "STREAM_INVALID",
            &format!("{path}/{missing}"),
            "REQUIRED",
        ));
    }
    let enum_values = input.optional::<Vec<String>>("enumValues", &path)?;
    if enum_values.as_ref().is_some_and(|values| {
        data_type != StreamType::Enum
            || !(1..=64).contains(&values.len())
            || values
                .iter()
                .any(|value| !(1..=64).contains(&value.chars().count()))
    }) {
        return Err(field_error(
            422,
            "STREAM_INVALID",
            &format!("{path}/enumValues"),
            "INVALID_VALUE",
        ));
    }
    let previous = previous.and_then(|draft| draft.streams.iter().find(|stream| stream.key == key));
    Ok(StreamDraft {
        display_name: previous.map_or_else(|| key.clone(), |stream| stream.display_name.clone()),
        key,
        channel_kind,
        direction,
        data_type,
        unit,
        minimum,
        maximum,
        string_max_length: previous
            .filter(|old| old.data_type == data_type)
            .and_then(|old| old.string_max_length),
        enum_values: enum_values
            .unwrap_or_default()
            .into_iter()
            .map(StreamValue::Text)
            .collect(),
        default_value: input
            .raw("default")
            .map(|raw| scalar(raw, &format!("{path}/default")))
            .transpose()?,
        safe_value: None,
    })
}

/// Đọc capability SET_VALUE cùng key và typed safeValue, không nhận ID client cung cấp.
fn command(raw: &RawValue, index: usize) -> Result<(String, StreamValue), HttpError> {
    let path = format!("/commands/{index}");
    let input = object(raw, &path)?;
    input.allow(&["type", "stream", "safeValue"], &path)?;
    if input.required::<String>("type", &path)? != "SET_VALUE" {
        return Err(field_error(
            422,
            "STREAM_INVALID",
            &format!("{path}/type"),
            "FORMAT",
        ));
    }
    let safe_value = input.raw("safeValue").ok_or_else(|| {
        field_error(
            422,
            "STREAM_INVALID",
            &format!("{path}/safeValue"),
            "REQUIRED",
        )
    })?;
    Ok((
        input.required("stream", &path)?,
        scalar(safe_value, &format!("{path}/safeValue"))?,
    ))
}

/// Đọc array có cận; khi create thiếu field trả 422, khi PATCH giữ array đã lưu.
fn items(input: &Fields, key: &str, create: bool) -> Result<Option<Vec<Box<RawValue>>>, HttpError> {
    let values = if create {
        Some(input.required::<Vec<_>>(key, "")?)
    } else {
        input.optional(key, "")?
    };
    if values.as_ref().is_some_and(|values| values.len() > 64) {
        return Err(field_error(
            422,
            "VALIDATION_ERROR",
            &format!("/{key}"),
            "LIMIT",
        ));
    }
    Ok(values)
}

/// Đóng candidate duy nhất từ POST/PATCH và map command sang đúng stream trước domain validation.
pub(super) fn candidate(
    input: &Fields,
    previous: Option<&TemplateDraft>,
) -> Result<ValidatedTemplate, HttpError> {
    input.allow(&["name", "model", "streams", "commands"], "")?;
    if input.0.is_empty() && previous.is_some() {
        return Err(HttpError::validation(422, "", "REQUIRED"));
    }
    let (name, model) = if let Some(previous) = previous {
        (
            input
                .optional("name", "")?
                .map(normalized_name)
                .transpose()?
                .unwrap_or_else(|| previous.name.clone()),
            input
                .optional("model", "")?
                .map(model_id)
                .transpose()?
                .unwrap_or_else(|| previous.model.clone()),
        )
    } else {
        (
            normalized_name(input.required("name", "")?)?,
            model_id(input.required("model", "")?)?,
        )
    };
    let mut streams = if let Some(items) = items(input, "streams", previous.is_none())? {
        items
            .iter()
            .enumerate()
            .map(|(index, raw)| stream(raw, index, previous))
            .collect::<Result<Vec<_>, _>>()?
    } else {
        previous.map_or_else(Vec::new, |draft| draft.streams.clone())
    };
    let commands = if let Some(items) = items(input, "commands", previous.is_none())? {
        items
            .iter()
            .enumerate()
            .map(|(index, raw)| command(raw, index))
            .collect::<Result<Vec<_>, _>>()?
    } else {
        previous
            .into_iter()
            .flat_map(|draft| &draft.streams)
            .filter_map(|stream| {
                stream
                    .safe_value
                    .as_ref()
                    .map(|safe| (stream.key.clone(), safe.clone()))
            })
            .collect()
    };
    for stream in &mut streams {
        stream.safe_value = None;
    }
    let mut indices = BTreeMap::new();
    let mut stream_keys = BTreeSet::new();
    for (index, stream) in streams.iter().enumerate() {
        if !stream_keys.insert(stream.key.clone()) {
            return Err(field_error(
                422,
                "STREAM_INVALID",
                &format!("/streams/{index}/key"),
                "DUPLICATE",
            ));
        }
    }
    for (index, (key, value)) in commands.into_iter().enumerate() {
        let path = format!("/commands/{index}/stream");
        if indices.insert(key.clone(), index).is_some() {
            return Err(field_error(422, "STREAM_INVALID", &path, "DUPLICATE"));
        }
        let target = streams
            .iter_mut()
            .find(|stream| stream.key == key)
            .ok_or_else(|| field_error(422, "STREAM_INVALID", &path, "INVALID_VALUE"))?;
        if target.direction == StreamDirection::Read || target.data_type == StreamType::String {
            return Err(field_error(422, "STREAM_INVALID", &path, "INCOMPATIBLE"));
        }
        target.safe_value = Some(value);
    }
    let keys = streams
        .iter()
        .map(|stream| stream.key.clone())
        .collect::<Vec<_>>();
    TemplateDraft {
        name,
        model,
        description: previous.and_then(|draft| draft.description.clone()),
        streams,
    }
    .validate()
    .map_err(|issue| {
        let command_index = issue
            .stream_index
            .and_then(|index| keys.get(index))
            .and_then(|key| indices.get(key))
            .copied();
        template_error(issue, command_index)
    })
}

/// Chuyển lỗi domain sang JSON Pointer và mã giới hạn; lỗi safeValue trỏ đúng command đầu vào.
pub(super) fn template_error(issue: TemplateValidation, command_index: Option<usize>) -> HttpError {
    let field = match issue.field {
        TemplateField::Name => "name",
        TemplateField::Model => "model",
        TemplateField::Description => "description",
        TemplateField::Key => "key",
        TemplateField::DisplayName => "key",
        TemplateField::Unit => "unit",
        TemplateField::Minimum => "min",
        TemplateField::Maximum => "max",
        TemplateField::StringMaxLength => "default",
        TemplateField::EnumValues => "enumValues",
        TemplateField::Direction => "direction",
        TemplateField::DefaultValue => "default",
        TemplateField::SafeValue => "safeValue",
    };
    let path = match (issue.stream_index, issue.field, command_index) {
        (_, TemplateField::SafeValue, Some(index)) => format!("/commands/{index}/safeValue"),
        (_, TemplateField::SafeValue, None) => "/commands".to_owned(),
        (Some(index), _, _) => format!("/streams/{index}/{field}"),
        (None, TemplateField::Key, _) => "/streams".to_owned(),
        (None, _, _) => format!("/{field}"),
    };
    let code = match issue.reason {
        TemplateIssueReason::Required => "REQUIRED",
        TemplateIssueReason::InvalidPattern => "FORMAT",
        TemplateIssueReason::Duplicate => "DUPLICATE",
        TemplateIssueReason::InvalidBounds => "INVALID_BOUNDS",
        TemplateIssueReason::Incompatible => "INCOMPATIBLE",
        TemplateIssueReason::InvalidValue => "INVALID_VALUE",
    };
    field_error(422, "STREAM_INVALID", &path, code)
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct StreamOutput<'a> {
    key: &'a str,
    #[serde(rename = "type")]
    data_type: &'static str,
    channel_kind: &'static str,
    direction: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    unit: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    min: Option<Box<RawValue>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    max: Option<Box<RawValue>>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    enum_values: Vec<Box<RawValue>>,
    #[serde(skip_serializing_if = "Option::is_none", rename = "default")]
    default_value: Option<Box<RawValue>>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct CommandOutput<'a> {
    #[serde(rename = "type")]
    command_type: &'static str,
    stream: &'a str,
    safe_value: Box<RawValue>,
}

#[derive(Serialize)]
pub(super) struct Configuration<'a> {
    name: &'a str,
    model: &'a str,
    streams: Vec<StreamOutput<'a>>,
    commands: Vec<CommandOutput<'a>>,
}

/// Serialize scalar giữ numeric literal đã validate, kể cả ENUM số lịch sử lớn hơn safe integer.
fn json_scalar(value: &StreamValue) -> Result<Box<RawValue>, HttpError> {
    match value {
        StreamValue::Number(number) => RawValue::from_string(number.json_number().to_owned()),
        StreamValue::Boolean(value) => to_raw_value(value),
        StreamValue::Text(value) => to_raw_value(value),
    }
    .map_err(|_| HttpError::unavailable())
}

/// Xuất bound finite ở dạng số JSON. Bound nguyên dùng spelling nguyên trong fixture và DTO.
fn json_bound(value: f64) -> Result<Box<RawValue>, HttpError> {
    RawValue::from_string(value.to_string()).map_err(|_| HttpError::unavailable())
}

/// Dựng capability wire từ giá trị persisted trên stream, không phản chiếu command request.
pub(super) fn capabilities(draft: &TemplateDraft) -> Result<Vec<CommandOutput<'_>>, HttpError> {
    draft
        .streams
        .iter()
        .filter_map(|stream| stream.safe_value.as_ref().map(|value| (stream, value)))
        .map(|(stream, value)| {
            Ok(CommandOutput {
                command_type: "SET_VALUE",
                stream: &stream.key,
                safe_value: json_scalar(value)?,
            })
        })
        .collect()
}

/// Dựng projection canonical; mỗi trục lấy đúng thuộc tính domain và không phát mode.
pub(super) fn configuration(draft: &TemplateDraft) -> Result<Configuration<'_>, HttpError> {
    let streams = draft
        .streams
        .iter()
        .map(|stream| {
            Ok(StreamOutput {
                key: &stream.key,
                data_type: match stream.data_type {
                    StreamType::Number => "NUMBER",
                    StreamType::Boolean => "BOOLEAN",
                    StreamType::String => "STRING",
                    StreamType::Enum => "ENUM",
                },
                channel_kind: match stream.channel_kind {
                    ChannelKind::Telemetry => "TELEMETRY",
                    ChannelKind::State => "STATE",
                },
                direction: match stream.direction {
                    StreamDirection::Read => "READ",
                    StreamDirection::Write => "WRITE",
                    StreamDirection::ReadWrite => "READ_WRITE",
                },
                unit: stream.unit.as_deref(),
                min: stream.minimum.map(json_bound).transpose()?,
                max: stream.maximum.map(json_bound).transpose()?,
                enum_values: stream
                    .enum_values
                    .iter()
                    .map(json_scalar)
                    .collect::<Result<Vec<_>, _>>()?,
                default_value: stream.default_value.as_ref().map(json_scalar).transpose()?,
            })
        })
        .collect::<Result<Vec<_>, HttpError>>()?;
    Ok(Configuration {
        name: &draft.name,
        model: &draft.model,
        streams,
        commands: capabilities(draft)?,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;

    /// So cả hai dạng legacy với canonical bằng đúng provider decoder và golden contract.
    #[test]
    fn golden_request_mapping() {
        let fixture: Value = serde_json::from_str(include_str!(
            "../../../contracts/fixtures/api/templates-devices.v1.json"
        ))
        .unwrap();
        let cases = fixture["scenarios"].as_array().unwrap();
        for case in cases
            .iter()
            .filter(|case| case["operationId"] == "createTemplate")
        {
            let input: Fields = serde_json::from_str(&case["request"]["body"].to_string()).unwrap();
            match candidate(&input, None) {
                Ok(result) => {
                    assert_eq!(case["response"]["status"], 201, "{}", case["id"]);
                    let Ok(output) = configuration(result.draft()) else {
                        panic!("fixture {} failed template projection", case["id"]);
                    };
                    let serialized = serde_json::to_string(&output).unwrap();
                    let saved: Value = serde_json::from_str(&serialized).unwrap();
                    assert_eq!(saved["streams"], case["response"]["body"]["streams"]);
                    assert_eq!(saved["commands"], case["response"]["body"]["commands"]);
                }
                Err(error) => {
                    assert_eq!(case["response"]["status"], error.status, "{}", case["id"]);
                    assert_eq!(
                        case["response"]["body"]["error"]["code"], error.code,
                        "{}",
                        case["id"]
                    );
                    assert_eq!(
                        case["response"]["body"]["error"]["details"], error.details,
                        "{}",
                        case["id"]
                    );
                }
            }
        }
    }

    /// Kiểm overflow, duplicate escaped và thay array không bỏ qua command còn tham chiếu.
    #[test]
    fn strict_candidate_and_merge() {
        let input: Fields = serde_json::from_str(r#"{"name":"Test","model":"TEST","streams":[{"key":"fan","type":"BOOLEAN","channelKind":"STATE","direction":"WRITE","default":true}],"commands":[{"type":"SET_VALUE","stream":"fan","safeValue":false}]}"#).unwrap();
        let before =
            candidate(&input, None).unwrap_or_else(|_| panic!("valid synthetic candidate"));
        let incomplete: Fields = serde_json::from_str(r#"{"streams":[]}"#).unwrap();
        assert!(candidate(&incomplete, Some(before.draft())).is_err());
        let complete: Fields = serde_json::from_str(r#"{"streams":[],"commands":[]}"#).unwrap();
        assert!(candidate(&complete, Some(before.draft())).is_ok());

        let overflow: Fields = serde_json::from_str(r#"{"streams":[{"key":"temperature","type":"NUMBER","channelKind":"TELEMETRY","direction":"READ","min":1e309}],"commands":[]}"#).unwrap();
        let error = candidate(&overflow, Some(before.draft())).unwrap_err();
        assert_eq!((error.status, error.code), (422, "STREAM_INVALID"));
        let duplicate: Fields = serde_json::from_str(
            r#"{"streams":[{"key":"fan","k\u0065y":"duplicate"}],"commands":[]}"#,
        )
        .unwrap();
        assert_eq!(
            candidate(&duplicate, Some(before.draft()))
                .unwrap_err()
                .status,
            400
        );
    }
}
