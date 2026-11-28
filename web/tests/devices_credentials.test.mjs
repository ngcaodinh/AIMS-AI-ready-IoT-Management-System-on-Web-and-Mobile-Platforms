import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import {
  assessSerialRecoveryOutcome,
  buildDeviceCreatePayload,
  canClaimUsbCredential,
  generateIdempotencyKey,
  parseActiveMembersPageDto,
  parseClaimCredentialResponse,
  parseCreateCredentialResponse,
  parseDeviceRegisteredDto,
  parseProvisioningPollResponse,
  validateCanonicalSerial,
} from '../src/features/devices/deviceContract.ts';
import {
  claimUsbCredentialApi,
  issueDeviceCredentialApi,
  listActiveOwnersForRegistrationApi,
  listPublishedVersionsForRegistrationApi,
  pollProvisioningOperationApi,
  recoverDeviceBySerialApi,
  registerDeviceApi,
} from '../src/features/devices/deviceApi.ts';
import { WorkspaceApiError } from '../src/features/workspace/workspaceApi.ts';

const WORKSPACE_ID = '00000000-0000-4000-8000-000000000001';
const VERSION_UUID = '00000000-0000-4000-8000-000000000003';
const OWNER_UUID = '00000000-0000-4000-8000-000000000005';
const DEVICE_UUID = '00000000-0000-4000-8000-000000000006';
const OP_UUID = '00000000-0000-4000-8000-000000000007';
const CRED_UUID = '00000000-0000-4000-8000-000000000013';

const CTX = {
  workspaceId: WORKSPACE_ID,
  session: {
    contextId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    csrfToken: '<synthetic-csrf-token>',
  },
};

const SYNTHETIC_DEVICE = {
  id: DEVICE_UUID,
  workspaceId: WORKSPACE_ID,
  ownerId: OWNER_UUID,
  templateVersionId: VERSION_UUID,
  serial: 'synthetic-room-001',
  name: 'Room device',
  model: 'SYNTHETIC-ROOM',
  room: null,
  tags: [],
  lifecycle: 'REGISTERED',
  connectivity: 'UNKNOWN',
  lastSeen: null,
  firmwareVersion: null,
  firmwareDigest: null,
  hardwareRevision: null,
  credentialStatus: 'PROVISIONING',
  maintenance: 'NONE',
  capabilities: [{ type: 'SET_VALUE', stream: 'fan', safeValue: false }],
  revision: 1,
  createdAt: '2026-11-27T05:00:00Z',
  updatedAt: '2026-11-27T05:00:00Z',
};

/** Tạo Response JSON tổng hợp trong RAM; không mở kết nối mạng thật. */
function jsonResponse(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' },
  });
}

test('serial validation enforces exact ASCII pattern without trimming and buildDeviceCreatePayload pins UUID',
  /** Kiểm tra OQ-DEVICE-001 serial không tự trim và pin phải là templateVersionId UUID. */
  () => {
    assert.equal(validateCanonicalSerial('synthetic-room-001'), true);
    assert.equal(validateCanonicalSerial(' synthetic-room-001'), false);
    assert.equal(validateCanonicalSerial('synthetic-room-001 '), false);
    assert.equal(validateCanonicalSerial('thiết-bị-01'), false);

    assert.throws(
      () => buildDeviceCreatePayload({
        serial: 'synthetic-room-001',
        name: 'Room device',
        model: 'SYNTHETIC-ROOM',
        templateVersionId: '1', // CT-DEVICE-UUID-NOT-SEQUENCE
        ownerId: OWNER_UUID,
      }),
      (err) => err instanceof WorkspaceApiError && err.status === 422,
    );
  },
);

test('registerDeviceApi parses CT-DEVICE-REGISTERED and serial recovery detects intent match or conflict',
  /** Kiểm tra 007 D4: 201 REGISTERED/UNKNOWN/PROVISIONING + SELECT_SETUP_METHOD và đối soát exact serial recovery. */
  async () => {
    globalThis.window = { setTimeout, clearTimeout };
    globalThis.fetch = async (url, init) => {
      if (init.method === 'POST' && url === '/api/v1/devices') {
        return jsonResponse({
          ...SYNTHETIC_DEVICE,
          nextStep: { type: 'SELECT_SETUP_METHOD', methods: ['USB', 'QR_BLE'] },
        }, 201);
      }
      if (init.method === 'GET' && url === '/api/v1/devices?serial=synthetic-room-001') {
        return jsonResponse({ items: [SYNTHETIC_DEVICE], nextCursor: null }, 200);
      }
      throw new Error(`Unexpected ${init.method} ${url}`);
    };

    const registered = await registerDeviceApi(CTX, {
      serial: 'synthetic-room-001',
      name: 'Room device',
      model: 'SYNTHETIC-ROOM',
      templateVersionId: VERSION_UUID,
      ownerId: OWNER_UUID,
    });
    assert.equal(registered.lifecycle, 'REGISTERED');
    assert.equal(registered.connectivity, 'UNKNOWN');
    assert.equal(registered.credentialStatus, 'PROVISIONING');
    assert.deepEqual(registered.nextStep.methods, ['USB', 'QR_BLE']);

    const page = await recoverDeviceBySerialApi(CTX, 'synthetic-room-001');
    assert.equal(page.items.length, 1);
    assert.equal(
      assessSerialRecoveryOutcome(
        { ownerId: OWNER_UUID, model: 'SYNTHETIC-ROOM', templateVersionId: VERSION_UUID },
        page.items[0],
      ),
      'MATCHES_INTENT',
    );
    assert.equal(
      assessSerialRecoveryOutcome(
        { ownerId: '00000000-0000-4000-8000-000000000099', model: 'SYNTHETIC-ROOM', templateVersionId: VERSION_UUID },
        page.items[0],
      ),
      'CONFLICTS_WITH_INTENT',
    );
  },
);

test('parseDeviceRegisteredDto rejects lastSeenAt spelling or non-REGISTERED initial state',
  /** Kiểm tra contract strict từ chối spelling sai lastSeenAt hoặc lifecycle ACTIVE giả ngay khi đăng ký. */
  () => {
    const badLastSeenAt = {
      ...SYNTHETIC_DEVICE,
      lastSeenAt: null,
      nextStep: { type: 'SELECT_SETUP_METHOD', methods: ['USB', 'QR_BLE'] },
    };
    delete badLastSeenAt.lastSeen;
    assert.throws(
      () => parseDeviceRegisteredDto(badLastSeenAt),
      (err) => err instanceof WorkspaceApiError && err.code === 'PROTOCOL_ERROR',
    );

    assert.throws(
      () => parseDeviceRegisteredDto({
        ...SYNTHETIC_DEVICE,
        lifecycle: 'ACTIVE',
        nextStep: { type: 'SELECT_SETUP_METHOD', methods: ['USB', 'QR_BLE'] },
      }),
      (err) => err instanceof WorkspaceApiError && err.code === 'PROTOCOL_ERROR',
    );
  },
);

test('provisioning poll parses explicit kind variants and rejects unknown kind or secret leakage',
  /** Kiểm tra 008 CRED-4: poll phân biệt 3 kind tường minh và fail closed với 4 rejectedResponses trong G1. */
  async () => {
    const usbAvailable = parseProvisioningPollResponse({
      kind: 'STATUS',
      operation: {
        kind: 'CREDENTIAL',
        operationId: OP_UUID,
        deviceId: DEVICE_UUID,
        deliveryMode: 'USB_ONE_TIME',
        status: 'READY',
        deliveryStatus: 'AVAILABLE',
        secretAvailable: true,
        escrowExpiresAt: '2026-11-27T05:10:00Z',
        claimedAt: null,
        errorCode: null,
        retryCount: 0,
      },
    });
    assert.equal(canClaimUsbCredential(usbAvailable.operation), true);

    const bleAvailable = parseProvisioningPollResponse({
      kind: 'STATUS',
      operation: {
        kind: 'CREDENTIAL',
        operationId: OP_UUID,
        deviceId: DEVICE_UUID,
        deliveryMode: 'ENROLLMENT_BLE',
        status: 'READY',
        deliveryStatus: 'AVAILABLE',
        secretAvailable: true,
        escrowExpiresAt: '2026-11-27T05:10:00Z',
        claimedAt: null,
        errorCode: null,
        retryCount: 0,
      },
    });
    assert.equal(canClaimUsbCredential(bleAvailable.operation), false);

    const lifecycle = parseProvisioningPollResponse({
      kind: 'STATUS',
      operation: {
        kind: 'DEVICE_LIFECYCLE',
        operationId: OP_UUID,
        deviceId: DEVICE_UUID,
        type: 'RESUME',
        status: 'PENDING',
        lifecycle: 'SUSPENDED',
        connectivity: 'UNKNOWN',
        credentialStatus: 'PROVISIONING',
        brokerStatus: 'PENDING',
        revision: 2,
      },
    });
    assert.equal(lifecycle.operation.kind, 'DEVICE_LIFECYCLE');
    assert.equal(canClaimUsbCredential(lifecycle.operation), false);

    const cleanup = parseProvisioningPollResponse({
      kind: 'STATUS',
      operation: {
        id: OP_UUID,
        kind: 'ENROLLMENT_CLEANUP',
        enrollmentId: '00000000-0000-4000-8000-000000000009',
        state: 'FAILED',
        reason: 'EXPIRED',
        applicationBlocked: true,
        escrowPurged: true,
        brokerRevocation: 'PENDING',
        boardCleanup: 'UNKNOWN',
        attempts: 1,
        nextAttemptAt: '2026-11-27T05:10:00Z',
        lastError: 'BROKER_UNAVAILABLE',
      },
    });
    assert.equal(cleanup.operation.kind, 'ENROLLMENT_CLEANUP');
    assert.equal(canClaimUsbCredential(cleanup.operation), false);

    const rejectedFixtures = [
      // UNKNOWN-OPERATION-KIND
      {
        kind: 'STATUS',
        operation: {
          kind: 'FUTURE_OPERATION',
          operationId: OP_UUID,
          deviceId: DEVICE_UUID,
          deliveryMode: 'USB_ONE_TIME',
          status: 'PENDING',
          deliveryStatus: 'PENDING',
          secretAvailable: false,
          escrowExpiresAt: '2026-11-27T05:10:00Z',
          claimedAt: null,
          errorCode: null,
          retryCount: 0,
        },
      },
      // UNEXPECTED-POLL-BUNDLE
      {
        kind: 'BUNDLE',
        operation: {
          kind: 'CREDENTIAL',
          operationId: OP_UUID,
          deviceId: DEVICE_UUID,
          deliveryMode: 'USB_ONE_TIME',
          status: 'READY',
          deliveryStatus: 'CLAIMED',
          secretAvailable: false,
          escrowExpiresAt: '2026-11-27T05:10:00Z',
          claimedAt: '2026-11-27T05:00:00Z',
          errorCode: null,
          retryCount: 0,
        },
        credential: {
          deviceId: DEVICE_UUID,
          credentialId: CRED_UUID,
          brokerHost: 'broker.example.test',
          brokerPort: 8883,
          clientId: 'synthetic-room-client',
          username: 'synthetic-username',
          password: '<synthetic-placeholder>',
          templateVersion: VERSION_UUID,
          expiresAt: '2026-11-27T05:10:00Z',
        },
      },
      // POLL-OUTER-SECRET
      {
        kind: 'STATUS',
        operation: {
          kind: 'CREDENTIAL',
          operationId: OP_UUID,
          deviceId: DEVICE_UUID,
          deliveryMode: 'USB_ONE_TIME',
          status: 'READY',
          deliveryStatus: 'CLAIMED',
          secretAvailable: false,
          escrowExpiresAt: '2026-11-27T05:10:00Z',
          claimedAt: '2026-11-27T05:00:00Z',
          errorCode: null,
          retryCount: 0,
        },
        credential: { password: '<synthetic-placeholder>' },
      },
      // POLL-NESTED-SECRET
      {
        kind: 'STATUS',
        operation: {
          kind: 'CREDENTIAL',
          operationId: OP_UUID,
          deviceId: DEVICE_UUID,
          deliveryMode: 'USB_ONE_TIME',
          status: 'READY',
          deliveryStatus: 'CLAIMED',
          secretAvailable: false,
          escrowExpiresAt: '2026-11-27T05:10:00Z',
          claimedAt: '2026-11-27T05:00:00Z',
          errorCode: null,
          retryCount: 0,
          password: '<synthetic-placeholder>',
        },
      },
    ];

    for (const payload of rejectedFixtures) {
      assert.throws(
        () => parseProvisioningPollResponse(payload),
        (err) => err instanceof WorkspaceApiError && err.code === 'PROTOCOL_ERROR',
      );
    }
  },
);

test('issueDeviceCredentialApi and claimUsbCredentialApi send empty body, Idempotency-Key and enforce one-time bundle schema',
  /** Kiểm tra create/claim gửi body rỗng + Idempotency-Key, nhận bundle có templateVersion UUID, và map 409/410 đúng mã. */
  async () => {
    const requests = [];
    globalThis.window = { setTimeout, clearTimeout };
    globalThis.fetch = async (url, init) => {
      requests.push({ url, init });
      if (url.endsWith('/credentials')) {
        return jsonResponse({
          kind: 'PENDING',
          operation: {
            kind: 'CREDENTIAL',
            operationId: OP_UUID,
            deviceId: DEVICE_UUID,
            deliveryMode: 'USB_ONE_TIME',
            status: 'PENDING',
            deliveryStatus: 'PENDING',
            secretAvailable: false,
            escrowExpiresAt: '2026-11-27T05:10:00Z',
            claimedAt: null,
            errorCode: null,
            retryCount: 0,
          },
        }, 202);
      }
      if (url.endsWith('/claim-credential')) {
        if (init.headers['Idempotency-Key'] === 'expired-key-000001') {
          return jsonResponse({
            error: {
              code: 'CREDENTIAL_ESCROW_EXPIRED',
              message: 'Expired',
              correlationId: '00000000-0000-4000-8000-000000000021',
              details: {},
            },
          }, 410);
        }
        return jsonResponse({
          kind: 'BUNDLE',
          operation: {
            kind: 'CREDENTIAL',
            operationId: OP_UUID,
            deviceId: DEVICE_UUID,
            deliveryMode: 'USB_ONE_TIME',
            status: 'READY',
            deliveryStatus: 'CLAIMED',
            secretAvailable: false,
            escrowExpiresAt: '2026-11-27T05:10:00Z',
            claimedAt: '2026-11-27T05:00:00Z',
            errorCode: null,
            retryCount: 0,
          },
          credential: {
            deviceId: DEVICE_UUID,
            credentialId: CRED_UUID,
            brokerHost: 'broker.example.test',
            brokerPort: 8883,
            clientId: 'synthetic-room-client',
            username: 'synthetic-username',
            password: '<synthetic-placeholder>',
            templateVersion: VERSION_UUID,
            expiresAt: '2026-11-27T05:10:00Z',
          },
        }, 200);
      }
      if (url.includes('/provisioning-operations/')) {
        return jsonResponse({
          kind: 'STATUS',
          operation: {
            kind: 'CREDENTIAL',
            operationId: OP_UUID,
            deviceId: DEVICE_UUID,
            deliveryMode: 'USB_ONE_TIME',
            status: 'READY',
            deliveryStatus: 'AVAILABLE',
            secretAvailable: true,
            escrowExpiresAt: '2026-11-27T05:10:00Z',
            claimedAt: null,
            errorCode: null,
            retryCount: 0,
          },
        }, 200);
      }
      throw new Error(`Unexpected URL: ${url}`);
    };

    const key = generateIdempotencyKey();
    assert.ok(key.length >= 16 && key.length <= 128);

    const pending = await issueDeviceCredentialApi(CTX, DEVICE_UUID, key);
    assert.equal(pending.kind, 'PENDING');
    assert.equal(requests[0].init.body, undefined);
    assert.equal(requests[0].init.headers['Idempotency-Key'], key);

    const polled = await pollProvisioningOperationApi(CTX, OP_UUID);
    assert.equal(canClaimUsbCredential(polled.operation), true);

    const claimed = await claimUsbCredentialApi(CTX, OP_UUID, generateIdempotencyKey());
    assert.equal(claimed.kind, 'BUNDLE');
    if (claimed.kind === 'BUNDLE') {
      assert.equal(claimed.credential.templateVersion, VERSION_UUID);
    }

    await assert.rejects(
      () => claimUsbCredentialApi(CTX, OP_UUID, 'expired-key-000001'),
      (err) => err instanceof WorkspaceApiError && err.status === 410 && err.code === 'CREDENTIAL_ESCROW_EXPIRED',
    );
  },
);

test('create and claim parsers handle 201 bundle, 200 metadata replay and active member parsing',
  /** Kiểm tra các biến thể parser cho 201 direct bundle, 200 STATUS replay và danh sách thành viên ACTIVE. */
  () => {
    const direct = parseCreateCredentialResponse(201, {
      kind: 'BUNDLE',
      operation: {
        kind: 'CREDENTIAL',
        operationId: OP_UUID,
        deviceId: DEVICE_UUID,
        deliveryMode: 'USB_ONE_TIME',
        status: 'READY',
        deliveryStatus: 'CLAIMED',
        secretAvailable: false,
        escrowExpiresAt: '2026-11-27T05:10:00Z',
        claimedAt: '2026-11-27T05:00:00Z',
        errorCode: null,
        retryCount: 0,
      },
      credential: {
        deviceId: DEVICE_UUID,
        credentialId: CRED_UUID,
        brokerHost: 'broker.example.test',
        brokerPort: 8883,
        clientId: 'synthetic-room-client',
        username: 'synthetic-username',
        password: '<synthetic-placeholder>',
        templateVersion: VERSION_UUID,
        expiresAt: '2026-11-27T05:10:00Z',
      },
    });
    assert.equal(direct.kind, 'BUNDLE');

    const replay = parseClaimCredentialResponse({
      kind: 'STATUS',
      operation: {
        kind: 'CREDENTIAL',
        operationId: OP_UUID,
        deviceId: DEVICE_UUID,
        deliveryMode: 'USB_ONE_TIME',
        status: 'READY',
        deliveryStatus: 'CLAIMED',
        secretAvailable: false,
        escrowExpiresAt: '2026-11-27T05:10:00Z',
        claimedAt: '2026-11-27T05:00:00Z',
        errorCode: null,
        retryCount: 0,
      },
    });
    assert.equal(replay.kind, 'STATUS');

    const members = parseActiveMembersPageDto({
      items: [{
        workspaceId: WORKSPACE_ID,
        userId: OWNER_UUID,
        email: 'admin@example.test',
        alias: null,
        role: 'ADMIN',
        status: 'ACTIVE',
        authzVersion: 1,
        revision: 1,
      }],
      nextCursor: null,
    });
    assert.equal(members.items.length, 1);
    assert.equal(members.items[0].userId, OWNER_UUID);
  },
);

test('USB credential and device modules never persist secrets in storage or log to console',
  /** Kiểm tra tĩnh bảo đảm code FE mới không dùng localStorage/sessionStorage/console cho bí mật USB hoặc state. */
  () => {
    const files = [
      '../src/features/workspace/workspaceApi.ts',
      '../src/features/templates/templateContract.ts',
      '../src/features/templates/templateApi.ts',
      '../src/features/templates/TemplatePublishPanel.tsx',
      '../src/features/templates/TemplatesWorkbench.tsx',
      '../src/features/devices/deviceContract.ts',
      '../src/features/devices/deviceApi.ts',
      '../src/features/devices/DeviceRegistrationPanel.tsx',
      '../src/features/devices/UsbCredentialPanel.tsx',
      '../src/features/devices/DevicesPage.tsx',
    ];
    for (const relPath of files) {
      const source = readFileSync(new URL(relPath, import.meta.url), 'utf8');
      assert.equal(
        /(window\.)?(localStorage|sessionStorage)\s*[.\[]|console\.(log|info|debug|warn|error)\s*\(/.test(source),
        false,
        relPath,
      );
    }
  },
);

test('registration dependency loaders follow cursor pagination across later pages and exclude ARCHIVED roots while keeping DRAFT-root pins',
  /** Hồi quy INT-0508-REG-PAGINATION + INT-0508-REG-ARCHIVED-PIN: phân trang hết mọi trang cursor, bỏ qua root ARCHIVED và giữ pin lịch sử của root DRAFT/PUBLISHED. */
  async () => {
    const TPL_PAGE_1 = '00000000-0000-4000-8000-000000000011';
    const TPL_ARCHIVED = '00000000-0000-4000-8000-000000000012';
    const TPL_DRAFT_PIN = '00000000-0000-4000-8000-000000000013';
    const TPL_UNPUBLISHED_DRAFT = '00000000-0000-4000-8000-000000000014';
    const VER_P1 = '00000000-0000-4000-8000-000000000021';
    const VER_P2 = '00000000-0000-4000-8000-000000000022';
    const VER_ARCHIVED = '00000000-0000-4000-8000-000000000023';
    const VER_DRAFT_HIST = '00000000-0000-4000-8000-000000000024';
    const OWNER_P2 = '00000000-0000-4000-8000-000000000032';

    const makeTpl = (id, name, status, versionId) => ({
      id,
      workspaceId: WORKSPACE_ID,
      status,
      schemaVersion: 1,
      revision: 2,
      latestPublishedVersionId: versionId,
      name,
      model: 'SYNTHETIC-ROOM',
      streams: [{ key: 't', type: 'NUMBER', channelKind: 'TELEMETRY', direction: 'READ' }],
      commands: [],
      createdAt: '2026-11-27T04:00:00Z',
      updatedAt: '2026-11-27T04:00:00Z',
    });

    const makeVer = (id, tplId, version) => ({
      id,
      workspaceId: WORKSPACE_ID,
      templateId: tplId,
      version,
      schemaVersion: 1,
      status: 'PUBLISHED',
      name: `Tpl v${version}`,
      model: 'SYNTHETIC-ROOM',
      streams: [{ key: 't', type: 'NUMBER', channelKind: 'TELEMETRY', direction: 'READ' }],
      commands: [],
      sourceRevision: 1,
      publishedAt: '2026-11-27T04:00:00Z',
    });

    globalThis.window = { setTimeout, clearTimeout };
    globalThis.fetch = async (url) => {
      if (url === '/api/v1/templates?limit=100') {
        return jsonResponse({
          items: [
            makeTpl(TPL_PAGE_1, 'One', 'PUBLISHED', VER_P1),
            makeTpl(TPL_ARCHIVED, 'Archived Family', 'ARCHIVED', VER_ARCHIVED),
          ],
          nextCursor: 'tpl-c2',
        }, 200);
      }
      if (url === '/api/v1/templates?cursor=tpl-c2&limit=100') {
        return jsonResponse({
          items: [
            makeTpl(TPL_DRAFT_PIN, 'Draft With Pin', 'DRAFT', VER_DRAFT_HIST),
            makeTpl(TPL_UNPUBLISHED_DRAFT, 'Draft Only', 'DRAFT', null),
          ],
          nextCursor: null,
        }, 200);
      }
      if (url === `/api/v1/templates/${TPL_PAGE_1}/versions?limit=100`) {
        return jsonResponse({ items: [makeVer(VER_P1, TPL_PAGE_1, 1)], nextCursor: 'ver-c2' }, 200);
      }
      if (url === `/api/v1/templates/${TPL_PAGE_1}/versions?cursor=ver-c2&limit=100`) {
        return jsonResponse({ items: [makeVer(VER_P2, TPL_PAGE_1, 2)], nextCursor: null }, 200);
      }
      if (url === `/api/v1/templates/${TPL_DRAFT_PIN}/versions?limit=100`) {
        return jsonResponse({ items: [makeVer(VER_DRAFT_HIST, TPL_DRAFT_PIN, 1)], nextCursor: null }, 200);
      }
      if (url.includes(TPL_ARCHIVED) || url.includes(TPL_UNPUBLISHED_DRAFT)) {
        throw new Error(`Must not fetch versions for ARCHIVED or unpublished template: ${url}`);
      }
      if (url === `/api/v1/workspaces/${WORKSPACE_ID}/members?status=ACTIVE&limit=100`) {
        return jsonResponse({
          items: [{
            workspaceId: WORKSPACE_ID,
            userId: OWNER_UUID,
            email: 'owner1@example.test',
            alias: 'Owner 1',
            role: 'ADMIN',
            status: 'ACTIVE',
            authzVersion: 1,
            revision: 1,
          }],
          nextCursor: 'mem-c2',
        }, 200);
      }
      if (url === `/api/v1/workspaces/${WORKSPACE_ID}/members?status=ACTIVE&limit=100&cursor=mem-c2`) {
        return jsonResponse({
          items: [{
            workspaceId: WORKSPACE_ID,
            userId: OWNER_P2,
            email: 'owner2@example.test',
            alias: 'Owner 2',
            role: 'USER',
            status: 'ACTIVE',
            authzVersion: 1,
            revision: 1,
          }],
          nextCursor: null,
        }, 200);
      }
      throw new Error(`Unexpected URL: ${url}`);
    };

    const versions = await listPublishedVersionsForRegistrationApi(CTX);
    assert.deepEqual(versions.map((v) => v.id), [VER_P1, VER_P2, VER_DRAFT_HIST]);

    const owners = await listActiveOwnersForRegistrationApi(CTX);
    assert.deepEqual(owners.map((o) => o.userId), [OWNER_UUID, OWNER_P2]);
  },
);
