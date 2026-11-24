//! Schema template thuần: loại kênh, direction, datatype và capability là các ràng buộc riêng.

use crate::template_value::DecimalLiteral;
use std::collections::BTreeSet;

/// Phân loại ý nghĩa dữ liệu, không cấp quyền điều khiển hoặc thay reported evidence.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ChannelKind {
    Telemetry,
    State,
}

/// Khả năng sử dụng kênh; current authorization và capability vẫn phải kiểm riêng.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum StreamDirection {
    Read,
    Write,
    ReadWrite,
}

/// Kiểu scalar hữu hạn trong platform, không hỗ trợ JSON object/array tùy ý.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum StreamType {
    Number,
    Boolean,
    String,
    Enum,
}

/// Giá trị typed; thứ tự derive chỉ phục vụ set/canonical serialization, không so sánh numeric range.
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum StreamValue {
    Number(DecimalLiteral),
    Boolean(bool),
    Text(String),
}

/// Input schema chưa được tin cậy; caller phải validate toàn aggregate trước ghi draft hoặc publish.
#[derive(Clone, Debug)]
pub struct StreamDraft {
    pub key: String,
    pub display_name: String,
    pub channel_kind: ChannelKind,
    pub data_type: StreamType,
    pub direction: StreamDirection,
    pub unit: Option<String>,
    pub minimum: Option<f64>,
    pub maximum: Option<f64>,
    pub string_max_length: Option<i32>,
    pub enum_values: Vec<StreamValue>,
    pub safe_value: Option<StreamValue>,
}

/// Trường lỗi typed cho wire adapter dựng field path mà không trả lại raw value hoặc SQL detail.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TemplateField {
    Name,
    Model,
    Description,
    Streams,
    Key,
    DisplayName,
    Unit,
    Minimum,
    Maximum,
    StringMaxLength,
    EnumValues,
    Direction,
    SafeValue,
}

/// Lý do finite/shape/value hữu hạn, không chứa nội dung request không tin cậy.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TemplateIssueReason {
    Required,
    InvalidPattern,
    Duplicate,
    InvalidBounds,
    Incompatible,
    InvalidValue,
}

/// Đường dẫn nội bộ: None là metadata root, Some là index stream trong request gốc.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct TemplateValidation {
    pub stream_index: Option<usize>,
    pub field: TemplateField,
    pub reason: TemplateIssueReason,
}

impl StreamDraft {
    /**
     * Kiểm toàn bộ definition và safeValue để draft/publish không lưu schema không nhất quán.
     * Input
     * Param: index — vị trí stream trong aggregate gốc, chỉ dùng gắn lỗi field path.
     * Output: thành công khi mọi invariant hợp lệ; Errors: field/reason không chứa raw value.
     */
    fn validate(&self, index: usize) -> Result<(), TemplateValidation> {
        let issue = |field, reason| TemplateValidation {
            stream_index: Some(index),
            field,
            reason,
        };
        if !valid_key(&self.key) {
            return Err(issue(
                TemplateField::Key,
                TemplateIssueReason::InvalidPattern,
            ));
        }
        for (value, field) in [
            (Some(self.display_name.as_str()), TemplateField::DisplayName),
            (self.unit.as_deref(), TemplateField::Unit),
        ] {
            if value.is_some_and(|text| text.contains('\0')) {
                return Err(issue(field, TemplateIssueReason::InvalidValue));
            }
        }
        for (bound, field) in [
            (self.minimum, TemplateField::Minimum),
            (self.maximum, TemplateField::Maximum),
        ] {
            if let Some(bound) = bound {
                if self.data_type != StreamType::Number || !bound.is_finite() {
                    return Err(issue(field, TemplateIssueReason::InvalidBounds));
                }
            }
        }
        if matches!((self.minimum,self.maximum),(Some(minimum),Some(maximum)) if minimum>maximum) {
            return Err(issue(
                TemplateField::Maximum,
                TemplateIssueReason::InvalidBounds,
            ));
        }
        if self
            .string_max_length
            .is_some_and(|length| length <= 0 || self.data_type != StreamType::String)
        {
            return Err(issue(
                TemplateField::StringMaxLength,
                TemplateIssueReason::Incompatible,
            ));
        }
        self.validate_enum(index)?;
        self.validate_safe_value(index)
    }

    /**
     * Kiểm tập ENUM bằng equality decimal exact và literal string, không gộp số1 với chuỗi "1".
     * Input
     * Param: index — index request để gắn field enumValues khi báo lỗi.
     * Output: thành công với ENUM nonempty/unique hoặc non-ENUM không có enum values.
     * Errors: tập rỗng, trùng, boolean hoặc NUL không được lưu vào relation enum JSON scalar.
     */
    fn validate_enum(&self, index: usize) -> Result<(), TemplateValidation> {
        let issue = |reason| TemplateValidation {
            stream_index: Some(index),
            field: TemplateField::EnumValues,
            reason,
        };
        if self.data_type != StreamType::Enum {
            return if self.enum_values.is_empty() {
                Ok(())
            } else {
                Err(issue(TemplateIssueReason::Incompatible))
            };
        }
        if self.enum_values.is_empty() {
            return Err(issue(TemplateIssueReason::Required));
        }
        let mut seen = BTreeSet::new();
        for value in &self.enum_values {
            if matches!(value, StreamValue::Boolean(_))
                || matches!(value,StreamValue::Text(text) if text.contains('\0'))
            {
                return Err(issue(TemplateIssueReason::InvalidValue));
            }
            if !seen.insert(value) {
                return Err(issue(TemplateIssueReason::Duplicate));
            }
        }
        Ok(())
    }

    /**
     * Ràng buộc control theo direction và type/range/enum, không suy capability từ channel kind.
     * Input
     * Param: index — vị trí field path cho direction/safeValue.
     * Output: READ không capability; writable có đúng một `SET_VALUE` safeValue hợp lệ.
     * Errors: STRING writable, thiếu safeValue hoặc value không tương thích definition.
     */
    fn validate_safe_value(&self, index: usize) -> Result<(), TemplateValidation> {
        if self.data_type == StreamType::String && self.direction != StreamDirection::Read {
            return Err(TemplateValidation {
                stream_index: Some(index),
                field: TemplateField::Direction,
                reason: TemplateIssueReason::Incompatible,
            });
        }
        let issue = |reason| TemplateValidation {
            stream_index: Some(index),
            field: TemplateField::SafeValue,
            reason,
        };
        if self.direction == StreamDirection::Read {
            return if self.safe_value.is_none() {
                Ok(())
            } else {
                Err(issue(TemplateIssueReason::Incompatible))
            };
        }
        let value = self
            .safe_value
            .as_ref()
            .ok_or_else(|| issue(TemplateIssueReason::Required))?;
        let valid = match (self.data_type, value) {
            (StreamType::Number, StreamValue::Number(number)) => self.number_within_bounds(number),
            (StreamType::Boolean, StreamValue::Boolean(_)) => true,
            (StreamType::Enum, value) => self.enum_values.contains(value),
            _ => false,
        };
        if valid {
            Ok(())
        } else {
            Err(issue(TemplateIssueReason::InvalidValue))
        }
    }

    /**
     * Kiểm `safe_value` số theo đúng giá trị thập phân của các biên biểu diễn trên wire.
     *
     * # Input
     * Param: number — literal decimal chính xác của `safe_value`.
     *
     * # Output
     * Trả `true` khi `number` hữu hạn theo `f64` và nằm trong `[minimum, maximum]` theo so sánh thập phân chính xác.
     */
    fn number_within_bounds(&self, number: &DecimalLiteral) -> bool {
        if number.finite_float().is_none() {
            return false;
        }
        // So sánh qua chuỗi thập phân chuẩn hóa của biên wire để chặn giá trị vượt nhẹ bị làm tròn về biên trong `f64`.
        let within_min = self.minimum.is_none_or(|minimum| {
            minimum.is_finite()
                && DecimalLiteral::new(&minimum.to_string())
                    .is_some_and(|bound| number.cmp_numeric(&bound) != std::cmp::Ordering::Less)
        });
        let within_max = self.maximum.is_none_or(|maximum| {
            maximum.is_finite()
                && DecimalLiteral::new(&maximum.to_string())
                    .is_some_and(|bound| number.cmp_numeric(&bound) != std::cmp::Ordering::Greater)
        });
        within_min && within_max
    }
}

/**
 * Kiểm key kỹ thuật theo WF005 để lookup/schema không phụ thuộc Unicode hoặc nhãn hiển thị.
 * Input
 * Param: key — text nguyên bản, không tự trim/lowercase làm đổi identity.
 * Output: true khi khớp ASCII [a-z][a-z0-9_]{0,63}.
 */
fn valid_key(key: &str) -> bool {
    let bytes = key.as_bytes();
    (1..=64).contains(&bytes.len())
        && bytes[0].is_ascii_lowercase()
        && bytes
            .iter()
            .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || *byte == b'_')
}

/// Input aggregate chưa được xác thực, không chứa revision/actor do client tự cấp authority.
#[derive(Clone, Debug)]
pub struct TemplateDraft {
    pub name: String,
    pub model: String,
    pub description: Option<String>,
    pub streams: Vec<StreamDraft>,
}

/// Wrapper immutable sau validation; adapter chỉ nhận aggregate đã kiểm toàn bộ trước persistence.
#[derive(Clone, Debug)]
pub struct ValidatedTemplate(TemplateDraft);

impl TemplateDraft {
    /**
     * Validate metadata và mọi stream trước unit of work, không lưu phần hợp lệ của schema lỗi.
     * Output: aggregate đã kiểm, giữ nguyên text.
     * # Errors
     * Field/index/reason cho boundary mapping khi metadata, key, bounds hoặc capability không hợp lệ.
     * Không đặt quota số stream hoặc bắt draft có stream khi source chưa quy định giới hạn đó.
     */
    pub fn validate(self) -> Result<ValidatedTemplate, TemplateValidation> {
        for (value, field) in [
            (&self.name, TemplateField::Name),
            (&self.model, TemplateField::Model),
        ] {
            if value.trim().is_empty() || value.contains('\0') {
                return Err(TemplateValidation {
                    stream_index: None,
                    field,
                    reason: TemplateIssueReason::InvalidValue,
                });
            }
        }
        if self
            .description
            .as_deref()
            .is_some_and(|text| text.contains('\0'))
        {
            return Err(TemplateValidation {
                stream_index: None,
                field: TemplateField::Description,
                reason: TemplateIssueReason::InvalidValue,
            });
        }
        let mut keys = BTreeSet::new();
        for (index, stream) in self.streams.iter().enumerate() {
            stream.validate(index)?;
            if !keys.insert(&stream.key) {
                return Err(TemplateValidation {
                    stream_index: Some(index),
                    field: TemplateField::Key,
                    reason: TemplateIssueReason::Duplicate,
                });
            }
        }
        Ok(ValidatedTemplate(self))
    }
}

impl ValidatedTemplate {
    /// Đọc immutable definition đã kiểm để adapter bind draft/snapshot, không cho caller mutate nội dung qua wrapper.
    #[must_use]
    pub const fn draft(&self) -> &TemplateDraft {
        &self.0
    }

    /**
     * Kiểm các ràng buộc wire snapshot v1 trước commit publication, không đổi nội dung đã lưu.
     *
     * # Output
     * Schema có thể biểu diễn đúng theo contract v1.
     *
     * # Errors
     * Trả `TemplateValidation` typed khi vượt giới hạn hoặc không tương thích wire v1; không chứa raw value.
     */
    pub fn validate_publication_v1(&self) -> Result<(), TemplateValidation> {
        let draft = self.draft();
        let root_issue = |field, reason| TemplateValidation {
            stream_index: None,
            field,
            reason,
        };
        let stream_issue = |stream_index, field, reason| TemplateValidation {
            stream_index: Some(stream_index),
            field,
            reason,
        };
        if !(1..=100).contains(&draft.name.chars().count()) {
            return Err(root_issue(
                TemplateField::Name,
                TemplateIssueReason::InvalidValue,
            ));
        }
        if !(1..=64).contains(&draft.model.chars().count()) {
            return Err(root_issue(
                TemplateField::Model,
                TemplateIssueReason::InvalidValue,
            ));
        }
        if draft.streams.is_empty() || draft.streams.len() > 64 {
            return Err(root_issue(
                TemplateField::Streams,
                if draft.streams.is_empty() {
                    TemplateIssueReason::Required
                } else {
                    TemplateIssueReason::InvalidValue
                },
            ));
        }
        for (index, stream) in draft.streams.iter().enumerate() {
            if let Some(unit) = stream.unit.as_deref() {
                if stream.data_type != StreamType::Number
                    || !(1..=32).contains(&unit.chars().count())
                {
                    return Err(stream_issue(
                        index,
                        TemplateField::Unit,
                        TemplateIssueReason::Incompatible,
                    ));
                }
            }
            if stream.data_type == StreamType::Number && stream.direction != StreamDirection::Read {
                if stream.minimum.is_none() {
                    return Err(stream_issue(
                        index,
                        TemplateField::Minimum,
                        TemplateIssueReason::Required,
                    ));
                }
                if stream.maximum.is_none() {
                    return Err(stream_issue(
                        index,
                        TemplateField::Maximum,
                        TemplateIssueReason::Required,
                    ));
                }
                if let Some(StreamValue::Number(number)) = &stream.safe_value {
                    if !stream.number_within_bounds(number) {
                        return Err(stream_issue(
                            index,
                            TemplateField::SafeValue,
                            TemplateIssueReason::InvalidValue,
                        ));
                    }
                }
            }
            // Contract v1 giới hạn ENUM từ 1 đến 64 phần tử chuỗi khác rỗng và không quá 64 ký tự.
            if stream.data_type == StreamType::Enum
                && (!(1..=64).contains(&stream.enum_values.len())
                    || stream.enum_values.iter().any(|value| {
                        !matches!(value, StreamValue::Text(text) if (1..=64).contains(&text.chars().count()))
                    }))
            {
                return Err(stream_issue(
                    index,
                    TemplateField::EnumValues,
                    TemplateIssueReason::InvalidValue,
                ));
            }
        }
        Ok(())
    }
}
