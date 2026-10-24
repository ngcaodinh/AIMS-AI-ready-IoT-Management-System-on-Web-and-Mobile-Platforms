/* Marker tổng hợp duy nhất được giữ để xác nhận restore có dữ liệu, không chứa account/key.
 * Idempotent trên lab; operational metadata này không thuộc schema nghiệp vụ.
 */
CREATE TABLE IF NOT EXISTS migration_control.restore_probe (
    probe_id integer PRIMARY KEY,
    note text NOT NULL
);
INSERT INTO migration_control.restore_probe VALUES(1,'synthetic restore marker')
ON CONFLICT DO NOTHING;
