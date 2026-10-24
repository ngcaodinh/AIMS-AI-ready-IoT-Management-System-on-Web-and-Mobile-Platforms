/* Lưu run/cutoff và kết quả từng audit-retention batch theo FEAT-TN-040 §8.4.
 * Hai quan hệ BCNF theo grain khai báo: run_id→cutoff; batch_id→run_id/limit/count/completed_at.
 * DDL thêm bảng nhỏ, không backfill/xóa audit và không cấp DELETE cho runtime request.
 * Trigger immutable/truncate tái dùng guard đã áp; chỉ worker có role riêng mới được purge qua adapter.
 */

-- Bảng audit_retention_runs: mỗi run giữ một cutoff đã đóng để restart không làm trôi cửa sổ retention.
CREATE TABLE audit_retention_runs (
    -- UUID của run do coordinator cấp, khóa chính không NULL/không trùng; không chấp nhận UUID nil.
    run_id uuid PRIMARY KEY CHECK(run_id<>'00000000-0000-0000-0000-000000000000'::uuid),
    -- Cutoff UTC server tính lúc start;720 giờ là30 ngày tuyệt đối, không lệch theo DST/TimeZone.
    -- NOT NULL bắt buộc có; CHECK không cho run xóa dữ liệu chưa đủ30 ngày tại thời điểm admission.
    cutoff timestamptz NOT NULL DEFAULT (statement_timestamp()-interval '720 hours'),
    CONSTRAINT ck_audit_retention_cutoff CHECK(cutoff<=statement_timestamp()-interval '720 hours')
);

-- Bảng audit_retention_batches: một result đã commit cho một batch; replay không DELETE thêm audit.
CREATE TABLE audit_retention_batches (
    -- UUID intent của batch, khóa chính chống xử lý lặp; không tự sinh và không chấp nhận UUID nil.
    batch_id uuid PRIMARY KEY CHECK(batch_id<>'00000000-0000-0000-0000-000000000000'::uuid),
    -- Run sở hữu batch; FK giữ cutoff snapshot chung, không cascade xóa kết quả khi run còn được tham chiếu.
    run_id uuid NOT NULL REFERENCES audit_retention_runs,
    -- Cận row tối đa của một transaction; NOT NULL/CHECK1…1000 ngăn batch vô hạn giữ lock lâu.
    batch_limit integer NOT NULL CONSTRAINT ck_audit_retention_batch_limit CHECK(batch_limit BETWEEN 1 AND 1000),
    -- Số audit đã xóa cùng commit result;0 hợp lệ khi chưa có row unlocked, không khẳng định run đã drain.
    removed_count integer NOT NULL CONSTRAINT ck_audit_retention_batch_count CHECK(removed_count BETWEEN 0 AND batch_limit),
    -- Thời điểm server lưu result; chỉ row result hoàn tất mới được INSERT, không có placeholder nửa chừng.
    completed_at timestamptz NOT NULL DEFAULT statement_timestamp()
);

-- FK/run đứng đầu phục vụ kiểm reference, tổng hợp tiến độ và cleanup batch trước run; không index payload.
CREATE INDEX ix_audit_retention_batches_run ON audit_retention_batches(run_id,batch_id);
-- Không rewrite run cutoff hoặc result sau commit, tránh replay trả số liệu khác lần xử lý gốc.
CREATE TRIGGER tr_audit_retention_runs_immutable BEFORE UPDATE ON audit_retention_runs FOR EACH ROW EXECUTE FUNCTION reject_immutable_update();
CREATE TRIGGER tr_audit_retention_batches_immutable BEFORE UPDATE ON audit_retention_batches FOR EACH ROW EXECUTE FUNCTION reject_immutable_update();
-- Tránh TRUNCATE bỏ qua FK/result evidence; retention metadata có cleanup DELETE riêng khi policy được chốt.
CREATE TRIGGER tr_audit_retention_runs_truncate BEFORE TRUNCATE ON audit_retention_runs FOR EACH STATEMENT EXECUTE FUNCTION reject_protected_truncate();
CREATE TRIGGER tr_audit_retention_batches_truncate BEFORE TRUNCATE ON audit_retention_batches FOR EACH STATEMENT EXECUTE FUNCTION reject_protected_truncate();
REVOKE ALL ON audit_retention_runs,audit_retention_batches FROM PUBLIC,iot_runtime;

/* PostgreSQL interval theo ngày có thể lệch DST với timestamptz;720 giờ giữ đúng duration UTC của policy. */
CREATE OR REPLACE VIEW public.audit_history WITH(security_invoker=true) AS
 SELECT * FROM public.audit_events WHERE created_at>=statement_timestamp()-interval '720 hours';

COMMENT ON TABLE public.audit_retention_runs IS 'Run nội bộ của audit retention; mỗi run giữ cutoff UTC đã đóng để restart/retry không làm thay đổi phạm vi xóa. Không chứa audit payload hoặc quyền của user request.';
COMMENT ON COLUMN public.audit_retention_runs.run_id IS 'Identity UUID không nil của một run retention do coordinator cấp; primary key không NULL và không trùng, dùng giữ cutoff cố định qua restart.';
COMMENT ON COLUMN public.audit_retention_runs.cutoff IS 'Cutoff ingestion UTC đã đóng cho run; mặc định serverNow trừ720 giờ, chỉ audit có created_at nhỏ hơn cutoff mới đủ điều kiện purge; đúng cutoff vẫn giữ.';
COMMENT ON TABLE public.audit_retention_batches IS 'Kết quả immutable của từng batch audit purge, commit cùng DELETE audit; batch ID là khóa replay để retry không xóa thêm hoặc trả count giả. Không chứa nội dung audit đã xóa.';
COMMENT ON COLUMN public.audit_retention_batches.batch_id IS 'Identity UUID không nil của intent batch, primary key không NULL/không trùng; retry cùng ID phải giữ run và batch limit gốc.';
COMMENT ON COLUMN public.audit_retention_batches.run_id IS 'Run/cutoff mà batch tham chiếu bằng khóa ngoại; không cascade xóa result và không sao chép cutoff vào từng batch gây lặp phụ thuộc hàm.';
COMMENT ON COLUMN public.audit_retention_batches.batch_limit IS 'Số audit tối đa một transaction được xóa, bắt buộc trong1…1000 để giới hạn lock/runtime; là một phần body identity của batch replay.';
COMMENT ON COLUMN public.audit_retention_batches.removed_count IS 'Số audit thực đã xóa cùng commit với result, trong0…batch_limit;0 không chứng nhận run drain nếu audit đang bị transaction khác khóa.';
COMMENT ON COLUMN public.audit_retention_batches.completed_at IS 'Thời điểm server ghi batch result đã hoàn tất; row chỉ xuất hiện sau commit DELETE cùng metadata, không dùng làm cutoff retention của audit.';
