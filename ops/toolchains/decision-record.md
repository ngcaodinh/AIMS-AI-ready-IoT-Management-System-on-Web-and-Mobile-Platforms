# Toolchain compatibility decision record

Status: pending compatibility PoC.

| Component | Candidate | Lock artifact | PoC evidence required | Status |
| --- | --- | --- | --- | --- |
| Rust | Rustup stable toolchain | `rust-toolchain.toml`, `Cargo.lock` | Axum/SQLx build and MQTT event loop | Pending |
| Node/Web | Node 22.13.0 present | `package-lock.json` | TypeScript build and browser smoke test | Pending |
| Flutter | Flutter 3.47.5 / Dart 3.13.4 | `pubspec.lock` | Android, BLE and push PoC | Pending — iOS deferred by ADR-001 |
| ESP-IDF | selected through EIM | ESP-IDF/config/component locks | Board, BLE and dual-slot OTA PoC | Pending |
| PostgreSQL | not selected | Compose/image digest and migration baseline | migration, isolation and restore PoC | Pending |
| Mosquitto | not selected | Compose/image digest and ACL baseline | TLS, ACL and reconnect PoC | Pending |

No entry becomes pinned merely because it is the newest available version. Record the version, owner, date, compatibility evidence and rollback path once each PoC succeeds. iOS is out of scope in the current BA/handoff source documents; a future iOS track requires a new source-document decision and toolchain PoC.
