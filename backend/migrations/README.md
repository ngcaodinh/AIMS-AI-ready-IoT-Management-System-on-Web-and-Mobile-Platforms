# Database toàn hệ thống và SQL đã import trên PostgreSQL 17

**Nguồn dùng cho toàn dự án hiện nay:** [platform.sql](platform.sql), áp vào duy nhất `iot_platform_lab`. Bộ này gồm toàn bộ89 bảng nghiệp vụ của IAM/workspace, template/device/telemetry, command/dashboard/rule, event/outbox, push/enrollment, OTA/API key/webhook. Xem [hướng dẫn canonical](platform/README.md) và [manifest thực tế](platform/manifest.json).

Các mục phía dưới mô tả **auth lab lịch sử `iot_database_lab`**, không phải hướng dựng toàn hệ thống. Không chạy numbered migration auth cấp này hoặc [schema.sql](schema.sql) lên `iot_platform_lab`. Chỉ dùng `platform.sql` hoặc numbered migration trong `platform/`; snapshot `platform/schema.sql` là đường dựng schema thay thế, không chạy nối tiếp migration.

Đích đã kiểm: `iot-postgres17-database` / `iot_database_lab`, PostgreSQL **17.11**. Thư mục này lưu đầy đủ DDL ứng dụng, SQL quản lý migration, bootstrap/quyền lab và snapshot schema hiện tại. Không chứa account, signing key hoặc dữ liệu ứng dụng thật.

| Nguồn | Nội dung và cách dùng |
| --- | --- |
| [0001_auth.sql](0001_auth.sql) | Baseline bảy bảng users, auth_settings, sessions, login_attempts, workspaces, memberships, audit_events; giữ nguyên byte đã áp |
| [0002_auth_integrity.sql](0002_auth_integrity.sql) | Forward migration sửa bốn invariant: capable Admin, session bất biến, audit actor/session, limiter count/window |
| [schema.sql](schema.sql) | Snapshot schema-only xuất từ DB thật: chín bảng trong public/migration_control, tám function, constraint, index, trigger và ACL; đã import lại và đối chiếu |
| [runner/ledger.sql](runner/ledger.sql) | Cấu trúc ledger version/checksum/applied_at |
| [runner/apply.sql](runner/apply.sql) | Template psql: transaction, advisory lock, kiểm checksum, áp DDL và ghi ledger atomic |
| [runner/fingerprint.sql](runner/fingerprint.sql) | Đối chiếu metadata cột, constraint, index, trigger, function và ACL; không đọc dữ liệu nghiệp vụ |
| [lab/bootstrap.sql](lab/bootstrap.sql) | Tạo role migrator/runtime và DB lab nếu thiếu; chạy bằng cluster owner, ngoài transaction CREATE DATABASE |
| [lab/permissions.sql](lab/permissions.sql) | Quyền lab: runtime chỉ SELECT users/workspaces/memberships; không phải policy writer của backend |
| [lab/restore_probe.sql](lab/restore_probe.sql) | Cấu trúc và marker tổng hợp phục vụ kiểm restore |

## Thứ tự áp dụng

Đường được kiểm chứng là bootstrap → `0001_auth.sql` → `0002_auth_integrity.sql` → quyền lab/restore probe. Runner chỉ nhận danh sách version tường minh, không glob mọi file SQL:

| Version trong ledger | SHA-256 nguồn |
| --- | --- |
| `draft-0001-auth` | `8957cdb90ff4f4ef46abaadcb92ae3afdc640870bf4ddab992982cc20578595d` |
| `0002-auth-integrity` | `eae2990687eed9488162b674c5fb2b78ee7a725fafa62f1ed61d3e9866cef12d` |

Không sửa migration đã áp dụng. `0002` cần transaction, giữ lock trong preflight/DDL và từ chối dữ liệu cũ vi phạm; không tự sửa/xóa dữ liệu. Timeout 5s/30s là guard của lab, chưa phải budget production. Lỗi trước commit rollback cả DDL/ledger; sau commit dùng forward migration đã review.

`runner/apply.sql` là template, không chạy trực tiếp: Python thay đúng hai marker `{{ledger_sql}}`/`{{migration_sql}}` bằng SQL nguồn cố định; version/checksum được truyền qua literal psql `:'name'`. `lab/bootstrap.sql` cần biến psql `lab_database` do launcher allowlist. Không thay các cơ chế này bằng nối input SQL tùy ý.

Chạy từ repository root, với Docker Desktop đang hoạt động:

```powershell
python -B -m unittest discover -s backend/tests/database -p 'test_*.py' -v
python -B ops/database/verify_database.py provision
python -B ops/database/verify_database.py verify
```

`verify` chỉ chạy với đúng container/DB lab được định danh và bảy bảng ứng dụng trống. Nó kiểm DB chính, dựng DB mới, chạy SQL/concurrency/restore, rồi sinh lại snapshot và [evidence JSON](../../ops/database/evidence/runtime-2026-10-23.json). Không dùng lệnh này với DB có dữ liệu ứng dụng.

## Snapshot và dữ liệu

`schema.sql` là phương án dựng schema trên **DB trống** sau bootstrap role, bằng psql tương thích PostgreSQL 17.11, dưới role `iot_migrator`. Không chạy snapshot nối tiếp numbered migration. Snapshot có DDL của ledger nhưng không có các hàng lịch sử đã áp; DB dựng bằng snapshot không được đưa vào runner apply khi chưa có quy trình adoption/checksum riêng. Để có lịch sử chuẩn, dùng đường numbered migration ở trên.

Snapshot giữ ACL và không giữ owner cố định; role chạy restore sở hữu object. SQL bootstrap giữ cấu hình role/DB lab ở file riêng. Cấu hình OS/socket/network/container nằm trong [launcher](../../ops/database/verify_database.py). Các dòng `\restrict`/`\unrestrict` là cơ chế psql do pg_dump sinh, không phải credential. Dữ liệu tổng hợp restore_probe ở file lab riêng; ledger được runner ghi bằng checksum nguồn. Không export signing key, verifier hoặc session thật.

## Invariant và giới hạn đã kiểm

- Workspace phải còn ít nhất một membership ADMIN/ACTIVE với account ACTIVE và `must_change_password=false`, kể cả khi đổi trạng thái User; check deferred cho phép handoff Admin trong cùng transaction. TRUNCATE memberships bị chặn.
- User/Workspace MVCC fences ngăn write skew ở READ COMMITTED và REPEATABLE READ, kể cả grant sau snapshot cũ. Writer tương lai cần khóa User → Workspace → Membership trước mutation. Row trigger không bảo đảm thứ tự toàn cục cho mọi batch owner; caller phải retry toàn transaction an toàn khi gặp `40001`/`40P01`.
- Session giữ identity, admission full/limited, thời điểm cấp/hết hạn; revocation không đảo ngược. Đây là bảo vệ UPDATE trong vòng đời hàng hiện có. Schema owner tin cậy vẫn có khả năng DDL hoặc xóa/tạo lại hàng không còn tham chiếu; không tuyên bố có tombstone chống tái sử dụng sau purge. Runtime hiện tại không có quyền ghi. FK audit ngăn xóa session đang được tham chiếu.
- Audit có session phải có actor đúng chủ session; audit anonymous/global không có session vẫn hợp lệ. Limiter count=0 cần window NULL; count>0 cần window, giữ giới hạn count gốc.
- Function chạy SECURITY INVOKER với search_path cố định và PUBLIC EXECUTE bị thu hồi. Trước khi mở writer không phải owner, cần thiết kế/grant helper EXECUTE cùng quyền parent phù hợp và kiểm lại bằng chính role đó.

[Báo cáo kiểm chứng và review](../../docs/test-reports/database-integrity-2026-10-23.md): 44 SQL PASS, sáu race PASS, chín unit test PASS, bốn runtime denials, clean/upgrade/restore/snapshot khớp metadata và ACL. Phạm vi hoàn thành là schema đã import; các module IoT tương lai và gate backend/production trong database-plan vẫn có checkpoint riêng.
