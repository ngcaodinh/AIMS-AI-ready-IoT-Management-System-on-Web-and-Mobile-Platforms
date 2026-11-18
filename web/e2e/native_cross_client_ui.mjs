import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { createInterface } from 'node:readline';
import { setTimeout as delay } from 'node:timers/promises';
import { chromium, request } from '@playwright/test';
import {
  createBrowserSecretCanaryState,
  disposeBrowserSecretCanary,
  finishBrowserSecretRegistration,
  observeBrowserSink,
  registerBrowserSecret,
} from './browser_secret_canary.mjs';

const webOrigin = 'http://localhost:5173';
const webReadyTimeoutMilliseconds = 30_000;
const inputTimeoutMilliseconds = 30_000;

/** Đọc một dòng IPC với thời hạn hữu hạn, không đưa dữ liệu lỗi ra stdout.
 * Input
 * Param: iterator — bộ đọc stdin do tiến trình host sở hữu.
 * Param: timeoutMilliseconds — giới hạn chờ credential hoặc ACK từ host.
 * Output: dòng IPC nguyên vẹn để caller xác thực schema và trạng thái.
 * Errors: từ chối EOF, timeout hoặc frame không phải chuỗi.
 */
async function readInputLine(iterator, timeoutMilliseconds) {
  let timeoutId;
  try {
    const result = await Promise.race([
      iterator.next(),
      new Promise((_, reject) => {
        /** Chỉ giới hạn ACK IPC, không mở thêm thời gian cho UI hoặc fixture. */
        timeoutId = setTimeout(() => reject(new Error('WEB_UI_INPUT_TIMEOUT')), timeoutMilliseconds);
      }),
    ]);
    if (result.done || typeof result.value !== 'string') throw new Error('WEB_UI_INPUT_CLOSED');
    return result.value;
  } finally {
    clearTimeout(timeoutId);
  }
}

/** Kiểm tra credential chỉ thuộc fixture account0 và đúng hình dạng do runner sinh.
 * Input
 * Param: rawLine — frame JSON đầu tiên nhận qua stdin.
 * Output: email/password tổng hợp dùng trong bộ nhớ để thao tác browser.
 * Errors: từ chối field thừa, identity sai namespace hoặc password ngoài mẫu fixture.
 */
function parseFixtureCredentials(rawLine) {
  const value = JSON.parse(rawLine);
  assert.ok(value !== null && typeof value === 'object' && !Array.isArray(value));
  assert.deepEqual(Object.keys(value).sort(), ['email', 'password']);
  assert.match(value.email, /^probe-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}-0@example\.invalid$/);
  assert.match(value.password, /^Aa1[0-9a-f]{32}$/);
  return { email: value.email, password: value.password };
}

/** Kiểm tra trang đăng nhập đã được phục vụ trên origin cố định.
 * Output: true khi trang phản hồi HTTP thành công.
 * Side effects: gửi GET không chứa credential tới Vite.
 */
async function isWebServerReady() {
  const controller = new AbortController();
  const timeout = setTimeout(
    /** Hủy probe mạng nếu origin không phản hồi trong một nhịp kiểm tra. */
    () => controller.abort(),
    1_000,
  );
  try {
    const response = await fetch(`${webOrigin}/login`, { signal: controller.signal });
    return response.ok;
  } catch {
    return false;
  } finally {
    clearTimeout(timeout);
  }
}

/** Khởi chạy script Vite cố định trong workspace Web, không nhận command từ packet.
 * Output: child process để owner dừng trong cleanup.
 * Side effects: mở tiến trình dev server trên port đã cố định trong vite.config.ts.
 */
function startWebServer() {
  const command = process.platform === 'win32' ? 'npm.cmd' : 'npm';
  const child = spawn(command, ['run', 'dev'], {
    cwd: process.cwd(),
    shell: process.platform === 'win32',
    windowsHide: true,
    stdio: 'ignore',
  });
  child.on('error',
    /** Ghi nhận startup failure cục bộ; không in command/path hoặc OS message. */
    () => { child.startupFailed = true; },
  );
  return child;
}

/** Chờ Vite sẵn sàng trong deadline; server có sẵn được tái sử dụng như Playwright config.
 * Input
 * Param: child — Vite process mới hoặc undefined nếu origin đã sẵn sàng.
 * Errors: báo lỗi cố định nếu startup hết hạn hoặc child thoát sớm.
 * Side effects: polling GET /login theo nhịp hữu hạn.
 */
async function waitForWebServer(child) {
  const deadline = performance.now() + webReadyTimeoutMilliseconds;
  while (performance.now() < deadline) {
    if (await isWebServerReady()) return;
    if (child && (child.exitCode !== null || child.startupFailed)) throw new Error('WEB_UI_SERVER_EXITED');
    await delay(250);
  }
  throw new Error('WEB_UI_SERVER_TIMEOUT');
}

/** Đợi logout bodyless khi socket S1 còn mở rồi xác nhận UI đã trở về màn đăng nhập.
 * Input
 * Param: page — trang React đã đăng nhập và chọn workspace.
 * Output: không có; assertion thất bại nếu HTTP/UI logout không đạt.
 * Side effects: chốt trạng thái socket trước thao tác, click logout và đọc cookie jar.
 */
async function verifyUiLogout(page) {
  const socketReady = await page.evaluate(
    /** Ghi mốc bắt đầu logout khi socket S1 còn mở để đối chiếu close phía server. */
    () => {
      const socket = window.__tn002Socket;
      if (!socket || socket.readyState !== WebSocket.OPEN) return false;
      window.__tn002LogoutStartedAt = performance.now();
      return true;
    },
  );
  assert.equal(socketReady, true, 'WEB_UI_REALTIME_SOCKET_NOT_OPEN_BEFORE_LOGOUT');
  const logoutResponsePromise = page.waitForResponse(
    /** Chỉ ghép đúng POST logout API do nút React phát ra. */
    (response) => response.request().method() === 'POST'
      && new URL(response.url()).pathname === '/api/v1/auth/logout',
  );
  await page.getByRole('button', { name: 'Đăng xuất', exact: true }).click();
  const logoutResponse = await logoutResponsePromise;
  assert.equal(logoutResponse.status(), 204, 'WEB_UI_LOGOUT_STATUS_INVALID');
  assert.equal((await logoutResponse.body()).byteLength, 0, 'WEB_UI_LOGOUT_BODY_INVALID');
  await page.getByRole('textbox', { name: 'Email' }).waitFor({ state: 'visible' });
  const remainingCookies = await page.context().cookies(`${webOrigin}/api/v1/me`);
  assert.equal(remainingCookies.some(
    /** Tìm riêng cookie session cần bị xóa sau response 204. */
    (cookie) => cookie.name === 'iot_session',
  ), false,
    'WEB_UI_LOGOUT_COOKIE_REMAINS');
}

/** Mở socket thật của Web S1 bằng ticket ở frame đầu và lưu listener trước logout.
 * Input
 * Param: page — browser context cùng origin được backend cho phép và giữ cookie S1.
 * Param: sessionContextId — context ID từ login Web để kiểm tra quyền session hiện hành.
 * Param: csrfToken — CSRF của S1 dùng cho mutation ticket.
 * Output: trạng thái xác thực an toàn, không trả ticket hoặc frame thô.
 * Errors: mã cố định nếu workspace, ticket, transport hoặc ACK sai/hết hạn.
 * Side effects: cấp ticket thật, mở WebSocket trực tiếp tới backend và đăng ký close observer.
 */
async function openAuthenticatedWebSessionSocket(page, sessionContextId, csrfToken) {
  const result = await page.evaluate(
    /** Ticket chỉ đi từ response thật sang frame đầu; URL và reporter không nhận capability. */
    async ({ authContextId, csrf }) => {
      const workspacesResponse = await fetch('/api/v1/workspaces', {
        headers: { 'X-Auth-Context-Id': authContextId },
      });
      if (!workspacesResponse.ok) return { kind: 'workspace-failed' };
      let workspaces;
      try { workspaces = await workspacesResponse.json(); } catch { return { kind: 'workspace-invalid' }; }
      const workspaceId = workspaces?.items?.[0]?.id;
      if (typeof workspaceId !== 'string' || workspaceId.length === 0) return { kind: 'workspace-invalid' };

      const ticketResponse = await fetch('/api/v1/realtime/tickets', {
        method: 'POST',
        headers: {
          'X-Auth-Context-Id': authContextId,
          'X-CSRF-Token': csrf,
          'X-Workspace-Id': workspaceId,
        },
      });
      if (ticketResponse.status !== 201 || ticketResponse.headers.get('cache-control') !== 'no-store') {
        return { kind: 'ticket-rejected' };
      }
      let ticketBody;
      try { ticketBody = await ticketResponse.json(); } catch { return { kind: 'ticket-invalid' }; }
      if (typeof ticketBody?.ticket !== 'string' || !/^[0-9a-f]{64}$/.test(ticketBody.ticket)
        || typeof ticketBody.expiresAt !== 'string' || Date.parse(ticketBody.expiresAt) <= Date.now()) {
        return { kind: 'ticket-invalid' };
      }

      let firstFrameTicket = ticketBody.ticket;
      ticketBody.ticket = '';
      await window.__tn002RegisterSensitiveValue(firstFrameTicket);
      const socket = new WebSocket(`ws://${window.location.hostname}:3000/api/v1/realtime`);
      window.__tn002Socket = socket;
      window.__tn002SocketClose = new Promise(
        /** Observer tồn tại trước logout để không bỏ lỡ close frame từ backend. */
        (resolve) => socket.addEventListener('close',
          /** Chỉ giữ mã policy, cờ cleanliness và thời điểm; loại bỏ reason hoặc frame raw. */
          (event) => resolve({
            kind: 'closed',
            policyClose: event.code === 1008,
            authenticationRequired: event.reason === 'Authentication required.',
            wasClean: event.wasClean,
            closedAt: performance.now(),
          }),
          { once: true },
        ),
      );

      return new Promise(
        /** Chờ server ACK trong ngân sách cố định, không phản chiếu nội dung frame khác. */
        (resolve) => {
          let settled = false;
          let preAuthenticationFrames = 0;
          let ticketSent = false;
          let timer;
          /** Hoàn tất một lần và chỉ trả enum/cờ không nhạy cảm. */
          const finish = (kind) => {
            if (settled) return;
            settled = true;
            window.clearTimeout(timer);
            resolve({
              kind,
              preAuthenticationFrames,
              ticketSent,
              socketOpen: socket.readyState === WebSocket.OPEN,
            });
          };
          timer = window.setTimeout(() => finish('timeout'), 6_000);
          socket.addEventListener('open',
            /** Gửi ticket đúng frame đầu và xóa bản local sau lần gửi. */
            () => {
              try {
                socket.send(firstFrameTicket);
                firstFrameTicket = '';
                ticketSent = true;
              } catch {
                firstFrameTicket = '';
                finish('send-failed');
              }
            },
            { once: true },
          );
          socket.addEventListener('message',
            /** Chấp nhận duy nhất AUTHENTICATED sau ticket; các frame khác chỉ được đếm. */
            (event) => {
              if (ticketSent && event.data === 'AUTHENTICATED') finish('authenticated');
              else preAuthenticationFrames += 1;
            },
          );
          socket.addEventListener('close',
            /** Close trước ACK là lỗi handshake, không phải bằng chứng logout. */
            () => finish('closed-before-authentication'),
            { once: true },
          );
          socket.addEventListener('error',
            /** Lỗi transport trở thành marker cố định, không chứa exception browser. */
            () => finish('transport-failed'),
            { once: true },
          );
        },
      );
    },
    { authContextId: sessionContextId, csrf: csrfToken },
  );
  assert.deepEqual(result, {
    kind: 'authenticated',
    preAuthenticationFrames: 0,
    ticketSent: true,
    socketOpen: true,
  }, 'WEB_UI_REALTIME_SOCKET_AUTHENTICATION_INVALID');
}

/** Xác nhận backend đóng socket S1 theo policy sau khi UI logout đã nhận HTTP 204.
 * Input
 * Param: page — browser context đã hoàn tất logout nhưng chưa bị đóng.
 * Errors: mã cố định nếu observer thiếu, timeout, close sai policy hoặc xảy ra trước logout.
 */
async function verifyWebSessionSocketClosed(page) {
  const result = await page.evaluate(
    /** Chờ close đã quan sát thật; không gọi socket.close để tạo kết quả tổng hợp. */
    async () => {
      const closePromise = window.__tn002SocketClose;
      const logoutStartedAt = window.__tn002LogoutStartedAt;
      if (!closePromise || !Number.isFinite(logoutStartedAt)) return { kind: 'missing' };
      let timer;
      const close = await Promise.race([
        closePromise,
        new Promise((resolve) => {
          /** Timeout chỉ kết thúc phép đo; observer vẫn thuộc socket S1 hiện hành. */
          timer = window.setTimeout(() => resolve({ kind: 'timeout' }), 7_000);
        }),
      ]);
      window.clearTimeout(timer);
      return {
        kind: close?.kind ?? 'invalid',
        policyClose: close?.policyClose === true,
        authenticationRequired: close?.authenticationRequired === true,
        wasClean: close?.wasClean === true,
        afterLogoutStarted: close?.closedAt >= logoutStartedAt,
      };
    },
  );
  assert.deepEqual(result, {
    kind: 'closed',
    policyClose: true,
    authenticationRequired: true,
    wasClean: true,
    afterLogoutStarted: true,
  }, 'WEB_UI_REALTIME_SOCKET_CLOSE_INVALID');
}
/** Gửi stale mutation và logout retry bằng cookie/context giữ riêng trong RAM sau UI logout.
 * Input
 * Param: cookiePair — cookie S1 cũ thu được từ browser context trước logout.
 * Param: sessionContextId — auth context ID của S1 từ response login.
 * Param: csrfToken — CSRF của S1 từ response login.
 * Errors: yêu cầu 401 SESSION_REVOKED và retry 204 bodyless.
 * Side effects: tạo rồi dispose API request context riêng cho stale session probes.
 */
async function verifyStaleSessionProbes(cookiePair, sessionContextId, csrfToken) {
  const staleRequest = await request.newContext({
    baseURL: webOrigin,
    extraHTTPHeaders: {
      cookie: cookiePair,
      origin: webOrigin,
      'x-auth-context-id': sessionContextId,
      'x-csrf-token': csrfToken,
    },
  });
  try {
    const mutation = await staleRequest.post('/api/v1/auth/password', {
      data: {
        currentPassword: 'synthetic-invalid-current-password',
        newPassword: `Aa2${'b'.repeat(32)}`,
      },
    });
    assert.equal(mutation.status(), 401, 'WEB_UI_STALE_MUTATION_STATUS_INVALID');
    assert.equal((await mutation.json())?.error?.code, 'SESSION_REVOKED', 'WEB_UI_STALE_MUTATION_CODE_INVALID');
    const retry = await staleRequest.post('/api/v1/auth/logout');
    assert.equal(retry.status(), 204, 'WEB_UI_LOGOUT_RETRY_STATUS_INVALID');
    assert.equal((await retry.body()).byteLength, 0, 'WEB_UI_LOGOUT_RETRY_BODY_INVALID');
  } finally {
    await staleRequest.dispose();
  }
}

/** Dừng đúng cây Vite do scenario này khởi chạy để npm.cmd không bỏ sót tiến trình node con.
 * Input
 * Param: child — process npm/Vite do startWebServer tạo trong lượt hiện tại.
 * Side effects: Windows dừng cây bằng PID owned; hệ khác gửi tín hiệu trực tiếp và đợi bounded exit.
 */
async function stopWebServer(child) {
  if (child.exitCode !== null) return;
  if (process.platform === 'win32') {
    const treeStopper = spawn('taskkill.exe', ['/PID', String(child.pid), '/T', '/F'], {
      shell: false,
      windowsHide: true,
      stdio: 'ignore',
    });
    treeStopper.on('error',
      /** Fallback sẽ dừng parent handle nếu Windows task-tree utility không chạy được. */
      () => { treeStopper.startupFailed = true; },
    );
    const stopperExit = once(treeStopper, 'exit').then(
      /** Tiêu thụ exit receipt local, không in PID hay process output. */
      () => true,
      /** Error đã được ghi nhận bằng cờ local để ngăn unhandled rejection. */
      () => false,
    );
    await Promise.race([stopperExit, delay(5_000)]);
  }
  if (child.exitCode === null) {
    try { child.kill(); } catch { /* Fallback chỉ nhắm process handle owned ở trên. */ }
    const childExit = once(child, 'exit').then(
      /** Exit của server owned là tín hiệu cleanup hoàn tất. */
      () => true,
      /** Error đã được bắt để finally không phát raw process detail. */
      () => false,
    );
    await Promise.race([childExit, delay(5_000)]);
  }
}

/** Chạy Web S1 login/workspace, xác thực socket thật rồi kiểm server close sau logout.
 * Errors: chỉ phát stage enum cố định khi có lỗi; không log exception/credential/response body.
 * Side effects: khởi chạy Vite nếu cần, mở Chrome headless và giữ nguyên fixture ACK/cleanup.
 */
async function run() {
  const input = createInterface({ input: process.stdin, crlfDelay: Infinity });
  const inputIterator = input[Symbol.asyncIterator]();
  let webServer;
  let browser;
  let passed = false;
  let cleanupFailed = false;
  const sinkState = createBrowserSecretCanaryState();
  let stage = 'input';
  try {
    const credentials = parseFixtureCredentials(await readInputLine(inputIterator, inputTimeoutMilliseconds));
    registerBrowserSecret(sinkState, credentials.email);
    registerBrowserSecret(sinkState, credentials.password);
    stage = 'web-server';
    if (!(await isWebServerReady())) webServer = startWebServer();
    await waitForWebServer(webServer);

    stage = 'browser';
    browser = await chromium.launch({ channel: 'chrome', headless: true });
    const context = await browser.newContext();
    const page = await context.newPage();
    page.setDefaultTimeout(10_000);
    page.setDefaultNavigationTimeout(15_000);
    page.on('console',
      /** Canari console thật của React kiểm credential mà không đưa text vào reporter. */
      (message) => observeBrowserSink(sinkState, message.text()),
    );
    page.on('pageerror',
      /** Canari exception browser thật giữ duy nhất trạng thái leak, không giữ stack/message. */
      (error) => observeBrowserSink(sinkState, error.message),
    );
    await page.exposeFunction('__tn002RegisterSensitiveValue',
      /** Nhận ticket để quét sink trước khi browser gửi capability qua WebSocket. */
      (value) => registerBrowserSecret(sinkState, value),
    );

    stage = 'ui-login';
    await page.goto(`${webOrigin}/login`);
    await page.getByRole('textbox', { name: 'Email' }).fill(credentials.email);
    await page.getByRole('textbox', { name: 'Mật khẩu' }).fill(credentials.password);
    const loginResponsePromise = page.waitForResponse(
      /** Chỉ nhận POST login từ form React trên origin của E2E. */
      (response) => response.request().method() === 'POST'
        && new URL(response.url()).pathname === '/api/v1/auth/login',
    );
    await page.getByRole('button', { name: 'Đăng nhập', exact: true }).click();
    const loginResponse = await loginResponsePromise;
    assert.equal(loginResponse.status(), 200, 'WEB_UI_LOGIN_STATUS_INVALID');
    const loginHeaders = loginResponse.headers();
    const sessionContextId = loginHeaders['x-auth-context-id'] ?? '';
    const csrfToken = loginHeaders['x-csrf-token'] ?? '';
    assert.ok(sessionContextId.length > 0 && csrfToken.length > 0, 'WEB_UI_SESSION_METADATA_MISSING');
    registerBrowserSecret(sinkState, sessionContextId);
    registerBrowserSecret(sinkState, csrfToken);

    stage = 'session-cookie';
    const sessionCookie = (await context.cookies(`${webOrigin}/api/v1/me`)).find(
      /** Chỉ giữ HttpOnly session cookie cũ trong RAM để thử stale request sau logout. */
      (cookie) => cookie.name === 'iot_session' && cookie.httpOnly,
    );
    assert.ok(sessionCookie?.value, 'WEB_UI_SESSION_COOKIE_MISSING');
    const cookiePair = `iot_session=${sessionCookie.value}`;
    registerBrowserSecret(sinkState, sessionCookie.value);
    registerBrowserSecret(sinkState, cookiePair);

    stage = 'ui-workspace';
    await page.getByRole('heading', { name: 'Chọn workspace' }).waitFor({ state: 'visible' });
    const workspaceChoice = page.getByRole('button', { name: /^Chọn workspace / }).first();
    await workspaceChoice.waitFor({ state: 'visible' });
    await workspaceChoice.click();
    await page.getByRole('status').filter({ hasText: 'Đã xác minh quyền' }).waitFor({ state: 'visible' });

    stage = 'realtime-authentication';
    await openAuthenticatedWebSessionSocket(page, sessionContextId, csrfToken);
    const canaryResult = finishBrowserSecretRegistration(sinkState);
    assert.equal(canaryResult.invalidInput, false, 'WEB_UI_SECRET_SINK_INPUT_INVALID');
    assert.equal(canaryResult.overflowed, false, 'WEB_UI_SECRET_SINK_BUFFER_OVERFLOW');
    assert.equal(canaryResult.leaked, false, 'WEB_UI_SECRET_SINK_LEAK');

    stage = 'host-login-ack';
    process.stdout.write('WEB_UI_LOGIN_COMPLETE\n');
    const acknowledgment = await readInputLine(inputIterator, inputTimeoutMilliseconds);
    if (acknowledgment !== 'CONTINUE') throw new Error('WEB_UI_HOST_ABORTED');

    stage = 'ui-logout';
    await verifyUiLogout(page);
    stage = 'realtime-close';
    await verifyWebSessionSocketClosed(page);
    stage = 'stale-probes';
    await verifyStaleSessionProbes(cookiePair, sessionContextId, csrfToken);
    stage = 'browser-sink';
    assert.equal(sinkState.leaked, false, 'WEB_UI_SECRET_SINK_LEAK');
    assert.equal(sinkState.overflowed, false, 'WEB_UI_SECRET_SINK_BUFFER_OVERFLOW');
    assert.equal(sinkState.invalidInput, false, 'WEB_UI_SECRET_SINK_INPUT_INVALID');
    passed = true;
  } catch {
    process.stdout.write(`WEB_UI_FAILURE_${stage.toUpperCase()}\n`);
    process.exitCode = 1;
  } finally {
    try { await browser?.close(); } catch { cleanupFailed = true; }
    if (webServer && webServer.exitCode === null) {
      try { await stopWebServer(webServer); } catch { cleanupFailed = true; }
    }
    disposeBrowserSecretCanary(sinkState);
    if (passed && sinkState.leaked) {
      process.stdout.write('WEB_UI_FAILURE_BROWSER_SINK\n');
      process.exitCode = 1;
    } else if (passed && cleanupFailed) {
      process.stdout.write('WEB_UI_FAILURE_CLEANUP\n');
      process.exitCode = 1;
    } else if (passed) process.stdout.write('WEB_UI_LOGOUT_COMPLETE\n');
    input.close();
  }
}

run().catch(
  /** Không forward exception nội bộ hoặc dữ liệu credential nếu cleanup bất ngờ lỗi. */
  () => {
    process.stdout.write('WEB_UI_FAILURE_UNEXPECTED\n');
    process.exitCode = 1;
  },
);
