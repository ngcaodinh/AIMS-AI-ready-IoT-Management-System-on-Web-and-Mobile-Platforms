//! Capability realtime sống30giây; binding identity không được suy thành quyền lâu dài.

use crate::identity::SecretString;
use chrono::{DateTime, Utc};
use uuid::Uuid;

/// Bản ghi chỉ có digest; phiên/grant/version được snapshot từ current authorization.
pub struct NewWebSocketTicket {
    pub ticket_id: Uuid,
    pub digest: [u8; 32],
    pub workspace_id: Uuid,
    pub user_id: Uuid,
    pub session_id: Uuid,
    pub grant_generation: i64,
    pub workspace_authorization_version: i64,
    pub membership_authorization_version: i64,
    pub issued_at: DateTime<Utc>,
    pub expires_at: DateTime<Utc>,
}

/// Token được phát sau commit, không xuất hiện trong Debug/log; không phải raw session credential.
pub struct IssuedWebSocketTicket {
    pub token: SecretString,
    pub expires_at: DateTime<Utc>,
}

/// Binding của consume winner; handler phải kiểm current quyền tiếp cho mỗi action/resource.
#[derive(Debug)]
pub struct RealtimeBinding {
    pub workspace_id: Uuid,
    pub user_id: Uuid,
    pub session_id: Uuid,
    pub grant_generation: i64,
    pub workspace_authorization_version: i64,
    pub membership_authorization_version: i64,
}
