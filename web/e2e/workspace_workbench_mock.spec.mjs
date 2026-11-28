import { expect, test } from '@playwright/test';

const CONTEXT_ID = '11111111-1111-4111-8111-111111111111';
const USER_ID = '22222222-2222-4222-8222-222222222222';
const OWNER_ID = '33333333-3333-4333-8333-333333333333';
const WORKSPACE_ID = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const TEMPLATE_ID = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const TEMPLATE_2_ID = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb2';
const VERSION_V1_ID = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
const DEVICE_ID = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd';
const OPERATION_ID = 'ffffffff-ffff-4fff-8fff-ffffffffffff';
const CSRF_TOKEN = 'mock-csrf-token-for-component-test';

const AUTH_HEADERS = {
  'content-type': 'application/json',
  'x-auth-context-id': CONTEXT_ID,
  'x-csrf-token': CSRF_TOKEN,
};

const BASE_STREAM = {
  key: 'speed',
  type: 'NUMBER',
  channelKind: 'STATE',
  direction: 'READ_WRITE',
  unit: '%',
  min: 0,
  max: 100,
  default: 20,
};

const BASE_COMMAND = {
  type: 'SET_VALUE',
  stream: 'speed',
  safeValue: 0,
};

/**
 * Tạo snapshot TemplateVersion G1 hoàn chỉnh theo `parseTemplateVersionDto`.
 * Input
 * Param: publishedAt — dấu thời gian UTC công bố phiên bản.
 * Param: sourceRevision — revision draft nguồn dương hoặc null cho snapshot lịch sử.
 * Output: object JSON khớp schema `TemplateVersion`.
 */
function makeVersionV1(publishedAt = '2026-11-26T02:00:00Z', sourceRevision = 1) {
  return {
    id: VERSION_V1_ID,
    workspaceId: WORKSPACE_ID,
    templateId: TEMPLATE_ID,
    version: 1,
    schemaVersion: 1,
    status: 'PUBLISHED',
    name: 'Quạt Lab Chuẩn',
    model: 'FAN_LAB_V1',
    streams: [BASE_STREAM],
    commands: [BASE_COMMAND],
    sourceRevision,
    publishedAt,
  };
}

/**
 * Tạo object Device G1 chuẩn cho recovery hoặc sau đăng ký.
 * Input
 * Param: serial — chuỗi serial canonical của thiết bị.
 * Param: name — tên thiết bị.
 * Param: model — mã model khớp TemplateVersion.
 * Param: templateVersionId — UUID của TemplateVersion đã pin.
 * Param: ownerId — UUID thành viên ACTIVE.
 * Output: object JSON khớp schema `Device`.
 */
function makeDevice(serial, name, model, templateVersionId, ownerId) {
  return {
    id: DEVICE_ID,
    workspaceId: WORKSPACE_ID,
    ownerId,
    templateVersionId,
    serial,
    name,
    model,
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
    capabilities: [BASE_COMMAND],
    revision: 1,
    createdAt: '2026-11-26T04:00:00Z',
    updatedAt: '2026-11-26T04:00:00Z',
  };
}

/**
 * Cài đặt route API giả lập theo hợp đồng G1 cho kiểm thử component trình duyệt cô lập (không thay thế kiểm thử live backend).
 * Input
 * Param: page — đối tượng Page của Playwright.
 * Param: options — tùy chọn gắn runtime routes, lỗi mất response POST và trạng thái template ban đầu.
 * Output: bộ đếm request để kiểm tra header bảo mật, payload và contract từ FE.
 * Side effects: chặn toàn bộ `/api/v1/**` và trả JSON G1 mô phỏng trong bộ nhớ.
 */
async function installG1MockApi(page, options = {}) {
  const {
    mountRuntimeWorkbenches = true,
    abortCreatePostAfterCommit = false,
    initialStatus = 'DRAFT',
    initialLatestPublishedVersionId = null,
    legacyVersionSourceRevision = 1,
  } = options;
  let loggedIn = false;
  let templateStatus = initialStatus;
  let templateRevision = 1;
  const latestPublishedVersionId = initialLatestPublishedVersionId;
  let streamsState = [BASE_STREAM];
  let commandsState = [BASE_COMMAND];
  let pollCount = 0;
  let deviceRegistered = null;
  const createdDrafts = [];
  const requests = [];

  await page.route('**/api/v1/**',
    /** Điều phối mock response theo path/method G1 cho UI workbench 005/006/007/008. */
    async (route) => {
      const req = route.request();
      const url = new URL(req.url());
      const path = url.pathname;
      const method = req.method();
      const postBody = method === 'POST' || method === 'PATCH' ? req.postDataJSON() : null;
      requests.push({ method, path, headers: req.headers(), body: postBody });

      const currentTemplate = {
        id: TEMPLATE_ID,
        workspaceId: WORKSPACE_ID,
        name: 'Quạt Lab Chuẩn',
        model: 'FAN_LAB_V1',
        status: templateStatus,
        schemaVersion: 1,
        revision: templateRevision,
        latestPublishedVersionId,
        streams: streamsState,
        commands: commandsState,
        createdAt: '2026-11-26T00:00:00Z',
        updatedAt: '2026-11-26T01:00:00Z',
      };

      if (path === '/api/v1/auth/login' && method === 'POST') {
        loggedIn = true;
        await route.fulfill({
          status: 200,
          headers: AUTH_HEADERS,
          body: JSON.stringify({
            me: {
              id: USER_ID,
              email: 'admin@nexa.local',
              mustChangePassword: false,
            },
            limited: false,
            expiresAt: '2026-11-27T12:00:00Z',
          }),
        });
        return;
      }

      if (path === '/api/v1/me' && method === 'GET') {
        if (!loggedIn || !req.headers()['x-auth-context-id']) {
          await route.fulfill({
            status: 401,
            headers: { 'content-type': 'application/json' },
            body: JSON.stringify({
              error: {
                code: 'SESSION_EXPIRED',
                message: 'Chưa đăng nhập.',
                details: {},
                correlationId: 'corr-mock-001',
              },
            }),
          });
          return;
        }
        await route.fulfill({
          status: 200,
          headers: AUTH_HEADERS,
          body: JSON.stringify({
            id: USER_ID,
            email: 'admin@nexa.local',
            mustChangePassword: false,
            displayTimezone: 'Asia/Ho_Chi_Minh',
            preferencesRevision: 1,
          }),
        });
        return;
      }

      if (path === '/api/v1/workspaces' && method === 'GET') {
        await route.fulfill({
          status: 200,
          headers: AUTH_HEADERS,
          body: JSON.stringify({
            items: [{ id: WORKSPACE_ID, name: 'Lab Alpha', status: 'ACTIVE', role: 'ADMIN', revision: 1 }],
            nextCursor: null,
          }),
        });
        return;
      }

      if (path === `/api/v1/workspaces/${WORKSPACE_ID}` && method === 'GET') {
        await route.fulfill({
          status: 200,
          headers: AUTH_HEADERS,
          body: JSON.stringify({
            id: WORKSPACE_ID,
            name: 'Lab Alpha',
            status: 'ACTIVE',
            membershipStatus: 'ACTIVE',
            role: 'ADMIN',
            revision: 1,
          }),
        });
        return;
      }

      if (!mountRuntimeWorkbenches) {
        await route.fulfill({ status: 404, body: '{}' });
        return;
      }

      if (path === `/api/v1/workspaces/${WORKSPACE_ID}/members` && method === 'GET') {
        await route.fulfill({
          status: 200,
          headers: { 'content-type': 'application/json' },
          body: JSON.stringify({
            items: [
              {
                workspaceId: WORKSPACE_ID,
                userId: OWNER_ID,
                email: 'operator@nexa.local',
                alias: 'Kỹ thuật viên A',
                role: 'USER',
                status: 'ACTIVE',
                updatedAt: '2026-11-26T00:00:00Z',
              },
            ],
            nextCursor: null,
          }),
        });
        return;
      }

      if (path === '/api/v1/templates' && method === 'POST') {
        const committedDraft = {
          id: TEMPLATE_2_ID,
          workspaceId: WORKSPACE_ID,
          name: postBody.name,
          model: postBody.model,
          status: 'DRAFT',
          schemaVersion: 1,
          revision: 1,
          latestPublishedVersionId: null,
          streams: postBody.streams ?? [],
          commands: postBody.commands ?? [],
          createdAt: '2026-11-27T05:00:00Z',
          updatedAt: '2026-11-27T05:00:00Z',
        };
        createdDrafts.push(committedDraft);
        if (abortCreatePostAfterCommit) {
          await route.abort('connectionreset');
          return;
        }
        await route.fulfill({
          status: 201,
          headers: { 'content-type': 'application/json', etag: '"1"' },
          body: JSON.stringify(committedDraft),
        });
        return;
      }

      if (path === '/api/v1/templates' && method === 'GET') {
        const statusFilter = url.searchParams.get('status');
        const allTemplates = [currentTemplate, ...createdDrafts];
        const items = statusFilter
          ? allTemplates.filter(
            /** Lọc theo trạng thái DRAFT/PUBLISHED giống endpoint danh sách G1. */
            (item) => item.status === statusFilter,
          )
          : allTemplates;
        await route.fulfill({
          status: 200,
          headers: { 'content-type': 'application/json' },
          body: JSON.stringify({ items, nextCursor: null }),
        });
        return;
      }

      if (path === `/api/v1/templates/${TEMPLATE_2_ID}` && method === 'PATCH') {
        const draft = createdDrafts.find(
          /** Tìm bản nháp vừa tạo theo đúng UUID để cập nhật revision. */
          (item) => item.id === TEMPLATE_2_ID,
        );
        if (!draft) {
          await route.fulfill({ status: 404, body: '{}' });
          return;
        }
        draft.name = postBody.name ?? draft.name;
        draft.model = postBody.model ?? draft.model;
        draft.streams = postBody.streams ?? draft.streams;
        draft.commands = postBody.commands ?? draft.commands;
        draft.revision += 1;
        draft.updatedAt = '2026-11-27T05:05:00Z';
        await route.fulfill({
          status: 200,
          headers: { 'content-type': 'application/json', etag: `"${draft.revision}"` },
          body: JSON.stringify(draft),
        });
        return;
      }

      if (path === `/api/v1/templates/${TEMPLATE_ID}` && method === 'PATCH') {
        streamsState = postBody.streams ?? streamsState;
        commandsState = postBody.commands ?? commandsState;
        templateRevision += 1;
        await route.fulfill({
          status: 200,
          headers: { 'content-type': 'application/json', etag: `"${templateRevision}"` },
          body: JSON.stringify({
            ...currentTemplate,
            name: postBody.name ?? currentTemplate.name,
            model: postBody.model ?? currentTemplate.model,
            streams: streamsState,
            commands: commandsState,
            revision: templateRevision,
            updatedAt: '2026-11-27T05:10:00Z',
          }),
        });
        return;
      }

      if (path === `/api/v1/templates/${TEMPLATE_2_ID}/versions` && method === 'GET') {
        await route.fulfill({
          status: 200,
          headers: { 'content-type': 'application/json' },
          body: JSON.stringify({ items: [], nextCursor: null }),
        });
        return;
      }

      if (path === `/api/v1/templates/${TEMPLATE_ID}` && method === 'GET') {
        await route.fulfill({
          status: 200,
          headers: { 'content-type': 'application/json', etag: `"${templateRevision}"` },
          body: JSON.stringify(currentTemplate),
        });
        return;
      }

      if (path === `/api/v1/templates/${TEMPLATE_ID}/versions` && method === 'GET') {
        const versions = latestPublishedVersionId
          ? [makeVersionV1('2026-11-26T02:00:00Z', legacyVersionSourceRevision)]
          : [];
        await route.fulfill({
          status: 200,
          headers: { 'content-type': 'application/json' },
          body: JSON.stringify({ items: versions, nextCursor: null }),
        });
        return;
      }

      if (path === `/api/v1/templates/${TEMPLATE_ID}/versions/${VERSION_V1_ID}` && method === 'GET') {
        await route.fulfill({
          status: 200,
          headers: { 'content-type': 'application/json' },
          body: JSON.stringify(makeVersionV1('2026-11-26T02:00:00Z', legacyVersionSourceRevision)),
        });
        return;
      }

      if (path === `/api/v1/templates/${TEMPLATE_ID}/draft` && method === 'POST') {
        templateStatus = 'DRAFT';
        templateRevision = 3;
        await route.fulfill({
          status: 201,
          headers: { 'content-type': 'application/json', etag: '"3"' },
          body: JSON.stringify({
            ...currentTemplate,
            status: 'DRAFT',
            revision: 3,
            latestPublishedVersionId: VERSION_V1_ID,
            updatedAt: '2026-11-26T03:00:00Z',
          }),
        });
        return;
      }

      if (path === '/api/v1/devices' && method === 'POST') {
        deviceRegistered = makeDevice(postBody.serial, postBody.name, postBody.model, postBody.templateVersionId, postBody.ownerId);
        await route.fulfill({
          status: 201,
          headers: { 'content-type': 'application/json' },
          body: JSON.stringify({
            ...deviceRegistered,
            nextStep: {
              type: 'SELECT_SETUP_METHOD',
              methods: ['USB', 'QR_BLE'],
            },
          }),
        });
        return;
      }

      if (path === '/api/v1/devices' && method === 'GET') {
        const serial = url.searchParams.get('serial');
        await route.fulfill({
          status: 200,
          headers: { 'content-type': 'application/json' },
          body: JSON.stringify({
            items: deviceRegistered && serial === deviceRegistered.serial ? [deviceRegistered] : [],
            nextCursor: null,
          }),
        });
        return;
      }

      if (path === `/api/v1/provisioning-operations/${OPERATION_ID}` && method === 'GET') {
        pollCount += 1;
        await route.fulfill({
          status: 200,
          headers: { 'content-type': 'application/json' },
          body: JSON.stringify({
            kind: 'STATUS',
            operation: {
              kind: 'CREDENTIAL',
              operationId: OPERATION_ID,
              deviceId: DEVICE_ID,
              deliveryMode: 'USB_ONE_TIME',
              status: 'READY',
              deliveryStatus: 'AVAILABLE',
              secretAvailable: true,
              escrowExpiresAt: '2026-11-26T04:11:00Z',
              claimedAt: null,
              errorCode: null,
              retryCount: 1,
            },
          }),
        });
        return;
      }

      await route.fulfill({ status: 404, body: '{}' });
    },
  );

  return {
    requests,
    /** Trả về số lần poll metadata operation đã thực thi. */
    getPollCount: () => pollCount,
  };
}

test(
  'preserves dev summary-only AuthPage when template and device runtime routes return 404',
  /** Kiểm tra khi runtime chỉ mount auth routes (404 ở /templates và /devices), UI giữ nguyên thẻ tổng quan tối giản như dev 95d35c0c. */
  async ({ page }) => {
    await installG1MockApi(page, { mountRuntimeWorkbenches: false });

    await page.goto('/login');
    await page.locator('#email').fill('admin@nexa.local');
    await page.locator('#password').fill('TestPassword123!');
    await page.getByRole('button', { name: 'Đăng nhập' }).click();
    await page.getByRole('button', { name: /Chọn workspace Lab Alpha/i }).click();
    await expect(page.getByText('Đã xác minh quyền quản trị viên của bạn.')).toBeVisible();

    // Đợi probe 404 hoàn tất rồi xác nhận không lộ tab workbench ngoài phạm vi runtime.
    await page.waitForTimeout(150);
    await expect(page.getByRole('navigation', { name: 'Chức năng quản trị workspace' })).toHaveCount(0);
    await expect(page.getByRole('button', { name: 'Templates (WB-03)' })).toHaveCount(0);
    await expect(page.getByRole('button', { name: 'Thiết bị & USB (WB-04)' })).toHaveCount(0);
  },
);

test(
  'scoped runtime batch verifies 005 stream default, 006 V4 clone/disabled publish, 007 registration, and 008 metadata-only poll',
  /** Kiểm thử đầy đủ các capability thật được nạp: stream.default round-trip, clone V4, khóa publish/issue/claim và poll metadata operation. */
  async ({ page }) => {
    const tracker = await installG1MockApi(page, {
      initialStatus: 'PUBLISHED',
      initialLatestPublishedVersionId: VERSION_V1_ID,
    });

    await page.goto('/login');
    await page.locator('#email').fill('admin@nexa.local');
    await page.locator('#password').fill('TestPassword123!');
    await page.getByRole('button', { name: 'Đăng nhập' }).click();
    await page.getByRole('button', { name: /Chọn workspace Lab Alpha/i }).click();
    await expect(page.getByText('Đã xác minh quyền quản trị viên của bạn.')).toBeVisible();

    // 1. WB-03 + 006 V4: Clone bản nháp từ v1, giữ stream.default và khóa nút Publish
    await page.getByRole('button', { name: 'Templates (WB-03)' }).click();
    await expect(page.getByRole('heading', { name: /Templates \(WB-03/i })).toBeVisible();
    await page.getByRole('button', { name: 'Xem & Công bố / Tạo draft' }).click();

    await expect(page.locator('#tpl-stream-0-default')).toHaveValue('20');
    await page.getByRole('button', { name: 'Mở bản nháp mới từ v1' }).click();
    await expect(page.getByText('Công bố bản nháp hiện hành (Revision #3)')).toBeVisible();
    const publishBtn = page.getByRole('button', { name: 'Công bố phiên bản (Chưa khả dụng)' });
    await expect(publishBtn).toBeDisabled();

    // Sửa default và PATCH bản nháp giữ đúng typed scalar default
    await page.locator('#tpl-stream-0-default').fill('42');
    await page.getByRole('button', { name: 'Lưu cập nhật nháp' }).click();
    await expect(page.locator('#tpl-stream-0-default')).toHaveValue('42');

    const patchReq = tracker.requests.find((r) => r.method === 'PATCH' && r.path === `/api/v1/templates/${TEMPLATE_ID}`);
    expect(patchReq?.headers['if-match']).toBe('"3"');
    expect(patchReq?.body?.streams?.[0]?.default).toBe(42);
    expect(tracker.requests.filter((r) => r.path.endsWith('/publish'))).toHaveLength(0);

    // 2. WB-04 + 007 D4 + 008 metadata-only poll (cấp mới & claim bị khóa)
    await page.getByRole('button', { name: 'Thiết bị & USB (WB-04)' }).click();
    await expect(page.getByRole('heading', { name: /Đăng ký thiết bị mới/i })).toBeVisible();

    await page.locator('#dev-field-serial').fill('synthetic-room-001');
    await page.locator('#dev-field-name').fill('Quạt phòng lab');
    await page.locator('#dev-field-version').selectOption(VERSION_V1_ID);
    await expect(page.locator('#dev-field-model')).toHaveValue('FAN_LAB_V1');
    await page.locator('#dev-field-owner').selectOption(OWNER_ID);
    await page.getByRole('button', { name: 'Đăng ký thiết bị' }).click();

    await expect(page.getByText('Lifecycle: REGISTERED')).toBeVisible();
    await expect(page.getByText('Connectivity: UNKNOWN')).toBeVisible();
    await expect(page.getByText('Credential: PROVISIONING (Chưa cấp credential)')).toBeVisible();

    await expect(page.getByRole('button', { name: 'Cấp credential USB (Chưa khả dụng)' })).toBeDisabled();

    await page.locator('#dev-poll-op-id').fill(OPERATION_ID);
    await page.getByRole('button', { name: 'Thăm dò metadata operation' }).click();

    await expect.poll(tracker.getPollCount).toBeGreaterThanOrEqual(1);
    await expect(page.getByText('Kind: CREDENTIAL')).toBeVisible();
    await expect(page.getByText('Operation: READY')).toBeVisible();
    await expect(page.getByRole('button', { name: /Claim \(Chưa khả dụng\)/i })).toBeDisabled();

    expect(tracker.requests.filter((r) => r.path.endsWith('/credentials'))).toHaveLength(0);
    expect(tracker.requests.filter((r) => r.path.endsWith('/claim-credential'))).toHaveLength(0);

    // Xác minh không rò rỉ secret/token vào localStorage hoặc sessionStorage
    const storageDump = await page.evaluate(() => ({
      local: Object.entries(window.localStorage),
      session: Object.entries(window.sessionStorage),
    }));
    const serializedStorage = JSON.stringify(storageDump).toLowerCase();
    expect(serializedStorage).not.toContain('mqtt');
    expect(serializedStorage).not.toContain('secret');
    expect(serializedStorage).not.toContain('password');
  },
);

test(
  'WEB-TEMPLATE-005 regression: selects newly committed same-name candidate absent from initial cache after lost POST response',
  /** Kiểm tra sau khi POST create mất response dù backend đã commit, người dùng chọn đúng draft mới chưa có trong cache ban đầu để mở editor và PATCH được. */
  async ({ page }) => {
    const tracker = await installG1MockApi(page, { abortCreatePostAfterCommit: true });

    await page.goto('/login');
    await page.locator('#email').fill('admin@nexa.local');
    await page.locator('#password').fill('TestPassword123!');
    await page.getByRole('button', { name: 'Đăng nhập' }).click();
    await page.getByRole('button', { name: /Chọn workspace Lab Alpha/i }).click();
    await expect(page.getByText('Đã xác minh quyền quản trị viên của bạn.')).toBeVisible();

    await page.getByRole('button', { name: 'Templates (WB-03)' }).click();
    await expect(page.getByRole('heading', { name: /Templates \(WB-03/i })).toBeVisible();
    await expect(page.locator('.tpl-list-item')).toHaveCount(1);

    await page.getByRole('button', { name: 'Tạo template' }).click();
    await page.locator('#tpl-field-name').fill('Quạt Lab Chuẩn');
    await page.locator('#tpl-field-model').fill('FAN_LAB_V1');
    await page.getByRole('button', { name: 'Tạo bản nháp' }).click();

    const unknownNotice = page.getByRole('alert');
    await expect(unknownNotice).toContainText('Chưa nhận được xác nhận sau khi tạo template');
    const candidateRows = unknownNotice.locator('li');
    await expect(candidateRows).toHaveCount(2);
    await expect(candidateRows.filter({ hasText: TEMPLATE_ID })).toHaveCount(1);
    const newCandidateRow = candidateRows.filter({ hasText: TEMPLATE_2_ID });
    await expect(newCandidateRow).toHaveCount(1);

    // Không tự gửi lại POST và không tự publish trong lúc hiển thị danh sách đối chiếu.
    expect(tracker.requests.filter((r) => r.method === 'POST' && r.path === '/api/v1/templates')).toHaveLength(1);
    expect(tracker.requests.filter((r) => r.method === 'POST' && r.path.endsWith('/publish'))).toHaveLength(0);

    await newCandidateRow.getByRole('button', { name: 'Mở bản nháp này' }).click();

    await expect(page.getByRole('alert')).toHaveCount(0);
    await expect(page.getByText('Revision #1', { exact: true })).toBeVisible();
    await expect(page.getByText('Công bố bản nháp hiện hành (Revision #1)')).toBeVisible();
    await expect(page.locator('#tpl-field-name')).toHaveValue('Quạt Lab Chuẩn');
    const patchButton = page.getByRole('button', { name: 'Lưu cập nhật nháp' });
    await expect(patchButton).toBeVisible();

    await page.locator('#tpl-field-name').fill('Quạt Lab Chuẩn (Mới)');
    await patchButton.click();

    const saveStatus = page.getByRole('status').filter({ hasText: 'Đã lưu bản nháp trên máy chủ.' });
    await expect(saveStatus).toContainText(TEMPLATE_2_ID);
    await expect(saveStatus).toContainText('Revision #2');

    const patchReq = tracker.requests.find((r) => r.method === 'PATCH' && r.path === `/api/v1/templates/${TEMPLATE_2_ID}`);
    expect(patchReq?.headers['if-match']).toBe('"1"');
    expect(tracker.requests.filter((r) => r.method === 'POST' && r.path === '/api/v1/templates')).toHaveLength(1);
  },
);

test(
  'FEAT-TN-006 V4 legacy back-compat: renders historical sourceRevision null without #null',
  /** Kiểm tra TemplatePublishPanel đọc và hiển thị snapshot lịch sử có sourceRevision null mà không in #null hay báo PROTOCOL_ERROR. */
  async ({ page }) => {
    await installG1MockApi(page, {
      initialStatus: 'PUBLISHED',
      initialLatestPublishedVersionId: VERSION_V1_ID,
      legacyVersionSourceRevision: null,
    });

    await page.goto('/login');
    await page.locator('#email').fill('admin@nexa.local');
    await page.locator('#password').fill('TestPassword123!');
    await page.getByRole('button', { name: 'Đăng nhập' }).click();
    await page.getByRole('button', { name: /Chọn workspace Lab Alpha/i }).click();
    await expect(page.getByText('Đã xác minh quyền quản trị viên của bạn.')).toBeVisible();

    await page.getByRole('button', { name: 'Templates (WB-03)' }).click();
    await page.getByRole('button', { name: 'Xem & Công bố / Tạo draft' }).click();

    const versionSelect = page.locator('#tpl-version-select');
    await expect(versionSelect).toHaveValue(VERSION_V1_ID);
    const selectedOptionText = await versionSelect.locator(`option[value="${VERSION_V1_ID}"]`).textContent();
    expect(selectedOptionText).toContain('chưa rõ revision gốc');
    expect(selectedOptionText).not.toContain('#null');

    const detailBox = page.locator('.tpl-version-detail');
    await expect(detailBox).toContainText('sourceRevision: Chưa ghi (bản lịch sử)');
    await expect(detailBox).not.toContainText('#null');
    await expect(page.getByRole('button', { name: 'Mở bản nháp mới từ v1' })).toBeVisible();
  },
);

test(
  'INT-0508-RENAME-DATA-PRESERVATION + INT-0508-ENUM-JSON-PRECISION: locks legacy numeric ENUM schema read-only, preserves 2^53 vs 2^53+1 on list/detail/versions, and allows name-only PATCH',
  /** Hồi quy #150 cho bản nháp có ENUM số lịch sử: đọc raw token 2^53 vs 2^53+1 trên danh sách/chi tiết/snapshot lịch sử, khóa nút sửa schema/capability và chỉ cho PATCH đổi tên. */
  async ({ page }) => {
    await installG1MockApi(page);

    let draftName = 'Cảm biến gốc';
    let draftRevision = 1;
    const makeRawLegacyDraft = () => `{
      "id": "${TEMPLATE_ID}",
      "workspaceId": "${WORKSPACE_ID}",
      "status": "DRAFT",
      "schemaVersion": 1,
      "revision": ${draftRevision},
      "latestPublishedVersionId": "${VERSION_V1_ID}",
      "name": ${JSON.stringify(draftName)},
      "model": "FAN_LAB_V1",
      "streams": [
        {
          "key": "fan_mode",
          "type": "ENUM",
          "channelKind": "STATE",
          "direction": "READ_WRITE",
          "enumValues": [9007199254740992, 9007199254740993, "1", 1],
          "default": 9007199254740993
        }
      ],
      "commands": [
        { "type": "SET_VALUE", "stream": "fan_mode", "safeValue": 9007199254740993 }
      ],
      "createdAt": "2026-11-26T00:00:00Z",
      "updatedAt": "2026-11-26T01:00:00Z"
    }`;

    const rawHistoricalVersion = `{
      "id": "${VERSION_V1_ID}",
      "workspaceId": "${WORKSPACE_ID}",
      "templateId": "${TEMPLATE_ID}",
      "version": 1,
      "schemaVersion": 1,
      "status": "PUBLISHED",
      "name": "Cảm biến gốc",
      "model": "FAN_LAB_V1",
      "streams": [
        {
          "key": "fan_mode",
          "type": "ENUM",
          "channelKind": "STATE",
          "direction": "READ_WRITE",
          "enumValues": [9007199254740992, 9007199254740993],
          "default": 9007199254740992
        }
      ],
      "commands": [
        { "type": "SET_VALUE", "stream": "fan_mode", "safeValue": 9007199254740992 }
      ],
      "sourceRevision": null,
      "publishedAt": "2026-11-26T02:00:00Z"
    }`;

    const capturedPatches = [];
    await page.route('**/api/v1/templates**',
      /** Phục vụ danh sách, chi tiết và snapshot lịch sử bằng chuỗi JSON thô giữ nguyên số 2^53 và 2^53+1. */
      async (route) => {
        const req = route.request();
        const url = new URL(req.url());
        if (url.pathname === '/api/v1/templates' && req.method() === 'GET') {
          await route.fulfill({
            status: 200,
            headers: { 'content-type': 'application/json' },
            body: `{"items":[${makeRawLegacyDraft()}],"nextCursor":null}`,
          });
          return;
        }
        if (url.pathname === `/api/v1/templates/${TEMPLATE_ID}` && req.method() === 'GET') {
          await route.fulfill({
            status: 200,
            headers: { 'content-type': 'application/json', etag: `"${draftRevision}"` },
            body: makeRawLegacyDraft(),
          });
          return;
        }
        if (url.pathname === `/api/v1/templates/${TEMPLATE_ID}` && req.method() === 'PATCH') {
          const patchBody = req.postDataJSON();
          capturedPatches.push({ headers: req.headers(), body: patchBody });
          draftName = patchBody.name ?? draftName;
          draftRevision += 1;
          await route.fulfill({
            status: 200,
            headers: { 'content-type': 'application/json', etag: `"${draftRevision}"` },
            body: makeRawLegacyDraft(),
          });
          return;
        }
        if (url.pathname === `/api/v1/templates/${TEMPLATE_ID}/versions` && req.method() === 'GET') {
          await route.fulfill({
            status: 200,
            headers: { 'content-type': 'application/json' },
            body: `{"items":[${rawHistoricalVersion}],"nextCursor":null}`,
          });
          return;
        }
        if (url.pathname === `/api/v1/templates/${TEMPLATE_ID}/versions/${VERSION_V1_ID}` && req.method() === 'GET') {
          await route.fulfill({
            status: 200,
            headers: { 'content-type': 'application/json' },
            body: rawHistoricalVersion,
          });
          return;
        }
        await route.fallback();
      },
    );

    await page.goto('/login');
    await page.locator('#email').fill('admin@nexa.local');
    await page.locator('#password').fill('TestPassword123!');
    await page.getByRole('button', { name: 'Đăng nhập' }).click();
    await page.getByRole('button', { name: /Chọn workspace Lab Alpha/i }).click();
    await page.getByRole('button', { name: 'Templates (WB-03)' }).click();
    await page.getByRole('button', { name: 'Mở bản nháp' }).click();

    // 1. Bảo toàn độ chính xác 2^53 vs 2^53 + 1 trên form và snapshot lịch sử V4.
    await expect(page.locator('#tpl-stream-0-enumValues-0')).toHaveValue('9007199254740992');
    await expect(page.locator('#tpl-stream-0-enumValues-1')).toHaveValue('9007199254740993');
    await expect(page.locator('#tpl-stream-0-default')).toHaveValue('9007199254740993');
    await expect(page.locator('.tpl-version-detail')).toContainText('9007199254740992, 9007199254740993');
    await expect(page.locator('#tpl-legacy-enum-lock-notice')).toBeVisible();

    // 2. Điều khiển sửa model, schema và capability đều bị khóa chỉ đọc, còn tên template vẫn sửa được.
    await expect(page.locator('#tpl-field-name')).toBeEditable();
    await expect(page.locator('#tpl-field-model')).not.toBeEditable();
    await expect(page.locator('#tpl-streams-add')).toBeDisabled();
    await expect(page.locator('#tpl-stream-0-key')).not.toBeEditable();
    await expect(page.locator('#tpl-stream-0-type')).toBeDisabled();
    await expect(page.locator('#tpl-stream-0-enumValues-add')).toBeDisabled();
    await expect(page.locator('#tpl-stream-0-enumValues-0')).not.toBeEditable();
    await expect(page.locator('#tpl-stream-0-default')).toBeDisabled();
    await expect(page.locator('#tpl-commands-add')).toBeDisabled();

    // 3. Đổi tên thuần túy chỉ gửi { name } với If-Match, không gửi mảng streams/commands.
    await page.locator('#tpl-field-name').fill('Cảm biến đã đổi tên');
    await page.getByRole('button', { name: 'Lưu cập nhật nháp' }).click();
    await expect(page.getByRole('status').filter({ hasText: 'Đã lưu bản nháp trên máy chủ.' })).toContainText('Revision #2');

    expect(capturedPatches).toHaveLength(1);
    expect(capturedPatches[0].headers['if-match']).toBe('"1"');
    expect(capturedPatches[0].body).toEqual({ name: 'Cảm biến đã đổi tên' });
    await expect(page.locator('#tpl-stream-0-enumValues-1')).toHaveValue('9007199254740993');
  },
);

test(
  'INT-0508-RENAME-DATA-PRESERVATION (writable): fresh explicit empty "", whitespace "   ", absent default, and exact untouched 2^53+1 scalars survive across other-stream edit',
  /** Hồi quy #150 cho bản nháp có thể ghi: mở mới bản nháp mang default "", default "   ", default vắng mặt và số 2^53+1, sửa một kênh khác nhưng giữ nguyên toàn bộ giá trị không đụng tới. */
  async ({ page }) => {
    await installG1MockApi(page);

    let savedRevision = 1;
    let currentWritableJson = `{
      "id": "${TEMPLATE_ID}",
      "workspaceId": "${WORKSPACE_ID}",
      "status": "DRAFT",
      "schemaVersion": 1,
      "revision": 1,
      "latestPublishedVersionId": null,
      "name": "Writable Precision Draft",
      "model": "FAN_LAB_V1",
      "streams": [
        { "key": "empty_note", "type": "STRING", "channelKind": "STATE", "direction": "READ", "default": "" },
        { "key": "blank_note", "type": "STRING", "channelKind": "STATE", "direction": "READ", "default": "   " },
        { "key": "counter", "type": "NUMBER", "channelKind": "STATE", "direction": "READ_WRITE", "unit": "cnt", "min": 0, "max": 1e20, "default": 9007199254740993 },
        { "key": "absent_note", "type": "STRING", "channelKind": "STATE", "direction": "READ" }
      ],
      "commands": [
        { "type": "SET_VALUE", "stream": "counter", "safeValue": 9007199254740993 }
      ],
      "createdAt": "2026-11-26T00:00:00Z",
      "updatedAt": "2026-11-26T01:00:00Z"
    }`;

    const capturedRawPatches = [];
    await page.route('**/api/v1/templates**',
      /** Trả JSON thô và bắt nguyên văn chuỗi PATCH body do trình duyệt gửi. */
      async (route) => {
        const req = route.request();
        const url = new URL(req.url());
        if (url.pathname === '/api/v1/templates' && req.method() === 'GET') {
          await route.fulfill({
            status: 200,
            headers: { 'content-type': 'application/json' },
            body: `{"items":[${currentWritableJson}],"nextCursor":null}`,
          });
          return;
        }
        if (url.pathname === `/api/v1/templates/${TEMPLATE_ID}` && req.method() === 'GET') {
          await route.fulfill({
            status: 200,
            headers: { 'content-type': 'application/json', etag: `"${savedRevision}"` },
            body: currentWritableJson,
          });
          return;
        }
        if (url.pathname === `/api/v1/templates/${TEMPLATE_ID}` && req.method() === 'PATCH') {
          const rawBody = req.postData() ?? '';
          const patchBody = req.postDataJSON();
          capturedRawPatches.push(rawBody);
          savedRevision += 1;
          const prevParsed = JSON.parse(
            currentWritableJson.replace(/:\s*9007199254740993/g, ':"__EXACT_2P53P1__"'),
          );
          const nextStreams = patchBody.streams
            ? JSON.parse(rawBody.replace(/:\s*9007199254740993/g, ':"__EXACT_2P53P1__"')).streams
            : prevParsed.streams;
          const nextCommands = patchBody.commands
            ? JSON.parse(rawBody.replace(/:\s*9007199254740993/g, ':"__EXACT_2P53P1__"')).commands
            : prevParsed.commands;
          currentWritableJson = `{
            "id": "${TEMPLATE_ID}",
            "workspaceId": "${WORKSPACE_ID}",
            "status": "DRAFT",
            "schemaVersion": 1,
            "revision": ${savedRevision},
            "latestPublishedVersionId": null,
            "name": ${JSON.stringify(patchBody.name ?? prevParsed.name)},
            "model": ${JSON.stringify(patchBody.model ?? prevParsed.model)},
            "streams": ${JSON.stringify(nextStreams).replace(/"__EXACT_2P53P1__"/g, '9007199254740993')},
            "commands": ${JSON.stringify(nextCommands).replace(/"__EXACT_2P53P1__"/g, '9007199254740993')},
            "createdAt": "2026-11-26T00:00:00Z",
            "updatedAt": "2026-11-26T01:00:00Z"
          }`;
          await route.fulfill({
            status: 200,
            headers: { 'content-type': 'application/json', etag: `"${savedRevision}"` },
            body: currentWritableJson,
          });
          return;
        }
        if (url.pathname === `/api/v1/templates/${TEMPLATE_ID}/versions` && req.method() === 'GET') {
          await route.fulfill({
            status: 200,
            headers: { 'content-type': 'application/json' },
            body: '{"items":[],"nextCursor":null}',
          });
          return;
        }
        await route.fallback();
      },
    );

    await page.goto('/login');
    await page.locator('#email').fill('admin@nexa.local');
    await page.locator('#password').fill('TestPassword123!');
    await page.getByRole('button', { name: 'Đăng nhập' }).click();
    await page.getByRole('button', { name: /Chọn workspace Lab Alpha/i }).click();
    await page.getByRole('button', { name: 'Templates (WB-03)' }).click();
    await page.getByRole('button', { name: 'Mở bản nháp' }).click();

    await expect(page.locator('#tpl-stream-0-default')).toHaveValue('');
    await expect(page.locator('#tpl-stream-0-default-present')).toBeChecked();
    await expect(page.locator('#tpl-stream-1-default')).toHaveValue('   ');
    await expect(page.locator('#tpl-stream-2-default')).toHaveValue('9007199254740993');
    await expect(page.locator('#tpl-stream-3-default-present')).not.toBeChecked();

    // 1. Chỉ sửa key của kênh thứ 4 (absent_note); các kênh 0/1/2 và command giữ nguyên không chạm tới.
    await page.locator('#tpl-stream-3-key').fill('absent_note_v2');
    await page.getByRole('button', { name: 'Lưu cập nhật nháp' }).click();
    await expect(page.getByRole('status').filter({ hasText: 'Đã lưu bản nháp trên máy chủ.' })).toContainText('Revision #2');

    expect(capturedRawPatches).toHaveLength(1);
    const rawPatch1 = capturedRawPatches[0];
    expect(rawPatch1).toContain('"key":"empty_note"');
    expect(rawPatch1).toContain('"default":""');
    expect(rawPatch1).toContain('"default":"   "');
    expect(rawPatch1).toContain('"default":9007199254740993');
    const parsedPatch1 = JSON.parse(rawPatch1);
    expect(Object.hasOwn(parsedPatch1.streams[3], 'default')).toBe(false);
    expect(parsedPatch1.commands).toBeUndefined();
    await expect(page.locator('#tpl-command-0-safeValue')).toHaveValue('9007199254740993');

    // 2. Thêm kênh + capability mới mà không sửa command 0 -> mảng commands gửi lên vẫn giữ nguyên safeValue 9007199254740993.
    await page.locator('#tpl-streams-add').click();
    await page.locator('#tpl-stream-4-key').fill('led');
    await page.locator('#tpl-stream-4-type').selectOption('BOOLEAN');
    await page.locator('#tpl-stream-4-direction').selectOption('WRITE');
    await page.getByRole('button', { name: /Tạo SET_VALUE cho/i }).click();
    await page.locator('#tpl-command-1-safeValue').selectOption('false');
    await page.getByRole('button', { name: 'Lưu cập nhật nháp' }).click();
    await expect(page.getByRole('status').filter({ hasText: 'Đã lưu bản nháp trên máy chủ.' })).toContainText('Revision #3');

    expect(capturedRawPatches).toHaveLength(2);
    expect(capturedRawPatches[1]).toContain('"safeValue":9007199254740993');
  },
);

test(
  'INT-0508-REG-PAGINATION + LOOKUP_RACE + ERROR_FEEDBACK: paginates deps across cursors, survives lookup race, and renders 422 without fieldErrors',
  /** Hồi quy 3 lỗi WB-04: nạp đủ nhiều trang version/owner, tra cứu serial song song không hủy load phụ thuộc, và hiển thị lỗi 422 OWNER_INVALID không có details.fieldErrors. */
  async ({ page }) => {
    await installG1MockApi(page, {
      initialStatus: 'PUBLISHED',
      initialLatestPublishedVersionId: VERSION_V1_ID,
    });

    const VERSION_V2_ID = 'cccccccc-cccc-4ccc-8ccc-ccccccccccc2';
    const OWNER_P2_ID = '33333333-3333-4333-8333-333333333334';
    let releaseMembersPage2;
    const membersPage2Gate = new Promise((resolve) => {
      releaseMembersPage2 = resolve;
    });

    await page.route(`**/api/v1/templates/${TEMPLATE_ID}/versions**`,
      /** Phân trang 2 trang cho danh sách TemplateVersion đã công bố. */
      async (route) => {
        const url = new URL(route.request().url());
        const cursor = url.searchParams.get('cursor');
        if (!cursor) {
          await route.fulfill({
            status: 200,
            headers: { 'content-type': 'application/json' },
            body: JSON.stringify({ items: [makeVersionV1()], nextCursor: 'ver-next-page' }),
          });
          return;
        }
        await route.fulfill({
          status: 200,
          headers: { 'content-type': 'application/json' },
          body: JSON.stringify({
            items: [{ ...makeVersionV1(), id: VERSION_V2_ID, version: 2, name: 'Quạt Lab Trang 2', sourceRevision: 2 }],
            nextCursor: null,
          }),
        });
      },
    );

    await page.route(`**/api/v1/workspaces/${WORKSPACE_ID}/members**`,
      /** Phân trang 2 trang cho thành viên ACTIVE và tạm giữ trang 2 để kích hoạt race với lookup serial. */
      async (route) => {
        const url = new URL(route.request().url());
        const cursor = url.searchParams.get('cursor');
        if (!cursor) {
          await route.fulfill({
            status: 200,
            headers: { 'content-type': 'application/json' },
            body: JSON.stringify({
              items: [{
                workspaceId: WORKSPACE_ID,
                userId: OWNER_ID,
                email: 'operator@nexa.local',
                alias: 'Kỹ thuật viên A',
                role: 'USER',
                status: 'ACTIVE',
                updatedAt: '2026-11-26T00:00:00Z',
              }],
              nextCursor: 'mem-next-page',
            }),
          });
          return;
        }
        await membersPage2Gate;
        await route.fulfill({
          status: 200,
          headers: { 'content-type': 'application/json' },
          body: JSON.stringify({
            items: [{
              workspaceId: WORKSPACE_ID,
              userId: OWNER_P2_ID,
              email: 'owner2@nexa.local',
              alias: 'Quản trị Trang 2',
              role: 'ADMIN',
              status: 'ACTIVE',
              updatedAt: '2026-11-26T00:00:00Z',
            }],
            nextCursor: null,
          }),
        });
      },
    );

    await page.route('**/api/v1/devices',
      /** Trả 422 OWNER_INVALID không kèm fieldErrors cho POST đăng ký thiết bị. */
      async (route) => {
        if (route.request().method() === 'POST') {
          await route.fulfill({
            status: 422,
            headers: { 'content-type': 'application/json' },
            body: JSON.stringify({
              error: {
                code: 'OWNER_INVALID',
                message: 'Owner is not active in this workspace.',
                details: {},
                correlationId: 'corr-owner-invalid-422',
              },
            }),
          });
          return;
        }
        await route.fallback();
      },
    );

    await page.goto('/login');
    await page.locator('#email').fill('admin@nexa.local');
    await page.locator('#password').fill('TestPassword123!');
    await page.getByRole('button', { name: 'Đăng nhập' }).click();
    await page.getByRole('button', { name: /Chọn workspace Lab Alpha/i }).click();
    await page.getByRole('button', { name: 'Thiết bị & USB (WB-04)' }).click();

    // Khi trang 2 members vẫn đang tải, thực hiện tra cứu serial song song (race).
    await expect(page.locator('#dev-field-owner')).toBeDisabled();
    await page.locator('#dev-lookup-serial').fill('missing-serial-01');
    await page.getByRole('button', { name: 'Tra cứu theo serial' }).click();
    await expect(page.getByText('Không tìm thấy thiết bị có serial này trong workspace hiện tại.')).toBeVisible();

    // Mở cổng cho trang 2 members hoàn tất -> đăng ký không bị treo disabled và có đủ item trang 2.
    releaseMembersPage2();
    await expect(page.locator('#dev-field-version')).toBeEnabled();
    await expect(page.locator('#dev-field-owner')).toBeEnabled();
    await expect(page.getByRole('button', { name: 'Đăng ký thiết bị' })).toBeEnabled();

    await page.locator('#dev-field-serial').fill('synthetic-room-page2');
    await page.locator('#dev-field-name').fill('Thiết bị trang 2');
    await page.locator('#dev-field-version').selectOption(VERSION_V2_ID);
    await page.locator('#dev-field-owner').selectOption(OWNER_P2_ID);
    await page.getByRole('button', { name: 'Đăng ký thiết bị' }).click();

    // Lỗi nghiệp vụ 422 OWNER_INVALID không có details.fieldErrors vẫn phải hiển thị rõ ràng và nhận focus.
    const alertSummary = page.locator('#dev-error-summary');
    await expect(alertSummary).toBeVisible();
    await expect(alertSummary).toContainText('Đăng ký bị từ chối (OWNER_INVALID).');
    await expect(alertSummary).toBeFocused();
  },
);

test(
  'INT-0508-REG-ARCHIVED-PIN: excludes ARCHIVED family pins while retaining PUBLISHED and DRAFT-root historical pins across pages',
  /** Kiểm tra picker #dev-field-version loại bỏ template ARCHIVED, không gọi /versions của family ARCHIVED, nhưng giữ nguyên version của family PUBLISHED và DRAFT có bản công bố cũ. */
  async ({ page }) => {
    await installG1MockApi(page, {
      initialStatus: 'PUBLISHED',
      initialLatestPublishedVersionId: VERSION_V1_ID,
    });

    const TEMPLATE_ARCHIVED_ID = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb3';
    const TEMPLATE_DRAFT_PIN_ID = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb4';
    const VER_ARCHIVED_ID = 'cccccccc-cccc-4ccc-8ccc-ccccccccccc3';
    const VER_DRAFT_HIST_ID = 'cccccccc-cccc-4ccc-8ccc-ccccccccccc4';
    const fetchedVersionPaths = [];

    await page.route('**/api/v1/templates**',
      /** Mô phỏng phân trang danh sách template gồm PUBLISHED, ARCHIVED và DRAFT từng công bố version. */
      async (route) => {
        const req = route.request();
        const url = new URL(req.url());
        if (url.pathname === '/api/v1/templates' && req.method() === 'GET') {
          const cursor = url.searchParams.get('cursor');
          if (!cursor) {
            await route.fulfill({
              status: 200,
              headers: { 'content-type': 'application/json' },
              body: JSON.stringify({
                items: [
                  {
                    id: TEMPLATE_ID,
                    workspaceId: WORKSPACE_ID,
                    name: 'Quạt Lab Chuẩn',
                    model: 'FAN_LAB_V1',
                    status: 'PUBLISHED',
                    schemaVersion: 1,
                    revision: 1,
                    latestPublishedVersionId: VERSION_V1_ID,
                    streams: [BASE_STREAM],
                    commands: [BASE_COMMAND],
                    createdAt: '2026-11-26T00:00:00Z',
                    updatedAt: '2026-11-26T01:00:00Z',
                  },
                  {
                    id: TEMPLATE_ARCHIVED_ID,
                    workspaceId: WORKSPACE_ID,
                    name: 'Cảm biến đã lưu trữ',
                    model: 'FAN_ARCHIVED',
                    status: 'ARCHIVED',
                    schemaVersion: 1,
                    revision: 2,
                    latestPublishedVersionId: VER_ARCHIVED_ID,
                    streams: [BASE_STREAM],
                    commands: [BASE_COMMAND],
                    createdAt: '2026-11-26T00:00:00Z',
                    updatedAt: '2026-11-26T01:00:00Z',
                  },
                ],
                nextCursor: 'tpl-page-2',
              }),
            });
            return;
          }
          await route.fulfill({
            status: 200,
            headers: { 'content-type': 'application/json' },
            body: JSON.stringify({
              items: [
                {
                  id: TEMPLATE_DRAFT_PIN_ID,
                  workspaceId: WORKSPACE_ID,
                  name: 'Quạt Lab Draft Mới',
                  model: 'FAN_DRAFT_HIST',
                  status: 'DRAFT',
                  schemaVersion: 1,
                  revision: 3,
                  latestPublishedVersionId: VER_DRAFT_HIST_ID,
                  streams: [BASE_STREAM],
                  commands: [BASE_COMMAND],
                  createdAt: '2026-11-26T00:00:00Z',
                  updatedAt: '2026-11-26T01:00:00Z',
                },
              ],
              nextCursor: null,
            }),
          });
          return;
        }
        if (url.pathname.endsWith('/versions') && req.method() === 'GET') {
          fetchedVersionPaths.push(url.pathname);
          if (url.pathname === `/api/v1/templates/${TEMPLATE_DRAFT_PIN_ID}/versions`) {
            await route.fulfill({
              status: 200,
              headers: { 'content-type': 'application/json' },
              body: JSON.stringify({
                items: [{
                  ...makeVersionV1(),
                  id: VER_DRAFT_HIST_ID,
                  templateId: TEMPLATE_DRAFT_PIN_ID,
                  version: 1,
                  name: 'Quạt Lab Draft Mới',
                  model: 'FAN_DRAFT_HIST',
                }],
                nextCursor: null,
              }),
            });
            return;
          }
        }
        await route.fallback();
      },
    );

    await page.goto('/login');
    await page.locator('#email').fill('admin@nexa.local');
    await page.locator('#password').fill('TestPassword123!');
    await page.getByRole('button', { name: 'Đăng nhập' }).click();
    await page.getByRole('button', { name: /Chọn workspace Lab Alpha/i }).click();
    await page.getByRole('button', { name: 'Thiết bị & USB (WB-04)' }).click();

    const versionSelect = page.locator('#dev-field-version');
    await expect(versionSelect).toBeEnabled();
    await expect(versionSelect.locator(`option[value="${VERSION_V1_ID}"]`)).toHaveCount(1);
    await expect(versionSelect.locator(`option[value="${VER_DRAFT_HIST_ID}"]`)).toHaveCount(1);
    await expect(versionSelect.locator(`option[value="${VER_ARCHIVED_ID}"]`)).toHaveCount(0);
    expect(fetchedVersionPaths).not.toContain(`/api/v1/templates/${TEMPLATE_ARCHIVED_ID}/versions`);
  },
);
