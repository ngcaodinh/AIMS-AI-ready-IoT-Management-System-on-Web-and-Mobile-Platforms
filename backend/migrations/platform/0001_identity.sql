/* Bản chú thích để đọc: ràng buộc hiện hành lấy từ manifest sau mọi forward migration.
 * Runner thực thi byte bất biến trong applied_sql và so token SQL với bản này; không sửa ledger.
 */
/* Baseline canonical IAM/workspace của toàn hệ thống, chỉ áp trên DB mới.
 * DDL+ledger phải cùng transaction; không thay lịch sử auth lab ở thư mục cha.
 * Không tạo singleton plaintext signing key; custody thuộc deployment interface.
 */
REVOKE CREATE ON SCHEMA public FROM PUBLIC;

/* Principal toàn cục; activation provenance phân biệt legacy với account tạm mới. */
-- Bảng users: Danh tính tài khoản dùng chung toàn hệ thống: lưu email đăng nhập, bộ kiểm chứng mật khẩu và trạng
-- thái kích hoạt. Vai trò theo workspace nằm ở memberships, không gắn vai trò toàn cục vào tài khoản.
CREATE TABLE users (
    -- Identity tài khoản toàn cục để đăng nhập và liên kết các membership; không gắn với một workspace duy nhất.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành users_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì uniqueness áp dụng cho
    -- cả tổ hợp.
    -- PRIMARY KEY (user_id)
    user_id uuid PRIMARY KEY,

    -- Email đã được lớp xác thực chuẩn hóa, dùng lookup tài khoản/lời mời; quy tắc chuẩn hóa phải thống nhất trước
    -- ghi.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành users_email_normalized_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua,
    -- nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK (((length(email_normalized) >= 3) AND (length(email_normalized) <= 254)))
    -- Ràng buộc hiện hành users_email_normalized_key: không trùng tổ hợp giá trị được nêu; các cột riêng lẻ vẫn có thể
    -- lặp khi khóa có nhiều cột.
    -- UNIQUE (email_normalized)
    -- CHECK length 3..254 chỉ kiểm số ký tự, không xác minh email RFC, số byte hoặc tự chuẩn hóa; backend phải
    -- validate và chuẩn hóa trước ghi.
    email_normalized text NOT NULL UNIQUE CHECK (length(email_normalized) BETWEEN 3 AND 254),

    -- Bộ kiểm chứng mật khẩu theo encoding của password hasher; không chứa mật khẩu gốc và không trả về client/log.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    password_hash text NOT NULL,

    -- Trạng thái tài khoản toàn cục ACTIVE/DISABLED; khác trạng thái membership trong một workspace.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành users_account_status_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên
    -- phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((account_status = ANY (ARRAY['ACTIVE'::text, 'DISABLED'::text])))
    account_status text NOT NULL CHECK (account_status IN ('ACTIVE','DISABLED')),

    -- Đánh dấu tài khoản phải đổi mật khẩu trước thao tác thông thường; backend dùng để hạn chế admission và session.
    -- boolean: cờ logic true/false; NULL là trạng thái riêng nếu cột cho phép.
    -- NOT NULL: bắt buộc có giá trị.
    -- DEFAULT false: giá trị dùng khi INSERT bỏ qua cột; không thay NULL được truyền tường minh và không tự áp lại khi
    -- UPDATE.
    must_change_password boolean NOT NULL DEFAULT false,

    -- Thời điểm xác nhận tài khoản đã kích hoạt; NULL không được tự suy thành tài khoản tạm nếu provenance là
    -- legacy/unknown.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    activated_at timestamptz,

    -- Nguồn/bằng chứng hình thành trạng thái kích hoạt, giúp phân biệt account tạm mới với dữ liệu legacy chưa rõ lịch
    -- sử.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành users_activation_provenance_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn
    -- qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((btrim(activation_provenance) <> ''::text))
    -- CHECK btrim(...)<>'' chặn chuỗi rỗng/chỉ khoảng trắng; không tự giới hạn thành danh sách phương thức kích hoạt
    -- hay chứng minh đã kích hoạt.
    activation_provenance text NOT NULL CHECK (btrim(activation_provenance)<>''),

    -- Thời điểm tạo bản ghi dưới dạng timestamptz; dùng provenance/sắp xếp hoặc retention khi policy của bảng quy
    -- định.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- NOT NULL: bắt buộc có giá trị.
    -- DEFAULT transaction_timestamp(): thời điểm bắt đầu transaction, giữ nguyên trong transaction; không phải đồng hồ
    -- thay đổi theo từng statement.
    created_at timestamptz NOT NULL DEFAULT transaction_timestamp()
);
/* Preference tách khỏi credential để CAS không làm thay đổi auth aggregate. */
-- Bảng user_preferences: Tùy chọn hiển thị của từng tài khoản, hiện gồm múi giờ. Tách khỏi hồ sơ xác thực để đổi
-- giao diện không làm thay đổi thông tin đăng nhập.
CREATE TABLE user_preferences (
    -- Identity tài khoản liên quan; khi đi cùng workspace_id phải tham chiếu đúng membership của workspace.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành user_preferences_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì uniqueness
    -- áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (user_id)
    -- Ràng buộc hiện hành user_preferences_user_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ hợp có workspace_id giữ
    -- quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (user_id) REFERENCES users(user_id)
    user_id uuid PRIMARY KEY REFERENCES users,

    -- Múi giờ IANA dùng hiển thị cho user, mặc định UTC; không đổi instant lưu trong DB hay lịch rule hiện hữu.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- DEFAULT 'UTC'::text: giá trị dùng khi INSERT bỏ qua cột; không thay NULL được truyền tường minh và không tự áp
    -- lại khi UPDATE.
    display_timezone text NOT NULL DEFAULT 'UTC',

    -- Phiên bản chỉnh sửa bản ghi dùng cho CAS/If-Match hoặc đối soát; bên ghi chịu trách nhiệm cập nhật theo đúng
    -- transaction contract.
    -- bigint: số nguyên có dấu 64 bit, phù hợp bộ đếm/generation tăng lâu dài; không tự tăng nếu chưa có cơ chế cấp
    -- giá trị.
    -- NOT NULL: bắt buộc có giá trị.
    -- DEFAULT 1: giá trị dùng khi INSERT bỏ qua cột; không thay NULL được truyền tường minh và không tự áp lại khi
    -- UPDATE.
    -- Ràng buộc hiện hành user_preferences_revision_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn
    -- qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((revision > 0))
    revision bigint NOT NULL DEFAULT 1 CHECK (revision>0),

    -- Thời điểm cập nhật gần nhất do đường ghi quản lý; không mặc định SQL tự cập nhật nếu không có trigger tương ứng.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- NOT NULL: bắt buộc có giá trị.
    -- DEFAULT transaction_timestamp(): thời điểm bắt đầu transaction, giữ nguyên trong transaction; không phải đồng hồ
    -- thay đổi theo từng statement.
    updated_at timestamptz NOT NULL DEFAULT transaction_timestamp()
);
/* Context/admission giữ theo auth contract draft hiện hành; không mở lại iOS đã hoãn. */
-- Bảng sessions: Mỗi hàng là một phiên đăng nhập Web hoặc Android, có chế độ full/limited và hạn 24 giờ. Lưu
-- digest để xác minh, thu hồi phiên; không lưu raw session token.
CREATE TABLE sessions (
    -- Identity một phiên đăng nhập; dùng gắn thao tác hoặc ticket với đúng principal, không phải raw token xác thực.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành sessions_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì uniqueness áp dụng
    -- cho cả tổ hợp.
    -- PRIMARY KEY (session_id)
    -- Ràng buộc hiện hành uq_sessions_user_identity: không trùng tổ hợp giá trị được nêu; các cột riêng lẻ vẫn có thể
    -- lặp khi khóa có nhiều cột.
    -- UNIQUE (user_id, session_id)
    session_id uuid PRIMARY KEY,

    -- Identity tài khoản liên quan; khi đi cùng workspace_id phải tham chiếu đúng membership của workspace.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành sessions_user_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ hợp có workspace_id giữ quan hệ
    -- trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (user_id) REFERENCES users(user_id)
    -- Ràng buộc hiện hành uq_sessions_user_identity: không trùng tổ hợp giá trị được nêu; các cột riêng lẻ vẫn có thể
    -- lặp khi khóa có nhiều cột.
    -- UNIQUE (user_id, session_id)
    user_id uuid NOT NULL REFERENCES users,

    -- SHA-256 32 byte của raw session token; unique toàn cục để lookup phiên, không trả về client/log.
    -- bytea: dãy byte nhị phân; tên digest/ciphertext mô tả mục đích, bản thân kiểu không băm hoặc mã hóa dữ liệu.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành sessions_token_digest_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua,
    -- nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((octet_length(token_digest) = 32))
    -- Ràng buộc hiện hành sessions_token_digest_key: không trùng tổ hợp giá trị được nêu; các cột riêng lẻ vẫn có thể
    -- lặp khi khóa có nhiều cột.
    -- UNIQUE (token_digest)
    token_digest bytea NOT NULL UNIQUE CHECK (octet_length(token_digest)=32),

    -- Identity ngữ cảnh xác thực của phiên theo auth contract, dùng phân biệt các lần admission và đối chiếu client.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành sessions_auth_context_id_key: không trùng tổ hợp giá trị được nêu; các cột riêng lẻ vẫn có
    -- thể lặp khi khóa có nhiều cột.
    -- UNIQUE (auth_context_id)
    auth_context_id uuid NOT NULL UNIQUE,

    -- True nếu phiên bị giới hạn vì cần đổi mật khẩu; không được đổi thành full tại chỗ, phải cấp phiên mới theo
    -- contract.
    -- boolean: cờ logic true/false; NULL là trạng thái riêng nếu cột cho phép.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    limited boolean NOT NULL,

    -- Loại client khởi tạo phiên/thao tác; enum của từng bảng phân biệt WEB, ANDROID và UNKNOWN khi được phép.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành sessions_client_type_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên
    -- phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((client_type = ANY (ARRAY['WEB'::text, 'ANDROID'::text])))
    client_type text NOT NULL CHECK (client_type IN ('WEB','ANDROID')),

    -- Thời điểm phát hành phiên/grant/credential/ticket, làm gốc tính TTL theo loại bản ghi.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành ck_sessions_ttl: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên phải phối
    -- hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((expires_at = (issued_at + '24:00:00'::interval)))
    issued_at timestamptz NOT NULL,

    -- Hạn hiệu lực cố định issued_at + 24 giờ; revoke có thể làm phiên hết quyền sớm hơn, row còn giữ khi audit/ticket
    -- tham chiếu.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành ck_sessions_ttl: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên phải phối
    -- hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((expires_at = (issued_at + '24:00:00'::interval)))
    expires_at timestamptz NOT NULL,

    -- Thời điểm thu hồi quyền/credential; NULL nghĩa chưa ghi nhận thu hồi, không đồng nghĩa mọi điều kiện xác thực
    -- khác còn hợp lệ.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    revoked_at timestamptz,

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    CONSTRAINT uq_sessions_user_identity UNIQUE (user_id,session_id),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    CONSTRAINT ck_sessions_ttl CHECK (expires_at=issued_at+interval '24 hours')
);
/* User đứng đầu để revoke toàn bộ phiên; expiry phục vụ purge sau audit retention. */
CREATE INDEX ix_sessions_user ON sessions(user_id,session_id);
CREATE INDEX ix_sessions_expiry ON sessions(expires_at,session_id);
/* Fixed-window bắt đầu ở failure đầu; expiry kiểm khi admission, không CHECK theo now(). */
-- Bảng login_attempt_buckets: Bộ đếm đăng nhập sai theo digest email chuẩn hóa. Ghi mốc cửa sổ thất bại để backend
-- thực thi giới hạn đăng nhập đồng nhất giữa các tiến trình.
CREATE TABLE login_attempt_buckets (
    -- Digest 32 byte của email chuẩn hóa để lập bucket/fence mà không dùng raw email làm khóa vận hành; policy key
    -- version thuộc custody.
    -- bytea: dãy byte nhị phân; tên digest/ciphertext mô tả mục đích, bản thân kiểu không băm hoặc mã hóa dữ liệu.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành login_attempt_buckets_email_digest_check: CHECK chỉ chặn khi biểu thức là FALSE;
    -- NULL/UNKNOWN vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((octet_length(email_digest) = 32))
    -- Ràng buộc hiện hành login_attempt_buckets_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (email_digest)
    email_digest bytea PRIMARY KEY CHECK (octet_length(email_digest)=32),

    -- Số lần đăng nhập sai trong bucket hiện hành, miền 0..5; count 0 đi cùng window_started_at NULL.
    -- integer: số nguyên có dấu 32 bit; CHECK giới hạn miền nghiệp vụ thay vì chỉ dựa phạm vi kiểu.
    -- NOT NULL: bắt buộc có giá trị.
    -- DEFAULT 0: giá trị dùng khi INSERT bỏ qua cột; không thay NULL được truyền tường minh và không tự áp lại khi
    -- UPDATE.
    -- Ràng buộc hiện hành ck_login_bucket_coherence: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên
    -- phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((((failure_count = 0) AND (window_started_at IS NULL)) OR ((failure_count > 0) AND (window_started_at IS
    -- NOT NULL))))
    -- Ràng buộc hiện hành login_attempt_buckets_failure_count_check: CHECK chỉ chặn khi biểu thức là FALSE;
    -- NULL/UNKNOWN vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK (((failure_count >= 0) AND (failure_count <= 5)))
    failure_count integer NOT NULL DEFAULT 0 CHECK (failure_count BETWEEN 0 AND 5),

    -- Mốc failure đầu mở fixed window đăng nhập, không trượt theo mỗi lần retry/429; NULL khi bucket rỗng.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    -- Ràng buộc hiện hành ck_login_bucket_coherence: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên
    -- phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((((failure_count = 0) AND (window_started_at IS NULL)) OR ((failure_count > 0) AND (window_started_at IS
    -- NOT NULL))))
    window_started_at timestamptz,

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    CONSTRAINT ck_login_bucket_coherence CHECK (
        (failure_count=0 AND window_started_at IS NULL) OR
        (failure_count>0 AND window_started_at IS NOT NULL))
);
/* Tenant root; creator quota và capable Admin dùng fence/guard ở migration cuối. */
-- Bảng workspaces: Đơn vị cô lập dữ liệu và quyền của dự án. Quản lý tên, múi giờ mặc định, trạng thái hoạt động
-- và phiên bản quyền; mọi tài nguyên nghiệp vụ đều thuộc một workspace.
CREATE TABLE workspaces (
    -- Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền
    -- của người gọi.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành workspaces_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì uniqueness áp dụng
    -- cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id)
    workspace_id uuid PRIMARY KEY,

    -- Tên hiển thị do người dùng đặt cho tài nguyên; không dùng làm identity, quyền hoặc khóa chống lặp.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành workspaces_name_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên phải
    -- phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK (((length(btrim(name)) >= 1) AND (length(btrim(name)) <= 100)))
    name text NOT NULL CHECK (length(btrim(name)) BETWEEN 1 AND 100),

    -- Mô tả bổ sung để người dùng hiểu tài nguyên; NULL nghĩa chưa cung cấp mô tả, không mang authority vận hành.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    -- Ràng buộc hiện hành ck_workspace_description: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên
    -- phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK (((description IS NULL) OR (length(description) <= 500)))
    description text,

    -- Múi giờ IANA mặc định của workspace cho cấu hình mới; đổi giá trị này không tự đổi timezone snapshot của lịch đã
    -- tạo.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- DEFAULT 'UTC'::text: giá trị dùng khi INSERT bỏ qua cột; không thay NULL được truyền tường minh và không tự áp
    -- lại khi UPDATE.
    default_timezone text NOT NULL DEFAULT 'UTC',

    -- Lifecycle ACTIVE/SUSPENDED/ARCHIVED; suspend chặn admission theo policy, archive không phải hard-delete và không
    -- tự unarchive.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- DEFAULT 'ACTIVE'::text: giá trị dùng khi INSERT bỏ qua cột; không thay NULL được truyền tường minh và không tự
    -- áp lại khi UPDATE.
    -- Ràng buộc hiện hành workspaces_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên phải phối
    -- hợp NOT NULL và CHECK shape khi cần.
    -- CHECK (((status = 'ARCHIVED'::text) = (archived_at IS NOT NULL)))
    -- Ràng buộc hiện hành workspaces_status_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên
    -- phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((status = ANY (ARRAY['ACTIVE'::text, 'SUSPENDED'::text, 'ARCHIVED'::text])))
    status text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','SUSPENDED','ARCHIVED')),

    -- Tài khoản tạo workspace, dùng anchor tuần tự hóa quota tối đa 5 workspace do account tạo.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành workspaces_created_by_user_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ hợp có workspace_id
    -- giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (created_by_user_id) REFERENCES users(user_id)
    created_by_user_id uuid NOT NULL REFERENCES users,

    -- Phiên bản chỉnh sửa bản ghi dùng cho CAS/If-Match hoặc đối soát; bên ghi chịu trách nhiệm cập nhật theo đúng
    -- transaction contract.
    -- bigint: số nguyên có dấu 64 bit, phù hợp bộ đếm/generation tăng lâu dài; không tự tăng nếu chưa có cơ chế cấp
    -- giá trị.
    -- NOT NULL: bắt buộc có giá trị.
    -- DEFAULT 1: giá trị dùng khi INSERT bỏ qua cột; không thay NULL được truyền tường minh và không tự áp lại khi
    -- UPDATE.
    -- Ràng buộc hiện hành workspaces_revision_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên
    -- phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((revision > 0))
    revision bigint NOT NULL DEFAULT 1 CHECK (revision>0),

    -- Mốc phiên bản quyền hiện hành; bên ghi phải tăng khi quyền thay đổi để ticket/job/cache phát hiện ngữ cảnh quyền
    -- cũ.
    -- bigint: số nguyên có dấu 64 bit, phù hợp bộ đếm/generation tăng lâu dài; không tự tăng nếu chưa có cơ chế cấp
    -- giá trị.
    -- NOT NULL: bắt buộc có giá trị.
    -- DEFAULT 1: giá trị dùng khi INSERT bỏ qua cột; không thay NULL được truyền tường minh và không tự áp lại khi
    -- UPDATE.
    -- Ràng buộc hiện hành workspaces_authorization_version_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN
    -- vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((authorization_version > 0))
    authorization_version bigint NOT NULL DEFAULT 1 CHECK (authorization_version>0),

    -- Thời điểm tạo bản ghi dưới dạng timestamptz; dùng provenance/sắp xếp hoặc retention khi policy của bảng quy
    -- định.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- NOT NULL: bắt buộc có giá trị.
    -- DEFAULT transaction_timestamp(): thời điểm bắt đầu transaction, giữ nguyên trong transaction; không phải đồng hồ
    -- thay đổi theo từng statement.
    created_at timestamptz NOT NULL DEFAULT transaction_timestamp(),

    -- Thời điểm cập nhật gần nhất do đường ghi quản lý; không mặc định SQL tự cập nhật nếu không có trigger tương ứng.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- NOT NULL: bắt buộc có giá trị.
    -- DEFAULT transaction_timestamp(): thời điểm bắt đầu transaction, giữ nguyên trong transaction; không phải đồng hồ
    -- thay đổi theo từng statement.
    updated_at timestamptz NOT NULL DEFAULT transaction_timestamp(),

    -- Thời điểm workspace được archive; phải đi cùng trạng thái ARCHIVED, không phải lệnh hard-delete dữ liệu.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    -- Ràng buộc hiện hành workspaces_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên phải phối
    -- hợp NOT NULL và CHECK shape khi cần.
    -- CHECK (((status = 'ARCHIVED'::text) = (archived_at IS NOT NULL)))
    archived_at timestamptz,

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    CHECK ((status='ARCHIVED')=(archived_at IS NOT NULL))
);
/* Đếm workspace theo creator; thứ tự khóa bắt đầu từ User, không count ngoài transaction. */
CREATE INDEX ix_workspaces_creator ON workspaces(created_by_user_id,workspace_id);
/* Membership là authority theo workspace; grant generation không tái sử dụng khi rejoin. */
-- Bảng memberships: Quan hệ hiện hành giữa tài khoản và workspace: vai trò ADMIN/USER, trạng thái và grant đang sử
-- dụng. Đây là nguồn xác định tư cách thành viên, không sao chép vai trò vào từng thiết bị.
CREATE TABLE memberships (
    -- Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền
    -- của người gọi.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành fk_memberships_current_grant: khóa ngoại giữ đúng bản ghi cha; tổ hợp có workspace_id giữ
    -- quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, user_id, current_grant_generation) REFERENCES membership_grants(workspace_id,
    -- user_id, grant_generation) DEFERRABLE INITIALLY DEFERRED
    -- Ràng buộc hiện hành memberships_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì uniqueness áp
    -- dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, user_id)
    -- Ràng buộc hiện hành memberships_workspace_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ hợp có workspace_id giữ
    -- quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id) REFERENCES workspaces(workspace_id)
    workspace_id uuid NOT NULL REFERENCES workspaces,

    -- Identity tài khoản liên quan; khi đi cùng workspace_id phải tham chiếu đúng membership của workspace.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành fk_memberships_current_grant: khóa ngoại giữ đúng bản ghi cha; tổ hợp có workspace_id giữ
    -- quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, user_id, current_grant_generation) REFERENCES membership_grants(workspace_id,
    -- user_id, grant_generation) DEFERRABLE INITIALLY DEFERRED
    -- Ràng buộc hiện hành memberships_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì uniqueness áp
    -- dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, user_id)
    -- Ràng buộc hiện hành memberships_user_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ hợp có workspace_id giữ quan
    -- hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (user_id) REFERENCES users(user_id)
    user_id uuid NOT NULL REFERENCES users,

    -- Vai trò thành viên ADMIN/USER trong workspace, không là quyền quản trị toàn bộ hệ thống.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành memberships_role_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên
    -- phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((role = ANY (ARRAY['ADMIN'::text, 'USER'::text])))
    role text NOT NULL CHECK (role IN ('ADMIN','USER')),

    -- Tư cách thành viên ACTIVE/SUSPENDED/REMOVED trong workspace; khác trạng thái tài khoản toàn cục.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- DEFAULT 'ACTIVE'::text: giá trị dùng khi INSERT bỏ qua cột; không thay NULL được truyền tường minh và không tự
    -- áp lại khi UPDATE.
    -- Ràng buộc hiện hành memberships_status_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên
    -- phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((status = ANY (ARRAY['ACTIVE'::text, 'SUSPENDED'::text, 'REMOVED'::text])))
    status text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','SUSPENDED','REMOVED')),

    -- Tên gọi của tài khoản trong workspace này, độc lập email đăng nhập hoặc tên trong workspace khác.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    alias text,

    -- Phiên bản chỉnh sửa bản ghi dùng cho CAS/If-Match hoặc đối soát; bên ghi chịu trách nhiệm cập nhật theo đúng
    -- transaction contract.
    -- bigint: số nguyên có dấu 64 bit, phù hợp bộ đếm/generation tăng lâu dài; không tự tăng nếu chưa có cơ chế cấp
    -- giá trị.
    -- NOT NULL: bắt buộc có giá trị.
    -- DEFAULT 1: giá trị dùng khi INSERT bỏ qua cột; không thay NULL được truyền tường minh và không tự áp lại khi
    -- UPDATE.
    -- Ràng buộc hiện hành memberships_revision_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên
    -- phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((revision > 0))
    revision bigint NOT NULL DEFAULT 1 CHECK (revision>0),

    -- Phiên bản quyền của membership, chụp vào ticket/job; đường ghi phải tăng khi role/status/quyền thay đổi theo
    -- protocol.
    -- bigint: số nguyên có dấu 64 bit, phù hợp bộ đếm/generation tăng lâu dài; không tự tăng nếu chưa có cơ chế cấp
    -- giá trị.
    -- NOT NULL: bắt buộc có giá trị.
    -- DEFAULT 1: giá trị dùng khi INSERT bỏ qua cột; không thay NULL được truyền tường minh và không tự áp lại khi
    -- UPDATE.
    -- Ràng buộc hiện hành memberships_authorization_version_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN
    -- vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((authorization_version > 0))
    authorization_version bigint NOT NULL DEFAULT 1 CHECK (authorization_version>0),

    -- Grant membership hiện đang dùng; phải trỏ đúng lịch sử cấp quyền, không tự bật lại grant đã revoke.
    -- bigint: số nguyên có dấu 64 bit, phù hợp bộ đếm/generation tăng lâu dài; không tự tăng nếu chưa có cơ chế cấp
    -- giá trị.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành fk_memberships_current_grant: khóa ngoại giữ đúng bản ghi cha; tổ hợp có workspace_id giữ
    -- quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, user_id, current_grant_generation) REFERENCES membership_grants(workspace_id,
    -- user_id, grant_generation) DEFERRABLE INITIALLY DEFERRED
    -- Ràng buộc hiện hành memberships_current_grant_generation_check: CHECK chỉ chặn khi biểu thức là FALSE;
    -- NULL/UNKNOWN vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((current_grant_generation > 0))
    current_grant_generation bigint NOT NULL CHECK (current_grant_generation>0),

    -- Thời điểm hình thành membership; lịch sử cấp quyền từng lần được giữ ở membership_grants.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- NOT NULL: bắt buộc có giá trị.
    -- DEFAULT transaction_timestamp(): thời điểm bắt đầu transaction, giữ nguyên trong transaction; không phải đồng hồ
    -- thay đổi theo từng statement.
    joined_at timestamptz NOT NULL DEFAULT transaction_timestamp(),

    -- Thời điểm membership bị remove; NULL khi chưa ghi nhận remove, không thay điều kiện status/current grant.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    removed_at timestamptz,

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    PRIMARY KEY(workspace_id,user_id)
);
/* Picker theo principal trước tenant, chỉ lấy membership còn hiệu lực. */
CREATE INDEX ix_memberships_picker ON memberships(user_id,workspace_id) WHERE status='ACTIVE';
/* Grant immutable identity giữ reference cũ sau remove/rejoin. */
-- Bảng membership_grants: Lịch sử từng lần cấp quyền thành viên. Giữ identity theo generation để lời mời, API key
-- hoặc tác vụ dùng grant cũ không tự có quyền lại khi tài khoản tham gia lại.
CREATE TABLE membership_grants (
    -- Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền
    -- của người gọi.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành membership_grants_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì uniqueness
    -- áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, user_id, grant_generation)
    -- Ràng buộc hiện hành membership_grants_workspace_id_user_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ hợp có
    -- workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, user_id) REFERENCES memberships(workspace_id, user_id)
    workspace_id uuid NOT NULL,

    -- Identity tài khoản liên quan; khi đi cùng workspace_id phải tham chiếu đúng membership của workspace.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành membership_grants_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì uniqueness
    -- áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, user_id, grant_generation)
    -- Ràng buộc hiện hành membership_grants_workspace_id_user_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ hợp có
    -- workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, user_id) REFERENCES memberships(workspace_id, user_id)
    user_id uuid NOT NULL,

    -- Generation của một lần cấp membership cụ thể, lớn hơn 0; không tái sử dụng identity khi remove rồi rejoin.
    -- bigint: số nguyên có dấu 64 bit, phù hợp bộ đếm/generation tăng lâu dài; không tự tăng nếu chưa có cơ chế cấp
    -- giá trị.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành membership_grants_grant_generation_check: CHECK chỉ chặn khi biểu thức là FALSE;
    -- NULL/UNKNOWN vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((grant_generation > 0))
    -- Ràng buộc hiện hành membership_grants_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì uniqueness
    -- áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, user_id, grant_generation)
    grant_generation bigint NOT NULL CHECK (grant_generation>0),

    -- Thời điểm phát hành phiên/grant/credential/ticket, làm gốc tính TTL theo loại bản ghi.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- NOT NULL: bắt buộc có giá trị.
    -- DEFAULT transaction_timestamp(): thời điểm bắt đầu transaction, giữ nguyên trong transaction; không phải đồng hồ
    -- thay đổi theo từng statement.
    issued_at timestamptz NOT NULL DEFAULT transaction_timestamp(),

    -- Thời điểm thu hồi quyền/credential; NULL nghĩa chưa ghi nhận thu hồi, không đồng nghĩa mọi điều kiện xác thực
    -- khác còn hợp lệ.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    revoked_at timestamptz,

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    PRIMARY KEY(workspace_id,user_id,grant_generation),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,user_id) REFERENCES memberships
);
/* Một grant chưa revoke cho mỗi membership; generation không nằm ngoài dedupe key. */
CREATE UNIQUE INDEX uq_membership_grants_current ON membership_grants(workspace_id,user_id) WHERE revoked_at IS NULL;
/* Vòng current-pointer cho phép tạo membership và grant atomically trong cùng transaction. */
ALTER TABLE memberships ADD CONSTRAINT fk_memberships_current_grant
    FOREIGN KEY(workspace_id,user_id,current_grant_generation)
    REFERENCES membership_grants DEFERRABLE INITIALLY DEFERRED;
/* Khóa được cả email chưa có User; không giữ raw invitation token. */
-- Bảng membership_admission_fences: Điểm tuần tự hóa nhận thành viên theo workspace và digest email, kể cả khi
-- chưa có tài khoản. Generation hiện hành giúp vô hiệu hóa lời mời hoặc admission cũ.
CREATE TABLE membership_admission_fences (
    -- Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền
    -- của người gọi.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành membership_admission_fences_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, email_digest)
    -- Ràng buộc hiện hành membership_admission_fences_workspace_id_email_digest_admis_key: không trùng tổ hợp giá trị
    -- được nêu; các cột riêng lẻ vẫn có thể lặp khi khóa có nhiều cột.
    -- UNIQUE (workspace_id, email_digest, admission_generation)
    -- Ràng buộc hiện hành membership_admission_fences_workspace_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ hợp có
    -- workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id) REFERENCES workspaces(workspace_id)
    workspace_id uuid NOT NULL REFERENCES workspaces,

    -- Digest 32 byte của email chuẩn hóa để lập bucket/fence mà không dùng raw email làm khóa vận hành; policy key
    -- version thuộc custody.
    -- bytea: dãy byte nhị phân; tên digest/ciphertext mô tả mục đích, bản thân kiểu không băm hoặc mã hóa dữ liệu.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành membership_admission_fences_email_digest_check: CHECK chỉ chặn khi biểu thức là FALSE;
    -- NULL/UNKNOWN vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((octet_length(email_digest) = 32))
    -- Ràng buộc hiện hành membership_admission_fences_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, email_digest)
    -- Ràng buộc hiện hành membership_admission_fences_workspace_id_email_digest_admis_key: không trùng tổ hợp giá trị
    -- được nêu; các cột riêng lẻ vẫn có thể lặp khi khóa có nhiều cột.
    -- UNIQUE (workspace_id, email_digest, admission_generation)
    email_digest bytea NOT NULL CHECK (octet_length(email_digest)=32),

    -- Thế hệ nhận thành viên theo email/workspace; snapshot invitation phải được so với fence hiện hành tại consume.
    -- bigint: số nguyên có dấu 64 bit, phù hợp bộ đếm/generation tăng lâu dài; không tự tăng nếu chưa có cơ chế cấp
    -- giá trị.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành membership_admission_fences_admission_generation_check: CHECK chỉ chặn khi biểu thức là
    -- FALSE; NULL/UNKNOWN vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((admission_generation > 0))
    -- Ràng buộc hiện hành membership_admission_fences_workspace_id_email_digest_admis_key: không trùng tổ hợp giá trị
    -- được nêu; các cột riêng lẻ vẫn có thể lặp khi khóa có nhiều cột.
    -- UNIQUE (workspace_id, email_digest, admission_generation)
    admission_generation bigint NOT NULL CHECK (admission_generation>0),

    -- Thời điểm cập nhật gần nhất do đường ghi quản lý; không mặc định SQL tự cập nhật nếu không có trigger tương ứng.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- NOT NULL: bắt buộc có giá trị.
    -- DEFAULT transaction_timestamp(): thời điểm bắt đầu transaction, giữ nguyên trong transaction; không phải đồng hồ
    -- thay đổi theo từng statement.
    updated_at timestamptz NOT NULL DEFAULT transaction_timestamp(),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    PRIMARY KEY(workspace_id,email_digest),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    UNIQUE(workspace_id,email_digest,admission_generation)
);
/* Invitation đóng băng issuer grant/admission generation; service vẫn recheck quyền khi consume. */
-- Bảng workspace_invitations: Lời mời tham gia workspace, chụp vai trò, người mời và generation quyền tại lúc phát
-- hành. Digest token, hạn 24 giờ và mốc sử dụng/thu hồi phục vụ nhận lời mời một lần.
CREATE TABLE workspace_invitations (
    -- Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền
    -- của người gọi.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành fk_invitation_admission_identity: khóa ngoại giữ đúng bản ghi cha; tổ hợp có workspace_id
    -- giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, email_digest) REFERENCES membership_admission_fences(workspace_id, email_digest)
    -- Ràng buộc hiện hành workspace_invitations_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, invitation_id)
    -- Ràng buộc hiện hành workspace_invitations_workspace_id_issued_by_user_id_issue_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, issued_by_user_id, issuer_grant_generation) REFERENCES
    -- membership_grants(workspace_id, user_id, grant_generation)
    workspace_id uuid NOT NULL,

    -- Identity lời mời workspace dùng quản trị/truy vết; token_digest mới là bộ kiểm chứng khi nhận lời mời.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành workspace_invitations_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, invitation_id)
    invitation_id uuid NOT NULL,

    -- Digest token dùng lookup/xác minh mà không lưu raw token; session token và provider token có ngữ nghĩa khác nhau
    -- theo bảng.
    -- bytea: dãy byte nhị phân; tên digest/ciphertext mô tả mục đích, bản thân kiểu không băm hoặc mã hóa dữ liệu.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành workspace_invitations_token_digest_check: CHECK chỉ chặn khi biểu thức là FALSE;
    -- NULL/UNKNOWN vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((octet_length(token_digest) = 32))
    -- Ràng buộc hiện hành workspace_invitations_token_digest_key: không trùng tổ hợp giá trị được nêu; các cột riêng
    -- lẻ vẫn có thể lặp khi khóa có nhiều cột.
    -- UNIQUE (token_digest)
    token_digest bytea NOT NULL UNIQUE CHECK (octet_length(token_digest)=32),

    -- Email đã được lớp xác thực chuẩn hóa, dùng lookup tài khoản/lời mời; quy tắc chuẩn hóa phải thống nhất trước
    -- ghi.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    email_normalized text NOT NULL,

    -- Digest 32 byte của email chuẩn hóa để lập bucket/fence mà không dùng raw email làm khóa vận hành; policy key
    -- version thuộc custody.
    -- bytea: dãy byte nhị phân; tên digest/ciphertext mô tả mục đích, bản thân kiểu không băm hoặc mã hóa dữ liệu.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành fk_invitation_admission_identity: khóa ngoại giữ đúng bản ghi cha; tổ hợp có workspace_id
    -- giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, email_digest) REFERENCES membership_admission_fences(workspace_id, email_digest)
    email_digest bytea NOT NULL,

    -- Vai trò thành viên ADMIN/USER trong workspace, không là quyền quản trị toàn bộ hệ thống.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành workspace_invitations_role_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn
    -- qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((role = ANY (ARRAY['ADMIN'::text, 'USER'::text])))
    role text NOT NULL CHECK (role IN ('ADMIN','USER')),

    -- Thành viên phát hành lời mời; issuer grant/version được chụp riêng để lần consume kiểm lại quyền.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành workspace_invitations_workspace_id_issued_by_user_id_issue_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, issued_by_user_id, issuer_grant_generation) REFERENCES
    -- membership_grants(workspace_id, user_id, grant_generation)
    issued_by_user_id uuid NOT NULL,

    -- Grant của người mời được chụp lúc phát hành invitation, không mặc định còn hợp lệ tại lúc consume.
    -- bigint: số nguyên có dấu 64 bit, phù hợp bộ đếm/generation tăng lâu dài; không tự tăng nếu chưa có cơ chế cấp
    -- giá trị.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành workspace_invitations_workspace_id_issued_by_user_id_issue_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, issued_by_user_id, issuer_grant_generation) REFERENCES
    -- membership_grants(workspace_id, user_id, grant_generation)
    issuer_grant_generation bigint NOT NULL,

    -- Phiên bản quyền của người mời tại lúc phát invitation, dùng kiểm callback/consume có dựa trên quyền cũ hay
    -- không.
    -- bigint: số nguyên có dấu 64 bit, phù hợp bộ đếm/generation tăng lâu dài; không tự tăng nếu chưa có cơ chế cấp
    -- giá trị.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành workspace_invitations_issuer_authorization_version_check: CHECK chỉ chặn khi biểu thức là
    -- FALSE; NULL/UNKNOWN vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((issuer_authorization_version > 0))
    issuer_authorization_version bigint NOT NULL CHECK (issuer_authorization_version>0),

    -- Thế hệ nhận thành viên theo email/workspace; snapshot invitation phải được so với fence hiện hành tại consume.
    -- bigint: số nguyên có dấu 64 bit, phù hợp bộ đếm/generation tăng lâu dài; không tự tăng nếu chưa có cơ chế cấp
    -- giá trị.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    admission_generation bigint NOT NULL,

    -- Thời điểm phát hành phiên/grant/credential/ticket, làm gốc tính TTL theo loại bản ghi.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành workspace_invitations_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua,
    -- nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((expires_at = (issued_at + '24:00:00'::interval)))
    issued_at timestamptz NOT NULL,

    -- Deadline issued_at + 24 giờ; consume phải kiểm thời gian và generation/quyền hiện hành, không chờ cron xóa row
    -- expired.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành workspace_invitations_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua,
    -- nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((expires_at = (issued_at + '24:00:00'::interval)))
    expires_at timestamptz NOT NULL,

    -- Thời điểm lời mời được tiêu thụ; một khi đã ghi không được xóa mốc để sử dụng lại token.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    used_at timestamptz,

    -- Thời điểm thu hồi quyền/credential; NULL nghĩa chưa ghi nhận thu hồi, không đồng nghĩa mọi điều kiện xác thực
    -- khác còn hợp lệ.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    revoked_at timestamptz,

    -- Thời điểm backend đã đánh dấu lời mời hết hạn để giải phóng pending slot; khác expires_at là deadline gốc.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    expired_at timestamptz,

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    PRIMARY KEY(workspace_id,invitation_id),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,issued_by_user_id,issuer_grant_generation) REFERENCES membership_grants,

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,email_digest,admission_generation)
        REFERENCES membership_admission_fences(workspace_id,email_digest,admission_generation),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    CHECK (expires_at=issued_at+interval '24 hours')
);
/* Expiry được đánh dấu dưới fence trước invite mới; không dùng partial predicate phụ thuộc clock. */
CREATE UNIQUE INDEX uq_workspace_invitations_pending ON workspace_invitations(workspace_id,email_digest)
    WHERE used_at IS NULL AND revoked_at IS NULL AND expired_at IS NULL;
/* Reset admission không lưu temporary password; budget5/15min thuộc controlled transaction. */
-- Bảng password_reset_admissions: Nhật ký những lần reset mật khẩu đã được nhận xử lý thành công theo
-- actor/target/workspace. Phục vụ đếm ngân sách reset và truy vết; không lưu mật khẩu tạm.
CREATE TABLE password_reset_admissions (
    -- Identity một lần admission đã được ghi nhận trong ledger reset/rate; không phải token dùng xác thực.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành password_reset_admissions_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (admission_id)
    admission_id uuid PRIMARY KEY,

    -- Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền
    -- của người gọi.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành password_reset_admissions_workspace_id_actor_user_id_fkey: khóa ngoại giữ đúng bản ghi cha;
    -- tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, actor_user_id) REFERENCES memberships(workspace_id, user_id)
    -- Ràng buộc hiện hành password_reset_admissions_workspace_id_target_user_id_fkey: khóa ngoại giữ đúng bản ghi cha;
    -- tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, target_user_id) REFERENCES memberships(workspace_id, user_id)
    workspace_id uuid NOT NULL,

    -- Tài khoản thực hiện hoặc khởi tạo thao tác, phục vụ kiểm quyền và truy vết; không lấy authority chỉ từ ID client
    -- gửi.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành password_reset_admissions_workspace_id_actor_user_id_fkey: khóa ngoại giữ đúng bản ghi cha;
    -- tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, actor_user_id) REFERENCES memberships(workspace_id, user_id)
    actor_user_id uuid NOT NULL,

    -- Tài khoản đích của thao tác quản trị trong workspace, phân biệt với actor thực hiện thao tác.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành password_reset_admissions_workspace_id_target_user_id_fkey: khóa ngoại giữ đúng bản ghi cha;
    -- tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, target_user_id) REFERENCES memberships(workspace_id, user_id)
    target_user_id uuid NOT NULL,

    -- Thời điểm yêu cầu được backend nhận vào ledger sau kiểm điều kiện; không chứng minh side effect đã thực hiện.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    admitted_at timestamptz NOT NULL,

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,actor_user_id) REFERENCES memberships,

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,target_user_id) REFERENCES memberships
);
/* Scope/actor/target đứng trước mốc thời gian để đếm budget reset đúng tenant. */
CREATE INDEX ix_password_reset_budget ON password_reset_admissions(workspace_id,actor_user_id,target_user_id,admitted_at);
/* Hàng khóa quota là projection, cần reconcile từ execution ledger trước mở worker. */
-- Bảng workspace_runtime_quotas: Projection đếm execution đang chiếm quota và hàng điều phối quota workspace.
-- Counter phải được đối soát từ rule_executions; không thay thế lịch sử thực thi.
CREATE TABLE workspace_runtime_quotas (
    -- Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền
    -- của người gọi.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành workspace_runtime_quotas_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id)
    -- Ràng buộc hiện hành workspace_runtime_quotas_workspace_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ hợp có
    -- workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id) REFERENCES workspaces(workspace_id)
    workspace_id uuid PRIMARY KEY REFERENCES workspaces,

    -- Projection số execution RUNNING/WAITING của workspace, miền 0..10; trigger đối chiếu ledger khi
    -- admission/terminal.
    -- integer: số nguyên có dấu 32 bit; CHECK giới hạn miền nghiệp vụ thay vì chỉ dựa phạm vi kiểu.
    -- NOT NULL: bắt buộc có giá trị.
    -- DEFAULT 0: giá trị dùng khi INSERT bỏ qua cột; không thay NULL được truyền tường minh và không tự áp lại khi
    -- UPDATE.
    -- Ràng buộc hiện hành workspace_runtime_quotas_active_execution_count_check: CHECK chỉ chặn khi biểu thức là
    -- FALSE; NULL/UNKNOWN vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK (((active_execution_count >= 0) AND (active_execution_count <= 10)))
    active_execution_count integer NOT NULL DEFAULT 0 CHECK (active_execution_count BETWEEN 0 AND 10),

    -- Phiên bản chỉnh sửa bản ghi dùng cho CAS/If-Match hoặc đối soát; bên ghi chịu trách nhiệm cập nhật theo đúng
    -- transaction contract.
    -- bigint: số nguyên có dấu 64 bit, phù hợp bộ đếm/generation tăng lâu dài; không tự tăng nếu chưa có cơ chế cấp
    -- giá trị.
    -- NOT NULL: bắt buộc có giá trị.
    -- DEFAULT 1: giá trị dùng khi INSERT bỏ qua cột; không thay NULL được truyền tường minh và không tự áp lại khi
    -- UPDATE.
    -- Ràng buộc hiện hành workspace_runtime_quotas_revision_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN
    -- vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((revision > 0))
    revision bigint NOT NULL DEFAULT 1 CHECK (revision>0)
);
/* Ticket one-time có binding đầy đủ; raw ticket chỉ được trả tại admission. */
-- Bảng websocket_tickets: Vé kết nối realtime dùng một lần, gắn với session, workspace và generation quyền.
-- Backend consume có điều kiện rồi mới mở kênh; không lưu raw ticket.
CREATE TABLE websocket_tickets (
    -- Identity quản lý bearer ticket, không phải secret; ticket_digest dùng xác minh/consume.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành websocket_tickets_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì uniqueness
    -- áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (ticket_id)
    ticket_id uuid PRIMARY KEY,

    -- Digest SHA-256 32 byte của bearer ticket, dùng lookup/consume hoặc tải artifact; raw ticket chỉ được trả qua
    -- kênh admission.
    -- bytea: dãy byte nhị phân; tên digest/ciphertext mô tả mục đích, bản thân kiểu không băm hoặc mã hóa dữ liệu.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành websocket_tickets_ticket_digest_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN
    -- vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((octet_length(ticket_digest) = 32))
    -- Ràng buộc hiện hành websocket_tickets_ticket_digest_key: không trùng tổ hợp giá trị được nêu; các cột riêng lẻ
    -- vẫn có thể lặp khi khóa có nhiều cột.
    -- UNIQUE (ticket_digest)
    ticket_digest bytea NOT NULL UNIQUE CHECK (octet_length(ticket_digest)=32),

    -- Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền
    -- của người gọi.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành websocket_tickets_workspace_id_user_id_grant_generation_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, user_id, grant_generation) REFERENCES membership_grants(workspace_id, user_id,
    -- grant_generation)
    workspace_id uuid NOT NULL,

    -- Identity tài khoản liên quan; khi đi cùng workspace_id phải tham chiếu đúng membership của workspace.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành websocket_tickets_user_id_session_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ hợp có
    -- workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (user_id, session_id) REFERENCES sessions(user_id, session_id)
    -- Ràng buộc hiện hành websocket_tickets_workspace_id_user_id_grant_generation_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, user_id, grant_generation) REFERENCES membership_grants(workspace_id, user_id,
    -- grant_generation)
    user_id uuid NOT NULL,

    -- Identity một phiên đăng nhập; dùng gắn thao tác hoặc ticket với đúng principal, không phải raw token xác thực.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành websocket_tickets_user_id_session_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ hợp có
    -- workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (user_id, session_id) REFERENCES sessions(user_id, session_id)
    session_id uuid NOT NULL,

    -- Generation của một lần cấp membership cụ thể, lớn hơn 0; không tái sử dụng identity khi remove rồi rejoin.
    -- bigint: số nguyên có dấu 64 bit, phù hợp bộ đếm/generation tăng lâu dài; không tự tăng nếu chưa có cơ chế cấp
    -- giá trị.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành websocket_tickets_workspace_id_user_id_grant_generation_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, user_id, grant_generation) REFERENCES membership_grants(workspace_id, user_id,
    -- grant_generation)
    grant_generation bigint NOT NULL,

    -- Phiên bản quyền workspace chụp trong ticket, phải khớp hiện hành khi consume realtime admission.
    -- bigint: số nguyên có dấu 64 bit, phù hợp bộ đếm/generation tăng lâu dài; không tự tăng nếu chưa có cơ chế cấp
    -- giá trị.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành websocket_tickets_workspace_authorization_version_check: CHECK chỉ chặn khi biểu thức là
    -- FALSE; NULL/UNKNOWN vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((workspace_authorization_version > 0))
    workspace_authorization_version bigint NOT NULL CHECK (workspace_authorization_version>0),

    -- Phiên bản quyền membership chụp trong ticket, dùng vô hiệu ngữ cảnh cũ sau mutation quyền.
    -- bigint: số nguyên có dấu 64 bit, phù hợp bộ đếm/generation tăng lâu dài; không tự tăng nếu chưa có cơ chế cấp
    -- giá trị.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành websocket_tickets_membership_authorization_version_check: CHECK chỉ chặn khi biểu thức là
    -- FALSE; NULL/UNKNOWN vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((membership_authorization_version > 0))
    membership_authorization_version bigint NOT NULL CHECK (membership_authorization_version>0),

    -- Thời điểm phát hành phiên/grant/credential/ticket, làm gốc tính TTL theo loại bản ghi.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành websocket_tickets_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên
    -- phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((expires_at = (issued_at + '00:00:30'::interval)))
    issued_at timestamptz NOT NULL,

    -- Deadline issued_at + 30 giây cho admission realtime; consume một winner và recheck session/grant/workspace trước
    -- mở socket.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành websocket_tickets_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên
    -- phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((expires_at = (issued_at + '00:00:30'::interval)))
    expires_at timestamptz NOT NULL,

    -- Thời điểm vé một lần đã được consume thành công; CAS và mốc một chiều ngăn dùng lại cùng ticket.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    consumed_at timestamptz,

    -- Thời điểm thu hồi quyền/credential; NULL nghĩa chưa ghi nhận thu hồi, không đồng nghĩa mọi điều kiện xác thực
    -- khác còn hợp lệ.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    revoked_at timestamptz,

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(user_id,session_id) REFERENCES sessions(user_id,session_id),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,user_id,grant_generation) REFERENCES membership_grants,

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    CHECK (expires_at=issued_at+interval '30 seconds')
);
/* Audit global có workspace NULL; session luôn phải thuộc actor, không cascade mất bằng chứng. */
-- Bảng audit_events: Nhật ký kiểm toán ai làm gì, ở đâu và kết quả ra sao. Hỗ trợ sự kiện IAM toàn cục với
-- workspace NULL, giữ tương quan request; chỉ lưu phần thay đổi đã loại bỏ dữ liệu nhạy cảm.
CREATE TABLE audit_events (
    -- Identity duy nhất của một bản ghi kiểm toán, dùng phân trang và tương quan lịch sử.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành audit_events_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì uniqueness áp
    -- dụng cho cả tổ hợp.
    -- PRIMARY KEY (audit_event_id)
    audit_event_id uuid PRIMARY KEY,

    -- Workspace của sự kiện kiểm toán; NULL chỉ cho IAM/global audit, không được fanout global log cho Admin
    -- workspace.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    -- Ràng buộc hiện hành audit_events_workspace_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ hợp có workspace_id giữ
    -- quan hệ trong đúng tenant, không thay kiểm quyền hiện hành. FK MATCH SIMPLE mặc định bỏ kiểm khi có thành phần
    -- NULL; CHECK shape riêng vẫn phải đạt.
    -- FOREIGN KEY (workspace_id) REFERENCES workspaces(workspace_id)
    workspace_id uuid REFERENCES workspaces,

    -- Principal thực hiện thao tác; NULL cho anonymous/system event hợp lệ, nhưng có session_id thì actor phải đúng
    -- chủ phiên.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    -- Ràng buộc hiện hành audit_events_actor_user_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ hợp có workspace_id giữ
    -- quan hệ trong đúng tenant, không thay kiểm quyền hiện hành. FK MATCH SIMPLE mặc định bỏ kiểm khi có thành phần
    -- NULL; CHECK shape riêng vẫn phải đạt.
    -- FOREIGN KEY (actor_user_id) REFERENCES users(user_id)
    -- Ràng buộc hiện hành audit_events_actor_user_id_session_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ hợp có
    -- workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành. FK MATCH SIMPLE mặc định bỏ kiểm
    -- khi có thành phần NULL; CHECK shape riêng vẫn phải đạt.
    -- FOREIGN KEY (actor_user_id, session_id) REFERENCES sessions(user_id, session_id)
    -- Ràng buộc hiện hành audit_events_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên phải
    -- phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK (((session_id IS NULL) OR (actor_user_id IS NOT NULL)))
    actor_user_id uuid REFERENCES users,

    -- Identity một phiên đăng nhập; dùng gắn thao tác hoặc ticket với đúng principal, không phải raw token xác thực.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    -- Ràng buộc hiện hành audit_events_actor_user_id_session_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ hợp có
    -- workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành. FK MATCH SIMPLE mặc định bỏ kiểm
    -- khi có thành phần NULL; CHECK shape riêng vẫn phải đạt.
    -- FOREIGN KEY (actor_user_id, session_id) REFERENCES sessions(user_id, session_id)
    -- Ràng buộc hiện hành audit_events_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên phải
    -- phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK (((session_id IS NULL) OR (actor_user_id IS NOT NULL)))
    -- Ràng buộc hiện hành audit_events_session_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ hợp có workspace_id giữ
    -- quan hệ trong đúng tenant, không thay kiểm quyền hiện hành. FK MATCH SIMPLE mặc định bỏ kiểm khi có thành phần
    -- NULL; CHECK shape riêng vẫn phải đạt.
    -- FOREIGN KEY (session_id) REFERENCES sessions(session_id)
    session_id uuid REFERENCES sessions,

    -- Loại sự kiện được audit/outbox/webhook sử dụng; ý nghĩa/allowlist phụ thuộc bảng và schema contract.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    event_type text NOT NULL,

    -- Kết quả kiểm toán của thao tác như thành công/từ chối/lỗi theo event contract; không mặc định là trạng thái
    -- command vật lý.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    outcome text NOT NULL,

    -- Loại resource được audit chụp lại; đi cùng resource_id như snapshot lịch sử, không là authority hoặc FK đa hình
    -- để cấp quyền.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    -- Ràng buộc hiện hành audit_events_check1: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên phải
    -- phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK (((resource_type IS NULL) = (resource_id IS NULL)))
    resource_type text,

    -- Identity resource được audit chụp ở thời điểm thao tác; có thể không còn live resource sau retention nhưng không
    -- cấp quyền truy cập.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    -- Ràng buộc hiện hành audit_events_check1: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên phải
    -- phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK (((resource_type IS NULL) = (resource_id IS NULL)))
    resource_id text,

    -- Identity tương quan request/flow để nối audit và intent/result; không chứa raw token, email hoặc payload nhạy
    -- cảm.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    correlation_id uuid NOT NULL,

    -- Thời điểm nghiệp vụ/sự kiện diễn ra để sắp xếp timeline; không mặc định bằng thời điểm fanout hoặc provider phản
    -- hồi.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- NOT NULL: bắt buộc có giá trị.
    -- DEFAULT transaction_timestamp(): thời điểm bắt đầu transaction, giữ nguyên trong transaction; không phải đồng hồ
    -- thay đổi theo từng statement.
    occurred_at timestamptz NOT NULL DEFAULT transaction_timestamp(),

    -- Mã nguyên nhân ổn định để giải thích kết quả/transition; phải là nội dung an toàn, không chứa raw lỗi/secret.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    reason_code text,

    -- Phần thay đổi metadata đã loại bỏ secret/PII theo audit policy; producer chịu trách nhiệm chọn trường trước ghi
    -- JSON.
    -- jsonb: tài liệu JSON lưu dạng nhị phân; kiểm object/scalar không thay validation đầy đủ cấu trúc và tham chiếu
    -- nghiệp vụ.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    redacted_diff jsonb,

    -- Loại client khởi tạo phiên/thao tác; enum của từng bảng phân biệt WEB, ANDROID và UNKNOWN khi được phép.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành audit_events_client_type_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua,
    -- nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((client_type = ANY (ARRAY['WEB'::text, 'ANDROID'::text, 'UNKNOWN'::text])))
    client_type text NOT NULL CHECK (client_type IN ('WEB','ANDROID','UNKNOWN')),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(actor_user_id,session_id) REFERENCES sessions(user_id,session_id),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    CHECK (session_id IS NULL OR actor_user_id IS NOT NULL),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    CHECK ((resource_type IS NULL)=(resource_id IS NULL))
);
/* Workspace/time phục vụ history; global retention dùng time trước identity riêng. */
CREATE INDEX ix_audit_workspace_time ON audit_events(workspace_id,occurred_at DESC,audit_event_id);
CREATE INDEX ix_audit_retention ON audit_events(occurred_at,audit_event_id);
