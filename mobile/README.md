# Mobile client

Flutter/Dart application for Android in the current implementation scope. Native Kotlin bridges are limited to BLE SDK integration when necessary; business logic stays in Dart and Rust.

iOS is explicitly out of scope in the BA/handoff source documents; see [ADR-001](../docs/adr/adr-001-defer-ios-client.md). The Flutter project will be generated after the Android/BLE PoC and toolchain pin decision.
