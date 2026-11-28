import assert from 'node:assert/strict';
import { test } from 'node:test';
import {
  buildTemplateCreatePayload,
  computeTemplateSchemaDiff,
  normalizeStreamInput,
  parseTemplateDto,
  parseTemplatePublishedDto,
  parseTemplateVersionDto,
  parseTemplateVersionPageDto,
} from '../src/features/templates/templateContract.ts';
import {
  cloneTemplateDraftApi,
  createTemplateDraftApi,
  getTemplateVersionApi,
  listTemplateVersionsApi,
  patchTemplateDraftApi,
  publishTemplateApi,
  recoverPublishBySourceRevisionApi,
} from '../src/features/templates/templateApi.ts';
import { WorkspaceApiError } from '../src/features/workspace/workspaceApi.ts';

const WORKSPACE_ID = '00000000-0000-4000-8000-000000000001';
const TEMPLATE_ID = '00000000-0000-4000-8000-000000000002';
const VERSION_V1_ID = '00000000-0000-4000-8000-000000000003';
const VERSION_V2_ID = '00000000-0000-4000-8000-000000000004';
const CTX = {
  workspaceId: WORKSPACE_ID,
  session: {
    contextId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    csrfToken: '<synthetic-csrf-token>',
  },
};

/** Tạo Response JSON tổng hợp trong RAM; không mở kết nối mạng thật. */
function jsonResponse(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' },
  });
}

test('G1 stream normalization keeps channelKind and direction independent and maps valid legacy mode once',
  /** Kiểm tra quy tắc G1: channelKind/direction độc lập, mode tương thích map đúng 1 trục kèm trục còn lại, và loại bỏ mode khi xuất wire. */
  () => {
    const legacyDir = normalizeStreamInput({
      key: 'fan',
      type: 'BOOLEAN',
      mode: 'READ_WRITE',
      channelKind: 'STATE',
      default: true,
    }, 0);
    assert.deepEqual(legacyDir, {
      key: 'fan',
      type: 'BOOLEAN',
      channelKind: 'STATE',
      direction: 'READ_WRITE',
      default: true,
    });
    assert.equal('mode' in legacyDir, false);

    const legacyKind = normalizeStreamInput({
      key: 'fan_reported',
      type: 'BOOLEAN',
      mode: 'STATE',
      direction: 'READ',
    }, 1);
    assert.deepEqual(legacyKind, {
      key: 'fan_reported',
      type: 'BOOLEAN',
      channelKind: 'STATE',
      direction: 'READ',
    });
  },
);

test('G1 stream normalization rejects incomplete, duplicate, conflicting, unknown mode and stream-level safeValue',
  /** Kiểm tra tất cả ca âm tính legacy mode và safeValue trên stream từ fixtures G1 bị từ chối rõ ràng. */
  () => {
    const invalidCases = [
      { key: 's', type: 'BOOLEAN', mode: 'READ' }, // CT-TEMPLATE-MODE-ONLY-DIRECTION
      { key: 's', type: 'BOOLEAN', mode: 'STATE' }, // CT-TEMPLATE-MODE-ONLY-KIND
      { key: 's', type: 'BOOLEAN', mode: 'READ', direction: 'READ' }, // CT-TEMPLATE-MODE-DUPLICATE-DIRECTION
      { key: 's', type: 'BOOLEAN', mode: 'STATE', channelKind: 'STATE' }, // CT-TEMPLATE-MODE-DUPLICATE-KIND
      { key: 's', type: 'BOOLEAN', mode: 'READ', channelKind: 'STATE', direction: 'READ' }, // CT-TEMPLATE-MODE-MIXED-CANONICAL
      { key: 's', type: 'BOOLEAN', mode: 'SENSOR', direction: 'READ' }, // CT-TEMPLATE-MODE-UNKNOWN
      { key: 's', type: 'BOOLEAN', direction: 'READ' }, // CT-TEMPLATE-CANONICAL-ONE-AXIS
      { key: 's', type: 'NUMBER', channelKind: 'TELEMETRY', direction: 'READ', safeValue: 0 }, // CT-TEMPLATE-006
    ];

    for (const candidate of invalidCases) {
      assert.throws(
        () => normalizeStreamInput(candidate, 0),
        (err) => err instanceof WorkspaceApiError && err.status === 422,
      );
    }
  },
);

test('createTemplateDraftApi emits canonical fields, enforces headers and rejects body workspaceId',
  /** Kiểm tra createTemplateDraftApi gửi đúng header workspace/context/CSRF và không cho phép workspaceId trong body. */
  async () => {
    const calls = [];
    globalThis.window = { setTimeout, clearTimeout };
    globalThis.fetch = async (url, init) => {
      calls.push({ url, init });
      return jsonResponse({
        id: TEMPLATE_ID,
        workspaceId: WORKSPACE_ID,
        status: 'DRAFT',
        schemaVersion: 1,
        revision: 1,
        latestPublishedVersionId: null,
        name: 'Room demo',
        model: 'SYNTHETIC-ROOM',
        streams: [
          { key: 'temperature', type: 'NUMBER', channelKind: 'TELEMETRY', direction: 'READ', unit: 'C', min: -20, max: 100 },
          { key: 'fan', type: 'BOOLEAN', channelKind: 'STATE', direction: 'READ_WRITE', default: true },
        ],
        commands: [{ type: 'SET_VALUE', stream: 'fan', safeValue: false }],
        createdAt: '2026-11-27T05:00:00Z',
        updatedAt: '2026-11-27T05:00:00Z',
      }, 201);
    };

    const created = await createTemplateDraftApi(CTX, buildTemplateCreatePayload({
      name: 'Room demo',
      model: 'SYNTHETIC-ROOM',
      streams: [
        { key: 'temperature', type: 'NUMBER', channelKind: 'TELEMETRY', direction: 'READ', unit: 'C', min: -20, max: 100 },
        { key: 'fan', type: 'BOOLEAN', channelKind: 'STATE', direction: 'READ_WRITE', default: true },
      ],
      commands: [{ type: 'SET_VALUE', stream: 'fan', safeValue: false }],
    }));

    assert.equal(created.id, TEMPLATE_ID);
    assert.equal(created.revision, 1);
    assert.equal(calls.length, 1);
    assert.equal(calls[0].url, '/api/v1/templates');
    assert.equal(calls[0].init.headers['X-Workspace-Id'], WORKSPACE_ID);
    assert.equal(calls[0].init.headers['X-Auth-Context-Id'], CTX.session.contextId);
    assert.equal(calls[0].init.headers['X-CSRF-Token'], CTX.session.csrfToken);
    const sentBody = JSON.parse(calls[0].init.body);
    assert.equal('workspaceId' in sentBody, false);
    assert.equal('mode' in sentBody.streams[0], false);
  },
);

test('publishTemplateApi sends empty body with If-Match and parses TemplatePublished; recovery queries sourceRevision',
  /** Kiểm tra 006 V4: publish không gửi body, đọc đúng TemplatePublished, clone gửi sourceVersionId và recovery tìm theo sourceRevision. */
  async () => {
    const requests = [];
    globalThis.window = { setTimeout, clearTimeout };
    globalThis.fetch = async (url, init) => {
      requests.push({ url, init });
      if (url.endsWith('/publish')) {
        return jsonResponse({
          templateId: TEMPLATE_ID,
          revision: 2,
          version: {
            id: VERSION_V1_ID,
            workspaceId: WORKSPACE_ID,
            templateId: TEMPLATE_ID,
            version: 1,
            schemaVersion: 1,
            status: 'PUBLISHED',
            name: 'Room demo',
            model: 'SYNTHETIC-ROOM',
            streams: [
              { key: 'temperature', type: 'NUMBER', channelKind: 'TELEMETRY', direction: 'READ', unit: 'C', min: -20, max: 100 },
              { key: 'fan', type: 'BOOLEAN', channelKind: 'STATE', direction: 'READ_WRITE', default: true },
            ],
            commands: [{ type: 'SET_VALUE', stream: 'fan', safeValue: false }],
            sourceRevision: 1,
            publishedAt: '2026-11-27T05:00:00Z',
          },
        }, 200);
      }
      if (url.includes('/versions?sourceRevision=3')) {
        return jsonResponse({
          items: [{
            id: VERSION_V2_ID,
            workspaceId: WORKSPACE_ID,
            templateId: TEMPLATE_ID,
            version: 2,
            schemaVersion: 1,
            status: 'PUBLISHED',
            name: 'Room demo',
            model: 'SYNTHETIC-ROOM',
            streams: [
              { key: 'temperature', type: 'NUMBER', channelKind: 'TELEMETRY', direction: 'READ', unit: 'C', min: -20, max: 100 },
              { key: 'fan', type: 'BOOLEAN', channelKind: 'STATE', direction: 'READ_WRITE', default: false },
            ],
            commands: [{ type: 'SET_VALUE', stream: 'fan', safeValue: false }],
            sourceRevision: 3,
            publishedAt: '2026-11-27T05:05:00Z',
          }],
          nextCursor: null,
        }, 200);
      }
      if (url.endsWith(`/templates/${TEMPLATE_ID}`)) {
        return jsonResponse({
          id: TEMPLATE_ID,
          workspaceId: WORKSPACE_ID,
          status: 'PUBLISHED',
          schemaVersion: 1,
          revision: 4,
          latestPublishedVersionId: VERSION_V2_ID,
          name: 'Room demo',
          model: 'SYNTHETIC-ROOM',
          streams: [
            { key: 'temperature', type: 'NUMBER', channelKind: 'TELEMETRY', direction: 'READ', unit: 'C', min: -20, max: 100 },
            { key: 'fan', type: 'BOOLEAN', channelKind: 'STATE', direction: 'READ_WRITE', default: false },
          ],
          commands: [{ type: 'SET_VALUE', stream: 'fan', safeValue: false }],
          createdAt: '2026-11-27T05:00:00Z',
          updatedAt: '2026-11-27T05:05:00Z',
        }, 200);
      }
      if (url.endsWith(`/templates/${TEMPLATE_ID}/draft`)) {
        return jsonResponse({
          id: TEMPLATE_ID,
          workspaceId: WORKSPACE_ID,
          status: 'DRAFT',
          schemaVersion: 1,
          revision: 5,
          latestPublishedVersionId: VERSION_V2_ID,
          name: 'Room demo',
          model: 'SYNTHETIC-ROOM',
          streams: [
            { key: 'temperature', type: 'NUMBER', channelKind: 'TELEMETRY', direction: 'READ', unit: 'C', min: -20, max: 100 },
            { key: 'fan', type: 'BOOLEAN', channelKind: 'STATE', direction: 'READ_WRITE', default: false },
          ],
          commands: [{ type: 'SET_VALUE', stream: 'fan', safeValue: false }],
          createdAt: '2026-11-27T05:00:00Z',
          updatedAt: '2026-11-27T05:06:00Z',
        }, 200);
      }
      throw new Error(`Unexpected URL: ${url}`);
    };

    const published = await publishTemplateApi(CTX, TEMPLATE_ID, 1);
    assert.equal(published.revision, 2);
    assert.equal(published.version.id, VERSION_V1_ID);
    assert.equal(requests[0].init.method, 'POST');
    assert.equal(requests[0].init.headers['If-Match'], '"1"');
    assert.equal(requests[0].init.body, undefined);
    assert.equal(requests[0].init.headers['Content-Type'], undefined);

    const recovery = await recoverPublishBySourceRevisionApi(CTX, TEMPLATE_ID, 3);
    assert.equal(recovery.matchedVersion?.id, VERSION_V2_ID);
    assert.equal(recovery.matchedVersion?.sourceRevision, 3);
    assert.equal(recovery.rootTemplate.revision, 4);

    const cloned = await cloneTemplateDraftApi(CTX, TEMPLATE_ID, 4, VERSION_V2_ID);
    assert.equal(cloned.status, 'DRAFT');
    assert.equal(cloned.revision, 5);
    assert.deepEqual(JSON.parse(requests[3].init.body), { sourceVersionId: VERSION_V2_ID });

    const diff = computeTemplateSchemaDiff(published.version, recovery.rootTemplate);
    assert.equal(diff.hasChanges, true);
    assert.equal(diff.streamChanges.length, 1);
    assert.equal(diff.streamChanges[0].key, 'fan');
    assert.equal(diff.streamChanges[0].change, 'modified');
  },
);

test('patchTemplateDraftApi maps 412 VERSION_CONFLICT and aborts cleanly on workspace switch',
  /** Kiểm tra PATCH If-Match báo lỗi 412 đúng mã và hủy ngay request đang chạy khi đổi workspace. */
  async () => {
    globalThis.window = { setTimeout, clearTimeout };
    globalThis.fetch = async (_url, init) => {
      if (init.headers['If-Match'] === '"1"') {
        return jsonResponse({
          error: {
            code: 'VERSION_CONFLICT',
            message: 'Synthetic conflict.',
            correlationId: '00000000-0000-4000-8000-000000000021',
            details: { currentRevision: 2 },
          },
        }, 412);
      }
      return new Promise((_resolve, reject) => {
        init.signal?.addEventListener('abort', () => reject(new DOMException('Aborted', 'AbortError')));
      });
    };

    await assert.rejects(
      () => patchTemplateDraftApi(CTX, TEMPLATE_ID, 1, { name: 'Updated' }),
      (err) => err instanceof WorkspaceApiError && err.status === 412 && err.code === 'VERSION_CONFLICT' && err.currentRevision === 2,
    );

    const controller = new AbortController();
    const pending = patchTemplateDraftApi(CTX, TEMPLATE_ID, 2, { name: 'Late' }, controller.signal);
    controller.abort();
    await assert.rejects(pending, (err) => err instanceof DOMException && err.name === 'AbortError');
  },
);

test('parsers reject malformed TemplateVersion and TemplatePublished shapes',
  /** Kiểm tra strict parser từ chối version rỗng streams hoặc TemplatePublished lệch templateId. */
  () => {
    assert.throws(
      () => parseTemplateVersionDto({
        id: VERSION_V1_ID,
        workspaceId: WORKSPACE_ID,
        templateId: TEMPLATE_ID,
        version: 1,
        schemaVersion: 1,
        status: 'PUBLISHED',
        name: 'Room',
        model: 'SYNTHETIC-ROOM',
        streams: [], // minItems: 1
        commands: [],
        sourceRevision: 1,
        publishedAt: '2026-11-27T05:00:00Z',
      }),
      (err) => err instanceof WorkspaceApiError && err.code === 'PROTOCOL_ERROR',
    );
    assert.throws(
      () => parseTemplateDto({
        id: TEMPLATE_ID,
        workspaceId: WORKSPACE_ID,
        status: 'DRAFT',
        schemaVersion: 1,
        revision: 1,
        latestPublishedVersionId: null,
        name: 'Room',
        model: 'SYNTHETIC-ROOM',
        streams: [],
        commands: [],
        createdAt: '2026-11-27T05:00:00Z',
        updatedAt: '2026-11-27T05:00:00Z',
        unexpectedExtra: true,
      }),
      (err) => err instanceof WorkspaceApiError && err.code === 'PROTOCOL_ERROR',
    );
    assert.throws(
      () => parseTemplatePublishedDto({
        templateId: TEMPLATE_ID,
        revision: 2,
        version: {
          id: VERSION_V1_ID,
          workspaceId: WORKSPACE_ID,
          templateId: '00000000-0000-4000-8000-000000000099',
          version: 1,
          schemaVersion: 1,
          status: 'PUBLISHED',
          name: 'Room',
          model: 'SYNTHETIC-ROOM',
          streams: [{ key: 't', type: 'NUMBER', channelKind: 'TELEMETRY', direction: 'READ' }],
          commands: [],
          sourceRevision: 1,
          publishedAt: '2026-11-27T05:00:00Z',
        },
      }),
      (err) => err instanceof WorkspaceApiError && err.code === 'PROTOCOL_ERROR',
    );
  },
);

test('legacy TemplateVersion with sourceRevision null parses on read and unfiltered list while rejecting invalid numbers',
  /** Kiểm tra tương thích ngược FEAT-TN-006: đọc/liệt kê snapshot lịch sử có sourceRevision null theo đúng UUID pin, vẫn từ chối 0/âm/số thực/thiếu field và filter null. */
  async () => {
    const legacySnapshot = {
      id: VERSION_V1_ID,
      workspaceId: WORKSPACE_ID,
      templateId: TEMPLATE_ID,
      version: 1,
      schemaVersion: 1,
      status: 'PUBLISHED',
      name: 'Room demo',
      model: 'SYNTHETIC-ROOM',
      streams: [{ key: 'temperature', type: 'NUMBER', channelKind: 'TELEMETRY', direction: 'READ', unit: 'C', min: -20, max: 100 }],
      commands: [],
      sourceRevision: null,
      publishedAt: '2026-11-27T05:00:00Z',
    };
    const modernSnapshot = {
      ...legacySnapshot,
      id: VERSION_V2_ID,
      version: 2,
      sourceRevision: 4,
    };

    const parsedSingle = parseTemplateVersionDto(legacySnapshot);
    assert.equal(parsedSingle.id, VERSION_V1_ID);
    assert.equal(parsedSingle.sourceRevision, null);

    const parsedPage = parseTemplateVersionPageDto({ items: [legacySnapshot, modernSnapshot], nextCursor: null });
    assert.equal(parsedPage.items.length, 2);
    assert.equal(parsedPage.items[0].sourceRevision, null);
    assert.equal(parsedPage.items[1].sourceRevision, 4);

    for (const badSourceRevision of [0, -1, 1.5, '1', Number.NaN, undefined]) {
      const candidate = { ...legacySnapshot, sourceRevision: badSourceRevision };
      if (badSourceRevision === undefined) delete candidate.sourceRevision;
      assert.throws(
        () => parseTemplateVersionDto(candidate),
        (err) => err instanceof WorkspaceApiError && err.code === 'PROTOCOL_ERROR',
      );
    }

    globalThis.window = { setTimeout, clearTimeout };
    globalThis.fetch = async (url) => {
      if (url.endsWith(`/templates/${TEMPLATE_ID}/versions/${VERSION_V1_ID}`)) {
        return jsonResponse(legacySnapshot, 200);
      }
      if (url.endsWith(`/templates/${TEMPLATE_ID}/versions`)) {
        return jsonResponse({ items: [legacySnapshot, modernSnapshot], nextCursor: null }, 200);
      }
      throw new Error(`Unexpected URL: ${url}`);
    };

    const readLegacy = await getTemplateVersionApi(CTX, TEMPLATE_ID, VERSION_V1_ID);
    assert.equal(readLegacy.sourceRevision, null);
    const listAll = await listTemplateVersionsApi(CTX, TEMPLATE_ID);
    assert.equal(listAll.items[0].sourceRevision, null);

    await assert.rejects(
      () => listTemplateVersionsApi(CTX, TEMPLATE_ID, { sourceRevision: null }),
      (err) => err instanceof WorkspaceApiError && err.status === 422,
    );
    await assert.rejects(
      () => listTemplateVersionsApi(CTX, TEMPLATE_ID, { sourceRevision: 0 }),
      (err) => err instanceof WorkspaceApiError && err.status === 422,
    );
  },
);

test('parseTemplatePublishedDto and publishTemplateApi reject sourceRevision null on publish responses',
  /** Kiểm tra parser publish luôn nghiêm ngặt: phản hồi công bố mới có sourceRevision null hoặc 0 bị coi là PROTOCOL_ERROR. */
  async () => {
    const legacyVersionBody = {
      id: VERSION_V1_ID,
      workspaceId: WORKSPACE_ID,
      templateId: TEMPLATE_ID,
      version: 1,
      schemaVersion: 1,
      status: 'PUBLISHED',
      name: 'Room demo',
      model: 'SYNTHETIC-ROOM',
      streams: [{ key: 't', type: 'NUMBER', channelKind: 'TELEMETRY', direction: 'READ' }],
      commands: [],
      sourceRevision: null,
      publishedAt: '2026-11-27T05:00:00Z',
    };

    assert.throws(
      () => parseTemplatePublishedDto({
        templateId: TEMPLATE_ID,
        revision: 2,
        version: legacyVersionBody,
      }),
      (err) => err instanceof WorkspaceApiError && err.code === 'PROTOCOL_ERROR',
    );
    assert.throws(
      () => parseTemplatePublishedDto({
        templateId: TEMPLATE_ID,
        revision: 2,
        version: { ...legacyVersionBody, sourceRevision: 0 },
      }),
      (err) => err instanceof WorkspaceApiError && err.code === 'PROTOCOL_ERROR',
    );

    globalThis.window = { setTimeout, clearTimeout };
    globalThis.fetch = async () => jsonResponse({
      templateId: TEMPLATE_ID,
      revision: 2,
      version: legacyVersionBody,
    }, 200);

    await assert.rejects(
      () => publishTemplateApi(CTX, TEMPLATE_ID, 1),
      (err) => err instanceof WorkspaceApiError && err.code === 'PROTOCOL_ERROR',
    );
  },
);

test('recoverPublishBySourceRevisionApi never matches historical null provenance or mismatched revision items',
  /** Kiểm tra recovery theo sourceRevision chỉ khớp snapshot có đúng số nguyên dương đã submit, loại trừ bản lịch sử null và revision khác. */
  async () => {
    const rootTemplate = {
      id: TEMPLATE_ID,
      workspaceId: WORKSPACE_ID,
      status: 'PUBLISHED',
      schemaVersion: 1,
      revision: 4,
      latestPublishedVersionId: VERSION_V1_ID,
      name: 'Room demo',
      model: 'SYNTHETIC-ROOM',
      streams: [{ key: 't', type: 'NUMBER', channelKind: 'TELEMETRY', direction: 'READ' }],
      commands: [],
      createdAt: '2026-11-27T04:00:00Z',
      updatedAt: '2026-11-27T05:00:00Z',
    };
    const historicalItem = {
      id: VERSION_V1_ID,
      workspaceId: WORKSPACE_ID,
      templateId: TEMPLATE_ID,
      version: 1,
      schemaVersion: 1,
      status: 'PUBLISHED',
      name: 'Room demo',
      model: 'SYNTHETIC-ROOM',
      streams: [{ key: 't', type: 'NUMBER', channelKind: 'TELEMETRY', direction: 'READ' }],
      commands: [],
      sourceRevision: null,
      publishedAt: '2026-11-27T04:30:00Z',
    };

    globalThis.window = { setTimeout, clearTimeout };
    globalThis.fetch = async (url) => {
      if (url.includes('/versions?sourceRevision=3')) {
        return jsonResponse({ items: [historicalItem], nextCursor: null }, 200);
      }
      if (url.endsWith(`/templates/${TEMPLATE_ID}`)) {
        return jsonResponse(rootTemplate, 200);
      }
      throw new Error(`Unexpected URL: ${url}`);
    };

    const recoveryHistoricalOnly = await recoverPublishBySourceRevisionApi(CTX, TEMPLATE_ID, 3);
    assert.equal(recoveryHistoricalOnly.matchedVersion, null);

    globalThis.fetch = async (url) => {
      if (url.includes('/versions?sourceRevision=3')) {
        return jsonResponse({ items: [{ ...historicalItem, sourceRevision: 2 }], nextCursor: null }, 200);
      }
      if (url.endsWith(`/templates/${TEMPLATE_ID}`)) {
        return jsonResponse(rootTemplate, 200);
      }
      throw new Error(`Unexpected URL: ${url}`);
    };

    const recoveryMismatchedRev = await recoverPublishBySourceRevisionApi(CTX, TEMPLATE_ID, 3);
    assert.equal(recoveryMismatchedRev.matchedVersion, null);

    const exactItem = { ...historicalItem, id: VERSION_V2_ID, version: 2, sourceRevision: 3 };
    globalThis.fetch = async (url) => {
      if (url.includes('/versions?sourceRevision=3')) {
        return jsonResponse({ items: [historicalItem, exactItem], nextCursor: null }, 200);
      }
      if (url.endsWith(`/templates/${TEMPLATE_ID}`)) {
        return jsonResponse(rootTemplate, 200);
      }
      throw new Error(`Unexpected URL: ${url}`);
    };

    const recoveryExact = await recoverPublishBySourceRevisionApi(CTX, TEMPLATE_ID, 3);
    assert.equal(recoveryExact.matchedVersion?.id, VERSION_V2_ID);
    assert.equal(recoveryExact.matchedVersion?.sourceRevision, 3);
  },
);
