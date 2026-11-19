/* Tách limiter đổi mật khẩu khỏi login để giới hạn theo User ổn định xuyên session/instance.
 * Bảng mới không backfill; chỉ tạo row khi có lần xác minh sai đầu tiên.
 * PK/FK và CHECK là DDL metadata ngắn, không quét hoặc khóa dữ liệu auth hiện có.
 */
CREATE TABLE public.password_change_attempt_buckets (
    user_id uuid PRIMARY KEY REFERENCES public.users(user_id) ON DELETE CASCADE,
    failure_count integer NOT NULL DEFAULT 0 CHECK (failure_count BETWEEN 0 AND 5),
    window_started_at timestamptz,
    CONSTRAINT password_change_attempt_buckets_coherence CHECK (
        (failure_count = 0 AND window_started_at IS NULL)
        OR (failure_count > 0 AND window_started_at IS NOT NULL)
    )
);

/* User ID là identity của bucket và không thể được chuyển sang account khác qua UPDATE. */
CREATE TRIGGER tr_password_change_attempt_bucket_identity
BEFORE UPDATE ON public.password_change_attempt_buckets
FOR EACH ROW EXECUTE FUNCTION public.enforce_identity_columns('user_id');

COMMENT ON TABLE public.password_change_attempt_buckets IS
    'Bộ đếm sai currentPassword riêng theo User ID; PostgreSQL khóa nguyên tử để chia sẻ giới hạn đổi mật khẩu giữa session và instance.';
COMMENT ON COLUMN public.password_change_attempt_buckets.user_id IS
    'User sở hữu limiter đổi mật khẩu; khóa ngoại giữ bucket gắn đúng account và không dùng email, session hoặc IP làm định danh.';
COMMENT ON COLUMN public.password_change_attempt_buckets.failure_count IS
    'Số lần currentPassword sai trong fixed window hiện hành, miền 0..5; count 0 đi cùng window_started_at NULL.';
COMMENT ON COLUMN public.password_change_attempt_buckets.window_started_at IS
    'Thời điểm failure đầu tiên mở fixed window 15 phút; không trượt khi retry hoặc nhận 429, NULL khi bucket rỗng.';
