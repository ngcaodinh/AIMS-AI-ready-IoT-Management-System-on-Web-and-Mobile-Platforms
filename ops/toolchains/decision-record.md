# Toolchain compatibility decision record

Status: PostgreSQL lab PoC verified; remaining toolchains and production readiness pending.

| Component | Candidate | Lock artifact | PoC evidence required | Status |
| --- | --- | --- | --- | --- |
| Rust |1.99.1 GNU cho máy Windows hiện hành; SQLx0.8.6 | `backend/rust-toolchain.toml`, `backend/Cargo.lock` | Workspace/core + PostgreSQL use-case PoC | SQLx slice verified45 checks/43 Rust tests; Axum/MQTT/platform production pending |
| Node/Web | Node 22.13.0 present | `package-lock.json` | TypeScript build and browser smoke test | Pending |
| Flutter | Flutter 3.47.5 / Dart 3.13.4 | `pubspec.lock` | Android, BLE and push PoC | Pending — iOS deferred by ADR-001 |
| ESP-IDF | selected through EIM | ESP-IDF/config/component locks | Board, BLE and dual-slot OTA PoC | Pending |
| PostgreSQL | 17.11 Debian for lab | `ops/database/verify_database.py` pinned image digest; PoC ledger | clean/re-run/drift/rollback, runtime role, dump/restore | Imported schema repaired: 44 SQL / 6 races PASS; production pending |
| Mosquitto | not selected | Compose/image digest and ACL baseline | TLS, ACL and reconnect PoC | Pending |

No entry becomes pinned merely because it is the newest available version. Record the version, owner, date, compatibility evidence and rollback path once each PoC succeeds. iOS is out of scope in the current BA/handoff source documents; a future iOS track requires a new source-document decision and toolchain PoC.

## Rust/SQLx database slice — 2026-10-24

Chỉ đạo thực thi database-plan và Clean Architecture cho phép mở stack Rust/SQLx đã có trong runtime proposal.
MSVC thiếu link.exe; đã cài host toolchain1.99.1 GNU và dùng GCC hiện có để build/test thật,
không dùng metadata-only compile thay test. Direct crate versions pin từ proposal, Cargo.lock đã sinh.
Không thêm Axum/MQTT vào workspace khi chưa có consumer của các dependency đó.

Pool probe8 connection/instance, acquire5s; gateway statement30s/lock5s/idle-tx15s;
hasher2 slot dùng chung, queue5s, Argon2id v1.3 m19456KiB/t2/p1/output32byte.
Đây là budget PoC, chưa là số throughput/RPO/RTO đo cho production.
[ADR-003](../../docs/adr/adr-003-clean-architecture-database-runtime.md),
[evidence](../../docs/test-reports/database-clean-architecture-2026-10-24.md).
Rollback: dừng probe, giữ source/migration additive và ledger; không bỏ guard hoặc giảm acceptance.

## PostgreSQL lab decision — 2026-10-23

Theo yêu cầu download và kiểm thử engine thật ngoài sandbox, chọn PostgreSQL17.11 trên Docker Desktop29.2.1 cho DB-01B. Image official `postgres:17-bookworm` resolve và pin thành `postgres@sha256:858bb5e98eed02eb8cafbcdc007f9a65d1b613972028944a8ec2133ccaf80d27`. Vai trò thực hiện: database architect/agent trong phiên; không ghi người duyệt production giả.

Đích mới: container `iot-postgres17-database`, DB `iot_database_lab`, network none, Unix socket nội bộ, không cổng host. Runner PoC dùng Python stdlib gọi psql17 trong container, không thêm crate/package. Migrator/runtime không superuser; runtime chỉ SELECT ba bảng tổng hợp. Test fixture rollback; ledger PoC checksum/lock và dump/restore đã kiểm trên engine thật. [Evidence](../../docs/test-reports/database-runtime-2026-10-23.md), [runbook](../database/README.md).

Rollback/recovery: lỗi migration rollback cả DDL/ledger; sau commit giữ database và forward repair có review. Runner không reset/drop. Dữ liệu ở writable layer của container, chưa có volume/backup policy production. Kết quả này không chốt SQLx backend runner, password/hash/pool/lock budget, RPO/RTO hoặc custody/rotation của key. Bốn gap đã sửa bằng forward migration0002; toàn bộ SQL và snapshot đã reimport nằm trong backend/migrations. [Evidence mới](../../docs/test-reports/database-integrity-2026-10-23.md). CP-01/02 và DB-02/03 còn checkpoint riêng.
