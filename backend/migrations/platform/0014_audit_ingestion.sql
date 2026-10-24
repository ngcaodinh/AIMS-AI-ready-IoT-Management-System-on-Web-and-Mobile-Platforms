/* Tách thời điểm audit được server lưu khỏi thời điểm sự kiện xảy ra theo FEAT-TN-040 §8.4.
 * Chỉ baseline audit trống: legacy row không có ingestion provenance phải có backfill được review riêng.
 * ACCESS EXCLUSIVE giữ từ preflight tới DDL để không có INSERT chen giữa kiểm trống và thêm cột.
 * Index thường phù hợp baseline trống này; không áp trực tiếp lên audit production đang có dữ liệu.
 * Không sửa byte/checksum0001…0013, không xóa audit hoặc gán occurred_at làm ingestion giả.
 */
LOCK TABLE public.audit_events IN ACCESS EXCLUSIVE MODE;
DO $$ BEGIN
 IF EXISTS(SELECT 1 FROM public.audit_events) THEN
  RAISE EXCEPTION 'Audit ingestion migration requires reviewed legacy backfill'
   USING ERRCODE='23514',CONSTRAINT='ck_audit_ingestion_backfill_required';
 END IF;
END $$;

-- Thời điểm server ghi audit, dùng phân trang/retention; không nhận timestamp này từ client hoặc event source.
-- timestamptz lưu thời điểm tuyệt đối; NOT NULL bắt buộc có; DEFAULT lấy thời điểm bắt đầu câu INSERT hiện hành.
-- Native immutable trigger đã có tiếp tục cấm thay cột này sau INSERT.
ALTER TABLE public.audit_events ADD COLUMN created_at timestamptz NOT NULL DEFAULT statement_timestamp();

-- Tenant đứng đầu cho scope; tuple thời gian/UUID giảm dần khớp thứ tự cursor cố định của audit query.
CREATE INDEX ix_audit_workspace_created ON public.audit_events(workspace_id,created_at DESC,audit_event_id DESC);
-- Cutoff trước UUID phục vụ batch purge toàn cục ổn định; không dùng event-time để kéo dài retention.
CREATE INDEX ix_audit_created_retention ON public.audit_events(created_at,audit_event_id);

/* Thêm cột view ở cuối giữ interface cũ; timestamp đúng cutoff vẫn được giữ theo retention30 ngày. */
CREATE OR REPLACE VIEW public.audit_history WITH(security_invoker=true) AS
 SELECT * FROM public.audit_events WHERE created_at>=statement_timestamp()-interval '30 days';

/* Writer chỉ append những cột đã review; không có INSERT table-wide hoặc quyền override created_at.
 * Grant này không cấp SELECT global audit, UPDATE/DELETE hoặc quyền retention cho runtime.
 */
REVOKE INSERT ON public.audit_events FROM iot_runtime;
GRANT INSERT(audit_event_id,workspace_id,actor_user_id,session_id,event_type,outcome,resource_type,resource_id,
 correlation_id,occurred_at,reason_code,redacted_diff,client_type) ON public.audit_events TO iot_runtime;

-- Comment native khớp dictionary để DBeaver/snapshot giải thích đúng ý nghĩa cột và server default.
COMMENT ON COLUMN public.audit_events.created_at IS 'Thời điểm server ghi audit bằng statement_timestamp(); dùng phân trang và retention30 ngày, độc lập occurred_at của sự kiện. Runtime chỉ có column INSERT allowlist không gồm cột này; immutable sau INSERT.';
COMMENT ON COLUMN public.audit_history.created_at IS 'Thời điểm server ghi audit bằng statement_timestamp(); dùng phân trang và retention30 ngày, độc lập occurred_at của sự kiện. Runtime chỉ có column INSERT allowlist không gồm cột này; immutable sau INSERT.';
