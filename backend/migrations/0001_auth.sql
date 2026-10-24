/*
 * Mục đích: khởi tạo schema auth/workspace theo thứ tự khóa ngoại trên DB lab mới mà không sửa dữ liệu cũ.
 * Vận hành: chỉ thêm bảng/index, không backfill; DDL cần quyền CREATE và có thể chờ khóa metadata.
 * Thời gian khóa phụ thuộc runner cùng hoạt động đồng thời, nên review bảng đích trước production.
 * Áp dụng theo thứ tự phiên bản bằng tài khoản migration chuyên biệt; ứng dụng không tự nâng schema.
 */

/* Hồ sơ principal toàn cục; email chuẩn hóa duy nhất để login không phụ thuộc cách viết hoa/thường.
 * password_hash lưu verifier một chiều thay cho mật khẩu gốc; không trả trường này trong response/log.
 * CHECK giữ trạng thái và revision hợp lệ ngay cả khi có writer ngoài service.
 */
CREATE TABLE users (
    id uuid PRIMARY KEY,
    email_normalized varchar(254) NOT NULL UNIQUE,
    password_hash text NOT NULL,
    status text NOT NULL CHECK (status IN ('ACTIVE', 'DISABLED')),
    must_change_password boolean NOT NULL DEFAULT false,
    display_timezone text NOT NULL DEFAULT 'UTC',
    preferences_revision bigint NOT NULL DEFAULT 1 CHECK (preferences_revision > 0),
    created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

/* Bảng cấu hình singleton chứa khóa ký do vận hành cấp; ứng dụng chỉ đọc khóa tại ranh giới xác thực.
 * PRIMARY KEY/CHECK ngăn nhiều hàng và sai độ dài 32 byte; khởi động phải xử lý rõ trường hợp chưa cấu hình.
 * Giá trị khóa không được đưa vào DTO/log và phải được cấp ngoài repository.
 */
CREATE TABLE auth_settings (
    singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton),
    signing_key bytea NOT NULL CHECK (octet_length(signing_key) = 32)
);

/* Mỗi hàng là một phiên độc lập để logout/password change có thể nhắm đúng phiên.
 * token_digest và auth_context_id duy nhất chống nhập nhằng; CHECK buộc TTL contract là 24 giờ.
 */
CREATE TABLE sessions (
    id uuid PRIMARY KEY,
    user_id uuid NOT NULL REFERENCES users(id),
    token_digest bytea NOT NULL UNIQUE CHECK (octet_length(token_digest) = 32),
    auth_context_id uuid NOT NULL UNIQUE,
    client_type text NOT NULL CHECK (client_type IN ('WEB', 'ANDROID', 'IOS')),
    limited boolean NOT NULL,
    created_at timestamptz NOT NULL,
    expires_at timestamptz NOT NULL,
    revoked_at timestamptz,
    CHECK (expires_at = created_at + interval '24 hours')
);

-- Phục vụ revoke các phiên theo user_id; cột này đứng đầu để không scan session của user khác.
CREATE INDEX sessions_by_user ON sessions (user_id, id);

/* Một hàng theo digest email chia sẻ bộ đếm giữa các backend instance.
 * failure_count bị chặn ở 0..5 để state limiter không vượt invariant khi nhiều request cập nhật.
 */
CREATE TABLE login_attempts (
    email_digest bytea PRIMARY KEY CHECK (octet_length(email_digest) = 32),
    failure_count integer NOT NULL DEFAULT 0 CHECK (failure_count BETWEEN 0 AND 5),
    window_started_at timestamptz
);

/* Danh mục workspace và revision dùng để phát hiện thay đổi giữa lần đọc và lần xác nhận.
 * CHECK tên/status/revision bảo vệ định dạng cơ bản trước khi membership tham chiếu đến.
 */
CREATE TABLE workspaces (
    id uuid PRIMARY KEY,
    name varchar(100) NOT NULL CHECK (length(btrim(name)) BETWEEN 1 AND 100),
    status text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE', 'SUSPENDED', 'ARCHIVED')),
    revision bigint NOT NULL DEFAULT 1 CHECK (revision > 0),
    authz_version bigint NOT NULL DEFAULT 1 CHECK (authz_version > 0),
    created_by uuid NOT NULL REFERENCES users(id)
);

/* Quan hệ user-workspace là authority cho picker và quyền trong workspace.
 * Khóa chính kép ngăn membership trùng; role/status/revision bị giới hạn ở các trạng thái hợp lệ.
 */
CREATE TABLE memberships (
    workspace_id uuid NOT NULL REFERENCES workspaces(id),
    user_id uuid NOT NULL REFERENCES users(id),
    role text NOT NULL CHECK (role IN ('ADMIN', 'USER')),
    status text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE', 'SUSPENDED', 'REMOVED')),
    authz_version bigint NOT NULL DEFAULT 1 CHECK (authz_version > 0),
    PRIMARY KEY (workspace_id, user_id)
);

/* Picker bắt đầu từ principal hiện tại rồi join workspace; thứ tự user_id, workspace_id hỗ trợ
 * lọc membership ACTIVE và phân trang ổn định theo UUID mà không quét thành viên khác.
 */
CREATE INDEX memberships_picker ON memberships (user_id, workspace_id) WHERE status = 'ACTIVE';

/* Nhật ký dùng cho sự kiện toàn cục hoặc theo workspace; workspace_id nullable để sự kiện login
 * không vô tình trở thành dữ liệu mà Admin một workspace được quyền đọc.
 */
CREATE TABLE audit_events (
    id uuid PRIMARY KEY,
    actor_id uuid REFERENCES users(id),
    session_id uuid REFERENCES sessions(id),
    workspace_id uuid REFERENCES workspaces(id),
    event_type text NOT NULL,
    outcome text NOT NULL,
    client_type text NOT NULL CHECK (client_type IN ('WEB', 'ANDROID', 'IOS', 'UNKNOWN')),
    correlation_id uuid NOT NULL,
    occurred_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

/* Job retention purge theo occurred_at và id; thứ tự cột hỗ trợ batch ổn định theo thời gian.
 * Thời hạn lưu 30 ngày thuộc cấu hình job vận hành, không được hard-code bằng partition tại đây.
 */
CREATE INDEX audit_events_retention ON audit_events (occurred_at, id);
