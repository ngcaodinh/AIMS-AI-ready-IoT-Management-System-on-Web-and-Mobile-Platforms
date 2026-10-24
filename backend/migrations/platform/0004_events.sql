/* Bản chú thích để đọc: ràng buộc hiện hành lấy từ manifest sau mọi forward migration.
 * Runner thực thi byte bất biến trong applied_sql và so token SQL với bản này; không sửa ledger.
 */
/* Journal sự kiện, lifecycle và durable messaging dùng các identity đã có0001..0003.
 * Không tạo Event giả cho command/connectivity; không lưu response chứa secret vào idempotency.
 */
-- Bảng workspace_operations: Ý định lifecycle toàn workspace và trạng thái đối soát. Một operation chưa settled
-- giữ fence cho đến khi các thiết bị liên quan có đủ kết quả cleanup.
CREATE TABLE workspace_operations (
    -- Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền
    -- của người gọi.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành workspace_operations_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, workspace_operation_id)
    -- Ràng buộc hiện hành workspace_operations_workspace_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ hợp có
    -- workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id) REFERENCES workspaces(workspace_id)
    -- Ràng buộc hiện hành workspace_operations_workspace_id_requested_by_user_id_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, requested_by_user_id) REFERENCES memberships(workspace_id, user_id)
    workspace_id uuid NOT NULL REFERENCES workspaces,

    -- Identity lifecycle operation workspace, dùng nhóm tập device snapshot và tiến độ cleanup từng thiết bị.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành workspace_operations_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, workspace_operation_id)
    workspace_operation_id uuid NOT NULL,

    -- Loại lifecycle mutation được yêu cầu, để worker thực hiện đúng thao tác và kiểm proof tương ứng.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành workspace_operations_operation_type_check: CHECK chỉ chặn khi biểu thức là FALSE;
    -- NULL/UNKNOWN vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((operation_type = ANY (ARRAY['SUSPEND'::text, 'RESUME'::text, 'ARCHIVE'::text])))
    operation_type text NOT NULL CHECK(operation_type IN ('SUSPEND','RESUME','ARCHIVE')),

    -- Thành viên yêu cầu lifecycle operation; dùng truy vết người khởi tạo, không thay kiểm quyền hiện hành khi worker
    -- thực thi.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành workspace_operations_workspace_id_requested_by_user_id_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, requested_by_user_id) REFERENCES memberships(workspace_id, user_id)
    requested_by_user_id uuid NOT NULL,

    -- Revision resource mà người yêu cầu dựa vào lúc khởi tạo lifecycle operation; dùng phát hiện yêu cầu chỉnh sửa đã
    -- lỗi thời.
    -- bigint: số nguyên có dấu 64 bit, phù hợp bộ đếm/generation tăng lâu dài; không tự tăng nếu chưa có cơ chế cấp
    -- giá trị.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành workspace_operations_requested_revision_check: CHECK chỉ chặn khi biểu thức là FALSE;
    -- NULL/UNKNOWN vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((requested_revision > 0))
    requested_revision bigint NOT NULL CHECK(requested_revision>0),

    -- Trạng thái xử lý bền vững của ledger/job/operation; không suy rằng enum hợp lệ tự chứng minh transition hợp lệ.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành workspace_operations_state_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn
    -- qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((state = ANY (ARRAY['PENDING'::text, 'RUNNING'::text, 'SUCCEEDED'::text, 'FAILED'::text,
    -- 'NEEDS_ATTENTION'::text])))
    state text NOT NULL CHECK(state IN ('PENDING','RUNNING','SUCCEEDED','FAILED','NEEDS_ATTENTION')),

    -- Thời điểm lưu ý định trước side effect bên ngoài DB; dùng tính ngân sách/expiry và phục hồi khi mất ACK.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    intent_at timestamptz NOT NULL,

    -- Thời điểm nghĩa vụ vận hành được đối soát xong và có thể nhả guard/quota; NULL tiếp tục giữ nghĩa vụ chưa giải
    -- quyết.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    settled_at timestamptz,

    -- Mã nguyên nhân ổn định để giải thích kết quả/transition; phải là nội dung an toàn, không chứa raw lỗi/secret.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    reason_code text,

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    PRIMARY KEY(workspace_id,workspace_operation_id),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,requested_by_user_id) REFERENCES memberships
);
/* Operation chưa settled tiếp tục giữ fence kể cả có lỗi cần đối soát. */
CREATE UNIQUE INDEX uq_workspace_operations_unsettled ON workspace_operations(workspace_id) WHERE settled_at IS NULL;
-- Bảng workspace_operation_devices: Snapshot tập thiết bị tham gia workspace operation cùng tiến độ mỗi thiết bị.
-- Liên kết đúng device_operation trên cùng device, không chỉ cùng tenant.
CREATE TABLE workspace_operation_devices (
    -- Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền
    -- của người gọi.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành workspace_operation_devices_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, workspace_operation_id, device_id)
    -- Ràng buộc hiện hành workspace_operation_devices_workspace_id_device_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ
    -- hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, device_id) REFERENCES devices(workspace_id, device_id)
    -- Ràng buộc hiện hành workspace_operation_devices_workspace_id_device_operation__fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, device_operation_id, device_id) REFERENCES device_operations(workspace_id,
    -- device_operation_id, device_id)
    -- Ràng buộc hiện hành workspace_operation_devices_workspace_id_workspace_operati_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, workspace_operation_id) REFERENCES workspace_operations(workspace_id,
    -- workspace_operation_id)
    workspace_id uuid NOT NULL,

    -- Identity lifecycle operation workspace, dùng nhóm tập device snapshot và tiến độ cleanup từng thiết bị.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành workspace_operation_devices_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, workspace_operation_id, device_id)
    -- Ràng buộc hiện hành workspace_operation_devices_workspace_id_workspace_operati_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, workspace_operation_id) REFERENCES workspace_operations(workspace_id,
    -- workspace_operation_id)
    workspace_operation_id uuid NOT NULL,

    -- Identity thiết bị toàn cục để resolve MQTT và registry; kết hợp workspace_id bảo vệ mọi tham chiếu trong đúng
    -- tenant.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành workspace_operation_devices_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, workspace_operation_id, device_id)
    -- Ràng buộc hiện hành workspace_operation_devices_workspace_id_device_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ
    -- hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, device_id) REFERENCES devices(workspace_id, device_id)
    -- Ràng buộc hiện hành workspace_operation_devices_workspace_id_device_operation__fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, device_operation_id, device_id) REFERENCES device_operations(workspace_id,
    -- device_operation_id, device_id)
    device_id uuid NOT NULL,

    -- Identity lifecycle operation của thiết bị; khi tham chiếu cùng device_id phải khớp đúng thiết bị đó.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    -- Ràng buộc hiện hành workspace_operation_devices_workspace_id_device_operation__fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành. FK MATCH SIMPLE mặc
    -- định bỏ kiểm khi có thành phần NULL; CHECK shape riêng vẫn phải đạt.
    -- FOREIGN KEY (workspace_id, device_operation_id, device_id) REFERENCES device_operations(workspace_id,
    -- device_operation_id, device_id)
    device_operation_id uuid,

    -- Trạng thái xử lý bền vững của ledger/job/operation; không suy rằng enum hợp lệ tự chứng minh transition hợp lệ.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành workspace_operation_devices_state_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN
    -- vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((state = ANY (ARRAY['PENDING'::text, 'RUNNING'::text, 'SUCCEEDED'::text, 'FAILED'::text,
    -- 'NEEDS_ATTENTION'::text])))
    state text NOT NULL CHECK(state IN ('PENDING','RUNNING','SUCCEEDED','FAILED','NEEDS_ATTENTION')),

    -- Thời điểm quan sát được dữ liệu/kết quả; nguồn và ý nghĩa được quy định theo bảng, không mặc định là thời gian
    -- commit.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    observed_at timestamptz,

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    PRIMARY KEY(workspace_id,workspace_operation_id,device_id),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,workspace_operation_id) REFERENCES workspace_operations,

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,device_id) REFERENCES devices(workspace_id,device_id),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,device_operation_id,device_id) REFERENCES device_operations(workspace_id,device_operation_id,device_id)
);
-- Bảng events: Sự kiện nghiệp vụ theo nguồn device/rule và episode, có mức độ cùng vòng đời đọc/xác nhận/resolve.
-- Một Event có thể tạo nhiều occurrence và inbox cho từng recipient.
CREATE TABLE events (
    -- Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền
    -- của người gọi.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành events_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì uniqueness áp dụng cho
    -- cả tổ hợp.
    -- PRIMARY KEY (workspace_id, event_id)
    -- Ràng buộc hiện hành events_workspace_id_acknowledged_by_user_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ hợp có
    -- workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, acknowledged_by_user_id) REFERENCES memberships(workspace_id, user_id)
    -- Ràng buộc hiện hành events_workspace_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ hợp có workspace_id giữ quan
    -- hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id) REFERENCES workspaces(workspace_id)
    -- Ràng buộc hiện hành events_workspace_id_source_device_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ hợp có
    -- workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, source_device_id) REFERENCES devices(workspace_id, device_id)
    -- Ràng buộc hiện hành events_workspace_id_source_kind_source_identity_episode_key_key: không trùng tổ hợp giá trị
    -- được nêu; các cột riêng lẻ vẫn có thể lặp khi khóa có nhiều cột.
    -- UNIQUE (workspace_id, source_kind, source_identity, episode_key)
    -- Ràng buộc hiện hành events_workspace_id_source_rule_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ hợp có
    -- workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, source_rule_id) REFERENCES rules(workspace_id, rule_id)
    workspace_id uuid NOT NULL REFERENCES workspaces,

    -- Identity Event nghiệp vụ trong workspace; khác occurrence_id đại diện từng transition để giao webhook.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành events_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì uniqueness áp dụng cho
    -- cả tổ hợp.
    -- PRIMARY KEY (workspace_id, event_id)
    event_id uuid NOT NULL,

    -- Discriminator chỉ loại nguồn typed; phải đi cùng đúng một nhánh FK, không dùng ID đa hình không kiểm chứng.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành events_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên phải phối hợp
    -- NOT NULL và CHECK shape khi cần.
    -- CHECK ((((source_kind = 'DEVICE'::text) AND (source_device_id IS NOT NULL) AND (source_rule_id IS NULL)) OR
    -- ((source_kind = 'RULE'::text) AND (source_rule_id IS NOT NULL) AND (source_device_id IS NULL))))
    -- Ràng buộc hiện hành events_source_kind_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên
    -- phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((source_kind = ANY (ARRAY['DEVICE'::text, 'RULE'::text])))
    -- Ràng buộc hiện hành events_workspace_id_source_kind_source_identity_episode_key_key: không trùng tổ hợp giá trị
    -- được nêu; các cột riêng lẻ vẫn có thể lặp khi khóa có nhiều cột.
    -- UNIQUE (workspace_id, source_kind, source_identity, episode_key)
    source_kind text NOT NULL CHECK(source_kind IN ('DEVICE','RULE')),

    -- Device làm nguồn Event khi source_kind=DEVICE; nhánh rule phải để NULL để giữ XOR nguồn.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    -- Ràng buộc hiện hành events_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên phải phối hợp
    -- NOT NULL và CHECK shape khi cần.
    -- CHECK ((((source_kind = 'DEVICE'::text) AND (source_device_id IS NOT NULL) AND (source_rule_id IS NULL)) OR
    -- ((source_kind = 'RULE'::text) AND (source_rule_id IS NOT NULL) AND (source_device_id IS NULL))))
    -- Ràng buộc hiện hành events_workspace_id_source_device_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ hợp có
    -- workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành. FK MATCH SIMPLE mặc định bỏ kiểm
    -- khi có thành phần NULL; CHECK shape riêng vẫn phải đạt.
    -- FOREIGN KEY (workspace_id, source_device_id) REFERENCES devices(workspace_id, device_id)
    source_device_id uuid,

    -- Rule làm nguồn Event khi source_kind=RULE; nhánh device phải để NULL để giữ XOR nguồn.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    -- Ràng buộc hiện hành events_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên phải phối hợp
    -- NOT NULL và CHECK shape khi cần.
    -- CHECK ((((source_kind = 'DEVICE'::text) AND (source_device_id IS NOT NULL) AND (source_rule_id IS NULL)) OR
    -- ((source_kind = 'RULE'::text) AND (source_rule_id IS NOT NULL) AND (source_device_id IS NULL))))
    -- Ràng buộc hiện hành events_workspace_id_source_rule_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ hợp có
    -- workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành. FK MATCH SIMPLE mặc định bỏ kiểm
    -- khi có thành phần NULL; CHECK shape riêng vẫn phải đạt.
    -- FOREIGN KEY (workspace_id, source_rule_id) REFERENCES rules(workspace_id, rule_id)
    source_rule_id uuid,

    -- Identity nguồn Event được sinh từ đúng một nhánh device/rule; dùng natural dedupe cùng source_kind và
    -- episode_key.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    -- Ràng buộc hiện hành events_workspace_id_source_kind_source_identity_episode_key_key: không trùng tổ hợp giá trị
    -- được nêu; các cột riêng lẻ vẫn có thể lặp khi khóa có nhiều cột. UNIQUE mặc định không coi các giá trị NULL là
    -- trùng nhau.
    -- UNIQUE (workspace_id, source_kind, source_identity, episode_key)
    source_identity uuid GENERATED ALWAYS AS (coalesce(source_device_id,source_rule_id)) STORED,

    -- Identity episode nghiệp vụ của nguồn Event, dùng dedupe một sự kiện trong cùng chu kỳ lỗi/điều kiện.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành events_episode_key_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên
    -- phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((btrim(episode_key) <> ''::text))
    -- Ràng buộc hiện hành events_workspace_id_source_kind_source_identity_episode_key_key: không trùng tổ hợp giá trị
    -- được nêu; các cột riêng lẻ vẫn có thể lặp khi khóa có nhiều cột.
    -- UNIQUE (workspace_id, source_kind, source_identity, episode_key)
    episode_key text NOT NULL CHECK(btrim(episode_key)<>''),

    -- Mức độ INFO/WARNING/CRITICAL của Event, dùng lọc hiển thị/notification; không thay trạng thái Event.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành events_severity_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên phải
    -- phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((severity = ANY (ARRAY['INFO'::text, 'WARNING'::text, 'CRITICAL'::text])))
    severity text NOT NULL CHECK(severity IN ('INFO','WARNING','CRITICAL')),

    -- Vòng đời Event OPEN/ACKNOWLEDGED/RESOLVED; khác trạng thái read của inbox và outcome của command.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- DEFAULT 'OPEN'::text: giá trị dùng khi INSERT bỏ qua cột; không thay NULL được truyền tường minh và không tự áp
    -- lại khi UPDATE.
    -- Ràng buộc hiện hành events_check2: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên phải phối
    -- hợp NOT NULL và CHECK shape khi cần.
    -- CHECK (((status = 'RESOLVED'::text) = (resolved_at IS NOT NULL)))
    -- Ràng buộc hiện hành events_status_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên phải
    -- phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((status = ANY (ARRAY['OPEN'::text, 'ACKNOWLEDGED'::text, 'RESOLVED'::text])))
    status text NOT NULL DEFAULT 'OPEN' CHECK(status IN ('OPEN','ACKNOWLEDGED','RESOLVED')),

    -- Tiêu đề hiển thị của dashboard hoặc sự kiện; là nội dung giao diện, không dùng thay identity tài nguyên.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    title text NOT NULL,

    -- Thông điệp Event dùng hiển thị hoặc thông báo sau validation/redaction phía producer; không là nơi cất payload
    -- bí mật.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    safe_message text NOT NULL,

    -- Phiên bản chỉnh sửa bản ghi dùng cho CAS/If-Match hoặc đối soát; bên ghi chịu trách nhiệm cập nhật theo đúng
    -- transaction contract.
    -- bigint: số nguyên có dấu 64 bit, phù hợp bộ đếm/generation tăng lâu dài; không tự tăng nếu chưa có cơ chế cấp
    -- giá trị.
    -- NOT NULL: bắt buộc có giá trị.
    -- DEFAULT 1: giá trị dùng khi INSERT bỏ qua cột; không thay NULL được truyền tường minh và không tự áp lại khi
    -- UPDATE.
    -- Ràng buộc hiện hành events_revision_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên phải
    -- phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((revision > 0))
    revision bigint NOT NULL DEFAULT 1 CHECK(revision>0),

    -- Thời điểm tạo bản ghi dưới dạng timestamptz; dùng provenance/sắp xếp hoặc retention khi policy của bảng quy
    -- định.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    created_at timestamptz NOT NULL,

    -- Thành viên đã xác nhận Event; đi cùng acknowledged_at để lưu người và thời điểm ACK.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    -- Ràng buộc hiện hành events_check1: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên phải phối
    -- hợp NOT NULL và CHECK shape khi cần.
    -- CHECK (((acknowledged_by_user_id IS NULL) = (acknowledged_at IS NULL)))
    -- Ràng buộc hiện hành events_workspace_id_acknowledged_by_user_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ hợp có
    -- workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành. FK MATCH SIMPLE mặc định bỏ kiểm
    -- khi có thành phần NULL; CHECK shape riêng vẫn phải đạt.
    -- FOREIGN KEY (workspace_id, acknowledged_by_user_id) REFERENCES memberships(workspace_id, user_id)
    acknowledged_by_user_id uuid,

    -- Thời điểm thành viên ACK Event, đi cùng acknowledged_by_user_id và độc lập read_at của inbox.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    -- Ràng buộc hiện hành events_check1: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên phải phối
    -- hợp NOT NULL và CHECK shape khi cần.
    -- CHECK (((acknowledged_by_user_id IS NULL) = (acknowledged_at IS NULL)))
    acknowledged_at timestamptz,

    -- Thời điểm Event/resolution được đóng xử lý; ngữ nghĩa theo aggregate, không tự thay command UNKNOWN thành
    -- SUCCEEDED.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    -- Ràng buộc hiện hành events_check2: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên phải phối
    -- hợp NOT NULL và CHECK shape khi cần.
    -- CHECK (((status = 'RESOLVED'::text) = (resolved_at IS NOT NULL)))
    resolved_at timestamptz,

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    PRIMARY KEY(workspace_id,event_id),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    UNIQUE(workspace_id,source_kind,source_identity,episode_key),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,source_device_id) REFERENCES devices(workspace_id,device_id),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,source_rule_id) REFERENCES rules,

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,acknowledged_by_user_id) REFERENCES memberships,

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    CHECK((source_kind='DEVICE' AND source_device_id IS NOT NULL AND source_rule_id IS NULL) OR
       (source_kind='RULE' AND source_rule_id IS NOT NULL AND source_device_id IS NULL)),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    CHECK((acknowledged_by_user_id IS NULL)=(acknowledged_at IS NULL)),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    CHECK((status='RESOLVED')=(resolved_at IS NOT NULL))
);
/* Tenant và thời gian phục vụ lịch sử, không dùng title làm dedupe. */
CREATE INDEX ix_events_history ON events(workspace_id,created_at DESC,event_id);
-- Bảng event_occurrences: Journal từng transition đã commit của Event, command hoặc connectivity. Identity
-- occurrence dùng cho webhook, khác Event nghiệp vụ; nhánh typed/XOR tránh tạo Event giả.
CREATE TABLE event_occurrences (
    -- Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền
    -- của người gọi.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành event_occurrences_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì uniqueness
    -- áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, occurrence_id)
    -- Ràng buộc hiện hành event_occurrences_workspace_id_command_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ hợp có
    -- workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, command_id) REFERENCES commands(workspace_id, command_id)
    -- Ràng buộc hiện hành event_occurrences_workspace_id_connectivity_device_id_conn_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, connectivity_device_id, connectivity_transition_sequence) REFERENCES
    -- connectivity_transitions(workspace_id, device_id, transition_sequence)
    -- Ràng buộc hiện hành event_occurrences_workspace_id_event_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ hợp có
    -- workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, event_id) REFERENCES events(workspace_id, event_id)
    -- Ràng buộc hiện hành event_occurrences_workspace_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ hợp có workspace_id
    -- giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id) REFERENCES workspaces(workspace_id)
    workspace_id uuid NOT NULL REFERENCES workspaces,

    -- Identity một transition đã commit; wire webhook eventId ánh xạ identity này, không gộp OPEN/RESOLVED thành một
    -- Event ID.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành event_occurrences_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì uniqueness
    -- áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, occurrence_id)
    occurrence_id uuid NOT NULL,

    -- Discriminator chỉ loại nguồn typed; phải đi cùng đúng một nhánh FK, không dùng ID đa hình không kiểm chứng.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành ck_event_occurrences_public_type: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn
    -- qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((((source_kind = 'EVENT'::text) AND (occurrence_type = 'CREATED'::text) AND (public_event_type IS NOT
    -- NULL) AND (public_event_type = 'event.opened'::text)) OR ((source_kind = 'EVENT'::text) AND (occurrence_type =
    -- 'RESOLVED'::text) AND (public_event_type IS NOT NULL) AND (public_event_type = 'event.resolved'::text)) OR
    -- ((source_kind = 'EVENT'::text) AND (occurrence_type = 'ACKNOWLEDGED'::text) AND (public_event_type IS NULL)) OR
    -- ((source_kind = 'COMMAND'::text) AND (occurrence_type = 'COMMAND_TERMINAL'::text) AND (public_event_type IS NOT
    -- NULL) AND (public_event_type = 'command.completed'::text)) OR ((source_kind = 'CONNECTIVITY'::text) AND
    -- (occurrence_type = 'CONNECTIVITY_CHANGED'::text) AND (public_event_type IS NOT NULL) AND (public_event_type =
    -- 'device.connectivity'::text))))
    -- Ràng buộc hiện hành ck_event_occurrences_source_shape: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn
    -- qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((((source_kind = 'EVENT'::text) AND (event_id IS NOT NULL) AND (event_revision IS NOT NULL) AND
    -- (event_revision > 0) AND (num_nonnulls(command_id, connectivity_device_id, connectivity_transition_sequence) =
    -- 0)) OR ((source_kind = 'COMMAND'::text) AND (command_id IS NOT NULL) AND (num_nonnulls(event_id, event_revision,
    -- connectivity_device_id, connectivity_transition_sequence) = 0)) OR ((source_kind = 'CONNECTIVITY'::text) AND
    -- (connectivity_device_id IS NOT NULL) AND (connectivity_transition_sequence IS NOT NULL) AND
    -- (connectivity_transition_sequence > 0) AND (num_nonnulls(event_id, event_revision, command_id) = 0))))
    -- Ràng buộc hiện hành event_occurrences_source_kind_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn
    -- qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((source_kind = ANY (ARRAY['EVENT'::text, 'COMMAND'::text, 'CONNECTIVITY'::text])))
    source_kind text NOT NULL CHECK(source_kind IN ('EVENT','COMMAND','CONNECTIVITY')),

    -- Identity Event nghiệp vụ trong workspace; khác occurrence_id đại diện từng transition để giao webhook.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    -- Ràng buộc hiện hành ck_event_occurrences_source_shape: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn
    -- qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((((source_kind = 'EVENT'::text) AND (event_id IS NOT NULL) AND (event_revision IS NOT NULL) AND
    -- (event_revision > 0) AND (num_nonnulls(command_id, connectivity_device_id, connectivity_transition_sequence) =
    -- 0)) OR ((source_kind = 'COMMAND'::text) AND (command_id IS NOT NULL) AND (num_nonnulls(event_id, event_revision,
    -- connectivity_device_id, connectivity_transition_sequence) = 0)) OR ((source_kind = 'CONNECTIVITY'::text) AND
    -- (connectivity_device_id IS NOT NULL) AND (connectivity_transition_sequence IS NOT NULL) AND
    -- (connectivity_transition_sequence > 0) AND (num_nonnulls(event_id, event_revision, command_id) = 0))))
    -- Ràng buộc hiện hành event_occurrences_workspace_id_event_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ hợp có
    -- workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành. FK MATCH SIMPLE mặc định bỏ kiểm
    -- khi có thành phần NULL; CHECK shape riêng vẫn phải đạt.
    -- FOREIGN KEY (workspace_id, event_id) REFERENCES events(workspace_id, event_id)
    event_id uuid,

    -- Revision transition Event được chụp trong occurrence, lớn hơn 0; unique cùng Event tránh phát cùng transition
    -- hai lần.
    -- bigint: số nguyên có dấu 64 bit, phù hợp bộ đếm/generation tăng lâu dài; không tự tăng nếu chưa có cơ chế cấp
    -- giá trị.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    -- Ràng buộc hiện hành ck_event_occurrences_source_shape: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn
    -- qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((((source_kind = 'EVENT'::text) AND (event_id IS NOT NULL) AND (event_revision IS NOT NULL) AND
    -- (event_revision > 0) AND (num_nonnulls(command_id, connectivity_device_id, connectivity_transition_sequence) =
    -- 0)) OR ((source_kind = 'COMMAND'::text) AND (command_id IS NOT NULL) AND (num_nonnulls(event_id, event_revision,
    -- connectivity_device_id, connectivity_transition_sequence) = 0)) OR ((source_kind = 'CONNECTIVITY'::text) AND
    -- (connectivity_device_id IS NOT NULL) AND (connectivity_transition_sequence IS NOT NULL) AND
    -- (connectivity_transition_sequence > 0) AND (num_nonnulls(event_id, event_revision, command_id) = 0))))
    event_revision bigint,

    -- Identity command ổn định qua retry/result/reconciliation; không tạo command mới chỉ vì mất response.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    -- Ràng buộc hiện hành ck_event_occurrences_source_shape: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn
    -- qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((((source_kind = 'EVENT'::text) AND (event_id IS NOT NULL) AND (event_revision IS NOT NULL) AND
    -- (event_revision > 0) AND (num_nonnulls(command_id, connectivity_device_id, connectivity_transition_sequence) =
    -- 0)) OR ((source_kind = 'COMMAND'::text) AND (command_id IS NOT NULL) AND (num_nonnulls(event_id, event_revision,
    -- connectivity_device_id, connectivity_transition_sequence) = 0)) OR ((source_kind = 'CONNECTIVITY'::text) AND
    -- (connectivity_device_id IS NOT NULL) AND (connectivity_transition_sequence IS NOT NULL) AND
    -- (connectivity_transition_sequence > 0) AND (num_nonnulls(event_id, event_revision, command_id) = 0))))
    -- Ràng buộc hiện hành event_occurrences_workspace_id_command_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ hợp có
    -- workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành. FK MATCH SIMPLE mặc định bỏ kiểm
    -- khi có thành phần NULL; CHECK shape riêng vẫn phải đạt.
    -- FOREIGN KEY (workspace_id, command_id) REFERENCES commands(workspace_id, command_id)
    command_id uuid,

    -- Device làm nguồn occurrence connectivity, chỉ có trong nhánh CONNECTIVITY.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    -- Ràng buộc hiện hành ck_event_occurrences_source_shape: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn
    -- qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((((source_kind = 'EVENT'::text) AND (event_id IS NOT NULL) AND (event_revision IS NOT NULL) AND
    -- (event_revision > 0) AND (num_nonnulls(command_id, connectivity_device_id, connectivity_transition_sequence) =
    -- 0)) OR ((source_kind = 'COMMAND'::text) AND (command_id IS NOT NULL) AND (num_nonnulls(event_id, event_revision,
    -- connectivity_device_id, connectivity_transition_sequence) = 0)) OR ((source_kind = 'CONNECTIVITY'::text) AND
    -- (connectivity_device_id IS NOT NULL) AND (connectivity_transition_sequence IS NOT NULL) AND
    -- (connectivity_transition_sequence > 0) AND (num_nonnulls(event_id, event_revision, command_id) = 0))))
    -- Ràng buộc hiện hành event_occurrences_workspace_id_connectivity_device_id_conn_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành. FK MATCH SIMPLE mặc
    -- định bỏ kiểm khi có thành phần NULL; CHECK shape riêng vẫn phải đạt.
    -- FOREIGN KEY (workspace_id, connectivity_device_id, connectivity_transition_sequence) REFERENCES
    -- connectivity_transitions(workspace_id, device_id, transition_sequence)
    connectivity_device_id uuid,

    -- Transition presence cụ thể của connectivity_device_id; cùng device/sequence là nguồn chống trùng occurrence.
    -- bigint: số nguyên có dấu 64 bit, phù hợp bộ đếm/generation tăng lâu dài; không tự tăng nếu chưa có cơ chế cấp
    -- giá trị.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    -- Ràng buộc hiện hành ck_event_occurrences_source_shape: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn
    -- qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((((source_kind = 'EVENT'::text) AND (event_id IS NOT NULL) AND (event_revision IS NOT NULL) AND
    -- (event_revision > 0) AND (num_nonnulls(command_id, connectivity_device_id, connectivity_transition_sequence) =
    -- 0)) OR ((source_kind = 'COMMAND'::text) AND (command_id IS NOT NULL) AND (num_nonnulls(event_id, event_revision,
    -- connectivity_device_id, connectivity_transition_sequence) = 0)) OR ((source_kind = 'CONNECTIVITY'::text) AND
    -- (connectivity_device_id IS NOT NULL) AND (connectivity_transition_sequence IS NOT NULL) AND
    -- (connectivity_transition_sequence > 0) AND (num_nonnulls(event_id, event_revision, command_id) = 0))))
    -- Ràng buộc hiện hành event_occurrences_workspace_id_connectivity_device_id_conn_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành. FK MATCH SIMPLE mặc
    -- định bỏ kiểm khi có thành phần NULL; CHECK shape riêng vẫn phải đạt.
    -- FOREIGN KEY (workspace_id, connectivity_device_id, connectivity_transition_sequence) REFERENCES
    -- connectivity_transitions(workspace_id, device_id, transition_sequence)
    connectivity_transition_sequence bigint,

    -- Loại transition nội bộ của nguồn occurrence; ACKNOWLEDGED không mặc định thành BUSINESS webhook public.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành ck_event_occurrences_public_type: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn
    -- qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((((source_kind = 'EVENT'::text) AND (occurrence_type = 'CREATED'::text) AND (public_event_type IS NOT
    -- NULL) AND (public_event_type = 'event.opened'::text)) OR ((source_kind = 'EVENT'::text) AND (occurrence_type =
    -- 'RESOLVED'::text) AND (public_event_type IS NOT NULL) AND (public_event_type = 'event.resolved'::text)) OR
    -- ((source_kind = 'EVENT'::text) AND (occurrence_type = 'ACKNOWLEDGED'::text) AND (public_event_type IS NULL)) OR
    -- ((source_kind = 'COMMAND'::text) AND (occurrence_type = 'COMMAND_TERMINAL'::text) AND (public_event_type IS NOT
    -- NULL) AND (public_event_type = 'command.completed'::text)) OR ((source_kind = 'CONNECTIVITY'::text) AND
    -- (occurrence_type = 'CONNECTIVITY_CHANGED'::text) AND (public_event_type IS NOT NULL) AND (public_event_type =
    -- 'device.connectivity'::text))))
    occurrence_type text NOT NULL,

    -- Loại event public để webhook fanout; NULL cho occurrence nội bộ không được phép phát BUSINESS webhook.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    -- Ràng buộc hiện hành ck_event_occurrences_public_type: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn
    -- qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((((source_kind = 'EVENT'::text) AND (occurrence_type = 'CREATED'::text) AND (public_event_type IS NOT
    -- NULL) AND (public_event_type = 'event.opened'::text)) OR ((source_kind = 'EVENT'::text) AND (occurrence_type =
    -- 'RESOLVED'::text) AND (public_event_type IS NOT NULL) AND (public_event_type = 'event.resolved'::text)) OR
    -- ((source_kind = 'EVENT'::text) AND (occurrence_type = 'ACKNOWLEDGED'::text) AND (public_event_type IS NULL)) OR
    -- ((source_kind = 'COMMAND'::text) AND (occurrence_type = 'COMMAND_TERMINAL'::text) AND (public_event_type IS NOT
    -- NULL) AND (public_event_type = 'command.completed'::text)) OR ((source_kind = 'CONNECTIVITY'::text) AND
    -- (occurrence_type = 'CONNECTIVITY_CHANGED'::text) AND (public_event_type IS NOT NULL) AND (public_event_type =
    -- 'device.connectivity'::text))))
    public_event_type text,

    -- Thời điểm nghiệp vụ/sự kiện diễn ra để sắp xếp timeline; không mặc định bằng thời điểm fanout hoặc provider phản
    -- hồi.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    occurred_at timestamptz NOT NULL,

    -- Mốc thời gian producer ghi cho occurrence trong transaction đã commit thành công; không phải physical commit
    -- timestamp biết trước commit.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    committed_at timestamptz NOT NULL,

    -- Snapshot payload occurrence đã commit, giữ nguyên để fanout/retry không đọc lại resource mutable rồi đổi sự thật
    -- lịch sử.
    -- jsonb: tài liệu JSON lưu dạng nhị phân; kiểm object/scalar không thay validation đầy đủ cấu trúc và tham chiếu
    -- nghiệp vụ.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành event_occurrences_immutable_payload_check: CHECK chỉ chặn khi biểu thức là FALSE;
    -- NULL/UNKNOWN vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((jsonb_typeof(immutable_payload) = 'object'::text))
    immutable_payload jsonb NOT NULL CHECK(jsonb_typeof(immutable_payload)='object'),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    PRIMARY KEY(workspace_id,occurrence_id),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,event_id) REFERENCES events,

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,command_id) REFERENCES commands,

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,connectivity_device_id,connectivity_transition_sequence) REFERENCES connectivity_transitions,

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    CONSTRAINT ck_event_occurrences_source_shape CHECK(
  (source_kind='EVENT' AND event_id IS NOT NULL AND event_revision IS NOT NULL AND event_revision>0 AND num_nonnulls(command_id,connectivity_device_id,connectivity_transition_sequence)=0) OR
  (source_kind='COMMAND' AND command_id IS NOT NULL AND num_nonnulls(event_id,event_revision,connectivity_device_id,connectivity_transition_sequence)=0) OR
  (source_kind='CONNECTIVITY' AND connectivity_device_id IS NOT NULL AND connectivity_transition_sequence IS NOT NULL AND connectivity_transition_sequence>0 AND num_nonnulls(event_id,event_revision,command_id)=0)),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    CONSTRAINT ck_event_occurrences_public_type CHECK(
  (source_kind='EVENT' AND occurrence_type='CREATED' AND public_event_type IS NOT NULL AND public_event_type='event.opened') OR
  (source_kind='EVENT' AND occurrence_type='RESOLVED' AND public_event_type IS NOT NULL AND public_event_type='event.resolved') OR
  (source_kind='EVENT' AND occurrence_type='ACKNOWLEDGED' AND public_event_type IS NULL) OR
  (source_kind='COMMAND' AND occurrence_type='COMMAND_TERMINAL' AND public_event_type IS NOT NULL AND public_event_type='command.completed') OR
  (source_kind='CONNECTIVITY' AND occurrence_type='CONNECTIVITY_CHANGED' AND public_event_type IS NOT NULL AND public_event_type='device.connectivity'))
);
/* Mỗi nguồn có natural dedupe riêng, NULL của nhánh khác không làm yếu uniqueness. */
CREATE UNIQUE INDEX uq_event_occurrences_event_revision ON event_occurrences(workspace_id,event_id,event_revision) WHERE source_kind='EVENT';
CREATE UNIQUE INDEX uq_event_occurrences_command_terminal ON event_occurrences(workspace_id,command_id) WHERE source_kind='COMMAND';
CREATE UNIQUE INDEX uq_event_occurrences_connectivity_transition ON event_occurrences(workspace_id,connectivity_device_id,connectivity_transition_sequence) WHERE source_kind='CONNECTIVITY';
-- Bảng notifications: Một mục inbox của một recipient, phân biệt EVENT và PUSH_TEST. Read state thuộc recipient;
-- target typed giữ đích deep link mà không cấp quyền đọc vượt scope hiện hành.
CREATE TABLE notifications (
    -- Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền
    -- của người gọi.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành notifications_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì uniqueness áp
    -- dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, notification_id)
    -- Ràng buộc hiện hành notifications_workspace_id_event_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ hợp có
    -- workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, event_id) REFERENCES events(workspace_id, event_id)
    -- Ràng buộc hiện hành notifications_workspace_id_notification_id_recipient_user_i_key: không trùng tổ hợp giá trị
    -- được nêu; các cột riêng lẻ vẫn có thể lặp khi khóa có nhiều cột.
    -- UNIQUE (workspace_id, notification_id, recipient_user_id)
    -- Ràng buộc hiện hành notifications_workspace_id_recipient_user_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ hợp
    -- có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, recipient_user_id) REFERENCES memberships(workspace_id, user_id)
    -- Ràng buộc hiện hành notifications_workspace_id_target_device_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ hợp có
    -- workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, target_device_id) REFERENCES devices(workspace_id, device_id)
    -- Ràng buộc hiện hành notifications_workspace_id_target_rule_execution_id_fkey: khóa ngoại giữ đúng bản ghi cha;
    -- tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, target_rule_execution_id) REFERENCES rule_executions(workspace_id, rule_execution_id)
    workspace_id uuid NOT NULL,

    -- Identity mục inbox của recipient, là gốc fanout push/deep link; không thay Event source hoặc occurrence
    -- identity.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành notifications_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì uniqueness áp
    -- dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, notification_id)
    -- Ràng buộc hiện hành notifications_workspace_id_notification_id_recipient_user_i_key: không trùng tổ hợp giá trị
    -- được nêu; các cột riêng lẻ vẫn có thể lặp khi khóa có nhiều cột.
    -- UNIQUE (workspace_id, notification_id, recipient_user_id)
    notification_id uuid NOT NULL,

    -- Thành viên nhận inbox/push; chỉ chính recipient được hưởng quyền đọc và thay đổi read state của inbox.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành notifications_workspace_id_notification_id_recipient_user_i_key: không trùng tổ hợp giá trị
    -- được nêu; các cột riêng lẻ vẫn có thể lặp khi khóa có nhiều cột.
    -- UNIQUE (workspace_id, notification_id, recipient_user_id)
    -- Ràng buộc hiện hành notifications_workspace_id_recipient_user_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ hợp
    -- có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, recipient_user_id) REFERENCES memberships(workspace_id, user_id)
    recipient_user_id uuid NOT NULL,

    -- EVENT là inbox từ Event nghiệp vụ; PUSH_TEST là test push không tạo Event giả.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành ck_notification_source: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên
    -- phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((((kind = 'EVENT'::text) AND (event_id IS NOT NULL)) OR ((kind = 'PUSH_TEST'::text) AND (event_id IS
    -- NULL))))
    -- Ràng buộc hiện hành ck_notification_target: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên
    -- phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((((target_type = 'EVENT'::text) AND (kind = 'EVENT'::text) AND (target_device_id IS NULL) AND
    -- (target_rule_execution_id IS NULL)) OR ((target_type = 'DEVICE'::text) AND (kind = 'EVENT'::text) AND
    -- (target_device_id IS NOT NULL) AND (target_rule_execution_id IS NULL)) OR ((target_type = 'EXECUTION'::text) AND
    -- (kind = 'EVENT'::text) AND (target_device_id IS NULL) AND (target_rule_execution_id IS NOT NULL)) OR
    -- ((target_type = 'NOTIFICATION'::text) AND (kind = 'PUSH_TEST'::text) AND (target_device_id IS NULL) AND
    -- (target_rule_execution_id IS NULL))))
    -- Ràng buộc hiện hành notifications_kind_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên
    -- phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((kind = ANY (ARRAY['EVENT'::text, 'PUSH_TEST'::text])))
    kind text NOT NULL CHECK(kind IN ('EVENT','PUSH_TEST')),

    -- Identity Event nghiệp vụ trong workspace; khác occurrence_id đại diện từng transition để giao webhook.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    -- Ràng buộc hiện hành ck_notification_source: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên
    -- phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((((kind = 'EVENT'::text) AND (event_id IS NOT NULL)) OR ((kind = 'PUSH_TEST'::text) AND (event_id IS
    -- NULL))))
    -- Ràng buộc hiện hành notifications_workspace_id_event_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ hợp có
    -- workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành. FK MATCH SIMPLE mặc định bỏ kiểm
    -- khi có thành phần NULL; CHECK shape riêng vẫn phải đạt.
    -- FOREIGN KEY (workspace_id, event_id) REFERENCES events(workspace_id, event_id)
    event_id uuid,

    -- Loại đích deep link EVENT/EXECUTION/DEVICE/NOTIFICATION, quyết định target FK nào phải có hoặc phải NULL.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành ck_notification_target: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên
    -- phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((((target_type = 'EVENT'::text) AND (kind = 'EVENT'::text) AND (target_device_id IS NULL) AND
    -- (target_rule_execution_id IS NULL)) OR ((target_type = 'DEVICE'::text) AND (kind = 'EVENT'::text) AND
    -- (target_device_id IS NOT NULL) AND (target_rule_execution_id IS NULL)) OR ((target_type = 'EXECUTION'::text) AND
    -- (kind = 'EVENT'::text) AND (target_device_id IS NULL) AND (target_rule_execution_id IS NOT NULL)) OR
    -- ((target_type = 'NOTIFICATION'::text) AND (kind = 'PUSH_TEST'::text) AND (target_device_id IS NULL) AND
    -- (target_rule_execution_id IS NULL))))
    -- Ràng buộc hiện hành notifications_target_type_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn
    -- qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((target_type = ANY (ARRAY['EVENT'::text, 'EXECUTION'::text, 'DEVICE'::text, 'NOTIFICATION'::text])))
    target_type text NOT NULL CHECK(target_type IN ('EVENT','EXECUTION','DEVICE','NOTIFICATION')),

    -- Thiết bị đích của action hoặc deep link; NULL khi nhánh không có device, nếu có phải cùng workspace và đúng pin.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    -- Ràng buộc hiện hành ck_notification_target: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên
    -- phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((((target_type = 'EVENT'::text) AND (kind = 'EVENT'::text) AND (target_device_id IS NULL) AND
    -- (target_rule_execution_id IS NULL)) OR ((target_type = 'DEVICE'::text) AND (kind = 'EVENT'::text) AND
    -- (target_device_id IS NOT NULL) AND (target_rule_execution_id IS NULL)) OR ((target_type = 'EXECUTION'::text) AND
    -- (kind = 'EVENT'::text) AND (target_device_id IS NULL) AND (target_rule_execution_id IS NOT NULL)) OR
    -- ((target_type = 'NOTIFICATION'::text) AND (kind = 'PUSH_TEST'::text) AND (target_device_id IS NULL) AND
    -- (target_rule_execution_id IS NULL))))
    -- Ràng buộc hiện hành notifications_workspace_id_target_device_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ hợp có
    -- workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành. FK MATCH SIMPLE mặc định bỏ kiểm
    -- khi có thành phần NULL; CHECK shape riêng vẫn phải đạt.
    -- FOREIGN KEY (workspace_id, target_device_id) REFERENCES devices(workspace_id, device_id)
    target_device_id uuid,

    -- Execution đích của notification; giữ identity lịch sử nhưng không kéo dài quyền đọc history sau retention/mất
    -- quyền.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    -- Ràng buộc hiện hành ck_notification_target: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên
    -- phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((((target_type = 'EVENT'::text) AND (kind = 'EVENT'::text) AND (target_device_id IS NULL) AND
    -- (target_rule_execution_id IS NULL)) OR ((target_type = 'DEVICE'::text) AND (kind = 'EVENT'::text) AND
    -- (target_device_id IS NOT NULL) AND (target_rule_execution_id IS NULL)) OR ((target_type = 'EXECUTION'::text) AND
    -- (kind = 'EVENT'::text) AND (target_device_id IS NULL) AND (target_rule_execution_id IS NOT NULL)) OR
    -- ((target_type = 'NOTIFICATION'::text) AND (kind = 'PUSH_TEST'::text) AND (target_device_id IS NULL) AND
    -- (target_rule_execution_id IS NULL))))
    -- Ràng buộc hiện hành notifications_workspace_id_target_rule_execution_id_fkey: khóa ngoại giữ đúng bản ghi cha;
    -- tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành. FK MATCH SIMPLE mặc định
    -- bỏ kiểm khi có thành phần NULL; CHECK shape riêng vẫn phải đạt.
    -- FOREIGN KEY (workspace_id, target_rule_execution_id) REFERENCES rule_executions(workspace_id, rule_execution_id)
    target_rule_execution_id uuid,

    -- Mốc tạo notification làm gốc expiry push +1 giờ; delivery fanout muộn không được lấy mốc worker mới làm gốc TTL.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    created_at timestamptz NOT NULL,

    -- Thời điểm recipient đánh dấu mục inbox đã đọc; không ACK/resolve Event và không chứng minh provider đã giao
    -- push.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    read_at timestamptz,

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    PRIMARY KEY(workspace_id,notification_id),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    UNIQUE(workspace_id,notification_id,recipient_user_id),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,recipient_user_id) REFERENCES memberships,

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,event_id) REFERENCES events,

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,target_device_id) REFERENCES devices(workspace_id,device_id),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,target_rule_execution_id) REFERENCES rule_executions,

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    CONSTRAINT ck_notification_source CHECK((kind='EVENT' AND event_id IS NOT NULL) OR (kind='PUSH_TEST' AND event_id IS NULL)),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    CONSTRAINT ck_notification_target CHECK(
  (target_type='EVENT' AND kind='EVENT' AND target_device_id IS NULL AND target_rule_execution_id IS NULL) OR
  (target_type='DEVICE' AND kind='EVENT' AND target_device_id IS NOT NULL AND target_rule_execution_id IS NULL) OR
  (target_type='EXECUTION' AND kind='EVENT' AND target_device_id IS NULL AND target_rule_execution_id IS NOT NULL) OR
  (target_type='NOTIFICATION' AND kind='PUSH_TEST' AND target_device_id IS NULL AND target_rule_execution_id IS NULL))
);
/* Inbox phân biệt người nhận; read của một người không sửa Event hoặc inbox người khác. */
CREATE UNIQUE INDEX uq_notifications_event_recipient ON notifications(workspace_id,event_id,recipient_user_id) WHERE kind='EVENT';
CREATE INDEX ix_notifications_recipient ON notifications(workspace_id,recipient_user_id,created_at DESC,notification_id);
-- Bảng global_idempotency_records: Biên nhận chống lặp cho request global theo tài khoản/route/key digest, không
-- gắn workspace đang chọn. Chỉ giữ kết quả đã loại secret trong cửa sổ replay 24 giờ.
CREATE TABLE global_idempotency_records (
    -- Tài khoản principal của request global; không đưa workspace đang chọn vào namespace replay.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành global_idempotency_records_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (user_id, route_key, key_digest)
    -- Ràng buộc hiện hành global_idempotency_records_user_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ hợp có
    -- workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (user_id) REFERENCES users(user_id)
    user_id uuid NOT NULL REFERENCES users,

    -- Namespace route canonical gồm identity resource cần thiết; không chỉ là route template khi nhiều target dùng
    -- chung idempotency key.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành global_idempotency_records_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (user_id, route_key, key_digest)
    route_key text NOT NULL,

    -- Digest idempotency key của client; cùng namespace principal/route tạo identity replay, không chứa secret
    -- response.
    -- bytea: dãy byte nhị phân; tên digest/ciphertext mô tả mục đích, bản thân kiểu không băm hoặc mã hóa dữ liệu.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành global_idempotency_records_key_digest_check: CHECK chỉ chặn khi biểu thức là FALSE;
    -- NULL/UNKNOWN vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((octet_length(key_digest) = 32))
    -- Ràng buộc hiện hành global_idempotency_records_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (user_id, route_key, key_digest)
    key_digest bytea NOT NULL CHECK(octet_length(key_digest)=32),

    -- Digest 32 byte của request/body đã canonical hóa để phát hiện cùng identity khác nội dung hoặc đối chiếu send
    -- intent.
    -- bytea: dãy byte nhị phân; tên digest/ciphertext mô tả mục đích, bản thân kiểu không băm hoặc mã hóa dữ liệu.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành global_idempotency_records_request_digest_check: CHECK chỉ chặn khi biểu thức là FALSE;
    -- NULL/UNKNOWN vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((octet_length(request_digest) = 32))
    request_digest bytea NOT NULL CHECK(octet_length(request_digest)=32),

    -- Thời điểm yêu cầu được backend nhận vào ledger sau kiểm điều kiện; không chứng minh side effect đã thực hiện.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành global_idempotency_records_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn
    -- qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((expires_at = (admitted_at + '24:00:00'::interval)))
    admitted_at timestamptz NOT NULL,

    -- Hết cửa sổ replay sau admitted_at + 24 giờ; không replay one-time secret, chỉ sanitized_result.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành global_idempotency_records_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn
    -- qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((expires_at = (admitted_at + '24:00:00'::interval)))
    expires_at timestamptz NOT NULL,

    -- Receipt đang IN_PROGRESS hoặc COMPLETED; lỗi mất ACK không cho tự kết luận transaction chưa commit.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành global_idempotency_records_state_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN
    -- vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((state = ANY (ARRAY['IN_PROGRESS'::text, 'COMPLETED'::text])))
    state text NOT NULL CHECK(state IN ('IN_PROGRESS','COMPLETED')),

    -- HTTP status đã ghi nhận, miền 100..599 khi có; NULL khi chưa có response đáng tin cậy.
    -- integer: số nguyên có dấu 32 bit; CHECK giới hạn miền nghiệp vụ thay vì chỉ dựa phạm vi kiểu.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    -- Ràng buộc hiện hành global_idempotency_records_response_status_check: CHECK chỉ chặn khi biểu thức là FALSE;
    -- NULL/UNKNOWN vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK (((response_status >= 100) AND (response_status <= 599)))
    response_status integer CHECK(response_status BETWEEN 100 AND 599),

    -- Kết quả replay đã loại secret, không lưu one-time credential response để trả lại sau retry.
    -- jsonb: tài liệu JSON lưu dạng nhị phân; kiểm object/scalar không thay validation đầy đủ cấu trúc và tham chiếu
    -- nghiệp vụ.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    sanitized_result jsonb,

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    PRIMARY KEY(user_id,route_key,key_digest),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    CHECK(expires_at=admitted_at+interval '24 hours')
);
/* Hai principal typed thay principal_id polymorphic không FK; API key FK bổ sung0006. */
-- Bảng workspace_idempotency_records: Biên nhận chống lặp cho request trong workspace theo principal user/API key.
-- Digest body dùng phát hiện cùng key khác nội dung; không đưa body hash vào khóa dedupe.
CREATE TABLE workspace_idempotency_records (
    -- Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền
    -- của người gọi.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành fk_idempotency_api_key: khóa ngoại giữ đúng bản ghi cha; tổ hợp có workspace_id giữ quan hệ
    -- trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, api_key_id) REFERENCES api_keys(workspace_id, api_key_id)
    -- Ràng buộc hiện hành workspace_idempotency_records_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, idempotency_record_id)
    -- Ràng buộc hiện hành workspace_idempotency_records_workspace_id_command_id_fkey: khóa ngoại giữ đúng bản ghi cha;
    -- tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, command_id) REFERENCES commands(workspace_id, command_id)
    -- Ràng buộc hiện hành workspace_idempotency_records_workspace_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ hợp có
    -- workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id) REFERENCES workspaces(workspace_id)
    -- Ràng buộc hiện hành workspace_idempotency_records_workspace_id_user_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ
    -- hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, user_id) REFERENCES memberships(workspace_id, user_id)
    workspace_id uuid NOT NULL REFERENCES workspaces,

    -- Identity kỹ thuật của receipt scoped; dedupe thực sự theo principal/route/key digest, không dựa vào ID này.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành workspace_idempotency_records_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, idempotency_record_id)
    idempotency_record_id uuid NOT NULL,

    -- Principal user trong workspace; NULL nếu request do API key, CHECK yêu cầu đúng một nhánh principal.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    -- Ràng buộc hiện hành workspace_idempotency_records_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn
    -- qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((num_nonnulls(user_id, api_key_id) = 1))
    -- Ràng buộc hiện hành workspace_idempotency_records_workspace_id_user_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ
    -- hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành. FK MATCH SIMPLE mặc định bỏ
    -- kiểm khi có thành phần NULL; CHECK shape riêng vẫn phải đạt.
    -- FOREIGN KEY (workspace_id, user_id) REFERENCES memberships(workspace_id, user_id)
    user_id uuid,

    -- Principal API key của request; NULL nếu dùng user session, FK buộc key thuộc đúng workspace.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    -- Ràng buộc hiện hành fk_idempotency_api_key: khóa ngoại giữ đúng bản ghi cha; tổ hợp có workspace_id giữ quan hệ
    -- trong đúng tenant, không thay kiểm quyền hiện hành. FK MATCH SIMPLE mặc định bỏ kiểm khi có thành phần NULL;
    -- CHECK shape riêng vẫn phải đạt.
    -- FOREIGN KEY (workspace_id, api_key_id) REFERENCES api_keys(workspace_id, api_key_id)
    -- Ràng buộc hiện hành workspace_idempotency_records_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn
    -- qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((num_nonnulls(user_id, api_key_id) = 1))
    api_key_id uuid,

    -- Namespace route canonical gồm identity resource cần thiết; không chỉ là route template khi nhiều target dùng
    -- chung idempotency key.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    route_key text NOT NULL,

    -- Digest idempotency key của client; cùng namespace principal/route tạo identity replay, không chứa secret
    -- response.
    -- bytea: dãy byte nhị phân; tên digest/ciphertext mô tả mục đích, bản thân kiểu không băm hoặc mã hóa dữ liệu.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành workspace_idempotency_records_key_digest_check: CHECK chỉ chặn khi biểu thức là FALSE;
    -- NULL/UNKNOWN vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((octet_length(key_digest) = 32))
    key_digest bytea NOT NULL CHECK(octet_length(key_digest)=32),

    -- Digest 32 byte của request/body đã canonical hóa để phát hiện cùng identity khác nội dung hoặc đối chiếu send
    -- intent.
    -- bytea: dãy byte nhị phân; tên digest/ciphertext mô tả mục đích, bản thân kiểu không băm hoặc mã hóa dữ liệu.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành workspace_idempotency_records_request_digest_check: CHECK chỉ chặn khi biểu thức là FALSE;
    -- NULL/UNKNOWN vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((octet_length(request_digest) = 32))
    request_digest bytea NOT NULL CHECK(octet_length(request_digest)=32),

    -- Thời điểm yêu cầu được backend nhận vào ledger sau kiểm điều kiện; không chứng minh side effect đã thực hiện.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành workspace_idempotency_records_check1: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN
    -- vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((expires_at = (admitted_at + '24:00:00'::interval)))
    admitted_at timestamptz NOT NULL,

    -- Cửa sổ replay admitted_at + 24 giờ; vẫn phải recheck current authorization trước trả receipt.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành workspace_idempotency_records_check1: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN
    -- vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((expires_at = (admitted_at + '24:00:00'::interval)))
    expires_at timestamptz NOT NULL,

    -- Receipt đang IN_PROGRESS hoặc COMPLETED; request_digest phân biệt retry cùng body với conflict cùng key khác
    -- body.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành workspace_idempotency_records_state_check: CHECK chỉ chặn khi biểu thức là FALSE;
    -- NULL/UNKNOWN vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((state = ANY (ARRAY['IN_PROGRESS'::text, 'COMPLETED'::text])))
    state text NOT NULL CHECK(state IN ('IN_PROGRESS','COMPLETED')),

    -- HTTP status đã ghi nhận, miền 100..599 khi có; NULL khi chưa có response đáng tin cậy.
    -- integer: số nguyên có dấu 32 bit; CHECK giới hạn miền nghiệp vụ thay vì chỉ dựa phạm vi kiểu.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    -- Ràng buộc hiện hành workspace_idempotency_records_response_status_check: CHECK chỉ chặn khi biểu thức là FALSE;
    -- NULL/UNKNOWN vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK (((response_status >= 100) AND (response_status <= 599)))
    response_status integer CHECK(response_status BETWEEN 100 AND 599),

    -- Kết quả replay đã loại secret, không lưu one-time credential response để trả lại sau retry.
    -- jsonb: tài liệu JSON lưu dạng nhị phân; kiểm object/scalar không thay validation đầy đủ cấu trúc và tham chiếu
    -- nghiệp vụ.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    sanitized_result jsonb,

    -- Identity command ổn định qua retry/result/reconciliation; không tạo command mới chỉ vì mất response.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    -- Ràng buộc hiện hành workspace_idempotency_records_workspace_id_command_id_fkey: khóa ngoại giữ đúng bản ghi cha;
    -- tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành. FK MATCH SIMPLE mặc định
    -- bỏ kiểm khi có thành phần NULL; CHECK shape riêng vẫn phải đạt.
    -- FOREIGN KEY (workspace_id, command_id) REFERENCES commands(workspace_id, command_id)
    command_id uuid,

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    PRIMARY KEY(workspace_id,idempotency_record_id),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,user_id) REFERENCES memberships,

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,command_id) REFERENCES commands,

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    CHECK(num_nonnulls(user_id,api_key_id)=1),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    CHECK(expires_at=admitted_at+interval '24 hours')
);
/* Body hash không thuộc khóa replay: cùng key khác body phải conflict. */
CREATE UNIQUE INDEX uq_workspace_idempotency_user ON workspace_idempotency_records(workspace_id,user_id,route_key,key_digest) WHERE user_id IS NOT NULL;
CREATE UNIQUE INDEX uq_workspace_idempotency_api_key ON workspace_idempotency_records(workspace_id,api_key_id,route_key,key_digest) WHERE api_key_id IS NOT NULL;
-- Bảng outbox_events: Sự kiện nội bộ được producer ghi cùng transaction nghiệp vụ. Payload/version và event key ổn
-- định cho các consumer xử lý sau commit, không thay network bằng transaction dài.
CREATE TABLE outbox_events (
    -- Identity outbox event đã commit, dùng ghép trạng thái riêng của từng consumer và claim/complete receipt.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành outbox_events_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì uniqueness áp
    -- dụng cho cả tổ hợp.
    -- PRIMARY KEY (outbox_event_id)
    outbox_event_id uuid PRIMARY KEY,

    -- Scope sự kiện; NULL là namespace IAM/global riêng, không được nhầm với quyền truy cập mọi workspace.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    -- Ràng buộc hiện hành outbox_events_workspace_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ hợp có workspace_id giữ
    -- quan hệ trong đúng tenant, không thay kiểm quyền hiện hành. FK MATCH SIMPLE mặc định bỏ kiểm khi có thành phần
    -- NULL; CHECK shape riêng vẫn phải đạt.
    -- FOREIGN KEY (workspace_id) REFERENCES workspaces(workspace_id)
    workspace_id uuid REFERENCES workspaces,

    -- Khóa nghĩa vụ outbox ổn định để dedupe trong namespace workspace hoặc global IAM; không sinh key mới cho cùng
    -- retry.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    event_key text NOT NULL,

    -- Loại sự kiện được audit/outbox/webhook sử dụng; ý nghĩa/allowlist phụ thuộc bảng và schema contract.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    event_type text NOT NULL,

    -- Phiên bản schema payload outbox để consumer đọc đúng cấu trúc, không nhầm với entity revision.
    -- integer: số nguyên có dấu 32 bit; CHECK giới hạn miền nghiệp vụ thay vì chỉ dựa phạm vi kiểu.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành outbox_events_payload_schema_version_check: CHECK chỉ chặn khi biểu thức là FALSE;
    -- NULL/UNKNOWN vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((payload_schema_version > 0))
    payload_schema_version integer NOT NULL CHECK(payload_schema_version>0),

    -- Document sự kiện nội bộ theo payload_schema_version; producer phải validation/redact trước ghi, không dùng thay
    -- authority entity.
    -- jsonb: tài liệu JSON lưu dạng nhị phân; kiểm object/scalar không thay validation đầy đủ cấu trúc và tham chiếu
    -- nghiệp vụ.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành outbox_events_payload_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua,
    -- nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((jsonb_typeof(payload) = 'object'::text))
    payload jsonb NOT NULL CHECK(jsonb_typeof(payload)='object'),

    -- Thời điểm tạo bản ghi dưới dạng timestamptz; dùng provenance/sắp xếp hoặc retention khi policy của bảng quy
    -- định.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- NOT NULL: bắt buộc có giá trị.
    -- DEFAULT transaction_timestamp(): thời điểm bắt đầu transaction, giữ nguyên trong transaction; không phải đồng hồ
    -- thay đổi theo từng statement.
    created_at timestamptz NOT NULL DEFAULT transaction_timestamp()
);
/* NULL tenant là namespace IAM toàn cục riêng, không để NULL bypass unique. */
CREATE UNIQUE INDEX uq_outbox_workspace_key ON outbox_events(workspace_id,event_key) WHERE workspace_id IS NOT NULL;
CREATE UNIQUE INDEX uq_outbox_global_key ON outbox_events(event_key) WHERE workspace_id IS NULL;
-- Bảng outbox_consumptions: Trạng thái xử lý riêng của từng consumer đối với một outbox event. Lease generation và
-- complete CAS ngăn worker cũ settle công việc sau khi bị takeover.
CREATE TABLE outbox_consumptions (
    -- Identity outbox event đã commit, dùng ghép trạng thái riêng của từng consumer và claim/complete receipt.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành outbox_consumptions_outbox_event_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ hợp có
    -- workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (outbox_event_id) REFERENCES outbox_events(outbox_event_id)
    -- Ràng buộc hiện hành outbox_consumptions_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (outbox_event_id, consumer_code)
    outbox_event_id uuid NOT NULL REFERENCES outbox_events,

    -- Tên pipeline nhận outbox event; mỗi consumer có trạng thái/lease riêng để không ảnh hưởng consumer khác.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành outbox_consumptions_consumer_code_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN
    -- vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((btrim(consumer_code) <> ''::text))
    -- Ràng buộc hiện hành outbox_consumptions_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (outbox_event_id, consumer_code)
    consumer_code text NOT NULL CHECK(btrim(consumer_code)<>''),

    -- Tiến trình consumer PENDING/PROCESSING/RETRY_WAIT/COMPLETED/DEAD_LETTER; COMPLETED phải đi cùng completed_at.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- DEFAULT 'PENDING'::text: giá trị dùng khi INSERT bỏ qua cột; không thay NULL được truyền tường minh và không tự
    -- áp lại khi UPDATE.
    -- Ràng buộc hiện hành outbox_consumptions_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên
    -- phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK (((state = 'COMPLETED'::text) = (completed_at IS NOT NULL)))
    -- Ràng buộc hiện hành outbox_consumptions_state_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn
    -- qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((state = ANY (ARRAY['PENDING'::text, 'PROCESSING'::text, 'RETRY_WAIT'::text, 'COMPLETED'::text,
    -- 'DEAD_LETTER'::text])))
    state text NOT NULL DEFAULT 'PENDING' CHECK(state IN ('PENDING','PROCESSING','RETRY_WAIT','COMPLETED','DEAD_LETTER')),

    -- Thời điểm sớm nhất consumer được claim công việc, phục vụ pending/retry schedule bền vững.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    available_at timestamptz NOT NULL,

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
    -- Ràng buộc hiện hành outbox_consumptions_lease_generation_check: CHECK chỉ chặn khi biểu thức là FALSE;
    -- NULL/UNKNOWN vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((lease_generation >= 0))
    lease_generation bigint NOT NULL DEFAULT 0 CHECK(lease_generation>=0),

    -- Số lần xử lý/claim đã tiêu hao theo pipeline; không tự coi một lần retry là một ý định nghiệp vụ mới.
    -- integer: số nguyên có dấu 32 bit; CHECK giới hạn miền nghiệp vụ thay vì chỉ dựa phạm vi kiểu.
    -- NOT NULL: bắt buộc có giá trị.
    -- DEFAULT 0: giá trị dùng khi INSERT bỏ qua cột; không thay NULL được truyền tường minh và không tự áp lại khi
    -- UPDATE.
    -- Ràng buộc hiện hành outbox_consumptions_attempt_count_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN
    -- vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((attempt_count >= 0))
    attempt_count integer NOT NULL DEFAULT 0 CHECK(attempt_count>=0),

    -- Thời điểm tác vụ hoặc enrollment được ghi nhận hoàn tất theo điều kiện của bảng; không lấy timer client làm bằng
    -- chứng.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    -- Ràng buộc hiện hành outbox_consumptions_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên
    -- phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK (((state = 'COMPLETED'::text) = (completed_at IS NOT NULL)))
    completed_at timestamptz,

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    PRIMARY KEY(outbox_event_id,consumer_code),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    CHECK((state='COMPLETED')=(completed_at IS NOT NULL))
);
/* Consumer đứng đầu phục vụ claim riêng từng pipeline bằng SKIP LOCKED. */
CREATE INDEX ix_outbox_claim ON outbox_consumptions(consumer_code,available_at,outbox_event_id) WHERE state IN ('PENDING','RETRY_WAIT','PROCESSING');
-- Bảng rate_limit_admissions: Nhật ký admission đã tính ngân sách theo policy và principal typed. Dùng đếm rate
-- giữa nhiều backend; login bucket và password-reset admission có ledger chuyên biệt riêng.
CREATE TABLE rate_limit_admissions (
    -- Identity một lần admission đã được ghi nhận trong ledger reset/rate; không phải token dùng xác thực.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành rate_limit_admissions_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (admission_id)
    admission_id uuid PRIMARY KEY,

    -- Workspace của policy scoped; NULL khi policy được phép ở namespace global, API key luôn phải có scope workspace.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    -- Ràng buộc hiện hành fk_rate_limit_api_key: khóa ngoại giữ đúng bản ghi cha; tổ hợp có workspace_id giữ quan hệ
    -- trong đúng tenant, không thay kiểm quyền hiện hành. FK MATCH SIMPLE mặc định bỏ kiểm khi có thành phần NULL;
    -- CHECK shape riêng vẫn phải đạt.
    -- FOREIGN KEY (workspace_id, api_key_id) REFERENCES api_keys(workspace_id, api_key_id)
    -- Ràng buộc hiện hành rate_limit_admissions_check1: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua,
    -- nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK (((api_key_id IS NULL) OR (workspace_id IS NOT NULL)))
    -- Ràng buộc hiện hành rate_limit_admissions_workspace_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ hợp có
    -- workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành. FK MATCH SIMPLE mặc định bỏ kiểm
    -- khi có thành phần NULL; CHECK shape riêng vẫn phải đạt.
    -- FOREIGN KEY (workspace_id) REFERENCES workspaces(workspace_id)
    -- Ràng buộc hiện hành rate_limit_admissions_workspace_id_user_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ hợp có
    -- workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành. FK MATCH SIMPLE mặc định bỏ kiểm
    -- khi có thành phần NULL; CHECK shape riêng vẫn phải đạt.
    -- FOREIGN KEY (workspace_id, user_id) REFERENCES memberships(workspace_id, user_id)
    workspace_id uuid REFERENCES workspaces,

    -- Principal user tiêu hao rate admission; chỉ có đúng một nhánh user_id hoặc api_key_id.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    -- Ràng buộc hiện hành rate_limit_admissions_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua,
    -- nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((num_nonnulls(user_id, api_key_id) = 1))
    -- Ràng buộc hiện hành rate_limit_admissions_user_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ hợp có workspace_id
    -- giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành. FK MATCH SIMPLE mặc định bỏ kiểm khi có thành
    -- phần NULL; CHECK shape riêng vẫn phải đạt.
    -- FOREIGN KEY (user_id) REFERENCES users(user_id)
    -- Ràng buộc hiện hành rate_limit_admissions_workspace_id_user_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ hợp có
    -- workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành. FK MATCH SIMPLE mặc định bỏ kiểm
    -- khi có thành phần NULL; CHECK shape riêng vẫn phải đạt.
    -- FOREIGN KEY (workspace_id, user_id) REFERENCES memberships(workspace_id, user_id)
    user_id uuid REFERENCES users,

    -- Principal API key tiêu hao rate admission, luôn gắn với workspace resolve từ key.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    -- Ràng buộc hiện hành fk_rate_limit_api_key: khóa ngoại giữ đúng bản ghi cha; tổ hợp có workspace_id giữ quan hệ
    -- trong đúng tenant, không thay kiểm quyền hiện hành. FK MATCH SIMPLE mặc định bỏ kiểm khi có thành phần NULL;
    -- CHECK shape riêng vẫn phải đạt.
    -- FOREIGN KEY (workspace_id, api_key_id) REFERENCES api_keys(workspace_id, api_key_id)
    -- Ràng buộc hiện hành rate_limit_admissions_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua,
    -- nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((num_nonnulls(user_id, api_key_id) = 1))
    -- Ràng buộc hiện hành rate_limit_admissions_check1: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua,
    -- nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK (((api_key_id IS NULL) OR (workspace_id IS NOT NULL)))
    api_key_id uuid,

    -- Identity policy rate-limit đã được duyệt, dùng nhóm admission và cửa sổ đếm; không cho client tự chọn policy để
    -- bỏ giới hạn.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành rate_limit_admissions_policy_code_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN
    -- vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((btrim(policy_code) <> ''::text))
    policy_code text NOT NULL CHECK(btrim(policy_code)<>''),

    -- Thời điểm yêu cầu được backend nhận vào ledger sau kiểm điều kiện; không chứng minh side effect đã thực hiện.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    admitted_at timestamptz NOT NULL,

    -- Identity request/flow đã tiêu hao rate admission, dùng truy vết và đối chiếu thay vì đếm lại cùng nghĩa vụ.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    request_correlation_id uuid NOT NULL,

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    CHECK(num_nonnulls(user_id,api_key_id)=1),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    CHECK(api_key_id IS NULL OR workspace_id IS NOT NULL),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,user_id) REFERENCES memberships
);
/* Policy/principal trước timestamp cho cửa sổ rate; service dùng lock anchor cùng admission. */
CREATE INDEX ix_rate_limit_user ON rate_limit_admissions(workspace_id,user_id,policy_code,admitted_at) WHERE user_id IS NOT NULL;
CREATE INDEX ix_rate_limit_key ON rate_limit_admissions(workspace_id,api_key_id,policy_code,admitted_at) WHERE api_key_id IS NOT NULL;
