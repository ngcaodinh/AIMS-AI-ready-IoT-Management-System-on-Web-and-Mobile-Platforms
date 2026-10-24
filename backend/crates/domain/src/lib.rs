//! Mô hình và policy thuần: không I/O, SQL, executor, HTTP hoặc implementation crypto.

pub mod audit;
pub mod audit_retention;
pub mod audit_write;
pub mod device;
pub mod idempotency;
pub mod identity;
pub mod input;
pub mod invitation;
pub mod invitation_management;
pub mod member_creation;
pub mod membership;
pub mod outbox;
pub mod password_reset;
pub mod preferences;
pub mod realtime;
pub mod template;
pub mod template_snapshot;
pub mod template_value;
pub mod workspace;
