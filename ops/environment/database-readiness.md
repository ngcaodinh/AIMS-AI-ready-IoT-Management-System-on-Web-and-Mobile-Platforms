# Database readiness — DB-01

**Cập nhật canonical hiện hành:** toàn ứng dụng dùng duy nhất `iot_platform_lab` trên engine17.11 đã định danh.11 migration/89 bảng đã áp trực tiếp ngoài sandbox;103 engine checks và13 unit tests đạt, metadata/ACL restore khớp trên cùng DB. [Runbook](../../backend/migrations/platform/README.md), [evidence](../../docs/test-reports/database-platform-2026-10-23.md). Các đoạn bên dưới mô tả auth lab trước đó. Backend writer/custody/production budgets/RPO/RTO vẫn còn gate; không dùng PoC để tự đóng chúng.

Ngày kiểm tra: 2026-10-23. Trạng thái: **LAB_IMPORTED_SCHEMA_VERIFIED** cho engine/schema hiện đã import; **MISSING_INPUT** cho các prerequisite backend/production còn lại. Người dùng đã yêu cầu tải và kiểm thử DB thật ngoài sandbox; đích mới là `iot-postgres17-database` / `iot_database_lab`. Không có DB ngoài namespace lab này được kết nối/reset. [Evidence integrity](../../docs/test-reports/database-integrity-2026-10-23.md), [runbook](../database/README.md).

## Quan sát thực tế

| Hạng mục | Actual | Điều kiện mở nhánh phụ thuộc |
| --- | --- | --- |
| PostgreSQL access | Không có MCP PostgreSQL; dùng psql trong container mới đã định danh | Không tìm credential trong tệp/environment hoặc kết nối DB khác; thao tác engine qua runner cố định |
| PostgreSQL CLI | Host không có psql trong PATH; psql17 có trong image, cùng server17.11 | Không cần cài thêm CLI host để chạy PoC |
| Docker | Đã start Docker Desktop; Client/Server29.2.1; image tải và container chạy ngoài sandbox | Daemon blocker cũ đã được xử lý, không còn là input thiếu |
| DB version/image | PostgreSQL17.11 Debian; digest `sha256:858bb5e98eed02eb8cafbcdc007f9a65d1b613972028944a8ec2133ccaf80d27` | Đã pin lab trong decision record; production/topology còn riêng |
| Migration runner | Python stdlib + psql, ledger PoC atomic/checksum/advisory lock đã test | SQLx/backend runner chưa chọn; không suy PoC thành dependency được pin cho Rust |
| Source imported | Bảy bảng0001 + integrity0002 đã áp; checksum0001 giữ nguyên; toàn bộ SQL/snapshot lưu trong backend/migrations | 44 SQL +6 race PASS; bốn GAP đã sửa trong scope này; không kết nối DB khác |
| Runtime roles | iot_migrator/iot_runtime không superuser/CREATEDB/CREATEROLE/BYPASSRLS;4 permission negative controls đạt | Runtime PoC chỉ đọc3 bảng; worker/retention/app mutation policy chưa được nghiệm thu |
| Custody và config | Chưa có rotation/restore evidence; auth_settings nháp khai signing_key bytea | Chốt protected key interface/wrapped metadata trước schema recoverable secret; không đọc giá trị thật |
| Pool/lock/hash budget | Chưa đo | START-03/CP-02 chốt phương án và đo thực tế; không điền số dự đoán |
| Backup/restore | pg_dump/restore so cột/constraint/index/trigger/function/ACL và marker tổng hợp; snapshot schema-only cũng đã reimport | Chưa có RPO/RTO, artifact/key reference recovery, restore physical side effects hoặc backup schedule production |

Khảo sát ban đầu chỉ có version/check readiness; sau yêu cầu tiếp tục đã start Docker, pull image, provision và kiểm engine thật. Runner không trực tiếp mở/in cấu hình Docker, environment hoặc secret; chỉ inspect label/image/user/network/port/mount identity và count dữ liệu lab. Fixture tổng hợp rollback; không seed signing key/account thật. Dump giữ trong RAM và chỉ thực hiện sau guard các bảng ứng dụng trống.

## Phân loại đường baseline

| Đường | Nhận diện bắt buộc | Thao tác được phép sau khi có target | Recovery |
| --- | --- | --- | --- |
| A — DB mới | Target cụ thể; trống; không consumer/dữ liệu cần giữ; owner/migrator/runtime role | Baseline mới được review, synthetic fixture và test role/constraint | Dừng writer; rollback transaction migration nếu chưa commit; lỗi sau commit dùng repair đã review |
| B — lab nháp | Target cụ thể; checksum đã áp dụng; xác nhận dữ liệu được bỏ | Chỉ reset nếu đã được giao rõ cho đúng target; không tự suy từ thiết kế mới | Giữ mapping/checksum và evidence; dựng lab mới ưu tiên hơn xóa lab chưa rõ |
| C — cần giữ dữ liệu | Target cụ thể; consumers; backup/restore; migration history | Expand, backfill, validate, switch, contract theo compatibility window | Forward repair; không sửa migration đã áp hoặc DROP để vượt gate |

## Mapping nháp cần xử lý ở DB-02/03

`users.id` → `user_id`; `sessions.id` → `session_id`; `workspaces.id` → `workspace_id`; `created_by` → `created_by_user_id`; `authz_version` → `authorization_version`; `login_attempts` → `login_attempt_buckets`; `audit_events.id/actor_id` → `audit_event_id/actor_user_id`. Preferences chuyển sang user_preferences trong thiết kế mới. `auth_settings.signing_key` không thành baseline custody. `IOS` trong enum nháp không mở scope iOS theo ADR-001.

Mapping không phải lệnh rename trên DB thật. Kiểm producer/query hiện có và target trước chọn baseline mới hoặc data-preserving migration. Không thay file nháp trong bước readiness.

## Đầu vào đang thiếu

1. Backend/production runner và policy role ứng dụng; lab engine/image/runner đã xác định và kiểm chứng.
2. CP-01 artifact review trước IAM backend; custody/rotation và ngân sách hash/pool/lock theo START-03.
3. RPO/RTO, backup schedule, durable volume và recovery artifact/key references trước production.

Các thiếu hụt trên không còn chặn PoC PostgreSQL lab đã chạy; vẫn chặn đường phụ thuộc backend/production tương ứng. DB-01B có evidence PoC, không dùng nó đóng DB-02/03, CP-01/02 hoặc toàn bộ database plan.
