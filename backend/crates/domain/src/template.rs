//! Schema template thuần: loại kênh, direction, datatype và capability là các ràng buộc riêng.

use crate::template_value::DecimalLiteral;
use std::collections::BTreeSet;
use unicode_normalization::UnicodeNormalization;

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
    pub default_value: Option<StreamValue>,
    pub safe_value: Option<StreamValue>,
}

/// Trường lỗi typed cho wire adapter dựng field path mà không trả lại raw value hoặc SQL detail.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TemplateField {
    Name,
    Model,
    Description,
    Key,
    DisplayName,
    Unit,
    Minimum,
    Maximum,
    StringMaxLength,
    EnumValues,
    Direction,
    DefaultValue,
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

/// Chuẩn hóa display name NFC/trim theo OQ-TEMPLATE-001 và kiểm 1–100 Unicode code points.
pub fn normalize_template_name(input: &str) -> Result<String, TemplateValidation> {
    let name: String = input.trim().nfc().collect();
    if !(1..=100).contains(&name.chars().count()) || name.contains('\0') {
        return Err(TemplateValidation {
            stream_index: None,
            field: TemplateField::Name,
            reason: TemplateIssueReason::InvalidValue,
        });
    }
    Ok(name)
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
        if self
            .default_value
            .as_ref()
            .is_some_and(|value| !self.accepts_value(value))
        {
            return Err(issue(
                TemplateField::DefaultValue,
                TemplateIssueReason::InvalidValue,
            ));
        }
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
        if self.accepts_value(value) {
            Ok(())
        } else {
            Err(issue(TemplateIssueReason::InvalidValue))
        }
    }

    /// Kiểm scalar theo datatype, bound và tập ENUM; giữ decimal identity khi so thành viên.
    fn accepts_value(&self, value: &StreamValue) -> bool {
        match (self.data_type, value) {
            (StreamType::Number, StreamValue::Number(number)) => {
                number.finite_float().is_some_and(|number| {
                    self.minimum.is_none_or(|minimum| number >= minimum)
                        && self.maximum.is_none_or(|maximum| number <= maximum)
                })
            }
            (StreamType::Boolean, StreamValue::Boolean(_)) => true,
            (StreamType::String, StreamValue::Text(text)) => {
                let limit = self.string_max_length.unwrap_or(256).min(256);
                !text.contains('\0') && text.chars().count() <= limit as usize
            }
            (StreamType::Enum, value) => self.enum_values.contains(value),
            _ => false,
        }
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
}
