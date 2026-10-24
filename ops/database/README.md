# PostgreSQL thật cho database-plan

**Đường dùng hiện hành cho toàn dự án:** duy nhất **`iot_platform_lab`**, [một file SQL tổng hợp](../../backend/migrations/platform.sql), [runbook canonical](../../backend/migrations/platform/README.md). Chạy `python -B ops/database/verify_platform.py apply` hoặc `verify` với quyền Docker ngoài sandbox. Runner canonical không tạo DB test/restore mới;151 engine checks và35 Python unit test đã đạt. [Report mới nhất](../../docs/test-reports/database-template-2026-10-24.md) ghi ingestion/retention cùng81 repository checks; [JSON evidence](evidence/platform-latest.json) có coverage native comments và fingerprint sau clean/restore. [DBeaver local](DBEAVER.md) dùng SCRAM, mẫu duy nhất ở [backend/.env.example](../../backend/.env.example).

Phần dưới là **lịch sử auth lab `iot_database_lab`**. Không dùng lệnh `verify_database.py verify` để kiểm baseline canonical hoặc làm phát sinh DB restore không cần thiết.

Engine: **PostgreSQL17.11**, Docker Desktop trên máy hiện tại. Các lệnh Docker và runner được chạy ngoài sandbox theo yêu cầu người dùng. Container `iot-postgres17-database`, database chính `iot_database_lab`, official image được pin trong [runner](verify_database.py) bằng digest đã tải và kiểm chứng.

## Chạy lại

Từ repository root:

```powershell
python -B -m unittest discover -s backend/tests/database -p 'test_*.py' -v
python -B ops/database/verify_database.py status
python -B ops/database/verify_database.py provision
python -B ops/database/verify_database.py verify
```

`provision` tạo/start đúng container có label/image đã chọn; từ chối container cùng tên sai identity. `verify` áp tuần tự `0001_auth.sql` và `0002_auth_integrity.sql`, kiểm trên engine thật, xuất snapshot schema-only và ghi [JSON evidence](evidence/runtime-2026-10-23.json). Toàn bộ SQL imported nằm trong [backend/migrations](../../backend/migrations/README.md). Không kết nối database ngoài namespace lab này. Các bảng ứng dụng phải trống trước khi thêm fixture/dump; runner kiểm count và dừng nếu có dữ liệu.

Mở psql trực tiếp trên database đang chạy:

```powershell
docker exec -it iot-postgres17-database psql -X -h /tmp -U iot_migrator -d iot_database_lab
```

## Cấu hình và dữ liệu

- PostgreSQL chạy bằng OS user `postgres`; Unix socket nội bộ tại `/tmp`; network none, không publish cổng, TCP bị reject. Local trust chỉ áp trong container này; không có connection password, biến environment hoặc signing key được tạo/lưu bởi runner.
- `iot_migrator` và `iot_runtime` là LOGIN role không superuser/CREATEDB/CREATEROLE/BYPASSRLS. Cluster owner `iot_lab_owner` chỉ bootstrap/CREATE DATABASE trong engine mới. Runtime PoC chỉ được SELECT ba bảng users/workspaces/memberships; đây chưa phải policy cho ứng dụng production.
- Dữ liệu nằm trong writable layer tại `/tmp/iot-postgres17-data`, còn sau stop/start cùng container. Xóa container sẽ mất cluster này; chưa triển khai volume/backup schedule production. Runner không có lệnh xóa/reset container, volume hoặc database.
- Fixture SQL rollback toàn bộ; password_hash là marker không xác thực được; các byte digest là dữ liệu tổng hợp. `auth_settings` không được seed khóa. Chỉ marker restore tổng hợp được giữ trong schema `migration_control`.
- Mỗi lần verify tạo ba DB mới `iot_database_restore_<12hex>` cho clean migration concurrency, full restore và schema-only import; giữ lại để review, không tự dọn. Evidence ghi tên các DB của lần chạy cuối. Lần restore thất bại cũng được giữ để chẩn đoán.
- Ledger PoC `migration_control.applied_migrations` giữ checksum SHA-256, khóa migration chung, timeout test5s/30s, DDL+ledger atomic và drift fail. Đây chưa phải SQLx runner hoặc migration history chính thức cho backend.

## Kết quả và giới hạn

Đã sửa bốn GAP bằng forward migration `0002_auth_integrity.sql`, giữ nguyên checksum0001. Kết quả: **44 SQL PASS, 6 race PASS** ở READ COMMITTED/REPEATABLE READ, **9 unit test PASS**, 4 runtime permission denials. Clean concurrent migration có một winner mỗi version; re-run, checksum drift cả hai version và interrupted DDL rollback đã kiểm. Main/clean/full restore/schema snapshot khớp cột, constraint, index, trigger, function và ACL. Session immutability và quyền writer có giới hạn ghi rõ trong README migrations.

Engine/migration PoC không thay CP-01/02, auth handler tests, authorization cross-workspace, load hoặc restore có physical side effect. Xem [báo cáo integrity mới](../../docs/test-reports/database-integrity-2026-10-23.md); [báo cáo trước sửa](../../docs/test-reports/database-runtime-2026-10-23.md) được giữ làm lịch sử. Quyền runtime ứng dụng, custody/rotation, pool/lock/hash budget và RPO/RTO production còn checkpoint riêng.
