/* Lịch sử runner lab: lưu checksum và thời điểm áp thật, không chứa credential.
 * Phải chạy trong transaction đã lấy advisory lock; không thay SQLx production history.
 */
CREATE SCHEMA IF NOT EXISTS migration_control;
CREATE TABLE IF NOT EXISTS migration_control.applied_migrations (
    version text PRIMARY KEY,
    checksum text NOT NULL CHECK(checksum ~ '^[0-9a-f]{64}$'),
    applied_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
