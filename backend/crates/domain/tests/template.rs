//! Validator template thuần: cả loại kênh và direction, type/range/capability được kiểm trước persistence.

use iot_domain::{
    template::{
        ChannelKind, StreamDirection, StreamDraft, StreamType, StreamValue, TemplateDraft,
        TemplateField,
    },
    template_value::DecimalLiteral,
};

/// Fixture số đo hợp lệ để từng test chỉ thay invariant cần kiểm, không dựa DB hoặc framework JSON.
fn temperature() -> StreamDraft {
    StreamDraft {
        key: "temperature".into(),
        display_name: "Temperature".into(),
        channel_kind: ChannelKind::Telemetry,
        data_type: StreamType::Number,
        direction: StreamDirection::Read,
        unit: Some("C".into()),
        minimum: Some(-20.0),
        maximum: Some(100.0),
        string_max_length: None,
        enum_values: vec![],
        safe_value: None,
    }
}

/// Fixture template giữ text nguyên bản và cho validate schema stream có cấu trúc.
fn draft(streams: Vec<StreamDraft>) -> TemplateDraft {
    TemplateDraft {
        name: "Room".into(),
        model: "ESP32".into(),
        description: None,
        streams,
    }
}

/// Giá trị số dùng token decimal exact, không cast integer lớn qua float ở fixture ENUM.
fn number(text: &str) -> StreamValue {
    StreamValue::Number(DecimalLiteral::new(text).unwrap())
}

/// Duplicate/key sai/range vô hạn phải bị reject toàn schema với field path nội bộ cụ thể.
#[test]
fn schema_validates_key_uniqueness_pattern_and_finite_bounds() {
    assert!(draft(vec![temperature()]).validate().is_ok());
    assert_eq!(
        draft(vec![temperature(), temperature()])
            .validate()
            .unwrap_err()
            .field,
        TemplateField::Key
    );
    for key in ["", "Temperature", "1temperature", "a-b", "nhiệt", "a b"] {
        let mut stream = temperature();
        stream.key = key.into();
        assert_eq!(
            draft(vec![stream]).validate().unwrap_err().field,
            TemplateField::Key
        );
    }
    let mut stream = temperature();
    stream.key = "a".repeat(64);
    assert!(draft(vec![stream.clone()]).validate().is_ok());
    stream.key.push('a');
    assert!(draft(vec![stream]).validate().is_err());
    for bound in [f64::NAN, f64::INFINITY, f64::NEG_INFINITY] {
        let mut stream = temperature();
        stream.minimum = Some(bound);
        assert_eq!(
            draft(vec![stream]).validate().unwrap_err().field,
            TemplateField::Minimum
        );
    }
    let mut stream = temperature();
    stream.minimum = Some(101.0);
    assert_eq!(
        draft(vec![stream]).validate().unwrap_err().field,
        TemplateField::Maximum
    );
}

/// Publish v1 sí loại nội dung ngoài wire shape mà không suy ra default hay model được duyệt.
#[test]
fn publication_v1_rejects_content_outside_wire_shape() {
    let ready = draft(vec![temperature()]).validate().unwrap();
    assert!(ready.validate_publication_v1().is_ok());

    let empty = draft(vec![]).validate().unwrap();
    assert_eq!(
        empty.validate_publication_v1().unwrap_err().field,
        TemplateField::Streams
    );

    let mut writable_number = temperature();
    writable_number.direction = StreamDirection::Write;
    writable_number.safe_value = Some(number("1"));
    writable_number.minimum = None;
    writable_number.maximum = None;
    let missing_bounds = draft(vec![writable_number]).validate().unwrap();
    assert_eq!(
        missing_bounds.validate_publication_v1().unwrap_err().field,
        TemplateField::Minimum
    );

    let numeric_enum = StreamDraft {
        key: "state".into(),
        display_name: "State".into(),
        channel_kind: ChannelKind::State,
        data_type: StreamType::Enum,
        direction: StreamDirection::Read,
        unit: None,
        minimum: None,
        maximum: None,
        string_max_length: None,
        enum_values: vec![number("1")],
        safe_value: None,
    };
    let numeric_enum = draft(vec![numeric_enum]).validate().unwrap();
    assert_eq!(
        numeric_enum.validate_publication_v1().unwrap_err().field,
        TemplateField::EnumValues
    );
}

/// ENUM publish v1 chấp nhận tối đa 64 giá trị chuỗi duy nhất và từ chối phần tử thứ 65 trước commit.
#[test]
fn publication_v1_enforces_enum_value_count_limit() {
    let make_enum = |count: usize| {
        let values = (0..count)
            .map(|index| StreamValue::Text(format!("state_{index}")))
            .collect();
        StreamDraft {
            key: "operating_state".into(),
            display_name: "Operating State".into(),
            channel_kind: ChannelKind::State,
            data_type: StreamType::Enum,
            direction: StreamDirection::ReadWrite,
            unit: None,
            minimum: None,
            maximum: None,
            string_max_length: None,
            enum_values: values,
            safe_value: Some(StreamValue::Text("state_0".into())),
        }
    };

    let at_limit = draft(vec![make_enum(64)]).validate().unwrap();
    assert!(at_limit.validate_publication_v1().is_ok());

    let over_limit = draft(vec![make_enum(65)]).validate().unwrap();
    let error = over_limit.validate_publication_v1().unwrap_err();
    assert_eq!(error.stream_index, Some(0));
    assert_eq!(error.field, TemplateField::EnumValues);
}

/// Giá trị số `safeValue` vượt nhẹ ngoài biên trên wire dù tròn bằng biên trong `f64` vẫn phải bị từ chối.
#[test]
fn numeric_safe_value_bounds_reject_sub_ulp_overflow_without_float_rounding() {
    let mut stream = temperature();
    stream.direction = StreamDirection::Write;
    stream.minimum = Some(-1.0);
    stream.maximum = Some(1.0);
    stream.safe_value = Some(number("1.0000000000000001"));
    let over_max = draft(vec![stream.clone()]).validate().unwrap_err();
    assert_eq!(over_max.stream_index, Some(0));
    assert_eq!(over_max.field, TemplateField::SafeValue);

    stream.safe_value = Some(number("-1.0000000000000001"));
    let under_min = draft(vec![stream.clone()]).validate().unwrap_err();
    assert_eq!(under_min.stream_index, Some(0));
    assert_eq!(under_min.field, TemplateField::SafeValue);

    stream.minimum = Some(0.1);
    stream.maximum = Some(0.1);
    stream.safe_value = Some(number("0.100000000000000005"));
    let over_decimal_max = draft(vec![stream.clone()]).validate().unwrap_err();
    assert_eq!(over_decimal_max.field, TemplateField::SafeValue);

    stream.safe_value = Some(number("0.1"));
    let exact_match = draft(vec![stream]).validate().unwrap();
    assert!(exact_match.validate_publication_v1().is_ok());
}

/// Channel kind không cấp capability; writable cần safeValue đúng type/range, READ không có `SET_VALUE`.
#[test]
fn direction_and_safe_value_are_independent_from_channel_kind() {
    let mut stream = temperature();
    stream.channel_kind = ChannelKind::State;
    assert!(draft(vec![stream.clone()]).validate().is_ok());
    stream.safe_value = Some(number("0"));
    assert_eq!(
        draft(vec![stream.clone()]).validate().unwrap_err().field,
        TemplateField::SafeValue
    );
    stream.direction = StreamDirection::ReadWrite;
    assert!(draft(vec![stream.clone()]).validate().is_ok());
    stream.safe_value = None;
    assert!(draft(vec![stream.clone()]).validate().is_err());
    stream.safe_value = Some(number("101"));
    assert!(draft(vec![stream.clone()]).validate().is_err());
    stream.safe_value = Some(StreamValue::Boolean(false));
    assert!(draft(vec![stream.clone()]).validate().is_err());
    stream.data_type = StreamType::Boolean;
    stream.minimum = None;
    stream.maximum = None;
    assert!(draft(vec![stream]).validate().is_ok());
}

/// ENUM dùng equality decimal exact; STRING chỉ hiển thị và không nhận constraints của kiểu khác.
#[test]
fn enum_preserves_numeric_identity_and_string_is_display_only() {
    let mut stream = temperature();
    stream.data_type = StreamType::Enum;
    stream.minimum = None;
    stream.maximum = None;
    stream.enum_values = vec![number("1"), number("1.0")];
    assert_eq!(
        draft(vec![stream.clone()]).validate().unwrap_err().field,
        TemplateField::EnumValues
    );
    stream.enum_values = vec![
        number("9007199254740992"),
        number("9007199254740993"),
        StreamValue::Text("1".into()),
    ];
    stream.direction = StreamDirection::Write;
    stream.safe_value = Some(number("9007199254740993"));
    assert!(draft(vec![stream.clone()]).validate().is_ok());
    stream.safe_value = Some(number("1"));
    assert!(draft(vec![stream.clone()]).validate().is_err());
    stream.enum_values = vec![StreamValue::Boolean(false)];
    stream.safe_value = Some(StreamValue::Boolean(false));
    assert!(draft(vec![stream.clone()]).validate().is_err());
    stream.data_type = StreamType::String;
    stream.enum_values.clear();
    stream.safe_value = None;
    stream.string_max_length = Some(10);
    assert_eq!(
        draft(vec![stream.clone()]).validate().unwrap_err().field,
        TemplateField::Direction
    );
    stream.direction = StreamDirection::Read;
    assert!(draft(vec![stream.clone()]).validate().is_ok());
    stream.string_max_length = Some(0);
    assert!(draft(vec![stream]).validate().is_err());
}

/// Boundary không lưu NUL của PostgreSQL và không tự trim text người dùng vào một schema khác.
#[test]
fn metadata_validation_preserves_text_and_rejects_null_character() {
    let mut input = draft(vec![temperature()]);
    input.name = "  Room  ".into();
    let valid = input.validate().unwrap();
    assert_eq!(valid.draft().name, "  Room  ");
    let mut input = draft(vec![]);
    input.model = " ".into();
    assert_eq!(input.validate().unwrap_err().field, TemplateField::Model);
    let mut stream = temperature();
    stream.unit = Some("C\0".into());
    assert_eq!(
        draft(vec![stream]).validate().unwrap_err().field,
        TemplateField::Unit
    );
}

/// Digest snapshot không phụ thuộc thứ tự stream/ENUM nhưng luôn đổi khi một trong hai thuộc tính kênh đổi.
#[test]
fn canonical_snapshot_sorts_sets_and_preserves_both_channel_properties() {
    let first = temperature();
    let mut second = temperature();
    second.key = "humidity".into();
    let left = draft(vec![first.clone(), second.clone()])
        .validate()
        .unwrap();
    let right = draft(vec![second, first]).validate().unwrap();
    assert_eq!(left.canonical_bytes(), right.canonical_bytes());
    let mut altered = left.draft().clone();
    altered.streams[0].channel_kind = ChannelKind::State;
    assert_ne!(
        left.canonical_bytes(),
        altered.validate().unwrap().canonical_bytes()
    );
    let mut writable = temperature();
    writable.direction = StreamDirection::Write;
    writable.safe_value = Some(number("0"));
    let write = draft(vec![writable.clone()]).validate().unwrap();
    writable.direction = StreamDirection::ReadWrite;
    assert_ne!(
        write.canonical_bytes(),
        draft(vec![writable]).validate().unwrap().canonical_bytes()
    );
}

/// Canonical ENUM không phụ thuộc thứ tự editor và chuẩn hóa decimal; optional text vẫn phân biệt None/empty.
#[test]
fn canonical_enum_equality_and_optional_text_are_unambiguous() {
    let mut stream = temperature();
    stream.data_type = StreamType::Enum;
    stream.minimum = None;
    stream.maximum = None;
    stream.enum_values = vec![number("1.0"), StreamValue::Text("one".into())];
    stream.unit = None;
    let left = draft(vec![stream.clone()]).validate().unwrap();
    stream.enum_values = vec![StreamValue::Text("one".into()), number("10e-1")];
    assert_eq!(
        left.canonical_bytes(),
        draft(vec![stream]).validate().unwrap().canonical_bytes()
    );
    let mut right = left.draft().clone();
    right.streams[0].unit = Some(String::new());
    assert_ne!(
        left.canonical_bytes(),
        right.validate().unwrap().canonical_bytes()
    );
    let mut metadata_only = left.draft().clone();
    metadata_only.description = Some("Root metadata only".into());
    assert_eq!(
        left.canonical_bytes(),
        metadata_only.validate().unwrap().canonical_bytes()
    );
}

/// Publish chỉ từ DRAFT, CAS phải báo stale trước state check, archived và bigint overflow không được mutate.
#[test]
fn template_transitions_preserve_revision_and_publication_state() {
    use iot_domain::template_snapshot::{
        TemplateMutation, TemplateSnapshot, TemplateStatus, TemplateTransitionFailure,
    };
    let now = chrono::DateTime::from_timestamp(1_700_000_000, 0).unwrap();
    let mut snapshot = TemplateSnapshot {
        workspace_id: uuid::Uuid::new_v4(),
        template_id: uuid::Uuid::new_v4(),
        revision: 1,
        status: TemplateStatus::Draft,
        draft: draft(vec![temperature()]).validate().unwrap(),
        created_at: now,
        updated_at: now,
    };
    assert_eq!(snapshot.next_revision(1, TemplateMutation::Publish), Ok(2));
    snapshot.revision = 2;
    snapshot.status = TemplateStatus::Published;
    assert_eq!(
        snapshot.next_revision(1, TemplateMutation::Publish),
        Err(TemplateTransitionFailure::StaleRevision)
    );
    assert_eq!(
        snapshot.next_revision(2, TemplateMutation::Publish),
        Err(TemplateTransitionFailure::Immutable)
    );
    assert_eq!(
        snapshot.next_revision(2, TemplateMutation::ReplaceDraft),
        Ok(3)
    );
    snapshot.status = TemplateStatus::Archived;
    assert_eq!(
        snapshot.next_revision(2, TemplateMutation::ReplaceDraft),
        Err(TemplateTransitionFailure::Immutable)
    );
    snapshot.status = TemplateStatus::Draft;
    snapshot.revision = i64::MAX;
    assert_eq!(
        snapshot.next_revision(i64::MAX, TemplateMutation::Publish),
        Err(TemplateTransitionFailure::RevisionExhausted)
    );
}
