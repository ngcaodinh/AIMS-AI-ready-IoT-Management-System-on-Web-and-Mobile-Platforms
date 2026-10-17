# Backend

Rust modular monolith for IAM, Workspace, Device, Template, Telemetry, Command, Dashboard, Automation, Event, Push, Enrollment, OTA, Integration and Audit.

The first Rust workspace is created only after the toolchain decision record is approved by the PoC. Every workspace-scoped request must resolve membership and carry `workspaceId` at each boundary.

Directories:

- `crates/`: application crates grouped by bounded module.
- `migrations/`: additive PostgreSQL migrations.
- `tests/`: integration and contract tests.

