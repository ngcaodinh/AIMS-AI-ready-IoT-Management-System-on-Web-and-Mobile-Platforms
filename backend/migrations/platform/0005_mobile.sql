/* Bản chú thích để đọc: ràng buộc hiện hành lấy từ manifest sau mọi forward migration.
 * Runner thực thi byte bất biến trong applied_sql và so token SQL với bản này; không sửa ledger.
 */
/* Push và enrollment cùng tenant database; không phụ thuộc push permission để onboarding.
 * Ciphertext chỉ là interface lưu trữ; key custody ngoài DB cần nghiệm thu trước dùng thật.
 */
-- Bảng push_installations: Một cài đặt Android với proof, provider token mã hóa và binding user/session hiện hành.
-- Generation/sequence phục vụ rebind, token rotate và tránh cleanup phiên cũ làm mất binding mới.
CREATE TABLE push_installations (
    -- Identity một cài đặt app Android, không đồng nghĩa user hoặc hardware device; rebind cần proof của installation.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành push_installations_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì uniqueness
    -- áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (installation_id)
    installation_id uuid PRIMARY KEY,

    -- Digest proof của một installation, dùng xác minh rebind/token update; không chỉ tin installation_id do client
    -- khai.
    -- bytea: dãy byte nhị phân; tên digest/ciphertext mô tả mục đích, bản thân kiểu không băm hoặc mã hóa dữ liệu.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành push_installations_installation_proof_digest_check: CHECK chỉ chặn khi biểu thức là FALSE;
    -- NULL/UNKNOWN vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((octet_length(installation_proof_digest) = 32))
    installation_proof_digest bytea NOT NULL CHECK(octet_length(installation_proof_digest)=32),

    -- Nền tảng installation được triển khai, hiện ANDROID; không tự mở scope iOS đã hoãn.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành push_installations_platform_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn
    -- qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((platform = 'ANDROID'::text))
    platform text NOT NULL CHECK(platform='ANDROID'),

    -- Provider push token đã mã hóa; chỉ adapter gửi push được giải mã theo custody, không trả ra UI/log.
    -- bytea: dãy byte nhị phân; tên digest/ciphertext mô tả mục đích, bản thân kiểu không băm hoặc mã hóa dữ liệu.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    -- Ràng buộc hiện hành push_installations_check1: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên
    -- phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((num_nonnulls(token_ciphertext, token_digest, encryption_key_reference) = ANY (ARRAY[0, 3])))
    token_ciphertext bytea,

    -- Digest 32 byte của provider push token hiện hành, phục vụ dedupe token giữa installation; raw token nằm ở
    -- ciphertext.
    -- bytea: dãy byte nhị phân; tên digest/ciphertext mô tả mục đích, bản thân kiểu không băm hoặc mã hóa dữ liệu.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    -- Ràng buộc hiện hành push_installations_check1: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên
    -- phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((num_nonnulls(token_ciphertext, token_digest, encryption_key_reference) = ANY (ARRAY[0, 3])))
    -- Ràng buộc hiện hành push_installations_token_digest_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN
    -- vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((octet_length(token_digest) = 32))
    token_digest bytea CHECK(octet_length(token_digest)=32),

    -- Tham chiếu/version của khóa dùng giải mã ciphertext, không chứa key material; NULL phải đồng bộ với nhánh không
    -- có ciphertext.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    -- Ràng buộc hiện hành push_installations_check1: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên
    -- phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((num_nonnulls(token_ciphertext, token_digest, encryption_key_reference) = ANY (ARRAY[0, 3])))
    encryption_key_reference text,

    -- Thế hệ provider token của installation; attempt giữ generation để giải thích token rotate và reply cũ.
    -- bigint: số nguyên có dấu 64 bit, phù hợp bộ đếm/generation tăng lâu dài; không tự tăng nếu chưa có cơ chế cấp
    -- giá trị.
    -- NOT NULL: bắt buộc có giá trị.
    -- DEFAULT 0: giá trị dùng khi INSERT bỏ qua cột; không thay NULL được truyền tường minh và không tự áp lại khi
    -- UPDATE.
    -- Ràng buộc hiện hành push_installations_token_generation_check: CHECK chỉ chặn khi biểu thức là FALSE;
    -- NULL/UNKNOWN vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((token_generation >= 0))
    token_generation bigint NOT NULL DEFAULT 0 CHECK(token_generation>=0),

    -- Thế hệ gắn user/session của installation; delivery chụp làm fence, không đưa vào dedupe
    -- notification/installation.
    -- bigint: số nguyên có dấu 64 bit, phù hợp bộ đếm/generation tăng lâu dài; không tự tăng nếu chưa có cơ chế cấp
    -- giá trị.
    -- NOT NULL: bắt buộc có giá trị.
    -- DEFAULT 0: giá trị dùng khi INSERT bỏ qua cột; không thay NULL được truyền tường minh và không tự áp lại khi
    -- UPDATE.
    -- Ràng buộc hiện hành push_installations_binding_generation_check: CHECK chỉ chặn khi biểu thức là FALSE;
    -- NULL/UNKNOWN vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((binding_generation >= 0))
    binding_generation bigint NOT NULL DEFAULT 0 CHECK(binding_generation>=0),

    -- Sequence cập nhật từ installation để từ chối update/rebind tới trễ, không dùng arrival time làm last-write-wins.
    -- bigint: số nguyên có dấu 64 bit, phù hợp bộ đếm/generation tăng lâu dài; không tự tăng nếu chưa có cơ chế cấp
    -- giá trị.
    -- NOT NULL: bắt buộc có giá trị.
    -- DEFAULT 0: giá trị dùng khi INSERT bỏ qua cột; không thay NULL được truyền tường minh và không tự áp lại khi
    -- UPDATE.
    -- Ràng buộc hiện hành push_installations_client_sequence_check: CHECK chỉ chặn khi biểu thức là FALSE;
    -- NULL/UNKNOWN vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((client_sequence >= 0))
    client_sequence bigint NOT NULL DEFAULT 0 CHECK(client_sequence>=0),

    -- Permission Android do app báo: UNKNOWN/GRANTED/DENIED/NOT_DETERMINED; không tự nâng preference hoặc session
    -- quyền.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành push_installations_permission_state_check: CHECK chỉ chặn khi biểu thức là FALSE;
    -- NULL/UNKNOWN vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((permission_state = ANY (ARRAY['UNKNOWN'::text, 'GRANTED'::text, 'DENIED'::text,
    -- 'NOT_DETERMINED'::text])))
    permission_state text NOT NULL CHECK(permission_state IN ('UNKNOWN','GRANTED','DENIED','NOT_DETERMINED')),

    -- Cờ cho phép nhận thông báo theo installation hoặc preference; còn phải giao với permission, binding và quyền
    -- hiện hành.
    -- boolean: cờ logic true/false; NULL là trạng thái riêng nếu cột cho phép.
    -- NOT NULL: bắt buộc có giá trị.
    -- DEFAULT false: giá trị dùng khi INSERT bỏ qua cột; không thay NULL được truyền tường minh và không tự áp lại khi
    -- UPDATE.
    enabled boolean NOT NULL DEFAULT false,

    -- Phiên bản app do installation khai để chẩn đoán tương thích; không phải bằng chứng xác thực hoặc quyền.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    app_version text,

    -- Tài khoản hiện đang gắn với installation push; phải cùng active_session_id hoặc cùng NULL khi chưa bind.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    -- Ràng buộc hiện hành push_installations_active_user_id_active_session_id_fkey: khóa ngoại giữ đúng bản ghi cha;
    -- tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành. FK MATCH SIMPLE mặc định
    -- bỏ kiểm khi có thành phần NULL; CHECK shape riêng vẫn phải đạt.
    -- FOREIGN KEY (active_user_id, active_session_id) REFERENCES sessions(user_id, session_id)
    -- Ràng buộc hiện hành push_installations_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên
    -- phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK (((active_user_id IS NULL) = (active_session_id IS NULL)))
    active_user_id uuid,

    -- Phiên đang sở hữu binding push hiện hành; cleanup phiên cũ phải CAS đúng binding để không xóa binding phiên mới.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    -- Ràng buộc hiện hành push_installations_active_user_id_active_session_id_fkey: khóa ngoại giữ đúng bản ghi cha;
    -- tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành. FK MATCH SIMPLE mặc định
    -- bỏ kiểm khi có thành phần NULL; CHECK shape riêng vẫn phải đạt.
    -- FOREIGN KEY (active_user_id, active_session_id) REFERENCES sessions(user_id, session_id)
    -- Ràng buộc hiện hành push_installations_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên
    -- phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK (((active_user_id IS NULL) = (active_session_id IS NULL)))
    active_session_id uuid,

    -- Thời điểm cập nhật gần nhất do đường ghi quản lý; không mặc định SQL tự cập nhật nếu không có trigger tương ứng.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- NOT NULL: bắt buộc có giá trị.
    -- DEFAULT transaction_timestamp(): thời điểm bắt đầu transaction, giữ nguyên trong transaction; không phải đồng hồ
    -- thay đổi theo từng statement.
    updated_at timestamptz NOT NULL DEFAULT transaction_timestamp(),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(active_user_id,active_session_id) REFERENCES sessions(user_id,session_id),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    CHECK((active_user_id IS NULL)=(active_session_id IS NULL)),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    CHECK(num_nonnulls(token_ciphertext,token_digest,encryption_key_reference) IN (0,3))
);
/* Một provider token hiện hành cho một installation; raw token không là khóa/index. */
CREATE UNIQUE INDEX uq_push_installations_token ON push_installations(token_digest) WHERE token_digest IS NOT NULL;
-- Bảng workspace_notification_preferences: Tùy chọn nhận push theo user/workspace, tách khỏi permission hệ điều
-- hành của installation. Hàng vắng mang default theo contract; lưu lần đầu bắt đầu revision 1.
CREATE TABLE workspace_notification_preferences (
    -- Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền
    -- của người gọi.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành workspace_notification_preferences_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều
    -- cột thì uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, user_id)
    -- Ràng buộc hiện hành workspace_notification_preferences_workspace_id_user_id_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, user_id) REFERENCES memberships(workspace_id, user_id)
    workspace_id uuid NOT NULL,

    -- Identity tài khoản liên quan; khi đi cùng workspace_id phải tham chiếu đúng membership của workspace.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành workspace_notification_preferences_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều
    -- cột thì uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, user_id)
    -- Ràng buộc hiện hành workspace_notification_preferences_workspace_id_user_id_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, user_id) REFERENCES memberships(workspace_id, user_id)
    user_id uuid NOT NULL,

    -- Cờ cho phép nhận thông báo theo installation hoặc preference; còn phải giao với permission, binding và quyền
    -- hiện hành.
    -- boolean: cờ logic true/false; NULL là trạng thái riêng nếu cột cho phép.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    enabled boolean NOT NULL,

    -- Mức độ Event thấp nhất người dùng cho phép nhận push trong workspace này.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành workspace_notification_preferences_minimum_severity_check: CHECK chỉ chặn khi biểu thức là
    -- FALSE; NULL/UNKNOWN vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((minimum_severity = ANY (ARRAY['INFO'::text, 'WARNING'::text, 'CRITICAL'::text])))
    minimum_severity text NOT NULL CHECK(minimum_severity IN ('INFO','WARNING','CRITICAL')),

    -- Phiên bản chỉnh sửa bản ghi dùng cho CAS/If-Match hoặc đối soát; bên ghi chịu trách nhiệm cập nhật theo đúng
    -- transaction contract.
    -- bigint: số nguyên có dấu 64 bit, phù hợp bộ đếm/generation tăng lâu dài; không tự tăng nếu chưa có cơ chế cấp
    -- giá trị.
    -- NOT NULL: bắt buộc có giá trị.
    -- DEFAULT 1: giá trị dùng khi INSERT bỏ qua cột; không thay NULL được truyền tường minh và không tự áp lại khi
    -- UPDATE.
    -- Ràng buộc hiện hành workspace_notification_preferences_revision_check: CHECK chỉ chặn khi biểu thức là FALSE;
    -- NULL/UNKNOWN vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((revision > 0))
    revision bigint NOT NULL DEFAULT 1 CHECK(revision>0),

    -- Thời điểm cập nhật gần nhất do đường ghi quản lý; không mặc định SQL tự cập nhật nếu không có trigger tương ứng.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- NOT NULL: bắt buộc có giá trị.
    -- DEFAULT transaction_timestamp(): thời điểm bắt đầu transaction, giữ nguyên trong transaction; không phải đồng hồ
    -- thay đổi theo từng statement.
    updated_at timestamptz NOT NULL DEFAULT transaction_timestamp(),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    PRIMARY KEY(workspace_id,user_id),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,user_id) REFERENCES memberships
);
-- Bảng push_deliveries: Nghĩa vụ giao một notification tới một installation tại fanout snapshot. Dedupe không chứa
-- binding generation; rebind không tạo thêm delivery cho cùng notification/installation.
CREATE TABLE push_deliveries (
    -- Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền
    -- của người gọi.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành push_deliveries_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì uniqueness áp
    -- dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, push_delivery_id)
    -- Ràng buộc hiện hành push_deliveries_workspace_id_notification_id_installation_i_key: không trùng tổ hợp giá trị
    -- được nêu; các cột riêng lẻ vẫn có thể lặp khi khóa có nhiều cột.
    -- UNIQUE (workspace_id, notification_id, installation_id)
    -- Ràng buộc hiện hành push_deliveries_workspace_id_notification_id_recipient_use_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, notification_id, recipient_user_id) REFERENCES notifications(workspace_id,
    -- notification_id, recipient_user_id)
    workspace_id uuid NOT NULL,

    -- Identity nghĩa vụ giao push, giữ nguyên qua mọi send attempt và phản hồi provider.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành push_deliveries_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì uniqueness áp
    -- dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, push_delivery_id)
    push_delivery_id uuid NOT NULL,

    -- Identity mục inbox của recipient, là gốc fanout push/deep link; không thay Event source hoặc occurrence
    -- identity.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành push_deliveries_workspace_id_notification_id_installation_i_key: không trùng tổ hợp giá trị
    -- được nêu; các cột riêng lẻ vẫn có thể lặp khi khóa có nhiều cột.
    -- UNIQUE (workspace_id, notification_id, installation_id)
    -- Ràng buộc hiện hành push_deliveries_workspace_id_notification_id_recipient_use_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, notification_id, recipient_user_id) REFERENCES notifications(workspace_id,
    -- notification_id, recipient_user_id)
    notification_id uuid NOT NULL,

    -- Identity một cài đặt app Android, không đồng nghĩa user hoặc hardware device; rebind cần proof của installation.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành push_deliveries_installation_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ hợp có
    -- workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (installation_id) REFERENCES push_installations(installation_id)
    -- Ràng buộc hiện hành push_deliveries_workspace_id_notification_id_installation_i_key: không trùng tổ hợp giá trị
    -- được nêu; các cột riêng lẻ vẫn có thể lặp khi khóa có nhiều cột.
    -- UNIQUE (workspace_id, notification_id, installation_id)
    installation_id uuid NOT NULL REFERENCES push_installations,

    -- Thành viên nhận inbox/push; chỉ chính recipient được hưởng quyền đọc và thay đổi read state của inbox.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành push_deliveries_workspace_id_notification_id_recipient_use_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, notification_id, recipient_user_id) REFERENCES notifications(workspace_id,
    -- notification_id, recipient_user_id)
    recipient_user_id uuid NOT NULL,

    -- Thế hệ gắn user/session của installation; delivery chụp làm fence, không đưa vào dedupe
    -- notification/installation.
    -- bigint: số nguyên có dấu 64 bit, phù hợp bộ đếm/generation tăng lâu dài; không tự tăng nếu chưa có cơ chế cấp
    -- giá trị.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành push_deliveries_binding_generation_check: CHECK chỉ chặn khi biểu thức là FALSE;
    -- NULL/UNKNOWN vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((binding_generation > 0))
    binding_generation bigint NOT NULL CHECK(binding_generation>0),

    -- Tiến trình PENDING/SENDING/RETRY_WAIT và terminal ACCEPTED/FAILED/EXPIRED/SUPPRESSED; ACCEPTED chỉ chứng minh
    -- provider nhận.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- DEFAULT 'PENDING'::text: giá trị dùng khi INSERT bỏ qua cột; không thay NULL được truyền tường minh và không tự
    -- áp lại khi UPDATE.
    -- Ràng buộc hiện hành push_deliveries_state_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua,
    -- nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((state = ANY (ARRAY['PENDING'::text, 'SENDING'::text, 'RETRY_WAIT'::text, 'ACCEPTED'::text,
    -- 'FAILED'::text, 'EXPIRED'::text, 'SUPPRESSED'::text])))
    state text NOT NULL DEFAULT 'PENDING' CHECK(state IN ('PENDING','SENDING','RETRY_WAIT','ACCEPTED','FAILED','EXPIRED','SUPPRESSED')),

    -- Bản sao Notification.created_at tại fanout, không là thời điểm worker gửi lần đầu.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành push_deliveries_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên phải
    -- phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((expires_at = (created_at + '01:00:00'::interval)))
    created_at timestamptz NOT NULL,

    -- Hạn gửi Notification.created_at + 1 giờ, độc lập retention history 30 ngày; rebind/retry không kéo dài TTL.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành push_deliveries_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên phải
    -- phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((expires_at = (created_at + '01:00:00'::interval)))
    expires_at timestamptz NOT NULL,

    -- Thời điểm quan sát trạng thái kết thúc của command/delivery; không thay gốc expiry hoặc gốc retention.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    terminal_at timestamptz,

    -- Thời điểm sớm nhất được thử gửi tiếp; không được gửi sớm hơn mốc này hoặc vượt expiry/budget của parent.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    next_attempt_at timestamptz,

    -- Hạn thuê xử lý hiện hành của worker; lease hết không chứng minh network side effect chưa xảy ra.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    lease_until timestamptz,

    -- Thế hệ lease tăng khi claim/takeover, dùng CAS để worker cũ không settle kết quả của thế hệ mới.
    -- bigint: số nguyên có dấu 64 bit, phù hợp bộ đếm/generation tăng lâu dài; không tự tăng nếu chưa có cơ chế cấp
    -- giá trị.
    -- NOT NULL: bắt buộc có giá trị.
    -- DEFAULT 0: giá trị dùng khi INSERT bỏ qua cột; không thay NULL được truyền tường minh và không tự áp lại khi
    -- UPDATE.
    -- Ràng buộc hiện hành push_deliveries_lease_generation_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN
    -- vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((lease_generation >= 0))
    lease_generation bigint NOT NULL DEFAULT 0 CHECK(lease_generation>=0),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    PRIMARY KEY(workspace_id,push_delivery_id),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    UNIQUE(workspace_id,notification_id,installation_id),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,notification_id,recipient_user_id) REFERENCES notifications(workspace_id,notification_id,recipient_user_id),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    CHECK(expires_at=created_at+interval '1 hour')
);
/* Retry theo thời gian, tenant giữ trong khóa để truy vết và claim không nhầm scope. */
CREATE INDEX ix_push_deliveries_due ON push_deliveries(next_attempt_at,workspace_id,push_delivery_id) WHERE state IN ('PENDING','RETRY_WAIT');
-- Bảng push_delivery_attempts: Ý định gửi push từng lần, tiêu hao ngân sách trước network call. Lưu token
-- generation và outcome quan sát; provider ACCEPTED không có nghĩa người dùng đã đọc.
CREATE TABLE push_delivery_attempts (
    -- Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền
    -- của người gọi.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành push_delivery_attempts_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, push_delivery_id, attempt_number)
    -- Ràng buộc hiện hành push_delivery_attempts_workspace_id_push_delivery_id_fkey: khóa ngoại giữ đúng bản ghi cha;
    -- tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, push_delivery_id) REFERENCES push_deliveries(workspace_id, push_delivery_id)
    workspace_id uuid NOT NULL,

    -- Identity nghĩa vụ giao push, giữ nguyên qua mọi send attempt và phản hồi provider.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành push_delivery_attempts_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, push_delivery_id, attempt_number)
    -- Ràng buộc hiện hành push_delivery_attempts_workspace_id_push_delivery_id_fkey: khóa ngoại giữ đúng bản ghi cha;
    -- tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, push_delivery_id) REFERENCES push_deliveries(workspace_id, push_delivery_id)
    push_delivery_id uuid NOT NULL,

    -- Số thứ tự send intent của một delivery, bắt đầu 1; PK và admission guard bảo vệ thứ tự/ngân sách.
    -- integer: số nguyên có dấu 32 bit; CHECK giới hạn miền nghiệp vụ thay vì chỉ dựa phạm vi kiểu.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành push_delivery_attempts_attempt_number_check: CHECK chỉ chặn khi biểu thức là FALSE;
    -- NULL/UNKNOWN vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK (((attempt_number >= 1) AND (attempt_number <= 4)))
    -- Ràng buộc hiện hành push_delivery_attempts_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, push_delivery_id, attempt_number)
    attempt_number integer NOT NULL CHECK(attempt_number BETWEEN 1 AND 4),

    -- Thời điểm lưu ý định trước side effect bên ngoài DB; dùng tính ngân sách/expiry và phục hồi khi mất ACK.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    intent_at timestamptz NOT NULL,

    -- Thế hệ provider token của installation; attempt giữ generation để giải thích token rotate và reply cũ.
    -- bigint: số nguyên có dấu 64 bit, phù hợp bộ đếm/generation tăng lâu dài; không tự tăng nếu chưa có cơ chế cấp
    -- giá trị.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành push_delivery_attempts_token_generation_check: CHECK chỉ chặn khi biểu thức là FALSE;
    -- NULL/UNKNOWN vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((token_generation > 0))
    token_generation bigint NOT NULL CHECK(token_generation>0),

    -- Identity request/message do push provider trả để đối chiếu attempt; không lưu bearer header hoặc response
    -- secret.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    provider_request_id text,

    -- Kết quả quan sát INTENT/ACCEPTED/TRANSIENT_FAILURE/PERMANENT_FAILURE/UNKNOWN của một send intent; không đồng
    -- nghĩa recipient đã đọc.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành push_delivery_attempts_outcome_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN
    -- vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((outcome = ANY (ARRAY['INTENT'::text, 'ACCEPTED'::text, 'TRANSIENT_FAILURE'::text,
    -- 'PERMANENT_FAILURE'::text, 'UNKNOWN'::text])))
    outcome text NOT NULL CHECK(outcome IN ('INTENT','ACCEPTED','TRANSIENT_FAILURE','PERMANENT_FAILURE','UNKNOWN')),

    -- Thời điểm quan sát được dữ liệu/kết quả; nguồn và ý nghĩa được quy định theo bảng, không mặc định là thời gian
    -- commit.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    observed_at timestamptz,

    -- Khoảng chờ retry tiếp theo tính bằng giây đã được adapter/policy chọn; không phải timestamp tuyệt đối.
    -- integer: số nguyên có dấu 32 bit; CHECK giới hạn miền nghiệp vụ thay vì chỉ dựa phạm vi kiểu.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    -- Ràng buộc hiện hành push_delivery_attempts_next_delay_seconds_check: CHECK chỉ chặn khi biểu thức là FALSE;
    -- NULL/UNKNOWN vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((next_delay_seconds >= 0))
    next_delay_seconds integer CHECK(next_delay_seconds>=0),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    PRIMARY KEY(workspace_id,push_delivery_id,attempt_number),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,push_delivery_id) REFERENCES push_deliveries
);
-- Bảng enrollment_sessions: Ý định onboarding/đổi Wi-Fi gắn device, actor grant, installation và proof, hạn 10
-- phút. Không lưu PoP/SSID/mật khẩu Wi-Fi và không phụ thuộc quyền nhận push.
CREATE TABLE enrollment_sessions (
    -- Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền
    -- của người gọi.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành enrollment_sessions_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, enrollment_session_id)
    -- Ràng buộc hiện hành enrollment_sessions_workspace_id_actor_user_id_actor_grant_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, actor_user_id, actor_grant_generation) REFERENCES membership_grants(workspace_id,
    -- user_id, grant_generation)
    -- Ràng buộc hiện hành enrollment_sessions_workspace_id_device_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ hợp có
    -- workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, device_id) REFERENCES devices(workspace_id, device_id)
    -- Ràng buộc hiện hành enrollment_sessions_workspace_id_enrollment_session_id_devi_key: không trùng tổ hợp giá trị
    -- được nêu; các cột riêng lẻ vẫn có thể lặp khi khóa có nhiều cột.
    -- UNIQUE (workspace_id, enrollment_session_id, device_id)
    -- Ràng buộc hiện hành enrollment_sessions_workspace_id_provisioning_operation_id_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, provisioning_operation_id, device_id) REFERENCES
    -- provisioning_operations(workspace_id, provisioning_operation_id, device_id)
    workspace_id uuid NOT NULL,

    -- Identity ý định onboarding/đổi Wi-Fi, dùng polling, proof binding và liên kết cleanup/guard.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành enrollment_sessions_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, enrollment_session_id)
    -- Ràng buộc hiện hành enrollment_sessions_workspace_id_enrollment_session_id_devi_key: không trùng tổ hợp giá trị
    -- được nêu; các cột riêng lẻ vẫn có thể lặp khi khóa có nhiều cột.
    -- UNIQUE (workspace_id, enrollment_session_id, device_id)
    enrollment_session_id uuid NOT NULL,

    -- Identity thiết bị toàn cục để resolve MQTT và registry; kết hợp workspace_id bảo vệ mọi tham chiếu trong đúng
    -- tenant.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành enrollment_sessions_workspace_id_device_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ hợp có
    -- workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, device_id) REFERENCES devices(workspace_id, device_id)
    -- Ràng buộc hiện hành enrollment_sessions_workspace_id_enrollment_session_id_devi_key: không trùng tổ hợp giá trị
    -- được nêu; các cột riêng lẻ vẫn có thể lặp khi khóa có nhiều cột.
    -- UNIQUE (workspace_id, enrollment_session_id, device_id)
    -- Ràng buộc hiện hành enrollment_sessions_workspace_id_provisioning_operation_id_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, provisioning_operation_id, device_id) REFERENCES
    -- provisioning_operations(workspace_id, provisioning_operation_id, device_id)
    device_id uuid NOT NULL,

    -- Tài khoản thực hiện hoặc khởi tạo thao tác, phục vụ kiểm quyền và truy vết; không lấy authority chỉ từ ID client
    -- gửi.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành enrollment_sessions_workspace_id_actor_user_id_actor_grant_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, actor_user_id, actor_grant_generation) REFERENCES membership_grants(workspace_id,
    -- user_id, grant_generation)
    actor_user_id uuid NOT NULL,

    -- Grant actor được chụp lúc tạo enrollment, giúp kiểm tác vụ cũ sau remove/rejoin.
    -- bigint: số nguyên có dấu 64 bit, phù hợp bộ đếm/generation tăng lâu dài; không tự tăng nếu chưa có cơ chế cấp
    -- giá trị.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành enrollment_sessions_workspace_id_actor_user_id_actor_grant_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, actor_user_id, actor_grant_generation) REFERENCES membership_grants(workspace_id,
    -- user_id, grant_generation)
    actor_grant_generation bigint NOT NULL,

    -- Installation mà enrollment gắn với; cố ý không FK tới push_installations vì onboarding không đòi quyền push.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    client_installation_id uuid NOT NULL,

    -- Digest 32 byte của proof enrollment do installation nắm, dùng chứng minh quyền thao tác phiên; không thay QR PoP
    -- hoặc physical proof.
    -- bytea: dãy byte nhị phân; tên digest/ciphertext mô tả mục đích, bản thân kiểu không băm hoặc mã hóa dữ liệu.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành enrollment_sessions_enrollment_proof_digest_check: CHECK chỉ chặn khi biểu thức là FALSE;
    -- NULL/UNKNOWN vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((octet_length(enrollment_proof_digest) = 32))
    enrollment_proof_digest bytea NOT NULL CHECK(octet_length(enrollment_proof_digest)=32),

    -- Chế độ enrollment INITIAL/WIFI_RECONFIGURE; đổi Wi-Fi không tự tạo/thu hồi MQTT credential hiện hành.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành enrollment_sessions_check2: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên
    -- phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK (((mode <> 'WIFI_RECONFIGURE'::text) OR (provisioning_operation_id IS NULL)))
    -- Ràng buộc hiện hành enrollment_sessions_mode_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua,
    -- nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((mode = ANY (ARRAY['INITIAL'::text, 'WIFI_RECONFIGURE'::text])))
    mode text NOT NULL CHECK(mode IN ('INITIAL','WIFI_RECONFIGURE')),

    -- CREATED→BLE_CONNECTED→WIFI_JOINED→CLOUD_CONNECTING→COMPLETED hoặc FAILED/CANCELLED/EXPIRED; chỉ trusted cloud
    -- evidence mới được xác nhận COMPLETED.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- DEFAULT 'CREATED'::text: giá trị dùng khi INSERT bỏ qua cột; không thay NULL được truyền tường minh và không tự
    -- áp lại khi UPDATE.
    -- Ràng buộc hiện hành enrollment_sessions_check1: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên
    -- phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK (((state = 'COMPLETED'::text) = (completed_at IS NOT NULL)))
    -- Ràng buộc hiện hành enrollment_sessions_state_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn
    -- qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((state = ANY (ARRAY['CREATED'::text, 'BLE_CONNECTED'::text, 'WIFI_JOINED'::text,
    -- 'CLOUD_CONNECTING'::text, 'COMPLETED'::text, 'FAILED'::text, 'CANCELLED'::text, 'EXPIRED'::text])))
    state text NOT NULL DEFAULT 'CREATED' CHECK(state IN ('CREATED','BLE_CONNECTED','WIFI_JOINED','CLOUD_CONNECTING','COMPLETED','FAILED','CANCELLED','EXPIRED')),

    -- Thời điểm bắt đầu boot/enrollment/action hoặc hoạt động tương ứng, tùy ngữ nghĩa bảng.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành enrollment_sessions_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên
    -- phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((expires_at = (started_at + '00:10:00'::interval)))
    started_at timestamptz NOT NULL,

    -- Hạn phiên started_at + 10 phút; expiry không tự xóa guard khi broker cleanup còn thiếu proof.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành enrollment_sessions_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên
    -- phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((expires_at = (started_at + '00:10:00'::interval)))
    expires_at timestamptz NOT NULL,

    -- Identity công việc cấp credential, dùng claim một lần và gắn enrollment đúng device/generation.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    -- Ràng buộc hiện hành enrollment_sessions_check2: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên
    -- phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK (((mode <> 'WIFI_RECONFIGURE'::text) OR (provisioning_operation_id IS NULL)))
    -- Ràng buộc hiện hành enrollment_sessions_workspace_id_provisioning_operation_id_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành. FK MATCH SIMPLE mặc
    -- định bỏ kiểm khi có thành phần NULL; CHECK shape riêng vẫn phải đạt.
    -- FOREIGN KEY (workspace_id, provisioning_operation_id, device_id) REFERENCES
    -- provisioning_operations(workspace_id, provisioning_operation_id, device_id)
    provisioning_operation_id uuid,

    -- Thời điểm tác vụ hoặc enrollment được ghi nhận hoàn tất theo điều kiện của bảng; không lấy timer client làm bằng
    -- chứng.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    -- Ràng buộc hiện hành enrollment_sessions_check1: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên
    -- phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK (((state = 'COMPLETED'::text) = (completed_at IS NOT NULL)))
    completed_at timestamptz,

    -- Phiên bản chỉnh sửa bản ghi dùng cho CAS/If-Match hoặc đối soát; bên ghi chịu trách nhiệm cập nhật theo đúng
    -- transaction contract.
    -- bigint: số nguyên có dấu 64 bit, phù hợp bộ đếm/generation tăng lâu dài; không tự tăng nếu chưa có cơ chế cấp
    -- giá trị.
    -- NOT NULL: bắt buộc có giá trị.
    -- DEFAULT 1: giá trị dùng khi INSERT bỏ qua cột; không thay NULL được truyền tường minh và không tự áp lại khi
    -- UPDATE.
    -- Ràng buộc hiện hành enrollment_sessions_revision_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn
    -- qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((revision > 0))
    revision bigint NOT NULL DEFAULT 1 CHECK(revision>0),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    PRIMARY KEY(workspace_id,enrollment_session_id),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    UNIQUE(workspace_id,enrollment_session_id,device_id),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,device_id) REFERENCES devices(workspace_id,device_id),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,actor_user_id,actor_grant_generation) REFERENCES membership_grants,

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,provisioning_operation_id,device_id) REFERENCES provisioning_operations(workspace_id,provisioning_operation_id,device_id),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    CHECK(expires_at=started_at+interval '10 minutes'),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    CHECK((state='COMPLETED')=(completed_at IS NOT NULL)),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    CHECK(mode<>'WIFI_RECONFIGURE' OR provisioning_operation_id IS NULL)
);
-- Bảng enrollment_cleanup_operations: Công việc cleanup enrollment cùng bằng chứng revoke/disconnect. Tách khỏi
-- TTL của phiên để expiry không bị hiểu nhầm là cloud cleanup đã hoàn tất.
CREATE TABLE enrollment_cleanup_operations (
    -- Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền
    -- của người gọi.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành enrollment_cleanup_operations_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, enrollment_cleanup_operation_id)
    -- Ràng buộc hiện hành enrollment_cleanup_operations_workspace_id_enrollment_sess_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, enrollment_session_id, device_id) REFERENCES enrollment_sessions(workspace_id,
    -- enrollment_session_id, device_id)
    -- Ràng buộc hiện hành enrollment_cleanup_operations_workspace_id_enrollment_sessi_key: không trùng tổ hợp giá trị
    -- được nêu; các cột riêng lẻ vẫn có thể lặp khi khóa có nhiều cột.
    -- UNIQUE (workspace_id, enrollment_session_id)
    workspace_id uuid NOT NULL,

    -- Identity công việc cleanup của enrollment, dùng theo dõi proof và settlement độc lập TTL phiên.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành enrollment_cleanup_operations_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, enrollment_cleanup_operation_id)
    enrollment_cleanup_operation_id uuid NOT NULL,

    -- Identity ý định onboarding/đổi Wi-Fi, dùng polling, proof binding và liên kết cleanup/guard.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành enrollment_cleanup_operations_workspace_id_enrollment_sess_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, enrollment_session_id, device_id) REFERENCES enrollment_sessions(workspace_id,
    -- enrollment_session_id, device_id)
    -- Ràng buộc hiện hành enrollment_cleanup_operations_workspace_id_enrollment_sessi_key: không trùng tổ hợp giá trị
    -- được nêu; các cột riêng lẻ vẫn có thể lặp khi khóa có nhiều cột.
    -- UNIQUE (workspace_id, enrollment_session_id)
    enrollment_session_id uuid NOT NULL,

    -- Identity thiết bị toàn cục để resolve MQTT và registry; kết hợp workspace_id bảo vệ mọi tham chiếu trong đúng
    -- tenant.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành enrollment_cleanup_operations_workspace_id_enrollment_sess_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, enrollment_session_id, device_id) REFERENCES enrollment_sessions(workspace_id,
    -- enrollment_session_id, device_id)
    device_id uuid NOT NULL,

    -- Trạng thái xử lý bền vững của ledger/job/operation; không suy rằng enum hợp lệ tự chứng minh transition hợp lệ.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành enrollment_cleanup_operations_state_check: CHECK chỉ chặn khi biểu thức là FALSE;
    -- NULL/UNKNOWN vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((state = ANY (ARRAY['PENDING'::text, 'RUNNING'::text, 'SUCCEEDED'::text, 'FAILED'::text,
    -- 'NEEDS_ATTENTION'::text])))
    state text NOT NULL CHECK(state IN ('PENDING','RUNNING','SUCCEEDED','FAILED','NEEDS_ATTENTION')),

    -- Thời điểm lưu ý định trước side effect bên ngoài DB; dùng tính ngân sách/expiry và phục hồi khi mất ACK.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    intent_at timestamptz NOT NULL,

    -- Bằng chứng đã redact về broker xác nhận thu hồi; không suy chỉ ghi trạng thái DB là broker đã chặn credential.
    -- jsonb: tài liệu JSON lưu dạng nhị phân; kiểm object/scalar không thay validation đầy đủ cấu trúc và tham chiếu
    -- nghiệp vụ.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    broker_revoke_receipt jsonb,

    -- Bằng chứng đã redact về kết nối thiết bị bị ngắt theo cleanup/lifecycle protocol; cần giữ để settlement có căn
    -- cứ.
    -- jsonb: tài liệu JSON lưu dạng nhị phân; kiểm object/scalar không thay validation đầy đủ cấu trúc và tham chiếu
    -- nghiệp vụ.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    disconnect_receipt jsonb,

    -- Thời điểm nghĩa vụ vận hành được đối soát xong và có thể nhả guard/quota; NULL tiếp tục giữ nghĩa vụ chưa giải
    -- quyết.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    settled_at timestamptz,

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    PRIMARY KEY(workspace_id,enrollment_cleanup_operation_id),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    UNIQUE(workspace_id,enrollment_session_id),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,enrollment_session_id,device_id) REFERENCES enrollment_sessions(workspace_id,enrollment_session_id,device_id)
);
/* Guard khác TTL: expiry không chứng minh broker đã revoke/disconnect. */
-- Bảng device_enrollment_guards: Khóa nghiệp vụ giữ một thiết bị cho enrollment đang chưa giải quyết. Guard chỉ
-- được nhả khi hoàn tất hoặc cleanup có proof, không chỉ vì session đã hết hạn.
CREATE TABLE device_enrollment_guards (
    -- Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền
    -- của người gọi.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành device_enrollment_guards_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, device_id)
    -- Ràng buộc hiện hành device_enrollment_guards_workspace_id_device_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ
    -- hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, device_id) REFERENCES devices(workspace_id, device_id)
    -- Ràng buộc hiện hành device_enrollment_guards_workspace_id_enrollment_session_i_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, enrollment_session_id, device_id) REFERENCES enrollment_sessions(workspace_id,
    -- enrollment_session_id, device_id)
    workspace_id uuid NOT NULL,

    -- Identity thiết bị toàn cục để resolve MQTT và registry; kết hợp workspace_id bảo vệ mọi tham chiếu trong đúng
    -- tenant.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành device_enrollment_guards_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, device_id)
    -- Ràng buộc hiện hành device_enrollment_guards_workspace_id_device_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ
    -- hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, device_id) REFERENCES devices(workspace_id, device_id)
    -- Ràng buộc hiện hành device_enrollment_guards_workspace_id_enrollment_session_i_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, enrollment_session_id, device_id) REFERENCES enrollment_sessions(workspace_id,
    -- enrollment_session_id, device_id)
    device_id uuid NOT NULL,

    -- Identity ý định onboarding/đổi Wi-Fi, dùng polling, proof binding và liên kết cleanup/guard.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành device_enrollment_guards_workspace_id_enrollment_session_i_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, enrollment_session_id, device_id) REFERENCES enrollment_sessions(workspace_id,
    -- enrollment_session_id, device_id)
    enrollment_session_id uuid NOT NULL,

    -- Thời điểm device enrollment guard được giữ, giúp chẩn đoán thời gian chiếm thiết bị khi session đã hết hạn.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    acquired_at timestamptz NOT NULL,

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    PRIMARY KEY(workspace_id,device_id),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,device_id) REFERENCES devices(workspace_id,device_id),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,enrollment_session_id,device_id) REFERENCES enrollment_sessions(workspace_id,enrollment_session_id,device_id)
);
