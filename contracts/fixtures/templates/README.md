# Template contract v1 compatibility note

These files are the shared, versioned contract draft for FEAT-TN-005 T1 and
FEAT-TN-006 V1:

- `../../openapi/templates.v1.json` describes the `/api/v1/templates` draft,
  publish, immutable-version read/list and clone operations.
- `../../schemas/templates.v1.schema.json` defines reusable request, response
  and error payload schemas.
- `scenarios.json` is a shared golden scenario set. Every case is marked
  `SPEC_ONLY`; the set says `execution.status: NOT_RUN`. Its expected values
  are contract requirements, not observed service behavior or test results.

## Frozen identities and concurrency

`schemaVersion: 1` identifies the payload format. A draft root's `revision` is
its compare-and-set revision, sent as a quoted integer in `If-Match`. A
published snapshot's UUID `id` is the exact immutable version identity; its
integer `version` is the sequence within one template family. These values are
not interchangeable.

For publish, the request has no body and requires the current workspace context
and `If-Match`. Missing preconditions return 428; a stale revision returns 412
`VERSION_CONFLICT`. The revision comparison happens before the status check,
so a concurrent loser observes 412 even if the winner has just published. A
fresh request against an already-published root returns 409
`IMMUTABLE_SCHEMA`. A successful publish returns the incremented root revision
outside the version snapshot. `version.sourceRevision` records the exact draft
revision named by the successful `If-Match`; it is the recovery key after a
lost publish acknowledgement. It is not the post-commit root revision.

The fixtures pin v1 and v2 to distinct synthetic UUIDs. They show source
revisions 1 and 4, with post-publish root revisions 2 and 5. They also show
cloning the current or an older pinned version into the one current draft while
preserving the latest-published pointer. A clone increments root revision;
another draft for the same family returns 409 `DRAFT_EXISTS`. The model cannot
change within a family after its first publication.

## Field reconciliation and remaining incompatibilities

| Concern | Contract draft | Existing evidence and integration gap |
| --- | --- | --- |
| Stream identity and access | `key`, `type`, `channelKind`, and `direction` are separate fields. `direction` is `READ`, `WRITE`, or `READ_WRITE`. | Accepted ADR-004 (`docs/adr/adr-004-channel-kind-and-direction.md`, local-only source read from the original checkout) resolves the wire choice: use `channelKind` plus `direction` as independent fields and reject ambiguous `mode`. FEAT-TN-005 OQ-TEMPLATE-001 and its local plan text still say `mode`; reconcile that wording with ADR-004 before provider/client integration. This naming decision is separate from the product mapping gaps below. |
| Command safe value | `commands[]` carries `{type: SET_VALUE, stream, safeValue}`. | The publish response adapter maps the persisted per-stream `safe_value` to one `SET_VALUE` command for each writable stream. Storage remains per-stream; draft create/patch wire adapters are not implemented here. This is structural mapping only. Fixture values remain synthetic and are not model-approved or physically safe. |
| Default and storage-only fields | Optional typed `default` is allowed; stream DTO fields follow the shared schema. | Domain/storage do not represent `default`, so publish responses omit it and never synthesize a value. Storage also contains `display_name` and `string_max_length`, which have no field in this v1 wire DTO; reconcile if BA/client flows require them before CRUD UI integration. |
| Published source revision | `version.sourceRevision` is the pre-publish draft revision; the response's outer `revision` is the post-commit root revision. Historical pre-0022 versions return `sourceRevision: null` on read/list while a new publish always requires an integer `>= 1`. | Local application/Postgres code now stores both separately in migration `0022_template_version_revisions.sql`; the publish service binds the locked pre-publish revision and checked post-commit revision in the same transaction as the snapshot/root update/audit. Existing rows remain NULL/unknown, with no inferred backfill; `TemplateVersionSnapshot` and `TemplateVersionListItem` accept `null`, whereas `PublishedTemplateVersionSnapshot` inside `PublishResponse` requires an integer. The migration and SQL/provider behavior have not been applied or runtime-verified. |
| Description | Not present in the accepted wire payload. | The domain has a description field, but BA/handoff/approved plan evidence does not include it in this request. It is not added here. |
| Model and physical safety | `model` is a stable opaque ID; `safeValue` and `default` follow only the structural rules above. | The new publication shape check does not invent a production model allowlist. Fixture IDs and values are synthetic, not approved models/safe values, BOM/driver compatibility, or physical validation. Model registry, hardware/BOM/driver PoC, and safe-value evidence remain separate gates. |
| Device compatibility projection | The fixture's `supportedTemplateVersions` contains exact v1/v2 UUID pins. | This is a spec-only projection for FEAT-TN-053 mapping. It is not a signed manifest, OTA/integration fixture, or evidence that an installed device supports either version. FEAT-TN-007 consumer integration and FEAT-TN-053 signed OTA evidence remain separate dependencies. |

## Plan consumption and limits

FEAT-TN-005 T1 consumes the draft input, patch, root/list, validation and
precondition contracts plus the `CT-TEMPLATE-*` create/read/list/patch,
non-admin denial, and cross-workspace root GET/PATCH redaction scenarios.
FEAT-TN-006 V1 consumes publish response, immutable snapshot,
version list/read, clone request/root and the `CT-PUBLISH-*` revision, recovery,
v1/v2 pin and conflict scenarios, plus the `IT-PUBLISH-003` D1 pin invariant.
Both plans can use the same frozen schema format and shared stream/command
shapes. The local Rust change adds an authenticated, dependency-injected publish
router and persisted revision provenance only. The router is mountable but is
not wired into `auth_router`, Auth Lab, or a production server composition root.
T1 create/read/list/patch and V1 version list/read/clone are still not runtime
endpoints in this change.

The top-level `specOnlyDevicePinInvariant` in `scenarios.json` records D1's
`Device.templateVersionId` as v1 before and after the existing v2 publish
scenario. It is data/invariant evidence only: it defines no device endpoint and
does not imply runtime, hardware PoC, signed-manifest, or physical-compatibility
evidence.

The fixture set remains `SPEC_ONLY` / `NOT_RUN`; it is not an API test result.
No HTTP, Cargo, SQL, or database runner was executed. The migration has not been
applied, and the mountable router has not been mounted or deployed. These files
do not establish runtime API behavior, physical safety, hardware/model
compatibility, G1, feature acceptance, or a PASS result. Resolve the remaining
field gaps above and complete the separate FEAT-TN-007/053 and hardware evidence
before making those claims.
