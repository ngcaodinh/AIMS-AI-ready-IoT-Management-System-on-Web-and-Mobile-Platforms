//! Pool thuộc adapter; không đọc `.env`, không bật SQL statement logging chứa secret.

use crate::storage_error;
use iot_application::error::ApplicationError;
use sqlx::{
    ConnectOptions, PgPool,
    postgres::{PgConnectOptions, PgPoolOptions, PgSslMode},
};
use std::time::Duration;

/**
 * Mở pool tới gateway probe tạm do launcher sở hữu, không dùng reader hoặc owner để chạy use case.
 * Input
 * Param: port — cổng ngẫu nhiên chỉ bind127.0.0.1 của launcher đang kiểm thử.
 * Param: username — bắt buộc role SCRAM probe, không chấp nhận schema owner.
 * Param: password — credential tạm nhận qua stdin launcher; không URL/argv/env/file/log.
 * Output: pool tối đa8 connection, pool wait5giây; gateway ép statement30s/lock5s/idle-tx15s.
 * Launcher phải cấp environment rỗng cho probe vì constructor `SQLx` vẫn xét các biến PG mặc định;
 * không đọc giá trị env để kiểm tra hoặc tự tìm credential.
 * Errors: invalid input hoặc unavailable đã lọc; transport này không là cấu hình TLS production.
 * # Errors
 * Trả lỗi từ chối hoặc lỗi đã mô tả ở trên; không chứa dữ liệu nhạy cảm.
 */
pub async fn connect_local_probe(
    port: u16,
    username: &str,
    password: &str,
) -> Result<PgPool, ApplicationError> {
    connect_probe(port, username, password, false).await
}

/**
 * Mở pool worker riêng với role NOLOGIN tạm, không thừa kế quyền app/fixture khi purge audit.
 * Input
 * Param: port — gateway loopback do launcher sở hữu.
 * Param: username — chỉ login probe đã được grant SET, INHERIT FALSE tới worker role.
 * Param: password — credential tạm qua stdin, không env/file/URL/log.
 * Output: pool worker tối đa4 connections; mỗi connection SET ROLE cố định ngay khi mở.
 * # Errors
 * `InvalidInput` hoặc Unavailable nếu role/gateway không đúng; không fallback sang app hoặc owner.
 */
pub async fn connect_local_retention_probe(
    port: u16,
    username: &str,
    password: &str,
) -> Result<PgPool, ApplicationError> {
    connect_probe(port, username, password, true).await
}

/**
 * Dựng pool đã phân biệt app/worker, giữ secret ngoài log và không đọc file cấu hình.
 * Input
 * Param: port — cổng gateway loopback.
 * Param: username — role login probe allowlist.
 * Param: password — password tổng hợp chỉ dùng xác thực SCRAM.
 * Param: retention — lựa chọn nội bộ của wrapper, không input từ HTTP.
 * Output: pool với role/current quyền cố định; Errors: lỗi đã lọc, không tự nâng quyền khác.
 */
async fn connect_probe(
    port: u16,
    username: &str,
    password: &str,
    retention: bool,
) -> Result<PgPool, ApplicationError> {
    if username != "iot_repository_probe" || password.is_empty() {
        return Err(ApplicationError::InvalidInput);
    }
    let options = PgConnectOptions::new_without_pgpass()
        .host("127.0.0.1")
        .port(port)
        .username(username)
        .password(password)
        .database("iot_platform_lab")
        .ssl_mode(PgSslMode::Disable)
        .application_name("iot-repository-verification")
        .disable_statement_logging();
    PgPoolOptions::new()
        // Hai worker pool4 + pool fixture8 không vượt login connection budget16 của launcher.
        .max_connections(if retention { 4 } else { 8 })
        .acquire_timeout(Duration::from_secs(5))
        .after_connect(move |connection, _metadata| {
            Box::pin(async move {
                if retention {
                    // Role literal nội bộ, không chèn identifier từ config; không reset connection này thành app role.
                    sqlx::query("SET ROLE iot_audit_retention_probe")
                        .execute(connection)
                        .await?;
                }
                Ok(())
            })
        })
        .connect_with(options)
        .await
        .map_err(storage_error)
}
