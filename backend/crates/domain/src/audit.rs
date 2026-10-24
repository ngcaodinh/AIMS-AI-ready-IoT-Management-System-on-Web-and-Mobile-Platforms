//! Projection audit cho Admin tenant; không chứa credential, raw payload hoặc diff tùy ý.

use chrono::{DateTime, Utc};
use uuid::Uuid;

/// Cursor nội bộ keyset; transport phải ký/bind cursor trước khi nhận lại từ client.
pub struct AuditCursor {
    pub created_at: DateTime<Utc>,
    pub audit_event_id: Uuid,
}

/// Projection allowlist; `workspace_id` bắt buộc vì đây không phải endpoint global authentication audit.
pub struct AuditEntry {
    pub audit_event_id: Uuid,
    pub workspace_id: Uuid,
    pub actor_user_id: Option<Uuid>,
    pub event_type: String,
    pub outcome: String,
    pub occurred_at: DateTime<Utc>,
    pub created_at: DateTime<Utc>,
    pub resource_type: Option<String>,
    pub resource_id: Option<String>,
}
