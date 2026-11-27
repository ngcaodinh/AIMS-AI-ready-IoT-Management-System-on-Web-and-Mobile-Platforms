/* Giữ default typed của stream draft và snapshot, tách khỏi safeValue và reportedValue.
 * Cột nullable giữ row cũ và INSERT của writer cũ; không backfill hay đổi digest lịch sử.
 * ALTER cần ACCESS EXCLUSIVE khi thêm cột và kiểm CHECK. Áp trước writer đọc/ghi cột mới.
 */
ALTER TABLE public.template_draft_streams ADD COLUMN default_value jsonb
 CONSTRAINT ck_template_draft_default_scalar CHECK(jsonb_typeof(default_value) IN ('number','boolean','string'));
ALTER TABLE public.datastream_definitions ADD COLUMN default_value jsonb
 CONSTRAINT ck_datastream_default_scalar CHECK(jsonb_typeof(default_value) IN ('number','boolean','string'));

COMMENT ON COLUMN public.template_draft_streams.default_value IS 'Default cấu hình typed; không phải safeValue, command hoặc giá trị thiết bị đã báo cáo.';
COMMENT ON COLUMN public.datastream_definitions.default_value IS 'Default typed đóng băng cùng snapshot và digest; NULL khi draft không khai báo.';
