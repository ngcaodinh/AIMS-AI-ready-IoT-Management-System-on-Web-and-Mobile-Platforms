import { spawn } from 'node:child_process';
import { EventEmitter, once } from 'node:events';
import { createHash, generateKeyPairSync, randomBytes } from 'node:crypto';
import { createConnection } from 'node:net';
import { createInterface } from 'node:readline';
import { PassThrough } from 'node:stream';
import { fileURLToPath } from 'node:url';
import { expect, request, test } from '@playwright/test';
import { decryptBrowserFixture } from '../../ops/auth/browser_fixture_handoff.mjs';

// Deadline 20 phút trùng với watchdog monotonic của fixture owner.
const LAB_ACTIVE_WINDOW_MS = 1_200_000;
// Fixture owner quan sát cleanup tối đa 18 phút; thêm 30 giây cho receipt qua pipe.
const LAB_CLEANUP_WINDOW_MS = 18 * 60_000 + 30_000;
// Owner đã xác nhận cleanup nhưng không thoát thì chỉ dừng đúng wrapper child này.
const LAB_OWNER_EXIT_GRACE_MS = 5_000;
// Bao phủ active window, cleanup window, exit grace và 30 giây cho setup/teardown Playwright.
const LAB_E2E_TIMEOUT_MS = LAB_ACTIVE_WINDOW_MS + LAB_CLEANUP_WINDOW_MS + LAB_OWNER_EXIT_GRACE_MS + 30_000;
const fixtureState = {
  child: undefined,
  output: undefined,
  credentials: undefined,
  ready: false,
  lastFrameKind: undefined,
  cleanupUnconfirmed: false,
};

/**
 * Đọc frame giới hạn từ fixture owner để kiểm soát giao thức mà không lộ ciphertext.
 * Input
 * Param: state — trạng thái child/output thuộc fixture owner đang được kiểm soát.
 * Param: timeoutMilliseconds — ngân sách hữu hạn của phase chờ READY hoặc cleanup receipt.
 * Output: frame JSON đã parse và kiểm tra cấu trúc trước khi caller dùng.
 * Errors: trả mã cố định khi owner thoát sớm, timeout hoặc gửi frame không hợp lệ.
 * Side effects: tiêu thụ một frame từ stream fixture và giải phóng bộ hẹn giờ chờ.
 */
async function readLabFrame(state = fixtureState, timeoutMilliseconds = LAB_ACTIVE_WINDOW_MS) {
  const controller = new AbortController();
  const timeout = setTimeout(
    /** Khóa chờ sau cùng deadline của lab, không in frame hoặc nội dung pipe. */
    () => controller.abort(),
    timeoutMilliseconds,
  );
  try {
    const childExit = once(state.child, 'exit', { signal: controller.signal }).then(
      /** Helper thoát trước frame là lỗi fixture; không đưa code hoặc stderr thô vào report. */
      () => { throw new Error('BROWSER_LAB_EXITED_EARLY'); },
    );
    const [line] = await Promise.race([
      once(state.output, 'line', { signal: controller.signal }),
      childExit,
    ]);
    const frame = JSON.parse(line);
    if (frame === null || typeof frame !== 'object' || typeof frame.kind !== 'string') {
      throw new Error('BROWSER_LAB_FRAME_INVALID');
    }
    state.lastFrameKind = frame.kind;
    return frame;
  } catch {
    if (state.child?.exitCode !== null && state.child?.exitCode !== undefined) {
      throw new Error(`BROWSER_LAB_CHILD_EXIT_${state.child.exitCode}`);
    }
    if (controller.signal.aborted) throw new Error('BROWSER_LAB_WAIT_TIMEOUT');
    throw new Error('BROWSER_LAB_PROTOCOL_FAILED');
  } finally {
    clearTimeout(timeout);
    controller.abort();
  }
}

/**
 * Tạo fixture DB thật để E2E kiểm tra luồng nghiệp vụ, giữ credential tổng hợp trong RAM.
 * Input
 * Param: state — trạng thái vòng đời của fixture owner cần khởi chạy.
 * Errors: dừng bước chuẩn bị nếu owner không sẵn sàng hoặc dữ liệu fixture không giải mã được.
 * Side effects: khởi chạy process fixture và giữ credential kiểm thử trong bộ nhớ đến cleanup.
 */
async function startLabFixture(state = fixtureState) {
  if (state.cleanupUnconfirmed) throw new Error('BROWSER_LAB_CLEANUP_UNCONFIRMED');
  state.lastFrameKind = undefined;
  const keyPair = generateKeyPairSync('rsa', { modulusLength: 2048 });
  const publicKey = keyPair.publicKey.export({ format: 'der', type: 'spki' }).toString('base64');
  const labPath = fileURLToPath(new URL('../../ops/auth/run_browser_e2e_lab.mjs', import.meta.url));
  const projectRoot = fileURLToPath(new URL('../../', import.meta.url));
  state.child = spawn(process.execPath, [labPath, publicKey], {
    cwd: projectRoot,
    windowsHide: true,
    shell: false,
    stdio: ['pipe', 'pipe', 'ignore'],
  });
  state.output = createInterface({ input: state.child.stdout });
  const ready = await readLabFrame(state);
  if (ready.kind !== 'BROWSER_LAB_READY' || typeof ready.ciphertext !== 'string') {
    throw new Error('BROWSER_LAB_READY_INVALID');
  }
  state.credentials = decryptBrowserFixture(ready.ciphertext, keyPair.privateKey);
  state.ready = true;
  ready.ciphertext = '';
}

/**
 * Gửi STOP và chờ receipt cùng exit hữu hạn để không treo test hoặc tuyên bố cleanup chưa xác nhận.
 * Input
 * Param: state — child/output/credential thuộc owner do runner này khởi chạy.
 * Param: budgets — thời hạn cleanup và grace thoát; chỉ giảm trong ca kiểm thử giả lập.
 * Errors: mã cố định phân biệt cleanup chưa xác nhận, owner chưa thoát và exit bất thường.
 * Side effects: yêu cầu cleanup; chỉ đóng đúng wrapper child sau receipt, còn thiếu receipt thì nhả handle và khóa fixture tiếp theo.
 */
async function stopLabFixture(state = fixtureState, budgets = {}) {
  const child = state.child;
  if (!child) return;
  const cleanupTimeoutMilliseconds = budgets.cleanupTimeoutMilliseconds ?? LAB_CLEANUP_WINDOW_MS;
  const childExitTimeoutMilliseconds = budgets.childExitTimeoutMilliseconds ?? LAB_OWNER_EXIT_GRACE_MS;
  const alreadyExited = child.exitCode !== null || child.signalCode !== null;
  if (alreadyExited) {
    // Lưu trạng thái trước khi reset để không che việc fixture thoát sau khi đã sẵn sàng.
    const exitedAfterReady = state.ready;
    const lastFrameKind = ['BROWSER_LAB_READY', 'BROWSER_LAB_FAILED', 'BROWSER_LAB_UNAVAILABLE']
      .includes(state.lastFrameKind) ? state.lastFrameKind : 'NO_FRAME';
    const childExitCode = child.exitCode ?? 'SIGNALLED';
    state.output?.close();
    if (state.credentials) state.credentials.password = '';
    state.credentials = undefined;
    state.child = undefined;
    state.output = undefined;
    state.ready = false;
    state.cleanupUnconfirmed = true;
    if (exitedAfterReady) {
      throw new Error('BROWSER_LAB_EXITED_BEFORE_CLEANUP_' + childExitCode + '_' + lastFrameKind);
    }
    throw new Error('BROWSER_LAB_CLEANUP_UNCONFIRMED_' + childExitCode + '_' + lastFrameKind);
  }

  let cleanupConfirmed = false;
  let ownerExitConfirmed = false;
  let failureCode;
  try {
    child.stdin.end('STOP\n');
    const cleanupDeadline = Date.now() + cleanupTimeoutMilliseconds;
    let unavailableSeen = false;
    while (!cleanupConfirmed) {
      const remainingMilliseconds = cleanupDeadline - Date.now();
      if (remainingMilliseconds <= 0) throw new Error('BROWSER_LAB_CLEANUP_UNCONFIRMED');
      const frame = await readLabFrame(state, remainingMilliseconds);
      if (frame.kind === 'BROWSER_LAB_OWNED_CLEANUP_PASS') {
        cleanupConfirmed = true;
      } else if (frame.kind === 'BROWSER_LAB_UNAVAILABLE' && !unavailableSeen) {
        // UNAVAILABLE chỉ báo E2E fail; owner vẫn có thể hoàn tất original cleanup và phát receipt tiếp theo.
        unavailableSeen = true;
      } else {
        const cleanupFrameKind = ['BROWSER_LAB_READY', 'BROWSER_LAB_FAILED', 'BROWSER_LAB_UNAVAILABLE']
          .includes(frame.kind) ? frame.kind : 'UNEXPECTED';
        throw new Error('BROWSER_LAB_CLEANUP_FRAME_' + cleanupFrameKind);
      }
    }
    ownerExitConfirmed = await waitForLabChildExit(child, childExitTimeoutMilliseconds);
    if (!ownerExitConfirmed) {
      // Receipt chứng minh fixture đã được dọn nên chỉ lúc này mới an toàn dừng wrapper owner bị kẹt.
      try { child.kill(); } catch { /* Exit vẫn bị báo chưa xác nhận bên dưới. */ }
      releaseLabChildHandles(child);
      throw new Error('BROWSER_LAB_OWNER_EXIT_UNCONFIRMED');
    }
    if (child.signalCode !== null || child.exitCode !== 0) {
      throw new Error('BROWSER_LAB_OWNER_EXIT_FAILED');
    }
  } catch (error) {
    if (error instanceof Error && error.message === 'BROWSER_LAB_OWNER_EXIT_UNCONFIRMED') {
      failureCode = error.message;
    } else if (error instanceof Error && error.message === 'BROWSER_LAB_OWNER_EXIT_FAILED') {
      failureCode = error.message;
    } else {
      cleanupConfirmed = false;
      // Chỉ giữ child-exit/frame enum; hết hạn chờ không có receipt vẫn dùng mã cleanup-unconfirmed ổn định.
      const safeProtocolFailure = error instanceof Error
        && /^(BROWSER_LAB_CHILD_EXIT_[0-9]+|BROWSER_LAB_PROTOCOL_FAILED|BROWSER_LAB_CLEANUP_FRAME_(BROWSER_LAB_READY|BROWSER_LAB_FAILED|BROWSER_LAB_UNAVAILABLE|UNEXPECTED))$/.test(error.message);
      failureCode = safeProtocolFailure ? error.message : 'BROWSER_LAB_CLEANUP_UNCONFIRMED';
    }
  } finally {
    if (!cleanupConfirmed) {
      state.cleanupUnconfirmed = true;
      // Nhả reader sẽ báo channel unavailable cho wrapper; owner tiếp tục tự cleanup, không bị kill.
      releaseLabChildHandles(child);
    }
    state.output?.close();
    if (state.credentials) state.credentials.password = '';
    state.credentials = undefined;
    state.child = undefined;
    state.output = undefined;
    state.ready = false;
  }
  if (failureCode) throw new Error(failureCode);
  if (!cleanupConfirmed) throw new Error('BROWSER_LAB_CLEANUP_UNCONFIRMED');
  if (!ownerExitConfirmed) throw new Error('BROWSER_LAB_OWNER_EXIT_UNCONFIRMED');
}

/** Nhả pipe và event-loop handle của đúng child đã được owner scope nhận diện.
 * Input
 * Param: child — wrapper process thuộc test này; không tra cứu hoặc dừng process theo PID.
 * Side effects: đóng stdio phía runner và unref child để lỗi cleanup không treo Playwright.
 */
function releaseLabChildHandles(child) {
  child.once('error', /** Nuốt late process error sau khi nhả owner, không đưa raw error vào reporter. */ () => {});
  try { child.stdin?.destroy(); } catch { /* Không để lỗi đóng input che trạng thái cleanup chưa xác nhận. */ }
  try { child.stdout?.destroy(); } catch { /* Đóng reader để owner nhận channel unavailable và tiếp tục cleanup. */ }
  try { child.unref(); } catch { /* Không để lỗi unref che trạng thái cleanup chưa xác nhận. */ }
}

/** Đợi terminal event trong grace hữu hạn, không coi timeout hoặc error là child đã thoát.
 * Input
 * Param: child — chính wrapper process do fixture runner tạo.
 * Param: timeoutMilliseconds — thời hạn nhỏ sau cleanup receipt trước khi dừng wrapper bị kẹt.
 * Output: true chỉ khi exitCode hoặc signalCode xác nhận terminal; ngược lại false.
 */
async function waitForLabChildExit(child, timeoutMilliseconds) {
  if (child.exitCode !== null || child.signalCode !== null) return true;
  const controller = new AbortController();
  const timeout = setTimeout(
    /** Deadline hết chỉ ngừng quan sát; caller mới quyết định xử lý owner đã được xác nhận cleanup. */
    () => controller.abort(),
    timeoutMilliseconds,
  );
  try {
    await once(child, 'exit', { signal: controller.signal });
    return true;
  } catch {
    return child.exitCode !== null || child.signalCode !== null;
  } finally {
    clearTimeout(timeout);
    controller.abort();
  }
}

/** Nhập credential qua Playwright nhưng không chuyển call log có giá trị bí mật ra test reporter.
 * Input
 * Param: locator — input đã chọn trong trang xác thực.
 * Param: secretValue — credential chỉ tồn tại trong bộ nhớ test.
 * Errors: luôn ném mã cố định nếu Playwright từ chối hoặc timeout khi nhập.
 * Side effects: điền credential vào ô đăng nhập mà không đưa giá trị vào test reporter.
 */
async function fillSecretSafely(locator, secretValue) {
  try {
    await locator.fill(secretValue);
  } catch {
    throw new Error('AUTH_CREDENTIAL_INPUT_FAILED');
  }
}

/** Gửi lại cookie phiên cũ mà không để lỗi request chứa header cookie lọt vào reporter.
 * Input
 * Param: requestContext — context API cô lập dùng kiểm tra cookie cũ sau logout.
 * Param: sessionCookie — bearer cookie chỉ lưu trong bộ nhớ của testcase.
 * Output: response HTTP để caller kiểm tra kết quả revoke.
 * Errors: luôn ném mã cố định nếu request thất bại.
 * Side effects: gửi GET `/api/v1/me` tới fixture với cookie cũ, không tạo mutation.
 */
async function requestWithStaleSessionSafely(requestContext, sessionCookie) {
  try {
    return await requestContext.get('/api/v1/me', {
      headers: { cookie: `iot_session=${sessionCookie}` },
    });
  } catch {
    throw new Error('STALE_SESSION_PROBE_FAILED');
  }
}

/** Gửi lại logout của đúng phiên đã revoke mà không để lỗi phản chiếu cookie hoặc CSRF tag.
 * Input
 * Param: requestContext — API context cô lập chỉ gọi fixture localhost.
 * Param: sessionCookie — cookie S1 được giữ trong RAM để kiểm idempotency.
 * Param: contextId — metadata ràng buộc CSRF vào chính phiên Web S1.
 * Param: csrfToken — tag mutation lấy từ response login S1, không ghi vào reporter.
 * Output: response HTTP để caller kiểm 204 không body.
 * Errors: luôn ném mã cố định nếu transport thất bại.
 * Side effects: gửi POST logout tới fixture bằng metadata của S1 để xác nhận retry idempotent.
 */
async function repeatLogoutSafely(requestContext, sessionCookie, contextId, csrfToken) {
  try {
    return await requestContext.post('/api/v1/auth/logout', {
      headers: {
        cookie: `iot_session=${sessionCookie}`,
        origin: 'http://localhost:5173',
        'x-auth-context-id': contextId,
        'x-csrf-token': csrfToken,
      },
    });
  } catch {
    throw new Error('REPEAT_LOGOUT_PROBE_FAILED');
  }
}

/** Dùng stale cookie thử một password mutation vô hại để chứng minh server chặn session đã revoke.
 * Input
 * Param: requestContext — API context cô lập chỉ gọi fixture localhost.
 * Param: sessionCookie — cookie S1 cũ được giữ trong RAM sau logout.
 * Param: contextId — metadata ràng buộc CSRF vào chính phiên Web S1.
 * Param: csrfToken — tag mutation lấy từ response login S1, không ghi vào reporter.
 * Output: response HTTP để caller kiểm mã SESSION_REVOKED.
 * Errors: luôn ném mã cố định nếu transport thất bại.
 * Side effects: gửi đổi password với current password tổng hợp sai; kể cả guard bị lỗi, mutation không thể đổi password.
 */
async function requestPasswordChangeWithStaleSessionSafely(requestContext, sessionCookie, contextId, csrfToken) {
  try {
    return await requestContext.post('/api/v1/auth/password', {
      headers: {
        cookie: `iot_session=${sessionCookie}`,
        origin: 'http://localhost:5173',
        'x-auth-context-id': contextId,
        'x-csrf-token': csrfToken,
      },
      data: {
        currentPassword: 'synthetic-incorrect-current-password',
        newPassword: 'Synthetic-Not-Current-Change-42',
      },
    });
  } catch {
    throw new Error('STALE_SESSION_MUTATION_PROBE_FAILED');
  }
}

/** Lấy workspace ID hiện hành qua session S1; không đưa context hoặc header vào error reporter.
 * Input
 * Param: page — trang cùng-origin đang đăng nhập bằng đúng session cần cấp ticket.
 * Param: contextId — metadata UUID của phiên; chỉ được gửi trong header request.
 * Output: UUID workspace đã trả bởi endpoint list hiện hành.
 * Errors: mã cố định nếu list không hợp lệ hoặc request thất bại.
 */
async function readRealtimeWorkspaceId(page, contextId) {
  let result;
  try {
    result = await page.evaluate(
      /** Chỉ trả workspace selector; không lấy token hay lưu response profile vào page state. */
      async ({ sessionContextId }) => {
        const response = await fetch('/api/v1/workspaces', {
          headers: { 'X-Auth-Context-Id': sessionContextId },
        });
        if (!response.ok) return { valid: false };
        const body = await response.json();
        const workspaceId = body.items?.[0]?.id;
        return typeof workspaceId === 'string'
          ? { valid: true, workspaceId }
          : { valid: false };
      },
      { sessionContextId: contextId },
    );
  } catch {
    throw new Error('REALTIME_WORKSPACE_LOOKUP_FAILED');
  }
  if (!result?.valid || typeof result.workspaceId !== 'string') {
    throw new Error('REALTIME_WORKSPACE_LOOKUP_FAILED');
  }
  return result.workspaceId;
}

/** Cấp ticket Web bằng cookie/context/CSRF thật nhưng che nội dung raw nếu có lỗi.
 * Input
 * Param: page — trang S1/S2 đang đăng nhập, browser tự gửi HttpOnly cookie.
 * Param: sessionContextId — UUID session hiện hành cho Web auth-context guard.
 * Param: csrfToken — token mutation trong RAM của testcase, không ghi log.
 * Param: workspaceId — scope selector đã đọc từ API của cùng session.
 * Output: ticket 64-hex và expiresAt chỉ giữ trong biến cục bộ để kiểm tra thời hạn tại lúc dùng.
 * Errors: mã cố định nếu response/status/schema/expiry không khớp contract.
 */
async function issueRealtimeTicketSafely(page, sessionContextId, csrfToken, workspaceId) {
  let result;
  try {
    result = await page.evaluate(
      /** POST bodyless; ticket chỉ được trả cho caller test và không đi vào URL hoặc persistent state. */
      async ({ authContextId, csrf, workspace }) => {
        const response = await fetch('/api/v1/realtime/tickets', {
          method: 'POST',
          headers: {
            'X-Auth-Context-Id': authContextId,
            'X-CSRF-Token': csrf,
            'X-Workspace-Id': workspace,
          },
        });
        if (response.status !== 201 || response.headers.get('cache-control') !== 'no-store') {
          return { valid: false };
        }
        let body;
        try {
          body = await response.json();
        } catch {
          return { valid: false };
        }
        return typeof body?.ticket === 'string'
          && /^[0-9a-f]{64}$/.test(body.ticket)
          && typeof body.expiresAt === 'string'
          && Date.parse(body.expiresAt) > Date.now()
          ? { valid: true, ticket: body.ticket, expiresAt: body.expiresAt }
          : { valid: false };
      },
      { authContextId: sessionContextId, csrf: csrfToken, workspace: workspaceId },
    );
  } catch {
    throw new Error('REALTIME_TICKET_REQUEST_FAILED');
  }
  if (!result?.valid || typeof result.ticket !== 'string') {
    throw new Error('REALTIME_TICKET_RESPONSE_INVALID');
  }
  return { ticket: result.ticket, expiresAt: result.expiresAt };
}

/** Mở WebSocket thật; có thể chờ ACK, kiểm ticket replay hoặc timeout frame đầu.
 * Input
 * Param: page — browser context sở hữu WebSocket và cùng Origin được Auth Lab cho phép.
 * Param: slot — tên tổng hợp dùng riêng để tham chiếu connection trong RAM của trang.
 * Param: ticket — capability raw chỉ truyền làm frame đầu; null giữ socket chờ timeout.
 * Output: kết quả allowlist gồm ACK/close, thời gian đóng socket thiếu frame và URL sạch.
 * Errors: mã cố định nếu transport/driver lỗi; reason do peer gửi chỉ được so sánh tại trang.
 */
async function openRealtimeSocketSafely(page, slot, ticket) {
  try {
    return await page.evaluate(
      /** Ticket không được đặt trong URL; delay100ms xác nhận server im lặng trước frame đầu. */
      async ({ socketSlot, firstFrameTicket }) => {
        const socketUrl = `ws://${window.location.hostname}:3000/api/v1/realtime`;
        const socket = new WebSocket(socketUrl);
        window.__tn002Sockets = window.__tn002Sockets ?? {};
        window.__tn002Sockets[socketSlot] = socket;
        let ticketSent = false;
        let preValidationFrames = 0;
        let missingFrameOpenedAt;
        const outcome = await new Promise(
          /** Gom mọi kết thúc vào một kết quả allowlist để không báo frame/input thô. */
          (resolve) => {
            let settled = false;
            let timer;
            /** Kết thúc một lần và dọn timer, không phản chiếu giá trị event vào console. */
            const finish = (result) => {
              if (settled) return;
              settled = true;
              window.clearTimeout(timer);
              resolve(result);
            };
            timer = window.setTimeout(
              /** Sáu giây chỉ là watchdog; assertion riêng bắt buộc close trong5s theo chính sách RT-2. */
              () => finish({ kind: 'timeout', preValidationFrames, ticketSent }),
              6_000,
            );
            /** Gửi đúng frame đầu sau khi socket mở; null cố ý kiểm timeout phía server. */
            socket.onopen = () => {
              if (firstFrameTicket === null) {
                // Đo từ khi handshake hoàn tất để so timeout server với ngưỡng RT-2 bằng đồng hồ monotonic.
                missingFrameOpenedAt = performance.now();
                return;
              }
              window.setTimeout(
                /** Delay ngắn xác nhận không có server frame trước khi gửi capability. */
                () => {
                  try {
                    ticketSent = true;
                    socket.send(firstFrameTicket);
                  } catch {
                    finish({ kind: 'send-failed', preValidationFrames, ticketSent });
                  }
                },
                100,
              );
            };
            /** Chỉ giữ số frame trước auth; sau auth chấp nhận đúng control ACK đã định nghĩa. */
            socket.onmessage = (event) => {
              if (!ticketSent) {
                preValidationFrames += 1;
                return;
              }
              finish({
                kind: event.data === 'AUTHENTICATED' ? 'authenticated' : 'unexpected-frame',
                preValidationFrames,
                ticketSent,
                readyState: socket.readyState,
                urlHasNoTicket: firstFrameTicket === null || !socket.url.includes(firstFrameTicket),
              });
            };
            /** Chỉ trả mã số protocol và boolean an toàn; reason do peer gửi không rời khỏi trang. */
            socket.onclose = (event) => finish({
              kind: 'closed',
              code: event.code === 1008 ? 'POLICY' : event.code === 1000 ? 'NORMAL' : 'OTHER',
              closeCode: event.code,
              authenticationRequired: event.reason === 'Authentication required.',
              wasClean: event.wasClean,
              preValidationFrames,
              ticketSent,
              urlHasNoTicket: firstFrameTicket === null || !socket.url.includes(firstFrameTicket),
              missingFrameCloseMilliseconds: missingFrameOpenedAt === undefined
                ? null
                : Math.ceil(performance.now() - missingFrameOpenedAt),
            });
            /** Browser error event lacks safe detail; the test receives only an enum-like value. */
            socket.onerror = () => finish({ kind: 'error', preValidationFrames, ticketSent });
          },
        );
        return outcome;
      },
      { socketSlot: slot, firstFrameTicket: ticket },
    );
  } catch {
    throw new Error('REALTIME_SOCKET_PROBE_FAILED');
  }
}

/**
 * Mở một WebSocket TCP thử nghiệm cố ý bỏ qua Ping để chứng minh peer im lặng giải phóng quota active.
 * Input
 * Param: ticket — capability tổng hợp chỉ gửi ở frame đầu, không ghi vào report.
 * Param: origin — origin local đã được Auth Lab cho phép cho handshake browser.
 * Output: Promise đóng socket có elapsedMs; caller kiểm tra timeout Ping/Pong và quota được thu hồi.
 * Errors: lỗi cố định nếu handshake hoặc xác thực thất bại, không chứa ticket hay header thô.
 * Side effects: mở TCP tới Auth Lab local và không phản hồi WebSocket control frame Ping.
 */
async function openUnresponsiveRealtimeSocketSafely(ticket, origin) {
  const connection = createConnection({ host: '127.0.0.1', port: 3000 });
  const handshakeKey = randomBytes(16).toString('base64');
  const expectedAccept = createHash('sha1')
    .update(`${handshakeKey}258EAFA5-E914-47DA-95CA-C5AB0DC85B11`)
    .digest('base64');
  const authenticatedFrame = Buffer.concat([
    Buffer.from([0x81, Buffer.byteLength('AUTHENTICATED')]),
    Buffer.from('AUTHENTICATED'),
  ]);
  let resolveAuthenticated;
  let rejectAuthenticated;
  const authenticated = new Promise(
    /** Chỉ cho phép lấp slot tiếp khi server đã ACK xác thực ticket dùng một lần. */
    (resolve, reject) => {
      resolveAuthenticated = resolve;
      rejectAuthenticated = reject;
    },
  );
  let resolveClosed;
  const closed = new Promise(
    /** Trả trạng thái kết thúc transport để test không đọc hoặc ghi lại frame thô. */
    (resolve) => {
      resolveClosed = resolve;
    },
  );
  let isAuthenticated = false;
  let authenticatedAt;
  let handshakeAccepted = false;
  let received = Buffer.alloc(0);
  const watchdog = setTimeout(
    /** Hạn chế fixture TCP bị treo nếu ping/Pong policy không đóng peer. */
    () => {
      connection.destroy();
      if (isAuthenticated) {
        resolveClosed({ kind: 'timeout' });
      } else {
        rejectAuthenticated(new Error('REALTIME_SILENT_SOCKET_AUTH_FAILED'));
      }
    },
    50_000,
  );

  /** Tạo frame text client đã mask theo RFC 6455, không đưa ticket vào URL/header. */
  const createMaskedTicketFrame = () => {
    const payload = Buffer.from(ticket, 'utf8');
    if (payload.length >= 126) throw new Error('REALTIME_SILENT_SOCKET_TICKET_INVALID');
    const mask = randomBytes(4);
    const maskedPayload = Buffer.alloc(payload.length);
    for (let index = 0; index < payload.length; index += 1) {
      maskedPayload[index] = payload[index] ^ mask[index % mask.length];
    }
    return Buffer.concat([Buffer.from([0x81, 0x80 | payload.length]), mask, maskedPayload]);
  };

  try {
    await once(connection, 'connect');
    connection.write(
      `GET /api/v1/realtime HTTP/1.1\r\n`
      + 'Host: 127.0.0.1:3000\r\n'
      + 'Upgrade: websocket\r\n'
      + 'Connection: Upgrade\r\n'
      + `Sec-WebSocket-Key: ${handshakeKey}\r\n`
      + 'Sec-WebSocket-Version: 13\r\n'
      + `Origin: ${origin}\r\n\r\n`,
    );

    /** Đọc TCP stream tới khi Auth Lab đóng half-open peer sau deadline Pong. */
    const readUntilClose = async () => {
      try {
        for await (const chunk of connection) {
          received = Buffer.concat([received, chunk]);
          if (!handshakeAccepted) {
            const headerEnd = received.indexOf('\r\n\r\n');
            if (headerEnd < 0) continue;
            const headerLines = received.subarray(0, headerEnd).toString('latin1').split('\r\n');
            const acceptHeader = headerLines.find(
              /** Chỉ lấy header xác nhận bắt tay, không đưa giá trị header ra ngoài test. */
              (line) => line.toLowerCase().startsWith('sec-websocket-accept:'),
            );
            if (!headerLines[0]?.startsWith('HTTP/1.1 101 ') || acceptHeader?.split(':')[1]?.trim() !== expectedAccept) {
              connection.destroy();
              rejectAuthenticated(new Error('REALTIME_SILENT_SOCKET_HANDSHAKE_FAILED'));
              return;
            }
            received = received.subarray(headerEnd + 4);
            handshakeAccepted = true;
            connection.write(createMaskedTicketFrame());
          }
          if (!isAuthenticated && received.includes(authenticatedFrame)) {
            isAuthenticated = true;
            authenticatedAt = Date.now();
            received = Buffer.alloc(0);
            resolveAuthenticated();
          } else if (isAuthenticated) {
            // Bỏ payload control sau ACK mà không gửi Pong để tái hiện peer im lặng.
            received = Buffer.alloc(0);
          }
        }
      } catch {
        if (!isAuthenticated) {
          rejectAuthenticated(new Error('REALTIME_SILENT_SOCKET_AUTH_FAILED'));
        }
      } finally {
        clearTimeout(watchdog);
        resolveClosed({
          kind: isAuthenticated ? 'closed' : 'unavailable',
          elapsedMs: authenticatedAt === undefined ? null : Date.now() - authenticatedAt,
        });
      }
    };
    void readUntilClose();
    await authenticated;
    return { closed };
  } catch {
    clearTimeout(watchdog);
    connection.destroy();
    throw new Error('REALTIME_SILENT_SOCKET_PROBE_FAILED');
  }
}

/** Chờ close của socket hiện hành để logout response và server connection close được đối soát riêng.
 * Input
 * Param: page — browser page đã giữ connection trong test-only RAM state.
 * Param: slot — tên connection tổng hợp được truyền lúc mở socket.
 * Output: mã protocol/cleanliness hoặc timeout; reason do peer gửi chỉ được so sánh tại trang.
 * Errors: mã cố định nếu page evaluation thất bại.
 */
async function waitForRealtimeCloseSafely(page, slot) {
  try {
    return await page.evaluate(
      /** Listener được gắn trước logout để không bỏ lỡ close frame đến sớm. */
      async (socketSlot) => {
        const socket = window.__tn002Sockets?.[socketSlot];
        if (!socket) return { kind: 'missing' };
        return new Promise(
          /** Chỉ chờ protocol close, không truy cập cookie/localStorage hoặc event payload. */
          (resolve) => {
            let timer;
            timer = window.setTimeout(
              /** Timeout là kết quả test, không đóng nhầm socket khác. */
              () => resolve({ kind: 'timeout' }),
              7_000,
            );
            /** Giữ mã protocol/cleanliness và bỏ reason do peer gửi để report không chứa text từ socket. */
            socket.addEventListener('close', (event) => {
              window.clearTimeout(timer);
              resolve({
                kind: 'closed',
                code: event.code === 1008 ? 'POLICY' : event.code === 1000 ? 'NORMAL' : 'OTHER',
                closeCode: event.code,
                authenticationRequired: event.reason === 'Authentication required.',
                wasClean: event.wasClean,
              });
            }, { once: true });
          },
        );
      },
      slot,
    );
  } catch {
    throw new Error('REALTIME_SOCKET_CLOSE_PROBE_FAILED');
  }
}

/** Kiểm tra socket sibling vẫn mở sau khi session khác trong cùng account bị logout.
 * Input
 * Param: page — page sở hữu socket đã xác thực.
 * Param: slot — tên connection tổng hợp trong page.
 * Output: true chỉ khi readyState là WebSocket.OPEN.
 */
async function isRealtimeSocketOpen(page, slot) {
  try {
    return await page.evaluate(
      /** Chỉ đọc trạng thái protocol của test socket; không đọc credential hoặc storage. */
      (socketSlot) => window.__tn002Sockets?.[socketSlot]?.readyState === WebSocket.OPEN,
      slot,
    );
  } catch {
    throw new Error('REALTIME_SOCKET_STATE_PROBE_FAILED');
  }
}

/**
 * Xác nhận response logout rỗng bằng kết quả boolean để assertion không in body bất ngờ.
 * Input
 * Param: response — response API của mutation logout.
 * Output: true chỉ khi status là204 và body không có byte.
 * Errors: false nếu body không đọc được hoặc response không đúng contract.
 */
async function isEmptyNoContentResponseSafely(response) {
  try {
    return response.status() === 204 && (await response.text()) === '';
  } catch {
    return false;
  }
}

/**
 * Đối soát stale-session response trong phạm vi allowlist, không đưa header/body thô vào test report.
 * Input
 * Param: response — response từ endpoint protected được gọi bằng session đã thu hồi.
 * Output: true chỉ khi status, media type và error code đều khớp contract `SESSION_REVOKED`.
 * Errors: false nếu body/header sai định dạng hoặc không thể đọc an toàn.
 */
async function isRevokedSessionResponseSafely(response) {
  try {
    if (response.status() !== 401) return false;
    const contentType = response.headers()['content-type'] ?? '';
    if (!/^application\/json(?:\s*;|$)/i.test(contentType)) return false;
    const body = await response.json();
    return body?.error?.code === 'SESSION_REVOKED';
  } catch {
    return false;
  }
}

test(
  'secret-bearing Playwright failures return fixed errors',
  /** Xác nhận lỗi từ thao tác có password/cookie chỉ trả mã cố định, không chứa sentinel bí mật. */
  async () => {
    const syntheticPassword = 'synthetic-password-redaction-sentinel';
    const syntheticCookie = 'synthetic-cookie-redaction-sentinel';
    const failingLocator = {
      /** Mô phỏng call log Playwright chứa password khi thao tác fill thất bại.
       * Input
       * Param: value — sentinel dùng kiểm chứng nhánh che dữ liệu.
       * Errors: luôn mô phỏng lỗi call log với giá trị đầu vào.
       */
      async fill(value) {
        throw new Error(`locator.fill("${value}") failed`);
      },
    };
    const failingRequestContext = {
      /** Mô phỏng call log request chứa cookie khi transport thất bại.
       * Input
       * Param: path — endpoint session probe tổng hợp.
       * Param: options — gồm header cookie sentinel.
       * Errors: luôn mô phỏng lỗi call log gồm header đầu vào.
       */
      async get(path, options) {
        throw new Error(`request ${path} ${options.headers.cookie} failed`);
      },
    };

    let passwordFailure;
    try {
      await fillSecretSafely(failingLocator, syntheticPassword);
    } catch (error) {
      passwordFailure = error;
    }
    expect(passwordFailure).toBeInstanceOf(Error);
    expect(passwordFailure.message).toBe('AUTH_CREDENTIAL_INPUT_FAILED');
    expect(passwordFailure.message).not.toContain(syntheticPassword);

    let cookieFailure;
    try {
      await requestWithStaleSessionSafely(failingRequestContext, syntheticCookie);
    } catch (error) {
      cookieFailure = error;
    }
    expect(cookieFailure).toBeInstanceOf(Error);
    expect(cookieFailure.message).toBe('STALE_SESSION_PROBE_FAILED');
    expect(cookieFailure.message).not.toContain(syntheticCookie);

    const failingLogoutRequestContext = {
      /** Mô phỏng call log logout có cả cookie và CSRF tag để kiểm tra che dữ liệu.
       * Input
       * Param: path — endpoint logout synthetic.
       * Param: options — chứa credential metadata chỉ dùng cho ca redaction.
       * Errors: luôn mô phỏng lỗi request gồm cookie và CSRF sentinel.
       */
      async post(path, options) {
        throw new Error(`request ${path} ${options.headers.cookie} ${options.headers['x-csrf-token']} failed`);
      },
    };
    let logoutFailure;
    try {
      await repeatLogoutSafely(failingLogoutRequestContext, syntheticCookie, 'synthetic-context', 'synthetic-csrf');
    } catch (error) {
      logoutFailure = error;
    }
    expect(logoutFailure).toBeInstanceOf(Error);
    expect(logoutFailure.message).toBe('REPEAT_LOGOUT_PROBE_FAILED');
    expect(logoutFailure.message).not.toContain(syntheticCookie);
    expect(logoutFailure.message).not.toContain('synthetic-csrf');

    const responseWithUntrustedDetails = {
      /** Trả status giả lập không hợp lệ để kiểm tra response helper chỉ xuất boolean. */
      status: () => 500,
      /** Header tổng hợp không hợp lệ chỉ dùng để xác nhận không bị đưa vào report. */
      headers: () => ({ 'content-type': syntheticCookie }),
      /** Body lỗi tổng hợp ném sentinel để helper phải bắt lỗi và trả false. */
      async text() { throw new Error(syntheticCookie); },
      /** JSON lỗi tổng hợp ném sentinel để helper phải bắt lỗi và trả false. */
      async json() { throw new Error(syntheticCookie); },
    };
    expect(await isEmptyNoContentResponseSafely(responseWithUntrustedDetails)).toBe(false);
    expect(await isRevokedSessionResponseSafely(responseWithUntrustedDetails)).toBe(false);

    const failingMutationRequestContext = {
      /** Mô phỏng call log password mutation có cookie, CSRF và password tổng hợp.
       * Input
       * Param: path — endpoint password tổng hợp.
       * Param: options — chứa cookie/CSRF/password chỉ dùng cho ca redaction.
       * Errors: luôn mô phỏng lỗi transport có phản chiếu credential metadata.
       */
      async post(path, options) {
        throw new Error(`request ${path} ${options.headers.cookie} ${options.headers['x-csrf-token']} ${options.data.currentPassword} ${options.data.newPassword} failed`);
      },
    };
    let mutationFailure;
    try {
      await requestPasswordChangeWithStaleSessionSafely(
        failingMutationRequestContext,
        syntheticCookie,
        'synthetic-context',
        'synthetic-csrf',
      );
    } catch (error) {
      mutationFailure = error;
    }
    expect(mutationFailure).toBeInstanceOf(Error);
    expect(mutationFailure.message).toBe('STALE_SESSION_MUTATION_PROBE_FAILED');
    expect(mutationFailure.message).not.toContain(syntheticCookie);
    expect(mutationFailure.message).not.toContain('synthetic-csrf');
    expect(mutationFailure.message).not.toContain('synthetic-incorrect-current-password');
    expect(mutationFailure.message).not.toContain('Synthetic-Not-Current-Change-42');
  },
);

test(
  'real login and idempotent logout preserve an independent browser session',
  /**
   * Chứng minh logout S1 đóng socket, thu hồi ticket chưa dùng và vẫn giữ session độc lập S2.
   * Input
   * Param: page — browser context S1 dùng cho đăng nhập, logout và kiểm tra cookie cũ.
   * Param: browser — factory tạo context S2 riêng để xác nhận phiên không bị revoke nhầm.
   * Side effects
   * Tạo fixture PostgreSQL tổng hợp, đăng nhập hai phiên, revoke S1 rồi cleanup fixture.
   */
  async ({ page, browser }) => {
    test.setTimeout(LAB_E2E_TIMEOUT_MS);
    let siblingContext;
    try {
      await startLabFixture();
      await page.goto('/login');
      await page.getByRole('textbox', { name: 'Email' }).fill(fixtureState.credentials.emails[0]);
      await fillSecretSafely(page.getByRole('textbox', { name: 'Mật khẩu' }), fixtureState.credentials.password);
      const loginResponsePromise = page.waitForResponse(
        /** Chỉ nhận login POST của S1 để giữ context/CSRF metadata trong RAM cho retry logout.
         * Input
         * Param: response — response HTTP được lọc theo method và route của login S1.
         * Output: true nếu response thuộc POST login S1 cần chờ.
         */
        (response) => response.request().method() === 'POST'
          && new URL(response.url()).pathname === '/api/v1/auth/login',
      );
      await page.getByRole('button', { name: 'Đăng nhập', exact: true }).click();
      const loginResponse = await loginResponsePromise;
      expect(loginResponse.status()).toBe(200);
      const loginHeaders = loginResponse.headers();
      const sessionContextId = loginHeaders['x-auth-context-id'] ?? '';
      const csrfToken = loginHeaders['x-csrf-token'] ?? '';
      if (!sessionContextId || !csrfToken) throw new Error('BROWSER_SESSION_METADATA_MISSING');
      await expect(page.getByRole('heading', { name: 'Chọn workspace' })).toBeVisible();

      const workspaceChoice = page.getByRole('button', { name: /^Chọn workspace / }).first();
      await expect(workspaceChoice).toBeVisible();
      await workspaceChoice.click();
      await expect(page.getByRole('status').filter({ hasText: 'Đã xác minh quyền' })).toBeVisible();

      siblingContext = await browser.newContext();
      const siblingPage = await siblingContext.newPage();
      await siblingPage.goto('http://localhost:5173/login');
      await siblingPage.getByRole('textbox', { name: 'Email' }).fill(fixtureState.credentials.emails[0]);
      await fillSecretSafely(siblingPage.getByRole('textbox', { name: 'Mật khẩu' }), fixtureState.credentials.password);
      const siblingLoginResponsePromise = siblingPage.waitForResponse(
        /** Chỉ nhận login POST của context độc lập S2, không giữ body hoặc session credential.
         * Input
         * Param: response — response HTTP được lọc theo method và route của login S2.
         * Output: true nếu response thuộc POST login S2 cần chờ.
         */
        (response) => response.request().method() === 'POST'
          && new URL(response.url()).pathname === '/api/v1/auth/login',
      );
      await siblingPage.getByRole('button', { name: 'Đăng nhập', exact: true }).click();
      const siblingLoginResponse = await siblingLoginResponsePromise;
      expect(siblingLoginResponse.status()).toBe(200);
      const siblingLoginHeaders = siblingLoginResponse.headers();
      const siblingSessionContextId = siblingLoginHeaders['x-auth-context-id'] ?? '';
      const siblingCsrfToken = siblingLoginHeaders['x-csrf-token'] ?? '';
      if (!siblingSessionContextId || !siblingCsrfToken) {
        throw new Error('BROWSER_SIBLING_SESSION_METADATA_MISSING');
      }
      await expect(siblingPage.getByRole('heading', { name: 'Chọn workspace' })).toBeVisible();
      await siblingPage.getByRole('button', { name: /^Chọn workspace / }).first().click();
      await expect(siblingPage.getByRole('status').filter({ hasText: 'Đã xác minh quyền' })).toBeVisible();

      const firstMeAfterSiblingLoginPromise = page.waitForResponse(
        /** Xác nhận S1 vẫn hợp lệ sau khi S2 login để retry logout không che lỗi revoke sớm.
         * Input
         * Param: response — GET `/me` của S1 dùng làm oracle trước logout.
         * Output: true nếu response thuộc GET `/me` của S1 cần chờ.
         */
        (response) => response.request().method() === 'GET'
          && new URL(response.url()).pathname === '/api/v1/me',
      );
      await page.reload();
      expect((await firstMeAfterSiblingLoginPromise).status()).toBe(200);

      let oldSessionCookie = '';
      // URL scope phải khớp Path=/api/v1 để Playwright trả về HttpOnly session cookie.
      for (const cookie of await page.context().cookies('http://localhost:5173/api/v1/me')) {
        if (cookie.name === 'iot_session' && cookie.httpOnly) oldSessionCookie = cookie.value;
      }
      if (!oldSessionCookie) throw new Error('BROWSER_SESSION_COOKIE_MISSING');

      const siblingMeBeforeLogoutPromise = siblingPage.waitForResponse(
        /** Giữ response oracle GET /me của S2 để chứng minh phiên thứ hai còn hợp lệ trước logout S1.
         * Input
         * Param: response — GET `/me` của S2 dùng làm oracle trước logout.
         * Output: true nếu response thuộc GET `/me` của S2 cần chờ.
         */
        (response) => response.request().method() === 'GET'
          && new URL(response.url()).pathname === '/api/v1/me',
      );
      await siblingPage.reload();
      expect((await siblingMeBeforeLogoutPromise).status()).toBe(200);

      const firstWorkspaceId = await readRealtimeWorkspaceId(page, sessionContextId);
      const siblingWorkspaceId = await readRealtimeWorkspaceId(siblingPage, siblingSessionContextId);
      const firstTicket = await issueRealtimeTicketSafely(
        page,
        sessionContextId,
        csrfToken,
        firstWorkspaceId,
      );
      const siblingTicket = await issueRealtimeTicketSafely(
        siblingPage,
        siblingSessionContextId,
        siblingCsrfToken,
        siblingWorkspaceId,
      );
      const firstSocket = await openRealtimeSocketSafely(page, 's1', firstTicket.ticket);
      if (firstSocket.kind !== 'authenticated') {
        const closeCode = firstSocket.code ?? 'OTHER';
        const closeReason = firstSocket.authenticationRequired ? 'AUTH_POLICY' : 'OTHER';
        const sent = firstSocket.ticketSent ? 'SENT' : 'NOT_SENT';
        throw new Error('REALTIME_FIRST_SOCKET_' + firstSocket.kind + '_CODE_' + closeCode + '_REASON_' + closeReason + '_' + sent);
      }
      expect(Object.hasOwn(firstSocket, 'reason')).toBe(false);
      expect(firstSocket).toMatchObject({
        kind: 'authenticated',
        preValidationFrames: 0,
        urlHasNoTicket: true,
      });
      const siblingSocket = await openRealtimeSocketSafely(siblingPage, 's2', siblingTicket.ticket);
      expect(Object.hasOwn(siblingSocket, 'reason')).toBe(false);
      expect(siblingSocket).toMatchObject({
        kind: 'authenticated',
        preValidationFrames: 0,
        urlHasNoTicket: true,
      });

      const replayedTicketSocket = await openRealtimeSocketSafely(page, 'replay', firstTicket.ticket);
      expect(Object.hasOwn(replayedTicketSocket, 'reason')).toBe(false);
      expect(replayedTicketSocket.kind).toBe('closed');
      expect(replayedTicketSocket.code).toBe('POLICY');
      expect(replayedTicketSocket.authenticationRequired).toBe(true);
      expect(replayedTicketSocket.wasClean).toBe(true);
      expect(replayedTicketSocket.preValidationFrames).toBe(0);
      expect(replayedTicketSocket.ticketSent).toBe(true);
      expect(replayedTicketSocket.urlHasNoTicket).toBe(true);

      const missingTicketSocket = await openRealtimeSocketSafely(page, 'missing-ticket', null);
      expect(Object.hasOwn(missingTicketSocket, 'reason')).toBe(false);
      expect(missingTicketSocket.kind).toBe('closed');
      expect(missingTicketSocket.code).toBe('POLICY');
      expect(missingTicketSocket.authenticationRequired).toBe(true);
      expect(missingTicketSocket.wasClean).toBe(true);
      expect(missingTicketSocket.preValidationFrames).toBe(0);
      expect(missingTicketSocket.missingFrameCloseMilliseconds).toBeLessThanOrEqual(5_000);

      // Cùng backend instance giới hạn tổng 16 socket; tuần tự ACK để không tranh quota DB handshake.
      const maxActiveRealtimeSockets = 16;
      const capacitySocketSlots = [];
      for (let index = 0; index < maxActiveRealtimeSockets - 3; index += 1) {
        const slot = `capacity-${index}`;
        const ticket = await issueRealtimeTicketSafely(
          page,
          sessionContextId,
          csrfToken,
          firstWorkspaceId,
        );
        const socket = await openRealtimeSocketSafely(page, slot, ticket.ticket);
        expect(Object.hasOwn(socket, 'reason')).toBe(false);
        expect(socket).toMatchObject({
          kind: 'authenticated',
          preValidationFrames: 0,
          ticketSent: true,
          urlHasNoTicket: true,
        });
        capacitySocketSlots.push(slot);
      }

      const silentPeerTicket = await issueRealtimeTicketSafely(
        page,
        sessionContextId,
        csrfToken,
        firstWorkspaceId,
      );
      const silentPeer = await openUnresponsiveRealtimeSocketSafely(
        silentPeerTicket.ticket,
        new URL(page.url()).origin,
      );

      const saturationTicket = await issueRealtimeTicketSafely(
        page,
        sessionContextId,
        csrfToken,
        firstWorkspaceId,
      );
      const saturatedSocket = await openRealtimeSocketSafely(
        page,
        'capacity-overflow',
        saturationTicket.ticket,
      );
      expect(Object.hasOwn(saturatedSocket, 'reason')).toBe(false);
      expect(saturatedSocket).toMatchObject({ kind: 'error', ticketSent: false });
      const saturationProbe = await request.newContext({ baseURL: 'http://localhost:3000' });
      let saturationResponse;
      try {
        // HTTP Upgrade giả lập chỉ đo status/header tại đúng route; JS WebSocket phía trên vẫn là luồng thật.
        saturationResponse = await saturationProbe.get('/api/v1/realtime', {
          headers: {
            Origin: 'http://localhost:5173',
            Connection: 'Upgrade',
            Upgrade: 'websocket',
            'Sec-WebSocket-Key': randomBytes(16).toString('base64'),
            'Sec-WebSocket-Version': '13',
          },
          timeout: 5_000,
        });
      } finally {
        await saturationProbe.dispose();
      }
      expect(saturationResponse.status()).toBe(503);
      expect(saturationResponse.headers()['cache-control']).toBe('no-store');

      const releasedCapacitySlot = capacitySocketSlots.shift();
      const releasedCapacityClosePromise = waitForRealtimeCloseSafely(page, releasedCapacitySlot);
      await page.evaluate(
        /** Đóng một socket bằng mã 1000 để xác minh server hoàn tất close handshake và trả quota. */
        (slot) => window.__tn002Sockets?.[slot]?.close(1000),
        releasedCapacitySlot,
      );
      expect(await releasedCapacityClosePromise).toMatchObject({
        kind: 'closed',
        code: 'NORMAL',
        wasClean: true,
      });

      let recoveredCapacitySocket;
      for (let attempt = 0; attempt < 20; attempt += 1) {
        recoveredCapacitySocket = await openRealtimeSocketSafely(
          page,
          'capacity-ticket-retry',
          saturationTicket.ticket,
        );
        if (recoveredCapacitySocket.kind === 'authenticated') break;
        await page.waitForTimeout(50);
      }
      expect(Object.hasOwn(recoveredCapacitySocket, 'reason')).toBe(false);
      expect(recoveredCapacitySocket).toMatchObject({
        kind: 'authenticated',
        preValidationFrames: 0,
        ticketSent: true,
        urlHasNoTicket: true,
      });
      capacitySocketSlots.push('capacity-ticket-retry');

      const silentPeerClose = await silentPeer.closed;
      expect(silentPeerClose).toMatchObject({ kind: 'closed' });
      expect(silentPeerClose.elapsedMs).toBeGreaterThanOrEqual(38_000);
      expect(silentPeerClose.elapsedMs).toBeLessThanOrEqual(45_000);
      const chromePeersAnsweredHeartbeat = await page.evaluate(
        /** Chỉ đối soát readyState của browser socket; WebSocket API tự xử lý control Pong. */
        (slots) => slots.every(
          /** Xác nhận từng socket Chrome vẫn được xác thực sau một chu kỳ Ping/Pong. */
          (slot) => window.__tn002Sockets?.[slot]?.readyState === WebSocket.OPEN,
        ),
        capacitySocketSlots,
      );
      expect(chromePeersAnsweredHeartbeat).toBe(true);

      const reclaimedLivenessTicket = await issueRealtimeTicketSafely(
        page,
        sessionContextId,
        csrfToken,
        firstWorkspaceId,
      );
      const reclaimedLivenessSocket = await openRealtimeSocketSafely(
        page,
        'heartbeat-capacity-reclaimed',
        reclaimedLivenessTicket.ticket,
      );
      expect(reclaimedLivenessSocket).toMatchObject({
        kind: 'authenticated',
        preValidationFrames: 0,
        ticketSent: true,
        urlHasNoTicket: true,
      });
      capacitySocketSlots.push('heartbeat-capacity-reclaimed');

      const capacitySocketClosePromises = capacitySocketSlots.map(
        /** Gắn listener riêng cho từng socket trước khi phát close từ trang. */
        (slot) => waitForRealtimeCloseSafely(page, slot),
      );
      await page.evaluate(
        /** Dọn toàn bộ socket phụ trước các assertion logout S1/S2 còn lại của scenario. */
        (slots) => slots.forEach(
          /** Đóng đúng slot synthetic bằng mã 1000 để server trả lại quota sau handshake sạch. */
          (slot) => window.__tn002Sockets?.[slot]?.close(1000),
        ),
        capacitySocketSlots,
      );
      const capacitySocketCloses = await Promise.all(capacitySocketClosePromises);
      expect(capacitySocketCloses.every(
        /** Chỉ chấp nhận socket phụ đã hoàn tất close handshake bình thường. */
        (close) => close.kind === 'closed' && close.code === 'NORMAL' && close.wasClean,
      )).toBe(true);

      const firstSocketClosedPromise = waitForRealtimeCloseSafely(page, 's1');
      const logoutResponsePromise = page.waitForResponse(
        /** Chỉ nhận mutation logout đúng route; mọi body/token đều nằm ngoài assertion và report.
         * Input
         * Param: response — response HTTP được lọc theo method và route logout của S1.
         * Output: true nếu response thuộc POST logout S1 cần chờ.
         */
        (response) => response.request().method() === 'POST'
          && new URL(response.url()).pathname === '/api/v1/auth/logout',
      );
      const unusedFirstSessionTicket = await issueRealtimeTicketSafely(
        page,
        sessionContextId,
        csrfToken,
        firstWorkspaceId,
      );
      const unusedFirstSessionTicketExpiresAt = Date.parse(unusedFirstSessionTicket.expiresAt);
      expect(unusedFirstSessionTicketExpiresAt).toBeGreaterThan(Date.now() + 1_000);
      await page.getByRole('button', { name: 'Đăng xuất', exact: true }).click();
      const logoutResponse = await logoutResponsePromise;
      expect(await isEmptyNoContentResponseSafely(logoutResponse)).toBe(true);
      const cookiesAfterLogout = await page.context().cookies('http://localhost:5173/api/v1/me');
      let sessionCookieRemains = false;
      for (const cookie of cookiesAfterLogout) {
        if (cookie.name === 'iot_session') sessionCookieRemains = true;
      }
      expect(sessionCookieRemains).toBe(false);
      await expect(page.getByRole('textbox', { name: 'Email' })).toBeVisible();
      const firstSocketClose = await firstSocketClosedPromise;
      expect(Object.hasOwn(firstSocketClose, 'reason')).toBe(false);
      expect(firstSocketClose.kind).toBe('closed');
      expect(firstSocketClose.code).toBe('POLICY');
      expect(firstSocketClose.authenticationRequired).toBe(true);
      expect(firstSocketClose.wasClean).toBe(true);
      expect(unusedFirstSessionTicketExpiresAt).toBeGreaterThan(Date.now() + 1_000);
      const revokedUnusedTicketSocket = await openRealtimeSocketSafely(
        page,
        'revoked-unused-ticket',
        unusedFirstSessionTicket.ticket,
      );
      expect(unusedFirstSessionTicketExpiresAt).toBeGreaterThan(Date.now());
      expect(Object.hasOwn(revokedUnusedTicketSocket, 'reason')).toBe(false);
      expect(revokedUnusedTicketSocket).toMatchObject({
        kind: 'closed',
        code: 'POLICY',
        authenticationRequired: true,
        wasClean: true,
        preValidationFrames: 0,
        ticketSent: true,
        urlHasNoTicket: true,
      });
      expect(await isRealtimeSocketOpen(siblingPage, 's2')).toBe(true);

      const siblingMeAfterLogoutPromise = siblingPage.waitForResponse(
        /** Đọc lại S2 sau commit S1 để phát hiện revoke nhầm session cùng account.
         * Input
         * Param: response — GET `/me` của S2 sau logout S1.
         * Output: true nếu response thuộc GET `/me` của S2 sau logout S1.
         */
        (response) => response.request().method() === 'GET'
          && new URL(response.url()).pathname === '/api/v1/me',
      );
      await siblingPage.reload();
      expect((await siblingMeAfterLogoutPromise).status()).toBe(200);

      // Gửi lại đúng cookie đã thu hồi qua context sạch; cookie jar đã xóa cookie này sau 204.
      const staleSessionRequest = await request.newContext({ baseURL: 'http://localhost:5173' });
      try {
        const oldSessionResponse = await requestWithStaleSessionSafely(staleSessionRequest, oldSessionCookie);
        expect(await isRevokedSessionResponseSafely(oldSessionResponse)).toBe(true);

        const oldSessionMutationResponse = await requestPasswordChangeWithStaleSessionSafely(
          staleSessionRequest,
          oldSessionCookie,
          sessionContextId,
          csrfToken,
        );
        expect(await isRevokedSessionResponseSafely(oldSessionMutationResponse)).toBe(true);

        const repeatLogoutResponse = await repeatLogoutSafely(
          staleSessionRequest,
          oldSessionCookie,
          sessionContextId,
          csrfToken,
        );
        expect(await isEmptyNoContentResponseSafely(repeatLogoutResponse)).toBe(true);

        const siblingMeAfterRepeatPromise = siblingPage.waitForResponse(
          /** Kiểm S2 sau retry idempotent để xác nhận lần logout lặp vẫn chỉ tác động S1.
           * Input
           * Param: response — GET `/me` của S2 sau lần logout lặp.
           * Output: true nếu response thuộc GET `/me` của S2 sau lần logout lặp.
           */
          (response) => response.request().method() === 'GET'
            && new URL(response.url()).pathname === '/api/v1/me',
        );
        await siblingPage.reload();
        expect((await siblingMeAfterRepeatPromise).status()).toBe(200);
      } finally {
        await staleSessionRequest.dispose();
        oldSessionCookie = '';
      }
    } finally {
      try {
        if (siblingContext) await siblingContext.close();
      } finally {
        await stopLabFixture();
      }
    }
  },
);

test(
  'uncertain login recovery renders at narrow width and reconciles with a session GET',
  /**
   * Kiểm tra trạng thái phục hồi ở viewport hẹp sau 503 mô phỏng và thao tác đối soát chỉ gửi GET phiên.
   * Input
   * Param: page — trang trình duyệt Playwright cô lập của ca kiểm thử.
   * Side effects
   * Chặn route đăng nhập cục bộ trong trang test, điều hướng tới `/login` và gửi một lần form thử nghiệm.
   */
  async ({ page }) => {
    let loginPostCount = 0;
    let sessionGetCount = 0;
    const authRequestSequence = [];
    const email = `probe-${randomBytes(8).toString('hex')}@example.invalid`;
    const password = `Aa1${randomBytes(16).toString('hex')}`;
    const viewportWidth = 320;
    // Mục16.1 yêu cầu card auth không tạo cuộn ngang ở viewport nhỏ nhất 320px.
    await page.setViewportSize({ width: viewportWidth, height: 800 });
    await page.route('**/api/v1/auth/login',
      /**
       * Mô phỏng upstream 503 text/plain để kiểm lỗi UNKNOWN mà không tạo server session.
       * Input
       * Param: route — request route đăng nhập bị chặn tại trình duyệt.
       * Side effects
       * Tăng bộ đếm `loginPostCount` và hoàn tất request bằng phản hồi 503 giả lập.
       */
      async (route) => {
        if (route.request().method() !== 'POST') {
          await route.continue();
          return;
        }
        loginPostCount += 1;
        authRequestSequence.push('POST /api/v1/auth/login');
        await route.fulfill({ status: 503, contentType: 'text/plain', body: 'upstream unavailable' });
      },
    );
    await page.route('**/api/v1/me',
      /** Mô phỏng 401 hợp lệ cho readiness và discovery; không cấp profile hoặc workspace giả.
       * Input
       * Param: route — request mà route handler kiểm method trước khi ghi nhận và phản hồi.
       * Side effects
       * Ghi method GET vào sequence và trả contract 401 tổng hợp.
       */
      async (route) => {
        if (route.request().method() !== 'GET') {
          await route.continue();
          return;
        }
        sessionGetCount += 1;
        authRequestSequence.push('GET /api/v1/me');
        await route.fulfill({
          status: 401,
          contentType: 'application/json',
          body: JSON.stringify({
            error: {
              code: 'SESSION_EXPIRED',
              message: 'Phiên đăng nhập không còn hiệu lực.',
              details: {},
              correlationId: 'corr_ui_reconcile',
            },
          }),
        });
      },
    );
    await page.goto('/login');
    await expect(page.locator('.auth-showcase')).toHaveCount(0);
    await expect(page.getByRole('complementary', { name: 'Giới thiệu Nexa IoT' })).toHaveCount(0);
    await page.getByRole('textbox', { name: 'Email' }).fill(email);
    await fillSecretSafely(page.getByRole('textbox', { name: 'Mật khẩu' }), password);
    await page.getByRole('button', { name: 'Đăng nhập', exact: true }).click();
    await expect(page.getByRole('alert')).toContainText(
      'Dịch vụ đang gián đoạn. Chưa thể xác nhận kết quả. Hãy đối soát phiên trước khi thử lại.',
    );
    await expect(page.getByText('Chưa xác nhận trạng thái phiên. Nội dung workspace đang được khóa.')).toBeVisible();
    await expect(page.getByRole('button', { name: 'Đối soát phiên hiện tại' })).toBeVisible();
    await expect(page.getByRole('button', { name: 'Đối soát phiên hiện tại' })).toBeEnabled();
    await expect(page.getByRole('button', { name: 'Đăng nhập lại' })).toBeVisible();
    expect(sessionGetCount).toBe(1);
    expect(authRequestSequence).toEqual([
      'GET /api/v1/me',
      'POST /api/v1/auth/login',
    ]);
    /**
     * Đọc chiều rộng tài liệu sau khi co viewport để bắt trạng thái tràn ngang.
     * Output
     * Trả về chiều rộng layout của document theo CSS pixel.
     */
    const documentWidth = await page.evaluate(
      /** Đọc chiều rộng layout của document theo CSS pixel để phát hiện cuộn ngang. */
      () => document.documentElement.scrollWidth,
    );
    expect(documentWidth).toBe(viewportWidth);
    const viewportBoundedElements = [
      page.locator('.auth-card'),
      page.getByRole('alert'),
      page.getByText('Chưa xác nhận trạng thái phiên. Nội dung workspace đang được khóa.'),
      page.getByRole('button', { name: 'Đối soát phiên hiện tại' }),
      page.getByRole('button', { name: 'Đăng nhập lại' }),
    ];
    // overflow-x: clip có thể giữ scrollWidth bằng viewport dù một phần tử con bị cắt, nên kiểm tra bounds thật.
    for (const element of viewportBoundedElements) {
      const bounds = await element.boundingBox();
      expect(bounds).not.toBeNull();
      expect(bounds?.x).toBeGreaterThanOrEqual(0);
      expect((bounds?.x ?? Number.POSITIVE_INFINITY) + (bounds?.width ?? 0)).toBeLessThanOrEqual(viewportWidth);
    }
    await expect(page.locator('.auth-showcase')).toHaveCount(0);
    const reconciliationResponsePromise = page.waitForResponse(
      /** Chờ response GET do người dùng chủ động đối soát, không đọc body hoặc cookie.
       * Input
       * Param: response — phản hồi được lọc theo method/path của endpoint discovery.
       * Output
       * True nếu đây là response GET `/api/v1/me` cần chờ.
       */
      (response) => response.request().method() === 'GET'
        && new URL(response.url()).pathname === '/api/v1/me',
    );
    await page.getByRole('button', { name: 'Đối soát phiên hiện tại' }).click();
    const reconciliationResponse = await reconciliationResponsePromise;
    expect(reconciliationResponse.status()).toBe(401);
    await expect(page.getByRole('alert')).toContainText('Phiên đã hết hạn hoặc bị thu hồi. Vui lòng đăng nhập lại.');
    await expect(page.getByText('Chưa xác nhận trạng thái phiên. Nội dung workspace đang được khóa.')).toBeVisible();
    await expect(page.getByRole('button', { name: 'Đăng nhập lại' })).toBeVisible();
    expect(sessionGetCount).toBe(2);
    expect(loginPostCount).toBe(1);
    expect(authRequestSequence).toEqual([
      'GET /api/v1/me',
      'POST /api/v1/auth/login',
      'GET /api/v1/me',
    ]);
  },
);

test(
  'fixture cleanup timeout stays bounded and never claims an unconfirmed cleanup',
  /** Bảo vệ runner khỏi chờ vô hạn và không kết luận cleanup thành công khi owner chưa gửi receipt.
   * Side effects
   * Mô phỏng owner child không gửi frame, rồi xác nhận controller chỉ nhả handle thuộc child đó.
   */
  async () => {
    const child = new EventEmitter();
    const input = new PassThrough();
    const output = new PassThrough();
    const state = {
      child,
      output: createInterface({ input: output }),
      credentials: { password: 'synthetic-cleanup-password' },
      ready: true,
      cleanupUnconfirmed: false,
    };
    child.exitCode = null;
    child.signalCode = null;
    child.stdin = input;
    child.stdout = output;
    child.killCalled = false;
    child.unrefCalled = false;
    child.kill = /** Ghi nhận kill để test cấm dừng owner khi chưa có receipt cleanup. */
      () => { child.killCalled = true; return true; };
    child.unref = /** Ghi nhận việc nhả handle để runner không bị treo bởi owner chưa xác nhận. */
      () => { child.unrefCalled = true; };

    await expect(stopLabFixture(state, {
      cleanupTimeoutMilliseconds: 5,
      childExitTimeoutMilliseconds: 5,
    })).rejects.toThrow('BROWSER_LAB_CLEANUP_UNCONFIRMED');
    expect(state.cleanupUnconfirmed).toBe(true);
    expect(state.credentials).toBeUndefined();
    expect(child.killCalled).toBe(false);
    expect(child.unrefCalled).toBe(true);
    expect(output.destroyed).toBe(true);

    const earlyChild = new EventEmitter();
    const earlyOutput = new PassThrough();
    const earlyState = {
      child: earlyChild,
      output: createInterface({ input: earlyOutput }),
      credentials: { password: 'synthetic-early-exit-password' },
      ready: false,
      cleanupUnconfirmed: false,
    };
    earlyChild.exitCode = 1;
    earlyChild.signalCode = null;
    earlyChild.stdin = new PassThrough();
    earlyChild.stdout = earlyOutput;

    await expect(stopLabFixture(earlyState, {
      cleanupTimeoutMilliseconds: 5,
      childExitTimeoutMilliseconds: 5,
    })).rejects.toThrow('BROWSER_LAB_CLEANUP_UNCONFIRMED');
    expect(earlyState.cleanupUnconfirmed).toBe(true);
    expect(earlyState.credentials).toBeUndefined();
  },
);
