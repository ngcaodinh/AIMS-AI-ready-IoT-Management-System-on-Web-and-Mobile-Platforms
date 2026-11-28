//! Snapshot template và canonical encoding có version; không hash hoặc truy cập persistence trong domain.

use crate::template::{ChannelKind, StreamDirection, StreamType, StreamValue, ValidatedTemplate};
use chrono::{DateTime, Utc};
use uuid::Uuid;

/// Trạng thái root draft không thay thế các phiên bản published immutable đã tồn tại.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TemplateStatus {
    Draft,
    Published,
    Archived,
}

impl TemplateStatus {
    /// Trả trạng thái canonical cho persistence và wire, giữ riêng trạng thái snapshot bất biến.
    #[must_use]
    pub const fn code(self) -> &'static str {
        match self {
            Self::Draft => "DRAFT",
            Self::Published => "PUBLISHED",
            Self::Archived => "ARCHIVED",
        }
    }
}

/// Ý định thay draft hoặc publish quyết định state guard; không dùng bool khó phân biệt ở caller.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TemplateMutation {
    ReplaceDraft,
    PatchDraft,
    Publish,
}

/// Lỗi CAS/state/overflow giữ riêng cho transport mapping, không lộ schema hoặc resource ngoài quyền.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TemplateTransitionFailure {
    StaleRevision,
    Immutable,
    RevisionExhausted,
}

/// Root và draft đọc dưới cùng khóa; không chứa quyền có thể reuse sau thay đổi membership.
#[derive(Clone, Debug)]
pub struct TemplateSnapshot {
    pub workspace_id: Uuid,
    pub template_id: Uuid,
    pub revision: i64,
    pub status: TemplateStatus,
    pub latest_published_version_id: Option<Uuid>,
    pub draft: ValidatedTemplate,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

impl TemplateSnapshot {
    /**
     * Kiểm CAS trước state để publish cạnh tranh cùng revision vẫn trả stale sau winner commit.
     * Input
     * Param: expected — revision từ request, không tự refresh khi stale.
     * Param: mutation — replace draft cho root chưa archived, publish chỉ từ DRAFT.
     * Output: revision kế tiếp.
     * # Errors
     * Stale, immutable state hoặc bigint overflow; không tự cấp revision khác để retry.
     */
    pub fn next_revision(
        &self,
        expected: i64,
        mutation: TemplateMutation,
    ) -> Result<i64, TemplateTransitionFailure> {
        if expected != self.revision || expected <= 0 {
            return Err(TemplateTransitionFailure::StaleRevision);
        }
        if self.status == TemplateStatus::Archived
            || (matches!(
                mutation,
                TemplateMutation::PatchDraft | TemplateMutation::Publish
            ) && self.status != TemplateStatus::Draft)
        {
            return Err(TemplateTransitionFailure::Immutable);
        }
        self.revision
            .checked_add(1)
            .ok_or(TemplateTransitionFailure::RevisionExhausted)
    }
}

/// Kết quả publish local sau commit; không thay pin thiết bị hoặc chứng nhận firmware tương thích.
#[derive(Clone, Debug)]
pub struct PublishedTemplate {
    pub workspace_id: Uuid,
    pub template_id: Uuid,
    pub template_version_id: Uuid,
    pub version_number: i32,
    pub template_revision: i64,
    pub published_at: DateTime<Utc>,
    pub content_digest: [u8; 32],
}

/// Immutable content đọc từ version rows; root description/revision hiện hành không thuộc snapshot này.
#[derive(Clone, Debug)]
pub struct TemplateVersionSnapshot {
    pub workspace_id: Uuid,
    pub template_id: Uuid,
    pub template_version_id: Uuid,
    pub version_number: i32,
    pub published_at: DateTime<Utc>,
    pub published_by_user_id: Uuid,
    pub content_digest: [u8; 32],
    pub content: ValidatedTemplate,
}

impl ValidatedTemplate {
    /**
     * Mã hóa content thực lưu trong published version, không gộp description chỉ có ở root metadata.
     * Output: bytes ổn định qua thứ tự stream/ENUM, gồm cả loại kênh/direction/capability; không là wire JSON.
     * Length-prefix tránh ghép chuỗi mơ hồ; số ENUM dùng literal exact, float bounds chuẩn hóa âm0 thành0.
     */
    #[must_use]
    pub fn canonical_bytes(&self) -> Vec<u8> {
        let draft = self.draft();
        // Giữ byte V1 cho snapshot cũ không có default; prefix mới tách encoding có field mới.
        let has_defaults = draft
            .streams
            .iter()
            .any(|stream| stream.default_value.is_some());
        let mut writer = CanonicalWriter(if has_defaults {
            b"TEMPLATE_SNAPSHOT_V2:".to_vec()
        } else {
            b"TEMPLATE_SNAPSHOT_V1:".to_vec()
        });
        writer.field(&draft.name);
        writer.field(&draft.model);
        // Description không được snapshot trong template_versions; không hash dữ liệu chỉ còn ở root mutable.
        let mut streams = draft.streams.iter().collect::<Vec<_>>();
        streams.sort_unstable_by(|left, right| left.key.cmp(&right.key));
        writer.field(&streams.len().to_string());
        for stream in streams {
            writer.field(&stream.key);
            writer.field(&stream.display_name);
            writer.field(match stream.channel_kind {
                ChannelKind::Telemetry => "TELEMETRY",
                ChannelKind::State => "STATE",
            });
            writer.field(match stream.direction {
                StreamDirection::Read => "READ",
                StreamDirection::Write => "WRITE",
                StreamDirection::ReadWrite => "READ_WRITE",
            });
            writer.field(match stream.data_type {
                StreamType::Number => "NUMBER",
                StreamType::Boolean => "BOOLEAN",
                StreamType::String => "STRING",
                StreamType::Enum => "ENUM",
            });
            writer.optional_text(stream.unit.as_deref());
            writer.float(stream.minimum);
            writer.float(stream.maximum);
            writer.optional_text(
                stream
                    .string_max_length
                    .map(|length| length.to_string())
                    .as_deref(),
            );
            let mut values = stream.enum_values.iter().collect::<Vec<_>>();
            values.sort_unstable();
            writer.field(&values.len().to_string());
            for value in values {
                writer.value(value);
            }
            writer.0.push(u8::from(stream.safe_value.is_some()));
            if let Some(value) = &stream.safe_value {
                writer.value(value);
            }
            if has_defaults {
                writer.0.push(u8::from(stream.default_value.is_some()));
                if let Some(value) = &stream.default_value {
                    writer.value(value);
                }
            }
        }
        writer.0
    }
}

/// Encoder chỉ dành nội bộ domain; không cung cấp tùy chọn serialize arbitrary JSON.
struct CanonicalWriter(Vec<u8>);

impl CanonicalWriter {
    /**
     * Ghi một field bằng length-prefix byte để Unicode hoặc dấu phân cách trong text không gây collision cấu trúc.
     * Input
     * Param: text — text nguyên bản đã validate, độ dài tính theo UTF-8 bytes.
     * Side effects: nối length thập phân, dấu hai chấm và bytes vào buffer.
     */
    fn field(&mut self, text: &str) {
        self.0.extend_from_slice(text.len().to_string().as_bytes());
        self.0.push(b':');
        self.0.extend_from_slice(text.as_bytes());
    }

    /// Ghi presence bit trước text optional để None và chuỗi rỗng không cùng representation.
    fn optional_text(&mut self, text: Option<&str>) {
        self.0.push(u8::from(text.is_some()));
        if let Some(text) = text {
            self.field(text);
        }
    }

    /// Ghi float bound hữu hạn bằng IEEE bits big-endian cố định, giữ presence và chuẩn hóa hai dấu zero.
    fn float(&mut self, value: Option<f64>) {
        self.0.push(u8::from(value.is_some()));
        if let Some(value) = value {
            self.0.extend_from_slice(
                &(if value == 0.0 { 0.0 } else { value })
                    .to_bits()
                    .to_be_bytes(),
            );
        }
    }

    /// Ghi tag scalar và representation exact để number1, string"1" và boolean không thể trùng digest cấu trúc.
    fn value(&mut self, value: &StreamValue) {
        match value {
            StreamValue::Number(number) => {
                self.0.push(0);
                self.field(number.json_number());
            }
            StreamValue::Boolean(value) => {
                self.0.push(1);
                self.0.push(u8::from(*value));
            }
            StreamValue::Text(text) => {
                self.0.push(2);
                self.field(text);
            }
        }
    }
}
