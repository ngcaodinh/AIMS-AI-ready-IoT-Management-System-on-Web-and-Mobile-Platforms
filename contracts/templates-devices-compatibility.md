# Template, registry and provisioning compatibility

These v1 companion artifacts describe the draft G1 software wire for
FEAT-TN-005–008 at contract version 0.2.0. Use the [OpenAPI](openapi/templates-devices.v1.json),
[shared schema](schemas/device/template-device-provisioning.v1.json), and
[golden cases](fixtures/api/templates-devices.v1.json).

## FEAT-TN-005 draft request and response

WF-TN-005 in the BA and handoff and ADR-004 §Decision define separate axes.
`channelKind` classifies a stream as `TELEMETRY` or `STATE`.
`direction` is `READ`, `WRITE` or `READ_WRITE`. The Rust
`StreamDraft.channel_kind` and `StreamDraft.direction` and the two
`channel_kind` columns added by migration 0018 store that independence.

OQ-TEMPLATE-001 used the old direction spelling `mode`. ADR-004 also records
older BA wording that used `mode` for channel kind. During migration, a request
can supply a known `mode` token for exactly the axis it names and must supply
the other axis explicitly.

| Request stream fields | Result |
| --- | --- |
| `channelKind: STATE, direction: READ` | Canonical `STATE + READ` |
| `mode: READ, channelKind: STATE` | Canonical `STATE + READ` |
| `mode: STATE, direction: READ` | Canonical `STATE + READ` |
| `mode` alone, unknown token, same axis repeated, or both canonical fields plus `mode` | 422 validation error |

The compatibility rule only decodes requests. Each axis is explicitly given.
Every response uses both canonical fields. Clients should migrate by writing
`channelKind` and `direction` directly, choose the missing axis from the
stream's actual purpose when migrating a mode-only source, and retain
`STATE + READ` for reported state. This adapter does not infer a channel kind
from direction or authorize a control. It does not backfill persisted rows.

OQ-TEMPLATE-005 places `safeValue` on `commands[].safeValue`. Each writable
NUMBER, BOOLEAN or ENUM stream requires exactly one `SET_VALUE` pointing to
its same-template key. A provider maps the typed value to
`StreamDraft.safe_value` and reconstructs the command from the persisted
capability. READ/STRING streams have no command. Each candidate validates
command uniqueness, references, type and range together with the streams.
`streams[].safeValue` is rejected. The independent optional
`streams[].default` from OQ-TEMPLATE-003 must round trip in draft and snapshot
and is typed and bounded. It supplies no live value, command, or physical
safety evidence. Existing exact decimal ENUM members can be preserved on
read from historical storage; new request ENUM members are strings.

The wire's `type`, `min`, and `max` map to Rust's `data_type`,
`minimum` and `maximum`. G1 adds neither a client authority field nor a
client display-name/description field. PATCH replaces each provided array
in full and validates the combined candidate under the current root CAS.

## FEAT-TN-006 and FEAT-TN-007 snapshot identity

ADR-002 DEC-02/03 and OQ-PUBLISH-002/005 distinguish the published UUID, the
per-family version sequence, root CAS revision, source draft revision and
JSON format version. Reads by snapshot UUID or in unfiltered pages report
a legacy snapshot without recorded provenance as `sourceRevision: null`.
Use an exact positive source revision to recover an uncertain publish. A
legacy snapshot with unknown provenance is excluded from that lookup.
Successful new publication requires a known positive `sourceRevision` and
returns the root revision from that publication. A device pins the immutable `version.id` UUID through
`templateVersionId`. The credential bundle uses the same UUID under the
historical wire key `templateVersion`. FEAT-TN-053/054
`supportedTemplateVersions` is exact UUID membership. Finding version
sequence 1 in another family cannot satisfy this check. An earlier snapshot
stays eligible when the family opens a new draft. A registration reserves
identity with `REGISTERED`, `UNKNOWN` and `PROVISIONING`.

## FEAT-TN-008 polling and one-time delivery

ADR-002 DEC-03/05 and FEAT-TN-008 §8.6 define nested
`operation.kind` as `CREDENTIAL`, `DEVICE_LIFECYCLE` or
`ENROLLMENT_CLEANUP`. The latter two projections follow FEAT-TN-039/052.
The outer kind is `STATUS` for poll or metadata replay, `PENDING` for
accepted pending issuance, and `BUNDLE` for one-time disclosure on the
authorized USB response path. Strict poll projections carry no bundle,
password, ciphertext or verifier. Unknown operation kinds fail closed.
`secretAvailable` is metadata. Current authorization, initiator,
USB delivery mode, generation and expiry govern the claim transaction.

The USB issuance contract allows a pending response and metadata replay.
The claim route requires trusted broker evidence for one-time delivery.
A synchronous 201 requires a broker adapter that can confirm all steps
within the create request. Lifecycle and cleanup poll producers belong to
FEAT-TN-039 and FEAT-TN-052.

## FEAT-TN-008 MQTT ACL profile

The golden ACL fixture binds the client ID to the registry Device UUID.
Under `iot/v1/devices/{deviceId}/`, the device publishes
`telemetry`, `hello`, `heartbeat` and `results`. It subscribes to and
receives `commands` and `receipts`. The six exact grants use QoS 1 and
retain false. Broker verification covers both device directions, cross-UUID
denial, TLS and session/generation provenance before ingress admission.

## Standalone contract and schema scope

Apply 0024 before starting readers or writers that use typed stream defaults.
The nullable columns preserve old rows and legacy inserts. Switch every
template writer and pinned-schema reader to the default-aware codec before
accepting default-bearing published snapshots. A snapshot without defaults
keeps the original digest encoding. Draft creation, model changes, and new
registration require a model allowlist supplied by trusted composition.

This slice carries draft interface artifacts and the 0024 storage expansion.
Endpoint activation, provider/consumer parity and model approval have
separate release gates. Public publish and exact source-revision recovery
require agreement on the shared provenance migration and writer. USB
issuance and claim require an approved escrow adapter and broker
reconciliation evidence.

## Evidence boundaries

The fixtures contain synthetic identifiers and a nonfunctional placeholder for
the one-time credential field. They are interface examples. A provider must
enforce duplicate-key handling, UTF-8/64 KiB, NFC, candidate-level invariants,
workspace authorization, CAS, recovery and delivery transitions. Client/provider
parity and the release gate need runtime evidence. Board/BOM/driver and
physical safeValue approval, signed firmware, production broker and two-board
tests have separate evidence gates.
