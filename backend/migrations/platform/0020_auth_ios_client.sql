/* Giữ enum server WEB/ANDROID/IOS theo OQ-AUTH-007, không triển khai iOS UI.
 * Phải áp sau 0019; ALTER CHECK giữ ACCESS EXCLUSIVE và quét hai bảng trong transaction migration.
 * Runner giới hạn lock_timeout 5 giây và statement_timeout 30 giây; không backfill hoặc sửa hàng session/audit.
 * Nếu cần rollback sau khi đã có IOS, phải revoke/hết hạn và xử lý retention các hàng IOS trước migration thu hẹp.
 */
ALTER TABLE public.sessions DROP CONSTRAINT sessions_client_type_check,
 ADD CONSTRAINT sessions_client_type_check CHECK (client_type IN ('WEB','ANDROID','IOS'));

/* Audit giữ IOS là metadata hữu hạn; UNKNOWN tiếp tục dành cho input không nhận diện được. */
ALTER TABLE public.audit_events DROP CONSTRAINT audit_events_client_type_check,
 ADD CONSTRAINT audit_events_client_type_check CHECK (client_type IN ('WEB','ANDROID','IOS','UNKNOWN'));

COMMENT ON COLUMN public.sessions.client_type IS 'Metadata client WEB/ANDROID/IOS; WEB dùng cookie còn ANDROID/IOS dùng bearer. Không chứng thực platform hoặc cấp quyền; session vẫn có TTL 24 giờ và guard hiện hành.';
COMMENT ON COLUMN public.audit_events.client_type IS 'Metadata client WEB/ANDROID/IOS hoặc UNKNOWN khi không nhận diện được. Nhãn hữu hạn phục vụ audit, không cấp quyền hoặc tiết lộ credential.';

/* History view giữ projection và mô tả cùng audit_events để metadata verification không lệch sau migrate. */
COMMENT ON COLUMN public.audit_history.client_type IS 'Metadata client WEB/ANDROID/IOS hoặc UNKNOWN khi không nhận diện được. Nhãn hữu hạn phục vụ audit, không cấp quyền hoặc tiết lộ credential.';
