# Shared contracts and model standards

This directory is the versioned source of truth shared by backend, web, mobile, firmware and simulator.

## Standards

- JSON uses UTF-8, English `camelCase` fields and explicit `schemaVersion` when a payload is versioned.
- Public REST routes are under `/api/v1`; additive changes require a compatibility note and matching fixtures.
- All workspace-scoped request/response, WebSocket and asynchronous models include the resolved workspace context. The server derives it; clients do not submit trusted `workspaceId` fields.
- Device identity is a global UUID. MQTT topics stay under `iot/v1/devices/{globalDeviceId}/…`; payload workspace values are never trusted for authorisation.
- Models use stable opaque identifiers, UTC timestamps and explicit state values. No secret, credential, PoP, signing material or Wi-Fi password appears in schemas or fixtures.
- Each contract change must include success, validation, authorisation, stale-revision and duplicate-delivery fixtures where relevant.

## Layout

- `openapi/`: versioned HTTP and WebSocket descriptions.
- `schemas/`: device, dashboard and rule JSON schemas.
- `fixtures/`: shared API and messaging examples with synthetic values only.

