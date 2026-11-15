//! Use case và ports; chỉ phụ thuộc domain và kiểu dữ liệu thuần, không có SQLx/Tokio/HTTP.

pub mod audit;
pub mod audit_retention;
pub mod auth_diagnostics;
pub mod auth_read;
pub mod device;
pub mod device_ports;
pub mod error;
pub mod identity;
pub mod invitation;
pub mod invitation_management;
pub mod invitation_ports;
pub mod member_creation;
pub mod member_creation_ports;
pub mod membership;
pub mod outbox;
pub mod password_reset;
pub mod ports;
pub mod preferences;
pub mod realtime;
pub mod session;
pub mod template;
pub mod template_ports;
pub mod workspace;
