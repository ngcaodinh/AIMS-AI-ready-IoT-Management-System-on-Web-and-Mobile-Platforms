/* Bản chú thích để đọc: ràng buộc hiện hành lấy từ manifest sau mọi forward migration.
 * Runner thực thi byte bất biến trong applied_sql và so token SQL với bản này; không sửa ledger.
 */
/* Template, thiết bị và telemetry dùng chung database; phụ thuộc IAM0001.
 * Chỉ DDL trên baseline mới; FK giữ lịch sử, không backfill/xóa auth lab.
 */
-- Bảng templates: Gốc quản lý template thiết bị và metadata bản nháp như tên/model. Không dùng bản nháp làm schema
-- runtime; thiết bị phải pin vào một template_versions đã công bố.
CREATE TABLE templates (
    -- Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền
    -- của người gọi.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành templates_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì uniqueness áp dụng
    -- cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, template_id)
    -- Ràng buộc hiện hành templates_workspace_id_created_by_user_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ hợp có
    -- workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, created_by_user_id) REFERENCES memberships(workspace_id, user_id)
    -- Ràng buộc hiện hành templates_workspace_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ hợp có workspace_id giữ
    -- quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id) REFERENCES workspaces(workspace_id)
    workspace_id uuid NOT NULL REFERENCES workspaces,

    -- Identity gốc template trong workspace, dùng nhóm các version và nội dung draft; không là identity version đã
    -- pin.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành templates_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì uniqueness áp dụng
    -- cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, template_id)
    template_id uuid NOT NULL,

    -- Tên hiển thị do người dùng đặt cho tài nguyên; không dùng làm identity, quyền hoặc khóa chống lặp.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành templates_name_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên phải
    -- phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((btrim(name) <> ''::text))
    name text NOT NULL CHECK(btrim(name)<>''),

    -- Mã model phần cứng/template theo registry đã duyệt, dùng kiểm tương thích; không suy model từ tên hiển thị.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành templates_model_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên phải
    -- phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((btrim(model) <> ''::text))
    model text NOT NULL CHECK(btrim(model)<>''),

    -- Mô tả bổ sung để người dùng hiểu tài nguyên; NULL nghĩa chưa cung cấp mô tả, không mang authority vận hành.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    description text,

    -- Trạng thái vòng đời quản lý tài nguyên, tách khỏi presence hoặc tiến độ của job đang chạy.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- DEFAULT 'DRAFT'::text: giá trị dùng khi INSERT bỏ qua cột; không thay NULL được truyền tường minh và không tự áp
    -- lại khi UPDATE.
    -- Ràng buộc hiện hành templates_lifecycle_status_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn
    -- qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((lifecycle_status = ANY (ARRAY['DRAFT'::text, 'PUBLISHED'::text, 'ARCHIVED'::text])))
    lifecycle_status text NOT NULL DEFAULT 'DRAFT' CHECK(lifecycle_status IN ('DRAFT','PUBLISHED','ARCHIVED')),

    -- Tài khoản tạo tài nguyên; giữ provenance và làm anchor quota hoặc FK thành viên theo loại tài nguyên.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành templates_workspace_id_created_by_user_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ hợp có
    -- workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, created_by_user_id) REFERENCES memberships(workspace_id, user_id)
    created_by_user_id uuid NOT NULL,

    -- Phiên bản chỉnh sửa bản ghi dùng cho CAS/If-Match hoặc đối soát; bên ghi chịu trách nhiệm cập nhật theo đúng
    -- transaction contract.
    -- bigint: số nguyên có dấu 64 bit, phù hợp bộ đếm/generation tăng lâu dài; không tự tăng nếu chưa có cơ chế cấp
    -- giá trị.
    -- NOT NULL: bắt buộc có giá trị.
    -- DEFAULT 1: giá trị dùng khi INSERT bỏ qua cột; không thay NULL được truyền tường minh và không tự áp lại khi
    -- UPDATE.
    -- Ràng buộc hiện hành templates_revision_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên
    -- phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((revision > 0))
    revision bigint NOT NULL DEFAULT 1 CHECK(revision>0),

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
    PRIMARY KEY(workspace_id,template_id),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,created_by_user_id) REFERENCES memberships
);
/* Draft và snapshot có grain riêng; không sửa snapshot khi draft đổi. */
-- Bảng template_draft_streams: Các kênh dữ liệu đang chỉnh sửa của một template, gồm datatype, chiều đọc/ghi và
-- giới hạn. Cho phép editor sửa draft trước khi tạo snapshot phiên bản.
CREATE TABLE template_draft_streams (
    -- Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền
    -- của người gọi.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành template_draft_streams_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, template_id, stream_key)
    -- Ràng buộc hiện hành template_draft_streams_workspace_id_template_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ
    -- hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, template_id) REFERENCES templates(workspace_id, template_id)
    workspace_id uuid NOT NULL,

    -- Identity gốc template trong workspace, dùng nhóm các version và nội dung draft; không là identity version đã
    -- pin.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành template_draft_streams_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, template_id, stream_key)
    -- Ràng buộc hiện hành template_draft_streams_workspace_id_template_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ
    -- hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, template_id) REFERENCES templates(workspace_id, template_id)
    template_id uuid NOT NULL,

    -- Khóa kỹ thuật ổn định của kênh trong template/version; không dùng nhãn hiển thị thay khóa schema.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành template_draft_streams_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, template_id, stream_key)
    -- Ràng buộc hiện hành template_draft_streams_stream_key_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN
    -- vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((btrim(stream_key) <> ''::text))
    stream_key text NOT NULL CHECK(btrim(stream_key)<>''),

    -- Nhãn hiển thị của kênh dữ liệu; stream_key vẫn là khóa kỹ thuật ổn định khi nhãn thay đổi.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    display_name text NOT NULL,

    -- Kiểu dữ liệu NUMBER/BOOLEAN/STRING/ENUM của definition; validator kiểm literal và giới hạn theo kiểu này.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành ck_draft_stream_bounds: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên
    -- phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((((min_value IS NULL) OR ((data_type = 'NUMBER'::text) AND (min_value > '-Infinity'::double precision)
    -- AND (min_value < 'Infinity'::double precision))) AND ((max_value IS NULL) OR ((data_type = 'NUMBER'::text) AND
    -- (max_value > '-Infinity'::double precision) AND (max_value < 'Infinity'::double precision))) AND ((min_value IS
    -- NULL) OR (max_value IS NULL) OR (min_value <= max_value)) AND ((string_max_length IS NULL) OR (data_type =
    -- 'STRING'::text))))
    -- Ràng buộc hiện hành template_draft_streams_data_type_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN
    -- vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((data_type = ANY (ARRAY['NUMBER'::text, 'BOOLEAN'::text, 'STRING'::text, 'ENUM'::text])))
    data_type text NOT NULL CHECK(data_type IN ('NUMBER','BOOLEAN','STRING','ENUM')),

    -- Chiều sử dụng kênh READ/WRITE/READ_WRITE; tồn tại stream không đồng nghĩa có capability điều khiển.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành template_draft_streams_direction_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN
    -- vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((direction = ANY (ARRAY['READ'::text, 'WRITE'::text, 'READ_WRITE'::text])))
    direction text NOT NULL CHECK(direction IN ('READ','WRITE','READ_WRITE')),

    -- Đơn vị đo hiển thị của kênh, ví dụ đơn vị cảm biến; NULL khi đại lượng không có đơn vị theo schema.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    unit text,

    -- Cận dưới cho giá trị NUMBER hữu hạn; NULL nghĩa không khai cận dưới, không mặc định bằng 0.
    -- double precision: số thực dấu phẩy động 64 bit, có sai số biểu diễn; kiểm finite/range theo CHECK và validator.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    -- Ràng buộc hiện hành ck_draft_stream_bounds: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên
    -- phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((((min_value IS NULL) OR ((data_type = 'NUMBER'::text) AND (min_value > '-Infinity'::double precision)
    -- AND (min_value < 'Infinity'::double precision))) AND ((max_value IS NULL) OR ((data_type = 'NUMBER'::text) AND
    -- (max_value > '-Infinity'::double precision) AND (max_value < 'Infinity'::double precision))) AND ((min_value IS
    -- NULL) OR (max_value IS NULL) OR (min_value <= max_value)) AND ((string_max_length IS NULL) OR (data_type =
    -- 'STRING'::text))))
    min_value double precision,

    -- Cận trên cho giá trị NUMBER hữu hạn; NULL nghĩa không khai cận trên, không tự đặt giới hạn phần cứng.
    -- double precision: số thực dấu phẩy động 64 bit, có sai số biểu diễn; kiểm finite/range theo CHECK và validator.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    -- Ràng buộc hiện hành ck_draft_stream_bounds: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên
    -- phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((((min_value IS NULL) OR ((data_type = 'NUMBER'::text) AND (min_value > '-Infinity'::double precision)
    -- AND (min_value < 'Infinity'::double precision))) AND ((max_value IS NULL) OR ((data_type = 'NUMBER'::text) AND
    -- (max_value > '-Infinity'::double precision) AND (max_value < 'Infinity'::double precision))) AND ((min_value IS
    -- NULL) OR (max_value IS NULL) OR (min_value <= max_value)) AND ((string_max_length IS NULL) OR (data_type =
    -- 'STRING'::text))))
    max_value double precision,

    -- Độ dài tối đa của STRING tính bằng ký tự theo validation hiện hành; NULL khi schema không khai giới hạn này.
    -- integer: số nguyên có dấu 32 bit; CHECK giới hạn miền nghiệp vụ thay vì chỉ dựa phạm vi kiểu.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    -- Ràng buộc hiện hành ck_draft_stream_bounds: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên
    -- phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((((min_value IS NULL) OR ((data_type = 'NUMBER'::text) AND (min_value > '-Infinity'::double precision)
    -- AND (min_value < 'Infinity'::double precision))) AND ((max_value IS NULL) OR ((data_type = 'NUMBER'::text) AND
    -- (max_value > '-Infinity'::double precision) AND (max_value < 'Infinity'::double precision))) AND ((min_value IS
    -- NULL) OR (max_value IS NULL) OR (min_value <= max_value)) AND ((string_max_length IS NULL) OR (data_type =
    -- 'STRING'::text))))
    -- Ràng buộc hiện hành template_draft_streams_string_max_length_check: CHECK chỉ chặn khi biểu thức là FALSE;
    -- NULL/UNKNOWN vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((string_max_length > 0))
    string_max_length integer CHECK(string_max_length>0),

    -- Phiên bản chỉnh sửa bản ghi dùng cho CAS/If-Match hoặc đối soát; bên ghi chịu trách nhiệm cập nhật theo đúng
    -- transaction contract.
    -- bigint: số nguyên có dấu 64 bit, phù hợp bộ đếm/generation tăng lâu dài; không tự tăng nếu chưa có cơ chế cấp
    -- giá trị.
    -- NOT NULL: bắt buộc có giá trị.
    -- DEFAULT 1: giá trị dùng khi INSERT bỏ qua cột; không thay NULL được truyền tường minh và không tự áp lại khi
    -- UPDATE.
    -- Ràng buộc hiện hành template_draft_streams_revision_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN
    -- vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((revision > 0))
    revision bigint NOT NULL DEFAULT 1 CHECK(revision>0),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    PRIMARY KEY(workspace_id,template_id,stream_key),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,template_id) REFERENCES templates,

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    CONSTRAINT ck_draft_stream_bounds CHECK(
  (min_value IS NULL OR (data_type='NUMBER' AND min_value>'-Infinity'::float8 AND min_value<'Infinity'::float8)) AND
  (max_value IS NULL OR (data_type='NUMBER' AND max_value>'-Infinity'::float8 AND max_value<'Infinity'::float8)) AND
  (min_value IS NULL OR max_value IS NULL OR min_value<=max_value) AND (string_max_length IS NULL OR data_type='STRING'))
);
/* ENUM là tập có khóa, không mảng ID; enum_value là literal JSON scalar giữ NUMBER/STRING. */
-- Bảng template_draft_enum_values: Tập literal được phép của một kênh ENUM trong bản nháp. Tách thành relation để
-- kiểm trùng giá trị, không lưu danh sách giá trị dạng chuỗi CSV.
CREATE TABLE template_draft_enum_values (
    -- Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền
    -- của người gọi.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành template_draft_enum_values_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, template_id, stream_key, enum_value)
    -- Ràng buộc hiện hành template_draft_enum_values_workspace_id_template_id_stream_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, template_id, stream_key) REFERENCES template_draft_streams(workspace_id, template_id,
    -- stream_key)
    workspace_id uuid NOT NULL,

    -- Identity gốc template trong workspace, dùng nhóm các version và nội dung draft; không là identity version đã
    -- pin.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành template_draft_enum_values_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, template_id, stream_key, enum_value)
    -- Ràng buộc hiện hành template_draft_enum_values_workspace_id_template_id_stream_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, template_id, stream_key) REFERENCES template_draft_streams(workspace_id, template_id,
    -- stream_key)
    template_id uuid NOT NULL,

    -- Khóa kỹ thuật ổn định của kênh trong template/version; không dùng nhãn hiển thị thay khóa schema.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành template_draft_enum_values_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, template_id, stream_key, enum_value)
    -- Ràng buộc hiện hành template_draft_enum_values_workspace_id_template_id_stream_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, template_id, stream_key) REFERENCES template_draft_streams(workspace_id, template_id,
    -- stream_key)
    stream_key text NOT NULL,

    -- Một literal JSON number/string được phép của kênh ENUM; validator còn phải kiểm bộ giá trị và type theo
    -- contract.
    -- jsonb: tài liệu JSON lưu dạng nhị phân; kiểm object/scalar không thay validation đầy đủ cấu trúc và tham chiếu
    -- nghiệp vụ.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành template_draft_enum_values_enum_value_check: CHECK chỉ chặn khi biểu thức là FALSE;
    -- NULL/UNKNOWN vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((jsonb_typeof(enum_value) = ANY (ARRAY['string'::text, 'number'::text])))
    -- Ràng buộc hiện hành template_draft_enum_values_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, template_id, stream_key, enum_value)
    enum_value jsonb NOT NULL,

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    PRIMARY KEY(workspace_id,template_id,stream_key,enum_value),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,template_id,stream_key) REFERENCES template_draft_streams,

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    CHECK(jsonb_typeof(enum_value) IN ('string','number'))
);
/* Safe value thuộc capability SET_VALUE; validator đối chiếu type/range của stream trước publish. */
-- Bảng template_draft_capabilities: Capability điều khiển và safeValue của từng kênh bản nháp. Mô tả khả năng
-- SET_VALUE để validator kiểm type/range trước khi publish.
CREATE TABLE template_draft_capabilities (
    -- Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền
    -- của người gọi.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành template_draft_capabilities_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, template_id, stream_key, command_type)
    -- Ràng buộc hiện hành template_draft_capabilities_workspace_id_template_id_strea_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, template_id, stream_key) REFERENCES template_draft_streams(workspace_id, template_id,
    -- stream_key)
    workspace_id uuid NOT NULL,

    -- Identity gốc template trong workspace, dùng nhóm các version và nội dung draft; không là identity version đã
    -- pin.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành template_draft_capabilities_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, template_id, stream_key, command_type)
    -- Ràng buộc hiện hành template_draft_capabilities_workspace_id_template_id_strea_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, template_id, stream_key) REFERENCES template_draft_streams(workspace_id, template_id,
    -- stream_key)
    template_id uuid NOT NULL,

    -- Khóa kỹ thuật ổn định của kênh trong template/version; không dùng nhãn hiển thị thay khóa schema.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành template_draft_capabilities_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, template_id, stream_key, command_type)
    -- Ràng buộc hiện hành template_draft_capabilities_workspace_id_template_id_strea_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, template_id, stream_key) REFERENCES template_draft_streams(workspace_id, template_id,
    -- stream_key)
    stream_key text NOT NULL,

    -- Capability lệnh được template công bố, hiện chỉ SET_VALUE; không cho thực thi script hoặc lệnh tùy ý.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành template_draft_capabilities_command_type_check: CHECK chỉ chặn khi biểu thức là FALSE;
    -- NULL/UNKNOWN vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((command_type = 'SET_VALUE'::text))
    -- Ràng buộc hiện hành template_draft_capabilities_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, template_id, stream_key, command_type)
    command_type text NOT NULL CHECK(command_type='SET_VALUE'),

    -- Literal giá trị an toàn của capability, phải đúng datatype/range/ENUM; đây là cấu hình, không tự gửi lệnh tới
    -- thiết bị.
    -- jsonb: tài liệu JSON lưu dạng nhị phân; kiểm object/scalar không thay validation đầy đủ cấu trúc và tham chiếu
    -- nghiệp vụ.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành template_draft_capabilities_safe_value_check: CHECK chỉ chặn khi biểu thức là FALSE;
    -- NULL/UNKNOWN vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((jsonb_typeof(safe_value) = ANY (ARRAY['number'::text, 'boolean'::text, 'string'::text])))
    safe_value jsonb NOT NULL CHECK(jsonb_typeof(safe_value) IN ('number','boolean','string')),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    PRIMARY KEY(workspace_id,template_id,stream_key,command_type),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,template_id,stream_key) REFERENCES template_draft_streams
);
/* Metadata model/name là snapshot tại publish, không live-copy metadata root. */
-- Bảng template_versions: Ảnh chụp schema và metadata template tại mỗi lần publish. Là phiên bản được thiết bị
-- tham chiếu cố định để thay đổi draft không làm lệch schema của thiết bị đang chạy.
CREATE TABLE template_versions (
    -- Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền
    -- của người gọi.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành template_versions_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì uniqueness
    -- áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, template_version_id)
    -- Ràng buộc hiện hành template_versions_workspace_id_published_by_user_id_fkey: khóa ngoại giữ đúng bản ghi cha;
    -- tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, published_by_user_id) REFERENCES memberships(workspace_id, user_id)
    -- Ràng buộc hiện hành template_versions_workspace_id_template_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ hợp có
    -- workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, template_id) REFERENCES templates(workspace_id, template_id)
    -- Ràng buộc hiện hành template_versions_workspace_id_template_id_version_number_key: không trùng tổ hợp giá trị
    -- được nêu; các cột riêng lẻ vẫn có thể lặp khi khóa có nhiều cột.
    -- UNIQUE (workspace_id, template_id, version_number)
    workspace_id uuid NOT NULL,

    -- Identity snapshot template cụ thể, dùng pin schema và kiểm đúng definition trong workspace.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành template_versions_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì uniqueness
    -- áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, template_version_id)
    template_version_id uuid NOT NULL,

    -- Identity gốc template trong workspace, dùng nhóm các version và nội dung draft; không là identity version đã
    -- pin.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành template_versions_workspace_id_template_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ hợp có
    -- workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, template_id) REFERENCES templates(workspace_id, template_id)
    -- Ràng buộc hiện hành template_versions_workspace_id_template_id_version_number_key: không trùng tổ hợp giá trị
    -- được nêu; các cột riêng lẻ vẫn có thể lặp khi khóa có nhiều cột.
    -- UNIQUE (workspace_id, template_id, version_number)
    template_id uuid NOT NULL,

    -- Số phiên bản publish tăng trong cùng template/rule, bắt đầu 1; khác revision chỉnh sửa metadata.
    -- integer: số nguyên có dấu 32 bit; CHECK giới hạn miền nghiệp vụ thay vì chỉ dựa phạm vi kiểu.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành template_versions_version_number_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN
    -- vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((version_number > 0))
    -- Ràng buộc hiện hành template_versions_workspace_id_template_id_version_number_key: không trùng tổ hợp giá trị
    -- được nêu; các cột riêng lẻ vẫn có thể lặp khi khóa có nhiều cột.
    -- UNIQUE (workspace_id, template_id, version_number)
    version_number integer NOT NULL CHECK(version_number>0),

    -- Tên hiển thị do người dùng đặt cho tài nguyên; không dùng làm identity, quyền hoặc khóa chống lặp.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    name text NOT NULL,

    -- Mã model phần cứng/template theo registry đã duyệt, dùng kiểm tương thích; không suy model từ tên hiển thị.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    model text NOT NULL,

    -- Thời điểm tạo snapshot đã công bố; không thay đổi theo các lần sửa draft sau đó.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- NOT NULL: bắt buộc có giá trị.
    -- DEFAULT transaction_timestamp(): thời điểm bắt đầu transaction, giữ nguyên trong transaction; không phải đồng hồ
    -- thay đổi theo từng statement.
    published_at timestamptz NOT NULL DEFAULT transaction_timestamp(),

    -- Thành viên thực hiện publish template version, giữ provenance của snapshot đã công bố.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành template_versions_workspace_id_published_by_user_id_fkey: khóa ngoại giữ đúng bản ghi cha;
    -- tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, published_by_user_id) REFERENCES memberships(workspace_id, user_id)
    published_by_user_id uuid NOT NULL,

    -- SHA-256 32 byte của nội dung snapshot đã publish, dùng nhận diện/đối chiếu định nghĩa thay vì hash metadata
    -- draft hiện tại.
    -- bytea: dãy byte nhị phân; tên digest/ciphertext mô tả mục đích, bản thân kiểu không băm hoặc mã hóa dữ liệu.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành template_versions_content_digest_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN
    -- vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((octet_length(content_digest) = 32))
    content_digest bytea NOT NULL CHECK(octet_length(content_digest)=32),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    PRIMARY KEY(workspace_id,template_version_id),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    UNIQUE(workspace_id,template_id,version_number),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,template_id) REFERENCES templates,

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,published_by_user_id) REFERENCES memberships
);
-- Bảng datastream_definitions: Định nghĩa từng kênh trong template version đã công bố. Là nguồn datatype, mode,
-- đơn vị và giới hạn để kiểm telemetry, binding và giá trị điều khiển theo đúng pin của thiết bị.
CREATE TABLE datastream_definitions (
    -- Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền
    -- của người gọi.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành datastream_definitions_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, template_version_id, stream_key)
    -- Ràng buộc hiện hành datastream_definitions_workspace_id_template_version_id_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, template_version_id) REFERENCES template_versions(workspace_id, template_version_id)
    workspace_id uuid NOT NULL,

    -- Identity snapshot template cụ thể, dùng pin schema và kiểm đúng definition trong workspace.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành datastream_definitions_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, template_version_id, stream_key)
    -- Ràng buộc hiện hành datastream_definitions_workspace_id_template_version_id_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, template_version_id) REFERENCES template_versions(workspace_id, template_version_id)
    template_version_id uuid NOT NULL,

    -- Khóa kỹ thuật ổn định của kênh trong template/version; không dùng nhãn hiển thị thay khóa schema.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành datastream_definitions_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, template_version_id, stream_key)
    -- Ràng buộc hiện hành datastream_definitions_stream_key_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN
    -- vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((btrim(stream_key) <> ''::text))
    stream_key text NOT NULL CHECK(btrim(stream_key)<>''),

    -- Nhãn hiển thị của kênh dữ liệu; stream_key vẫn là khóa kỹ thuật ổn định khi nhãn thay đổi.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    display_name text NOT NULL,

    -- Kiểu dữ liệu NUMBER/BOOLEAN/STRING/ENUM của definition; validator kiểm literal và giới hạn theo kiểu này.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành ck_datastream_bounds: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên phải
    -- phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((((min_value IS NULL) OR ((data_type = 'NUMBER'::text) AND (min_value > '-Infinity'::double precision)
    -- AND (min_value < 'Infinity'::double precision))) AND ((max_value IS NULL) OR ((data_type = 'NUMBER'::text) AND
    -- (max_value > '-Infinity'::double precision) AND (max_value < 'Infinity'::double precision))) AND ((min_value IS
    -- NULL) OR (max_value IS NULL) OR (min_value <= max_value)) AND ((string_max_length IS NULL) OR (data_type =
    -- 'STRING'::text))))
    -- Ràng buộc hiện hành datastream_definitions_data_type_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN
    -- vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((data_type = ANY (ARRAY['NUMBER'::text, 'BOOLEAN'::text, 'STRING'::text, 'ENUM'::text])))
    data_type text NOT NULL CHECK(data_type IN ('NUMBER','BOOLEAN','STRING','ENUM')),

    -- Chiều sử dụng kênh READ/WRITE/READ_WRITE; tồn tại stream không đồng nghĩa có capability điều khiển.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành datastream_definitions_direction_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN
    -- vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((direction = ANY (ARRAY['READ'::text, 'WRITE'::text, 'READ_WRITE'::text])))
    direction text NOT NULL CHECK(direction IN ('READ','WRITE','READ_WRITE')),

    -- Đơn vị đo hiển thị của kênh, ví dụ đơn vị cảm biến; NULL khi đại lượng không có đơn vị theo schema.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    unit text,

    -- Cận dưới cho giá trị NUMBER hữu hạn; NULL nghĩa không khai cận dưới, không mặc định bằng 0.
    -- double precision: số thực dấu phẩy động 64 bit, có sai số biểu diễn; kiểm finite/range theo CHECK và validator.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    -- Ràng buộc hiện hành ck_datastream_bounds: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên phải
    -- phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((((min_value IS NULL) OR ((data_type = 'NUMBER'::text) AND (min_value > '-Infinity'::double precision)
    -- AND (min_value < 'Infinity'::double precision))) AND ((max_value IS NULL) OR ((data_type = 'NUMBER'::text) AND
    -- (max_value > '-Infinity'::double precision) AND (max_value < 'Infinity'::double precision))) AND ((min_value IS
    -- NULL) OR (max_value IS NULL) OR (min_value <= max_value)) AND ((string_max_length IS NULL) OR (data_type =
    -- 'STRING'::text))))
    min_value double precision,

    -- Cận trên cho giá trị NUMBER hữu hạn; NULL nghĩa không khai cận trên, không tự đặt giới hạn phần cứng.
    -- double precision: số thực dấu phẩy động 64 bit, có sai số biểu diễn; kiểm finite/range theo CHECK và validator.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    -- Ràng buộc hiện hành ck_datastream_bounds: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên phải
    -- phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((((min_value IS NULL) OR ((data_type = 'NUMBER'::text) AND (min_value > '-Infinity'::double precision)
    -- AND (min_value < 'Infinity'::double precision))) AND ((max_value IS NULL) OR ((data_type = 'NUMBER'::text) AND
    -- (max_value > '-Infinity'::double precision) AND (max_value < 'Infinity'::double precision))) AND ((min_value IS
    -- NULL) OR (max_value IS NULL) OR (min_value <= max_value)) AND ((string_max_length IS NULL) OR (data_type =
    -- 'STRING'::text))))
    max_value double precision,

    -- Độ dài tối đa của STRING tính bằng ký tự theo validation hiện hành; NULL khi schema không khai giới hạn này.
    -- integer: số nguyên có dấu 32 bit; CHECK giới hạn miền nghiệp vụ thay vì chỉ dựa phạm vi kiểu.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    -- Ràng buộc hiện hành ck_datastream_bounds: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên phải
    -- phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((((min_value IS NULL) OR ((data_type = 'NUMBER'::text) AND (min_value > '-Infinity'::double precision)
    -- AND (min_value < 'Infinity'::double precision))) AND ((max_value IS NULL) OR ((data_type = 'NUMBER'::text) AND
    -- (max_value > '-Infinity'::double precision) AND (max_value < 'Infinity'::double precision))) AND ((min_value IS
    -- NULL) OR (max_value IS NULL) OR (min_value <= max_value)) AND ((string_max_length IS NULL) OR (data_type =
    -- 'STRING'::text))))
    -- Ràng buộc hiện hành datastream_definitions_string_max_length_check: CHECK chỉ chặn khi biểu thức là FALSE;
    -- NULL/UNKNOWN vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((string_max_length > 0))
    string_max_length integer CHECK(string_max_length>0),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    PRIMARY KEY(workspace_id,template_version_id,stream_key),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,template_version_id) REFERENCES template_versions,

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    CONSTRAINT ck_datastream_bounds CHECK(
  (min_value IS NULL OR (data_type='NUMBER' AND min_value>'-Infinity'::float8 AND min_value<'Infinity'::float8)) AND
  (max_value IS NULL OR (data_type='NUMBER' AND max_value>'-Infinity'::float8 AND max_value<'Infinity'::float8)) AND
  (min_value IS NULL OR max_value IS NULL OR min_value<=max_value) AND (string_max_length IS NULL OR data_type='STRING'))
);
-- Bảng datastream_enum_values: Các literal ENUM thuộc một kênh của template version đã công bố. Giữ tập giá trị
-- theo phiên bản để dữ liệu cũ không phụ thuộc draft hiện hành.
CREATE TABLE datastream_enum_values (
    -- Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền
    -- của người gọi.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành datastream_enum_values_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, template_version_id, stream_key, enum_value)
    -- Ràng buộc hiện hành datastream_enum_values_workspace_id_template_version_id_st_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, template_version_id, stream_key) REFERENCES datastream_definitions(workspace_id,
    -- template_version_id, stream_key)
    workspace_id uuid NOT NULL,

    -- Identity snapshot template cụ thể, dùng pin schema và kiểm đúng definition trong workspace.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành datastream_enum_values_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, template_version_id, stream_key, enum_value)
    -- Ràng buộc hiện hành datastream_enum_values_workspace_id_template_version_id_st_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, template_version_id, stream_key) REFERENCES datastream_definitions(workspace_id,
    -- template_version_id, stream_key)
    template_version_id uuid NOT NULL,

    -- Khóa kỹ thuật ổn định của kênh trong template/version; không dùng nhãn hiển thị thay khóa schema.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành datastream_enum_values_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, template_version_id, stream_key, enum_value)
    -- Ràng buộc hiện hành datastream_enum_values_workspace_id_template_version_id_st_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, template_version_id, stream_key) REFERENCES datastream_definitions(workspace_id,
    -- template_version_id, stream_key)
    stream_key text NOT NULL,

    -- Một literal JSON number/string được phép của kênh ENUM; validator còn phải kiểm bộ giá trị và type theo
    -- contract.
    -- jsonb: tài liệu JSON lưu dạng nhị phân; kiểm object/scalar không thay validation đầy đủ cấu trúc và tham chiếu
    -- nghiệp vụ.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành datastream_enum_values_enum_value_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN
    -- vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((jsonb_typeof(enum_value) = ANY (ARRAY['string'::text, 'number'::text])))
    -- Ràng buộc hiện hành datastream_enum_values_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, template_version_id, stream_key, enum_value)
    enum_value jsonb NOT NULL,

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    PRIMARY KEY(workspace_id,template_version_id,stream_key,enum_value),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,template_version_id,stream_key) REFERENCES datastream_definitions,

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    CHECK(jsonb_typeof(enum_value) IN ('string','number'))
);
-- Bảng datastream_capabilities: Capability SET_VALUE cùng safeValue của kênh đã công bố. Cho phép kiểm kênh có thể
-- điều khiển, thay vì suy từ việc stream tồn tại.
CREATE TABLE datastream_capabilities (
    -- Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền
    -- của người gọi.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành datastream_capabilities_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, template_version_id, stream_key, command_type)
    -- Ràng buộc hiện hành datastream_capabilities_workspace_id_template_version_id_s_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, template_version_id, stream_key) REFERENCES datastream_definitions(workspace_id,
    -- template_version_id, stream_key)
    workspace_id uuid NOT NULL,

    -- Identity snapshot template cụ thể, dùng pin schema và kiểm đúng definition trong workspace.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành datastream_capabilities_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, template_version_id, stream_key, command_type)
    -- Ràng buộc hiện hành datastream_capabilities_workspace_id_template_version_id_s_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, template_version_id, stream_key) REFERENCES datastream_definitions(workspace_id,
    -- template_version_id, stream_key)
    template_version_id uuid NOT NULL,

    -- Khóa kỹ thuật ổn định của kênh trong template/version; không dùng nhãn hiển thị thay khóa schema.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành datastream_capabilities_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, template_version_id, stream_key, command_type)
    -- Ràng buộc hiện hành datastream_capabilities_workspace_id_template_version_id_s_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, template_version_id, stream_key) REFERENCES datastream_definitions(workspace_id,
    -- template_version_id, stream_key)
    stream_key text NOT NULL,

    -- Capability lệnh được template công bố, hiện chỉ SET_VALUE; không cho thực thi script hoặc lệnh tùy ý.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành datastream_capabilities_command_type_check: CHECK chỉ chặn khi biểu thức là FALSE;
    -- NULL/UNKNOWN vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((command_type = 'SET_VALUE'::text))
    -- Ràng buộc hiện hành datastream_capabilities_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, template_version_id, stream_key, command_type)
    command_type text NOT NULL CHECK(command_type='SET_VALUE'),

    -- Literal giá trị an toàn của capability, phải đúng datatype/range/ENUM; đây là cấu hình, không tự gửi lệnh tới
    -- thiết bị.
    -- jsonb: tài liệu JSON lưu dạng nhị phân; kiểm object/scalar không thay validation đầy đủ cấu trúc và tham chiếu
    -- nghiệp vụ.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành datastream_capabilities_safe_value_check: CHECK chỉ chặn khi biểu thức là FALSE;
    -- NULL/UNKNOWN vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((jsonb_typeof(safe_value) = ANY (ARRAY['number'::text, 'boolean'::text, 'string'::text])))
    safe_value jsonb NOT NULL CHECK(jsonb_typeof(safe_value) IN ('number','boolean','string')),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    PRIMARY KEY(workspace_id,template_version_id,stream_key,command_type),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,template_version_id,stream_key) REFERENCES datastream_definitions
);
/* device_id và serial global cho MQTT lookup; UK scoped bảo vệ mọi reference tenant. */
-- Bảng devices: Registry thiết bị: identity MQTT toàn cục, serial, workspace, owner và template version đã pin.
-- Quản lý lifecycle/metadata; trạng thái kết nối và bộ đếm runtime tách sang device_runtime.
CREATE TABLE devices (
    -- Identity thiết bị toàn cục để resolve MQTT và registry; kết hợp workspace_id bảo vệ mọi tham chiếu trong đúng
    -- tenant.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành devices_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì uniqueness áp dụng
    -- cho cả tổ hợp.
    -- PRIMARY KEY (device_id)
    -- Ràng buộc hiện hành devices_workspace_id_device_id_key: không trùng tổ hợp giá trị được nêu; các cột riêng lẻ
    -- vẫn có thể lặp khi khóa có nhiều cột.
    -- UNIQUE (workspace_id, device_id)
    -- Ràng buộc hiện hành devices_workspace_id_device_id_template_version_id_key: không trùng tổ hợp giá trị được nêu;
    -- các cột riêng lẻ vẫn có thể lặp khi khóa có nhiều cột.
    -- UNIQUE (workspace_id, device_id, template_version_id)
    device_id uuid PRIMARY KEY,

    -- Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền
    -- của người gọi.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành devices_workspace_id_device_id_key: không trùng tổ hợp giá trị được nêu; các cột riêng lẻ
    -- vẫn có thể lặp khi khóa có nhiều cột.
    -- UNIQUE (workspace_id, device_id)
    -- Ràng buộc hiện hành devices_workspace_id_device_id_template_version_id_key: không trùng tổ hợp giá trị được nêu;
    -- các cột riêng lẻ vẫn có thể lặp khi khóa có nhiều cột.
    -- UNIQUE (workspace_id, device_id, template_version_id)
    -- Ràng buộc hiện hành devices_workspace_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ hợp có workspace_id giữ quan
    -- hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id) REFERENCES workspaces(workspace_id)
    -- Ràng buộc hiện hành devices_workspace_id_owner_user_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ hợp có
    -- workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, owner_user_id) REFERENCES memberships(workspace_id, user_id)
    -- Ràng buộc hiện hành devices_workspace_id_template_version_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ hợp có
    -- workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, template_version_id) REFERENCES template_versions(workspace_id, template_version_id)
    workspace_id uuid NOT NULL REFERENCES workspaces,

    -- Serial phần cứng duy nhất toàn cục, phân biệt hoa/thường theo contract registry; dùng lookup đăng ký/onboarding.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành ck_device_serial: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên phải phối
    -- hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((serial_number ~ '^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$'::text))
    -- Ràng buộc hiện hành devices_serial_number_key: không trùng tổ hợp giá trị được nêu; các cột riêng lẻ vẫn có thể
    -- lặp khi khóa có nhiều cột.
    -- UNIQUE (serial_number)
    serial_number text NOT NULL UNIQUE,

    -- Identity snapshot template cụ thể, dùng pin schema và kiểm đúng definition trong workspace.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành devices_workspace_id_device_id_template_version_id_key: không trùng tổ hợp giá trị được nêu;
    -- các cột riêng lẻ vẫn có thể lặp khi khóa có nhiều cột.
    -- UNIQUE (workspace_id, device_id, template_version_id)
    -- Ràng buộc hiện hành devices_workspace_id_template_version_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ hợp có
    -- workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, template_version_id) REFERENCES template_versions(workspace_id, template_version_id)
    template_version_id uuid NOT NULL,

    -- Tài khoản sở hữu tài nguyên trong workspace; backend phải kiểm membership và quyền hiện hành khi đọc/ghi.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành devices_workspace_id_owner_user_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ hợp có
    -- workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, owner_user_id) REFERENCES memberships(workspace_id, user_id)
    owner_user_id uuid NOT NULL,

    -- Tên hiển thị do người dùng đặt cho tài nguyên; không dùng làm identity, quyền hoặc khóa chống lặp.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    name text NOT NULL,

    -- Mô tả bổ sung để người dùng hiểu tài nguyên; NULL nghĩa chưa cung cấp mô tả, không mang authority vận hành.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    description text,

    -- Mã model phần cứng/template theo registry đã duyệt, dùng kiểm tương thích; không suy model từ tên hiển thị.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    model text NOT NULL,

    -- Revision phần cứng để kiểm đúng biến thể board/firmware, khác firmware_version và revision chỉnh sửa metadata.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    hardware_revision text NOT NULL,

    -- Phiên bản firmware được thiết bị báo hoặc manifest khai; không tự chứng minh artifact đã được xác minh/chạy
    -- khỏe.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    firmware_version text,

    -- SHA-256 32 byte của image firmware được xác thực từ thiết bị; NULL khi chưa có identity image đáng tin cậy.
    -- bytea: dãy byte nhị phân; tên digest/ciphertext mô tả mục đích, bản thân kiểu không băm hoặc mã hóa dữ liệu.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    -- Ràng buộc hiện hành devices_firmware_digest_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua,
    -- nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((octet_length(firmware_digest) = 32))
    firmware_digest bytea CHECK(octet_length(firmware_digest)=32),

    -- Trạng thái vòng đời quản lý tài nguyên, tách khỏi presence hoặc tiến độ của job đang chạy.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- DEFAULT 'REGISTERED'::text: giá trị dùng khi INSERT bỏ qua cột; không thay NULL được truyền tường minh và không
    -- tự áp lại khi UPDATE.
    -- Ràng buộc hiện hành ck_device_lifecycle: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên phải
    -- phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((lifecycle_status = ANY (ARRAY['REGISTERED'::text, 'ACTIVE'::text, 'SUSPENDED'::text,
    -- 'ARCHIVED'::text])))
    lifecycle_status text NOT NULL DEFAULT 'ACTIVE' CHECK(lifecycle_status IN ('ACTIVE','SUSPENDED','ARCHIVED')),

    -- Phiên bản chỉnh sửa bản ghi dùng cho CAS/If-Match hoặc đối soát; bên ghi chịu trách nhiệm cập nhật theo đúng
    -- transaction contract.
    -- bigint: số nguyên có dấu 64 bit, phù hợp bộ đếm/generation tăng lâu dài; không tự tăng nếu chưa có cơ chế cấp
    -- giá trị.
    -- NOT NULL: bắt buộc có giá trị.
    -- DEFAULT 1: giá trị dùng khi INSERT bỏ qua cột; không thay NULL được truyền tường minh và không tự áp lại khi
    -- UPDATE.
    -- Ràng buộc hiện hành devices_revision_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên
    -- phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((revision > 0))
    revision bigint NOT NULL DEFAULT 1 CHECK(revision>0),

    -- Mốc phiên bản quyền hiện hành; bên ghi phải tăng khi quyền thay đổi để ticket/job/cache phát hiện ngữ cảnh quyền
    -- cũ.
    -- bigint: số nguyên có dấu 64 bit, phù hợp bộ đếm/generation tăng lâu dài; không tự tăng nếu chưa có cơ chế cấp
    -- giá trị.
    -- NOT NULL: bắt buộc có giá trị.
    -- DEFAULT 1: giá trị dùng khi INSERT bỏ qua cột; không thay NULL được truyền tường minh và không tự áp lại khi
    -- UPDATE.
    -- Ràng buộc hiện hành devices_authorization_version_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn
    -- qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((authorization_version > 0))
    authorization_version bigint NOT NULL DEFAULT 1 CHECK(authorization_version>0),

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
    UNIQUE(workspace_id,device_id),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    UNIQUE(workspace_id,device_id,template_version_id),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,template_version_id) REFERENCES template_versions,

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,owner_user_id) REFERENCES memberships
);
/* Tenant/owner trước identity phục vụ danh sách thiết bị được giao. */
CREATE INDEX ix_devices_owner ON devices(workspace_id,owner_user_id,device_id);
-- Bảng device_runtime: Trạng thái vận hành thay đổi thường xuyên của thiết bị: presence, boot hiện hành, bộ đếm
-- ingest và epoch bảo trì. Tách khỏi metadata để telemetry không làm tăng revision chỉnh sửa thiết bị.
CREATE TABLE device_runtime (
    -- Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền
    -- của người gọi.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành device_runtime_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì uniqueness áp
    -- dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, device_id)
    -- Ràng buộc hiện hành device_runtime_workspace_id_device_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ hợp có
    -- workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, device_id) REFERENCES devices(workspace_id, device_id)
    -- Ràng buộc hiện hành fk_device_runtime_boot: khóa ngoại giữ đúng bản ghi cha; tổ hợp có workspace_id giữ quan hệ
    -- trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, device_id, current_boot_id) REFERENCES device_boot_sessions(workspace_id, device_id,
    -- boot_id)
    workspace_id uuid NOT NULL,

    -- Identity thiết bị toàn cục để resolve MQTT và registry; kết hợp workspace_id bảo vệ mọi tham chiếu trong đúng
    -- tenant.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành device_runtime_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì uniqueness áp
    -- dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, device_id)
    -- Ràng buộc hiện hành device_runtime_workspace_id_device_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ hợp có
    -- workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, device_id) REFERENCES devices(workspace_id, device_id)
    -- Ràng buộc hiện hành fk_device_runtime_boot: khóa ngoại giữ đúng bản ghi cha; tổ hợp có workspace_id giữ quan hệ
    -- trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, device_id, current_boot_id) REFERENCES device_boot_sessions(workspace_id, device_id,
    -- boot_id)
    device_id uuid NOT NULL,

    -- Bộ đếm server đã tiếp nhận cho device, ban đầu 0; tăng theo ingest commit, không lấy wire seq thay thế.
    -- bigint: số nguyên có dấu 64 bit, phù hợp bộ đếm/generation tăng lâu dài; không tự tăng nếu chưa có cơ chế cấp
    -- giá trị.
    -- NOT NULL: bắt buộc có giá trị.
    -- DEFAULT 0: giá trị dùng khi INSERT bỏ qua cột; không thay NULL được truyền tường minh và không tự áp lại khi
    -- UPDATE.
    -- Ràng buộc hiện hành device_runtime_ingestion_sequence_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN
    -- vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((ingestion_sequence >= 0))
    ingestion_sequence bigint NOT NULL DEFAULT 0 CHECK(ingestion_sequence>=0),

    -- Thế hệ kết nối đã xác minh của device, dùng loại sự kiện/reply từ kết nối cũ.
    -- bigint: số nguyên có dấu 64 bit, phù hợp bộ đếm/generation tăng lâu dài; không tự tăng nếu chưa có cơ chế cấp
    -- giá trị.
    -- NOT NULL: bắt buộc có giá trị.
    -- DEFAULT 0: giá trị dùng khi INSERT bỏ qua cột; không thay NULL được truyền tường minh và không tự áp lại khi
    -- UPDATE.
    -- Ràng buộc hiện hành device_runtime_connection_generation_check: CHECK chỉ chặn khi biểu thức là FALSE;
    -- NULL/UNKNOWN vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((connection_generation >= 0))
    connection_generation bigint NOT NULL DEFAULT 0 CHECK(connection_generation>=0),

    -- Thế hệ khóa bảo trì, dùng phân biệt OTA/dispatch đang hiện hành với callback cũ; không reset do reconnect.
    -- bigint: số nguyên có dấu 64 bit, phù hợp bộ đếm/generation tăng lâu dài; không tự tăng nếu chưa có cơ chế cấp
    -- giá trị.
    -- NOT NULL: bắt buộc có giá trị.
    -- DEFAULT 0: giá trị dùng khi INSERT bỏ qua cột; không thay NULL được truyền tường minh và không tự áp lại khi
    -- UPDATE.
    -- Ràng buộc hiện hành device_runtime_maintenance_epoch_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN
    -- vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((maintenance_epoch >= 0))
    maintenance_epoch bigint NOT NULL DEFAULT 0 CHECK(maintenance_epoch>=0),

    -- Chế độ vận hành NONE/OTA của thiết bị, dùng chặn command/automation khi đang bảo trì.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- DEFAULT 'NONE'::text: giá trị dùng khi INSERT bỏ qua cột; không thay NULL được truyền tường minh và không tự áp
    -- lại khi UPDATE.
    -- Ràng buộc hiện hành device_runtime_maintenance_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn
    -- qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((maintenance = ANY (ARRAY['NONE'::text, 'OTA'::text])))
    maintenance text NOT NULL DEFAULT 'NONE' CHECK(maintenance IN ('NONE','OTA')),

    -- Thời điểm hoạt động hợp lệ gần nhất từ thiết bị, dùng phát hiện mất kết nối theo policy presence.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    last_seen_at timestamptz,

    -- Trạng thái kết nối UNKNOWN/ONLINE/OFFLINE, độc lập với lifecycle và maintenance của thiết bị.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- DEFAULT 'UNKNOWN'::text: giá trị dùng khi INSERT bỏ qua cột; không thay NULL được truyền tường minh và không tự
    -- áp lại khi UPDATE.
    -- Ràng buộc hiện hành ck_device_presence: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên phải
    -- phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((presence_state = ANY (ARRAY['UNKNOWN'::text, 'ONLINE'::text, 'OFFLINE'::text])))
    presence_state text NOT NULL DEFAULT 'OFFLINE' CHECK(presence_state IN ('ONLINE','OFFLINE')),

    -- Boot đang hiện hành của thiết bị; NULL khi chưa có boot đáng tin cậy, không hồi sinh boot cũ từ hello trùng.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    -- Ràng buộc hiện hành fk_device_runtime_boot: khóa ngoại giữ đúng bản ghi cha; tổ hợp có workspace_id giữ quan hệ
    -- trong đúng tenant, không thay kiểm quyền hiện hành. FK MATCH SIMPLE mặc định bỏ kiểm khi có thành phần NULL;
    -- CHECK shape riêng vẫn phải đạt.
    -- FOREIGN KEY (workspace_id, device_id, current_boot_id) REFERENCES device_boot_sessions(workspace_id, device_id,
    -- boot_id)
    current_boot_id text,

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    PRIMARY KEY(workspace_id,device_id),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,device_id) REFERENCES devices(workspace_id,device_id)
);
-- Bảng device_credentials: Các generation credential MQTT của thiết bị và trạng thái cấp/thu hồi. Chỉ lưu bộ kiểm
-- chứng, không giữ raw credential để đọc lại.
CREATE TABLE device_credentials (
    -- Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền
    -- của người gọi.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành device_credentials_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì uniqueness
    -- áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, device_id, credential_generation)
    -- Ràng buộc hiện hành device_credentials_workspace_id_device_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ hợp có
    -- workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, device_id) REFERENCES devices(workspace_id, device_id)
    workspace_id uuid NOT NULL,

    -- Identity thiết bị toàn cục để resolve MQTT và registry; kết hợp workspace_id bảo vệ mọi tham chiếu trong đúng
    -- tenant.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành device_credentials_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì uniqueness
    -- áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, device_id, credential_generation)
    -- Ràng buộc hiện hành device_credentials_workspace_id_device_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ hợp có
    -- workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, device_id) REFERENCES devices(workspace_id, device_id)
    device_id uuid NOT NULL,

    -- Thế hệ credential MQTT của thiết bị, phân biệt lần cấp mới với credential cũ đã thu hồi.
    -- bigint: số nguyên có dấu 64 bit, phù hợp bộ đếm/generation tăng lâu dài; không tự tăng nếu chưa có cơ chế cấp
    -- giá trị.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành device_credentials_credential_generation_check: CHECK chỉ chặn khi biểu thức là FALSE;
    -- NULL/UNKNOWN vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((credential_generation > 0))
    -- Ràng buộc hiện hành device_credentials_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì uniqueness
    -- áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, device_id, credential_generation)
    credential_generation bigint NOT NULL CHECK(credential_generation>0),

    -- Định danh credential/client phía broker, duy nhất toàn cục; không phải raw password MQTT.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành device_credentials_credential_identifier_key: không trùng tổ hợp giá trị được nêu; các cột
    -- riêng lẻ vẫn có thể lặp khi khóa có nhiều cột.
    -- UNIQUE (credential_identifier)
    credential_identifier text NOT NULL UNIQUE,

    -- Bộ kiểm chứng mật 32 byte dùng xác thực credential/API key theo protected-verifier contract; không là raw secret
    -- và không trả client/log.
    -- bytea: dãy byte nhị phân; tên digest/ciphertext mô tả mục đích, bản thân kiểu không băm hoặc mã hóa dữ liệu.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành device_credentials_verifier_digest_check: CHECK chỉ chặn khi biểu thức là FALSE;
    -- NULL/UNKNOWN vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((octet_length(verifier_digest) = 32))
    verifier_digest bytea NOT NULL CHECK(octet_length(verifier_digest)=32),

    -- Tiến trình credential PROVISIONING/ACTIVE/REVOCATION_PENDING/REVOKED; chỉ báo đã revoke khi có xác nhận phù hợp.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành ck_device_credential_state: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên
    -- phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((credential_state = ANY (ARRAY['PROVISIONING'::text, 'ACTIVE'::text, 'REVOCATION_PENDING'::text,
    -- 'REVOKED'::text])))
    credential_state text NOT NULL CHECK(credential_state IN ('PROVISIONING','ACTIVE','REVOKING','REVOKED','FAILED')),

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
    PRIMARY KEY(workspace_id,device_id,credential_generation),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,device_id) REFERENCES devices(workspace_id,device_id)
);
/* Không cấp hai credential ACTIVE cho cùng thiết bị. */
CREATE UNIQUE INDEX uq_device_credentials_active ON device_credentials(workspace_id,device_id) WHERE credential_state='ACTIVE';
-- Bảng device_boot_sessions: Mỗi lần khởi động/kết nối thiết bị đã được backend xác minh. Gắn boot với credential
-- và connection generation, lưu frontier sequence để phân biệt replay với dữ liệu của boot mới.
CREATE TABLE device_boot_sessions (
    -- Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền
    -- của người gọi.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành device_boot_sessions_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, device_id, boot_id)
    -- Ràng buộc hiện hành device_boot_sessions_workspace_id_device_id_boot_id_credent_key: không trùng tổ hợp giá trị
    -- được nêu; các cột riêng lẻ vẫn có thể lặp khi khóa có nhiều cột.
    -- UNIQUE (workspace_id, device_id, boot_id, credential_generation)
    -- Ràng buộc hiện hành device_boot_sessions_workspace_id_device_id_credential_gen_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, device_id, credential_generation) REFERENCES device_credentials(workspace_id,
    -- device_id, credential_generation)
    workspace_id uuid NOT NULL,

    -- Identity thiết bị toàn cục để resolve MQTT và registry; kết hợp workspace_id bảo vệ mọi tham chiếu trong đúng
    -- tenant.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành device_boot_sessions_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, device_id, boot_id)
    -- Ràng buộc hiện hành device_boot_sessions_workspace_id_device_id_boot_id_credent_key: không trùng tổ hợp giá trị
    -- được nêu; các cột riêng lẻ vẫn có thể lặp khi khóa có nhiều cột.
    -- UNIQUE (workspace_id, device_id, boot_id, credential_generation)
    -- Ràng buộc hiện hành device_boot_sessions_workspace_id_device_id_credential_gen_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, device_id, credential_generation) REFERENCES device_credentials(workspace_id,
    -- device_id, credential_generation)
    device_id uuid NOT NULL,

    -- Identity boot của thiết bị theo wire dạng text, không suy UUID; chỉ chấp nhận khi gắn với credential/connection
    -- đã xác minh.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành device_boot_sessions_boot_id_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn
    -- qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((btrim(boot_id) <> ''::text))
    -- Ràng buộc hiện hành device_boot_sessions_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, device_id, boot_id)
    -- Ràng buộc hiện hành device_boot_sessions_workspace_id_device_id_boot_id_credent_key: không trùng tổ hợp giá trị
    -- được nêu; các cột riêng lẻ vẫn có thể lặp khi khóa có nhiều cột.
    -- UNIQUE (workspace_id, device_id, boot_id, credential_generation)
    boot_id text NOT NULL CHECK(btrim(boot_id)<>''),

    -- Thế hệ credential MQTT của thiết bị, phân biệt lần cấp mới với credential cũ đã thu hồi.
    -- bigint: số nguyên có dấu 64 bit, phù hợp bộ đếm/generation tăng lâu dài; không tự tăng nếu chưa có cơ chế cấp
    -- giá trị.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành device_boot_sessions_workspace_id_device_id_boot_id_credent_key: không trùng tổ hợp giá trị
    -- được nêu; các cột riêng lẻ vẫn có thể lặp khi khóa có nhiều cột.
    -- UNIQUE (workspace_id, device_id, boot_id, credential_generation)
    -- Ràng buộc hiện hành device_boot_sessions_workspace_id_device_id_credential_gen_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, device_id, credential_generation) REFERENCES device_credentials(workspace_id,
    -- device_id, credential_generation)
    credential_generation bigint NOT NULL,

    -- Thế hệ kết nối đã xác minh của device, dùng loại sự kiện/reply từ kết nối cũ.
    -- bigint: số nguyên có dấu 64 bit, phù hợp bộ đếm/generation tăng lâu dài; không tự tăng nếu chưa có cơ chế cấp
    -- giá trị.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành device_boot_sessions_connection_generation_check: CHECK chỉ chặn khi biểu thức là FALSE;
    -- NULL/UNKNOWN vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((connection_generation > 0))
    connection_generation bigint NOT NULL CHECK(connection_generation>0),

    -- Thời điểm backend xác minh boot/kết nối theo credential generation; không chỉ tin boot_id trong payload.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    started_at timestamptz NOT NULL,

    -- Thời điểm boot/secret version được retire; dữ liệu lịch sử và các nghĩa vụ còn tham chiếu có thể tiếp tục được
    -- giữ.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    retired_at timestamptz,

    -- Frontier sequence nguồn đã được compact/retire theo boot; writer phải đối soát trước compact receipt, không tự
    -- reset khi purge raw.
    -- bigint: số nguyên có dấu 64 bit, phù hợp bộ đếm/generation tăng lâu dài; không tự tăng nếu chưa có cơ chế cấp
    -- giá trị.
    -- NOT NULL: bắt buộc có giá trị.
    -- DEFAULT 0: giá trị dùng khi INSERT bỏ qua cột; không thay NULL được truyền tường minh và không tự áp lại khi
    -- UPDATE.
    -- Ràng buộc hiện hành device_boot_sessions_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên
    -- phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((last_source_sequence >= source_sequence_floor))
    -- Ràng buộc hiện hành device_boot_sessions_source_sequence_floor_check: CHECK chỉ chặn khi biểu thức là FALSE;
    -- NULL/UNKNOWN vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((source_sequence_floor >= 0))
    source_sequence_floor bigint NOT NULL DEFAULT 0 CHECK(source_sequence_floor>=0),

    -- Sequence nguồn gần nhất đã ghi nhận cho boot; NULL khi chưa có mốc, không dùng thay thứ tự server ingest.
    -- bigint: số nguyên có dấu 64 bit, phù hợp bộ đếm/generation tăng lâu dài; không tự tăng nếu chưa có cơ chế cấp
    -- giá trị.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    -- Ràng buộc hiện hành device_boot_sessions_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên
    -- phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((last_source_sequence >= source_sequence_floor))
    last_source_sequence bigint CHECK(last_source_sequence>=source_sequence_floor),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    PRIMARY KEY(workspace_id,device_id,boot_id),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    UNIQUE(workspace_id,device_id,boot_id,credential_generation),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,device_id,credential_generation) REFERENCES device_credentials
);
ALTER TABLE device_runtime ADD CONSTRAINT fk_device_runtime_boot FOREIGN KEY(workspace_id,device_id,current_boot_id) REFERENCES device_boot_sessions;
-- Bảng provisioning_operations: Ý định cấp credential và tiến trình bàn giao một lần qua USB/BLE. Tách kết quả cấu
-- hình broker khỏi trạng thái phát secret; escrow chỉ là ciphertext tạm có key reference và hạn riêng.
CREATE TABLE provisioning_operations (
    -- Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền
    -- của người gọi.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành provisioning_operations_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, provisioning_operation_id)
    -- Ràng buộc hiện hành provisioning_operations_workspace_id_actor_user_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ
    -- hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, actor_user_id) REFERENCES memberships(workspace_id, user_id)
    -- Ràng buộc hiện hành provisioning_operations_workspace_id_device_id_credential__fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, device_id, credential_generation) REFERENCES device_credentials(workspace_id,
    -- device_id, credential_generation)
    -- Ràng buộc hiện hành provisioning_operations_workspace_id_device_id_credential_g_key: không trùng tổ hợp giá trị
    -- được nêu; các cột riêng lẻ vẫn có thể lặp khi khóa có nhiều cột.
    -- UNIQUE (workspace_id, device_id, credential_generation)
    -- Ràng buộc hiện hành provisioning_operations_workspace_id_provisioning_operation_key: không trùng tổ hợp giá trị
    -- được nêu; các cột riêng lẻ vẫn có thể lặp khi khóa có nhiều cột.
    -- UNIQUE (workspace_id, provisioning_operation_id, device_id)
    workspace_id uuid NOT NULL,

    -- Identity công việc cấp credential, dùng claim một lần và gắn enrollment đúng device/generation.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành provisioning_operations_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, provisioning_operation_id)
    -- Ràng buộc hiện hành provisioning_operations_workspace_id_provisioning_operation_key: không trùng tổ hợp giá trị
    -- được nêu; các cột riêng lẻ vẫn có thể lặp khi khóa có nhiều cột.
    -- UNIQUE (workspace_id, provisioning_operation_id, device_id)
    provisioning_operation_id uuid NOT NULL,

    -- Identity thiết bị toàn cục để resolve MQTT và registry; kết hợp workspace_id bảo vệ mọi tham chiếu trong đúng
    -- tenant.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành provisioning_operations_workspace_id_device_id_credential__fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, device_id, credential_generation) REFERENCES device_credentials(workspace_id,
    -- device_id, credential_generation)
    -- Ràng buộc hiện hành provisioning_operations_workspace_id_device_id_credential_g_key: không trùng tổ hợp giá trị
    -- được nêu; các cột riêng lẻ vẫn có thể lặp khi khóa có nhiều cột.
    -- UNIQUE (workspace_id, device_id, credential_generation)
    -- Ràng buộc hiện hành provisioning_operations_workspace_id_provisioning_operation_key: không trùng tổ hợp giá trị
    -- được nêu; các cột riêng lẻ vẫn có thể lặp khi khóa có nhiều cột.
    -- UNIQUE (workspace_id, provisioning_operation_id, device_id)
    device_id uuid NOT NULL,

    -- Thế hệ credential MQTT của thiết bị, phân biệt lần cấp mới với credential cũ đã thu hồi.
    -- bigint: số nguyên có dấu 64 bit, phù hợp bộ đếm/generation tăng lâu dài; không tự tăng nếu chưa có cơ chế cấp
    -- giá trị.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành provisioning_operations_workspace_id_device_id_credential__fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, device_id, credential_generation) REFERENCES device_credentials(workspace_id,
    -- device_id, credential_generation)
    -- Ràng buộc hiện hành provisioning_operations_workspace_id_device_id_credential_g_key: không trùng tổ hợp giá trị
    -- được nêu; các cột riêng lẻ vẫn có thể lặp khi khóa có nhiều cột.
    -- UNIQUE (workspace_id, device_id, credential_generation)
    credential_generation bigint NOT NULL,

    -- Kênh phát credential USB_ONE_TIME/ENROLLMENT_BLE; quyết định binding/escrow/claim policy, không là trạng thái
    -- broker.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành provisioning_operations_delivery_channel_check: CHECK chỉ chặn khi biểu thức là FALSE;
    -- NULL/UNKNOWN vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((delivery_channel = ANY (ARRAY['USB_ONE_TIME'::text, 'ENROLLMENT_BLE'::text])))
    delivery_channel text NOT NULL CHECK(delivery_channel IN ('USB_ONE_TIME','ENROLLMENT_BLE')),

    -- Kết quả cấu hình broker PENDING/READY/FAILED, tách khỏi delivery_status của secret để không báo board đã nhận
    -- credential chỉ vì broker READY.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành ck_provisioning_state: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên phải
    -- phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((state = ANY (ARRAY['PENDING'::text, 'READY'::text, 'FAILED'::text])))
    state text NOT NULL CHECK(state IN ('PENDING','PROVISIONING','READY','CLAIMED','FAILED','EXPIRED','REVOKING','REVOKED')),

    -- Tài khoản thực hiện hoặc khởi tạo thao tác, phục vụ kiểm quyền và truy vết; không lấy authority chỉ từ ID client
    -- gửi.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành provisioning_operations_workspace_id_actor_user_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ
    -- hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, actor_user_id) REFERENCES memberships(workspace_id, user_id)
    actor_user_id uuid NOT NULL,

    -- Thời điểm lưu ý định trước side effect bên ngoài DB; dùng tính ngân sách/expiry và phục hồi khi mất ACK.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành ck_provisioning_escrow_expiry: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua,
    -- nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((expires_at = (intent_at + '00:10:00'::interval)))
    -- Ràng buộc hiện hành provisioning_operations_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua,
    -- nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((expires_at > intent_at))
    intent_at timestamptz NOT NULL,

    -- Hạn escrow intent_at + 10 phút; broker ACK/retry/poll không kéo dài deadline, cleanup intent có thể sống lâu hơn
    -- escrow.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành ck_provisioning_escrow_expiry: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua,
    -- nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((expires_at = (intent_at + '00:10:00'::interval)))
    -- Ràng buộc hiện hành provisioning_operations_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua,
    -- nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((expires_at > intent_at))
    expires_at timestamptz NOT NULL,

    -- Mốc backend có xác nhận cấu hình credential/ACL từ broker; khác MQTT PUBACK của message ứng dụng.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    broker_receipt_at timestamptz,

    -- Thời điểm server tiêu thụ quyền phát credential một lần; không chứng minh client/board đã nhận được secret.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    claimed_at timestamptz,

    -- Secret recoverable đã mã hóa cho escrow/ký webhook; key wrapping nằm ngoài DB và chỉ đường ghi có custody được
    -- dùng giá trị này.
    -- bytea: dãy byte nhị phân; tên digest/ciphertext mô tả mục đích, bản thân kiểu không băm hoặc mã hóa dữ liệu.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    -- Ràng buộc hiện hành provisioning_operations_check1: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua,
    -- nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK (((secret_ciphertext IS NULL) = (encryption_key_reference IS NULL)))
    secret_ciphertext bytea,

    -- Tham chiếu/version của khóa dùng giải mã ciphertext, không chứa key material; NULL phải đồng bộ với nhánh không
    -- có ciphertext.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    -- Ràng buộc hiện hành provisioning_operations_check1: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua,
    -- nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK (((secret_ciphertext IS NULL) = (encryption_key_reference IS NULL)))
    encryption_key_reference text,

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    PRIMARY KEY(workspace_id,provisioning_operation_id),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    UNIQUE(workspace_id,device_id,credential_generation),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    UNIQUE(workspace_id,provisioning_operation_id,device_id),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,device_id,credential_generation) REFERENCES device_credentials,

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,actor_user_id) REFERENCES memberships,

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    CHECK(expires_at>intent_at),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    CHECK((secret_ciphertext IS NULL)=(encryption_key_reference IS NULL))
);
-- Bảng device_operations: Ý định lifecycle thiết bị như suspend/resume/archive/revoke. Giữ trạng thái đối soát
-- cùng receipt broker/disconnect để không báo hoàn tất khi side effect chưa được xác nhận.
CREATE TABLE device_operations (
    -- Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền
    -- của người gọi.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành device_operations_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì uniqueness
    -- áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, device_operation_id)
    -- Ràng buộc hiện hành device_operations_workspace_id_actor_user_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ hợp
    -- có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, actor_user_id) REFERENCES memberships(workspace_id, user_id)
    -- Ràng buộc hiện hành device_operations_workspace_id_device_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ hợp có
    -- workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, device_id) REFERENCES devices(workspace_id, device_id)
    -- Ràng buộc hiện hành device_operations_workspace_id_device_operation_id_device_i_key: không trùng tổ hợp giá trị
    -- được nêu; các cột riêng lẻ vẫn có thể lặp khi khóa có nhiều cột.
    -- UNIQUE (workspace_id, device_operation_id, device_id)
    workspace_id uuid NOT NULL,

    -- Identity lifecycle operation của thiết bị; khi tham chiếu cùng device_id phải khớp đúng thiết bị đó.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành device_operations_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì uniqueness
    -- áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, device_operation_id)
    -- Ràng buộc hiện hành device_operations_workspace_id_device_operation_id_device_i_key: không trùng tổ hợp giá trị
    -- được nêu; các cột riêng lẻ vẫn có thể lặp khi khóa có nhiều cột.
    -- UNIQUE (workspace_id, device_operation_id, device_id)
    device_operation_id uuid NOT NULL,

    -- Identity thiết bị toàn cục để resolve MQTT và registry; kết hợp workspace_id bảo vệ mọi tham chiếu trong đúng
    -- tenant.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành device_operations_workspace_id_device_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ hợp có
    -- workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, device_id) REFERENCES devices(workspace_id, device_id)
    -- Ràng buộc hiện hành device_operations_workspace_id_device_operation_id_device_i_key: không trùng tổ hợp giá trị
    -- được nêu; các cột riêng lẻ vẫn có thể lặp khi khóa có nhiều cột.
    -- UNIQUE (workspace_id, device_operation_id, device_id)
    device_id uuid NOT NULL,

    -- Loại lifecycle mutation được yêu cầu, để worker thực hiện đúng thao tác và kiểm proof tương ứng.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành device_operations_operation_type_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN
    -- vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((operation_type = ANY (ARRAY['SUSPEND'::text, 'RESUME'::text, 'ARCHIVE'::text,
    -- 'REVOKE_CREDENTIAL'::text])))
    operation_type text NOT NULL CHECK(operation_type IN ('SUSPEND','RESUME','ARCHIVE','REVOKE_CREDENTIAL')),

    -- Trạng thái xử lý bền vững của ledger/job/operation; không suy rằng enum hợp lệ tự chứng minh transition hợp lệ.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành device_operations_state_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua,
    -- nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((state = ANY (ARRAY['PENDING'::text, 'RUNNING'::text, 'SUCCEEDED'::text, 'FAILED'::text,
    -- 'NEEDS_ATTENTION'::text])))
    state text NOT NULL CHECK(state IN ('PENDING','RUNNING','SUCCEEDED','FAILED','NEEDS_ATTENTION')),

    -- Revision resource mà người yêu cầu dựa vào lúc khởi tạo lifecycle operation; dùng phát hiện yêu cầu chỉnh sửa đã
    -- lỗi thời.
    -- bigint: số nguyên có dấu 64 bit, phù hợp bộ đếm/generation tăng lâu dài; không tự tăng nếu chưa có cơ chế cấp
    -- giá trị.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành device_operations_requested_revision_check: CHECK chỉ chặn khi biểu thức là FALSE;
    -- NULL/UNKNOWN vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((requested_revision > 0))
    requested_revision bigint NOT NULL CHECK(requested_revision>0),

    -- Tài khoản thực hiện hoặc khởi tạo thao tác, phục vụ kiểm quyền và truy vết; không lấy authority chỉ từ ID client
    -- gửi.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành device_operations_workspace_id_actor_user_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ hợp
    -- có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, actor_user_id) REFERENCES memberships(workspace_id, user_id)
    actor_user_id uuid NOT NULL,

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

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    PRIMARY KEY(workspace_id,device_operation_id),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    UNIQUE(workspace_id,device_operation_id,device_id),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,device_id) REFERENCES devices(workspace_id,device_id),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,actor_user_id) REFERENCES memberships
);
/* Cleanup chưa có proof vẫn giữ operation guard. */
CREATE UNIQUE INDEX uq_device_operations_unsettled ON device_operations(workspace_id,device_id) WHERE settled_at IS NULL;
-- Bảng connectivity_transitions: Nhật ký từng chuyển trạng thái kết nối thực sự của thiết bị. Sequence ổn định
-- giúp rule và webhook chống tạo sự kiện trùng từ heartbeat hoặc hello lặp.
CREATE TABLE connectivity_transitions (
    -- Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền
    -- của người gọi.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành connectivity_transitions_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, device_id, transition_sequence)
    -- Ràng buộc hiện hành connectivity_transitions_workspace_id_device_id_boot_id_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, device_id, boot_id) REFERENCES device_boot_sessions(workspace_id, device_id, boot_id)
    -- Ràng buộc hiện hành connectivity_transitions_workspace_id_device_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ
    -- hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, device_id) REFERENCES devices(workspace_id, device_id)
    workspace_id uuid NOT NULL,

    -- Identity thiết bị toàn cục để resolve MQTT và registry; kết hợp workspace_id bảo vệ mọi tham chiếu trong đúng
    -- tenant.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành connectivity_transitions_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, device_id, transition_sequence)
    -- Ràng buộc hiện hành connectivity_transitions_workspace_id_device_id_boot_id_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, device_id, boot_id) REFERENCES device_boot_sessions(workspace_id, device_id, boot_id)
    -- Ràng buộc hiện hành connectivity_transitions_workspace_id_device_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ
    -- hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, device_id) REFERENCES devices(workspace_id, device_id)
    device_id uuid NOT NULL,

    -- Số thứ tự chuyển presence thực sự của thiết bị, bắt đầu lớn hơn 0; heartbeat trùng không tạo transition mới.
    -- bigint: số nguyên có dấu 64 bit, phù hợp bộ đếm/generation tăng lâu dài; không tự tăng nếu chưa có cơ chế cấp
    -- giá trị.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành connectivity_transitions_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, device_id, transition_sequence)
    -- Ràng buộc hiện hành connectivity_transitions_transition_sequence_check: CHECK chỉ chặn khi biểu thức là FALSE;
    -- NULL/UNKNOWN vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((transition_sequence > 0))
    transition_sequence bigint NOT NULL CHECK(transition_sequence>0),

    -- Thế hệ kết nối đã xác minh của device, dùng loại sự kiện/reply từ kết nối cũ.
    -- bigint: số nguyên có dấu 64 bit, phù hợp bộ đếm/generation tăng lâu dài; không tự tăng nếu chưa có cơ chế cấp
    -- giá trị.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành connectivity_transitions_connection_generation_check: CHECK chỉ chặn khi biểu thức là FALSE;
    -- NULL/UNKNOWN vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((connection_generation > 0))
    connection_generation bigint NOT NULL CHECK(connection_generation>0),

    -- Trạng thái presence trước chuyển đổi, dùng đối chiếu edge thực tế và giải thích trigger connectivity.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành connectivity_transitions_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua,
    -- nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((from_state <> to_state))
    -- Ràng buộc hiện hành connectivity_transitions_from_state_check: CHECK chỉ chặn khi biểu thức là FALSE;
    -- NULL/UNKNOWN vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((from_state = ANY (ARRAY['ONLINE'::text, 'OFFLINE'::text])))
    from_state text NOT NULL CHECK(from_state IN ('ONLINE','OFFLINE')),

    -- Trạng thái presence sau chuyển đổi, phải khác from_state; không tự thay lifecycle ACTIVE/SUSPENDED.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành connectivity_transitions_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua,
    -- nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((from_state <> to_state))
    -- Ràng buộc hiện hành connectivity_transitions_to_state_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN
    -- vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((to_state = ANY (ARRAY['ONLINE'::text, 'OFFLINE'::text])))
    to_state text NOT NULL CHECK(to_state IN ('ONLINE','OFFLINE')),

    -- Thời điểm quan sát được dữ liệu/kết quả; nguồn và ý nghĩa được quy định theo bảng, không mặc định là thời gian
    -- commit.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    observed_at timestamptz NOT NULL,

    -- Identity boot của thiết bị theo wire dạng text, không suy UUID; chỉ chấp nhận khi gắn với credential/connection
    -- đã xác minh.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    -- Ràng buộc hiện hành connectivity_transitions_workspace_id_device_id_boot_id_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành. FK MATCH SIMPLE mặc
    -- định bỏ kiểm khi có thành phần NULL; CHECK shape riêng vẫn phải đạt.
    -- FOREIGN KEY (workspace_id, device_id, boot_id) REFERENCES device_boot_sessions(workspace_id, device_id, boot_id)
    boot_id text,

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    PRIMARY KEY(workspace_id,device_id,transition_sequence),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    CHECK(from_state<>to_state),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,device_id) REFERENCES devices(workspace_id,device_id),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,device_id,boot_id) REFERENCES device_boot_sessions
);
/* Receipt là authority dedupe, không tham chiếu ngược raw để purge raw độc lập. */
-- Bảng telemetry_receipts: Ledger định danh và digest của envelope đã nhận thành công. Tồn tại độc lập raw
-- telemetry để retry không tái tạo dữ liệu sau khi raw bị purge.
CREATE TABLE telemetry_receipts (
    -- Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền
    -- của người gọi.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành telemetry_receipts_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì uniqueness
    -- áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, device_id, boot_id, message_id)
    -- Ràng buộc hiện hành telemetry_receipts_workspace_id_device_id_boot_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ
    -- hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, device_id, boot_id) REFERENCES device_boot_sessions(workspace_id, device_id, boot_id)
    -- Ràng buộc hiện hành telemetry_receipts_workspace_id_device_id_ingestion_sequenc_key: không trùng tổ hợp giá trị
    -- được nêu; các cột riêng lẻ vẫn có thể lặp khi khóa có nhiều cột.
    -- UNIQUE (workspace_id, device_id, ingestion_sequence)
    workspace_id uuid NOT NULL,

    -- Identity thiết bị toàn cục để resolve MQTT và registry; kết hợp workspace_id bảo vệ mọi tham chiếu trong đúng
    -- tenant.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành telemetry_receipts_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì uniqueness
    -- áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, device_id, boot_id, message_id)
    -- Ràng buộc hiện hành telemetry_receipts_workspace_id_device_id_boot_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ
    -- hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, device_id, boot_id) REFERENCES device_boot_sessions(workspace_id, device_id, boot_id)
    -- Ràng buộc hiện hành telemetry_receipts_workspace_id_device_id_ingestion_sequenc_key: không trùng tổ hợp giá trị
    -- được nêu; các cột riêng lẻ vẫn có thể lặp khi khóa có nhiều cột.
    -- UNIQUE (workspace_id, device_id, ingestion_sequence)
    device_id uuid NOT NULL,

    -- Identity boot của thiết bị theo wire dạng text, không suy UUID; chỉ chấp nhận khi gắn với credential/connection
    -- đã xác minh.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành telemetry_receipts_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì uniqueness
    -- áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, device_id, boot_id, message_id)
    -- Ràng buộc hiện hành telemetry_receipts_workspace_id_device_id_boot_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ
    -- hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, device_id, boot_id) REFERENCES device_boot_sessions(workspace_id, device_id, boot_id)
    boot_id text NOT NULL,

    -- Identity message do thiết bị gửi trong một boot, kiểu text theo wire contract; kết hợp device/boot để chống nhận
    -- trùng.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành telemetry_receipts_message_id_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn
    -- qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((btrim(message_id) <> ''::text))
    -- Ràng buộc hiện hành telemetry_receipts_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì uniqueness
    -- áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, device_id, boot_id, message_id)
    message_id text NOT NULL CHECK(btrim(message_id)<>''),

    -- Sequence thiết bị khai trong message/boot theo wire; dùng frontier chống replay, không nhầm với
    -- ingestion_sequence.
    -- bigint: số nguyên có dấu 64 bit, phù hợp bộ đếm/generation tăng lâu dài; không tự tăng nếu chưa có cơ chế cấp
    -- giá trị.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành telemetry_receipts_source_sequence_check: CHECK chỉ chặn khi biểu thức là FALSE;
    -- NULL/UNKNOWN vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((source_sequence >= 0))
    source_sequence bigint NOT NULL CHECK(source_sequence>=0),

    -- SHA-256 32 byte của payload đã chấp nhận, phục vụ dedupe và phát hiện cùng identity nhưng body mâu thuẫn.
    -- bytea: dãy byte nhị phân; tên digest/ciphertext mô tả mục đích, bản thân kiểu không băm hoặc mã hóa dữ liệu.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành telemetry_receipts_payload_digest_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN
    -- vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((octet_length(payload_digest) = 32))
    payload_digest bytea NOT NULL CHECK(octet_length(payload_digest)=32),

    -- Thời điểm server chấp nhận lần đầu message identity, giữ nguyên khi retry và làm authority cho envelope
    -- received_at.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    first_received_at timestamptz NOT NULL,

    -- Thứ tự tiếp nhận do server quản lý trong từng device, khác sequence trên wire của thiết bị.
    -- bigint: số nguyên có dấu 64 bit, phù hợp bộ đếm/generation tăng lâu dài; không tự tăng nếu chưa có cơ chế cấp
    -- giá trị.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành telemetry_receipts_ingestion_sequence_check: CHECK chỉ chặn khi biểu thức là FALSE;
    -- NULL/UNKNOWN vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((ingestion_sequence > 0))
    -- Ràng buộc hiện hành telemetry_receipts_workspace_id_device_id_ingestion_sequenc_key: không trùng tổ hợp giá trị
    -- được nêu; các cột riêng lẻ vẫn có thể lặp khi khóa có nhiều cột.
    -- UNIQUE (workspace_id, device_id, ingestion_sequence)
    ingestion_sequence bigint NOT NULL CHECK(ingestion_sequence>0),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    PRIMARY KEY(workspace_id,device_id,boot_id,message_id),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    UNIQUE(workspace_id,device_id,ingestion_sequence),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,device_id,boot_id) REFERENCES device_boot_sessions
);
-- Bảng telemetry_envelopes: Một gói telemetry đã nhận, chứa thời gian/provenance chung và số point dự kiến. Liên
-- kết receipt với các point để ghi toàn gói hoặc rollback toàn gói.
CREATE TABLE telemetry_envelopes (
    -- Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền
    -- của người gọi.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành telemetry_envelopes_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, envelope_id)
    -- Ràng buộc hiện hành telemetry_envelopes_workspace_id_device_id_boot_id_message__key: không trùng tổ hợp giá trị
    -- được nêu; các cột riêng lẻ vẫn có thể lặp khi khóa có nhiều cột.
    -- UNIQUE (workspace_id, device_id, boot_id, message_id)
    -- Ràng buộc hiện hành telemetry_envelopes_workspace_id_device_id_boot_id_message_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, device_id, boot_id, message_id) REFERENCES telemetry_receipts(workspace_id,
    -- device_id, boot_id, message_id)
    -- Ràng buộc hiện hành telemetry_envelopes_workspace_id_envelope_id_device_id_key: không trùng tổ hợp giá trị được
    -- nêu; các cột riêng lẻ vẫn có thể lặp khi khóa có nhiều cột.
    -- UNIQUE (workspace_id, envelope_id, device_id)
    workspace_id uuid NOT NULL,

    -- Identity raw envelope trong workspace để liên kết các point; receipt tự nhiên vẫn tồn tại khi raw envelope bị
    -- purge.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành telemetry_envelopes_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, envelope_id)
    -- Ràng buộc hiện hành telemetry_envelopes_workspace_id_envelope_id_device_id_key: không trùng tổ hợp giá trị được
    -- nêu; các cột riêng lẻ vẫn có thể lặp khi khóa có nhiều cột.
    -- UNIQUE (workspace_id, envelope_id, device_id)
    envelope_id uuid NOT NULL,

    -- Identity thiết bị toàn cục để resolve MQTT và registry; kết hợp workspace_id bảo vệ mọi tham chiếu trong đúng
    -- tenant.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành telemetry_envelopes_workspace_id_device_id_boot_id_message__key: không trùng tổ hợp giá trị
    -- được nêu; các cột riêng lẻ vẫn có thể lặp khi khóa có nhiều cột.
    -- UNIQUE (workspace_id, device_id, boot_id, message_id)
    -- Ràng buộc hiện hành telemetry_envelopes_workspace_id_device_id_boot_id_message_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, device_id, boot_id, message_id) REFERENCES telemetry_receipts(workspace_id,
    -- device_id, boot_id, message_id)
    -- Ràng buộc hiện hành telemetry_envelopes_workspace_id_envelope_id_device_id_key: không trùng tổ hợp giá trị được
    -- nêu; các cột riêng lẻ vẫn có thể lặp khi khóa có nhiều cột.
    -- UNIQUE (workspace_id, envelope_id, device_id)
    device_id uuid NOT NULL,

    -- Identity boot của thiết bị theo wire dạng text, không suy UUID; chỉ chấp nhận khi gắn với credential/connection
    -- đã xác minh.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành telemetry_envelopes_workspace_id_device_id_boot_id_message__key: không trùng tổ hợp giá trị
    -- được nêu; các cột riêng lẻ vẫn có thể lặp khi khóa có nhiều cột.
    -- UNIQUE (workspace_id, device_id, boot_id, message_id)
    -- Ràng buộc hiện hành telemetry_envelopes_workspace_id_device_id_boot_id_message_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, device_id, boot_id, message_id) REFERENCES telemetry_receipts(workspace_id,
    -- device_id, boot_id, message_id)
    boot_id text NOT NULL,

    -- Identity message do thiết bị gửi trong một boot, kiểu text theo wire contract; kết hợp device/boot để chống nhận
    -- trùng.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành telemetry_envelopes_workspace_id_device_id_boot_id_message__key: không trùng tổ hợp giá trị
    -- được nêu; các cột riêng lẻ vẫn có thể lặp khi khóa có nhiều cột.
    -- UNIQUE (workspace_id, device_id, boot_id, message_id)
    -- Ràng buộc hiện hành telemetry_envelopes_workspace_id_device_id_boot_id_message_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, device_id, boot_id, message_id) REFERENCES telemetry_receipts(workspace_id,
    -- device_id, boot_id, message_id)
    message_id text NOT NULL,

    -- Timestamp do thiết bị khai chung cho envelope; NULL khi thiết bị chưa có clock, không nhận timestamp khác nhau
    -- cho từng point.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    -- Ràng buộc hiện hành ck_telemetry_time_basis: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên
    -- phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((((time_basis = 'DEVICE'::text) AND (observed_at IS NOT NULL) AND (effective_at = observed_at)) OR
    -- ((time_basis = 'SERVER'::text) AND (effective_at = received_at))))
    observed_at timestamptz,

    -- Server first-received time phải khớp receipt, không thay thành thời gian nhận lại khi retry.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành ck_telemetry_time_basis: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên
    -- phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((((time_basis = 'DEVICE'::text) AND (observed_at IS NOT NULL) AND (effective_at = observed_at)) OR
    -- ((time_basis = 'SERVER'::text) AND (effective_at = received_at))))
    received_at timestamptz NOT NULL,

    -- Thời gian hiệu lực chung của envelope theo time_basis, là authority để point event_at khớp cùng mốc.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành ck_telemetry_time_basis: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên
    -- phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((((time_basis = 'DEVICE'::text) AND (observed_at IS NOT NULL) AND (effective_at = observed_at)) OR
    -- ((time_basis = 'SERVER'::text) AND (effective_at = received_at))))
    effective_at timestamptz NOT NULL,

    -- Nguồn thời gian hiệu lực DEVICE/SERVER: DEVICE dùng observed_at, SERVER dùng received_at theo envelope.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành ck_telemetry_time_basis: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên
    -- phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((((time_basis = 'DEVICE'::text) AND (observed_at IS NOT NULL) AND (effective_at = observed_at)) OR
    -- ((time_basis = 'SERVER'::text) AND (effective_at = received_at))))
    -- Ràng buộc hiện hành telemetry_envelopes_time_basis_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN
    -- vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((time_basis = ANY (ARRAY['DEVICE'::text, 'SERVER'::text])))
    time_basis text NOT NULL CHECK(time_basis IN ('DEVICE','SERVER')),

    -- Thứ tự tiếp nhận do server quản lý trong từng device, khác sequence trên wire của thiết bị.
    -- bigint: số nguyên có dấu 64 bit, phù hợp bộ đếm/generation tăng lâu dài; không tự tăng nếu chưa có cơ chế cấp
    -- giá trị.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành telemetry_envelopes_ingestion_sequence_check: CHECK chỉ chặn khi biểu thức là FALSE;
    -- NULL/UNKNOWN vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((ingestion_sequence > 0))
    ingestion_sequence bigint NOT NULL CHECK(ingestion_sequence>0),

    -- Số point dự kiến của envelope, từ 1 đến 10; deferred cardinality check ngăn commit gói thiếu/extra point.
    -- integer: số nguyên có dấu 32 bit; CHECK giới hạn miền nghiệp vụ thay vì chỉ dựa phạm vi kiểu.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành telemetry_envelopes_point_count_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN
    -- vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK (((point_count >= 1) AND (point_count <= 10)))
    point_count integer NOT NULL CHECK(point_count BETWEEN 1 AND 10),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    PRIMARY KEY(workspace_id,envelope_id),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    UNIQUE(workspace_id,device_id,boot_id,message_id),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    UNIQUE(workspace_id,envelope_id,device_id),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,device_id,boot_id,message_id) REFERENCES telemetry_receipts,

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    CONSTRAINT ck_telemetry_time_basis CHECK((time_basis='DEVICE' AND observed_at IS NOT NULL AND effective_at=observed_at) OR (time_basis='SERVER' AND effective_at=received_at))
);
/* Truy vấn lịch sử theo tenant/device rồi mốc ingest; receipt giữ riêng tính duy nhất. */
CREATE INDEX ix_telemetry_envelopes_device ON telemetry_envelopes(workspace_id,device_id,ingestion_sequence);
-- Bảng telemetry_points: Các mẫu typed trong một envelope, mỗi stream xuất hiện tối đa một lần. Device và thời
-- gian được lặp có chủ đích cho query lịch sử, phải khớp authority ở envelope.
CREATE TABLE telemetry_points (
    -- Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền
    -- của người gọi.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành telemetry_points_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì uniqueness
    -- áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, envelope_id, point_index)
    -- Ràng buộc hiện hành telemetry_points_workspace_id_envelope_id_device_id_fkey: khóa ngoại giữ đúng bản ghi cha;
    -- tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, envelope_id, device_id) REFERENCES telemetry_envelopes(workspace_id, envelope_id,
    -- device_id)
    -- Ràng buộc hiện hành telemetry_points_workspace_id_envelope_id_stream_key_key: không trùng tổ hợp giá trị được
    -- nêu; các cột riêng lẻ vẫn có thể lặp khi khóa có nhiều cột.
    -- UNIQUE (workspace_id, envelope_id, stream_key)
    workspace_id uuid NOT NULL,

    -- Identity raw envelope trong workspace để liên kết các point; receipt tự nhiên vẫn tồn tại khi raw envelope bị
    -- purge.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành telemetry_points_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì uniqueness
    -- áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, envelope_id, point_index)
    -- Ràng buộc hiện hành telemetry_points_workspace_id_envelope_id_device_id_fkey: khóa ngoại giữ đúng bản ghi cha;
    -- tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, envelope_id, device_id) REFERENCES telemetry_envelopes(workspace_id, envelope_id,
    -- device_id)
    -- Ràng buộc hiện hành telemetry_points_workspace_id_envelope_id_stream_key_key: không trùng tổ hợp giá trị được
    -- nêu; các cột riêng lẻ vẫn có thể lặp khi khóa có nhiều cột.
    -- UNIQUE (workspace_id, envelope_id, stream_key)
    envelope_id uuid NOT NULL,

    -- Vị trí point trong envelope, bắt đầu 0 và tối đa 9; khác stream_key dùng kiểm trùng kênh.
    -- integer: số nguyên có dấu 32 bit; CHECK giới hạn miền nghiệp vụ thay vì chỉ dựa phạm vi kiểu.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành telemetry_points_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì uniqueness
    -- áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, envelope_id, point_index)
    -- Ràng buộc hiện hành telemetry_points_point_index_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn
    -- qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK (((point_index >= 0) AND (point_index <= 9)))
    point_index integer NOT NULL CHECK(point_index BETWEEN 0 AND 9),

    -- Identity thiết bị toàn cục để resolve MQTT và registry; kết hợp workspace_id bảo vệ mọi tham chiếu trong đúng
    -- tenant.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành telemetry_points_workspace_id_envelope_id_device_id_fkey: khóa ngoại giữ đúng bản ghi cha;
    -- tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, envelope_id, device_id) REFERENCES telemetry_envelopes(workspace_id, envelope_id,
    -- device_id)
    device_id uuid NOT NULL,

    -- Khóa kỹ thuật ổn định của kênh trong template/version; không dùng nhãn hiển thị thay khóa schema.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành telemetry_points_workspace_id_envelope_id_stream_key_key: không trùng tổ hợp giá trị được
    -- nêu; các cột riêng lẻ vẫn có thể lặp khi khóa có nhiều cột.
    -- UNIQUE (workspace_id, envelope_id, stream_key)
    stream_key text NOT NULL,

    -- Bản sao observed_at của envelope để phục vụ lịch sử; so khớp null-safe, không phải per-point timestamp độc lập
    -- từ wire.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    observed_at timestamptz,

    -- Thời gian dùng query point, phải bằng envelope.effective_at; được lặp để phục vụ index lịch sử theo stream.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    event_at timestamptz NOT NULL,

    -- Chất lượng mẫu GOOD/NULL/SERVER_TIME; quality NULL biểu diễn mẫu null, không là giá trị số 0 và không tự quyết
    -- định time_basis.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành ck_telemetry_point_value: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên
    -- phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((((quality = 'NULL'::text) AND (num_nonnulls(numeric_value, boolean_value, text_value) = 0)) OR ((quality
    -- <> 'NULL'::text) AND (num_nonnulls(numeric_value, boolean_value, text_value) = 1) AND (((value_type =
    -- 'NUMBER'::text) AND (numeric_value IS NOT NULL)) OR ((value_type = 'BOOLEAN'::text) AND (boolean_value IS NOT
    -- NULL)) OR ((value_type = 'STRING'::text) AND (text_value IS NOT NULL)) OR ((value_type = 'ENUM'::text) AND
    -- ((numeric_value IS NOT NULL) OR (text_value IS NOT NULL)))))))
    -- Ràng buộc hiện hành telemetry_points_quality_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua,
    -- nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((quality = ANY (ARRAY['GOOD'::text, 'NULL'::text, 'SERVER_TIME'::text])))
    quality text NOT NULL CHECK(quality IN ('GOOD','NULL','SERVER_TIME')),

    -- Nhánh kiểu dữ liệu của giá trị được lưu; XOR chọn đúng cột numeric/boolean/text và phải khớp pinned definition.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành ck_telemetry_point_value: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên
    -- phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((((quality = 'NULL'::text) AND (num_nonnulls(numeric_value, boolean_value, text_value) = 0)) OR ((quality
    -- <> 'NULL'::text) AND (num_nonnulls(numeric_value, boolean_value, text_value) = 1) AND (((value_type =
    -- 'NUMBER'::text) AND (numeric_value IS NOT NULL)) OR ((value_type = 'BOOLEAN'::text) AND (boolean_value IS NOT
    -- NULL)) OR ((value_type = 'STRING'::text) AND (text_value IS NOT NULL)) OR ((value_type = 'ENUM'::text) AND
    -- ((numeric_value IS NOT NULL) OR (text_value IS NOT NULL)))))))
    -- Ràng buộc hiện hành telemetry_points_value_type_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn
    -- qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((value_type = ANY (ARRAY['NUMBER'::text, 'BOOLEAN'::text, 'STRING'::text, 'ENUM'::text])))
    value_type text NOT NULL CHECK(value_type IN ('NUMBER','BOOLEAN','STRING','ENUM')),

    -- Giá trị số hữu hạn của nhánh NUMBER hoặc ENUM số; NULL khi dùng nhánh giá trị khác hoặc quality NULL.
    -- double precision: số thực dấu phẩy động 64 bit, có sai số biểu diễn; kiểm finite/range theo CHECK và validator.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    -- Ràng buộc hiện hành ck_telemetry_point_value: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên
    -- phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((((quality = 'NULL'::text) AND (num_nonnulls(numeric_value, boolean_value, text_value) = 0)) OR ((quality
    -- <> 'NULL'::text) AND (num_nonnulls(numeric_value, boolean_value, text_value) = 1) AND (((value_type =
    -- 'NUMBER'::text) AND (numeric_value IS NOT NULL)) OR ((value_type = 'BOOLEAN'::text) AND (boolean_value IS NOT
    -- NULL)) OR ((value_type = 'STRING'::text) AND (text_value IS NOT NULL)) OR ((value_type = 'ENUM'::text) AND
    -- ((numeric_value IS NOT NULL) OR (text_value IS NOT NULL)))))))
    -- Ràng buộc hiện hành telemetry_points_numeric_value_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN
    -- vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK (((numeric_value IS NULL) OR ((numeric_value > '-Infinity'::double precision) AND (numeric_value <
    -- 'Infinity'::double precision))))
    numeric_value double precision,

    -- Giá trị boolean của nhánh BOOLEAN; false là dữ liệu thật, không tương đương NULL/missing.
    -- boolean: cờ logic true/false; NULL là trạng thái riêng nếu cột cho phép.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    -- Ràng buộc hiện hành ck_telemetry_point_value: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên
    -- phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((((quality = 'NULL'::text) AND (num_nonnulls(numeric_value, boolean_value, text_value) = 0)) OR ((quality
    -- <> 'NULL'::text) AND (num_nonnulls(numeric_value, boolean_value, text_value) = 1) AND (((value_type =
    -- 'NUMBER'::text) AND (numeric_value IS NOT NULL)) OR ((value_type = 'BOOLEAN'::text) AND (boolean_value IS NOT
    -- NULL)) OR ((value_type = 'STRING'::text) AND (text_value IS NOT NULL)) OR ((value_type = 'ENUM'::text) AND
    -- ((numeric_value IS NOT NULL) OR (text_value IS NOT NULL)))))))
    boolean_value boolean,

    -- Giá trị chuỗi của nhánh STRING hoặc ENUM chuỗi; không chuyển mọi datatype thành text để bỏ kiểm kiểu.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    -- Ràng buộc hiện hành ck_telemetry_point_value: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên
    -- phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((((quality = 'NULL'::text) AND (num_nonnulls(numeric_value, boolean_value, text_value) = 0)) OR ((quality
    -- <> 'NULL'::text) AND (num_nonnulls(numeric_value, boolean_value, text_value) = 1) AND (((value_type =
    -- 'NUMBER'::text) AND (numeric_value IS NOT NULL)) OR ((value_type = 'BOOLEAN'::text) AND (boolean_value IS NOT
    -- NULL)) OR ((value_type = 'STRING'::text) AND (text_value IS NOT NULL)) OR ((value_type = 'ENUM'::text) AND
    -- ((numeric_value IS NOT NULL) OR (text_value IS NOT NULL)))))))
    text_value text,

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    PRIMARY KEY(workspace_id,envelope_id,point_index),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    UNIQUE(workspace_id,envelope_id,stream_key),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,envelope_id,device_id) REFERENCES telemetry_envelopes(workspace_id,envelope_id,device_id),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    CONSTRAINT ck_telemetry_point_value CHECK(
  (quality='NULL' AND num_nonnulls(numeric_value,boolean_value,text_value)=0) OR
  (quality<>'NULL' AND num_nonnulls(numeric_value,boolean_value,text_value)=1 AND
   ((value_type='NUMBER' AND numeric_value IS NOT NULL) OR (value_type='BOOLEAN' AND boolean_value IS NOT NULL) OR
    (value_type='STRING' AND text_value IS NOT NULL) OR (value_type='ENUM' AND (numeric_value IS NOT NULL OR text_value IS NOT NULL))))),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    CHECK(numeric_value IS NULL OR (numeric_value>'-Infinity'::float8 AND numeric_value<'Infinity'::float8))
);
/* Projection device/time theo Core33; trigger0007 kiểm null-safe với envelope authority. */
CREATE INDEX ix_telemetry_points_history ON telemetry_points(workspace_id,device_id,stream_key,event_at DESC,envelope_id);
-- Bảng device_latest_values: Projection mẫu mới nhất của từng kênh phục vụ giao diện và rule. Giữ marker đủ điều
-- kiện riêng để mẫu NULL/stale mới không bị thay bằng GOOD cũ khi điều khiển.
CREATE TABLE device_latest_values (
    -- Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền
    -- của người gọi.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành device_latest_values_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, device_id, stream_key)
    -- Ràng buộc hiện hành device_latest_values_workspace_id_device_id_template_versi_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, device_id, template_version_id) REFERENCES devices(workspace_id, device_id,
    -- template_version_id)
    -- Ràng buộc hiện hành device_latest_values_workspace_id_template_version_id_stre_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, template_version_id, stream_key) REFERENCES datastream_definitions(workspace_id,
    -- template_version_id, stream_key)
    workspace_id uuid NOT NULL,

    -- Identity thiết bị toàn cục để resolve MQTT và registry; kết hợp workspace_id bảo vệ mọi tham chiếu trong đúng
    -- tenant.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành device_latest_values_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, device_id, stream_key)
    -- Ràng buộc hiện hành device_latest_values_workspace_id_device_id_template_versi_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, device_id, template_version_id) REFERENCES devices(workspace_id, device_id,
    -- template_version_id)
    device_id uuid NOT NULL,

    -- Identity snapshot template cụ thể, dùng pin schema và kiểm đúng definition trong workspace.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành device_latest_values_workspace_id_device_id_template_versi_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, device_id, template_version_id) REFERENCES devices(workspace_id, device_id,
    -- template_version_id)
    -- Ràng buộc hiện hành device_latest_values_workspace_id_template_version_id_stre_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, template_version_id, stream_key) REFERENCES datastream_definitions(workspace_id,
    -- template_version_id, stream_key)
    template_version_id uuid NOT NULL,

    -- Khóa kỹ thuật ổn định của kênh trong template/version; không dùng nhãn hiển thị thay khóa schema.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành device_latest_values_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, device_id, stream_key)
    -- Ràng buộc hiện hành device_latest_values_workspace_id_template_version_id_stre_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, template_version_id, stream_key) REFERENCES datastream_definitions(workspace_id,
    -- template_version_id, stream_key)
    stream_key text NOT NULL,

    -- Marker server của mẫu mới nhất được projection chấp nhận; không được lùi khi message đến sai thứ tự.
    -- bigint: số nguyên có dấu 64 bit, phù hợp bộ đếm/generation tăng lâu dài; không tự tăng nếu chưa có cơ chế cấp
    -- giá trị.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành ck_latest_rule_current_marker: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua,
    -- nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK (((rule_eligible_marker_sequence IS NULL) OR (rule_eligible_marker_sequence = latest_marker_sequence)))
    -- Ràng buộc hiện hành device_latest_values_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên
    -- phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK (((rule_eligible_marker_sequence IS NULL) OR (rule_eligible_marker_sequence <= latest_marker_sequence)))
    -- Ràng buộc hiện hành device_latest_values_latest_marker_sequence_check: CHECK chỉ chặn khi biểu thức là FALSE;
    -- NULL/UNKNOWN vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((latest_marker_sequence > 0))
    latest_marker_sequence bigint NOT NULL CHECK(latest_marker_sequence>0),

    -- Mốc server nhận mẫu đang làm latest; không được lùi, không thay observed/effective time của dữ liệu gốc.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    latest_received_at timestamptz NOT NULL,

    -- Snapshot giá trị mới nhất cho hiển thị, có thể NULL/không đủ điều kiện rule; không mặc định fallback GOOD cũ.
    -- jsonb: tài liệu JSON lưu dạng nhị phân; kiểm object/scalar không thay validation đầy đủ cấu trúc và tham chiếu
    -- nghiệp vụ.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    latest_value jsonb,

    -- Marker của mẫu hiện hành đủ điều kiện rule, phải bằng latest marker nếu có; NULL nghĩa không có giá trị rule đủ
    -- điều kiện.
    -- bigint: số nguyên có dấu 64 bit, phù hợp bộ đếm/generation tăng lâu dài; không tự tăng nếu chưa có cơ chế cấp
    -- giá trị.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    -- Ràng buộc hiện hành ck_latest_rule_current_marker: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua,
    -- nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK (((rule_eligible_marker_sequence IS NULL) OR (rule_eligible_marker_sequence = latest_marker_sequence)))
    -- Ràng buộc hiện hành ck_latest_rule_value_shape: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên
    -- phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((((rule_eligible_marker_sequence IS NULL) = (rule_value IS NULL)) AND ((rule_value IS NULL) OR
    -- (rule_value <> 'null'::jsonb))))
    -- Ràng buộc hiện hành device_latest_values_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên
    -- phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK (((rule_eligible_marker_sequence IS NULL) OR (rule_eligible_marker_sequence <= latest_marker_sequence)))
    -- Ràng buộc hiện hành device_latest_values_rule_eligible_marker_sequence_check: CHECK chỉ chặn khi biểu thức là
    -- FALSE; NULL/UNKNOWN vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((rule_eligible_marker_sequence > 0))
    rule_eligible_marker_sequence bigint CHECK(rule_eligible_marker_sequence>0),

    -- Giá trị của đúng eligible marker hiện hành để rule dùng; NULL khi marker mới không đủ điều kiện, không giữ GOOD
    -- cũ làm authority.
    -- jsonb: tài liệu JSON lưu dạng nhị phân; kiểm object/scalar không thay validation đầy đủ cấu trúc và tham chiếu
    -- nghiệp vụ.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    -- Ràng buộc hiện hành ck_latest_rule_value_shape: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên
    -- phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((((rule_eligible_marker_sequence IS NULL) = (rule_value IS NULL)) AND ((rule_value IS NULL) OR
    -- (rule_value <> 'null'::jsonb))))
    rule_value jsonb,

    -- Lý do latest được/không được dùng cho rule, giúp giải thích NULL/stale/server-time thay vì đoán từ giá trị.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    eligibility_reason text NOT NULL,

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    PRIMARY KEY(workspace_id,device_id,stream_key),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,device_id,template_version_id) REFERENCES devices(workspace_id,device_id,template_version_id),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,template_version_id,stream_key) REFERENCES datastream_definitions,

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    CHECK(rule_eligible_marker_sequence IS NULL OR rule_eligible_marker_sequence<=latest_marker_sequence)
);
