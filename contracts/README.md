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

## Authentication/bootstrap contract 0.2.2 (draft)

Password validation addendum2026-10-26 (explicit user change): login accepts
9–128Unicode codepoints; currentPassword remains1–128. New and generated
temporary passwords require9–128, Unicode Uppercase +Lowercase and an ASCII
digit0–9. No special character is required; no trim/normalization. Existing
credentials remain usable for login without the new composition check.
`fixtures/auth/password-policy.json` policyVersion1 is the cross-runtime oracle
used by Rust/Web/Dart tests. This supersedes the old12minimum in this unreleased
draft; login fields stay unchanged, while the artifact version advances to
0.2.2 for the additive realtime-ticket contract. This validation change requires
coordinated provider/client deployment and is not a backward-compatibility claim.

`openapi/auth.v1.json` is the P1 contract artifact for FEAT-TN-001 with the
minimal logout, password, profile preference and workspace-create boundaries
from FEAT-TN-002/004/041/065. `fixtures/auth/scenarios.json` and
`fixtures/auth/workspace-scenarios.json` contain synthetic, nonfunctional
examples. Run the static check:

    python -B -m unittest discover -s contracts/tests -p validate_auth_contract.py -v
    python -B -m unittest discover -s contracts/tests -p test_auth_qa_coverage.py -v
    python -B -m unittest discover -s contracts/tests -p test_logout_contract.py -v

Or run all static checks with `python -B -m unittest discover -s contracts/tests -p '*.py' -v`.

These checks cover references, fixture/status alignment, Web/Android full and
limited login examples, 413/415 request boundaries, Web auth-context mismatch
fixtures and selected security invariants. These static checks do not establish provider
behavior, browser flow, Android secure storage or G1 acceptance.

Latest local execution on 2026-10-24: the full discovery command above ran
36/36 checks and passed. This is static contract evidence only; CP-01 owner
review, provider behavior, browser flow and Android secure-storage evidence
remain outstanding.

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
- Version `0.2.0` adds `X-Auth-Context-Id` to successful Web login and full or
  limited `GET /me` responses. The UUID identifies a Web session for client
  reconciliation; it is not a credential or authorization grant. A protected
  cookie Web request supplies that header, and a missing/mismatched value on an
  authenticated session receives `409 AUTH_CONTEXT_MISMATCH` before data or
  side effects. A missing/invalid cookie still follows its existing auth error.
  Header-free `GET /me` is a discovery request while the UI is locked and must
  not silently bootstrap a pending/unknown login or a new account. Android
  bearer requests do not use this header.
- This is a wire change from `0.1.0`: provider, Web and Mobile owners must
  review the header, status and fixtures at CP-01. Provider/client integration,
  browser cookie-race and Android runtime evidence belong to later checkpoints.
- The default workspace list includes only ACTIVE memberships and ACTIVE
  workspaces. Historical Admin recovery is an explicit filter; list summaries
  are never authorization grants. Create uses a separate detail projection.
- Requests are strict at the boundary. Authentication mutations must not be
  replayed automatically when their response is lost. Error envelope and
  public auth failure semantics are shared across consumers.
- The earlier login and validation fixtures were additive examples under
  contract `0.1.0`. Version `0.2.0` changes Web header/error semantics while
  preserving Web limited cookie/CSRF and Android limited bearer transport.
- `CT-AUTH-ME-LIMITED` is header-free discovery while the Web UI is locked.
  `CT-AUTH-ME-LIMITED-CONFIRMATION` sends the context from a successful Web
  limited login and requires `403 PASSWORD_CHANGE_REQUIRED` with the same
  response context before the password screen opens. The matching 409 fixture
  covers a different cookie session. Neither response exposes a profile or
  membership; Android limited login does not use this Web handshake.

The artifact has no running provider or generated client yet. API/Web/Mobile
owner review of the artifact belongs to CP-01. Approved topology, toolchain
and storage/hash PoC are prerequisites for their respective backend, Web or
Android BUILD tasks at START-03. Provider/security measurements are created
during backend BUILD and checked at CP-02; provider/client compatibility and
browser/device evidence are created during client BUILD and checked at CP-03.

### Login001 validation matrix

`fixtures/auth/login-validation-scenarios.json` retains 33 synthetic login cases
and is labeled with the current draft version `0.2.2`. The shared validator includes this
file in version, operation/status, error-code and transport checks. Run
`python -B -m unittest discover -s contracts/tests -p test_login_contract.py -v`
for six focused checks, or the full discovery command above for regressions.
No dependency was added for these checks.

The examples cover missing/null/type per field, empty values, malformed or
non-object JSON, invalid client enum, authority injection, ASCII email limits
and normalization, and password scalar/whitespace boundaries. Successful
cases require a separate disposable account seeded with exactly the request
password (`given.storedPasswordEqualsRequest`); reset that account between
cases, using the declared synthetic clock only in a test clock adapter.
`given`, `issuedAt` and `assertions` describe setup/expectations, not HTTP fields
or observed state. Send `rawBody` as bytes without JSON reserialization.
These fixtures preserve the wire; provider tests, real Web cookies and Android
storage remain separate checkpoints.

### Logout002 completion of the draft contract

Version `0.2.2` completes logout semantics already selected in feature002
section22 and adds the ticket HTTP response and first-frame WebSocket contract;
it retains the `0.2.0` login/auth-context wire. It does not indicate a provider
release or change the historical FEAT001 QA results. Auth fixtures use the
current artifact version. CP-01 owner review remains pending.

`fixtures/auth/logout-scenarios.json` describes Web/Android active, limited,
revoked and expired sessions; absent/unknown/malformed credentials; body,
mixed-credential, CSRF/context, DB-failure and commit-unknown boundaries; and
expected S1/S2 isolation, idempotent audit and push-binding compare-and-set.
`request.credentialSession`/`credentialAliases` are per-scenario setup aliases,
not HTTP fields or client authority. A provider runner must create isolated lab
sessions, resolve each alias through its real transport and redact credentials.
`given`, `expectedEffects` and `assertions` are requirements, never observed DB
state. No fixture status means a runtime test has passed.

`fixtures/auth/realtime-ticket-scenarios.json` is a synthetic wire matrix for
`POST /api/v1/realtime/tickets` and the `/api/v1/realtime` first-frame handshake.
The ticket string is a nonfunctional 64-hex placeholder; runtime clients must
keep a real ticket only in memory and send it as the first text frame. The
contract extension requires no server frame before validation, a fixed
`AUTHENTICATED` acknowledgment after validation, and a five-second timeout for
an unvalidated socket. These static cases do not prove a PostgreSQL consume or
physical socket close.

- Logout alone includes an empty security requirement `{}` because no
  credential must produce a side-effect-free 204. This representation follows
  [OpenAPI 3.1 Operation Object security](https://spec.openapis.org/oas/v3.1.0.html#operation-object).
  A supplied unknown/malformed credential still receives 401; protected routes
  keep required authentication. The extension `x-logout-policy` records these
  conditional rules, which standard OpenAPI security alternatives cannot express.
- Request body is absent or zero bytes. `{}`, `null` and `[]` are nonempty
  JSON and receive 422; malformed/duplicate JSON 400, over 64 KiB 413 and
  unsupported nonempty media type 415 follow the existing strict boundary.
  The existing shared rate policy can return 429/Retry-After; the example
  value 5 is synthetic, not a new quota or retry budget.
- Recognized Web success sends the exact cookie deletion scope with no Domain.
  Anonymous/App success and every error omit Set-Cookie. Both fresh and inactive
  Web sessions still require context, exact origin and bound CSRF. A mismatched
  context returns 409 before CSRF processing so intent A cannot revoke cookie B.
- A lost commit ACK is UNKNOWN even when HTTP 503 is received; retain local
  lock and reconcile the same session. 204 does not by itself prove every
  socket has closed; that requires per-instance realtime evidence at L3/L6.
- `rawBodyGenerator` uses the encoding defined above; 204 `response.body=null`
  means zero HTTP response bytes, never a JSON `null` payload.

Run the static suite for artifact consistency; then API/Web/Mobile owners
review CP-L1/CP-01. Backend transaction/guards and real browser/Android tests
remain blocked by FEAT001/START-03 and must not be replaced by these fixtures.

### Template draft and published-version contract v1

`openapi/templates.v1.json` and `schemas/templates.v1.schema.json` define the
shared FEAT-TN-005 T1 / FEAT-TN-006 V1 contract for draft create/read/list/patch,
publish, immutable version read/list and clone. The synthetic scenarios and
field reconciliation are documented in `fixtures/templates/README.md` and
`fixtures/templates/scenarios.json`. All template scenarios are
`SPEC_ONLY`/`NOT_RUN`; they are not provider, hardware, G1 or acceptance
evidence. The note records the remaining `mode`/`direction`, command
`safeValue` storage, stream `default`, and published `sourceRevision` integration
gaps.

