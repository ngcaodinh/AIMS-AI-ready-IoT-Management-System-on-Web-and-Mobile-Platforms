/* Tách loại kênh TELEMETRY/STATE khỏi direction READ/WRITE/READ_WRITE theo ADR-004.
 * ALTER TABLE giữ ACCESS EXCLUSIVE trên hai relation stream trong transaction migration ngắn.
 * Không backfill/suy loại kênh từ direction; baseline có stream phải dừng để adoption được review riêng.
 * Published snapshot cũ không được rewrite, migration đã áp giữ nguyên checksum.
 */
LOCK TABLE public.template_draft_streams,public.datastream_definitions IN ACCESS EXCLUSIVE MODE;
DO $$ BEGIN
 IF EXISTS(SELECT 1 FROM public.template_draft_streams) OR EXISTS(SELECT 1 FROM public.datastream_definitions) THEN
  RAISE EXCEPTION 'Channel kind requires reviewed adoption for existing streams'
   USING ERRCODE='23514',CONSTRAINT='ck_channel_kind_adoption_required';
 END IF;
END $$;

-- Loại dữ liệu nghiệp vụ của từng stream draft: TELEMETRY là số liệu quan sát, STATE là trạng thái.
-- text NOT NULL: bắt buộc caller chọn loại; CHECK giới hạn đúng hai giá trị; không DEFAULT để tránh tự đoán.
-- Thuộc tính này không cấp quyền hoặc tự tạo capability điều khiển, direction vẫn được lưu độc lập.
ALTER TABLE public.template_draft_streams ADD COLUMN channel_kind text NOT NULL
 CONSTRAINT ck_draft_stream_channel_kind CHECK(channel_kind IN ('TELEMETRY','STATE'));

-- Loại kênh được đóng trong definition published để thiết bị tiếp tục dùng đúng schema đã pin.
-- text NOT NULL, CHECK hai giá trị, không DEFAULT; native immutable trigger cấm đổi snapshot sau publish.
-- Publish service phải sao chép từ draft và đưa thuộc tính vào content digest, không suy lại theo runtime.
ALTER TABLE public.datastream_definitions ADD COLUMN channel_kind text NOT NULL
 CONSTRAINT ck_datastream_channel_kind CHECK(channel_kind IN ('TELEMETRY','STATE'));

COMMENT ON COLUMN public.template_draft_streams.channel_kind IS 'Loại kênh TELEMETRY cho số liệu quan sát hoặc STATE cho trạng thái; bắt buộc khai báo tường minh, độc lập với direction và không tự cấp capability hay quyền điều khiển.';
COMMENT ON COLUMN public.datastream_definitions.channel_kind IS 'Loại kênh TELEMETRY cho số liệu quan sát hoặc STATE cho trạng thái; bắt buộc khai báo tường minh, độc lập với direction và không tự cấp capability hay quyền điều khiển.';
