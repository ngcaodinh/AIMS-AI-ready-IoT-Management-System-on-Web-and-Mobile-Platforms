/* Bản chú thích để đọc: ràng buộc hiện hành lấy từ manifest sau mọi forward migration.
 * Runner thực thi byte bất biến trong applied_sql và so token SQL với bản này; không sửa ledger.
 */
/* Automation/command/dashboard phụ thuộc device pin0002; cycle FK được đóng cuối migration.
 * Không dispatch mạng, không reset dữ liệu; writer bị khóa ở0007 trước mở ứng dụng.
 */
-- Bảng actuator_states: Trạng thái một kênh điều khiển của thiết bị, gồm manual epoch và giá trị được thiết bị
-- báo. Có thể giữ command chưa đối soát; không coi giá trị người dùng yêu cầu là reported truth.
CREATE TABLE actuator_states (
    -- Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền
    -- của người gọi.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành actuator_states_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì uniqueness áp
    -- dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, device_id, stream_key)
    -- Ràng buộc hiện hành actuator_states_workspace_id_device_id_pinned_template_ver_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, device_id, pinned_template_version_id) REFERENCES devices(workspace_id, device_id,
    -- template_version_id)
    -- Ràng buộc hiện hành actuator_states_workspace_id_pinned_template_version_id_st_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, pinned_template_version_id, stream_key) REFERENCES
    -- datastream_definitions(workspace_id, template_version_id, stream_key)
    -- Ràng buộc hiện hành fk_actuator_unresolved_command: khóa ngoại giữ đúng bản ghi cha; tổ hợp có workspace_id giữ
    -- quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, device_id, stream_key, unresolved_command_id) REFERENCES commands(workspace_id,
    -- device_id, stream_key, command_id) DEFERRABLE INITIALLY DEFERRED
    workspace_id uuid NOT NULL,

    -- Identity thiết bị toàn cục để resolve MQTT và registry; kết hợp workspace_id bảo vệ mọi tham chiếu trong đúng
    -- tenant.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành actuator_states_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì uniqueness áp
    -- dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, device_id, stream_key)
    -- Ràng buộc hiện hành actuator_states_workspace_id_device_id_pinned_template_ver_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, device_id, pinned_template_version_id) REFERENCES devices(workspace_id, device_id,
    -- template_version_id)
    -- Ràng buộc hiện hành fk_actuator_unresolved_command: khóa ngoại giữ đúng bản ghi cha; tổ hợp có workspace_id giữ
    -- quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, device_id, stream_key, unresolved_command_id) REFERENCES commands(workspace_id,
    -- device_id, stream_key, command_id) DEFERRABLE INITIALLY DEFERRED
    device_id uuid NOT NULL,

    -- Khóa kỹ thuật ổn định của kênh trong template/version; không dùng nhãn hiển thị thay khóa schema.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành actuator_states_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì uniqueness áp
    -- dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, device_id, stream_key)
    -- Ràng buộc hiện hành actuator_states_workspace_id_pinned_template_version_id_st_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, pinned_template_version_id, stream_key) REFERENCES
    -- datastream_definitions(workspace_id, template_version_id, stream_key)
    -- Ràng buộc hiện hành fk_actuator_unresolved_command: khóa ngoại giữ đúng bản ghi cha; tổ hợp có workspace_id giữ
    -- quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, device_id, stream_key, unresolved_command_id) REFERENCES commands(workspace_id,
    -- device_id, stream_key, command_id) DEFERRABLE INITIALLY DEFERRED
    stream_key text NOT NULL,

    -- Template version cố định của device/actuator, lặp để FK kiểm stream đúng pin thay vì chỉ đúng tên kênh.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành actuator_states_workspace_id_device_id_pinned_template_ver_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, device_id, pinned_template_version_id) REFERENCES devices(workspace_id, device_id,
    -- template_version_id)
    -- Ràng buộc hiện hành actuator_states_workspace_id_pinned_template_version_id_st_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, pinned_template_version_id, stream_key) REFERENCES
    -- datastream_definitions(workspace_id, template_version_id, stream_key)
    pinned_template_version_id uuid NOT NULL,

    -- Bộ đếm thao tác điều khiển thủ công/integration làm thay đổi ưu tiên actuator; dùng ngăn automation cũ ghi đè
    -- thao tác mới.
    -- bigint: số nguyên có dấu 64 bit, phù hợp bộ đếm/generation tăng lâu dài; không tự tăng nếu chưa có cơ chế cấp
    -- giá trị.
    -- NOT NULL: bắt buộc có giá trị.
    -- DEFAULT 0: giá trị dùng khi INSERT bỏ qua cột; không thay NULL được truyền tường minh và không tự áp lại khi
    -- UPDATE.
    -- Ràng buộc hiện hành actuator_states_manual_epoch_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn
    -- qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((manual_epoch >= 0))
    manual_epoch bigint NOT NULL DEFAULT 0 CHECK(manual_epoch>=0),

    -- Giá trị đầu ra được thiết bị xác nhận gần nhất; không cập nhật thành target chỉ vì command đã admission.
    -- jsonb: tài liệu JSON lưu dạng nhị phân; kiểm object/scalar không thay validation đầy đủ cấu trúc và tham chiếu
    -- nghiệp vụ.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    last_reported_value jsonb,

    -- Thời điểm của reported observation gần nhất được chấp nhận, phục vụ hiển thị độ mới của trạng thái đầu ra.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    last_reported_at timestamptz,

    -- Nguồn của reported value NONE/DEVICE_RESULT/TELEMETRY/HELLO để phân biệt bằng chứng thiết bị với giá trị người
    -- dùng yêu cầu.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- DEFAULT 'NONE'::text: giá trị dùng khi INSERT bỏ qua cột; không thay NULL được truyền tường minh và không tự áp
    -- lại khi UPDATE.
    -- Ràng buộc hiện hành actuator_states_reported_source_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN
    -- vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((reported_source = ANY (ARRAY['NONE'::text, 'DEVICE_RESULT'::text, 'TELEMETRY'::text, 'HELLO'::text])))
    reported_source text NOT NULL DEFAULT 'NONE' CHECK(reported_source IN ('NONE','DEVICE_RESULT','TELEMETRY','HELLO')),

    -- Command còn cần đối soát trên actuator; NULL khi không giữ guard này, không tự chứng minh physical output an
    -- toàn.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    -- Ràng buộc hiện hành fk_actuator_unresolved_command: khóa ngoại giữ đúng bản ghi cha; tổ hợp có workspace_id giữ
    -- quan hệ trong đúng tenant, không thay kiểm quyền hiện hành. FK MATCH SIMPLE mặc định bỏ kiểm khi có thành phần
    -- NULL; CHECK shape riêng vẫn phải đạt.
    -- FOREIGN KEY (workspace_id, device_id, stream_key, unresolved_command_id) REFERENCES commands(workspace_id,
    -- device_id, stream_key, command_id) DEFERRABLE INITIALLY DEFERRED
    unresolved_command_id uuid,

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    PRIMARY KEY(workspace_id,device_id,stream_key),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,device_id,pinned_template_version_id) REFERENCES devices(workspace_id,device_id,template_version_id),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,pinned_template_version_id,stream_key) REFERENCES datastream_definitions
);
-- Bảng dashboards: Gốc dashboard do một thành viên sở hữu, chứa tên, trạng thái và revision. Các widget/binding là
-- dữ liệu con để lưu một cấu hình nguyên tử qua CAS.
CREATE TABLE dashboards (
    -- Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền
    -- của người gọi.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành dashboards_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì uniqueness áp dụng
    -- cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, dashboard_id)
    -- Ràng buộc hiện hành dashboards_workspace_id_owner_user_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ hợp có
    -- workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, owner_user_id) REFERENCES memberships(workspace_id, user_id)
    workspace_id uuid NOT NULL,

    -- Identity dashboard trong workspace, dùng nhóm widget và kiểm owner/revision khi lưu cấu hình.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành dashboards_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì uniqueness áp dụng
    -- cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, dashboard_id)
    dashboard_id uuid NOT NULL,

    -- Tài khoản sở hữu tài nguyên trong workspace; backend phải kiểm membership và quyền hiện hành khi đọc/ghi.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành dashboards_workspace_id_owner_user_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ hợp có
    -- workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, owner_user_id) REFERENCES memberships(workspace_id, user_id)
    owner_user_id uuid NOT NULL,

    -- Tiêu đề hiển thị của dashboard hoặc sự kiện; là nội dung giao diện, không dùng thay identity tài nguyên.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    title text NOT NULL,

    -- Phiên bản cấu trúc document dashboard/rule, hiện 1; khác revision chỉnh sửa và version publish.
    -- integer: số nguyên có dấu 32 bit; CHECK giới hạn miền nghiệp vụ thay vì chỉ dựa phạm vi kiểu.
    -- NOT NULL: bắt buộc có giá trị.
    -- DEFAULT 1: giá trị dùng khi INSERT bỏ qua cột; không thay NULL được truyền tường minh và không tự áp lại khi
    -- UPDATE.
    -- Ràng buộc hiện hành dashboards_schema_version_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn
    -- qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((schema_version = 1))
    schema_version integer NOT NULL DEFAULT 1 CHECK(schema_version=1),

    -- Phiên bản chỉnh sửa bản ghi dùng cho CAS/If-Match hoặc đối soát; bên ghi chịu trách nhiệm cập nhật theo đúng
    -- transaction contract.
    -- bigint: số nguyên có dấu 64 bit, phù hợp bộ đếm/generation tăng lâu dài; không tự tăng nếu chưa có cơ chế cấp
    -- giá trị.
    -- NOT NULL: bắt buộc có giá trị.
    -- DEFAULT 1: giá trị dùng khi INSERT bỏ qua cột; không thay NULL được truyền tường minh và không tự áp lại khi
    -- UPDATE.
    -- Ràng buộc hiện hành dashboards_revision_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên
    -- phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((revision > 0))
    revision bigint NOT NULL DEFAULT 1 CHECK(revision>0),

    -- Trạng thái vòng đời quản lý tài nguyên, tách khỏi presence hoặc tiến độ của job đang chạy.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- DEFAULT 'ACTIVE'::text: giá trị dùng khi INSERT bỏ qua cột; không thay NULL được truyền tường minh và không tự
    -- áp lại khi UPDATE.
    -- Ràng buộc hiện hành dashboards_lifecycle_status_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn
    -- qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((lifecycle_status = ANY (ARRAY['ACTIVE'::text, 'ARCHIVED'::text])))
    lifecycle_status text NOT NULL DEFAULT 'ACTIVE' CHECK(lifecycle_status IN ('ACTIVE','ARCHIVED')),

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

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    PRIMARY KEY(workspace_id,dashboard_id),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,owner_user_id) REFERENCES memberships
);
-- Bảng dashboard_widgets: Từng widget trong dashboard: loại hiển thị/điều khiển, thứ tự trên mobile và bố cục
-- grid. Presentation giữ cấu hình của loại widget, không là nơi lưu credential hoặc script tùy ý.
CREATE TABLE dashboard_widgets (
    -- Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền
    -- của người gọi.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành dashboard_widgets_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì uniqueness
    -- áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, dashboard_id, widget_id)
    -- Ràng buộc hiện hành dashboard_widgets_workspace_id_dashboard_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ hợp có
    -- workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, dashboard_id) REFERENCES dashboards(workspace_id, dashboard_id)
    -- Ràng buộc hiện hành dashboard_widgets_workspace_id_dashboard_id_position_key: không trùng tổ hợp giá trị được
    -- nêu; các cột riêng lẻ vẫn có thể lặp khi khóa có nhiều cột.
    -- UNIQUE (workspace_id, dashboard_id, "position")
    workspace_id uuid NOT NULL,

    -- Identity dashboard trong workspace, dùng nhóm widget và kiểm owner/revision khi lưu cấu hình.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành dashboard_widgets_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì uniqueness
    -- áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, dashboard_id, widget_id)
    -- Ràng buộc hiện hành dashboard_widgets_workspace_id_dashboard_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ hợp có
    -- workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, dashboard_id) REFERENCES dashboards(workspace_id, dashboard_id)
    -- Ràng buộc hiện hành dashboard_widgets_workspace_id_dashboard_id_position_key: không trùng tổ hợp giá trị được
    -- nêu; các cột riêng lẻ vẫn có thể lặp khi khóa có nhiều cột.
    -- UNIQUE (workspace_id, dashboard_id, "position")
    dashboard_id uuid NOT NULL,

    -- Identity widget trong dashboard, giữ binding đúng thành phần dù thay layout hoặc thứ tự mobile.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành dashboard_widgets_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì uniqueness
    -- áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, dashboard_id, widget_id)
    widget_id uuid NOT NULL,

    -- Loại widget VALUE/GAUGE/STATUS/SWITCH/BUTTON/CHART; backend còn phải kiểm tương thích datatype/capability và
    -- config.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành dashboard_widgets_widget_type_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn
    -- qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((widget_type = ANY (ARRAY['VALUE'::text, 'GAUGE'::text, 'STATUS'::text, 'SWITCH'::text, 'BUTTON'::text,
    -- 'CHART'::text])))
    widget_type text NOT NULL CHECK(widget_type IN ('VALUE','GAUGE','STATUS','SWITCH','BUTTON','CHART')),

    -- Thứ tự widget trên mobile, từ 0 đến 19 và duy nhất trong dashboard; khác tọa độ layout grid Web.
    -- integer: số nguyên có dấu 32 bit; CHECK giới hạn miền nghiệp vụ thay vì chỉ dựa phạm vi kiểu.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành dashboard_widgets_position_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn
    -- qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((("position" >= 0) AND ("position" <= 19)))
    -- Ràng buộc hiện hành dashboard_widgets_workspace_id_dashboard_id_position_key: không trùng tổ hợp giá trị được
    -- nêu; các cột riêng lẻ vẫn có thể lặp khi khóa có nhiều cột.
    -- UNIQUE (workspace_id, dashboard_id, "position")
    position integer NOT NULL CHECK(position BETWEEN 0 AND 19),

    -- Cấu hình hiển thị theo loại widget dưới dạng JSON object; không phải nơi lưu resource authority, secret hoặc
    -- script tùy ý.
    -- jsonb: tài liệu JSON lưu dạng nhị phân; kiểm object/scalar không thay validation đầy đủ cấu trúc và tham chiếu
    -- nghiệp vụ.
    -- NOT NULL: bắt buộc có giá trị.
    -- DEFAULT '{}'::jsonb: giá trị dùng khi INSERT bỏ qua cột; không thay NULL được truyền tường minh và không tự áp
    -- lại khi UPDATE.
    -- Ràng buộc hiện hành dashboard_widgets_presentation_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN
    -- vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((jsonb_typeof(presentation) = 'object'::text))
    presentation jsonb NOT NULL DEFAULT '{}' CHECK(jsonb_typeof(presentation)='object'),

    -- Tọa độ cột bắt đầu trong grid Web 12 cột, từ 0 đến 11; phải cộng width không vượt 12.
    -- integer: số nguyên có dấu 32 bit; CHECK giới hạn miền nghiệp vụ thay vì chỉ dựa phạm vi kiểu.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành dashboard_widgets_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên
    -- phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK (((layout_x + layout_width) <= 12))
    -- Ràng buộc hiện hành dashboard_widgets_layout_x_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn
    -- qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK (((layout_x >= 0) AND (layout_x <= 11)))
    layout_x integer NOT NULL CHECK(layout_x BETWEEN 0 AND 11),

    -- Tọa độ hàng bắt đầu của widget trong grid Web, không âm; khác mobile order.
    -- integer: số nguyên có dấu 32 bit; CHECK giới hạn miền nghiệp vụ thay vì chỉ dựa phạm vi kiểu.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành dashboard_widgets_layout_y_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn
    -- qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((layout_y >= 0))
    layout_y integer NOT NULL CHECK(layout_y>=0),

    -- Số cột grid mà widget chiếm, lớn hơn 0; tổng với layout_x phải nằm trong 12 cột.
    -- integer: số nguyên có dấu 32 bit; CHECK giới hạn miền nghiệp vụ thay vì chỉ dựa phạm vi kiểu.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành dashboard_widgets_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên
    -- phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK (((layout_x + layout_width) <= 12))
    -- Ràng buộc hiện hành dashboard_widgets_layout_width_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN
    -- vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((layout_width > 0))
    layout_width integer NOT NULL CHECK(layout_width>0),

    -- Số đơn vị hàng grid mà widget chiếm, lớn hơn 0; không phải pixel hoặc số mẫu lịch sử.
    -- integer: số nguyên có dấu 32 bit; CHECK giới hạn miền nghiệp vụ thay vì chỉ dựa phạm vi kiểu.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành dashboard_widgets_layout_height_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN
    -- vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((layout_height > 0))
    layout_height integer NOT NULL CHECK(layout_height>0),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    PRIMARY KEY(workspace_id,dashboard_id,widget_id),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    UNIQUE(workspace_id,dashboard_id,position),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,dashboard_id) REFERENCES dashboards,

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    CHECK(layout_x+layout_width<=12)
);
/* Presence không có stream; tuple pin/stream cùng NULL hoặc cùng có, device luôn scoped. */
-- Bảng dashboard_widget_bindings: Liên kết từng slot widget với thiết bị và kênh đã pin. Presence binding có thể
-- không có stream; FK và shape bảo vệ tham chiếu trong đúng workspace/version.
CREATE TABLE dashboard_widget_bindings (
    -- Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền
    -- của người gọi.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành dashboard_widget_bindings_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, dashboard_id, widget_id, binding_slot)
    -- Ràng buộc hiện hành dashboard_widget_bindings_workspace_id_dashboard_id_widget_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, dashboard_id, widget_id) REFERENCES dashboard_widgets(workspace_id, dashboard_id,
    -- widget_id)
    -- Ràng buộc hiện hành dashboard_widget_bindings_workspace_id_device_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ
    -- hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, device_id) REFERENCES devices(workspace_id, device_id)
    -- Ràng buộc hiện hành dashboard_widget_bindings_workspace_id_device_id_template__fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, device_id, template_version_id) REFERENCES devices(workspace_id, device_id,
    -- template_version_id)
    -- Ràng buộc hiện hành dashboard_widget_bindings_workspace_id_template_version_id_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, template_version_id, stream_key) REFERENCES datastream_definitions(workspace_id,
    -- template_version_id, stream_key)
    workspace_id uuid NOT NULL,

    -- Identity dashboard trong workspace, dùng nhóm widget và kiểm owner/revision khi lưu cấu hình.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành dashboard_widget_bindings_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, dashboard_id, widget_id, binding_slot)
    -- Ràng buộc hiện hành dashboard_widget_bindings_workspace_id_dashboard_id_widget_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, dashboard_id, widget_id) REFERENCES dashboard_widgets(workspace_id, dashboard_id,
    -- widget_id)
    dashboard_id uuid NOT NULL,

    -- Identity widget trong dashboard, giữ binding đúng thành phần dù thay layout hoặc thứ tự mobile.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành dashboard_widget_bindings_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, dashboard_id, widget_id, binding_slot)
    -- Ràng buộc hiện hành dashboard_widget_bindings_workspace_id_dashboard_id_widget_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, dashboard_id, widget_id) REFERENCES dashboard_widgets(workspace_id, dashboard_id,
    -- widget_id)
    widget_id uuid NOT NULL,

    -- Tên slot dữ liệu/điều khiển của widget, để một widget có thể liên kết từng nhu cầu với resource đúng scope.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành dashboard_widget_bindings_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, dashboard_id, widget_id, binding_slot)
    binding_slot text NOT NULL,

    -- Identity thiết bị toàn cục để resolve MQTT và registry; kết hợp workspace_id bảo vệ mọi tham chiếu trong đúng
    -- tenant.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành dashboard_widget_bindings_workspace_id_device_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ
    -- hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, device_id) REFERENCES devices(workspace_id, device_id)
    -- Ràng buộc hiện hành dashboard_widget_bindings_workspace_id_device_id_template__fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, device_id, template_version_id) REFERENCES devices(workspace_id, device_id,
    -- template_version_id)
    device_id uuid NOT NULL,

    -- Pin version cho stream binding; cùng NULL với stream_key khi binding là presence của device.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    -- Ràng buộc hiện hành dashboard_widget_bindings_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn
    -- qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK (((template_version_id IS NULL) = (stream_key IS NULL)))
    -- Ràng buộc hiện hành dashboard_widget_bindings_workspace_id_device_id_template__fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành. FK MATCH SIMPLE mặc
    -- định bỏ kiểm khi có thành phần NULL; CHECK shape riêng vẫn phải đạt.
    -- FOREIGN KEY (workspace_id, device_id, template_version_id) REFERENCES devices(workspace_id, device_id,
    -- template_version_id)
    -- Ràng buộc hiện hành dashboard_widget_bindings_workspace_id_template_version_id_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành. FK MATCH SIMPLE mặc
    -- định bỏ kiểm khi có thành phần NULL; CHECK shape riêng vẫn phải đạt.
    -- FOREIGN KEY (workspace_id, template_version_id, stream_key) REFERENCES datastream_definitions(workspace_id,
    -- template_version_id, stream_key)
    template_version_id uuid,

    -- Kênh pinned của stream binding; cùng NULL với template_version_id khi slot dùng presence, device_id vẫn bắt
    -- buộc.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    -- Ràng buộc hiện hành dashboard_widget_bindings_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn
    -- qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK (((template_version_id IS NULL) = (stream_key IS NULL)))
    -- Ràng buộc hiện hành dashboard_widget_bindings_workspace_id_template_version_id_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành. FK MATCH SIMPLE mặc
    -- định bỏ kiểm khi có thành phần NULL; CHECK shape riêng vẫn phải đạt.
    -- FOREIGN KEY (workspace_id, template_version_id, stream_key) REFERENCES datastream_definitions(workspace_id,
    -- template_version_id, stream_key)
    stream_key text,

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    PRIMARY KEY(workspace_id,dashboard_id,widget_id,binding_slot),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,dashboard_id,widget_id) REFERENCES dashboard_widgets,

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,device_id) REFERENCES devices(workspace_id,device_id),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,device_id,template_version_id) REFERENCES devices(workspace_id,device_id,template_version_id),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,template_version_id,stream_key) REFERENCES datastream_definitions,

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    CHECK((template_version_id IS NULL)=(stream_key IS NULL))
);
-- Bảng rules: Gốc rule thuộc một owner: metadata, trạng thái bật/tắt, revision draft và con trỏ phiên bản đang
-- dùng. Draft và version runtime được tách để chỉnh sửa không thay execution đang chạy.
CREATE TABLE rules (
    -- Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền
    -- của người gọi.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành fk_rules_active_version: khóa ngoại giữ đúng bản ghi cha; tổ hợp có workspace_id giữ quan hệ
    -- trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, rule_id, active_rule_version_id) REFERENCES rule_versions(workspace_id, rule_id,
    -- rule_version_id) DEFERRABLE INITIALLY DEFERRED
    -- Ràng buộc hiện hành rules_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì uniqueness áp dụng cho
    -- cả tổ hợp.
    -- PRIMARY KEY (workspace_id, rule_id)
    -- Ràng buộc hiện hành rules_workspace_id_owner_user_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ hợp có
    -- workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, owner_user_id) REFERENCES memberships(workspace_id, user_id)
    workspace_id uuid NOT NULL,

    -- Identity gốc rule trong workspace, dùng nhóm draft/version/runtime; không là identity một lần chạy.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành fk_rules_active_version: khóa ngoại giữ đúng bản ghi cha; tổ hợp có workspace_id giữ quan hệ
    -- trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, rule_id, active_rule_version_id) REFERENCES rule_versions(workspace_id, rule_id,
    -- rule_version_id) DEFERRABLE INITIALLY DEFERRED
    -- Ràng buộc hiện hành rules_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì uniqueness áp dụng cho
    -- cả tổ hợp.
    -- PRIMARY KEY (workspace_id, rule_id)
    rule_id uuid NOT NULL,

    -- Tài khoản sở hữu tài nguyên trong workspace; backend phải kiểm membership và quyền hiện hành khi đọc/ghi.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành rules_workspace_id_owner_user_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ hợp có
    -- workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, owner_user_id) REFERENCES memberships(workspace_id, user_id)
    owner_user_id uuid NOT NULL,

    -- Tên hiển thị do người dùng đặt cho tài nguyên; không dùng làm identity, quyền hoặc khóa chống lặp.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    name text NOT NULL,

    -- Trạng thái vòng đời quản lý tài nguyên, tách khỏi presence hoặc tiến độ của job đang chạy.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- DEFAULT 'DRAFT'::text: giá trị dùng khi INSERT bỏ qua cột; không thay NULL được truyền tường minh và không tự áp
    -- lại khi UPDATE.
    -- Ràng buộc hiện hành rules_lifecycle_status_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua,
    -- nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((lifecycle_status = ANY (ARRAY['DRAFT'::text, 'ENABLED'::text, 'DISABLED'::text, 'ARCHIVED'::text,
    -- 'ERROR_DISABLED'::text])))
    lifecycle_status text NOT NULL DEFAULT 'DRAFT' CHECK(lifecycle_status IN ('DRAFT','ENABLED','DISABLED','ARCHIVED','ERROR_DISABLED')),

    -- Phiên bản chỉnh sửa bản ghi dùng cho CAS/If-Match hoặc đối soát; bên ghi chịu trách nhiệm cập nhật theo đúng
    -- transaction contract.
    -- bigint: số nguyên có dấu 64 bit, phù hợp bộ đếm/generation tăng lâu dài; không tự tăng nếu chưa có cơ chế cấp
    -- giá trị.
    -- NOT NULL: bắt buộc có giá trị.
    -- DEFAULT 1: giá trị dùng khi INSERT bỏ qua cột; không thay NULL được truyền tường minh và không tự áp lại khi
    -- UPDATE.
    -- Ràng buộc hiện hành rules_revision_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên phải
    -- phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((revision > 0))
    revision bigint NOT NULL DEFAULT 1 CHECK(revision>0),

    -- Phiên bản chỉnh sửa của draft rule, tách khỏi revision metadata root và version_number của snapshot đã publish.
    -- bigint: số nguyên có dấu 64 bit, phù hợp bộ đếm/generation tăng lâu dài; không tự tăng nếu chưa có cơ chế cấp
    -- giá trị.
    -- NOT NULL: bắt buộc có giá trị.
    -- DEFAULT 1: giá trị dùng khi INSERT bỏ qua cột; không thay NULL được truyền tường minh và không tự áp lại khi
    -- UPDATE.
    -- Ràng buộc hiện hành rules_draft_revision_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên
    -- phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((draft_revision > 0))
    draft_revision bigint NOT NULL DEFAULT 1 CHECK(draft_revision>0),

    -- Version đang được rule chọn để thực thi; FK buộc thuộc cùng rule, khác draft đang chỉnh.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    -- Ràng buộc hiện hành fk_rules_active_version: khóa ngoại giữ đúng bản ghi cha; tổ hợp có workspace_id giữ quan hệ
    -- trong đúng tenant, không thay kiểm quyền hiện hành. FK MATCH SIMPLE mặc định bỏ kiểm khi có thành phần NULL;
    -- CHECK shape riêng vẫn phải đạt.
    -- FOREIGN KEY (workspace_id, rule_id, active_rule_version_id) REFERENCES rule_versions(workspace_id, rule_id,
    -- rule_version_id) DEFERRABLE INITIALLY DEFERRED
    active_rule_version_id uuid,

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

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    PRIMARY KEY(workspace_id,rule_id),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,owner_user_id) REFERENCES memberships
);
-- Bảng rule_drafts: Nội dung rule hiện đang soạn: trigger, AST điều kiện và policy. Chưa là định nghĩa được thực
-- thi cho đến khi được validate và publish.
CREATE TABLE rule_drafts (
    -- Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền
    -- của người gọi.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành rule_drafts_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì uniqueness áp
    -- dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, rule_id)
    -- Ràng buộc hiện hành rule_drafts_workspace_id_rule_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ hợp có
    -- workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, rule_id) REFERENCES rules(workspace_id, rule_id)
    workspace_id uuid NOT NULL,

    -- Identity gốc rule trong workspace, dùng nhóm draft/version/runtime; không là identity một lần chạy.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành rule_drafts_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì uniqueness áp
    -- dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, rule_id)
    -- Ràng buộc hiện hành rule_drafts_workspace_id_rule_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ hợp có
    -- workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, rule_id) REFERENCES rules(workspace_id, rule_id)
    rule_id uuid NOT NULL,

    -- Nguồn kích hoạt THRESHOLD/SCHEDULE/CONNECTIVITY/MANUAL của rule, quyết định shape trigger_config cần validate.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành rule_drafts_trigger_type_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua,
    -- nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((trigger_type = ANY (ARRAY['THRESHOLD'::text, 'SCHEDULE'::text, 'CONNECTIVITY'::text, 'MANUAL'::text])))
    trigger_type text NOT NULL CHECK(trigger_type IN ('THRESHOLD','SCHEDULE','CONNECTIVITY','MANUAL')),

    -- Cấu hình trigger theo schema version; JSON object CHECK chỉ kiểm dạng ngoài, không thay validator typed và quyền
    -- resource.
    -- jsonb: tài liệu JSON lưu dạng nhị phân; kiểm object/scalar không thay validation đầy đủ cấu trúc và tham chiếu
    -- nghiệp vụ.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành rule_drafts_trigger_config_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn
    -- qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((jsonb_typeof(trigger_config) = 'object'::text))
    trigger_config jsonb NOT NULL CHECK(jsonb_typeof(trigger_config)='object'),

    -- Cây điều kiện AND/OR/literal theo rule contract; backend phải kiểm depth/type/leaves và bijection với reference
    -- rows.
    -- jsonb: tài liệu JSON lưu dạng nhị phân; kiểm object/scalar không thay validation đầy đủ cấu trúc và tham chiếu
    -- nghiệp vụ.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành rule_drafts_condition_ast_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn
    -- qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((jsonb_typeof(condition_ast) = 'object'::text))
    condition_ast jsonb NOT NULL CHECK(jsonb_typeof(condition_ast)='object'),

    -- Phiên bản cấu trúc document dashboard/rule, hiện 1; khác revision chỉnh sửa và version publish.
    -- integer: số nguyên có dấu 32 bit; CHECK giới hạn miền nghiệp vụ thay vì chỉ dựa phạm vi kiểu.
    -- NOT NULL: bắt buộc có giá trị.
    -- DEFAULT 1: giá trị dùng khi INSERT bỏ qua cột; không thay NULL được truyền tường minh và không tự áp lại khi
    -- UPDATE.
    -- Ràng buộc hiện hành rule_drafts_schema_version_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn
    -- qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((schema_version = 1))
    schema_version integer NOT NULL DEFAULT 1 CHECK(schema_version=1),

    -- Thời gian nghỉ tối thiểu giữa các lần admission rule, đơn vị giây, từ 10 đến 3600 theo policy rule.
    -- integer: số nguyên có dấu 32 bit; CHECK giới hạn miền nghiệp vụ thay vì chỉ dựa phạm vi kiểu.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành rule_drafts_cooldown_seconds_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn
    -- qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK (((cooldown_seconds >= 10) AND (cooldown_seconds <= 3600)))
    cooldown_seconds integer NOT NULL CHECK(cooldown_seconds BETWEEN 10 AND 3600),

    -- Mức ưu tiên HIGH/NORMAL/LOW của rule, không tự cho quyền vượt manual epoch hoặc guard actuator.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành rule_drafts_priority_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên
    -- phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((priority = ANY (ARRAY['HIGH'::text, 'NORMAL'::text, 'LOW'::text])))
    priority text NOT NULL CHECK(priority IN ('HIGH','NORMAL','LOW')),

    -- Policy STOP/CONTINUE cho lỗi đã biết của chuỗi; UNKNOWN vẫn cần dừng/đối soát theo contract, không tự chạy bước
    -- sau.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành rule_drafts_on_failure_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua,
    -- nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((on_failure = ANY (ARRAY['STOP'::text, 'CONTINUE'::text])))
    on_failure text NOT NULL CHECK(on_failure IN ('STOP','CONTINUE')),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    PRIMARY KEY(workspace_id,rule_id),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,rule_id) REFERENCES rules
);
-- Bảng rule_draft_actions: Chuỗi action của rule draft theo thứ tự, với các nhánh SET_VALUE/WAIT/NOTIFY được biểu
-- diễn typed. Lưu cấu hình hành động, không lưu kết quả chạy.
CREATE TABLE rule_draft_actions (
    -- Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền
    -- của người gọi.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành rule_draft_actions_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì uniqueness
    -- áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, rule_id, action_position)
    -- Ràng buộc hiện hành rule_draft_actions_workspace_id_rule_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ hợp có
    -- workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, rule_id) REFERENCES rule_drafts(workspace_id, rule_id)
    -- Ràng buộc hiện hành rule_draft_actions_workspace_id_target_device_id_target_te_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, target_device_id, target_template_version_id) REFERENCES devices(workspace_id,
    -- device_id, template_version_id)
    -- Ràng buộc hiện hành rule_draft_actions_workspace_id_target_template_version_id_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, target_template_version_id, target_stream_key) REFERENCES
    -- datastream_definitions(workspace_id, template_version_id, stream_key)
    workspace_id uuid NOT NULL,

    -- Identity gốc rule trong workspace, dùng nhóm draft/version/runtime; không là identity một lần chạy.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành rule_draft_actions_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì uniqueness
    -- áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, rule_id, action_position)
    -- Ràng buộc hiện hành rule_draft_actions_workspace_id_rule_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ hợp có
    -- workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, rule_id) REFERENCES rule_drafts(workspace_id, rule_id)
    rule_id uuid NOT NULL,

    -- Chỉ số action bắt đầu 0 trong chuỗi tối đa 5 bước, dùng ghép definition/action execution/job.
    -- integer: số nguyên có dấu 32 bit; CHECK giới hạn miền nghiệp vụ thay vì chỉ dựa phạm vi kiểu.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành rule_draft_actions_action_position_check: CHECK chỉ chặn khi biểu thức là FALSE;
    -- NULL/UNKNOWN vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK (((action_position >= 0) AND (action_position <= 4)))
    -- Ràng buộc hiện hành rule_draft_actions_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì uniqueness
    -- áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, rule_id, action_position)
    action_position integer NOT NULL CHECK(action_position BETWEEN 0 AND 4),

    -- Loại hành động SET_VALUE/WAIT/NOTIFY; mỗi nhánh yêu cầu bộ trường typed riêng, không chứa code/script tùy ý.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành ck_rule_draft_action_shape: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên
    -- phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((((action_type = 'WAIT'::text) AND (wait_seconds IS NOT NULL) AND ((wait_seconds >= 5) AND (wait_seconds
    -- <= 600)) AND (num_nonnulls(target_device_id, target_template_version_id, target_stream_key, target_value,
    -- notification_config) = 0)) OR ((action_type = 'SET_VALUE'::text) AND (wait_seconds IS NULL) AND
    -- (notification_config IS NULL) AND (num_nonnulls(target_device_id, target_template_version_id, target_stream_key,
    -- target_value) = 4) AND (jsonb_typeof(target_value) = ANY (ARRAY['boolean'::text, 'number'::text,
    -- 'string'::text]))) OR ((action_type = 'NOTIFY'::text) AND (notification_config IS NOT NULL) AND
    -- (jsonb_typeof(notification_config) = 'object'::text) AND (num_nonnulls(wait_seconds, target_device_id,
    -- target_template_version_id, target_stream_key, target_value) = 0))))
    -- Ràng buộc hiện hành rule_draft_actions_action_type_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN
    -- vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((action_type = ANY (ARRAY['SET_VALUE'::text, 'WAIT'::text, 'NOTIFY'::text])))
    action_type text NOT NULL CHECK(action_type IN ('SET_VALUE','WAIT','NOTIFY')),

    -- Thời lượng WAIT theo giây, từ 5 đến 600 cho một bước; tổng WAIT của version còn bị giới hạn 600 giây.
    -- integer: số nguyên có dấu 32 bit; CHECK giới hạn miền nghiệp vụ thay vì chỉ dựa phạm vi kiểu.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    -- Ràng buộc hiện hành ck_rule_draft_action_shape: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên
    -- phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((((action_type = 'WAIT'::text) AND (wait_seconds IS NOT NULL) AND ((wait_seconds >= 5) AND (wait_seconds
    -- <= 600)) AND (num_nonnulls(target_device_id, target_template_version_id, target_stream_key, target_value,
    -- notification_config) = 0)) OR ((action_type = 'SET_VALUE'::text) AND (wait_seconds IS NULL) AND
    -- (notification_config IS NULL) AND (num_nonnulls(target_device_id, target_template_version_id, target_stream_key,
    -- target_value) = 4) AND (jsonb_typeof(target_value) = ANY (ARRAY['boolean'::text, 'number'::text,
    -- 'string'::text]))) OR ((action_type = 'NOTIFY'::text) AND (notification_config IS NOT NULL) AND
    -- (jsonb_typeof(notification_config) = 'object'::text) AND (num_nonnulls(wait_seconds, target_device_id,
    -- target_template_version_id, target_stream_key, target_value) = 0))))
    wait_seconds integer,

    -- Thiết bị đích của action hoặc deep link; NULL khi nhánh không có device, nếu có phải cùng workspace và đúng pin.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    -- Ràng buộc hiện hành ck_rule_draft_action_shape: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên
    -- phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((((action_type = 'WAIT'::text) AND (wait_seconds IS NOT NULL) AND ((wait_seconds >= 5) AND (wait_seconds
    -- <= 600)) AND (num_nonnulls(target_device_id, target_template_version_id, target_stream_key, target_value,
    -- notification_config) = 0)) OR ((action_type = 'SET_VALUE'::text) AND (wait_seconds IS NULL) AND
    -- (notification_config IS NULL) AND (num_nonnulls(target_device_id, target_template_version_id, target_stream_key,
    -- target_value) = 4) AND (jsonb_typeof(target_value) = ANY (ARRAY['boolean'::text, 'number'::text,
    -- 'string'::text]))) OR ((action_type = 'NOTIFY'::text) AND (notification_config IS NOT NULL) AND
    -- (jsonb_typeof(notification_config) = 'object'::text) AND (num_nonnulls(wait_seconds, target_device_id,
    -- target_template_version_id, target_stream_key, target_value) = 0))))
    -- Ràng buộc hiện hành rule_draft_actions_workspace_id_target_device_id_target_te_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành. FK MATCH SIMPLE mặc
    -- định bỏ kiểm khi có thành phần NULL; CHECK shape riêng vẫn phải đạt.
    -- FOREIGN KEY (workspace_id, target_device_id, target_template_version_id) REFERENCES devices(workspace_id,
    -- device_id, template_version_id)
    target_device_id uuid,

    -- Template version của target device, lặp để FK bảo vệ target stream đúng pin.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    -- Ràng buộc hiện hành ck_rule_draft_action_shape: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên
    -- phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((((action_type = 'WAIT'::text) AND (wait_seconds IS NOT NULL) AND ((wait_seconds >= 5) AND (wait_seconds
    -- <= 600)) AND (num_nonnulls(target_device_id, target_template_version_id, target_stream_key, target_value,
    -- notification_config) = 0)) OR ((action_type = 'SET_VALUE'::text) AND (wait_seconds IS NULL) AND
    -- (notification_config IS NULL) AND (num_nonnulls(target_device_id, target_template_version_id, target_stream_key,
    -- target_value) = 4) AND (jsonb_typeof(target_value) = ANY (ARRAY['boolean'::text, 'number'::text,
    -- 'string'::text]))) OR ((action_type = 'NOTIFY'::text) AND (notification_config IS NOT NULL) AND
    -- (jsonb_typeof(notification_config) = 'object'::text) AND (num_nonnulls(wait_seconds, target_device_id,
    -- target_template_version_id, target_stream_key, target_value) = 0))))
    -- Ràng buộc hiện hành rule_draft_actions_workspace_id_target_device_id_target_te_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành. FK MATCH SIMPLE mặc
    -- định bỏ kiểm khi có thành phần NULL; CHECK shape riêng vẫn phải đạt.
    -- FOREIGN KEY (workspace_id, target_device_id, target_template_version_id) REFERENCES devices(workspace_id,
    -- device_id, template_version_id)
    -- Ràng buộc hiện hành rule_draft_actions_workspace_id_target_template_version_id_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành. FK MATCH SIMPLE mặc
    -- định bỏ kiểm khi có thành phần NULL; CHECK shape riêng vẫn phải đạt.
    -- FOREIGN KEY (workspace_id, target_template_version_id, target_stream_key) REFERENCES
    -- datastream_definitions(workspace_id, template_version_id, stream_key)
    target_template_version_id uuid,

    -- Kênh điều khiển đích trong pinned template version, không chỉ một stream cùng tên ở version bất kỳ.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    -- Ràng buộc hiện hành ck_rule_draft_action_shape: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên
    -- phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((((action_type = 'WAIT'::text) AND (wait_seconds IS NOT NULL) AND ((wait_seconds >= 5) AND (wait_seconds
    -- <= 600)) AND (num_nonnulls(target_device_id, target_template_version_id, target_stream_key, target_value,
    -- notification_config) = 0)) OR ((action_type = 'SET_VALUE'::text) AND (wait_seconds IS NULL) AND
    -- (notification_config IS NULL) AND (num_nonnulls(target_device_id, target_template_version_id, target_stream_key,
    -- target_value) = 4) AND (jsonb_typeof(target_value) = ANY (ARRAY['boolean'::text, 'number'::text,
    -- 'string'::text]))) OR ((action_type = 'NOTIFY'::text) AND (notification_config IS NOT NULL) AND
    -- (jsonb_typeof(notification_config) = 'object'::text) AND (num_nonnulls(wait_seconds, target_device_id,
    -- target_template_version_id, target_stream_key, target_value) = 0))))
    -- Ràng buộc hiện hành rule_draft_actions_workspace_id_target_template_version_id_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành. FK MATCH SIMPLE mặc
    -- định bỏ kiểm khi có thành phần NULL; CHECK shape riêng vẫn phải đạt.
    -- FOREIGN KEY (workspace_id, target_template_version_id, target_stream_key) REFERENCES
    -- datastream_definitions(workspace_id, template_version_id, stream_key)
    target_stream_key text,

    -- Literal JSON của SET_VALUE, phải qua kiểm datatype/range/capability; không được dùng expression hoặc script làm
    -- giá trị.
    -- jsonb: tài liệu JSON lưu dạng nhị phân; kiểm object/scalar không thay validation đầy đủ cấu trúc và tham chiếu
    -- nghiệp vụ.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    -- Ràng buộc hiện hành ck_rule_draft_action_shape: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên
    -- phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((((action_type = 'WAIT'::text) AND (wait_seconds IS NOT NULL) AND ((wait_seconds >= 5) AND (wait_seconds
    -- <= 600)) AND (num_nonnulls(target_device_id, target_template_version_id, target_stream_key, target_value,
    -- notification_config) = 0)) OR ((action_type = 'SET_VALUE'::text) AND (wait_seconds IS NULL) AND
    -- (notification_config IS NULL) AND (num_nonnulls(target_device_id, target_template_version_id, target_stream_key,
    -- target_value) = 4) AND (jsonb_typeof(target_value) = ANY (ARRAY['boolean'::text, 'number'::text,
    -- 'string'::text]))) OR ((action_type = 'NOTIFY'::text) AND (notification_config IS NOT NULL) AND
    -- (jsonb_typeof(notification_config) = 'object'::text) AND (num_nonnulls(wait_seconds, target_device_id,
    -- target_template_version_id, target_stream_key, target_value) = 0))))
    target_value jsonb,

    -- Cấu hình NOTIFY theo schema, chỉ tồn tại ở nhánh NOTIFY; nội dung phải được validation/redact khi tạo Event.
    -- jsonb: tài liệu JSON lưu dạng nhị phân; kiểm object/scalar không thay validation đầy đủ cấu trúc và tham chiếu
    -- nghiệp vụ.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    -- Ràng buộc hiện hành ck_rule_draft_action_shape: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên
    -- phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((((action_type = 'WAIT'::text) AND (wait_seconds IS NOT NULL) AND ((wait_seconds >= 5) AND (wait_seconds
    -- <= 600)) AND (num_nonnulls(target_device_id, target_template_version_id, target_stream_key, target_value,
    -- notification_config) = 0)) OR ((action_type = 'SET_VALUE'::text) AND (wait_seconds IS NULL) AND
    -- (notification_config IS NULL) AND (num_nonnulls(target_device_id, target_template_version_id, target_stream_key,
    -- target_value) = 4) AND (jsonb_typeof(target_value) = ANY (ARRAY['boolean'::text, 'number'::text,
    -- 'string'::text]))) OR ((action_type = 'NOTIFY'::text) AND (notification_config IS NOT NULL) AND
    -- (jsonb_typeof(notification_config) = 'object'::text) AND (num_nonnulls(wait_seconds, target_device_id,
    -- target_template_version_id, target_stream_key, target_value) = 0))))
    notification_config jsonb,

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    PRIMARY KEY(workspace_id,rule_id,action_position),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,rule_id) REFERENCES rule_drafts,

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,target_device_id,target_template_version_id) REFERENCES devices(workspace_id,device_id,template_version_id),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,target_template_version_id,target_stream_key) REFERENCES datastream_definitions,

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    CONSTRAINT ck_rule_draft_action_shape CHECK(
  (action_type='WAIT' AND wait_seconds IS NOT NULL AND wait_seconds BETWEEN 5 AND 600 AND num_nonnulls(target_device_id,target_template_version_id,target_stream_key,target_value,notification_config)=0) OR
  (action_type='SET_VALUE' AND wait_seconds IS NULL AND notification_config IS NULL AND num_nonnulls(target_device_id,target_template_version_id,target_stream_key,target_value)=4 AND jsonb_typeof(target_value) IN ('boolean','number','string')) OR
  (action_type='NOTIFY' AND notification_config IS NOT NULL AND jsonb_typeof(notification_config)='object' AND num_nonnulls(wait_seconds,target_device_id,target_template_version_id,target_stream_key,target_value)=0))
);
-- Bảng rule_draft_references: Các tham chiếu resource trích từ AST/trigger/action của draft, định danh theo đường
-- dẫn trong tài liệu. FK bảo vệ scope/pin; validator còn phải kiểm đủ và khớp hai chiều với AST.
CREATE TABLE rule_draft_references (
    -- Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền
    -- của người gọi.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành rule_draft_references_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, rule_id, reference_path)
    -- Ràng buộc hiện hành rule_draft_references_workspace_id_device_id_template_vers_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, device_id, template_version_id) REFERENCES devices(workspace_id, device_id,
    -- template_version_id)
    -- Ràng buộc hiện hành rule_draft_references_workspace_id_rule_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ hợp có
    -- workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, rule_id) REFERENCES rule_drafts(workspace_id, rule_id)
    -- Ràng buộc hiện hành rule_draft_references_workspace_id_template_version_id_str_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, template_version_id, stream_key) REFERENCES datastream_definitions(workspace_id,
    -- template_version_id, stream_key)
    workspace_id uuid NOT NULL,

    -- Identity gốc rule trong workspace, dùng nhóm draft/version/runtime; không là identity một lần chạy.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành rule_draft_references_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, rule_id, reference_path)
    -- Ràng buộc hiện hành rule_draft_references_workspace_id_rule_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ hợp có
    -- workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, rule_id) REFERENCES rule_drafts(workspace_id, rule_id)
    rule_id uuid NOT NULL,

    -- Đường dẫn ổn định tới một reference trong AST/trigger/action snapshot, dùng kiểm đủ và đúng hai chiều với
    -- document.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành rule_draft_references_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, rule_id, reference_path)
    reference_path text NOT NULL,

    -- Identity thiết bị toàn cục để resolve MQTT và registry; kết hợp workspace_id bảo vệ mọi tham chiếu trong đúng
    -- tenant.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành rule_draft_references_workspace_id_device_id_template_vers_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, device_id, template_version_id) REFERENCES devices(workspace_id, device_id,
    -- template_version_id)
    device_id uuid NOT NULL,

    -- Identity snapshot template cụ thể, dùng pin schema và kiểm đúng definition trong workspace.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành rule_draft_references_workspace_id_device_id_template_vers_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, device_id, template_version_id) REFERENCES devices(workspace_id, device_id,
    -- template_version_id)
    -- Ràng buộc hiện hành rule_draft_references_workspace_id_template_version_id_str_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, template_version_id, stream_key) REFERENCES datastream_definitions(workspace_id,
    -- template_version_id, stream_key)
    template_version_id uuid NOT NULL,

    -- Khóa kỹ thuật ổn định của kênh trong template/version; không dùng nhãn hiển thị thay khóa schema.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    -- Ràng buộc hiện hành rule_draft_references_workspace_id_template_version_id_str_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành. FK MATCH SIMPLE mặc
    -- định bỏ kiểm khi có thành phần NULL; CHECK shape riêng vẫn phải đạt.
    -- FOREIGN KEY (workspace_id, template_version_id, stream_key) REFERENCES datastream_definitions(workspace_id,
    -- template_version_id, stream_key)
    stream_key text,

    -- Reference thuộc TRIGGER/CONDITION/ACTION, giúp validator đối chiếu đúng vai trò tài nguyên tại publish/save.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành rule_draft_references_reference_kind_check: CHECK chỉ chặn khi biểu thức là FALSE;
    -- NULL/UNKNOWN vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((reference_kind = ANY (ARRAY['TRIGGER'::text, 'CONDITION'::text, 'ACTION'::text])))
    reference_kind text NOT NULL CHECK(reference_kind IN ('TRIGGER','CONDITION','ACTION')),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    PRIMARY KEY(workspace_id,rule_id,reference_path),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,rule_id) REFERENCES rule_drafts,

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,device_id,template_version_id) REFERENCES devices(workspace_id,device_id,template_version_id),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,template_version_id,stream_key) REFERENCES datastream_definitions
);
-- Bảng rule_versions: Ảnh chụp rule tại một lần publish, gồm điều kiện, trigger và policy. Execution tham chiếu
-- phiên bản này để restart hoặc chỉnh draft không đổi định nghĩa lịch sử.
CREATE TABLE rule_versions (
    -- Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền
    -- của người gọi.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành rule_versions_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì uniqueness áp
    -- dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, rule_version_id)
    -- Ràng buộc hiện hành rule_versions_workspace_id_rule_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ hợp có
    -- workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, rule_id) REFERENCES rules(workspace_id, rule_id)
    -- Ràng buộc hiện hành rule_versions_workspace_id_rule_id_rule_version_id_key: không trùng tổ hợp giá trị được nêu;
    -- các cột riêng lẻ vẫn có thể lặp khi khóa có nhiều cột.
    -- UNIQUE (workspace_id, rule_id, rule_version_id)
    -- Ràng buộc hiện hành rule_versions_workspace_id_rule_id_version_number_key: không trùng tổ hợp giá trị được nêu;
    -- các cột riêng lẻ vẫn có thể lặp khi khóa có nhiều cột.
    -- UNIQUE (workspace_id, rule_id, version_number)
    workspace_id uuid NOT NULL,

    -- Identity rule snapshot đã publish, dùng pin trigger/action/execution thay vì đọc draft hiện hành.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành rule_versions_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì uniqueness áp
    -- dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, rule_version_id)
    -- Ràng buộc hiện hành rule_versions_workspace_id_rule_id_rule_version_id_key: không trùng tổ hợp giá trị được nêu;
    -- các cột riêng lẻ vẫn có thể lặp khi khóa có nhiều cột.
    -- UNIQUE (workspace_id, rule_id, rule_version_id)
    rule_version_id uuid NOT NULL,

    -- Identity gốc rule trong workspace, dùng nhóm draft/version/runtime; không là identity một lần chạy.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành rule_versions_workspace_id_rule_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ hợp có
    -- workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, rule_id) REFERENCES rules(workspace_id, rule_id)
    -- Ràng buộc hiện hành rule_versions_workspace_id_rule_id_rule_version_id_key: không trùng tổ hợp giá trị được nêu;
    -- các cột riêng lẻ vẫn có thể lặp khi khóa có nhiều cột.
    -- UNIQUE (workspace_id, rule_id, rule_version_id)
    -- Ràng buộc hiện hành rule_versions_workspace_id_rule_id_version_number_key: không trùng tổ hợp giá trị được nêu;
    -- các cột riêng lẻ vẫn có thể lặp khi khóa có nhiều cột.
    -- UNIQUE (workspace_id, rule_id, version_number)
    rule_id uuid NOT NULL,

    -- Số phiên bản publish tăng trong cùng template/rule, bắt đầu 1; khác revision chỉnh sửa metadata.
    -- integer: số nguyên có dấu 32 bit; CHECK giới hạn miền nghiệp vụ thay vì chỉ dựa phạm vi kiểu.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành rule_versions_version_number_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn
    -- qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((version_number > 0))
    -- Ràng buộc hiện hành rule_versions_workspace_id_rule_id_version_number_key: không trùng tổ hợp giá trị được nêu;
    -- các cột riêng lẻ vẫn có thể lặp khi khóa có nhiều cột.
    -- UNIQUE (workspace_id, rule_id, version_number)
    version_number integer NOT NULL CHECK(version_number>0),

    -- Nguồn kích hoạt THRESHOLD/SCHEDULE/CONNECTIVITY/MANUAL của rule, quyết định shape trigger_config cần validate.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành rule_versions_trigger_type_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn
    -- qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((trigger_type = ANY (ARRAY['THRESHOLD'::text, 'SCHEDULE'::text, 'CONNECTIVITY'::text, 'MANUAL'::text])))
    trigger_type text NOT NULL CHECK(trigger_type IN ('THRESHOLD','SCHEDULE','CONNECTIVITY','MANUAL')),

    -- Cấu hình trigger theo schema version; JSON object CHECK chỉ kiểm dạng ngoài, không thay validator typed và quyền
    -- resource.
    -- jsonb: tài liệu JSON lưu dạng nhị phân; kiểm object/scalar không thay validation đầy đủ cấu trúc và tham chiếu
    -- nghiệp vụ.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành rule_versions_trigger_config_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn
    -- qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((jsonb_typeof(trigger_config) = 'object'::text))
    trigger_config jsonb NOT NULL CHECK(jsonb_typeof(trigger_config)='object'),

    -- Cây điều kiện AND/OR/literal theo rule contract; backend phải kiểm depth/type/leaves và bijection với reference
    -- rows.
    -- jsonb: tài liệu JSON lưu dạng nhị phân; kiểm object/scalar không thay validation đầy đủ cấu trúc và tham chiếu
    -- nghiệp vụ.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành rule_versions_condition_ast_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn
    -- qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((jsonb_typeof(condition_ast) = 'object'::text))
    condition_ast jsonb NOT NULL CHECK(jsonb_typeof(condition_ast)='object'),

    -- Phiên bản cấu trúc document dashboard/rule, hiện 1; khác revision chỉnh sửa và version publish.
    -- integer: số nguyên có dấu 32 bit; CHECK giới hạn miền nghiệp vụ thay vì chỉ dựa phạm vi kiểu.
    -- NOT NULL: bắt buộc có giá trị.
    -- DEFAULT 1: giá trị dùng khi INSERT bỏ qua cột; không thay NULL được truyền tường minh và không tự áp lại khi
    -- UPDATE.
    -- Ràng buộc hiện hành rule_versions_schema_version_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn
    -- qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((schema_version = 1))
    schema_version integer NOT NULL DEFAULT 1 CHECK(schema_version=1),

    -- Thời gian nghỉ tối thiểu giữa các lần admission rule, đơn vị giây, từ 10 đến 3600 theo policy rule.
    -- integer: số nguyên có dấu 32 bit; CHECK giới hạn miền nghiệp vụ thay vì chỉ dựa phạm vi kiểu.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành rule_versions_cooldown_seconds_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN
    -- vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK (((cooldown_seconds >= 10) AND (cooldown_seconds <= 3600)))
    cooldown_seconds integer NOT NULL CHECK(cooldown_seconds BETWEEN 10 AND 3600),

    -- Mức ưu tiên HIGH/NORMAL/LOW của rule, không tự cho quyền vượt manual epoch hoặc guard actuator.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành rule_versions_priority_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua,
    -- nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((priority = ANY (ARRAY['HIGH'::text, 'NORMAL'::text, 'LOW'::text])))
    priority text NOT NULL CHECK(priority IN ('HIGH','NORMAL','LOW')),

    -- Policy STOP/CONTINUE cho lỗi đã biết của chuỗi; UNKNOWN vẫn cần dừng/đối soát theo contract, không tự chạy bước
    -- sau.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành rule_versions_on_failure_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua,
    -- nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((on_failure = ANY (ARRAY['STOP'::text, 'CONTINUE'::text])))
    on_failure text NOT NULL CHECK(on_failure IN ('STOP','CONTINUE')),

    -- Thời điểm tạo snapshot đã công bố; không thay đổi theo các lần sửa draft sau đó.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- NOT NULL: bắt buộc có giá trị.
    -- DEFAULT transaction_timestamp(): thời điểm bắt đầu transaction, giữ nguyên trong transaction; không phải đồng hồ
    -- thay đổi theo từng statement.
    published_at timestamptz NOT NULL DEFAULT transaction_timestamp(),

    -- SHA-256 32 byte của nội dung snapshot đã publish, dùng nhận diện/đối chiếu định nghĩa thay vì hash metadata
    -- draft hiện tại.
    -- bytea: dãy byte nhị phân; tên digest/ciphertext mô tả mục đích, bản thân kiểu không băm hoặc mã hóa dữ liệu.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành rule_versions_content_digest_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn
    -- qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((octet_length(content_digest) = 32))
    content_digest bytea NOT NULL CHECK(octet_length(content_digest)=32),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    PRIMARY KEY(workspace_id,rule_version_id),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    UNIQUE(workspace_id,rule_id,version_number),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    UNIQUE(workspace_id,rule_id,rule_version_id),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,rule_id) REFERENCES rules
);
ALTER TABLE rules ADD CONSTRAINT fk_rules_active_version FOREIGN KEY(workspace_id,rule_id,active_rule_version_id) REFERENCES rule_versions(workspace_id,rule_id,rule_version_id) DEFERRABLE INITIALLY DEFERRED;
-- Bảng rule_version_actions: Chuỗi action thuộc rule version đã công bố. Dùng cùng action_position trong execution
-- để xác định chính xác hành động nào được chạy.
CREATE TABLE rule_version_actions (
    -- Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền
    -- của người gọi.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành rule_version_actions_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, rule_version_id, action_position)
    -- Ràng buộc hiện hành rule_version_actions_workspace_id_rule_version_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ
    -- hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, rule_version_id) REFERENCES rule_versions(workspace_id, rule_version_id)
    -- Ràng buộc hiện hành rule_version_actions_workspace_id_target_device_id_target__fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, target_device_id, target_template_version_id) REFERENCES devices(workspace_id,
    -- device_id, template_version_id)
    -- Ràng buộc hiện hành rule_version_actions_workspace_id_target_template_version__fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, target_template_version_id, target_stream_key) REFERENCES
    -- datastream_definitions(workspace_id, template_version_id, stream_key)
    workspace_id uuid NOT NULL,

    -- Identity rule snapshot đã publish, dùng pin trigger/action/execution thay vì đọc draft hiện hành.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành rule_version_actions_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, rule_version_id, action_position)
    -- Ràng buộc hiện hành rule_version_actions_workspace_id_rule_version_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ
    -- hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, rule_version_id) REFERENCES rule_versions(workspace_id, rule_version_id)
    rule_version_id uuid NOT NULL,

    -- Chỉ số action bắt đầu 0 trong chuỗi tối đa 5 bước, dùng ghép definition/action execution/job.
    -- integer: số nguyên có dấu 32 bit; CHECK giới hạn miền nghiệp vụ thay vì chỉ dựa phạm vi kiểu.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành rule_version_actions_action_position_check: CHECK chỉ chặn khi biểu thức là FALSE;
    -- NULL/UNKNOWN vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK (((action_position >= 0) AND (action_position <= 4)))
    -- Ràng buộc hiện hành rule_version_actions_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, rule_version_id, action_position)
    action_position integer NOT NULL CHECK(action_position BETWEEN 0 AND 4),

    -- Loại hành động SET_VALUE/WAIT/NOTIFY; mỗi nhánh yêu cầu bộ trường typed riêng, không chứa code/script tùy ý.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành ck_rule_version_action_shape: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua,
    -- nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((((action_type = 'WAIT'::text) AND (wait_seconds IS NOT NULL) AND ((wait_seconds >= 5) AND (wait_seconds
    -- <= 600)) AND (num_nonnulls(target_device_id, target_template_version_id, target_stream_key, target_value,
    -- notification_config) = 0)) OR ((action_type = 'SET_VALUE'::text) AND (wait_seconds IS NULL) AND
    -- (notification_config IS NULL) AND (num_nonnulls(target_device_id, target_template_version_id, target_stream_key,
    -- target_value) = 4) AND (jsonb_typeof(target_value) = ANY (ARRAY['boolean'::text, 'number'::text,
    -- 'string'::text]))) OR ((action_type = 'NOTIFY'::text) AND (notification_config IS NOT NULL) AND
    -- (jsonb_typeof(notification_config) = 'object'::text) AND (num_nonnulls(wait_seconds, target_device_id,
    -- target_template_version_id, target_stream_key, target_value) = 0))))
    -- Ràng buộc hiện hành rule_version_actions_action_type_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN
    -- vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((action_type = ANY (ARRAY['SET_VALUE'::text, 'WAIT'::text, 'NOTIFY'::text])))
    action_type text NOT NULL CHECK(action_type IN ('SET_VALUE','WAIT','NOTIFY')),

    -- Thời lượng WAIT theo giây, từ 5 đến 600 cho một bước; tổng WAIT của version còn bị giới hạn 600 giây.
    -- integer: số nguyên có dấu 32 bit; CHECK giới hạn miền nghiệp vụ thay vì chỉ dựa phạm vi kiểu.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    -- Ràng buộc hiện hành ck_rule_version_action_shape: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua,
    -- nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((((action_type = 'WAIT'::text) AND (wait_seconds IS NOT NULL) AND ((wait_seconds >= 5) AND (wait_seconds
    -- <= 600)) AND (num_nonnulls(target_device_id, target_template_version_id, target_stream_key, target_value,
    -- notification_config) = 0)) OR ((action_type = 'SET_VALUE'::text) AND (wait_seconds IS NULL) AND
    -- (notification_config IS NULL) AND (num_nonnulls(target_device_id, target_template_version_id, target_stream_key,
    -- target_value) = 4) AND (jsonb_typeof(target_value) = ANY (ARRAY['boolean'::text, 'number'::text,
    -- 'string'::text]))) OR ((action_type = 'NOTIFY'::text) AND (notification_config IS NOT NULL) AND
    -- (jsonb_typeof(notification_config) = 'object'::text) AND (num_nonnulls(wait_seconds, target_device_id,
    -- target_template_version_id, target_stream_key, target_value) = 0))))
    wait_seconds integer,

    -- Thiết bị đích của action hoặc deep link; NULL khi nhánh không có device, nếu có phải cùng workspace và đúng pin.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    -- Ràng buộc hiện hành ck_rule_version_action_shape: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua,
    -- nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((((action_type = 'WAIT'::text) AND (wait_seconds IS NOT NULL) AND ((wait_seconds >= 5) AND (wait_seconds
    -- <= 600)) AND (num_nonnulls(target_device_id, target_template_version_id, target_stream_key, target_value,
    -- notification_config) = 0)) OR ((action_type = 'SET_VALUE'::text) AND (wait_seconds IS NULL) AND
    -- (notification_config IS NULL) AND (num_nonnulls(target_device_id, target_template_version_id, target_stream_key,
    -- target_value) = 4) AND (jsonb_typeof(target_value) = ANY (ARRAY['boolean'::text, 'number'::text,
    -- 'string'::text]))) OR ((action_type = 'NOTIFY'::text) AND (notification_config IS NOT NULL) AND
    -- (jsonb_typeof(notification_config) = 'object'::text) AND (num_nonnulls(wait_seconds, target_device_id,
    -- target_template_version_id, target_stream_key, target_value) = 0))))
    -- Ràng buộc hiện hành rule_version_actions_workspace_id_target_device_id_target__fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành. FK MATCH SIMPLE mặc
    -- định bỏ kiểm khi có thành phần NULL; CHECK shape riêng vẫn phải đạt.
    -- FOREIGN KEY (workspace_id, target_device_id, target_template_version_id) REFERENCES devices(workspace_id,
    -- device_id, template_version_id)
    target_device_id uuid,

    -- Template version của target device, lặp để FK bảo vệ target stream đúng pin.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    -- Ràng buộc hiện hành ck_rule_version_action_shape: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua,
    -- nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((((action_type = 'WAIT'::text) AND (wait_seconds IS NOT NULL) AND ((wait_seconds >= 5) AND (wait_seconds
    -- <= 600)) AND (num_nonnulls(target_device_id, target_template_version_id, target_stream_key, target_value,
    -- notification_config) = 0)) OR ((action_type = 'SET_VALUE'::text) AND (wait_seconds IS NULL) AND
    -- (notification_config IS NULL) AND (num_nonnulls(target_device_id, target_template_version_id, target_stream_key,
    -- target_value) = 4) AND (jsonb_typeof(target_value) = ANY (ARRAY['boolean'::text, 'number'::text,
    -- 'string'::text]))) OR ((action_type = 'NOTIFY'::text) AND (notification_config IS NOT NULL) AND
    -- (jsonb_typeof(notification_config) = 'object'::text) AND (num_nonnulls(wait_seconds, target_device_id,
    -- target_template_version_id, target_stream_key, target_value) = 0))))
    -- Ràng buộc hiện hành rule_version_actions_workspace_id_target_device_id_target__fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành. FK MATCH SIMPLE mặc
    -- định bỏ kiểm khi có thành phần NULL; CHECK shape riêng vẫn phải đạt.
    -- FOREIGN KEY (workspace_id, target_device_id, target_template_version_id) REFERENCES devices(workspace_id,
    -- device_id, template_version_id)
    -- Ràng buộc hiện hành rule_version_actions_workspace_id_target_template_version__fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành. FK MATCH SIMPLE mặc
    -- định bỏ kiểm khi có thành phần NULL; CHECK shape riêng vẫn phải đạt.
    -- FOREIGN KEY (workspace_id, target_template_version_id, target_stream_key) REFERENCES
    -- datastream_definitions(workspace_id, template_version_id, stream_key)
    target_template_version_id uuid,

    -- Kênh điều khiển đích trong pinned template version, không chỉ một stream cùng tên ở version bất kỳ.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    -- Ràng buộc hiện hành ck_rule_version_action_shape: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua,
    -- nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((((action_type = 'WAIT'::text) AND (wait_seconds IS NOT NULL) AND ((wait_seconds >= 5) AND (wait_seconds
    -- <= 600)) AND (num_nonnulls(target_device_id, target_template_version_id, target_stream_key, target_value,
    -- notification_config) = 0)) OR ((action_type = 'SET_VALUE'::text) AND (wait_seconds IS NULL) AND
    -- (notification_config IS NULL) AND (num_nonnulls(target_device_id, target_template_version_id, target_stream_key,
    -- target_value) = 4) AND (jsonb_typeof(target_value) = ANY (ARRAY['boolean'::text, 'number'::text,
    -- 'string'::text]))) OR ((action_type = 'NOTIFY'::text) AND (notification_config IS NOT NULL) AND
    -- (jsonb_typeof(notification_config) = 'object'::text) AND (num_nonnulls(wait_seconds, target_device_id,
    -- target_template_version_id, target_stream_key, target_value) = 0))))
    -- Ràng buộc hiện hành rule_version_actions_workspace_id_target_template_version__fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành. FK MATCH SIMPLE mặc
    -- định bỏ kiểm khi có thành phần NULL; CHECK shape riêng vẫn phải đạt.
    -- FOREIGN KEY (workspace_id, target_template_version_id, target_stream_key) REFERENCES
    -- datastream_definitions(workspace_id, template_version_id, stream_key)
    target_stream_key text,

    -- Literal JSON của SET_VALUE, phải qua kiểm datatype/range/capability; không được dùng expression hoặc script làm
    -- giá trị.
    -- jsonb: tài liệu JSON lưu dạng nhị phân; kiểm object/scalar không thay validation đầy đủ cấu trúc và tham chiếu
    -- nghiệp vụ.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    -- Ràng buộc hiện hành ck_rule_version_action_shape: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua,
    -- nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((((action_type = 'WAIT'::text) AND (wait_seconds IS NOT NULL) AND ((wait_seconds >= 5) AND (wait_seconds
    -- <= 600)) AND (num_nonnulls(target_device_id, target_template_version_id, target_stream_key, target_value,
    -- notification_config) = 0)) OR ((action_type = 'SET_VALUE'::text) AND (wait_seconds IS NULL) AND
    -- (notification_config IS NULL) AND (num_nonnulls(target_device_id, target_template_version_id, target_stream_key,
    -- target_value) = 4) AND (jsonb_typeof(target_value) = ANY (ARRAY['boolean'::text, 'number'::text,
    -- 'string'::text]))) OR ((action_type = 'NOTIFY'::text) AND (notification_config IS NOT NULL) AND
    -- (jsonb_typeof(notification_config) = 'object'::text) AND (num_nonnulls(wait_seconds, target_device_id,
    -- target_template_version_id, target_stream_key, target_value) = 0))))
    target_value jsonb,

    -- Cấu hình NOTIFY theo schema, chỉ tồn tại ở nhánh NOTIFY; nội dung phải được validation/redact khi tạo Event.
    -- jsonb: tài liệu JSON lưu dạng nhị phân; kiểm object/scalar không thay validation đầy đủ cấu trúc và tham chiếu
    -- nghiệp vụ.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    -- Ràng buộc hiện hành ck_rule_version_action_shape: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua,
    -- nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((((action_type = 'WAIT'::text) AND (wait_seconds IS NOT NULL) AND ((wait_seconds >= 5) AND (wait_seconds
    -- <= 600)) AND (num_nonnulls(target_device_id, target_template_version_id, target_stream_key, target_value,
    -- notification_config) = 0)) OR ((action_type = 'SET_VALUE'::text) AND (wait_seconds IS NULL) AND
    -- (notification_config IS NULL) AND (num_nonnulls(target_device_id, target_template_version_id, target_stream_key,
    -- target_value) = 4) AND (jsonb_typeof(target_value) = ANY (ARRAY['boolean'::text, 'number'::text,
    -- 'string'::text]))) OR ((action_type = 'NOTIFY'::text) AND (notification_config IS NOT NULL) AND
    -- (jsonb_typeof(notification_config) = 'object'::text) AND (num_nonnulls(wait_seconds, target_device_id,
    -- target_template_version_id, target_stream_key, target_value) = 0))))
    notification_config jsonb,

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    PRIMARY KEY(workspace_id,rule_version_id,action_position),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,rule_version_id) REFERENCES rule_versions,

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,target_device_id,target_template_version_id) REFERENCES devices(workspace_id,device_id,template_version_id),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,target_template_version_id,target_stream_key) REFERENCES datastream_definitions,

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    CONSTRAINT ck_rule_version_action_shape CHECK(
  (action_type='WAIT' AND wait_seconds IS NOT NULL AND wait_seconds BETWEEN 5 AND 600 AND num_nonnulls(target_device_id,target_template_version_id,target_stream_key,target_value,notification_config)=0) OR
  (action_type='SET_VALUE' AND wait_seconds IS NULL AND notification_config IS NULL AND num_nonnulls(target_device_id,target_template_version_id,target_stream_key,target_value)=4 AND jsonb_typeof(target_value) IN ('boolean','number','string')) OR
  (action_type='NOTIFY' AND notification_config IS NOT NULL AND jsonb_typeof(notification_config)='object' AND num_nonnulls(wait_seconds,target_device_id,target_template_version_id,target_stream_key,target_value)=0))
);
/* Tối đa một NOTIFY; tổng WAIT và contiguity kiểm tại publish boundary. */
CREATE UNIQUE INDEX uq_rule_version_notify ON rule_version_actions(workspace_id,rule_version_id) WHERE action_type='NOTIFY';
CREATE UNIQUE INDEX uq_rule_draft_notify ON rule_draft_actions(workspace_id,rule_id) WHERE action_type='NOTIFY';
-- Bảng rule_version_references: Các tham chiếu thiết bị/kênh theo đường dẫn trong rule version đã công bố. Giữ
-- quan hệ typed và pinned, không thay thế kiểm tra AST/reference completeness của validator.
CREATE TABLE rule_version_references (
    -- Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền
    -- của người gọi.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành rule_version_references_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, rule_version_id, reference_path)
    -- Ràng buộc hiện hành rule_version_references_workspace_id_device_id_template_ve_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, device_id, template_version_id) REFERENCES devices(workspace_id, device_id,
    -- template_version_id)
    -- Ràng buộc hiện hành rule_version_references_workspace_id_rule_version_id_fkey: khóa ngoại giữ đúng bản ghi cha;
    -- tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, rule_version_id) REFERENCES rule_versions(workspace_id, rule_version_id)
    -- Ràng buộc hiện hành rule_version_references_workspace_id_template_version_id_s_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, template_version_id, stream_key) REFERENCES datastream_definitions(workspace_id,
    -- template_version_id, stream_key)
    workspace_id uuid NOT NULL,

    -- Identity rule snapshot đã publish, dùng pin trigger/action/execution thay vì đọc draft hiện hành.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành rule_version_references_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, rule_version_id, reference_path)
    -- Ràng buộc hiện hành rule_version_references_workspace_id_rule_version_id_fkey: khóa ngoại giữ đúng bản ghi cha;
    -- tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, rule_version_id) REFERENCES rule_versions(workspace_id, rule_version_id)
    rule_version_id uuid NOT NULL,

    -- Đường dẫn ổn định tới một reference trong AST/trigger/action snapshot, dùng kiểm đủ và đúng hai chiều với
    -- document.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành rule_version_references_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, rule_version_id, reference_path)
    reference_path text NOT NULL,

    -- Identity thiết bị toàn cục để resolve MQTT và registry; kết hợp workspace_id bảo vệ mọi tham chiếu trong đúng
    -- tenant.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành rule_version_references_workspace_id_device_id_template_ve_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, device_id, template_version_id) REFERENCES devices(workspace_id, device_id,
    -- template_version_id)
    device_id uuid NOT NULL,

    -- Identity snapshot template cụ thể, dùng pin schema và kiểm đúng definition trong workspace.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành rule_version_references_workspace_id_device_id_template_ve_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, device_id, template_version_id) REFERENCES devices(workspace_id, device_id,
    -- template_version_id)
    -- Ràng buộc hiện hành rule_version_references_workspace_id_template_version_id_s_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, template_version_id, stream_key) REFERENCES datastream_definitions(workspace_id,
    -- template_version_id, stream_key)
    template_version_id uuid NOT NULL,

    -- Khóa kỹ thuật ổn định của kênh trong template/version; không dùng nhãn hiển thị thay khóa schema.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    -- Ràng buộc hiện hành rule_version_references_workspace_id_template_version_id_s_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành. FK MATCH SIMPLE mặc
    -- định bỏ kiểm khi có thành phần NULL; CHECK shape riêng vẫn phải đạt.
    -- FOREIGN KEY (workspace_id, template_version_id, stream_key) REFERENCES datastream_definitions(workspace_id,
    -- template_version_id, stream_key)
    stream_key text,

    -- Reference thuộc TRIGGER/CONDITION/ACTION, giúp validator đối chiếu đúng vai trò tài nguyên tại publish/save.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành rule_version_references_reference_kind_check: CHECK chỉ chặn khi biểu thức là FALSE;
    -- NULL/UNKNOWN vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((reference_kind = ANY (ARRAY['TRIGGER'::text, 'CONDITION'::text, 'ACTION'::text])))
    reference_kind text NOT NULL CHECK(reference_kind IN ('TRIGGER','CONDITION','ACTION')),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    PRIMARY KEY(workspace_id,rule_version_id,reference_path),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,rule_version_id) REFERENCES rule_versions,

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,device_id,template_version_id) REFERENCES devices(workspace_id,device_id,template_version_id),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,template_version_id,stream_key) REFERENCES datastream_definitions
);
-- Bảng rule_runtime: Trạng thái điều phối rule đang chạy như active generation và cooldown. Lưu bền vững để
-- restart không xóa khoảng nghỉ hoặc dùng lại thế hệ runtime cũ.
CREATE TABLE rule_runtime (
    -- Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền
    -- của người gọi.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành rule_runtime_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì uniqueness áp
    -- dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, rule_id)
    -- Ràng buộc hiện hành rule_runtime_workspace_id_rule_id_current_rule_version_id_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, rule_id, current_rule_version_id) REFERENCES rule_versions(workspace_id, rule_id,
    -- rule_version_id)
    -- Ràng buộc hiện hành rule_runtime_workspace_id_rule_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ hợp có
    -- workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, rule_id) REFERENCES rules(workspace_id, rule_id)
    workspace_id uuid NOT NULL,

    -- Identity gốc rule trong workspace, dùng nhóm draft/version/runtime; không là identity một lần chạy.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành rule_runtime_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì uniqueness áp
    -- dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, rule_id)
    -- Ràng buộc hiện hành rule_runtime_workspace_id_rule_id_current_rule_version_id_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, rule_id, current_rule_version_id) REFERENCES rule_versions(workspace_id, rule_id,
    -- rule_version_id)
    -- Ràng buộc hiện hành rule_runtime_workspace_id_rule_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ hợp có
    -- workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, rule_id) REFERENCES rules(workspace_id, rule_id)
    rule_id uuid NOT NULL,

    -- Thế hệ kích hoạt runtime rule, dùng phân biệt công việc cũ sau enable/disable/publish lại.
    -- bigint: số nguyên có dấu 64 bit, phù hợp bộ đếm/generation tăng lâu dài; không tự tăng nếu chưa có cơ chế cấp
    -- giá trị.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành rule_runtime_active_generation_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN
    -- vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((active_generation > 0))
    active_generation bigint NOT NULL CHECK(active_generation>0),

    -- Mốc UTC kết thúc cooldown đang có hiệu lực; restart không được reset mốc để lách giới hạn.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    cooldown_until timestamptz,

    -- Nguyên nhân rule bị tắt do lỗi/rate policy, đã chuẩn hóa để hiển thị và yêu cầu thao tác phục hồi phù hợp.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    error_disabled_reason text,

    -- Rule version runtime hiện hành của đúng rule, dùng phối hợp active generation/cooldown với coordinator.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    -- Ràng buộc hiện hành rule_runtime_workspace_id_rule_id_current_rule_version_id_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành. FK MATCH SIMPLE mặc
    -- định bỏ kiểm khi có thành phần NULL; CHECK shape riêng vẫn phải đạt.
    -- FOREIGN KEY (workspace_id, rule_id, current_rule_version_id) REFERENCES rule_versions(workspace_id, rule_id,
    -- rule_version_id)
    current_rule_version_id uuid,

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    PRIMARY KEY(workspace_id,rule_id),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,rule_id) REFERENCES rules,

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,rule_id,current_rule_version_id) REFERENCES rule_versions(workspace_id,rule_id,rule_version_id)
);
-- Bảng rule_trigger_states: Trạng thái episode/hold của trigger trong một rule version. Giữ mốc fresh, armed và
-- sequence để tránh fire lặp hoặc cộng hold từ dữ liệu stale.
CREATE TABLE rule_trigger_states (
    -- Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền
    -- của người gọi.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành rule_trigger_states_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, rule_version_id, trigger_key)
    -- Ràng buộc hiện hành rule_trigger_states_workspace_id_rule_version_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ
    -- hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, rule_version_id) REFERENCES rule_versions(workspace_id, rule_version_id)
    workspace_id uuid NOT NULL,

    -- Identity rule snapshot đã publish, dùng pin trigger/action/execution thay vì đọc draft hiện hành.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành rule_trigger_states_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, rule_version_id, trigger_key)
    -- Ràng buộc hiện hành rule_trigger_states_workspace_id_rule_version_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ
    -- hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, rule_version_id) REFERENCES rule_versions(workspace_id, rule_version_id)
    rule_version_id uuid NOT NULL,

    -- Identity ổn định của trigger/episode/occurrence theo version; dùng dedupe, không sinh key mới chỉ vì worker
    -- restart.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành rule_trigger_states_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, rule_version_id, trigger_key)
    trigger_key text NOT NULL,

    -- True khi trigger episode sẵn sàng nhận một lần fire theo policy hysteresis/hold; không thay kiểm freshness
    -- input.
    -- boolean: cờ logic true/false; NULL là trạng thái riêng nếu cột cho phép.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    is_armed boolean NOT NULL,

    -- Mốc bắt đầu hold liên tục đủ điều kiện; stale/restart phải xử lý theo policy, không cộng thời gian mất dữ liệu
    -- như hold hợp lệ.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    hold_started_at timestamptz,

    -- Thời điểm input/trigger gần nhất còn đủ fresh, dùng reset hold hoặc xác định episode không còn tin cậy.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    last_fresh_at timestamptz,

    -- Sequence episode tăng để identity lần fire không bị tái sử dụng khi condition bật/tắt hoặc worker phục hồi.
    -- bigint: số nguyên có dấu 64 bit, phù hợp bộ đếm/generation tăng lâu dài; không tự tăng nếu chưa có cơ chế cấp
    -- giá trị.
    -- NOT NULL: bắt buộc có giá trị.
    -- DEFAULT 0: giá trị dùng khi INSERT bỏ qua cột; không thay NULL được truyền tường minh và không tự áp lại khi
    -- UPDATE.
    -- Ràng buộc hiện hành rule_trigger_states_episode_sequence_check: CHECK chỉ chặn khi biểu thức là FALSE;
    -- NULL/UNKNOWN vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((episode_sequence >= 0))
    episode_sequence bigint NOT NULL DEFAULT 0 CHECK(episode_sequence>=0),

    -- Marker dữ liệu cuối đã xử lý cho trigger state, tránh mẫu lặp làm tăng hold hoặc fire lại.
    -- bigint: số nguyên có dấu 64 bit, phù hợp bộ đếm/generation tăng lâu dài; không tự tăng nếu chưa có cơ chế cấp
    -- giá trị.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    -- Ràng buộc hiện hành rule_trigger_states_last_marker_sequence_check: CHECK chỉ chặn khi biểu thức là FALSE;
    -- NULL/UNKNOWN vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((last_marker_sequence > 0))
    last_marker_sequence bigint CHECK(last_marker_sequence>0),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    PRIMARY KEY(workspace_id,rule_version_id,trigger_key),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,rule_version_id) REFERENCES rule_versions
);
-- Bảng rule_executions: Mỗi lần quyết định/chạy một rule version với trigger identity ổn định và deadline 15 phút.
-- Là ledger runtime cho quota, tiến độ và outcome, tách khỏi payload lịch sử lớn.
CREATE TABLE rule_executions (
    -- Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền
    -- của người gọi.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành rule_executions_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì uniqueness áp
    -- dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, rule_execution_id)
    -- Ràng buộc hiện hành rule_executions_workspace_id_owner_user_id_snapshot_fkey: khóa ngoại giữ đúng bản ghi cha;
    -- tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, owner_user_id_snapshot) REFERENCES memberships(workspace_id, user_id)
    -- Ràng buộc hiện hành rule_executions_workspace_id_rule_execution_id_rule_version_key: không trùng tổ hợp giá trị
    -- được nêu; các cột riêng lẻ vẫn có thể lặp khi khóa có nhiều cột.
    -- UNIQUE (workspace_id, rule_execution_id, rule_version_id)
    -- Ràng buộc hiện hành rule_executions_workspace_id_rule_id_rule_version_id_fkey: khóa ngoại giữ đúng bản ghi cha;
    -- tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, rule_id, rule_version_id) REFERENCES rule_versions(workspace_id, rule_id,
    -- rule_version_id)
    -- Ràng buộc hiện hành rule_executions_workspace_id_rule_version_id_trigger_key_key: không trùng tổ hợp giá trị
    -- được nêu; các cột riêng lẻ vẫn có thể lặp khi khóa có nhiều cột.
    -- UNIQUE (workspace_id, rule_version_id, trigger_key)
    workspace_id uuid NOT NULL,

    -- Identity một lần quyết định/chạy rule version, dùng quota, history, action chain và notification target.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành rule_executions_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì uniqueness áp
    -- dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, rule_execution_id)
    -- Ràng buộc hiện hành rule_executions_workspace_id_rule_execution_id_rule_version_key: không trùng tổ hợp giá trị
    -- được nêu; các cột riêng lẻ vẫn có thể lặp khi khóa có nhiều cột.
    -- UNIQUE (workspace_id, rule_execution_id, rule_version_id)
    rule_execution_id uuid NOT NULL,

    -- Identity gốc rule trong workspace, dùng nhóm draft/version/runtime; không là identity một lần chạy.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành rule_executions_workspace_id_rule_id_rule_version_id_fkey: khóa ngoại giữ đúng bản ghi cha;
    -- tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, rule_id, rule_version_id) REFERENCES rule_versions(workspace_id, rule_id,
    -- rule_version_id)
    rule_id uuid NOT NULL,

    -- Identity rule snapshot đã publish, dùng pin trigger/action/execution thay vì đọc draft hiện hành.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành rule_executions_workspace_id_rule_execution_id_rule_version_key: không trùng tổ hợp giá trị
    -- được nêu; các cột riêng lẻ vẫn có thể lặp khi khóa có nhiều cột.
    -- UNIQUE (workspace_id, rule_execution_id, rule_version_id)
    -- Ràng buộc hiện hành rule_executions_workspace_id_rule_id_rule_version_id_fkey: khóa ngoại giữ đúng bản ghi cha;
    -- tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, rule_id, rule_version_id) REFERENCES rule_versions(workspace_id, rule_id,
    -- rule_version_id)
    -- Ràng buộc hiện hành rule_executions_workspace_id_rule_version_id_trigger_key_key: không trùng tổ hợp giá trị
    -- được nêu; các cột riêng lẻ vẫn có thể lặp khi khóa có nhiều cột.
    -- UNIQUE (workspace_id, rule_version_id, trigger_key)
    rule_version_id uuid NOT NULL,

    -- Identity ổn định của trigger/episode/occurrence theo version; dùng dedupe, không sinh key mới chỉ vì worker
    -- restart.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành rule_executions_workspace_id_rule_version_id_trigger_key_key: không trùng tổ hợp giá trị
    -- được nêu; các cột riêng lẻ vẫn có thể lặp khi khóa có nhiều cột.
    -- UNIQUE (workspace_id, rule_version_id, trigger_key)
    trigger_key text NOT NULL,

    -- Trạng thái RUNNING/WAITING hoặc kết quả SUCCEEDED/PARTIAL/FAILED/CANCELLED/NEEDS_ATTENTION/NO_MATCH;
    -- RUNNING/WAITING chiếm quota.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành rule_executions_state_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua,
    -- nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((state = ANY (ARRAY['RUNNING'::text, 'WAITING'::text, 'SUCCEEDED'::text, 'PARTIAL'::text, 'FAILED'::text,
    -- 'CANCELLED'::text, 'NEEDS_ATTENTION'::text, 'NO_MATCH'::text])))
    state text NOT NULL CHECK(state IN ('RUNNING','WAITING','SUCCEEDED','PARTIAL','FAILED','CANCELLED','NEEDS_ATTENTION','NO_MATCH')),

    -- Thời điểm yêu cầu được backend nhận vào ledger sau kiểm điều kiện; không chứng minh side effect đã thực hiện.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành rule_executions_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên phải
    -- phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((deadline_at = (admitted_at + '00:15:00'::interval)))
    admitted_at timestamptz NOT NULL,

    -- Deadline admitted_at + 15 phút cho cả execution; WAIT/restart không kéo dài ngân sách toàn chuỗi.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành rule_executions_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên phải
    -- phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((deadline_at = (admitted_at + '00:15:00'::interval)))
    deadline_at timestamptz NOT NULL,

    -- Thời điểm execution/action kết thúc; NULL khi chưa ghi nhận kết thúc, outcome/state là trục kết quả riêng.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    ended_at timestamptz,

    -- Vị trí bước kế của execution, miền 0..5; giá trị 5 có thể biểu diễn đã qua bước cuối trong chuỗi tối đa 5
    -- action.
    -- integer: số nguyên có dấu 32 bit; CHECK giới hạn miền nghiệp vụ thay vì chỉ dựa phạm vi kiểu.
    -- NOT NULL: bắt buộc có giá trị.
    -- DEFAULT 0: giá trị dùng khi INSERT bỏ qua cột; không thay NULL được truyền tường minh và không tự áp lại khi
    -- UPDATE.
    -- Ràng buộc hiện hành rule_executions_next_action_position_check: CHECK chỉ chặn khi biểu thức là FALSE;
    -- NULL/UNKNOWN vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK (((next_action_position >= 0) AND (next_action_position <= 5)))
    next_action_position integer NOT NULL DEFAULT 0 CHECK(next_action_position BETWEEN 0 AND 5),

    -- Owner được chụp khi execution admission, dùng phân quyền lịch sử theo policy; request vẫn phải recheck
    -- membership hiện hành.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành rule_executions_workspace_id_owner_user_id_snapshot_fkey: khóa ngoại giữ đúng bản ghi cha;
    -- tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, owner_user_id_snapshot) REFERENCES memberships(workspace_id, user_id)
    owner_user_id_snapshot uuid NOT NULL,

    -- Nguyên nhân thất bại đã chuẩn hóa/redact cho vận hành và lịch sử; không lưu response bí mật của dịch vụ ngoài.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    failure_reason text,

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    PRIMARY KEY(workspace_id,rule_execution_id),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    UNIQUE(workspace_id,rule_execution_id,rule_version_id),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    UNIQUE(workspace_id,rule_version_id,trigger_key),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,rule_id,rule_version_id) REFERENCES rule_versions(workspace_id,rule_id,rule_version_id),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,owner_user_id_snapshot) REFERENCES memberships,

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    CHECK(deadline_at=admitted_at+interval '15 minutes')
);
/* Unicité active par rule; quota workspace serialisé par trigger0007. */
CREATE UNIQUE INDEX uq_rule_executions_active_rule ON rule_executions(workspace_id,rule_id) WHERE state IN ('RUNNING','WAITING');
CREATE INDEX ix_rule_executions_history ON rule_executions(workspace_id,rule_id,admitted_at DESC,rule_execution_id);
-- Bảng rule_execution_snapshots: Payload giải thích execution: input, condition trace và snapshot định nghĩa. Lưu
-- sự thật tại lúc đánh giá để người dùng đọc lịch sử mà không live-join vào draft đã đổi.
CREATE TABLE rule_execution_snapshots (
    -- Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền
    -- của người gọi.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành rule_execution_snapshots_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, rule_execution_id)
    -- Ràng buộc hiện hành rule_execution_snapshots_workspace_id_rule_execution_id_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, rule_execution_id) REFERENCES rule_executions(workspace_id, rule_execution_id)
    workspace_id uuid NOT NULL,

    -- Identity một lần quyết định/chạy rule version, dùng quota, history, action chain và notification target.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành rule_execution_snapshots_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, rule_execution_id)
    -- Ràng buộc hiện hành rule_execution_snapshots_workspace_id_rule_execution_id_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, rule_execution_id) REFERENCES rule_executions(workspace_id, rule_execution_id)
    rule_execution_id uuid NOT NULL,

    -- Dữ liệu đầu vào/quality/time được chụp tại evaluation để giải thích quyết định mà không lấy latest mới ghi đè
    -- lịch sử.
    -- jsonb: tài liệu JSON lưu dạng nhị phân; kiểm object/scalar không thay validation đầy đủ cấu trúc và tham chiếu
    -- nghiệp vụ.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    input_snapshot jsonb NOT NULL,

    -- Trace kết quả từng phần của AST tại evaluation, phục vụ giải thích TRUE/FALSE/UNKNOWN và dry-run/history.
    -- jsonb: tài liệu JSON lưu dạng nhị phân; kiểm object/scalar không thay validation đầy đủ cấu trúc và tham chiếu
    -- nghiệp vụ.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    condition_trace jsonb NOT NULL,

    -- Bản sao định nghĩa cần giữ cho lịch sử khi policy cho phép; không live-join draft mutable để diễn giải execution
    -- cũ.
    -- jsonb: tài liệu JSON lưu dạng nhị phân; kiểm object/scalar không thay validation đầy đủ cấu trúc và tham chiếu
    -- nghiệp vụ.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    definition_snapshot jsonb,

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    PRIMARY KEY(workspace_id,rule_execution_id),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,rule_execution_id) REFERENCES rule_executions
);
-- Bảng schedule_occurrences: Mỗi lần lịch được định danh ổn định theo rule version và occurrence key. Giữ thời
-- gian/timezone snapshot cùng kết quả admission để tránh chạy trùng sau restart/DST.
CREATE TABLE schedule_occurrences (
    -- Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền
    -- của người gọi.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành schedule_occurrences_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, rule_version_id, occurrence_key)
    -- Ràng buộc hiện hành schedule_occurrences_workspace_id_rule_execution_id_rule_v_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, rule_execution_id, rule_version_id) REFERENCES rule_executions(workspace_id,
    -- rule_execution_id, rule_version_id)
    -- Ràng buộc hiện hành schedule_occurrences_workspace_id_rule_version_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ
    -- hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, rule_version_id) REFERENCES rule_versions(workspace_id, rule_version_id)
    workspace_id uuid NOT NULL,

    -- Identity rule snapshot đã publish, dùng pin trigger/action/execution thay vì đọc draft hiện hành.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành schedule_occurrences_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, rule_version_id, occurrence_key)
    -- Ràng buộc hiện hành schedule_occurrences_workspace_id_rule_execution_id_rule_v_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, rule_execution_id, rule_version_id) REFERENCES rule_executions(workspace_id,
    -- rule_execution_id, rule_version_id)
    -- Ràng buộc hiện hành schedule_occurrences_workspace_id_rule_version_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ
    -- hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, rule_version_id) REFERENCES rule_versions(workspace_id, rule_version_id)
    rule_version_id uuid NOT NULL,

    -- Identity calendar ổn định của một lần lịch trong rule version, dùng chống chạy trùng/catchup sai sau restart.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành schedule_occurrences_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, rule_version_id, occurrence_key)
    occurrence_key text NOT NULL,

    -- Instant lịch đã resolve theo timezone/DST policy; không tính lại từ timezone mặc định mới khi job được đọc lại.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    scheduled_at timestamptz NOT NULL,

    -- Múi giờ IANA được chụp khi định danh schedule occurrence, giữ đúng calendar/DST policy dù cấu hình mặc định đổi.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    timezone_snapshot text NOT NULL,

    -- Tiến trình lần lịch PENDING/ADMITTED/SKIPPED/CANCELLED; không tạo occurrence identity mới khi restart đọc lại.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành schedule_occurrences_state_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn
    -- qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((state = ANY (ARRAY['PENDING'::text, 'ADMITTED'::text, 'SKIPPED'::text, 'CANCELLED'::text])))
    state text NOT NULL CHECK(state IN ('PENDING','ADMITTED','SKIPPED','CANCELLED')),

    -- Identity một lần quyết định/chạy rule version, dùng quota, history, action chain và notification target.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    -- Ràng buộc hiện hành schedule_occurrences_workspace_id_rule_execution_id_rule_v_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành. FK MATCH SIMPLE mặc
    -- định bỏ kiểm khi có thành phần NULL; CHECK shape riêng vẫn phải đạt.
    -- FOREIGN KEY (workspace_id, rule_execution_id, rule_version_id) REFERENCES rule_executions(workspace_id,
    -- rule_execution_id, rule_version_id)
    rule_execution_id uuid,

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    PRIMARY KEY(workspace_id,rule_version_id,occurrence_key),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,rule_version_id) REFERENCES rule_versions,

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,rule_execution_id,rule_version_id) REFERENCES rule_executions(workspace_id,rule_execution_id,rule_version_id)
);
/* Lịch đến hạn sau scope, không dùng now() trong partial predicate. */
CREATE INDEX ix_schedule_due ON schedule_occurrences(scheduled_at,workspace_id,rule_version_id) WHERE state='PENDING';
-- Bảng rule_trigger_receipts: Quyết định đã xử lý một trigger identity: nhận chạy, không khớp hoặc bị chặn. Giữ
-- receipt chống replay ngay cả khi payload history execution được purge.
CREATE TABLE rule_trigger_receipts (
    -- Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền
    -- của người gọi.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành rule_trigger_receipts_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, rule_version_id, trigger_key)
    -- Ràng buộc hiện hành rule_trigger_receipts_workspace_id_rule_execution_id_rule__fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, rule_execution_id, rule_version_id) REFERENCES rule_executions(workspace_id,
    -- rule_execution_id, rule_version_id)
    -- Ràng buộc hiện hành rule_trigger_receipts_workspace_id_rule_version_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ
    -- hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, rule_version_id) REFERENCES rule_versions(workspace_id, rule_version_id)
    workspace_id uuid NOT NULL,

    -- Identity rule snapshot đã publish, dùng pin trigger/action/execution thay vì đọc draft hiện hành.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành rule_trigger_receipts_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, rule_version_id, trigger_key)
    -- Ràng buộc hiện hành rule_trigger_receipts_workspace_id_rule_execution_id_rule__fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, rule_execution_id, rule_version_id) REFERENCES rule_executions(workspace_id,
    -- rule_execution_id, rule_version_id)
    -- Ràng buộc hiện hành rule_trigger_receipts_workspace_id_rule_version_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ
    -- hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, rule_version_id) REFERENCES rule_versions(workspace_id, rule_version_id)
    rule_version_id uuid NOT NULL,

    -- Identity ổn định của trigger/episode/occurrence theo version; dùng dedupe, không sinh key mới chỉ vì worker
    -- restart.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành rule_trigger_receipts_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, rule_version_id, trigger_key)
    trigger_key text NOT NULL,

    -- Quyết định đã xử lý trigger: ADMITTED/NO_MATCH/SUPPRESSED/REJECTED, phục vụ chống lặp admission.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành rule_trigger_receipts_decision_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN
    -- vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((decision = ANY (ARRAY['ADMITTED'::text, 'NO_MATCH'::text, 'SUPPRESSED'::text, 'REJECTED'::text])))
    decision text NOT NULL CHECK(decision IN ('ADMITTED','NO_MATCH','SUPPRESSED','REJECTED')),

    -- Thời điểm quyết định trigger được ghi bền vững, không dùng thời điểm worker đọc lại làm lần trigger mới.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    decided_at timestamptz NOT NULL,

    -- Identity một lần quyết định/chạy rule version, dùng quota, history, action chain và notification target.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    -- Ràng buộc hiện hành rule_trigger_receipts_workspace_id_rule_execution_id_rule__fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành. FK MATCH SIMPLE mặc
    -- định bỏ kiểm khi có thành phần NULL; CHECK shape riêng vẫn phải đạt.
    -- FOREIGN KEY (workspace_id, rule_execution_id, rule_version_id) REFERENCES rule_executions(workspace_id,
    -- rule_execution_id, rule_version_id)
    rule_execution_id uuid,

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    PRIMARY KEY(workspace_id,rule_version_id,trigger_key),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,rule_version_id) REFERENCES rule_versions,

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,rule_execution_id,rule_version_id) REFERENCES rule_executions(workspace_id,rule_execution_id,rule_version_id)
);
-- Bảng execution_actuator_snapshots: Manual epoch của từng actuator tại đầu execution. Giữ snapshot trước WAIT để
-- automation phát hiện người dùng đã điều khiển thủ công và không ghi đè thao tác mới.
CREATE TABLE execution_actuator_snapshots (
    -- Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền
    -- của người gọi.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành execution_actuator_snapshots_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, rule_execution_id, device_id, stream_key)
    -- Ràng buộc hiện hành execution_actuator_snapshots_workspace_id_device_id_stream_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, device_id, stream_key) REFERENCES actuator_states(workspace_id, device_id,
    -- stream_key)
    -- Ràng buộc hiện hành execution_actuator_snapshots_workspace_id_rule_execution_i_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, rule_execution_id) REFERENCES rule_executions(workspace_id, rule_execution_id)
    workspace_id uuid NOT NULL,

    -- Identity một lần quyết định/chạy rule version, dùng quota, history, action chain và notification target.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành execution_actuator_snapshots_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, rule_execution_id, device_id, stream_key)
    -- Ràng buộc hiện hành execution_actuator_snapshots_workspace_id_rule_execution_i_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, rule_execution_id) REFERENCES rule_executions(workspace_id, rule_execution_id)
    rule_execution_id uuid NOT NULL,

    -- Identity thiết bị toàn cục để resolve MQTT và registry; kết hợp workspace_id bảo vệ mọi tham chiếu trong đúng
    -- tenant.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành execution_actuator_snapshots_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, rule_execution_id, device_id, stream_key)
    -- Ràng buộc hiện hành execution_actuator_snapshots_workspace_id_device_id_stream_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, device_id, stream_key) REFERENCES actuator_states(workspace_id, device_id,
    -- stream_key)
    device_id uuid NOT NULL,

    -- Khóa kỹ thuật ổn định của kênh trong template/version; không dùng nhãn hiển thị thay khóa schema.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành execution_actuator_snapshots_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, rule_execution_id, device_id, stream_key)
    -- Ràng buộc hiện hành execution_actuator_snapshots_workspace_id_device_id_stream_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, device_id, stream_key) REFERENCES actuator_states(workspace_id, device_id,
    -- stream_key)
    stream_key text NOT NULL,

    -- Manual epoch của actuator được chụp lúc execution bắt đầu, trước WAIT; không đọc lại sau WAIT rồi coi là
    -- snapshot ban đầu.
    -- bigint: số nguyên có dấu 64 bit, phù hợp bộ đếm/generation tăng lâu dài; không tự tăng nếu chưa có cơ chế cấp
    -- giá trị.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành execution_actuator_snapshots_manual_epoch_at_start_check: CHECK chỉ chặn khi biểu thức là
    -- FALSE; NULL/UNKNOWN vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((manual_epoch_at_start >= 0))
    manual_epoch_at_start bigint NOT NULL CHECK(manual_epoch_at_start>=0),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    PRIMARY KEY(workspace_id,rule_execution_id,device_id,stream_key),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,rule_execution_id) REFERENCES rule_executions,

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,device_id,stream_key) REFERENCES actuator_states
);
-- Bảng action_executions: Trạng thái từng action trong một execution, gắn đúng rule version và action_position.
-- Giữ command backlink và lý do kết thúc để coordinator quyết định bước kế.
CREATE TABLE action_executions (
    -- Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền
    -- của người gọi.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành action_executions_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì uniqueness
    -- áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, rule_execution_id, action_position)
    -- Ràng buộc hiện hành action_executions_workspace_id_action_execution_id_command__key: không trùng tổ hợp giá trị
    -- được nêu; các cột riêng lẻ vẫn có thể lặp khi khóa có nhiều cột.
    -- UNIQUE (workspace_id, action_execution_id, command_id)
    -- Ràng buộc hiện hành action_executions_workspace_id_action_execution_id_key: không trùng tổ hợp giá trị được nêu;
    -- các cột riêng lẻ vẫn có thể lặp khi khóa có nhiều cột.
    -- UNIQUE (workspace_id, action_execution_id)
    -- Ràng buộc hiện hành action_executions_workspace_id_rule_execution_id_rule_vers_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, rule_execution_id, rule_version_id) REFERENCES rule_executions(workspace_id,
    -- rule_execution_id, rule_version_id)
    -- Ràng buộc hiện hành action_executions_workspace_id_rule_version_id_action_posi_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, rule_version_id, action_position) REFERENCES rule_version_actions(workspace_id,
    -- rule_version_id, action_position)
    -- Ràng buộc hiện hành fk_action_command: khóa ngoại giữ đúng bản ghi cha; tổ hợp có workspace_id giữ quan hệ trong
    -- đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, command_id, action_execution_id) REFERENCES commands(workspace_id, command_id,
    -- action_execution_id) DEFERRABLE INITIALLY DEFERRED
    workspace_id uuid NOT NULL,

    -- Identity một lần quyết định/chạy rule version, dùng quota, history, action chain và notification target.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành action_executions_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì uniqueness
    -- áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, rule_execution_id, action_position)
    -- Ràng buộc hiện hành action_executions_workspace_id_rule_execution_id_rule_vers_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, rule_execution_id, rule_version_id) REFERENCES rule_executions(workspace_id,
    -- rule_execution_id, rule_version_id)
    rule_execution_id uuid NOT NULL,

    -- Chỉ số action bắt đầu 0 trong chuỗi tối đa 5 bước, dùng ghép definition/action execution/job.
    -- integer: số nguyên có dấu 32 bit; CHECK giới hạn miền nghiệp vụ thay vì chỉ dựa phạm vi kiểu.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành action_executions_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì uniqueness
    -- áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, rule_execution_id, action_position)
    -- Ràng buộc hiện hành action_executions_workspace_id_rule_version_id_action_posi_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, rule_version_id, action_position) REFERENCES rule_version_actions(workspace_id,
    -- rule_version_id, action_position)
    action_position integer NOT NULL,

    -- Identity ổn định của một action runtime; unique command theo identity này ngăn retry tạo lệnh vật lý thứ hai.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành action_executions_workspace_id_action_execution_id_command__key: không trùng tổ hợp giá trị
    -- được nêu; các cột riêng lẻ vẫn có thể lặp khi khóa có nhiều cột.
    -- UNIQUE (workspace_id, action_execution_id, command_id)
    -- Ràng buộc hiện hành action_executions_workspace_id_action_execution_id_key: không trùng tổ hợp giá trị được nêu;
    -- các cột riêng lẻ vẫn có thể lặp khi khóa có nhiều cột.
    -- UNIQUE (workspace_id, action_execution_id)
    -- Ràng buộc hiện hành fk_action_command: khóa ngoại giữ đúng bản ghi cha; tổ hợp có workspace_id giữ quan hệ trong
    -- đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, command_id, action_execution_id) REFERENCES commands(workspace_id, command_id,
    -- action_execution_id) DEFERRABLE INITIALLY DEFERRED
    action_execution_id uuid NOT NULL,

    -- Identity rule snapshot đã publish, dùng pin trigger/action/execution thay vì đọc draft hiện hành.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành action_executions_workspace_id_rule_execution_id_rule_vers_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, rule_execution_id, rule_version_id) REFERENCES rule_executions(workspace_id,
    -- rule_execution_id, rule_version_id)
    -- Ràng buộc hiện hành action_executions_workspace_id_rule_version_id_action_posi_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, rule_version_id, action_position) REFERENCES rule_version_actions(workspace_id,
    -- rule_version_id, action_position)
    rule_version_id uuid NOT NULL,

    -- Trạng thái từng bước
    -- BLOCKED/READY/WAITING/DISPATCHING/AWAITING_RESULT/SUCCEEDED/FAILED/CANCELLED/NEEDS_ATTENTION; UNKNOWN không tự
    -- unblock bước sau.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành action_executions_state_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua,
    -- nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((state = ANY (ARRAY['BLOCKED'::text, 'READY'::text, 'WAITING'::text, 'DISPATCHING'::text,
    -- 'AWAITING_RESULT'::text, 'SUCCEEDED'::text, 'FAILED'::text, 'CANCELLED'::text, 'NEEDS_ATTENTION'::text])))
    state text NOT NULL CHECK(state IN ('BLOCKED','READY','WAITING','DISPATCHING','AWAITING_RESULT','SUCCEEDED','FAILED','CANCELLED','NEEDS_ATTENTION')),

    -- Thời điểm bắt đầu boot/enrollment/action hoặc hoạt động tương ứng, tùy ngữ nghĩa bảng.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    started_at timestamptz,

    -- Thời điểm execution/action kết thúc; NULL khi chưa ghi nhận kết thúc, outcome/state là trục kết quả riêng.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    ended_at timestamptz,

    -- Identity command ổn định qua retry/result/reconciliation; không tạo command mới chỉ vì mất response.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    -- Ràng buộc hiện hành action_executions_workspace_id_action_execution_id_command__key: không trùng tổ hợp giá trị
    -- được nêu; các cột riêng lẻ vẫn có thể lặp khi khóa có nhiều cột. UNIQUE mặc định không coi các giá trị NULL là
    -- trùng nhau.
    -- UNIQUE (workspace_id, action_execution_id, command_id)
    -- Ràng buộc hiện hành fk_action_command: khóa ngoại giữ đúng bản ghi cha; tổ hợp có workspace_id giữ quan hệ trong
    -- đúng tenant, không thay kiểm quyền hiện hành. FK MATCH SIMPLE mặc định bỏ kiểm khi có thành phần NULL; CHECK
    -- shape riêng vẫn phải đạt.
    -- FOREIGN KEY (workspace_id, command_id, action_execution_id) REFERENCES commands(workspace_id, command_id,
    -- action_execution_id) DEFERRABLE INITIALLY DEFERRED
    command_id uuid,

    -- Mã nguyên nhân ổn định để giải thích kết quả/transition; phải là nội dung an toàn, không chứa raw lỗi/secret.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    reason_code text,

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    PRIMARY KEY(workspace_id,rule_execution_id,action_position),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    UNIQUE(workspace_id,action_execution_id),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    UNIQUE(workspace_id,action_execution_id,command_id),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,rule_execution_id,rule_version_id) REFERENCES rule_executions(workspace_id,rule_execution_id,rule_version_id),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,rule_version_id,action_position) REFERENCES rule_version_actions
);
-- Bảng action_jobs: Công việc bền vững tương ứng từng action, gồm dueAt, lease và retry counter. WAIT dùng thời
-- điểm tuyệt đối trong DB; worker không giữ timer RAM làm nguồn sự thật.
CREATE TABLE action_jobs (
    -- Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền
    -- của người gọi.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành action_jobs_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì uniqueness áp
    -- dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, rule_execution_id, action_position)
    -- Ràng buộc hiện hành action_jobs_workspace_id_rule_execution_id_action_position_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, rule_execution_id, action_position) REFERENCES action_executions(workspace_id,
    -- rule_execution_id, action_position)
    workspace_id uuid NOT NULL,

    -- Identity một lần quyết định/chạy rule version, dùng quota, history, action chain và notification target.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành action_jobs_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì uniqueness áp
    -- dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, rule_execution_id, action_position)
    -- Ràng buộc hiện hành action_jobs_workspace_id_rule_execution_id_action_position_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, rule_execution_id, action_position) REFERENCES action_executions(workspace_id,
    -- rule_execution_id, action_position)
    rule_execution_id uuid NOT NULL,

    -- Chỉ số action bắt đầu 0 trong chuỗi tối đa 5 bước, dùng ghép definition/action execution/job.
    -- integer: số nguyên có dấu 32 bit; CHECK giới hạn miền nghiệp vụ thay vì chỉ dựa phạm vi kiểu.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành action_jobs_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì uniqueness áp
    -- dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, rule_execution_id, action_position)
    -- Ràng buộc hiện hành action_jobs_workspace_id_rule_execution_id_action_position_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, rule_execution_id, action_position) REFERENCES action_executions(workspace_id,
    -- rule_execution_id, action_position)
    action_position integer NOT NULL,

    -- Trạng thái công việc tương ứng action execution; chỉ một READY/execution, due_at và lease quyết định khi worker
    -- được claim.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành action_jobs_state_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên
    -- phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((state = ANY (ARRAY['BLOCKED'::text, 'READY'::text, 'WAITING'::text, 'DISPATCHING'::text,
    -- 'AWAITING_RESULT'::text, 'SUCCEEDED'::text, 'FAILED'::text, 'CANCELLED'::text, 'NEEDS_ATTENTION'::text])))
    state text NOT NULL CHECK(state IN ('BLOCKED','READY','WAITING','DISPATCHING','AWAITING_RESULT','SUCCEEDED','FAILED','CANCELLED','NEEDS_ATTENTION')),

    -- Thời điểm tuyệt đối UTC mà job/lượt WAIT được phép đến hạn; timer RAM chỉ đánh thức worker, không thay mốc này.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    due_at timestamptz NOT NULL,

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
    -- Ràng buộc hiện hành action_jobs_lease_generation_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn
    -- qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((lease_generation >= 0))
    lease_generation bigint NOT NULL DEFAULT 0 CHECK(lease_generation>=0),

    -- Số lần xử lý/claim đã tiêu hao theo pipeline; không tự coi một lần retry là một ý định nghiệp vụ mới.
    -- integer: số nguyên có dấu 32 bit; CHECK giới hạn miền nghiệp vụ thay vì chỉ dựa phạm vi kiểu.
    -- NOT NULL: bắt buộc có giá trị.
    -- DEFAULT 0: giá trị dùng khi INSERT bỏ qua cột; không thay NULL được truyền tường minh và không tự áp lại khi
    -- UPDATE.
    -- Ràng buộc hiện hành action_jobs_attempt_count_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn
    -- qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((attempt_count >= 0))
    attempt_count integer NOT NULL DEFAULT 0 CHECK(attempt_count>=0),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    PRIMARY KEY(workspace_id,rule_execution_id,action_position),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,rule_execution_id,action_position) REFERENCES action_executions
);
/* Một bước READY/execution; claim theo due_at và lease_generation, không giữ lock qua mạng. */
CREATE UNIQUE INDEX uq_action_jobs_ready ON action_jobs(workspace_id,rule_execution_id) WHERE state='READY';
CREATE INDEX ix_action_jobs_due ON action_jobs(due_at,workspace_id,rule_execution_id) WHERE state IN ('READY','WAITING');
-- Bảng commands: Ledger mỗi lần nhận yêu cầu điều khiển: nguồn lệnh, giá trị đích, deadline và kết quả vật lý.
-- Tách admission/dispatch khỏi terminal outcome; UNKNOWN không được biến thành thành công chỉ vì có ACK thủ công.
CREATE TABLE commands (
    -- Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền
    -- của người gọi.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành commands_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì uniqueness áp dụng
    -- cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, command_id)
    -- Ràng buộc hiện hành commands_workspace_id_action_execution_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ hợp có
    -- workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, action_execution_id) REFERENCES action_executions(workspace_id, action_execution_id)
    -- Ràng buộc hiện hành commands_workspace_id_actor_user_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ hợp có
    -- workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, actor_user_id) REFERENCES memberships(workspace_id, user_id)
    -- Ràng buộc hiện hành commands_workspace_id_command_id_action_execution_id_key: không trùng tổ hợp giá trị được
    -- nêu; các cột riêng lẻ vẫn có thể lặp khi khóa có nhiều cột.
    -- UNIQUE (workspace_id, command_id, action_execution_id)
    -- Ràng buộc hiện hành commands_workspace_id_command_id_device_id_key: không trùng tổ hợp giá trị được nêu; các cột
    -- riêng lẻ vẫn có thể lặp khi khóa có nhiều cột.
    -- UNIQUE (workspace_id, command_id, device_id)
    -- Ràng buộc hiện hành commands_workspace_id_device_id_stream_key_command_id_key: không trùng tổ hợp giá trị được
    -- nêu; các cột riêng lẻ vẫn có thể lặp khi khóa có nhiều cột.
    -- UNIQUE (workspace_id, device_id, stream_key, command_id)
    -- Ràng buộc hiện hành commands_workspace_id_device_id_stream_key_fkey: khóa ngoại giữ đúng bản ghi cha; tổ hợp có
    -- workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, device_id, stream_key) REFERENCES actuator_states(workspace_id, device_id,
    -- stream_key)
    -- Ràng buộc hiện hành fk_commands_api_key: khóa ngoại giữ đúng bản ghi cha; tổ hợp có workspace_id giữ quan hệ
    -- trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, api_key_id) REFERENCES api_keys(workspace_id, api_key_id)
    workspace_id uuid NOT NULL,

    -- Identity command ổn định qua retry/result/reconciliation; không tạo command mới chỉ vì mất response.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành commands_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì uniqueness áp dụng
    -- cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, command_id)
    -- Ràng buộc hiện hành commands_workspace_id_command_id_action_execution_id_key: không trùng tổ hợp giá trị được
    -- nêu; các cột riêng lẻ vẫn có thể lặp khi khóa có nhiều cột.
    -- UNIQUE (workspace_id, command_id, action_execution_id)
    -- Ràng buộc hiện hành commands_workspace_id_command_id_device_id_key: không trùng tổ hợp giá trị được nêu; các cột
    -- riêng lẻ vẫn có thể lặp khi khóa có nhiều cột.
    -- UNIQUE (workspace_id, command_id, device_id)
    -- Ràng buộc hiện hành commands_workspace_id_device_id_stream_key_command_id_key: không trùng tổ hợp giá trị được
    -- nêu; các cột riêng lẻ vẫn có thể lặp khi khóa có nhiều cột.
    -- UNIQUE (workspace_id, device_id, stream_key, command_id)
    command_id uuid NOT NULL,

    -- Identity thiết bị toàn cục để resolve MQTT và registry; kết hợp workspace_id bảo vệ mọi tham chiếu trong đúng
    -- tenant.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành commands_workspace_id_command_id_device_id_key: không trùng tổ hợp giá trị được nêu; các cột
    -- riêng lẻ vẫn có thể lặp khi khóa có nhiều cột.
    -- UNIQUE (workspace_id, command_id, device_id)
    -- Ràng buộc hiện hành commands_workspace_id_device_id_stream_key_command_id_key: không trùng tổ hợp giá trị được
    -- nêu; các cột riêng lẻ vẫn có thể lặp khi khóa có nhiều cột.
    -- UNIQUE (workspace_id, device_id, stream_key, command_id)
    -- Ràng buộc hiện hành commands_workspace_id_device_id_stream_key_fkey: khóa ngoại giữ đúng bản ghi cha; tổ hợp có
    -- workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, device_id, stream_key) REFERENCES actuator_states(workspace_id, device_id,
    -- stream_key)
    device_id uuid NOT NULL,

    -- Khóa kỹ thuật ổn định của kênh trong template/version; không dùng nhãn hiển thị thay khóa schema.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành commands_workspace_id_device_id_stream_key_command_id_key: không trùng tổ hợp giá trị được
    -- nêu; các cột riêng lẻ vẫn có thể lặp khi khóa có nhiều cột.
    -- UNIQUE (workspace_id, device_id, stream_key, command_id)
    -- Ràng buộc hiện hành commands_workspace_id_device_id_stream_key_fkey: khóa ngoại giữ đúng bản ghi cha; tổ hợp có
    -- workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, device_id, stream_key) REFERENCES actuator_states(workspace_id, device_id,
    -- stream_key)
    stream_key text NOT NULL,

    -- Nguồn command MANUAL/AUTOMATION/INTEGRATION, quyết định actor/user, action execution hoặc API key phải có.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành ck_command_origin: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên phải
    -- phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((((origin_type = 'MANUAL'::text) AND (actor_user_id IS NOT NULL) AND (api_key_id IS NULL) AND
    -- (action_execution_id IS NULL)) OR ((origin_type = 'AUTOMATION'::text) AND (action_execution_id IS NOT NULL) AND
    -- (actor_user_id IS NULL) AND (api_key_id IS NULL)) OR ((origin_type = 'INTEGRATION'::text) AND (api_key_id IS NOT
    -- NULL) AND (actor_user_id IS NULL) AND (action_execution_id IS NULL))))
    -- Ràng buộc hiện hành commands_origin_type_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên
    -- phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((origin_type = ANY (ARRAY['MANUAL'::text, 'AUTOMATION'::text, 'INTEGRATION'::text])))
    origin_type text NOT NULL CHECK(origin_type IN ('MANUAL','AUTOMATION','INTEGRATION')),

    -- Người phát lệnh MANUAL; phải NULL cho AUTOMATION/INTEGRATION vì hai nguồn đó có principal typed riêng.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    -- Ràng buộc hiện hành ck_command_origin: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên phải
    -- phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((((origin_type = 'MANUAL'::text) AND (actor_user_id IS NOT NULL) AND (api_key_id IS NULL) AND
    -- (action_execution_id IS NULL)) OR ((origin_type = 'AUTOMATION'::text) AND (action_execution_id IS NOT NULL) AND
    -- (actor_user_id IS NULL) AND (api_key_id IS NULL)) OR ((origin_type = 'INTEGRATION'::text) AND (api_key_id IS NOT
    -- NULL) AND (actor_user_id IS NULL) AND (action_execution_id IS NULL))))
    -- Ràng buộc hiện hành commands_workspace_id_actor_user_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ hợp có
    -- workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành. FK MATCH SIMPLE mặc định bỏ kiểm
    -- khi có thành phần NULL; CHECK shape riêng vẫn phải đạt.
    -- FOREIGN KEY (workspace_id, actor_user_id) REFERENCES memberships(workspace_id, user_id)
    actor_user_id uuid,

    -- Identity principal API key toàn cục, dùng resolve workspace trước kiểm quyền; không chứa raw key secret.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    -- Ràng buộc hiện hành ck_command_origin: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên phải
    -- phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((((origin_type = 'MANUAL'::text) AND (actor_user_id IS NOT NULL) AND (api_key_id IS NULL) AND
    -- (action_execution_id IS NULL)) OR ((origin_type = 'AUTOMATION'::text) AND (action_execution_id IS NOT NULL) AND
    -- (actor_user_id IS NULL) AND (api_key_id IS NULL)) OR ((origin_type = 'INTEGRATION'::text) AND (api_key_id IS NOT
    -- NULL) AND (actor_user_id IS NULL) AND (action_execution_id IS NULL))))
    -- Ràng buộc hiện hành fk_commands_api_key: khóa ngoại giữ đúng bản ghi cha; tổ hợp có workspace_id giữ quan hệ
    -- trong đúng tenant, không thay kiểm quyền hiện hành. FK MATCH SIMPLE mặc định bỏ kiểm khi có thành phần NULL;
    -- CHECK shape riêng vẫn phải đạt.
    -- FOREIGN KEY (workspace_id, api_key_id) REFERENCES api_keys(workspace_id, api_key_id)
    api_key_id uuid,

    -- Identity ổn định của một action runtime; unique command theo identity này ngăn retry tạo lệnh vật lý thứ hai.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    -- Ràng buộc hiện hành ck_command_origin: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên phải
    -- phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((((origin_type = 'MANUAL'::text) AND (actor_user_id IS NOT NULL) AND (api_key_id IS NULL) AND
    -- (action_execution_id IS NULL)) OR ((origin_type = 'AUTOMATION'::text) AND (action_execution_id IS NOT NULL) AND
    -- (actor_user_id IS NULL) AND (api_key_id IS NULL)) OR ((origin_type = 'INTEGRATION'::text) AND (api_key_id IS NOT
    -- NULL) AND (actor_user_id IS NULL) AND (action_execution_id IS NULL))))
    -- Ràng buộc hiện hành commands_workspace_id_action_execution_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ hợp có
    -- workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành. FK MATCH SIMPLE mặc định bỏ kiểm
    -- khi có thành phần NULL; CHECK shape riêng vẫn phải đạt.
    -- FOREIGN KEY (workspace_id, action_execution_id) REFERENCES action_executions(workspace_id, action_execution_id)
    -- Ràng buộc hiện hành commands_workspace_id_command_id_action_execution_id_key: không trùng tổ hợp giá trị được
    -- nêu; các cột riêng lẻ vẫn có thể lặp khi khóa có nhiều cột. UNIQUE mặc định không coi các giá trị NULL là trùng
    -- nhau.
    -- UNIQUE (workspace_id, command_id, action_execution_id)
    action_execution_id uuid,

    -- Nhánh kiểu dữ liệu của giá trị được lưu; XOR chọn đúng cột numeric/boolean/text và phải khớp pinned definition.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành ck_command_value: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên phải phối
    -- hợp NOT NULL và CHECK shape khi cần.
    -- CHECK (((num_nonnulls(numeric_value, boolean_value, text_value) = 1) AND (((value_type = 'NUMBER'::text) AND
    -- (numeric_value IS NOT NULL)) OR ((value_type = 'BOOLEAN'::text) AND (boolean_value IS NOT NULL)) OR ((value_type
    -- = 'ENUM'::text) AND ((numeric_value IS NOT NULL) OR (text_value IS NOT NULL))))))
    -- Ràng buộc hiện hành commands_value_type_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên
    -- phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((value_type = ANY (ARRAY['NUMBER'::text, 'BOOLEAN'::text, 'ENUM'::text])))
    value_type text NOT NULL CHECK(value_type IN ('NUMBER','BOOLEAN','ENUM')),

    -- Giá trị số hữu hạn của nhánh NUMBER hoặc ENUM số; NULL khi dùng nhánh giá trị khác hoặc quality NULL.
    -- double precision: số thực dấu phẩy động 64 bit, có sai số biểu diễn; kiểm finite/range theo CHECK và validator.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    -- Ràng buộc hiện hành ck_command_value: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên phải phối
    -- hợp NOT NULL và CHECK shape khi cần.
    -- CHECK (((num_nonnulls(numeric_value, boolean_value, text_value) = 1) AND (((value_type = 'NUMBER'::text) AND
    -- (numeric_value IS NOT NULL)) OR ((value_type = 'BOOLEAN'::text) AND (boolean_value IS NOT NULL)) OR ((value_type
    -- = 'ENUM'::text) AND ((numeric_value IS NOT NULL) OR (text_value IS NOT NULL))))))
    -- Ràng buộc hiện hành commands_numeric_value_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua,
    -- nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK (((numeric_value IS NULL) OR ((numeric_value > '-Infinity'::double precision) AND (numeric_value <
    -- 'Infinity'::double precision))))
    numeric_value double precision,

    -- Giá trị boolean của nhánh BOOLEAN; false là dữ liệu thật, không tương đương NULL/missing.
    -- boolean: cờ logic true/false; NULL là trạng thái riêng nếu cột cho phép.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    -- Ràng buộc hiện hành ck_command_value: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên phải phối
    -- hợp NOT NULL và CHECK shape khi cần.
    -- CHECK (((num_nonnulls(numeric_value, boolean_value, text_value) = 1) AND (((value_type = 'NUMBER'::text) AND
    -- (numeric_value IS NOT NULL)) OR ((value_type = 'BOOLEAN'::text) AND (boolean_value IS NOT NULL)) OR ((value_type
    -- = 'ENUM'::text) AND ((numeric_value IS NOT NULL) OR (text_value IS NOT NULL))))))
    boolean_value boolean,

    -- Giá trị chuỗi của nhánh STRING hoặc ENUM chuỗi; không chuyển mọi datatype thành text để bỏ kiểm kiểu.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    -- Ràng buộc hiện hành ck_command_value: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên phải phối
    -- hợp NOT NULL và CHECK shape khi cần.
    -- CHECK (((num_nonnulls(numeric_value, boolean_value, text_value) = 1) AND (((value_type = 'NUMBER'::text) AND
    -- (numeric_value IS NOT NULL)) OR ((value_type = 'BOOLEAN'::text) AND (boolean_value IS NOT NULL)) OR ((value_type
    -- = 'ENUM'::text) AND ((numeric_value IS NOT NULL) OR (text_value IS NOT NULL))))))
    text_value text,

    -- Tiến trình command từ ADMITTED qua dispatch tới terminal; transition được guard, không nhảy thẳng admission
    -- thành success.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- DEFAULT 'ADMITTED'::text: giá trị dùng khi INSERT bỏ qua cột; không thay NULL được truyền tường minh và không tự
    -- áp lại khi UPDATE.
    -- Ràng buộc hiện hành ck_command_state_outcome: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên
    -- phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((((state = ANY (ARRAY['ADMITTED'::text, 'DISPATCHING'::text, 'DISPATCHED'::text, 'ACCEPTED'::text])) AND
    -- (outcome = 'PENDING'::text) AND (terminal_at IS NULL)) OR ((state = 'SUCCEEDED'::text) AND (outcome =
    -- 'SUCCEEDED'::text) AND (terminal_at IS NOT NULL)) OR ((state = ANY (ARRAY['FAILED'::text,
    -- 'EXPIRED_BEFORE_DISPATCH'::text, 'CANCELLED'::text])) AND (outcome = 'FAILED'::text) AND (terminal_at IS NOT
    -- NULL)) OR ((state = 'TIMED_OUT'::text) AND (outcome = 'UNKNOWN'::text) AND (terminal_at IS NOT NULL))))
    -- Ràng buộc hiện hành commands_state_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên phải
    -- phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((state = ANY (ARRAY['ADMITTED'::text, 'DISPATCHING'::text, 'DISPATCHED'::text, 'ACCEPTED'::text,
    -- 'SUCCEEDED'::text, 'FAILED'::text, 'TIMED_OUT'::text, 'EXPIRED_BEFORE_DISPATCH'::text, 'CANCELLED'::text])))
    state text NOT NULL DEFAULT 'ADMITTED' CHECK(state IN ('ADMITTED','DISPATCHING','DISPATCHED','ACCEPTED','SUCCEEDED','FAILED','TIMED_OUT','EXPIRED_BEFORE_DISPATCH','CANCELLED')),

    -- Kết quả vật lý PENDING/SUCCEEDED/FAILED/UNKNOWN; TIMED_OUT giữ UNKNOWN kể cả sau ACK thủ công hoặc thêm late
    -- evidence.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- DEFAULT 'PENDING'::text: giá trị dùng khi INSERT bỏ qua cột; không thay NULL được truyền tường minh và không tự
    -- áp lại khi UPDATE.
    -- Ràng buộc hiện hành ck_command_state_outcome: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên
    -- phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((((state = ANY (ARRAY['ADMITTED'::text, 'DISPATCHING'::text, 'DISPATCHED'::text, 'ACCEPTED'::text])) AND
    -- (outcome = 'PENDING'::text) AND (terminal_at IS NULL)) OR ((state = 'SUCCEEDED'::text) AND (outcome =
    -- 'SUCCEEDED'::text) AND (terminal_at IS NOT NULL)) OR ((state = ANY (ARRAY['FAILED'::text,
    -- 'EXPIRED_BEFORE_DISPATCH'::text, 'CANCELLED'::text])) AND (outcome = 'FAILED'::text) AND (terminal_at IS NOT
    -- NULL)) OR ((state = 'TIMED_OUT'::text) AND (outcome = 'UNKNOWN'::text) AND (terminal_at IS NOT NULL))))
    -- Ràng buộc hiện hành commands_outcome_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên
    -- phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((outcome = ANY (ARRAY['PENDING'::text, 'SUCCEEDED'::text, 'FAILED'::text, 'UNKNOWN'::text])))
    outcome text NOT NULL DEFAULT 'PENDING' CHECK(outcome IN ('PENDING','SUCCEEDED','FAILED','UNKNOWN')),

    -- Thời điểm yêu cầu được backend nhận vào ledger sau kiểm điều kiện; không chứng minh side effect đã thực hiện.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành commands_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên phải phối
    -- hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((deadline_at = (admitted_at + '00:00:10'::interval)))
    admitted_at timestamptz NOT NULL,

    -- Deadline cố định admitted_at + 10 giây; command đã có khả năng dispatch mà hết hạn không được blind retry.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành commands_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên phải phối
    -- hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((deadline_at = (admitted_at + '00:00:10'::interval)))
    deadline_at timestamptz NOT NULL,

    -- Thời điểm lưu ý định dispatch command trước network; dùng phân biệt chưa gửi với đã có khả năng tác động vật lý.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    dispatch_intent_at timestamptz,

    -- Thời điểm quan sát trạng thái kết thúc của command/delivery; không thay gốc expiry hoặc gốc retention.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    -- Ràng buộc hiện hành ck_command_state_outcome: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên
    -- phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((((state = ANY (ARRAY['ADMITTED'::text, 'DISPATCHING'::text, 'DISPATCHED'::text, 'ACCEPTED'::text])) AND
    -- (outcome = 'PENDING'::text) AND (terminal_at IS NULL)) OR ((state = 'SUCCEEDED'::text) AND (outcome =
    -- 'SUCCEEDED'::text) AND (terminal_at IS NOT NULL)) OR ((state = ANY (ARRAY['FAILED'::text,
    -- 'EXPIRED_BEFORE_DISPATCH'::text, 'CANCELLED'::text])) AND (outcome = 'FAILED'::text) AND (terminal_at IS NOT
    -- NULL)) OR ((state = 'TIMED_OUT'::text) AND (outcome = 'UNKNOWN'::text) AND (terminal_at IS NOT NULL))))
    terminal_at timestamptz,

    -- Manual epoch chụp khi command admission, để kiểm command/automation không dựa vào quyền điều khiển đã lỗi thời.
    -- bigint: số nguyên có dấu 64 bit, phù hợp bộ đếm/generation tăng lâu dài; không tự tăng nếu chưa có cơ chế cấp
    -- giá trị.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành commands_manual_epoch_snapshot_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN
    -- vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((manual_epoch_snapshot >= 0))
    manual_epoch_snapshot bigint NOT NULL CHECK(manual_epoch_snapshot>=0),

    -- Phiên bản chỉnh sửa bản ghi dùng cho CAS/If-Match hoặc đối soát; bên ghi chịu trách nhiệm cập nhật theo đúng
    -- transaction contract.
    -- bigint: số nguyên có dấu 64 bit, phù hợp bộ đếm/generation tăng lâu dài; không tự tăng nếu chưa có cơ chế cấp
    -- giá trị.
    -- NOT NULL: bắt buộc có giá trị.
    -- DEFAULT 1: giá trị dùng khi INSERT bỏ qua cột; không thay NULL được truyền tường minh và không tự áp lại khi
    -- UPDATE.
    -- Ràng buộc hiện hành commands_revision_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên
    -- phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((revision > 0))
    revision bigint NOT NULL DEFAULT 1 CHECK(revision>0),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    PRIMARY KEY(workspace_id,command_id),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    UNIQUE(workspace_id,command_id,device_id),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    UNIQUE(workspace_id,device_id,stream_key,command_id),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    UNIQUE(workspace_id,command_id,action_execution_id),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,device_id,stream_key) REFERENCES actuator_states,

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,actor_user_id) REFERENCES memberships,

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,action_execution_id) REFERENCES action_executions(workspace_id,action_execution_id),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    CHECK(deadline_at=admitted_at+interval '10 seconds'),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    CONSTRAINT ck_command_origin CHECK(
  (origin_type='MANUAL' AND actor_user_id IS NOT NULL AND api_key_id IS NULL AND action_execution_id IS NULL) OR
  (origin_type='AUTOMATION' AND action_execution_id IS NOT NULL AND actor_user_id IS NULL AND api_key_id IS NULL) OR
  (origin_type='INTEGRATION' AND api_key_id IS NOT NULL AND actor_user_id IS NULL AND action_execution_id IS NULL)),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    CONSTRAINT ck_command_value CHECK(num_nonnulls(numeric_value,boolean_value,text_value)=1 AND
  ((value_type='NUMBER' AND numeric_value IS NOT NULL) OR (value_type='BOOLEAN' AND boolean_value IS NOT NULL) OR (value_type='ENUM' AND (numeric_value IS NOT NULL OR text_value IS NOT NULL)))),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    CHECK(numeric_value IS NULL OR (numeric_value>'-Infinity'::float8 AND numeric_value<'Infinity'::float8)),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    CONSTRAINT ck_command_state_outcome CHECK(
  (state IN ('ADMITTED','DISPATCHING','DISPATCHED','ACCEPTED') AND outcome='PENDING' AND terminal_at IS NULL) OR
  (state='SUCCEEDED' AND outcome='SUCCEEDED' AND terminal_at IS NOT NULL) OR
  (state IN ('FAILED','EXPIRED_BEFORE_DISPATCH','CANCELLED') AND outcome='FAILED' AND terminal_at IS NOT NULL) OR
  (state='TIMED_OUT' AND outcome='UNKNOWN' AND terminal_at IS NOT NULL))
);
/* Guard active không đủ cho UNKNOWN; actuator.unresolved_command_id giữ fence sau timeout. */
CREATE UNIQUE INDEX uq_commands_active_actuator ON commands(workspace_id,device_id,stream_key) WHERE state IN ('ADMITTED','DISPATCHING','DISPATCHED','ACCEPTED');
/* Stable action chỉ tạo một command kể cả command đã terminal. */
CREATE UNIQUE INDEX uq_commands_action ON commands(workspace_id,action_execution_id) WHERE action_execution_id IS NOT NULL;
CREATE INDEX ix_commands_history ON commands(workspace_id,device_id,admitted_at DESC,command_id);
ALTER TABLE actuator_states ADD CONSTRAINT fk_actuator_unresolved_command FOREIGN KEY(workspace_id,device_id,stream_key,unresolved_command_id) REFERENCES commands(workspace_id,device_id,stream_key,command_id) DEFERRABLE INITIALLY DEFERRED;
ALTER TABLE action_executions ADD CONSTRAINT fk_action_command FOREIGN KEY(workspace_id,command_id,action_execution_id) REFERENCES commands(workspace_id,command_id,action_execution_id) DEFERRABLE INITIALLY DEFERRED;
-- Bảng command_result_receipts: Kết quả MQTT từng phase của command đã được xác minh theo device/boot/credential.
-- Khóa phase và digest phục vụ nhận trùng, không ghi đè kết quả đã chấp nhận.
CREATE TABLE command_result_receipts (
    -- Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền
    -- của người gọi.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành command_result_receipts_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, command_id, result_phase)
    -- Ràng buộc hiện hành command_result_receipts_workspace_id_command_id_device_id_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, command_id, device_id) REFERENCES commands(workspace_id, command_id, device_id)
    -- Ràng buộc hiện hành command_result_receipts_workspace_id_device_id_boot_id_cre_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, device_id, boot_id, credential_generation) REFERENCES
    -- device_boot_sessions(workspace_id, device_id, boot_id, credential_generation)
    workspace_id uuid NOT NULL,

    -- Identity command ổn định qua retry/result/reconciliation; không tạo command mới chỉ vì mất response.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành command_result_receipts_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, command_id, result_phase)
    -- Ràng buộc hiện hành command_result_receipts_workspace_id_command_id_device_id_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, command_id, device_id) REFERENCES commands(workspace_id, command_id, device_id)
    command_id uuid NOT NULL,

    -- Phase result ACCEPTED/SUCCEEDED/FAILED của command; ACCEPTED không phải kết quả vật lý thành công.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành command_result_receipts_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, command_id, result_phase)
    -- Ràng buộc hiện hành command_result_receipts_result_phase_check: CHECK chỉ chặn khi biểu thức là FALSE;
    -- NULL/UNKNOWN vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((result_phase = ANY (ARRAY['ACCEPTED'::text, 'SUCCEEDED'::text, 'FAILED'::text])))
    result_phase text NOT NULL CHECK(result_phase IN ('ACCEPTED','SUCCEEDED','FAILED')),

    -- Identity thiết bị toàn cục để resolve MQTT và registry; kết hợp workspace_id bảo vệ mọi tham chiếu trong đúng
    -- tenant.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành command_result_receipts_workspace_id_command_id_device_id_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, command_id, device_id) REFERENCES commands(workspace_id, command_id, device_id)
    -- Ràng buộc hiện hành command_result_receipts_workspace_id_device_id_boot_id_cre_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, device_id, boot_id, credential_generation) REFERENCES
    -- device_boot_sessions(workspace_id, device_id, boot_id, credential_generation)
    device_id uuid NOT NULL,

    -- Identity boot của thiết bị theo wire dạng text, không suy UUID; chỉ chấp nhận khi gắn với credential/connection
    -- đã xác minh.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành command_result_receipts_workspace_id_device_id_boot_id_cre_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, device_id, boot_id, credential_generation) REFERENCES
    -- device_boot_sessions(workspace_id, device_id, boot_id, credential_generation)
    boot_id text NOT NULL,

    -- Thế hệ credential MQTT của thiết bị, phân biệt lần cấp mới với credential cũ đã thu hồi.
    -- bigint: số nguyên có dấu 64 bit, phù hợp bộ đếm/generation tăng lâu dài; không tự tăng nếu chưa có cơ chế cấp
    -- giá trị.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành command_result_receipts_workspace_id_device_id_boot_id_cre_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, device_id, boot_id, credential_generation) REFERENCES
    -- device_boot_sessions(workspace_id, device_id, boot_id, credential_generation)
    credential_generation bigint NOT NULL,

    -- SHA-256 32 byte của payload đã chấp nhận, phục vụ dedupe và phát hiện cùng identity nhưng body mâu thuẫn.
    -- bytea: dãy byte nhị phân; tên digest/ciphertext mô tả mục đích, bản thân kiểu không băm hoặc mã hóa dữ liệu.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành command_result_receipts_payload_digest_check: CHECK chỉ chặn khi biểu thức là FALSE;
    -- NULL/UNKNOWN vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((octet_length(payload_digest) = 32))
    payload_digest bytea NOT NULL CHECK(octet_length(payload_digest)=32),

    -- Thời điểm server nhận gói dữ liệu/kết quả; phân biệt với observed_at do thiết bị hoặc nguồn sự kiện cung cấp.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    received_at timestamptz NOT NULL,

    -- Snapshot result đã xác thực và redact, dùng dedupe/đối soát; không thay quyền hiện hành khi hiển thị.
    -- jsonb: tài liệu JSON lưu dạng nhị phân; kiểm object/scalar không thay validation đầy đủ cấu trúc và tham chiếu
    -- nghiệp vụ.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    result_snapshot jsonb NOT NULL,

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    PRIMARY KEY(workspace_id,command_id,result_phase),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,command_id,device_id) REFERENCES commands(workspace_id,command_id,device_id),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,device_id,boot_id,credential_generation) REFERENCES device_boot_sessions(workspace_id,device_id,boot_id,credential_generation)
);
-- Bảng command_evidence: Bằng chứng quan sát muộn hoặc mâu thuẫn của command. Ghi bổ sung vào timeline thay vì sửa
-- terminal outcome hoặc tự phát lại thao tác vật lý.
CREATE TABLE command_evidence (
    -- Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền
    -- của người gọi.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành command_evidence_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì uniqueness
    -- áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, command_evidence_id)
    -- Ràng buộc hiện hành command_evidence_workspace_id_command_id_command_evidence_i_key: không trùng tổ hợp giá trị
    -- được nêu; các cột riêng lẻ vẫn có thể lặp khi khóa có nhiều cột.
    -- UNIQUE (workspace_id, command_id, command_evidence_id)
    -- Ràng buộc hiện hành command_evidence_workspace_id_command_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ hợp có
    -- workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, command_id) REFERENCES commands(workspace_id, command_id)
    workspace_id uuid NOT NULL,

    -- Identity một bằng chứng command bổ sung để liên kết resolution và timeline quan sát.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành command_evidence_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì uniqueness
    -- áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, command_evidence_id)
    -- Ràng buộc hiện hành command_evidence_workspace_id_command_id_command_evidence_i_key: không trùng tổ hợp giá trị
    -- được nêu; các cột riêng lẻ vẫn có thể lặp khi khóa có nhiều cột.
    -- UNIQUE (workspace_id, command_id, command_evidence_id)
    command_evidence_id uuid NOT NULL,

    -- Identity command ổn định qua retry/result/reconciliation; không tạo command mới chỉ vì mất response.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành command_evidence_workspace_id_command_id_command_evidence_i_key: không trùng tổ hợp giá trị
    -- được nêu; các cột riêng lẻ vẫn có thể lặp khi khóa có nhiều cột.
    -- UNIQUE (workspace_id, command_id, command_evidence_id)
    -- Ràng buộc hiện hành command_evidence_workspace_id_command_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ hợp có
    -- workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, command_id) REFERENCES commands(workspace_id, command_id)
    command_id uuid NOT NULL,

    -- Loại bằng chứng command LATE_RESULT/CONFLICTING_RESULT/DEVICE_OBSERVATION để không nhầm quan sát với terminal
    -- truth.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành command_evidence_evidence_type_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN
    -- vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((evidence_type = ANY (ARRAY['LATE_RESULT'::text, 'CONFLICTING_RESULT'::text,
    -- 'DEVICE_OBSERVATION'::text])))
    evidence_type text NOT NULL CHECK(evidence_type IN ('LATE_RESULT','CONFLICTING_RESULT','DEVICE_OBSERVATION')),

    -- Thời điểm server nhận gói dữ liệu/kết quả; phân biệt với observed_at do thiết bị hoặc nguồn sự kiện cung cấp.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    received_at timestamptz NOT NULL,

    -- SHA-256 32 byte của payload đã chấp nhận, phục vụ dedupe và phát hiện cùng identity nhưng body mâu thuẫn.
    -- bytea: dãy byte nhị phân; tên digest/ciphertext mô tả mục đích, bản thân kiểu không băm hoặc mã hóa dữ liệu.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành command_evidence_payload_digest_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN
    -- vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((octet_length(payload_digest) = 32))
    payload_digest bytea NOT NULL CHECK(octet_length(payload_digest)=32),

    -- Payload quan sát đã được producer loại trường nhạy cảm, dùng audit/đối soát; SQL JSON type không tự làm
    -- redaction.
    -- jsonb: tài liệu JSON lưu dạng nhị phân; kiểm object/scalar không thay validation đầy đủ cấu trúc và tham chiếu
    -- nghiệp vụ.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    sanitized_payload jsonb NOT NULL,

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    PRIMARY KEY(workspace_id,command_evidence_id),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    UNIQUE(workspace_id,command_id,command_evidence_id),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,command_id) REFERENCES commands
);
/* Timeline bằng chứng theo tenant/command và thời điểm quan sát. */
CREATE INDEX ix_command_evidence_timeline ON command_evidence(workspace_id,command_id,received_at,command_evidence_id);
-- Bảng command_resolutions: Trục xử lý/đối soát command UNKNOWN: ghi nhận ACK thủ công hoặc bằng chứng thiết bị
-- muộn. Không đồng nhất resolution với kết quả thực thi ban đầu.
CREATE TABLE command_resolutions (
    -- Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền
    -- của người gọi.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành command_resolutions_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, command_id)
    -- Ràng buộc hiện hành command_resolutions_workspace_id_command_id_device_evidenc_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, command_id, device_evidence_id) REFERENCES command_evidence(workspace_id, command_id,
    -- command_evidence_id)
    -- Ràng buộc hiện hành command_resolutions_workspace_id_command_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ hợp có
    -- workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, command_id) REFERENCES commands(workspace_id, command_id)
    -- Ràng buộc hiện hành command_resolutions_workspace_id_resolved_by_user_id_fkey: khóa ngoại giữ đúng bản ghi cha;
    -- tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, resolved_by_user_id) REFERENCES memberships(workspace_id, user_id)
    workspace_id uuid NOT NULL,

    -- Identity command ổn định qua retry/result/reconciliation; không tạo command mới chỉ vì mất response.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành command_resolutions_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, command_id)
    -- Ràng buộc hiện hành command_resolutions_workspace_id_command_id_device_evidenc_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, command_id, device_evidence_id) REFERENCES command_evidence(workspace_id, command_id,
    -- command_evidence_id)
    -- Ràng buộc hiện hành command_resolutions_workspace_id_command_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ hợp có
    -- workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, command_id) REFERENCES commands(workspace_id, command_id)
    command_id uuid NOT NULL,

    -- Tình trạng đối soát UNKNOWN: UNRESOLVED/ACKNOWLEDGED_UNKNOWN/DEVICE_CONFIRMED_LATE, độc lập command outcome.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành command_resolutions_resolution_status_check: CHECK chỉ chặn khi biểu thức là FALSE;
    -- NULL/UNKNOWN vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((resolution_status = ANY (ARRAY['UNRESOLVED'::text, 'ACKNOWLEDGED_UNKNOWN'::text,
    -- 'DEVICE_CONFIRMED_LATE'::text])))
    resolution_status text NOT NULL CHECK(resolution_status IN ('UNRESOLVED','ACKNOWLEDGED_UNKNOWN','DEVICE_CONFIRMED_LATE')),

    -- Thành viên thực hiện đối soát hoặc xác nhận thủ công; NULL khi chưa có người xử lý theo nhánh resolution.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    -- Ràng buộc hiện hành command_resolutions_workspace_id_resolved_by_user_id_fkey: khóa ngoại giữ đúng bản ghi cha;
    -- tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành. FK MATCH SIMPLE mặc định
    -- bỏ kiểm khi có thành phần NULL; CHECK shape riêng vẫn phải đạt.
    -- FOREIGN KEY (workspace_id, resolved_by_user_id) REFERENCES memberships(workspace_id, user_id)
    resolved_by_user_id uuid,

    -- Mốc ghi nhận resolution ACK/late device proof; không viết lại terminal_at hoặc outcome của command gốc.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    resolved_at timestamptz,

    -- Quan sát do người dùng khai lúc ACK UNKNOWN; không được ghi đè reported value từ thiết bị hoặc coi là device
    -- proof.
    -- jsonb: tài liệu JSON lưu dạng nhị phân; kiểm object/scalar không thay validation đầy đủ cấu trúc và tham chiếu
    -- nghiệp vụ.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    manual_observation jsonb,

    -- Bằng chứng thuộc chính command được dùng cho DEVICE_CONFIRMED_LATE; không nhận evidence của command khác.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    -- Ràng buộc hiện hành command_resolutions_workspace_id_command_id_device_evidenc_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành. FK MATCH SIMPLE mặc
    -- định bỏ kiểm khi có thành phần NULL; CHECK shape riêng vẫn phải đạt.
    -- FOREIGN KEY (workspace_id, command_id, device_evidence_id) REFERENCES command_evidence(workspace_id, command_id,
    -- command_evidence_id)
    device_evidence_id uuid,

    -- Mã nguyên nhân ổn định để giải thích kết quả/transition; phải là nội dung an toàn, không chứa raw lỗi/secret.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    reason_code text,

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    PRIMARY KEY(workspace_id,command_id),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,command_id) REFERENCES commands,

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,resolved_by_user_id) REFERENCES memberships,

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,command_id,device_evidence_id) REFERENCES command_evidence(workspace_id,command_id,command_evidence_id)
);
