/* Đồng bộ registry với WF007/OQ-DEVICE-002: chưa có authenticated hello thì hardware chưa biết.
 * ALTER TABLE/DROP TRIGGER giữ khóa metadata trong transaction migration ngắn; không backfill hoặc xóa dữ liệu.
 * Giữ nguyên serial/workspace/owner/model/pin bất biến; hardware là observation do DB-10 xác thực, không input HTTP.
 * Các giá trị hardware hiện có được bảo toàn; không sửa checksum migration đã áp.
 */
ALTER TABLE public.devices ALTER COLUMN hardware_revision DROP NOT NULL;

/* Chỉ bỏ observation khỏi identity guard; không mở chuyển tenant, owner hoặc template đã pin. */
DROP TRIGGER tr_device_pin_identity ON public.devices;
CREATE TRIGGER tr_device_pin_identity BEFORE UPDATE ON public.devices
 FOR EACH ROW EXECUTE FUNCTION public.enforce_identity_columns('workspace_id','template_version_id','owner_user_id','serial_number','model');

COMMENT ON COLUMN public.devices.hardware_revision IS 'Revision phần cứng từ authenticated hello/status; NULL khi registry chưa có observation, không lấy từ input đăng ký. Dùng kiểm tương thích firmware, không thuộc identity cloud bất biến.';
