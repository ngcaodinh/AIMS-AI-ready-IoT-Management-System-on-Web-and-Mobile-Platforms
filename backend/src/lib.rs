//! Composition boundary của modular monolith; dependency hướng vào application/domain.

pub mod adapters;
pub use iot_application as application;
pub use iot_domain as domain;
pub use iot_postgres as postgres;
