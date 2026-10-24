/* Bản chú thích để đọc: ràng buộc hiện hành lấy từ manifest sau mọi forward migration.
 * Runner thực thi byte bất biến trong applied_sql và so token SQL với bản này; không sửa ledger.
 */
/* OTA và integration đóng các typed FK API key còn chờ0003/0004.
 * Không verify chữ ký, gửi HTTP hoặc flash phần cứng trong migration; raw bytes giữ authority.
 */
-- Bảng firmware_upload_attempts: Mỗi lần upload/verify firmware, kể cả lần lỗi. Tách khỏi canonical package để chữ
-- ký sai đầu tiên không chiếm identity digest của artifact hợp lệ.
CREATE TABLE firmware_upload_attempts (
    -- Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền
    -- của người gọi.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành firmware_upload_attempts_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, firmware_upload_attempt_id)
    -- Ràng buộc hiện hành firmware_upload_attempts_workspace_id_actor_user_id_fkey: khóa ngoại giữ đúng bản ghi cha;
    -- tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, actor_user_id) REFERENCES memberships(workspace_id, user_id)
    workspace_id uuid NOT NULL,

    -- Identity một lượt upload/verify, kể cả reject; không là canonical package identity.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành firmware_upload_attempts_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, firmware_upload_attempt_id)
    firmware_upload_attempt_id uuid NOT NULL,

    -- Tài khoản thực hiện hoặc khởi tạo thao tác, phục vụ kiểm quyền và truy vết; không lấy authority chỉ từ ID client
    -- gửi.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành firmware_upload_attempts_workspace_id_actor_user_id_fkey: khóa ngoại giữ đúng bản ghi cha;
    -- tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, actor_user_id) REFERENCES memberships(workspace_id, user_id)
    actor_user_id uuid NOT NULL,

    -- SHA-256 32 byte của artifact firmware, dùng identity nội dung và kiểm binary khớp manifest.
    -- bytea: dãy byte nhị phân; tên digest/ciphertext mô tả mục đích, bản thân kiểu không băm hoặc mã hóa dữ liệu.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    -- Ràng buộc hiện hành firmware_upload_attempts_artifact_digest_check: CHECK chỉ chặn khi biểu thức là FALSE;
    -- NULL/UNKNOWN vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((octet_length(artifact_digest) = 32))
    artifact_digest bytea CHECK(octet_length(artifact_digest)=32),

    -- Locator blob upload tạm còn cần verify/cleanup, khác artifact canonical đã được package/job tham chiếu.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    temporary_artifact_reference text,

    -- Kết quả lượt upload UPLOADED/VERIFIED/REJECTED; lần reject không chiếm canonical package identity.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành firmware_upload_attempts_state_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN
    -- vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((state = ANY (ARRAY['UPLOADED'::text, 'VERIFIED'::text, 'REJECTED'::text])))
    state text NOT NULL CHECK(state IN ('UPLOADED','VERIFIED','REJECTED')),

    -- Nguyên nhân thất bại đã chuẩn hóa/redact cho vận hành và lịch sử; không lưu response bí mật của dịch vụ ngoài.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    failure_reason text,

    -- Thời điểm tạo bản ghi dưới dạng timestamptz; dùng provenance/sắp xếp hoặc retention khi policy của bảng quy
    -- định.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành firmware_upload_attempts_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua,
    -- nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((expires_at = (created_at + '24:00:00'::interval)))
    created_at timestamptz NOT NULL,

    -- Mốc created_at + 24 giờ cho artifact upload tạm theo policy; cleanup vẫn phải kiểm reference/lease còn hoạt
    -- động.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành firmware_upload_attempts_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua,
    -- nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((expires_at = (created_at + '24:00:00'::interval)))
    expires_at timestamptz NOT NULL,

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    PRIMARY KEY(workspace_id,firmware_upload_attempt_id),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,actor_user_id) REFERENCES memberships,

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    CHECK(expires_at=created_at+interval '24 hours')
);
/* Chỉ package đã qua validator đi vào canonical identity; bad upload không chiếm digest. */
-- Bảng firmware_packages: Metadata package firmware đã được validator xác minh, giữ exact signed manifest bytes và
-- chữ ký. Binary nằm ở artifact store; nhãn VERIFIED trong SQL không tự thực hiện kiểm chữ ký.
CREATE TABLE firmware_packages (
    -- Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền
    -- của người gọi.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành firmware_packages_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì uniqueness
    -- áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, firmware_package_id)
    -- Ràng buộc hiện hành firmware_packages_workspace_id_artifact_digest_key: không trùng tổ hợp giá trị được nêu; các
    -- cột riêng lẻ vẫn có thể lặp khi khóa có nhiều cột.
    -- UNIQUE (workspace_id, artifact_digest)
    -- Ràng buộc hiện hành firmware_packages_workspace_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ hợp có workspace_id
    -- giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id) REFERENCES workspaces(workspace_id)
    workspace_id uuid NOT NULL REFERENCES workspaces,

    -- Identity canonical package firmware trong workspace, dùng liên kết compatibility và OTA jobs.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành firmware_packages_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì uniqueness
    -- áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, firmware_package_id)
    firmware_package_id uuid NOT NULL,

    -- SHA-256 32 byte của artifact firmware, dùng identity nội dung và kiểm binary khớp manifest.
    -- bytea: dãy byte nhị phân; tên digest/ciphertext mô tả mục đích, bản thân kiểu không băm hoặc mã hóa dữ liệu.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành firmware_packages_artifact_digest_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN
    -- vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((octet_length(artifact_digest) = 32))
    -- Ràng buộc hiện hành firmware_packages_workspace_id_artifact_digest_key: không trùng tổ hợp giá trị được nêu; các
    -- cột riêng lẻ vẫn có thể lặp khi khóa có nhiều cột.
    -- UNIQUE (workspace_id, artifact_digest)
    artifact_digest bytea NOT NULL CHECK(octet_length(artifact_digest)=32),

    -- Exact signed manifest bytes làm authority kiểm chữ ký; không dựng lại từ các cột parsed rồi giả là cùng signed
    -- bytes.
    -- bytea: dãy byte nhị phân; tên digest/ciphertext mô tả mục đích, bản thân kiểu không băm hoặc mã hóa dữ liệu.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành firmware_packages_raw_manifest_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN
    -- vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((octet_length(raw_manifest) > 0))
    raw_manifest bytea NOT NULL CHECK(octet_length(raw_manifest)>0),

    -- Bytes chữ ký của exact raw_manifest theo thuật toán trong trust profile; SQL chỉ lưu bytes, validator phải kiểm
    -- chữ ký.
    -- bytea: dãy byte nhị phân; tên digest/ciphertext mô tả mục đích, bản thân kiểu không băm hoặc mã hóa dữ liệu.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành firmware_packages_signature_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn
    -- qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((octet_length(signature) > 0))
    signature bytea NOT NULL CHECK(octet_length(signature)>0),

    -- Locator artifact trong kho đã duyệt, không là arbitrary URL cho client điều khiển hoặc private signing key.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành firmware_packages_artifact_reference_check: CHECK chỉ chặn khi biểu thức là FALSE;
    -- NULL/UNKNOWN vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((btrim(artifact_reference) <> ''::text))
    artifact_reference text NOT NULL CHECK(btrim(artifact_reference)<>''),

    -- Kích thước binary firmware tính bằng byte, dùng kiểm manifest, giới hạn download và khả năng chứa image của
    -- board.
    -- bigint: số nguyên có dấu 64 bit, phù hợp bộ đếm/generation tăng lâu dài; không tự tăng nếu chưa có cơ chế cấp
    -- giá trị.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành firmware_packages_artifact_size_bytes_check: CHECK chỉ chặn khi biểu thức là FALSE;
    -- NULL/UNKNOWN vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((artifact_size_bytes > 0))
    artifact_size_bytes bigint NOT NULL CHECK(artifact_size_bytes>0),

    -- Fingerprint SHA-256 32 byte của khóa ký được tin cậy, phục vụ audit/provenance chữ ký firmware.
    -- bytea: dãy byte nhị phân; tên digest/ciphertext mô tả mục đích, bản thân kiểu không băm hoặc mã hóa dữ liệu.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành firmware_packages_signing_key_fingerprint_check: CHECK chỉ chặn khi biểu thức là FALSE;
    -- NULL/UNKNOWN vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((octet_length(signing_key_fingerprint) = 32))
    signing_key_fingerprint bytea NOT NULL CHECK(octet_length(signing_key_fingerprint)=32),

    -- Định danh khóa ký public/trust profile dùng kiểm firmware manifest; không lưu private signing key.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    signing_key_identifier text NOT NULL,

    -- Phiên bản cấu trúc signed manifest, hiện 1; khác firmware version hoặc revision package.
    -- integer: số nguyên có dấu 32 bit; CHECK giới hạn miền nghiệp vụ thay vì chỉ dựa phạm vi kiểu.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành firmware_packages_manifest_schema_version_check: CHECK chỉ chặn khi biểu thức là FALSE;
    -- NULL/UNKNOWN vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((manifest_schema_version = 1))
    manifest_schema_version integer NOT NULL CHECK(manifest_schema_version=1),

    -- Model board được signed manifest khai hỗ trợ; validator đối chiếu với device trước OTA.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    board_model text NOT NULL,

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
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    firmware_version text NOT NULL,

    -- Định danh build firmware trong manifest, dùng truy vết artifact/toolchain; không thay artifact digest.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    build_identifier text NOT NULL,

    -- Nhãn package đã đi qua validator, bảng canonical hiện chỉ VERIFIED; không tự chứng minh chữ ký đúng chỉ nhờ
    -- INSERT giá trị này.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành firmware_packages_validation_state_check: CHECK chỉ chặn khi biểu thức là FALSE;
    -- NULL/UNKNOWN vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((validation_state = 'VERIFIED'::text))
    validation_state text NOT NULL CHECK(validation_state='VERIFIED'),

    -- Thời điểm tạo bản ghi dưới dạng timestamptz; dùng provenance/sắp xếp hoặc retention khi policy của bảng quy
    -- định.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    created_at timestamptz NOT NULL,

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    PRIMARY KEY(workspace_id,firmware_package_id),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    UNIQUE(workspace_id,artifact_digest)
);
-- Bảng firmware_package_templates: Tập template version được package khai tương thích trong signed manifest. Giữ
-- FK tới version cụ thể, không suy compatibility từ tên hoặc template root.
CREATE TABLE firmware_package_templates (
    -- Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền
    -- của người gọi.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành firmware_package_templates_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, firmware_package_id, template_version_id)
    -- Ràng buộc hiện hành firmware_package_templates_workspace_id_firmware_package_i_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, firmware_package_id) REFERENCES firmware_packages(workspace_id, firmware_package_id)
    -- Ràng buộc hiện hành firmware_package_templates_workspace_id_template_version_i_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, template_version_id) REFERENCES template_versions(workspace_id, template_version_id)
    workspace_id uuid NOT NULL,

    -- Identity canonical package firmware trong workspace, dùng liên kết compatibility và OTA jobs.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành firmware_package_templates_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, firmware_package_id, template_version_id)
    -- Ràng buộc hiện hành firmware_package_templates_workspace_id_firmware_package_i_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, firmware_package_id) REFERENCES firmware_packages(workspace_id, firmware_package_id)
    firmware_package_id uuid NOT NULL,

    -- Identity snapshot template cụ thể, dùng pin schema và kiểm đúng definition trong workspace.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành firmware_package_templates_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, firmware_package_id, template_version_id)
    -- Ràng buộc hiện hành firmware_package_templates_workspace_id_template_version_i_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, template_version_id) REFERENCES template_versions(workspace_id, template_version_id)
    template_version_id uuid NOT NULL,

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    PRIMARY KEY(workspace_id,firmware_package_id,template_version_id),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,firmware_package_id) REFERENCES firmware_packages,

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,template_version_id) REFERENCES template_versions
);
-- Bảng ota_jobs: Ý định OTA một thiết bị, chụp firmware nguồn/đích, nonce và maintenance epoch. RECOVERY_REQUIRED
-- tiếp tục giữ slot cho tới settlement có đối soát; timeout không là proof rollback.
CREATE TABLE ota_jobs (
    -- Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền
    -- của người gọi.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành ota_jobs_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì uniqueness áp dụng
    -- cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, ota_job_id)
    -- Ràng buộc hiện hành ota_jobs_workspace_id_device_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ hợp có
    -- workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, device_id) REFERENCES devices(workspace_id, device_id)
    -- Ràng buộc hiện hành ota_jobs_workspace_id_firmware_package_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ hợp có
    -- workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, firmware_package_id) REFERENCES firmware_packages(workspace_id, firmware_package_id)
    -- Ràng buộc hiện hành ota_jobs_workspace_id_ota_job_id_device_id_key: không trùng tổ hợp giá trị được nêu; các cột
    -- riêng lẻ vẫn có thể lặp khi khóa có nhiều cột.
    -- UNIQUE (workspace_id, ota_job_id, device_id)
    workspace_id uuid NOT NULL,

    -- Identity ý định OTA ổn định qua status/probe/recovery, dùng gắn nonce, artifact và maintenance epoch.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành ota_jobs_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì uniqueness áp dụng
    -- cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, ota_job_id)
    -- Ràng buộc hiện hành ota_jobs_workspace_id_ota_job_id_device_id_key: không trùng tổ hợp giá trị được nêu; các cột
    -- riêng lẻ vẫn có thể lặp khi khóa có nhiều cột.
    -- UNIQUE (workspace_id, ota_job_id, device_id)
    ota_job_id uuid NOT NULL,

    -- Identity thiết bị toàn cục để resolve MQTT và registry; kết hợp workspace_id bảo vệ mọi tham chiếu trong đúng
    -- tenant.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành ota_jobs_workspace_id_device_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ hợp có
    -- workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, device_id) REFERENCES devices(workspace_id, device_id)
    -- Ràng buộc hiện hành ota_jobs_workspace_id_ota_job_id_device_id_key: không trùng tổ hợp giá trị được nêu; các cột
    -- riêng lẻ vẫn có thể lặp khi khóa có nhiều cột.
    -- UNIQUE (workspace_id, ota_job_id, device_id)
    device_id uuid NOT NULL,

    -- Identity canonical package firmware trong workspace, dùng liên kết compatibility và OTA jobs.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành ota_jobs_workspace_id_firmware_package_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ hợp có
    -- workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, firmware_package_id) REFERENCES firmware_packages(workspace_id, firmware_package_id)
    firmware_package_id uuid NOT NULL,

    -- Firmware nguồn được chụp lúc OTA admission để đối soát upgrade/rollback sau reboot.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    source_firmware_version_snapshot text NOT NULL,

    -- SHA-256 image đích được chụp khi nhận OTA, không đổi theo package/config hiện tại.
    -- bytea: dãy byte nhị phân; tên digest/ciphertext mô tả mục đích, bản thân kiểu không băm hoặc mã hóa dữ liệu.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành ota_jobs_target_artifact_digest_snapshot_check: CHECK chỉ chặn khi biểu thức là FALSE;
    -- NULL/UNKNOWN vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((octet_length(target_artifact_digest_snapshot) = 32))
    target_artifact_digest_snapshot bytea NOT NULL CHECK(octet_length(target_artifact_digest_snapshot)=32),

    -- Nonce 32 byte gắn ý định OTA, giúp board/backend phân biệt job cũ và bằng chứng của lần update khác.
    -- bytea: dãy byte nhị phân; tên digest/ciphertext mô tả mục đích, bản thân kiểu không băm hoặc mã hóa dữ liệu.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành ota_jobs_job_nonce_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên
    -- phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((octet_length(job_nonce) = 32))
    job_nonce bytea NOT NULL CHECK(octet_length(job_nonce)=32),

    -- Vòng đời OTA từ QUEUED tới dispatch/download/verify/reboot/health và terminal hoặc RECOVERY_REQUIRED; recovery
    -- vẫn giữ slot.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành ota_jobs_check1: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên phải phối
    -- hợp NOT NULL và CHECK shape khi cần.
    -- CHECK (((state <> 'RECOVERY_REQUIRED'::text) OR (settled_at IS NULL)))
    -- Ràng buộc hiện hành ota_jobs_state_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên phải
    -- phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((state = ANY (ARRAY['QUEUED'::text, 'DISPATCHING'::text, 'ACCEPTED'::text, 'DOWNLOADING'::text,
    -- 'VERIFYING'::text, 'REBOOTING'::text, 'HEALTH_CHECK'::text, 'SUCCEEDED'::text, 'FAILED'::text,
    -- 'CANCELLED'::text, 'ROLLED_BACK'::text, 'RECOVERY_REQUIRED'::text])))
    state text NOT NULL CHECK(state IN ('QUEUED','DISPATCHING','ACCEPTED','DOWNLOADING','VERIFYING','REBOOTING','HEALTH_CHECK','SUCCEEDED','FAILED','CANCELLED','ROLLED_BACK','RECOVERY_REQUIRED')),

    -- Pha kỹ thuật OTA hiện được job/status báo; khác state điều phối và phải được validator/worker kiểm theo
    -- protocol.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    phase text NOT NULL,

    -- Thế hệ khóa bảo trì, dùng phân biệt OTA/dispatch đang hiện hành với callback cũ; không reset do reconnect.
    -- bigint: số nguyên có dấu 64 bit, phù hợp bộ đếm/generation tăng lâu dài; không tự tăng nếu chưa có cơ chế cấp
    -- giá trị.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành ota_jobs_maintenance_epoch_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn
    -- qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((maintenance_epoch > 0))
    maintenance_epoch bigint NOT NULL CHECK(maintenance_epoch>0),

    -- Thời điểm yêu cầu được backend nhận vào ledger sau kiểm điều kiện; không chứng minh side effect đã thực hiện.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành ota_jobs_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên phải phối
    -- hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((deadline_at = (admitted_at + '00:10:00'::interval)))
    admitted_at timestamptz NOT NULL,

    -- Deadline admitted_at + 10 phút của ý định OTA; hết deadline không tự settlement nếu chưa biết image/board state.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành ota_jobs_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên phải phối
    -- hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((deadline_at = (admitted_at + '00:10:00'::interval)))
    deadline_at timestamptz NOT NULL,

    -- Thời điểm ghi ý định gửi START OTA trước network; có thể đã gửi khi mất ACK, không blind resend chỉ vì thiếu
    -- reply.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    start_intent_at timestamptz,

    -- Thời điểm nghĩa vụ vận hành được đối soát xong và có thể nhả guard/quota; NULL tiếp tục giữ nghĩa vụ chưa giải
    -- quyết.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    -- Ràng buộc hiện hành ota_jobs_check1: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên phải phối
    -- hợp NOT NULL và CHECK shape khi cần.
    -- CHECK (((state <> 'RECOVERY_REQUIRED'::text) OR (settled_at IS NULL)))
    settled_at timestamptz,

    -- Lý do cần recovery/đối soát OTA đã redact; không tự giải phóng maintenance hoặc kết luận rollback.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    recovery_reason text,

    -- Boot tham gia recovery được xác minh theo protocol; NULL khi chưa có bằng chứng boot phục hồi.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    recovery_boot_id text,

    -- Thời điểm backend hoàn tất bước đối soát recovery, khác deadline và thời điểm board reboot.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    reconciled_at timestamptz,

    -- Phiên bản chỉnh sửa bản ghi dùng cho CAS/If-Match hoặc đối soát; bên ghi chịu trách nhiệm cập nhật theo đúng
    -- transaction contract.
    -- bigint: số nguyên có dấu 64 bit, phù hợp bộ đếm/generation tăng lâu dài; không tự tăng nếu chưa có cơ chế cấp
    -- giá trị.
    -- NOT NULL: bắt buộc có giá trị.
    -- DEFAULT 1: giá trị dùng khi INSERT bỏ qua cột; không thay NULL được truyền tường minh và không tự áp lại khi
    -- UPDATE.
    -- Ràng buộc hiện hành ota_jobs_revision_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên
    -- phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((revision > 0))
    revision bigint NOT NULL DEFAULT 1 CHECK(revision>0),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    PRIMARY KEY(workspace_id,ota_job_id),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    UNIQUE(workspace_id,ota_job_id,device_id),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,device_id) REFERENCES devices(workspace_id,device_id),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,firmware_package_id) REFERENCES firmware_packages,

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    CHECK(deadline_at=admitted_at+interval '10 minutes'),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    CHECK(state<>'RECOVERY_REQUIRED' OR settled_at IS NULL)
);
/* Chỉ settlement có proof giải phóng quota; timeout/recovery vẫn giữ cả workspace/device. */
CREATE UNIQUE INDEX uq_ota_jobs_active_workspace ON ota_jobs(workspace_id) WHERE settled_at IS NULL;
CREATE UNIQUE INDEX uq_ota_jobs_active_device ON ota_jobs(workspace_id,device_id) WHERE settled_at IS NULL;
-- Bảng ota_download_tickets: Bearer ticket tải artifact cho một OTA job. Lưu digest và expiry không vượt deadline
-- job; không coi ticket là device proof-of-possession.
CREATE TABLE ota_download_tickets (
    -- Identity quản lý bearer ticket, không phải secret; ticket_digest dùng xác minh/consume.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành ota_download_tickets_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (ticket_id)
    ticket_id uuid PRIMARY KEY,

    -- Digest SHA-256 32 byte của bearer ticket, dùng lookup/consume hoặc tải artifact; raw ticket chỉ được trả qua
    -- kênh admission.
    -- bytea: dãy byte nhị phân; tên digest/ciphertext mô tả mục đích, bản thân kiểu không băm hoặc mã hóa dữ liệu.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành ota_download_tickets_ticket_digest_check: CHECK chỉ chặn khi biểu thức là FALSE;
    -- NULL/UNKNOWN vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((octet_length(ticket_digest) = 32))
    -- Ràng buộc hiện hành ota_download_tickets_ticket_digest_key: không trùng tổ hợp giá trị được nêu; các cột riêng
    -- lẻ vẫn có thể lặp khi khóa có nhiều cột.
    -- UNIQUE (ticket_digest)
    ticket_digest bytea NOT NULL UNIQUE CHECK(octet_length(ticket_digest)=32),

    -- Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền
    -- của người gọi.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành ota_download_tickets_workspace_id_ota_job_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ hợp
    -- có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, ota_job_id) REFERENCES ota_jobs(workspace_id, ota_job_id)
    workspace_id uuid NOT NULL,

    -- Identity ý định OTA ổn định qua status/probe/recovery, dùng gắn nonce, artifact và maintenance epoch.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành ota_download_tickets_workspace_id_ota_job_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ hợp
    -- có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, ota_job_id) REFERENCES ota_jobs(workspace_id, ota_job_id)
    ota_job_id uuid NOT NULL,

    -- Thời điểm phát hành phiên/grant/credential/ticket, làm gốc tính TTL theo loại bản ghi.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành ota_download_tickets_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên
    -- phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((expires_at > issued_at))
    issued_at timestamptz NOT NULL,

    -- Hạn bearer download ticket phải sau issued_at và không vượt deadline của OTA job; không reset khi tải lại.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành ota_download_tickets_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên
    -- phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((expires_at > issued_at))
    expires_at timestamptz NOT NULL,

    -- Thời điểm thu hồi quyền/credential; NULL nghĩa chưa ghi nhận thu hồi, không đồng nghĩa mọi điều kiện xác thực
    -- khác còn hợp lệ.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    revoked_at timestamptz,

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,ota_job_id) REFERENCES ota_jobs,

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    CHECK(expires_at>issued_at)
);
-- Bảng ota_status_receipts: Status OTA được xác thực theo job/device/boot/credential và sequence. Digest phục vụ
-- dedupe hoặc phát hiện cùng sequence khác body, không ghi đè status đã nhận.
CREATE TABLE ota_status_receipts (
    -- Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền
    -- của người gọi.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành ota_status_receipts_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, ota_job_id, status_sequence)
    -- Ràng buộc hiện hành ota_status_receipts_workspace_id_device_id_boot_id_credent_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, device_id, boot_id, credential_generation) REFERENCES
    -- device_boot_sessions(workspace_id, device_id, boot_id, credential_generation)
    -- Ràng buộc hiện hành ota_status_receipts_workspace_id_ota_job_id_device_id_fkey: khóa ngoại giữ đúng bản ghi cha;
    -- tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, ota_job_id, device_id) REFERENCES ota_jobs(workspace_id, ota_job_id, device_id)
    workspace_id uuid NOT NULL,

    -- Identity ý định OTA ổn định qua status/probe/recovery, dùng gắn nonce, artifact và maintenance epoch.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành ota_status_receipts_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, ota_job_id, status_sequence)
    -- Ràng buộc hiện hành ota_status_receipts_workspace_id_ota_job_id_device_id_fkey: khóa ngoại giữ đúng bản ghi cha;
    -- tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, ota_job_id, device_id) REFERENCES ota_jobs(workspace_id, ota_job_id, device_id)
    ota_job_id uuid NOT NULL,

    -- Sequence uint32 của status OTA, từ 0 đến 4294967295; cùng sequence khác digest phải được đối soát, không last-
    -- write-wins.
    -- bigint: số nguyên có dấu 64 bit, phù hợp bộ đếm/generation tăng lâu dài; không tự tăng nếu chưa có cơ chế cấp
    -- giá trị.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành ota_status_receipts_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, ota_job_id, status_sequence)
    -- Ràng buộc hiện hành ota_status_receipts_status_sequence_check: CHECK chỉ chặn khi biểu thức là FALSE;
    -- NULL/UNKNOWN vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK (((status_sequence >= 0) AND (status_sequence <= '4294967295'::bigint)))
    status_sequence bigint NOT NULL CHECK(status_sequence BETWEEN 0 AND 4294967295),

    -- Identity thiết bị toàn cục để resolve MQTT và registry; kết hợp workspace_id bảo vệ mọi tham chiếu trong đúng
    -- tenant.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành ota_status_receipts_workspace_id_device_id_boot_id_credent_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, device_id, boot_id, credential_generation) REFERENCES
    -- device_boot_sessions(workspace_id, device_id, boot_id, credential_generation)
    -- Ràng buộc hiện hành ota_status_receipts_workspace_id_ota_job_id_device_id_fkey: khóa ngoại giữ đúng bản ghi cha;
    -- tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, ota_job_id, device_id) REFERENCES ota_jobs(workspace_id, ota_job_id, device_id)
    device_id uuid NOT NULL,

    -- SHA-256 32 byte của payload đã chấp nhận, phục vụ dedupe và phát hiện cùng identity nhưng body mâu thuẫn.
    -- bytea: dãy byte nhị phân; tên digest/ciphertext mô tả mục đích, bản thân kiểu không băm hoặc mã hóa dữ liệu.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành ota_status_receipts_payload_digest_check: CHECK chỉ chặn khi biểu thức là FALSE;
    -- NULL/UNKNOWN vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((octet_length(payload_digest) = 32))
    payload_digest bytea NOT NULL CHECK(octet_length(payload_digest)=32),

    -- Identity boot của thiết bị theo wire dạng text, không suy UUID; chỉ chấp nhận khi gắn với credential/connection
    -- đã xác minh.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành ota_status_receipts_workspace_id_device_id_boot_id_credent_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, device_id, boot_id, credential_generation) REFERENCES
    -- device_boot_sessions(workspace_id, device_id, boot_id, credential_generation)
    boot_id text NOT NULL,

    -- Thế hệ credential MQTT của thiết bị, phân biệt lần cấp mới với credential cũ đã thu hồi.
    -- bigint: số nguyên có dấu 64 bit, phù hợp bộ đếm/generation tăng lâu dài; không tự tăng nếu chưa có cơ chế cấp
    -- giá trị.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành ota_status_receipts_workspace_id_device_id_boot_id_credent_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, device_id, boot_id, credential_generation) REFERENCES
    -- device_boot_sessions(workspace_id, device_id, boot_id, credential_generation)
    credential_generation bigint NOT NULL,

    -- Pha kỹ thuật OTA hiện được job/status báo; khác state điều phối và phải được validator/worker kiểm theo
    -- protocol.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    phase text NOT NULL,

    -- Thời điểm server nhận gói dữ liệu/kết quả; phân biệt với observed_at do thiết bị hoặc nguồn sự kiện cung cấp.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    received_at timestamptz NOT NULL,

    -- Payload quan sát đã được producer loại trường nhạy cảm, dùng audit/đối soát; SQL JSON type không tự làm
    -- redaction.
    -- jsonb: tài liệu JSON lưu dạng nhị phân; kiểm object/scalar không thay validation đầy đủ cấu trúc và tham chiếu
    -- nghiệp vụ.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    sanitized_payload jsonb NOT NULL,

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    PRIMARY KEY(workspace_id,ota_job_id,status_sequence),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,ota_job_id,device_id) REFERENCES ota_jobs(workspace_id,ota_job_id,device_id),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,device_id,boot_id,credential_generation) REFERENCES device_boot_sessions(workspace_id,device_id,boot_id,credential_generation)
);
-- Bảng ota_probe_intents: Ngân sách probe bền vững theo job/recovery epoch. Mỗi ý định probe có request identity
-- để restart không reset budget hoặc tự phát lại START OTA.
CREATE TABLE ota_probe_intents (
    -- Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền
    -- của người gọi.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành ota_probe_intents_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì uniqueness
    -- áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, ota_job_id, recovery_epoch, probe_number)
    -- Ràng buộc hiện hành ota_probe_intents_workspace_id_ota_job_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ hợp có
    -- workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, ota_job_id) REFERENCES ota_jobs(workspace_id, ota_job_id)
    workspace_id uuid NOT NULL,

    -- Identity ý định OTA ổn định qua status/probe/recovery, dùng gắn nonce, artifact và maintenance epoch.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành ota_probe_intents_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì uniqueness
    -- áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, ota_job_id, recovery_epoch, probe_number)
    -- Ràng buộc hiện hành ota_probe_intents_workspace_id_ota_job_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ hợp có
    -- workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, ota_job_id) REFERENCES ota_jobs(workspace_id, ota_job_id)
    ota_job_id uuid NOT NULL,

    -- Thế hệ một đợt recovery/probe của job để ngân sách probe không bị dùng lại sau restart.
    -- bigint: số nguyên có dấu 64 bit, phù hợp bộ đếm/generation tăng lâu dài; không tự tăng nếu chưa có cơ chế cấp
    -- giá trị.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành ota_probe_intents_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì uniqueness
    -- áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, ota_job_id, recovery_epoch, probe_number)
    -- Ràng buộc hiện hành ota_probe_intents_recovery_epoch_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN
    -- vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((recovery_epoch > 0))
    recovery_epoch bigint NOT NULL CHECK(recovery_epoch>0),

    -- Số thứ tự probe trong một recovery epoch, từ 1 đến 3; không reset để vượt budget bằng retry.
    -- integer: số nguyên có dấu 32 bit; CHECK giới hạn miền nghiệp vụ thay vì chỉ dựa phạm vi kiểu.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành ota_probe_intents_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì uniqueness
    -- áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, ota_job_id, recovery_epoch, probe_number)
    -- Ràng buộc hiện hành ota_probe_intents_probe_number_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN
    -- vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK (((probe_number >= 1) AND (probe_number <= 3)))
    probe_number integer NOT NULL CHECK(probe_number BETWEEN 1 AND 3),

    -- Identity duy nhất của probe request, dùng ghép reply với đúng ý định gửi.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành ota_probe_intents_request_id_key: không trùng tổ hợp giá trị được nêu; các cột riêng lẻ vẫn
    -- có thể lặp khi khóa có nhiều cột.
    -- UNIQUE (request_id)
    request_id uuid NOT NULL UNIQUE,

    -- Thời điểm ghi ý định probe OTA trước network call, dùng giữ budget bền vững qua restart.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    intended_at timestamptz NOT NULL,

    -- Thời điểm adapter ghi nhận đã gửi probe; NULL khi chưa có xác nhận gửi, không mặc định nghĩa là chắc chắn chưa
    -- gửi.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    sent_at timestamptz,

    -- Thời điểm server ghi nhận reply probe, dùng giải thích kết quả recovery và deadline.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    reply_at timestamptz,

    -- Digest 32 byte của reply probe nhận được, phục vụ đối soát cùng request mà không lưu nội dung bí mật.
    -- bytea: dãy byte nhị phân; tên digest/ciphertext mô tả mục đích, bản thân kiểu không băm hoặc mã hóa dữ liệu.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    -- Ràng buộc hiện hành ota_probe_intents_reply_digest_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN
    -- vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((octet_length(reply_digest) = 32))
    reply_digest bytea CHECK(octet_length(reply_digest)=32),

    -- Trạng thái probe INTENT/SENT/REPLIED/UNKNOWN; missing reply không cho reset budget hoặc suy đã rollback.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành ota_probe_intents_state_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua,
    -- nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((state = ANY (ARRAY['INTENT'::text, 'SENT'::text, 'REPLIED'::text, 'UNKNOWN'::text])))
    state text NOT NULL CHECK(state IN ('INTENT','SENT','REPLIED','UNKNOWN')),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    PRIMARY KEY(workspace_id,ota_job_id,recovery_epoch,probe_number),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,ota_job_id) REFERENCES ota_jobs
);
/* API credential chỉ có keyId.secret nên keyId phải unique toàn cục trước resolve tenant. */
-- Bảng api_keys: Principal API key có lookup ID toàn cục nhưng quyền chỉ trong một workspace. Chụp grant của
-- owner, lưu protected verifier/expiry/revocation; không lưu raw secret để đọc lại.
CREATE TABLE api_keys (
    -- Identity principal API key toàn cục, dùng resolve workspace trước kiểm quyền; không chứa raw key secret.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành api_keys_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì uniqueness áp dụng
    -- cho cả tổ hợp.
    -- PRIMARY KEY (api_key_id)
    -- Ràng buộc hiện hành api_keys_workspace_id_api_key_id_key: không trùng tổ hợp giá trị được nêu; các cột riêng lẻ
    -- vẫn có thể lặp khi khóa có nhiều cột.
    -- UNIQUE (workspace_id, api_key_id)
    api_key_id uuid PRIMARY KEY,

    -- Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền
    -- của người gọi.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành api_keys_workspace_id_api_key_id_key: không trùng tổ hợp giá trị được nêu; các cột riêng lẻ
    -- vẫn có thể lặp khi khóa có nhiều cột.
    -- UNIQUE (workspace_id, api_key_id)
    -- Ràng buộc hiện hành api_keys_workspace_id_owner_user_id_owner_grant_generation_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, owner_user_id, owner_grant_generation) REFERENCES membership_grants(workspace_id,
    -- user_id, grant_generation)
    workspace_id uuid NOT NULL,

    -- Tài khoản sở hữu tài nguyên trong workspace; backend phải kiểm membership và quyền hiện hành khi đọc/ghi.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành api_keys_workspace_id_owner_user_id_owner_grant_generation_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, owner_user_id, owner_grant_generation) REFERENCES membership_grants(workspace_id,
    -- user_id, grant_generation)
    owner_user_id uuid NOT NULL,

    -- Grant owner được chụp khi cấp API key; request sau này phải giao với quyền/grant hiện hành.
    -- bigint: số nguyên có dấu 64 bit, phù hợp bộ đếm/generation tăng lâu dài; không tự tăng nếu chưa có cơ chế cấp
    -- giá trị.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành api_keys_workspace_id_owner_user_id_owner_grant_generation_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, owner_user_id, owner_grant_generation) REFERENCES membership_grants(workspace_id,
    -- user_id, grant_generation)
    owner_grant_generation bigint NOT NULL,

    -- Bộ kiểm chứng mật 32 byte dùng xác thực credential/API key theo protected-verifier contract; không là raw secret
    -- và không trả client/log.
    -- bytea: dãy byte nhị phân; tên digest/ciphertext mô tả mục đích, bản thân kiểu không băm hoặc mã hóa dữ liệu.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành api_keys_verifier_digest_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua,
    -- nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((octet_length(verifier_digest) = 32))
    -- Ràng buộc hiện hành api_keys_verifier_digest_key: không trùng tổ hợp giá trị được nêu; các cột riêng lẻ vẫn có
    -- thể lặp khi khóa có nhiều cột.
    -- UNIQUE (verifier_digest)
    verifier_digest bytea NOT NULL UNIQUE CHECK(octet_length(verifier_digest)=32),

    -- Tên hiển thị do người dùng đặt cho tài nguyên; không dùng làm identity, quyền hoặc khóa chống lặp.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    name text NOT NULL,

    -- Phần nhận diện không nhạy cảm của API key để hiển thị/quản trị; không đủ xác thực và không thay secret.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    prefix text NOT NULL,

    -- Thời điểm phát hành phiên/grant/credential/ticket, làm gốc tính TTL theo loại bản ghi.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành ck_api_keys_fixed_duration_ttl: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua,
    -- nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK (((expires_at >= (issued_at + '24:00:00'::interval)) AND (expires_at <= (issued_at +
    -- '2160:00:00'::interval))))
    issued_at timestamptz NOT NULL,

    -- Deadline API key theo admission policy 1..90 ngày, một ngày=86400 giây theo contract; backend phải validate
    -- input trước issue.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành ck_api_keys_fixed_duration_ttl: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua,
    -- nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK (((expires_at >= (issued_at + '24:00:00'::interval)) AND (expires_at <= (issued_at +
    -- '2160:00:00'::interval))))
    expires_at timestamptz NOT NULL,

    -- Thời điểm thu hồi quyền/credential; NULL nghĩa chưa ghi nhận thu hồi, không đồng nghĩa mọi điều kiện xác thực
    -- khác còn hợp lệ.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    revoked_at timestamptz,

    -- Mốc request hợp lệ gần nhất được key chấp nhận theo policy; update đến trễ không được làm lùi mốc hoặc hồi sinh
    -- key revoked.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    last_used_at timestamptz,

    -- Phiên bản chỉnh sửa bản ghi dùng cho CAS/If-Match hoặc đối soát; bên ghi chịu trách nhiệm cập nhật theo đúng
    -- transaction contract.
    -- bigint: số nguyên có dấu 64 bit, phù hợp bộ đếm/generation tăng lâu dài; không tự tăng nếu chưa có cơ chế cấp
    -- giá trị.
    -- NOT NULL: bắt buộc có giá trị.
    -- DEFAULT 1: giá trị dùng khi INSERT bỏ qua cột; không thay NULL được truyền tường minh và không tự áp lại khi
    -- UPDATE.
    -- Ràng buộc hiện hành api_keys_revision_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên
    -- phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((revision > 0))
    revision bigint NOT NULL DEFAULT 1 CHECK(revision>0),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    UNIQUE(workspace_id,api_key_id),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,owner_user_id,owner_grant_generation) REFERENCES membership_grants,

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    CHECK(expires_at>=issued_at+interval '1 day' AND expires_at<=issued_at+interval '90 days')
);
-- Bảng api_key_devices: Allowlist thiết bị được API key cấp quyền, tối đa 5 theo admission policy. Đây là tập độc
-- lập với scopes, không lưu tích Descartes device×permission.
CREATE TABLE api_key_devices (
    -- Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền
    -- của người gọi.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành api_key_devices_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì uniqueness áp
    -- dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, api_key_id, device_id)
    -- Ràng buộc hiện hành api_key_devices_workspace_id_api_key_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ hợp có
    -- workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, api_key_id) REFERENCES api_keys(workspace_id, api_key_id)
    -- Ràng buộc hiện hành api_key_devices_workspace_id_device_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ hợp có
    -- workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, device_id) REFERENCES devices(workspace_id, device_id)
    workspace_id uuid NOT NULL,

    -- Identity principal API key toàn cục, dùng resolve workspace trước kiểm quyền; không chứa raw key secret.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành api_key_devices_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì uniqueness áp
    -- dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, api_key_id, device_id)
    -- Ràng buộc hiện hành api_key_devices_workspace_id_api_key_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ hợp có
    -- workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, api_key_id) REFERENCES api_keys(workspace_id, api_key_id)
    api_key_id uuid NOT NULL,

    -- Identity thiết bị toàn cục để resolve MQTT và registry; kết hợp workspace_id bảo vệ mọi tham chiếu trong đúng
    -- tenant.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành api_key_devices_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì uniqueness áp
    -- dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, api_key_id, device_id)
    -- Ràng buộc hiện hành api_key_devices_workspace_id_device_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ hợp có
    -- workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, device_id) REFERENCES devices(workspace_id, device_id)
    device_id uuid NOT NULL,

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    PRIMARY KEY(workspace_id,api_key_id,device_id),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,api_key_id) REFERENCES api_keys(workspace_id,api_key_id),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,device_id) REFERENCES devices(workspace_id,device_id)
);
-- Bảng api_key_scopes: Các permission được cấp cho API key theo allowlist scope code. Không suy thêm quyền quản
-- trị từ scope đọc telemetry hoặc điều khiển thiết bị.
CREATE TABLE api_key_scopes (
    -- Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền
    -- của người gọi.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành api_key_scopes_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì uniqueness áp
    -- dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, api_key_id, scope_code)
    -- Ràng buộc hiện hành api_key_scopes_workspace_id_api_key_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ hợp có
    -- workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, api_key_id) REFERENCES api_keys(workspace_id, api_key_id)
    workspace_id uuid NOT NULL,

    -- Identity principal API key toàn cục, dùng resolve workspace trước kiểm quyền; không chứa raw key secret.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành api_key_scopes_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì uniqueness áp
    -- dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, api_key_id, scope_code)
    -- Ràng buộc hiện hành api_key_scopes_workspace_id_api_key_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ hợp có
    -- workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, api_key_id) REFERENCES api_keys(workspace_id, api_key_id)
    api_key_id uuid NOT NULL,

    -- Permission API key từ allowlist devices:read/telemetry:read/commands:write; không chứa quyền admin ngầm định.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành api_key_scopes_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì uniqueness áp
    -- dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, api_key_id, scope_code)
    -- Ràng buộc hiện hành api_key_scopes_scope_code_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn
    -- qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((scope_code = ANY (ARRAY['devices:read'::text, 'telemetry:read'::text, 'commands:write'::text])))
    scope_code text NOT NULL CHECK(scope_code IN ('devices:read','telemetry:read','commands:write')),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    PRIMARY KEY(workspace_id,api_key_id,scope_code),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,api_key_id) REFERENCES api_keys(workspace_id,api_key_id)
);
ALTER TABLE commands ADD CONSTRAINT fk_commands_api_key FOREIGN KEY(workspace_id,api_key_id) REFERENCES api_keys(workspace_id,api_key_id);
ALTER TABLE workspace_idempotency_records ADD CONSTRAINT fk_idempotency_api_key FOREIGN KEY(workspace_id,api_key_id) REFERENCES api_keys(workspace_id,api_key_id);
ALTER TABLE rate_limit_admissions ADD CONSTRAINT fk_rate_limit_api_key FOREIGN KEY(workspace_id,api_key_id) REFERENCES api_keys(workspace_id,api_key_id);
-- Bảng webhook_subscriptions: Cấu hình đích webhook, owner, trạng thái endpoint verification và active secret
-- version. Revision endpoint khác secret version để đổi URL không được hưởng kết quả verify của URL cũ.
CREATE TABLE webhook_subscriptions (
    -- Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền
    -- của người gọi.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành fk_webhook_active_secret: khóa ngoại giữ đúng bản ghi cha; tổ hợp có workspace_id giữ quan
    -- hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, webhook_subscription_id, active_secret_version) REFERENCES
    -- webhook_secret_versions(workspace_id, webhook_subscription_id, secret_version) DEFERRABLE INITIALLY DEFERRED
    -- Ràng buộc hiện hành webhook_subscriptions_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, webhook_subscription_id)
    -- Ràng buộc hiện hành webhook_subscriptions_workspace_id_owner_user_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ
    -- hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, owner_user_id) REFERENCES memberships(workspace_id, user_id)
    workspace_id uuid NOT NULL,

    -- Identity cấu hình webhook trong workspace, dùng nhóm filter, secret versions và lịch sử delivery.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành fk_webhook_active_secret: khóa ngoại giữ đúng bản ghi cha; tổ hợp có workspace_id giữ quan
    -- hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, webhook_subscription_id, active_secret_version) REFERENCES
    -- webhook_secret_versions(workspace_id, webhook_subscription_id, secret_version) DEFERRABLE INITIALLY DEFERRED
    -- Ràng buộc hiện hành webhook_subscriptions_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, webhook_subscription_id)
    webhook_subscription_id uuid NOT NULL,

    -- Tài khoản sở hữu tài nguyên trong workspace; backend phải kiểm membership và quyền hiện hành khi đọc/ghi.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành webhook_subscriptions_workspace_id_owner_user_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ
    -- hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, owner_user_id) REFERENCES memberships(workspace_id, user_id)
    owner_user_id uuid NOT NULL,

    -- URL HTTPS của webhook subscription; lớp outbound còn phải kiểm DNS/IP/redirect chống SSRF mỗi lần gửi.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành webhook_subscriptions_endpoint_url_check: CHECK chỉ chặn khi biểu thức là FALSE;
    -- NULL/UNKNOWN vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((endpoint_url ~~ 'https://%'::text))
    endpoint_url text NOT NULL CHECK(endpoint_url LIKE 'https://%'),

    -- Phiên bản endpoint URL hiện hành; đổi URL phải làm verify cũ không còn hiệu lực.
    -- bigint: số nguyên có dấu 64 bit, phù hợp bộ đếm/generation tăng lâu dài; không tự tăng nếu chưa có cơ chế cấp
    -- giá trị.
    -- NOT NULL: bắt buộc có giá trị.
    -- DEFAULT 1: giá trị dùng khi INSERT bỏ qua cột; không thay NULL được truyền tường minh và không tự áp lại khi
    -- UPDATE.
    -- Ràng buộc hiện hành webhook_subscriptions_check1: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua,
    -- nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK (((verified_endpoint_revision IS NULL) OR (verified_endpoint_revision = endpoint_revision)))
    -- Ràng buộc hiện hành webhook_subscriptions_endpoint_revision_check: CHECK chỉ chặn khi biểu thức là FALSE;
    -- NULL/UNKNOWN vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((endpoint_revision > 0))
    endpoint_revision bigint NOT NULL DEFAULT 1 CHECK(endpoint_revision>0),

    -- Endpoint revision đã được xác minh, phải trùng endpoint_revision hiện hành nếu có; NULL khi chưa có verify hợp
    -- lệ.
    -- bigint: số nguyên có dấu 64 bit, phù hợp bộ đếm/generation tăng lâu dài; không tự tăng nếu chưa có cơ chế cấp
    -- giá trị.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    -- Ràng buộc hiện hành webhook_subscriptions_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua,
    -- nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK (((verified_endpoint_revision IS NULL) = (verified_at IS NULL)))
    -- Ràng buộc hiện hành webhook_subscriptions_check1: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua,
    -- nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK (((verified_endpoint_revision IS NULL) OR (verified_endpoint_revision = endpoint_revision)))
    -- Ràng buộc hiện hành webhook_subscriptions_check2: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua,
    -- nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK (((lifecycle_status <> 'ACTIVE'::text) OR (verified_endpoint_revision IS NOT NULL)))
    verified_endpoint_revision bigint,

    -- Thời điểm xác minh endpoint revision hiện hành; không dùng lại cho URL mới hoặc coi như quyền SSRF vĩnh viễn.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    -- Ràng buộc hiện hành webhook_subscriptions_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua,
    -- nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK (((verified_endpoint_revision IS NULL) = (verified_at IS NULL)))
    verified_at timestamptz,

    -- Phiên bản chỉnh sửa bản ghi dùng cho CAS/If-Match hoặc đối soát; bên ghi chịu trách nhiệm cập nhật theo đúng
    -- transaction contract.
    -- bigint: số nguyên có dấu 64 bit, phù hợp bộ đếm/generation tăng lâu dài; không tự tăng nếu chưa có cơ chế cấp
    -- giá trị.
    -- NOT NULL: bắt buộc có giá trị.
    -- DEFAULT 1: giá trị dùng khi INSERT bỏ qua cột; không thay NULL được truyền tường minh và không tự áp lại khi
    -- UPDATE.
    -- Ràng buộc hiện hành webhook_subscriptions_revision_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN
    -- vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((revision > 0))
    revision bigint NOT NULL DEFAULT 1 CHECK(revision>0),

    -- Trạng thái vòng đời quản lý tài nguyên, tách khỏi presence hoặc tiến độ của job đang chạy.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành webhook_subscriptions_check2: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua,
    -- nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK (((lifecycle_status <> 'ACTIVE'::text) OR (verified_endpoint_revision IS NOT NULL)))
    -- Ràng buộc hiện hành webhook_subscriptions_lifecycle_status_check: CHECK chỉ chặn khi biểu thức là FALSE;
    -- NULL/UNKNOWN vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((lifecycle_status = ANY (ARRAY['ACTIVE'::text, 'PAUSED'::text, 'REVOKED'::text])))
    lifecycle_status text NOT NULL CHECK(lifecycle_status IN ('ACTIVE','PAUSED','REVOKED')),

    -- Con trỏ secret version hiện hành của đúng subscription; delivery cũ vẫn giữ version snapshot riêng.
    -- bigint: số nguyên có dấu 64 bit, phù hợp bộ đếm/generation tăng lâu dài; không tự tăng nếu chưa có cơ chế cấp
    -- giá trị.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành fk_webhook_active_secret: khóa ngoại giữ đúng bản ghi cha; tổ hợp có workspace_id giữ quan
    -- hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, webhook_subscription_id, active_secret_version) REFERENCES
    -- webhook_secret_versions(workspace_id, webhook_subscription_id, secret_version) DEFERRABLE INITIALLY DEFERRED
    -- Ràng buộc hiện hành webhook_subscriptions_active_secret_version_check: CHECK chỉ chặn khi biểu thức là FALSE;
    -- NULL/UNKNOWN vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((active_secret_version > 0))
    active_secret_version bigint NOT NULL CHECK(active_secret_version>0),

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
    PRIMARY KEY(workspace_id,webhook_subscription_id),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,owner_user_id) REFERENCES memberships,

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    CHECK((verified_endpoint_revision IS NULL)=(verified_at IS NULL)),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    CHECK(verified_endpoint_revision IS NULL OR verified_endpoint_revision=endpoint_revision),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    CHECK(lifecycle_status<>'ACTIVE' OR verified_endpoint_revision IS NOT NULL)
);
-- Bảng webhook_subscription_devices: Bộ lọc thiết bị của webhook subscription trong cùng workspace. Quyền hiện
-- hành vẫn phải được kiểm tại fanout/send, không chỉ dựa vào FK tồn tại.
CREATE TABLE webhook_subscription_devices (
    -- Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền
    -- của người gọi.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành webhook_subscription_devices_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, webhook_subscription_id, device_id)
    -- Ràng buộc hiện hành webhook_subscription_devices_workspace_id_device_id_fkey: khóa ngoại giữ đúng bản ghi cha;
    -- tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, device_id) REFERENCES devices(workspace_id, device_id)
    -- Ràng buộc hiện hành webhook_subscription_devices_workspace_id_webhook_subscrip_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, webhook_subscription_id) REFERENCES webhook_subscriptions(workspace_id,
    -- webhook_subscription_id)
    workspace_id uuid NOT NULL,

    -- Identity cấu hình webhook trong workspace, dùng nhóm filter, secret versions và lịch sử delivery.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành webhook_subscription_devices_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, webhook_subscription_id, device_id)
    -- Ràng buộc hiện hành webhook_subscription_devices_workspace_id_webhook_subscrip_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, webhook_subscription_id) REFERENCES webhook_subscriptions(workspace_id,
    -- webhook_subscription_id)
    webhook_subscription_id uuid NOT NULL,

    -- Identity thiết bị toàn cục để resolve MQTT và registry; kết hợp workspace_id bảo vệ mọi tham chiếu trong đúng
    -- tenant.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành webhook_subscription_devices_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, webhook_subscription_id, device_id)
    -- Ràng buộc hiện hành webhook_subscription_devices_workspace_id_device_id_fkey: khóa ngoại giữ đúng bản ghi cha;
    -- tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, device_id) REFERENCES devices(workspace_id, device_id)
    device_id uuid NOT NULL,

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    PRIMARY KEY(workspace_id,webhook_subscription_id,device_id),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,webhook_subscription_id) REFERENCES webhook_subscriptions,

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,device_id) REFERENCES devices(workspace_id,device_id)
);
-- Bảng webhook_subscription_events: Các loại BUSINESS event mà subscription muốn nhận. Tách relation có CHECK
-- allowlist, không lưu mảng chuỗi làm nguồn quyền/fanout.
CREATE TABLE webhook_subscription_events (
    -- Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền
    -- của người gọi.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành webhook_subscription_events_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, webhook_subscription_id, event_type)
    -- Ràng buộc hiện hành webhook_subscription_events_workspace_id_webhook_subscript_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, webhook_subscription_id) REFERENCES webhook_subscriptions(workspace_id,
    -- webhook_subscription_id)
    workspace_id uuid NOT NULL,

    -- Identity cấu hình webhook trong workspace, dùng nhóm filter, secret versions và lịch sử delivery.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành webhook_subscription_events_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, webhook_subscription_id, event_type)
    -- Ràng buộc hiện hành webhook_subscription_events_workspace_id_webhook_subscript_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, webhook_subscription_id) REFERENCES webhook_subscriptions(workspace_id,
    -- webhook_subscription_id)
    webhook_subscription_id uuid NOT NULL,

    -- Loại sự kiện được audit/outbox/webhook sử dụng; ý nghĩa/allowlist phụ thuộc bảng và schema contract.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành webhook_subscription_events_event_type_check: CHECK chỉ chặn khi biểu thức là FALSE;
    -- NULL/UNKNOWN vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((event_type = ANY (ARRAY['event.opened'::text, 'event.resolved'::text, 'command.completed'::text,
    -- 'device.connectivity'::text])))
    -- Ràng buộc hiện hành webhook_subscription_events_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, webhook_subscription_id, event_type)
    event_type text NOT NULL CHECK(event_type IN ('event.opened','event.resolved','command.completed','device.connectivity')),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    PRIMARY KEY(workspace_id,webhook_subscription_id,event_type),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,webhook_subscription_id) REFERENCES webhook_subscriptions
);
/* Có thể purge ciphertext sau nghĩa vụ gửi, giữ metadata version để FK lịch sử không đứt. */
-- Bảng webhook_secret_versions: Từng generation secret ký webhook, lưu ciphertext và wrapping key reference. Giữ
-- version còn được delivery tham chiếu; metadata có thể tồn tại sau khi ciphertext được purge theo policy.
CREATE TABLE webhook_secret_versions (
    -- Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền
    -- của người gọi.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành webhook_secret_versions_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, webhook_subscription_id, secret_version)
    -- Ràng buộc hiện hành webhook_secret_versions_workspace_id_webhook_subscription__fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, webhook_subscription_id) REFERENCES webhook_subscriptions(workspace_id,
    -- webhook_subscription_id)
    workspace_id uuid NOT NULL,

    -- Identity cấu hình webhook trong workspace, dùng nhóm filter, secret versions và lịch sử delivery.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành webhook_secret_versions_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, webhook_subscription_id, secret_version)
    -- Ràng buộc hiện hành webhook_secret_versions_workspace_id_webhook_subscription__fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, webhook_subscription_id) REFERENCES webhook_subscriptions(workspace_id,
    -- webhook_subscription_id)
    webhook_subscription_id uuid NOT NULL,

    -- Thế hệ secret ký webhook trong một subscription; khác endpoint_revision và được delivery giữ cố định khi retry.
    -- bigint: số nguyên có dấu 64 bit, phù hợp bộ đếm/generation tăng lâu dài; không tự tăng nếu chưa có cơ chế cấp
    -- giá trị.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành webhook_secret_versions_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, webhook_subscription_id, secret_version)
    -- Ràng buộc hiện hành webhook_secret_versions_secret_version_check: CHECK chỉ chặn khi biểu thức là FALSE;
    -- NULL/UNKNOWN vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((secret_version > 0))
    secret_version bigint NOT NULL CHECK(secret_version>0),

    -- Secret recoverable đã mã hóa cho escrow/ký webhook; key wrapping nằm ngoài DB và chỉ đường ghi có custody được
    -- dùng giá trị này.
    -- bytea: dãy byte nhị phân; tên digest/ciphertext mô tả mục đích, bản thân kiểu không băm hoặc mã hóa dữ liệu.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    -- Ràng buộc hiện hành webhook_secret_versions_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua,
    -- nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK (((secret_ciphertext IS NULL) = (encryption_key_reference IS NULL)))
    secret_ciphertext bytea,

    -- Tham chiếu/version của khóa dùng giải mã ciphertext, không chứa key material; NULL phải đồng bộ với nhánh không
    -- có ciphertext.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    -- Ràng buộc hiện hành webhook_secret_versions_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua,
    -- nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK (((secret_ciphertext IS NULL) = (encryption_key_reference IS NULL)))
    encryption_key_reference text,

    -- Thời điểm tạo bản ghi dưới dạng timestamptz; dùng provenance/sắp xếp hoặc retention khi policy của bảng quy
    -- định.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    created_at timestamptz NOT NULL,

    -- Thời điểm boot/secret version được retire; dữ liệu lịch sử và các nghĩa vụ còn tham chiếu có thể tiếp tục được
    -- giữ.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    retired_at timestamptz,

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    PRIMARY KEY(workspace_id,webhook_subscription_id,secret_version),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,webhook_subscription_id) REFERENCES webhook_subscriptions,

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    CHECK((secret_ciphertext IS NULL)=(encryption_key_reference IS NULL))
);
ALTER TABLE webhook_subscriptions ADD CONSTRAINT fk_webhook_active_secret FOREIGN KEY(workspace_id,webhook_subscription_id,active_secret_version) REFERENCES webhook_secret_versions DEFERRABLE INITIALLY DEFERRED;
-- Bảng webhook_deliveries: Nghĩa vụ giao occurrence tới subscription hoặc một lần TEST, với exact
-- body/endpoint/secret snapshot. Retry dùng cùng delivery identity và body, không dựng lại payload từ dữ liệu hiện
-- tại.
CREATE TABLE webhook_deliveries (
    -- Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền
    -- của người gọi.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành webhook_deliveries_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì uniqueness
    -- áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, webhook_delivery_id)
    -- Ràng buộc hiện hành webhook_deliveries_workspace_id_occurrence_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ hợp
    -- có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, occurrence_id) REFERENCES event_occurrences(workspace_id, occurrence_id)
    -- Ràng buộc hiện hành webhook_deliveries_workspace_id_webhook_subscription_id_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, webhook_subscription_id) REFERENCES webhook_subscriptions(workspace_id,
    -- webhook_subscription_id)
    -- Ràng buộc hiện hành webhook_deliveries_workspace_id_webhook_subscription_id_se_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, webhook_subscription_id, secret_version) REFERENCES
    -- webhook_secret_versions(workspace_id, webhook_subscription_id, secret_version)
    workspace_id uuid NOT NULL,

    -- Identity nghĩa vụ webhook giữ nguyên khi retry, để receiver dedupe ngay cả khi response bị mất.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành webhook_deliveries_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì uniqueness
    -- áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, webhook_delivery_id)
    webhook_delivery_id uuid NOT NULL,

    -- Identity cấu hình webhook trong workspace, dùng nhóm filter, secret versions và lịch sử delivery.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành webhook_deliveries_workspace_id_webhook_subscription_id_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, webhook_subscription_id) REFERENCES webhook_subscriptions(workspace_id,
    -- webhook_subscription_id)
    -- Ràng buộc hiện hành webhook_deliveries_workspace_id_webhook_subscription_id_se_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, webhook_subscription_id, secret_version) REFERENCES
    -- webhook_secret_versions(workspace_id, webhook_subscription_id, secret_version)
    webhook_subscription_id uuid NOT NULL,

    -- BUSINESS có occurrence nguồn và budget 6+6; TEST không có occurrence/Event giả, chỉ một lần gửi trong 30 giây.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành webhook_deliveries_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên
    -- phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((((kind = 'BUSINESS'::text) AND (occurrence_id IS NOT NULL)) OR ((kind = 'TEST'::text) AND (occurrence_id
    -- IS NULL) AND (manual_batch_count = 0))))
    -- Ràng buộc hiện hành webhook_deliveries_check2: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên
    -- phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK (((kind <> 'TEST'::text) OR (expires_at = (admitted_at + '00:00:30'::interval))))
    -- Ràng buộc hiện hành webhook_deliveries_kind_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua,
    -- nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((kind = ANY (ARRAY['BUSINESS'::text, 'TEST'::text])))
    kind text NOT NULL CHECK(kind IN ('BUSINESS','TEST')),

    -- Identity một transition đã commit; wire webhook eventId ánh xạ identity này, không gộp OPEN/RESOLVED thành một
    -- Event ID.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    -- Ràng buộc hiện hành webhook_deliveries_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên
    -- phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((((kind = 'BUSINESS'::text) AND (occurrence_id IS NOT NULL)) OR ((kind = 'TEST'::text) AND (occurrence_id
    -- IS NULL) AND (manual_batch_count = 0))))
    -- Ràng buộc hiện hành webhook_deliveries_workspace_id_occurrence_id_fkey: khóa ngoại giữ đúng bản ghi cha; tổ hợp
    -- có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành. FK MATCH SIMPLE mặc định bỏ kiểm
    -- khi có thành phần NULL; CHECK shape riêng vẫn phải đạt.
    -- FOREIGN KEY (workspace_id, occurrence_id) REFERENCES event_occurrences(workspace_id, occurrence_id)
    occurrence_id uuid,

    -- URL đích được chụp khi delivery admission; retry không tự đổi sang URL hiện hành khác.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    endpoint_url_snapshot text NOT NULL,

    -- Revision URL được delivery chụp, phục vụ recheck endpoint/fanout policy và giải thích lịch sử gửi.
    -- bigint: số nguyên có dấu 64 bit, phù hợp bộ đếm/generation tăng lâu dài; không tự tăng nếu chưa có cơ chế cấp
    -- giá trị.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành webhook_deliveries_endpoint_revision_snapshot_check: CHECK chỉ chặn khi biểu thức là FALSE;
    -- NULL/UNKNOWN vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((endpoint_revision_snapshot > 0))
    endpoint_revision_snapshot bigint NOT NULL CHECK(endpoint_revision_snapshot>0),

    -- Thế hệ secret ký webhook trong một subscription; khác endpoint_revision và được delivery giữ cố định khi retry.
    -- bigint: số nguyên có dấu 64 bit, phù hợp bộ đếm/generation tăng lâu dài; không tự tăng nếu chưa có cơ chế cấp
    -- giá trị.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành webhook_deliveries_workspace_id_webhook_subscription_id_se_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, webhook_subscription_id, secret_version) REFERENCES
    -- webhook_secret_versions(workspace_id, webhook_subscription_id, secret_version)
    secret_version bigint NOT NULL,

    -- Exact body bytes gửi webhook và ký HMAC, giữ nguyên khi retry/manual batch; không dựng lại từ live resource.
    -- bytea: dãy byte nhị phân; tên digest/ciphertext mô tả mục đích, bản thân kiểu không băm hoặc mã hóa dữ liệu.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    raw_body bytea NOT NULL,

    -- SHA-256 32 byte của exact raw_body webhook; producer tính trước gửi và giữ nguyên khi retry.
    -- bytea: dãy byte nhị phân; tên digest/ciphertext mô tả mục đích, bản thân kiểu không băm hoặc mã hóa dữ liệu.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành webhook_deliveries_body_digest_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN
    -- vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((octet_length(body_digest) = 32))
    body_digest bytea NOT NULL CHECK(octet_length(body_digest)=32),

    -- Tiến trình PENDING/SENDING/RETRY_WAIT hoặc ACCEPTED/FAILED/DEAD_LETTER/CANCELLED; DEAD_LETTER có thể mở đúng một
    -- manual batch đủ điều kiện.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- DEFAULT 'PENDING'::text: giá trị dùng khi INSERT bỏ qua cột; không thay NULL được truyền tường minh và không tự
    -- áp lại khi UPDATE.
    -- Ràng buộc hiện hành webhook_deliveries_state_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua,
    -- nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((state = ANY (ARRAY['PENDING'::text, 'SENDING'::text, 'RETRY_WAIT'::text, 'ACCEPTED'::text,
    -- 'FAILED'::text, 'DEAD_LETTER'::text, 'CANCELLED'::text])))
    state text NOT NULL DEFAULT 'PENDING' CHECK(state IN ('PENDING','SENDING','RETRY_WAIT','ACCEPTED','FAILED','DEAD_LETTER','CANCELLED')),

    -- Thời điểm yêu cầu được backend nhận vào ledger sau kiểm điều kiện; không chứng minh side effect đã thực hiện.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành webhook_deliveries_check1: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên
    -- phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((expires_at > admitted_at))
    -- Ràng buộc hiện hành webhook_deliveries_check2: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên
    -- phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK (((kind <> 'TEST'::text) OR (expires_at = (admitted_at + '00:00:30'::interval))))
    admitted_at timestamptz NOT NULL,

    -- BUSINESS neo occurrence.committed_at +24 giờ; TEST neo admitted_at +30 giây, độc lập history retention 30 ngày.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành webhook_deliveries_check1: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên
    -- phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((expires_at > admitted_at))
    -- Ràng buộc hiện hành webhook_deliveries_check2: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên
    -- phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK (((kind <> 'TEST'::text) OR (expires_at = (admitted_at + '00:00:30'::interval))))
    expires_at timestamptz NOT NULL,

    -- Thời điểm quan sát trạng thái kết thúc của command/delivery; không thay gốc expiry hoặc gốc retention.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    terminal_at timestamptz,

    -- Số đợt retry thủ công webhook đã mở, chỉ 0 hoặc 1; TEST không có manual batch.
    -- integer: số nguyên có dấu 32 bit; CHECK giới hạn miền nghiệp vụ thay vì chỉ dựa phạm vi kiểu.
    -- NOT NULL: bắt buộc có giá trị.
    -- DEFAULT 0: giá trị dùng khi INSERT bỏ qua cột; không thay NULL được truyền tường minh và không tự áp lại khi
    -- UPDATE.
    -- Ràng buộc hiện hành webhook_deliveries_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên
    -- phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((((kind = 'BUSINESS'::text) AND (occurrence_id IS NOT NULL)) OR ((kind = 'TEST'::text) AND (occurrence_id
    -- IS NULL) AND (manual_batch_count = 0))))
    -- Ràng buộc hiện hành webhook_deliveries_manual_batch_count_check: CHECK chỉ chặn khi biểu thức là FALSE;
    -- NULL/UNKNOWN vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK (((manual_batch_count >= 0) AND (manual_batch_count <= 1)))
    manual_batch_count integer NOT NULL DEFAULT 0 CHECK(manual_batch_count BETWEEN 0 AND 1),

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
    -- Ràng buộc hiện hành webhook_deliveries_lease_generation_check: CHECK chỉ chặn khi biểu thức là FALSE;
    -- NULL/UNKNOWN vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((lease_generation >= 0))
    lease_generation bigint NOT NULL DEFAULT 0 CHECK(lease_generation>=0),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    PRIMARY KEY(workspace_id,webhook_delivery_id),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,webhook_subscription_id) REFERENCES webhook_subscriptions,

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,occurrence_id) REFERENCES event_occurrences,

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,webhook_subscription_id,secret_version) REFERENCES webhook_secret_versions,

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    CHECK((kind='BUSINESS' AND occurrence_id IS NOT NULL) OR (kind='TEST' AND occurrence_id IS NULL AND manual_batch_count=0)),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    CHECK(expires_at>admitted_at),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    CHECK(kind<>'TEST' OR expires_at=admitted_at+interval '30 seconds')
);
/* Transition occurrence và subscription là dedupe; secret rotate không tạo delivery mới. */
CREATE UNIQUE INDEX uq_webhook_delivery_occurrence ON webhook_deliveries(workspace_id,webhook_subscription_id,occurrence_id) WHERE kind='BUSINESS';
CREATE INDEX ix_webhook_deliveries_due ON webhook_deliveries(next_attempt_at,workspace_id,webhook_delivery_id) WHERE state IN ('PENDING','RETRY_WAIT');
-- Bảng webhook_delivery_attempts: Ý định HTTP outbound mỗi lần gửi delivery, với batch và outcome đã loại dữ liệu
-- nhạy cảm. Ngân sách BUSINESS 6 tự động + một batch 6 thủ công, TEST chỉ một attempt.
CREATE TABLE webhook_delivery_attempts (
    -- Identity workspace sở hữu dữ liệu, dùng giữ phạm vi tenant trong khóa, FK và truy vấn; không tự chứng minh quyền
    -- của người gọi.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành webhook_delivery_attempts_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, webhook_delivery_id, attempt_number)
    -- Ràng buộc hiện hành webhook_delivery_attempts_workspace_id_webhook_delivery_id_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, webhook_delivery_id) REFERENCES webhook_deliveries(workspace_id, webhook_delivery_id)
    workspace_id uuid NOT NULL,

    -- Identity nghĩa vụ webhook giữ nguyên khi retry, để receiver dedupe ngay cả khi response bị mất.
    -- UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành webhook_delivery_attempts_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, webhook_delivery_id, attempt_number)
    -- Ràng buộc hiện hành webhook_delivery_attempts_workspace_id_webhook_delivery_id_fkey: khóa ngoại giữ đúng bản ghi
    -- cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành.
    -- FOREIGN KEY (workspace_id, webhook_delivery_id) REFERENCES webhook_deliveries(workspace_id, webhook_delivery_id)
    webhook_delivery_id uuid NOT NULL,

    -- Số thứ tự send intent của một delivery, bắt đầu 1; PK và admission guard bảo vệ thứ tự/ngân sách.
    -- integer: số nguyên có dấu 32 bit; CHECK giới hạn miền nghiệp vụ thay vì chỉ dựa phạm vi kiểu.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành webhook_delivery_attempts_attempt_number_check: CHECK chỉ chặn khi biểu thức là FALSE;
    -- NULL/UNKNOWN vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK (((attempt_number >= 1) AND (attempt_number <= 12)))
    -- Ràng buộc hiện hành webhook_delivery_attempts_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn
    -- qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((batch_number = ((attempt_number - 1) / 6)))
    -- Ràng buộc hiện hành webhook_delivery_attempts_pkey: khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì
    -- uniqueness áp dụng cho cả tổ hợp.
    -- PRIMARY KEY (workspace_id, webhook_delivery_id, attempt_number)
    attempt_number integer NOT NULL CHECK(attempt_number BETWEEN 1 AND 12),

    -- Đợt webhook: 0 là tự động, 1 là đợt retry thủ công duy nhất; không tạo body/delivery identity mới.
    -- integer: số nguyên có dấu 32 bit; CHECK giới hạn miền nghiệp vụ thay vì chỉ dựa phạm vi kiểu.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành webhook_delivery_attempts_batch_number_check: CHECK chỉ chặn khi biểu thức là FALSE;
    -- NULL/UNKNOWN vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK (((batch_number >= 0) AND (batch_number <= 1)))
    -- Ràng buộc hiện hành webhook_delivery_attempts_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn
    -- qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((batch_number = ((attempt_number - 1) / 6)))
    batch_number integer NOT NULL CHECK(batch_number BETWEEN 0 AND 1),

    -- Thời điểm lưu ý định trước side effect bên ngoài DB; dùng tính ngân sách/expiry và phục hồi khi mất ACK.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    intent_at timestamptz NOT NULL,

    -- Digest 32 byte của request/body đã canonical hóa để phát hiện cùng identity khác nội dung hoặc đối chiếu send
    -- intent.
    -- bytea: dãy byte nhị phân; tên digest/ciphertext mô tả mục đích, bản thân kiểu không băm hoặc mã hóa dữ liệu.
    -- NOT NULL: bắt buộc có giá trị.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành webhook_delivery_attempts_request_digest_check: CHECK chỉ chặn khi biểu thức là FALSE;
    -- NULL/UNKNOWN vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((octet_length(request_digest) = 32))
    request_digest bytea NOT NULL CHECK(octet_length(request_digest)=32),

    -- HTTP status đã ghi nhận, miền 100..599 khi có; NULL khi chưa có response đáng tin cậy.
    -- integer: số nguyên có dấu 32 bit; CHECK giới hạn miền nghiệp vụ thay vì chỉ dựa phạm vi kiểu.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    -- Ràng buộc hiện hành webhook_delivery_attempts_response_status_check: CHECK chỉ chặn khi biểu thức là FALSE;
    -- NULL/UNKNOWN vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK (((response_status >= 100) AND (response_status <= 599)))
    response_status integer CHECK(response_status BETWEEN 100 AND 599),

    -- Kết quả quan sát của một HTTP send intent, không tự chứng minh receiver chưa xử lý khi response bị mất.
    -- text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp
    -- vụ.
    -- NOT NULL: bắt buộc có giá trị. Chuỗi rỗng vẫn cần CHECK riêng.
    -- Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.
    -- Ràng buộc hiện hành webhook_delivery_attempts_outcome_check: CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN
    -- vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần.
    -- CHECK ((outcome = ANY (ARRAY['INTENT'::text, 'ACCEPTED'::text, 'TRANSIENT_FAILURE'::text,
    -- 'PERMANENT_FAILURE'::text, 'UNKNOWN'::text])))
    outcome text NOT NULL CHECK(outcome IN ('INTENT','ACCEPTED','TRANSIENT_FAILURE','PERMANENT_FAILURE','UNKNOWN')),

    -- Thời điểm quan sát được dữ liệu/kết quả; nguồn và ý nghĩa được quy định theo bảng, không mặc định là thời gian
    -- commit.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    observed_at timestamptz,

    -- Thời điểm sớm nhất được thử gửi tiếp; không được gửi sớm hơn mốc này hoặc vượt expiry/budget của parent.
    -- timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.
    -- Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.
    next_attempt_at timestamptz,

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    PRIMARY KEY(workspace_id,webhook_delivery_id,attempt_number),

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    FOREIGN KEY(workspace_id,webhook_delivery_id) REFERENCES webhook_deliveries,

    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.
    CHECK(batch_number=(attempt_number-1)/6)
);
