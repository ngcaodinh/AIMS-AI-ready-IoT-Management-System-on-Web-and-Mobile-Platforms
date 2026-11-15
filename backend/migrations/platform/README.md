# Một database PostgreSQL cho toàn dự án

Đích ứng dụng duy nhất: **`iot_platform_lab`**, PostgreSQL **17.11**, container **`iot-postgres17-database`**. Tất cả module dùng schema `public`, lịch sử migration ở `migration_control`. Các tên có hậu tố `lab` là tên engine hiện hữu đã được định danh; đây là database thật được áp bằng lệnh ngoài sandbox, không là mô phỏng SQL.

## Nguồn canonical

| Artifact | Cách dùng |
| --- | --- |
| [../platform.sql](../platform.sql) | Một file psql đầy đủ20 migration, target guard, ledger/checksum và transaction từng version |
| `0001_identity.sql`…`0020_auth_ios_client.sql` | 0001–0006 là bản comment chi tiết để đọc; SQL đã áp giữ byte gốc ở [applied_sql](applied_sql/README.md); runner so token và dùng checksum gốc, không rewrite ledger |
| [schema.sql](schema.sql) | Schema-only snapshot có mục đích tiếng Việt trước từng bảng và công dụng từng cột; không chứa row/credential hoặc ledger history; chỉ dựng DB trống thay cho numbered migration |
| [manifest.json](manifest.json) |91 bảng public, description bảng/cột và mọi null/default/PK/UK/FK/CHECK/index lấy từ engine, phủ87 relation catalog và4 bảng enum/capability chuẩn hóa |

Không dùng snapshot auth ở thư mục cha làm baseline này. `platform.sql` là artifact sinh từ source, không sửa tay. Snapshot không có các hàng applied_migrations; không đưa DB dựng từ snapshot vào runner apply nếu chưa có adoption ledger được kiểm chứng.

Ngày13/11/2026,0020 đã áp forward trên DB canonical sau khi đối chiếu19version/checksum trước. Migration mở CHECK sessions/audit_events cho IOS và cập nhật metadata comment, không sửa row. Bundle giữ target/transaction/ledger/advisory-lock guards. Snapshot/manifest/relations đã refresh từ catalog20versions, exact native comments đạt92tables/5views. Lượt này không chạy empty-database rebuild suite của CLI verify. [Evidence và giới hạn](../../../docs/test-reports/FEAT-TN-001-ios-provider-and-policy-2026-11-13.md).

## Áp và kiểm trực tiếp

Từ root, Docker Desktop phải đang chạy. Runner kiểm đúng label, image digest, owner và namespace trước ghi; không nhận URI hoặc credential từ shell/environment.

```powershell
python -B ops/database/verify_platform.py apply
python -B ops/database/verify_platform.py verify
python -B -m unittest discover -s backend/tests/database -p 'test_*.py' -v
```

`apply` tạo duy nhất DB canonical nếu chưa tồn tại rồi áp các version còn thiếu và xuất SQL tổng hợp. Với baseline hiện tại, cả `apply` lẫn `verify` yêu cầu các bảng ứng dụng trống; runner dừng nếu thấy dữ liệu. Sau khi có dữ liệu thật cần runner rollout có preflight/backfill tương ứng; không dùng kiểm thử baseline làm đường nâng cấp production.

`verify` chạy constraint/permission tests, năm race hai connection thật, checksum drift, migration fault rollback, dựng sạch và restore metadata/ACL/functions/views/comments trong transaction rollback trên **chính DB này**. Không tạo DB test/restore mới. Clean/restore tạm khóa schema, chỉ chạy trên DB trống khi chưa mở traffic. Sau kiểm, schema/ledger gốc và trạng thái không có dữ liệu ứng dụng được đối chiếu lại.

Để áp file tổng hợp đã có, sao chép nguyên file UTF-8 vào container rồi dùng psql:

```powershell
docker cp backend/migrations/platform.sql iot-postgres17-database:/tmp/iot-platform.sql
docker exec iot-postgres17-database psql -X -w -v ON_ERROR_STOP=1 -h /tmp -U iot_migrator -d iot_platform_lab -f /tmp/iot-platform.sql
```

Lệnh mở DB để quản lý:

```powershell
docker exec -it iot-postgres17-database psql -X -h /tmp -U iot_migrator -d iot_platform_lab
```

## Đọc công dụng bảng và cột

Mở chính0001–0006 và0014–0018 để đọc comment từng dòng: purpose bảng, công dụng/type/NULL/default/PK/UK/FK/CHECK của từng cột. [schema.sql](schema.sql) có cùng hướng dẫn cạnh định nghĩa hiện hành. [0012_schema_comments.sql](0012_schema_comments.sql) và các forward migration sau đã lưu mô tả vào PostgreSQL bằng `COMMENT ON`. Trong psql dùng `\d+ public.users` hoặc `\d+ public.devices`. Native coverage hiện là92 bảng/822 cột gồm ledger và5 view/69 cột view.

[Report mới nhất](../../../docs/test-reports/database-template-2026-10-24.md):151 engine checks/35 Python unit tests đạt; ingestion/retention có81 repository checks và51 Rust tests. [DBeaver local](../../../ops/database/DBEAVER.md) có SCRAM và kiểm quyền riêng. Comment diễn giải mục đích, không thay constraint hoặc nghiệm thu service. Đọc [đối chiếu31 task](../../../docs/plan/database/full-plan-status.md) trước kết luận full plan đã xong.

## Thiết kế và phạm vi bảo vệ

- Khóa tenant `(workspace_id,…)`, FK cùng device/pin/version, global device/serial/key lookup, natural uniqueness, typed source/XOR; không tách DB theo module.
- Snapshot template/rule/firmware chặn UPDATE đổi nội dung; child chỉ append khi marker transaction/cluster của parent chứng minh parent được INSERT cùng transaction. SAVEPOINT/CTE được kiểm. User/Workspace MVCC fences bảo vệ Admin cuối và quota; caller batch giữ thứ tự khóa ổn định, retry toàn transaction khi40001/40P01 trước side effect ngoài DB.
- Telemetry nguyên envelope, điểm typed/range/finite, thời gian copy null-safe; receipt không FK ngược raw. `purge_expired_telemetry` xóa raw quá7 ngày theo batch, giữ dedupe receipt.
- Command terminal không đổi truth; late evidence/resolution tách riêng. Push unique notification/installation dù rebind, attempt≤4; BUSINESS webhook theo occurrence/subscription,6+6 attempt và một manual batch giữ body/key snapshot.
- `RECOVERY_REQUIRED` không release OTA slot. Enrollment expiry không tự release guard khi chưa cleanup proof. Outbox claim/complete dùng lease generation; WebSocket ticket consume một winner và recheck quyền hiện hành.
- History view cắt raw7 ngày, audit/execution/delivery30 ngày; đây là logical visibility, không đồng nghĩa mọi payload/operational guard đã có policy compact/purge production.

`iot_runtime` chỉ có INSERT audit theo column allowlist, loại created_at; chưa có SELECT audit, UPDATE/DELETE hoặc DML nghiệp vụ khác, DDL/helper EXECUTE. Quyền còn lại cấp theo repository/procedure sau kiểm authorization backend; không cấp toàn schema. Worker retention role trong probe tách pool, có SELECT/DELETE audit và UPDATE(ID) để khóa row, immutable trigger chặn sửa ID. Đây là role kiểm thử được cleanup, chưa triển khai credential worker production. Schema owner là role migration tin cậy và phải tuân thủ retention/write protocol. FK không chứng minh current authorization; JSON object CHECK không chứng minh AST/reference bijection; nhãn VERIFIED không kiểm chữ ký firmware bằng SQL.

## Những gate còn lại

DDL đã được kiểm; không đánh đồng với hoàn thành31 task full stack trong database-plan. Backend writer policy, validation AST/dashboard/manifest, key custody/rotation, dispatch fences và provider/board reconciliation, physical backup+artifact/key recovery, RPO/RTO và tải100 simulator trong30 phút vẫn cần acceptance riêng. Repository đã có scoped audit read và audit-retention kernel; HTTP endpoints và worker production chưa có trong phạm vi này.

Engine hiện tại giữ cluster trong writable layer của container, network none và Unix socket `/tmp`, không publish TCP. Stop/start cùng container giữ dữ liệu; xóa container mất cluster. Chưa cấp kết nối TCP/credential cho backend Windows hoặc triển khai durable volume/backup production. Không suy DB đã tạo thành hệ thống production-ready.

DB auth/restore cũ được giữ làm lịch sử, không là dependency ứng dụng. Không tự DROP database hay xóa container khi chưa có yêu cầu đúng đích.
