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

## Authentication/bootstrap contract 0.1.0

`openapi/auth.v1.json` is the P1 contract artifact for FEAT-TN-001 with the
minimal logout, password, profile preference and workspace-create boundaries
from FEAT-TN-002/004/041/065. `fixtures/auth/scenarios.json` and
`fixtures/auth/workspace-scenarios.json` contain synthetic, nonfunctional
examples. Run the static check:

    python -B -m unittest discover -s contracts/tests -p validate_auth_contract.py -v
    python -B -m unittest discover -s contracts/tests -p test_auth_qa_coverage.py -v

These checks cover references, fixture/status alignment, Web/Android full and
limited login examples, 413/415 request boundaries and selected security
invariants. These static checks do not establish provider
behavior, browser flow, Android secure storage or G1 acceptance.

For `CT-AUTH-BODY-TOO-LARGE`, `rawBodyGenerator` avoids storing a 65 KiB
literal. `jsonWithTrailingAsciiWhitespace` means UTF-8 encode `prefix`, then
append ASCII spaces until the request body is exactly `totalBytes` bytes.
The resulting body is valid JSON and exceeds the common 64 KiB REST limit by
one byte. Consumers must send those bytes as the HTTP body, without
re-serializing the JSON.

Compatibility decisions carried from ADR-002 and the feature plans:

- `GET /me` is a global self profile with no global `role`; it adds
  `displayTimezone` and `preferencesRevision` from FEAT-TN-041. Workspace role
  comes only from the current membership. This resolves the older shorthand
  “role and preferences” in handoff Core contract 35.
- `WEB` login returns an HttpOnly cookie and no body token. `ANDROID` and the
  server-only `IOS` enum use bearer transport. The iOS UI remains out of scope.
  A client must accept additive response fields while rejecting a Web token.
- The default workspace list includes only ACTIVE memberships and ACTIVE
  workspaces. Historical Admin recovery is an explicit filter; list summaries
  are never authorization grants. Create uses a separate detail projection.
- Requests are strict at the boundary. Authentication mutations must not be
  replayed automatically when their response is lost. Error envelope and
  public auth failure semantics are shared across consumers.
- The four added login and validation fixtures are additive examples under
  contract `0.1.0`; route, DTO and error semantics are unchanged. Web limited
  keeps cookie and CSRF transport; Android limited keeps bearer transport.

The artifact has no running provider or generated client yet. API/Web/Mobile
owner review, provider-client compatibility tests, topology, toolchain and
storage/hash PoC remain required before the corresponding BUILD gate.

