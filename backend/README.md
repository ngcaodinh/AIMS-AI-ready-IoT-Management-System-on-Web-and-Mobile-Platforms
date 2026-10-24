# Backend

Rust modular monolith for IAM, Workspace, Device, Template, Telemetry, Command, Dashboard, Automation, Event, Push, Enrollment, OTA, Integration and Audit.

Workspace Rust đã build/test trên toolchain1.99.1 GNU và SQLx0.8.6. [Clean Architecture](ARCHITECTURE.md) tách domain → application ports ← PostgreSQL/crypto adapters; mọi scope đọc quyền hiện hành, không tin workspaceId hoặc role từ client.

Database canonical: `iot_platform_lab`; [runbook](migrations/platform/README.md), [DBeaver local](../ops/database/DBEAVER.md). Chỉ giữ mẫu cấu hình tại [.env.example](.env.example); không commit credential thật. Endpoint mẫu hiện là inspection read-only. Integration runner cấp role SCRAM tạm riêng, không dùng reader làm writer và không đọc file secret. [Trạng thái từng task](../docs/plan/database/full-plan-status.md) phân biệt81 repository checks với các module/gate chưa triển khai.

Directories:

- `crates/domain/`: entities, value objects, policy và validation thuần.
- `crates/application/`: use case và ports giữ atomic boundary.
- `crates/postgres/`: SQLx adapter, locks, queries và physical transaction.
- `src/adapters/`: bounded Argon2id/CSPRNG/HMAC implementation.
- `migrations/`: additive PostgreSQL migrations.
- `tests/`: integration and contract tests.

Kiểm từ thư mục `backend`: `cargo test --workspace --all-features --locked`,
`cargo clippy --workspace --all-targets --all-features --locked -- -D warnings`.
Từ root: `python -B ops/database/verify_repositories.py` chạy use case thật
trên cùng DB với fixture/role cleanup; `python -B ops/database/verify_platform.py verify`
kiểm schema/restore. Các runner không được chạy song song vì verifier schema yêu cầu
DB không có dữ liệu ứng dụng. Toolchain/linker hiện được pin cho máy Windows GNU này;
Linux/production cần PoC riêng. Chưa có HTTP server, worker delivery hoặc release gate PASS.

