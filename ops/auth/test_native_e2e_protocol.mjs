import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { EventEmitter } from 'node:events';
import { createBrowserSecretCanaryState, disposeBrowserSecretCanary,
  finishBrowserSecretRegistration, observeBrowserSink, registerBrowserSecret } from '../../web/e2e/browser_secret_canary.mjs';
import { parseDaemonLine, validateOwnedApp, normalizeExtensionResult, canSendDaemonRequest, canHandleNativeCheckpoint, validateNativePreselectionOracle, isConfirmedSpawnFailure, shutdownNativeDaemon, validateSessionDelta, validateCrossClientSessionDelta, validateAndroidLogoutPreservesWebSibling, validateRawBodyless204Response, validateAccessSessionDelta, validateAccountSwitchSessionDelta, createAccessCheckpointOracle, createPasswordCheckpointOracle, validatePasswordSessionDelta, nativePhaseBudget, nativeS2RealtimeTicketArguments, safeNativeFailureCategory, requireWorkBudget, containsNativeSecret, validateFixtureCleanup, armNativeFixture, validateFixtureArmFrame, closeNativeFixture, startFixture } from './run_native_e2e.mjs';

let protocolStage = 'setup';

/**
 * Tạo owned lifecycle giả để kiểm STOP/EOF, terminal và readback mà không spawn DB hoặc SDK.
 * Input
 * Param: counts — projection public8count để dùng trong STOPPED giả sau terminal do test điều khiển.
 * Output: owner dùng trực tiếp bởi close helper, state và callbacks kiểm chứng completion.
 */
function fakeFixtureLifecycle(counts) {
  const state = { terminal: false, failed: false, exitCode: undefined, stopped: undefined };
  const commands = []; const destroyed = []; let finishExit;
  const exit = new Promise(/** Giữ exit pending thật tới khi test phát terminal, không coi observer timeout là exit. */
    (resolve) => { finishExit = resolve; });
  const owner = { child: { pid: 4242,
    stdin: { end: /** Ghi literal STOP để kiểm intent đúng một lần. */ (value) => { commands.push(value); },
      destroy: /** Ghi EOF/pipe release của đúng owned input. */ () => { destroyed.push('stdin'); } },
    stdout: { destroy: /** Ghi release output sau terminal. */ () => { destroyed.push('stdout'); } },
    stderr: { destroy: /** Ghi release error pipe sau terminal. */ () => { destroyed.push('stderr'); } },
  }, exit,
  getState: /** Trả lifecycle fake authoritative do test giữ, không tự gán terminal từ timeout. */ () => state,
  observeExit: /** Chỉ hoàn tất observer sau đúng exit promise và kiểm cleanup budget hiện hữu18phút. */ async (pending, milliseconds) => {
    assert.equal(pending, exit); assert.equal(milliseconds, 18 * 60_000);
    await pending; return { settled: true };
  } };
  return { owner, state, commands, destroyed,
    finish: /** Phát terminal và tùy chọn readback/exitcode để kiểm negative cleanup evidence. */
      (stopped = { kind: 'STOPPED', cleanup: counts }, exitCode = 0) => {
        state.terminal = true; state.exitCode = exitCode; state.stopped = stopped; finishExit(exitCode);
      },
  };
}

/** Kiểm daemon/session/request counters bằng input synthetic, kể cả logout độc lập OTHER; không mở SDK/DB. */
async function main() {
  const webUiHarnessSource = readFileSync(new URL('../../web/e2e/native_cross_client_ui.mjs', import.meta.url), 'utf8');
  const socketAssignment = /window\.(\w+)\s*=\s*socket\b/.exec(webUiHarnessSource);
  const logoutHandlerStart = webUiHarnessSource.indexOf('async function verifyUiLogout');
  const socketCloseHandlerStart = webUiHarnessSource.indexOf('async function verifyWebSessionSocketClosed');
  assert.ok(socketAssignment && logoutHandlerStart >= 0 && socketCloseHandlerStart > logoutHandlerStart,
    'NATIVE_WEB_UI_SOCKET_SOURCE_SHAPE_INVALID');
  const logoutHandlerSource = webUiHarnessSource.slice(logoutHandlerStart, socketCloseHandlerStart);
  const socketRead = /const socket = window\.(\w+)/.exec(logoutHandlerSource);
  // Writer và logout guard phải dùng cùng property; lệch key khiến logout dừng trước khi xác minh server close.
  assert.ok(socketRead, 'NATIVE_WEB_UI_LOGOUT_SOCKET_READ_MISSING');
  assert.equal(socketRead[1], socketAssignment[1], 'NATIVE_WEB_UI_SOCKET_STATE_KEY_MISMATCH');
  console.log('NATIVE_WEB_UI_SOCKET_STATE_KEY_CONTRACT_PASS');
  // Credential phải được đăng ký trước action workspace; ticket phải được đăng ký trước khi dùng làm frame đầu.
  const workspaceActionStart = webUiHarnessSource.indexOf("await page.getByRole('heading', { name: 'Chọn workspace' }).waitFor");
  assert.ok(workspaceActionStart > 0, 'NATIVE_WEB_UI_WORKSPACE_ACTION_MISSING');
  for (const credentialName of ['sessionContextId', 'csrfToken', 'sessionCookie.value', 'cookiePair']) {
    const registration = webUiHarnessSource.indexOf(`registerBrowserSecret(sinkState, ${credentialName})`);
    assert.ok(registration >= 0 && registration < workspaceActionStart,
      'NATIVE_WEB_UI_AUTH_CANARY_REGISTERED_TOO_LATE');
  }
  const ticketRegistration = webUiHarnessSource.indexOf('window.__tn002RegisterSensitiveValue(firstFrameTicket)');
  const webSocketCreation = webUiHarnessSource.indexOf('new WebSocket(');
  assert.ok(ticketRegistration >= 0 && ticketRegistration < webSocketCreation,
    'NATIVE_WEB_UI_TICKET_CANARY_REGISTERED_TOO_LATE');
  // Log đến trước canary phải được quét lại; buffer vượt ngưỡng phải báo lỗi đóng an toàn.
  const browserCanary = createBrowserSecretCanaryState();
  const syntheticTicket = 'synthetic-realtime-ticket-canary';
  observeBrowserSink(browserCanary, `message contained ${syntheticTicket}`);
  registerBrowserSecret(browserCanary, syntheticTicket);
  assert.equal(browserCanary.leaked, true, 'NATIVE_WEB_UI_PRE_REGISTRATION_SINK_NOT_DETECTED');
  const completedCanary = finishBrowserSecretRegistration(browserCanary);
  assert.equal(completedCanary.leaked, true, 'NATIVE_WEB_UI_PRE_REGISTRATION_SINK_NOT_DETECTED');
  const overflowCanary = createBrowserSecretCanaryState();
  observeBrowserSink(overflowCanary, 'x'.repeat(1_048_577));
  assert.equal(overflowCanary.overflowed, true, 'NATIVE_WEB_UI_SINK_OVERFLOW_NOT_FAILED_CLOSED');
  disposeBrowserSecretCanary(browserCanary);
  disposeBrowserSecretCanary(overflowCanary);
  console.log('NATIVE_WEB_UI_SECRET_CANARY_ORDER_CONTRACT_PASS');
  assert.equal(safeNativeFailureCategory({ code: 'ENOENT', message: 'private path' }), 'ENOENT');
  assert.equal(safeNativeFailureCategory({ code: 'ERR_ASSERTION', message: 'NATIVE_E2E_PHASE_NOT_READY' }), 'NATIVE_E2E_PHASE_NOT_READY');
  assert.equal(safeNativeFailureCategory({ code: 'ERR_ASSERTION', message: 'NATIVE_PID_QUERY_COMMAND_FAILED_STDERR_PRESENT\nprivate details' }), 'NATIVE_PID_QUERY_COMMAND_FAILED_STDERR_PRESENT');
  assert.equal(safeNativeFailureCategory({ code: 'ERR_ASSERTION', message: 'OLD_NATIVE_PROCESS_STILL_PRESENT' }), 'OLD_NATIVE_PROCESS_STILL_PRESENT');
  assert.equal(safeNativeFailureCategory({ code: 'ERR_ASSERTION', message: 'private details', stack: 'Error\n    at assertNativePid (D:/workspace/ops/auth/run_native_e2e.mjs:1800:12)' }), 'ASSERTION_AT_1800');
  assert.equal(safeNativeFailureCategory({ code: 'ERR_ASSERTION', message: 'token=private' }), 'ERR_ASSERTION');
  assert.equal(safeNativeFailureCategory({ name: 'TypeError', message: 'private value' }), 'TYPE_ERROR');
  assert.equal(safeNativeFailureCategory({ code: 'PRIVATE_CODE', message: 'secret value' }), 'OTHER');
  assert.equal(safeNativeFailureCategory({ message: 'token=private' }), 'OTHER');
  console.log('NATIVE_PREFLIGHT_FAILURE_CATEGORY_SECRET_SAFE_PASS');
  const app = { appId: '11111111-2222-4333-8444-555555555555', deviceId: 'emulator-5554',
    directory: 'D:\\CODE\\DO_AN\\DO_AN_3\\mobile', mode: 'debug', launchMode: 'run' };
  assert.deepEqual(nativeS2RealtimeTicketArguments('resume', true),
    ['--dart-define=AUTH_E2E_S2_REALTIME_TICKET=true']);
  assert.deepEqual(nativeS2RealtimeTicketArguments('full', false), []);
  assert.throws(() => nativeS2RealtimeTicketArguments('full', true),
    { message: 'NATIVE_S2_REALTIME_TICKET_PHASE_INVALID' });
  assert.throws(() => nativeS2RealtimeTicketArguments('resume', true, true),
    { message: 'NATIVE_S2_REALTIME_TICKET_PHASE_INVALID' });
  console.log('NATIVE_S2_REALTIME_TICKET_DEFINE_PASS');
  assert.equal(validateOwnedApp(app), app.appId);
  for (const invalid of [{ ...app, deviceId: 'other' }, { ...app, mode: 'release' },
    { ...app, launchMode: 'attach' }, { ...app, appId: '' }, { ...app, directory: `${app.directory}-other` }]) {
    assert.throws(/** Không chấp nhận event có cấu trúc giống nhưng sai ownership. */
      () => validateOwnedApp(invalid), { message: 'NATIVE_DAEMON_OWNERSHIP_FAILED' });
  }
  assert.deepEqual(parseDaemonLine('ordinary non-protocol build output'), []);
  assert.deepEqual(parseDaemonLine('[{"event":"app.started","params":{}}]'), [{ event: 'app.started', params: {} }]);
  for (const invalid of ['[invalid-json]', '[' + ' '.repeat(65_536), '[1]', '[{}]',
    JSON.stringify(Array.from({ length: 17 }, /** Tạo envelope quá số lượng cho boundary cap. */
      () => ({ event: 'app.started' })))]) {
    assert.throws(/** Input lỗi phải mang fixed error, không phản chiếu nội dung vào exception. */
      () => parseDaemonLine(invalid), { message: 'NATIVE_DAEMON_PROTOCOL_FAILED' });
  }
  assert.deepEqual(normalizeExtensionResult({ accepted: true }), { accepted: true });
  assert.deepEqual(normalizeExtensionResult({ result: { accepted: false } }), { accepted: false });
  assert.throws(/** Không đưa raw trace/error response của SDK qua boundary kết quả. */
    () => normalizeExtensionResult({ error: 'synthetic-private-sentinel' }), { message: 'NATIVE_EXTENSION_RESULT_FAILED' });
  console.log('NATIVE_DAEMON_PROTOCOL_6_GROUPS_PASS');
  const checkpointCallback = () => {};
  assert.equal(canHandleNativeCheckpoint('full', checkpointCallback), true);
  assert.equal(canHandleNativeCheckpoint('access', checkpointCallback), true);
  assert.equal(canHandleNativeCheckpoint('resume', checkpointCallback), false);
  assert.equal(canHandleNativeCheckpoint('resume', checkpointCallback, true), true);
  assert.equal(canHandleNativeCheckpoint('resume', undefined, true), false);
  assert.equal(canHandleNativeCheckpoint('full', undefined), false);
  const preselectionCounts = { AUTH_LOGIN: 1, AUTH_LOGOUT: 0, PROFILE_READ: 1, WORKSPACE_LIST: 1, PASSWORD_CHANGE: 0, OTHER: 0 };
  assert.equal(validateNativePreselectionOracle('workspace-picker-before-select', preselectionCounts), true);
  assert.throws(() => validateNativePreselectionOracle('workspace-picker-before-select', { ...preselectionCounts, OTHER: 1 }),
    { message: /^NATIVE_DEVICE_OR_RESOURCE_REQUEST_BEFORE_PICKER/ });
  assert.throws(() => validateNativePreselectionOracle('workspace-picker-before-select', { ...preselectionCounts, WORKSPACE_LIST: 0 }),
    { message: /^NATIVE_PRESELECTION_WORKSPACE_COUNT_INVALID/ });
  assert.throws(() => validateNativePreselectionOracle('wrong-stage', preselectionCounts),
    { message: /^NATIVE_PRESELECTION_CHECKPOINT_INVALID/ });
  console.log('NATIVE_FULL_PRESELECTION_CHECKPOINT_AND_REQUEST_ORACLE_PASS');
  const failedBoundary = { terminal: false, boundaryFailed: true };
  assert.equal(canSendDaemonRequest(failedBoundary, 'app.stop', true), true);
  assert.equal(canSendDaemonRequest(failedBoundary, 'daemon.shutdown', true), true);
  assert.equal(canSendDaemonRequest(failedBoundary, 'app.callServiceExtension', true), false);
  assert.equal(canSendDaemonRequest(failedBoundary, 'app.callServiceExtension', false), false);
  assert.equal(canSendDaemonRequest({ ...failedBoundary, terminal: true }, 'app.stop', true), false);
  console.log('NATIVE_CLEANUP_ONLY_RPC_ALLOWANCE_PASS');
  assert.equal(isConfirmedSpawnFailure(false, undefined), true);
  assert.equal(isConfirmedSpawnFailure(true, 123), false);
  assert.equal(isConfirmedSpawnFailure(false, 123), false);
  assert.equal(isConfirmedSpawnFailure(true, undefined), false);
  console.log('NATIVE_POST_SPAWN_ERROR_NOT_TERMINAL_PASS');
  const state = { terminal: false, stopped: false, appId: app.appId, boundaryFailed: true };
  const commands = [];
  let end;
  const exit = new Promise(
    /**
     * Test chỉ xác nhận exit sau khi cleanup đã gửi đúng command, không fake terminal từ timeout.
     * Input
     * Param: resolve — owned SDK exit observer giả lập.
     */
    (resolve) => { end = resolve; });
  let killed = 0; let detached = 0;
  const fakeChild = {
    kill: /** Ghi forced kill để không coi cleanup timeout là clean exit. */ () => { killed++; },
    unref: /** Ghi detach để nhánh unconfirmed không giữ host test vô hạn. */ () => { detached++; },
    stdin: { destroy: /** Không giữ write pipe ở outcome terminal. */ () => {} },
    stdout: { destroy: /** Không giữ output giả của test. */ () => {} },
    stderr: { destroy: /** Không giữ error pipe giả của test. */ () => {} },
  };
  const result = await shutdownNativeDaemon({ child: fakeChild,
    getState: /** Snapshot này cố ý có boundaryFailed để bắt cleanup bị short-circuit. */ () => state,
    request:
      /**
       * ACK shutdown ngay cả khi boundaryFailed, chỉ fixed commands được phép.
       * Input
       * Param: method — app.stop/daemon.shutdown cần được phát.
       * Param: params — đúng owned appId, không credential.
       * Param: cleanup — phải bật cleanup-only allowance.
       */
      async (method, params, cleanup) => {
        assert.equal(cleanup, true); commands.push(method);
        if (method === 'app.stop') { assert.equal(params.appId, app.appId); state.stopped = true; throw new Error('EXPECTED_STOP_RPC_FAILURE'); }
        state.terminal = true; end(0);
      }, exit, budgetMilliseconds: 10 });
  assert.deepEqual(commands, ['app.stop', 'daemon.shutdown']);
  assert.equal(result.sdkExited, true); assert.equal(result.forced, false);
  assert.equal(killed, 0); assert.equal(detached, 0);
  console.log('NATIVE_BOUNDARY_FAILURE_CLEANUP_COMMANDS_PASS');
  const never = new Promise(/** Child giả không bao giờ exit để tái hiện bug unbounded await. */ () => {});
  const failure = await shutdownNativeDaemon({ child: fakeChild,
    getState: /** SDK vẫn live sau mọi command/kill, phải báo unconfirmed và trả hữu hạn. */
      () => ({ ...state, terminal: false, stopped: false }),
    request: /** Lỗi một resource không được làm bỏ deadline/cleanup resource khác. */
      async () => { throw new Error('EXPECTED_RPC_FAILURE'); }, exit: never, budgetMilliseconds: 10 });
  assert.equal(failure.sdkExited, false); assert.equal(failure.forced, true);
  assert.equal(killed, 1); assert.equal(detached, 1);
  console.log('NATIVE_NEVER_EXIT_BOUNDED_FAILURE_PASS');
  const seedId = 'aaaaaaaa-1111-4111-8111-111111111111';
  const appId = 'bbbbbbbb-2222-4222-8222-222222222222';
  const otherId = 'cccccccc-3333-4333-8333-333333333333';
  const baseline = [{ sessionId: seedId, revoked: false }];
  const full = [...baseline, { sessionId: appId, revoked: false }];
  assert.equal(validateSessionDelta(baseline, full), appId);
  assert.equal(validateSessionDelta(baseline, full, [...baseline, { sessionId: appId, revoked: true }]), appId);
  for (const invalid of [baseline, [...full, { sessionId: otherId, revoked: false }],
    [{ sessionId: seedId, revoked: true }, full[1]], [full[1]], [...full, full[1]],
    [...baseline, { sessionId: appId, revoked: true }]]) {
    assert.throws(/** Sai delta không được biến thành bằng chứng App session được tạo đúng. */
      () => validateSessionDelta(baseline, invalid));
  }
  for (const invalid of [full, [full[1]], [...baseline, { sessionId: otherId, revoked: true }],
    [{ sessionId: seedId, revoked: true }, { sessionId: appId, revoked: true }]]) {
    assert.throws(/** Logout chỉ được đổi flag của đúng App UUID, không tạo/xóa baseline hoặc relogin. */
      () => validateSessionDelta(baseline, full, invalid));
  }
  console.log('NATIVE_EXACT_SESSION_DELTA_LOGIN_LOGOUT_PASS');
  // Snapshot fixture chứng minh Web logout không thu hồi Android S2; Android chỉ revoke S2 khi App tự logout.
  const androidId = 'dddddddd-4444-4444-8444-444444444444';
  const webId = 'eeeeeeee-5555-4555-8555-555555555555';
  const androidFull = [...baseline, { sessionId: androidId, revoked: false }];
  const webLogin = [...androidFull, { sessionId: webId, revoked: false }];
  const webLogout = [...androidFull, { sessionId: webId, revoked: true }];
  const androidLogout = [...baseline, { sessionId: androidId, revoked: true }, { sessionId: webId, revoked: true }];
  assert.deepEqual(validateCrossClientSessionDelta(baseline, androidFull, webLogin, webLogout, androidLogout),
    { androidSessionId: androidId, webSessionId: webId });
  const webLogoutWronglyRevokesAndroid = [...baseline, { sessionId: androidId, revoked: true }, { sessionId: webId, revoked: true }];
  assert.throws(
    /** Invariant Web revoke không được đánh dấu Android S2 revoked trước khi App logout. */
    () => validateCrossClientSessionDelta(baseline, androidFull, webLogin, webLogoutWronglyRevokesAndroid),
    { message: /^CROSS_CLIENT_SESSION_DELTA_INVALID/ },
  );
  console.log('NATIVE_CROSS_CLIENT_SESSION_DELTA_ORACLE_PASS');
  protocolStage = 'android-sibling-session-delta';
  // S1 được tạo trước lần đăng nhập Android để chứng minh ngay sau logout S2 thì S1 vẫn còn hoạt động.
  const activeWebSession = { sessionId: webId, revoked: false };
  const activeAndroidSession = { sessionId: androidId, revoked: false };
  const revokedWebSession = { ...activeWebSession, revoked: true };
  const revokedAndroidSession = { ...activeAndroidSession, revoked: true };
  const webBeforeAndroidLogin = [...baseline, activeWebSession];
  const bothActive = [...webBeforeAndroidLogin, activeAndroidSession];
  const afterAndroidLogout = [...webBeforeAndroidLogin, revokedAndroidSession];
  const afterWebCleanup = [...baseline, revokedAndroidSession, revokedWebSession];
  const siblingSessionIds = { androidSessionId: androidId, webSessionId: webId };
  assert.deepEqual(validateAndroidLogoutPreservesWebSibling(baseline, webBeforeAndroidLogin, bothActive), siblingSessionIds);
  assert.deepEqual(validateAndroidLogoutPreservesWebSibling(baseline, webBeforeAndroidLogin, bothActive,
    afterAndroidLogout), siblingSessionIds);
  assert.deepEqual(validateAndroidLogoutPreservesWebSibling(baseline, webBeforeAndroidLogin, bothActive,
    afterAndroidLogout, afterWebCleanup), siblingSessionIds);

  assert.throws(/** S1 phải còn hoạt động ngay tại điểm kiểm Web login. */
    () => validateAndroidLogoutPreservesWebSibling(baseline, [...baseline, revokedWebSession], bothActive),
    { message: /^SESSION_ALREADY_REVOKED\b/ });
  assert.throws(/** Android login không được làm mất hiệu lực S1 trước khi chạy logout. */
    () => validateAndroidLogoutPreservesWebSibling(baseline, webBeforeAndroidLogin,
      [...baseline, revokedWebSession, activeAndroidSession]),
    { message: /^SESSION_BASELINE_CHANGED\b/ });

  for (const invalidAfterAndroidLogout of [
    bothActive,
    afterWebCleanup,
    [{ sessionId: seedId, revoked: true }, activeWebSession, revokedAndroidSession],
    [...baseline, { sessionId: otherId, revoked: false }, revokedAndroidSession],
  ]) {
    assert.throws(/** Logout S2 phải đổi đúng S2, giữ nguyên bản ghi seed và UUID/trạng thái của S1. */
      () => validateAndroidLogoutPreservesWebSibling(baseline, webBeforeAndroidLogin, bothActive, invalidAfterAndroidLogout),
      { message: /^SESSION_LOGOUT_DELTA_INVALID\b/ });
  }

  assert.throws(/** Hai phiên revoked ở snapshot cuối không bù được việc thiếu snapshot ngay sau Android logout. */
    () => validateAndroidLogoutPreservesWebSibling(baseline, webBeforeAndroidLogin, bothActive, undefined, afterWebCleanup),
    { message: /^ANDROID_SIBLING_SESSION_DELTA_INVALID\b/ });
  for (const invalidAfterWebCleanup of [
    afterAndroidLogout,
    [...baseline, activeAndroidSession, revokedWebSession],
    [{ sessionId: seedId, revoked: true }, revokedAndroidSession, revokedWebSession],
    [...afterWebCleanup, { sessionId: otherId, revoked: false }],
  ]) {
    assert.throws(/** Cleanup chỉ được revoke S1 và phải giữ nguyên S2 đã revoke cùng toàn bộ baseline. */
      () => validateAndroidLogoutPreservesWebSibling(baseline, webBeforeAndroidLogin, bothActive,
        afterAndroidLogout, invalidAfterWebCleanup),
      { message: /^ANDROID_SIBLING_SESSION_DELTA_INVALID\b/ });
  }
  console.log('NATIVE_ANDROID_SIBLING_SESSION_DELTA_ORACLE_PASS');
  protocolStage = 'raw-bodyless-204';
  const bodylessResponse = Buffer.from('HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n', 'ascii');
  assert.deepEqual(validateRawBodyless204Response(bodylessResponse), { status: 204, bodyByteLength: 0 });
  assert.throws(/** Byte nhị phân sau header phải bị chặn dù HTTP client có thể bỏ thân của 204. */
    () => validateRawBodyless204Response(Buffer.concat([bodylessResponse, Buffer.from([0x00, 0xff])])),
    { message: /^ANDROID_SIBLING_WEB_WIRE_BODY_NOT_EMPTY\b/ });
  assert.throws(/** Response rỗng chỉ hợp lệ với status cleanup đã chốt là 204. */
    () => validateRawBodyless204Response(Buffer.from('HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n', 'ascii')),
    { message: /^ANDROID_SIBLING_WEB_WIRE_STATUS_INVALID\b/ });
  assert.throws(/** Header kết thúc bằng LF thiếu phân cách HTTP CRLF nên chưa chứng minh thân rỗng. */
    () => validateRawBodyless204Response(Buffer.from('HTTP/1.1 204 No Content\r\nConnection: close\n\n', 'ascii')),
    { message: /^ANDROID_SIBLING_WEB_WIRE_RESPONSE_INVALID\b/ });
  // Dùng header có cấu trúc hợp lệ nhưng vượt ngân sách 16 KiB để cô lập kiểm tra giới hạn wire.
  const oversizeResponse = Buffer.from(`HTTP/1.1 204 No Content\r\nX-Padding: ${'x'.repeat(16_384)}\r\n\r\n`, 'ascii');
  assert.throws(/** Một 204 rỗng vẫn bị từ chối nếu response vượt giới hạn tổng số byte. */
    () => validateRawBodyless204Response(oversizeResponse),
    { message: /^ANDROID_SIBLING_WEB_WIRE_RESPONSE_INVALID\b/ });
  console.log('NATIVE_ANDROID_SIBLING_RAW_BODYLESS_204_ORACLE_PASS');
  protocolStage = 'access-session-delta';
  const completed = [...baseline, { sessionId: appId, revoked: true }];
  const accountBAfterLogout = [...baseline, { sessionId: otherId, revoked: true }];
  assert.deepEqual(validateAccountSwitchSessionDelta(baseline, completed, [], [], baseline, accountBAfterLogout),
    { accountASessionId: appId, accountBSessionId: otherId });
  for (const [fullBefore, fullAfter, disabledBefore, disabledAfter, emptyBefore, emptyAfter] of [
    [baseline, baseline, [], [], baseline, accountBAfterLogout],
    [baseline, [...completed, { sessionId: otherId, revoked: true }], [], [], baseline, accountBAfterLogout],
    [[{ sessionId: seedId, revoked: true }], completed, [], [], baseline, accountBAfterLogout],
    [baseline, full, [], [], baseline, accountBAfterLogout],
    [baseline, completed, [], [{ sessionId: otherId, revoked: true }], baseline, accountBAfterLogout],
    [baseline, completed, [], [], baseline, baseline],
    [baseline, completed, [], [], baseline, full],
    [baseline, completed, [], [], baseline, [...accountBAfterLogout, { sessionId: appId, revoked: true }]],
    [baseline, completed, [], [], [{ sessionId: seedId, revoked: true }], accountBAfterLogout],
    [baseline, completed, [], [], baseline, [accountBAfterLogout[1]]],
    [baseline, completed, [], [], baseline, [...accountBAfterLogout, accountBAfterLogout[1]]],
  ]) {
    assert.throws(/** Không che thiếu/thừa hoặc revoke sai session A, disabled hay B bằng final flag. */
      () => validateAccountSwitchSessionDelta(fullBefore, fullAfter, disabledBefore, disabledAfter, emptyBefore, emptyAfter));
  }
  console.log('NATIVE_ACCESS_SESSION_DELTA_PASS');
  const steps = [
    ['before-account-a', 0, 0, 0], ['account-a-ready', 1, 1, 0], ['account-a-logged-out', 1, 1, 1],
    ['before-disabled', 1, 1, 1], ['disabled-rejected', 2, 1, 1], ['wrong-rejected', 3, 1, 1],
    ['empty-ready', 4, 2, 1], ['empty-refreshed', 4, 3, 1], ['logged-out', 4, 3, 2],
  ];
  const oracle = createAccessCheckpointOracle();
  for (const [stage, login, workspace, logout] of steps) oracle.checkpoint(stage,
    { AUTH_LOGIN: login, AUTH_LOGOUT: logout, WORKSPACE_LIST: workspace, PASSWORD_CHANGE: 0, PROFILE_READ: workspace ? 1 : 0, OTHER: 1 });
  oracle.finish({ AUTH_LOGIN: 4, AUTH_LOGOUT: 2, WORKSPACE_LIST: 3, PASSWORD_CHANGE: 0, PROFILE_READ: 1, OTHER: 1 });
  for (const [target, loginDelta, workspaceDelta, other] of [
    [1, -1, 0, 0], [1, 1, 0, 0], [4, -1, 0, 0],
    [6, 0, 1, 0], [7, 0, -1, 99],
  ]) {
    const rejected = createAccessCheckpointOracle();
    for (const [index, [stage, login, workspace, logout]] of steps.entries()) {
      const counts = { AUTH_LOGIN: login + (index === target ? loginDelta : 0),
        AUTH_LOGOUT: logout, WORKSPACE_LIST: workspace + (index === target ? workspaceDelta : 0), PASSWORD_CHANGE: 0, PROFILE_READ: workspace ? 1 : 0, OTHER: other };
      if (index === target) {
        assert.throws(/** No-op/duplicate POST, duplicate initial list hoặc thiếu refresh không được OTHER bù. */
          () => rejected.checkpoint(stage, counts));
        break;
      }
      rejected.checkpoint(stage, counts);
    }
  }
  const ordered = createAccessCheckpointOracle();
  const zero = { AUTH_LOGIN: 0, AUTH_LOGOUT: 0, WORKSPACE_LIST: 0, PASSWORD_CHANGE: 0, PROFILE_READ: 0, OTHER: 0 };
  assert.throws(/** Stage ngoài thứ tự không được ACK dù counter shape đúng. */
    () => ordered.checkpoint('disabled-rejected', zero));
  ordered.checkpoint('before-account-a', zero);
  assert.throws(/** C2-A không có đổi mật khẩu; enum mới không được âm thầm cấp mutation ngoài scope. */
    () => createAccessCheckpointOracle().checkpoint('before-account-a', { ...zero, PASSWORD_CHANGE: 1 }));
  assert.throws(/** Replay checkpoint không được tiến sequence hai lần. */
    () => ordered.checkpoint('before-account-a', zero));
  assert.throws(/** Không thiếu stage hoặc dùng final count để giả toàn chuỗi đã ACK. */
    () => ordered.finish({ AUTH_LOGIN: 4, AUTH_LOGOUT: 2, WORKSPACE_LIST: 3, PASSWORD_CHANGE: 0, PROFILE_READ: 1, OTHER: 0 }));
  assert.throws(/** POST phát muộn sau completed sequence vẫn phải FAIL final oracle. */
    () => oracle.finish({ AUTH_LOGIN: 4, AUTH_LOGOUT: 3, WORKSPACE_LIST: 3, PASSWORD_CHANGE: 0, PROFILE_READ: 1, OTHER: 1 }));
  for (const [target, logout] of [[0, 1], [2, 0], [2, 2], [8, 1], [8, 3]]) {
    const rejected = createAccessCheckpointOracle();
    for (const [index, [stage, login, workspace, expectedLogout]] of steps.entries()) {
      const counts = { AUTH_LOGIN: login, AUTH_LOGOUT: expectedLogout,
        WORKSPACE_LIST: workspace, PASSWORD_CHANGE: 0, PROFILE_READ: workspace ? 1 : 0, OTHER: 99 };
      if (index === target) {
        counts.AUTH_LOGOUT = logout;
        assert.throws(/** Logout sớm, no-op hoặc duplicate không được OTHER bù hay chỉ nhìn UI cuối. */
          () => rejected.checkpoint(stage, counts), { code: 'ERR_ASSERTION', message: /^ACCESS_LOGOUT_COUNT_INVALID\b/ });
        break;
      }
      rejected.checkpoint(stage, counts);
    }
  }
  assert.throws(/** Request logout phát muộn sau SDK stop vẫn không được gộp vào trạng thái đã chốt. */
    () => oracle.finish({ AUTH_LOGIN: 4, AUTH_LOGOUT: 3, WORKSPACE_LIST: 3, PASSWORD_CHANGE: 0, PROFILE_READ: 1, OTHER: 99 }),
    { code: 'ERR_ASSERTION', message: /^ACCESS_LOGOUT_COUNT_INVALID\b/ });
  const missingLogout = { ...zero }; delete missingLogout.AUTH_LOGOUT;
  for (const invalid of [missingLogout, { ...zero, AUTH_LOGOUT: -1 }, { ...zero, AUTH_LOGOUT: 0.5 }, { ...zero, EXTRA: 0 }]) {
    assert.throws(/** Thiếu/thừa key hoặc count không nguyên không được nhận như counter protocol hợp lệ. */
      () => createAccessCheckpointOracle().checkpoint('before-account-a', invalid), { message: 'ACCESS_COUNTER_INVALID' });
  }
  console.log('NATIVE_ACCESS_ORDERED_CHECKPOINTS_PASS');
  protocolStage = 'password-checkpoints';
  const passwordSteps = [['password-before', 0, 0, 0], ['limited-ready', 1, 0, 0],
    ['invalid-short', 1, 0, 0], ['invalid-uppercase', 1, 0, 0], ['invalid-lowercase', 1, 0, 0],
    ['invalid-digit', 1, 0, 0], ['invalid-confirm', 1, 0, 0], ['current-rejected', 1, 1, 0], ['password-changed', 1, 2, 0],
    ['relogin-before', 1, 2, 0], ['old-rejected', 2, 2, 0], ['new-empty', 3, 2, 1], ['password-logout', 3, 2, 1]];
  const passwordOracle = createPasswordCheckpointOracle();
  for (const [index, [stage, login, password, workspace]] of passwordSteps.entries()) {
    const counts = { AUTH_LOGIN: login, AUTH_LOGOUT: stage === 'password-logout' ? 1 : 0, PASSWORD_CHANGE: password, WORKSPACE_LIST: workspace, PROFILE_READ: workspace, OTHER: 0 };
    passwordOracle.checkpoint(stage, counts);
    if (index === 8) passwordOracle.finishPhase('password', counts);
    if (index === 12) passwordOracle.finishPhase('password-relogin', counts);
  }
  for (const [target, key, delta] of [[1, 'WORKSPACE_LIST', 1], [1, 'PROFILE_READ', 1], [1, 'OTHER', 1], [2, 'PASSWORD_CHANGE', 1],
    [7, 'PASSWORD_CHANGE', -1], [7, 'PASSWORD_CHANGE', 1], [8, 'AUTH_LOGIN', 1],
    [10, 'AUTH_LOGIN', -1], [11, 'WORKSPACE_LIST', -1], [12, 'PASSWORD_CHANGE', 1],
    [0, 'AUTH_LOGOUT', 1], [12, 'AUTH_LOGOUT', -1], [12, 'AUTH_LOGOUT', 1]]) {
    const rejected = createPasswordCheckpointOracle();
    for (const [index, [stage, login, password, workspace]] of passwordSteps.entries()) {
      const counts = { AUTH_LOGIN: login, AUTH_LOGOUT: stage === 'password-logout' ? 1 : 0, PASSWORD_CHANGE: password, WORKSPACE_LIST: workspace, PROFILE_READ: workspace, OTHER: 0 };
      if (index === target) {
        counts[key] += delta;
        assert.throws(/** Validation/no-op/duplicate hoặc early workspace không được request OTHER bù. */
          () => rejected.checkpoint(stage, counts));
        break;
      }
      rejected.checkpoint(stage, counts);
    }
  }
  assert.throws(/** Không bỏ phase1 hoặc relogin trước password ACK. */
    () => createPasswordCheckpointOracle().checkpoint('relogin-before', { ...zero }));
  assert.throws(/** Không dùng final tổng thay sequence chưa đủ. */
    () => createPasswordCheckpointOracle().finishPhase('password', { ...zero }));
  assert.throws(/** Logout phát muộn sau phase2 đã chốt phải FAIL ngay cả khi password/login counts vẫn đúng. */
    () => passwordOracle.finishPhase('password-relogin', { AUTH_LOGIN: 3, AUTH_LOGOUT: 2, PASSWORD_CHANGE: 2,
      WORKSPACE_LIST: 1, PROFILE_READ: 1, OTHER: 99 }), { code: 'ERR_ASSERTION', message: /^PASSWORD_LOGOUT_COUNT_INVALID\b/ });
  for (const invalid of [missingLogout, { ...zero, AUTH_LOGOUT: -1 }, { ...zero, AUTH_LOGOUT: 0.5 }, { ...zero, EXTRA: 0 }]) {
    assert.throws(/** Cả password oracle phải kiểm đủ6counter, không có schema fallback chỉ ở phase khác. */
      () => createPasswordCheckpointOracle().checkpoint('password-before', invalid), { message: 'PASSWORD_COUNTER_INVALID' });
  }
  protocolStage = 'password-session-delta';
  const changed = [{ sessionId: appId, revoked: true }];
  const afterNewLogin = [...changed, { sessionId: otherId, revoked: true }];
  assert.deepEqual(validatePasswordSessionDelta([], changed, afterNewLogin), [appId, otherId]);
  for (const [first, last] of [[[], afterNewLogin], [[{ sessionId: appId, revoked: false }], afterNewLogin],
    [changed, changed], [changed, [...changed, { sessionId: otherId, revoked: false }]],
    [changed, [{ sessionId: appId, revoked: false }, afterNewLogin[1]]]]) {
    assert.throws(/** Phiên limited/new phải bị revoke đúng giai đoạn, không thêm phiên trước password ACK. */
      () => validatePasswordSessionDelta([], first, last));
  }
  assert.deepEqual(nativePhaseBudget('password'), { testMilliseconds: 240_000, reserveMilliseconds: 960_000 });
  protocolStage = 'phase-budget';
  assert.deepEqual(nativePhaseBudget('password-relogin'), { testMilliseconds: 180_000, reserveMilliseconds: 900_000 });
  assert.deepEqual(nativePhaseBudget('access'), { testMilliseconds: 240_000, reserveMilliseconds: 480_000 });
  assert.throws(/** Không nhận numeric hoặc phase tùy ý để kéo dài test. */ () => nativePhaseBudget('arbitrary'));
  requireWorkBudget(2_100_000, 1_860_000, 135_000);
  assert.throws(/** Thiếu reserve phải dừng trước spawn tiếp; deadline không giả terminal/cleanup. */
    () => requireWorkBudget(2_100_000, 1_860_000, 240_001));
  assert.throws(/** Success đến sau deadline cũng bị chặn. */ () => requireWorkBudget(10, 0, 11));
  const syntheticSecrets = ['Aa1' + 'a'.repeat(32), 'Aa2' + 'b'.repeat(32)];
  assert.equal(containsNativeSecret('ordinary metadata', syntheticSecrets), false);
  for (const secret of syntheticSecrets) {
    assert.equal(containsNativeSecret('prefix' + secret + 'suffix', syntheticSecrets), true);
    const previousTail = secret.slice(0, 15);
    assert.equal(containsNativeSecret(previousTail + secret.slice(15), syntheticSecrets), true);
  }
  const expiredSessionToken = 'c'.repeat(64);
  const offlineSecrets = [syntheticSecrets[0], expiredSessionToken];
  assert.equal(containsNativeSecret('prefix' + expiredSessionToken + 'suffix', offlineSecrets), true);
  assert.equal(containsNativeSecret(expiredSessionToken.slice(0, 31) + expiredSessionToken.slice(31), offlineSecrets), true);
  assert.throws(/** Secret list rỗng không được âm thầm tắt redaction boundary. */ () => containsNativeSecret('text', []));
  protocolStage = 'fixture-cleanup';
  const cleanup = { role: 0, hba: 0, users: 0, sessions: 0, workspaces: 0, memberships: 0,
    auditActor: 0, limiterBuckets: 0, pushInstallations: 0, websocketTickets: 0,
    outboxEvents: 0, outboxConsumptions: 0, globalIdempotencyRecords: 0 };
  validateFixtureCleanup(cleanup);
  for (const key of Object.keys(cleanup)) {
    const missing = { ...cleanup }; delete missing[key];
    assert.throws(/** Thiếu từng key kể cả bucket mới không được giả cleanup0 từ schema cũ. */
      () => validateFixtureCleanup(missing), { message: 'NATIVE_FIXTURE_CLEANUP_FAILED' });
  }
  const { limiterBuckets, ...legacyCleanup } = cleanup;
  for (const invalid of [null, [], {}, { ...cleanup, unexpected: 0 }, { ...legacyCleanup, unexpected: 0 },
    ...['pushInstallations', 'websocketTickets', 'outboxEvents', 'outboxConsumptions', 'globalIdempotencyRecords'].map(
      /** Bất kỳ bảng nghiệp vụ nào còn record fixture cũng phải chặn ACK cleanup. */
      (key) => ({ ...cleanup, [key]: 1 })),
    ...[1, -1, false, null, '0', 0.1, NaN].map(
      /** Biến count bucket thành giá trị không phải integer0 để kiểm strict consumer boundary. */
      (value) => ({ ...cleanup, limiterBuckets: value }))]) {
    assert.throws(/** Đủ8keys nhưng sai tên/kiểu/count vẫn phải FAIL trước cleanup ACK. */
      () => validateFixtureCleanup(invalid), { message: 'NATIVE_FIXTURE_CLEANUP_FAILED' });
  }
  console.log('NATIVE_FIXTURE_THIRTEEN_COUNT_CLEANUP_PASS');
  protocolStage = 'fixture-readiness-diagnostic';
  {
    const child = new EventEmitter(); child.pid = 4245;
    child.stdin = new EventEmitter(); child.stdout = new EventEmitter(); child.stderr = new EventEmitter();
    const commands = []; let terminal = false; const diagnostics = [];
    child.stdin.write = /** Không dùng nội dung packet giả trong assertion hoặc log test. */ () => {};
    child.stdin.end = /** STOP vẫn đi tới child sở hữu và chỉ exit/readback giả mới hoàn tất cleanup. */ (value) => {
      commands.push(value);
      child.stdout.emit('data', Buffer.from(JSON.stringify({ kind: 'STOPPED', cleanup }) + '\n'));
      terminal = true; child.emit('exit', 0);
    };
    for (const stream of [child.stdin, child.stdout, child.stderr]) {
      stream.destroy = /** Chỉ giải phóng pipe của child fake sau terminal. */ () => {};
    }
    const password = 'Aa1' + 'd'.repeat(32);
    const fixture = startFixture(password, 'default', [password],
      /** Thay duy nhất boundary spawn bằng process fake, không khởi tạo tiến trình hệ thống. */ () => child);
    const originalError = console.error;
    console.error = /** Thu riêng dòng diagnostic để chứng minh không phản chiếu stderr hoặc frame thô. */
      (...values) => { diagnostics.push(values.join(' ')); };
    try {
      const ready = fixture.ready();
      child.emit('spawn');
      child.stderr.emit('data', Buffer.from('PRIVATE_STDERR_SENTINEL'));
      child.stdout.emit('data', Buffer.from('{"kind":"FAILED","message":"PRIVATE_FRAME_SENTINEL"}\n'));
      await assert.rejects(/** Fixture FAIL trước READY phải giữ lỗi protocol đã được phân loại. */ () => ready);
      assert.deepEqual(diagnostics,
        ['NATIVE_FIXTURE_READINESS_DIAGNOSTIC STATE=FIXTURE_REPORTED_FAILURE STDERR_PRESENT']);
      assert.equal(diagnostics.join(' ').includes('PRIVATE_STDERR_SENTINEL'), false);
      assert.equal(diagnostics.join(' ').includes('PRIVATE_FRAME_SENTINEL'), false);
    } finally {
      console.error = originalError;
    }
    await assert.rejects(/** Readback/STOP được thử dù fixture failure vẫn khiến cleanup verdict FAIL. */
      () => fixture.close(), { message: 'NATIVE_FIXTURE_CLEANUP_FAILED' });
    assert.equal(terminal, true); assert.deepEqual(commands, ['STOP\n']);
  }
  console.log('NATIVE_FIXTURE_READINESS_DIAGNOSTIC_REDACTED_PASS');
  const armState = { scenario: 'rate-limit', readyReceived: true, armSent: true, alreadyArmed: false };
  validateFixtureArmFrame({ kind: 'ARMED' }, armState);
  for (const state of [{ ...armState, scenario: 'default' }, { ...armState, readyReceived: false },
    { ...armState, armSent: false }, { ...armState, alreadyArmed: true }]) {
    assert.throws(/** ARMED không được nhận trước READY/write, từ profile cũ hoặc lần thứ hai. */
      () => validateFixtureArmFrame({ kind: 'ARMED' }, state), { message: 'NATIVE_FIXTURE_ARM_FAILED' });
  }
  for (const frame of [null, [], {}, { kind: 'READY' }, { kind: 'ARMED', extra: true }]) {
    assert.throws(/** Chỉ exact frame của handshake được nhận, không thêm metadata hoặc fallback kind. */
      () => validateFixtureArmFrame(frame, armState), { message: 'NATIVE_FIXTURE_ARM_FAILED' });
  }
  let armClock = 100; let armWrites = 0;
  assert.equal(await armNativeFixture({ startupDeadline: 10_000,
    beforeArm: /** Positive wrapper state đã sẵn sàng, không có precondition failure. */ () => {},
    closeOnFailure: /** Positive ARM không được dừng fixture đang được admission. */ async () => { assert.fail('UNEXPECTED_CLOSE'); },
    now: /** Clock host synthetic để kiểm anchor trước write, không fake clock native/DB. */ () => armClock,
    isAvailable: /** Owned shim giả còn sống trong positive host case. */ () => true,
    sendArm: /** Delay write phải tiêu thụ chung ACK budget, không dời work anchor. */ () => { armWrites++; armClock += 2; },
    waitForArmed: /** ACK trễ100ms vẫn giữ deadline host ban đầu, không mở lại40phút. */ async (deadline) => {
      assert.equal(deadline, 5100); armClock += 100; return { kind: 'ARMED' };
    },
  }), 2_400_100);
  assert.equal(armWrites, 1);
  for (const failure of ['before-write', 'after-write', 'late-ack', 'startup-expired', 'exit', 'bad-frame', 'lost-ack', 'pipe-fail']) {
    let clock = 100; let reads = 0; let writes = 0; let available = true; let closes = 0;
    await assert.rejects(/** Mọi nhánh bất định dừng admission; ARM không được retry hoặc trả work window mới. */
      () => armNativeFixture({ startupDeadline: failure === 'startup-expired' ? 100 : 10_000,
        beforeArm: /** Các ca này kiểm deadline/pipe sau precondition hợp lệ. */ () => {},
        closeOnFailure: /** Rejection phải chờ close capability đúng một lần, kể cả chưa write được ARM. */ async () => { closes++; },
        now: /** Delay trước write phải bị chặn trước khi gửi command. */ () => ++reads > 1 && failure === 'before-write' ? 5100 : clock,
        isAvailable: /** SDK/shim exit sau write không được coi lost ACK là success. */ () => available,
        sendArm: /** Pipe lỗi hoặc write trễ không mở deadline mới và không gửi lại. */ () => {
          writes++; if (failure === 'pipe-fail') throw new Error('SYNTHETIC_PIPE_FAILURE');
          if (failure === 'after-write') clock = 5100;
        },
        waitForArmed: /** Trả fixed fake boundary result, không process/DB hoặc raw diagnostic. */ async () => {
          if (failure === 'lost-ack') throw new Error('SYNTHETIC_ACK_UNKNOWN');
          if (failure === 'late-ack') clock = 5100;
          if (failure === 'exit') available = false;
          return { kind: failure === 'bad-frame' ? 'READY' : 'ARMED' };
        },
      }));
    assert.equal(writes, ['before-write', 'startup-expired'].includes(failure) ? 0 : 1);
    assert.equal(closes, 1);
  }
  for (const failure of ['lost-ack', 'wrapper-precondition']) {
    const lifecycle = fakeFixtureLifecycle(cleanup);
    let armSettled = false;
    const arming = armNativeFixture({ startupDeadline: 10_000,
      beforeArm: /** Callback precondition của wrapper phải nằm trong cùng guarded cleanup với mất ACK. */ () => {
        if (failure === 'wrapper-precondition') throw new Error('SYNTHETIC_WRAPPER_PRECONDITION');
      },
      now: /** Clock synthetic giữ request trong bound, lỗi đến từ mất receipt. */ () => 100,
      isAvailable: /** Shim giả vẫn sống để close phải gửi STOP thật qua capability. */ () => true,
      sendArm: /** Fake pipe nhận ARM, không side effect ngoài test. */ () => {},
      waitForArmed: /** Nếu precondition bị bỏ qua thì trả ACK hợp lệ để test bắt false admission thật. */ async () => {
        if (failure === 'lost-ack') throw new Error('SYNTHETIC_ACK_UNKNOWN');
        return { kind: 'ARMED' };
      },
      closeOnFailure: /** Dùng đúng memoized close helper mà consumer dùng để kiểm ownership lifecycle. */ () => closeNativeFixture(lifecycle.owner),
    });
    arming.then(/** Ghi completion để phát hiện return sớm trước owned exit. */ () => { armSettled = true; },
      /** Ghi failure terminal mà không tạo unhandled rejection trong test pending. */ () => { armSettled = true; });
    await new Promise(/** Cho close bắt đầu chờ exit qua một event-loop turn, không ngủ hoặc giả exit. */ (resolve) => setImmediate(resolve));
    assert.deepEqual(lifecycle.commands, ['STOP\n']); assert.equal(armSettled, false);
    const closeAgain = closeNativeFixture(lifecycle.owner);
    assert.equal(closeAgain, closeNativeFixture(lifecycle.owner));
    lifecycle.finish();
    await assert.rejects(/** Chỉ sau terminal/8zero thì ARM error mới được trả cho caller. */
      () => arming, { message: 'NATIVE_FIXTURE_ARM_FAILED' });
    await closeAgain;
    assert.deepEqual(lifecycle.commands, ['STOP\n']);
    assert.deepEqual(lifecycle.destroyed, ['stdin', 'stdout', 'stderr']);
  }
  for (const invalid of [null, { kind: 'STOPPED', cleanup: { ...cleanup, limiterBuckets: 1 } },
    { kind: 'STOPPED', cleanup }]) {
    const lifecycle = fakeFixtureLifecycle(cleanup);
    const closing = closeNativeFixture(lifecycle.owner);
    lifecycle.finish(invalid, invalid?.cleanup === cleanup ? 1 : 0);
    await assert.rejects(/** Terminal riêng không thay STOPPED/zero readback hoặc exit0. */
      () => closing, { message: 'NATIVE_FIXTURE_CLEANUP_FAILED' });
  }
  for (const observerFailure of [false, true]) {
    const lifecycle = fakeFixtureLifecycle(cleanup); const diagnostics = []; let settled = false;
    lifecycle.owner.observeExit = /** Timeout hoặc observer error đều giữ cùng owned exit đến terminal. */ async () => {
      if (observerFailure) throw new Error('SYNTHETIC_OBSERVER_FAILURE');
      return { settled: false };
    };
    const originalError = console.error;
    console.error = /** Chỉ thu marker fixed của cleanup unknown, không dữ liệu input hoặc raw error. */ (value) => { diagnostics.push(value); };
    try {
      const closing = closeNativeFixture(lifecycle.owner);
      closing.then(/** Ghi completion để bắt timeout giả terminal. */ () => { settled = true; },
        /** Ghi rejection sau actual fake terminal. */ () => { settled = true; });
      await new Promise(/** Cho observer báo unknown rồi kiểm handle vẫn đang được chờ. */ (resolve) => setImmediate(resolve));
      assert.equal(settled, false); assert.deepEqual(lifecycle.commands, ['STOP\n']);
      assert.deepEqual(diagnostics, ['NATIVE_FIXTURE_EXIT_UNCONFIRMED ownedShimPid=4242']);
      lifecycle.finish();
      await assert.rejects(/** Late terminal không biến cleanup quá budget thành PASS. */
        () => closing, { message: 'NATIVE_FIXTURE_CLEANUP_FAILED' });
    } finally { console.error = originalError; }
  }
  for (const eofFails of [false, true]) {
    const lifecycle = fakeFixtureLifecycle(cleanup);
    lifecycle.owner.child.stdin.end = /** Write STOP hỏng vẫn phải thử EOF và đợi exit, không bail sớm. */ () => { throw new Error('SYNTHETIC_PIPE_FAILURE'); };
    if (eofFails) lifecycle.owner.child.stdin.destroy = /** Cả EOF cũng hỏng không được bỏ observer/những pipe còn lại. */ () => { throw new Error('SYNTHETIC_EOF_FAILURE'); };
    const closing = closeNativeFixture(lifecycle.owner);
    lifecycle.finish();
    if (eofFails) await assert.rejects(/** Stream cleanup thất bại vẫn giữ FAIL sau terminal. */
      () => closing, { message: 'NATIVE_FIXTURE_CLEANUP_FAILED' });
    else await closing;
    assert.ok(lifecycle.destroyed.includes('stdout') && lifecycle.destroyed.includes('stderr'));
  }
  console.log('NATIVE_RATE_ARM_FAILURE_OWNED_CLOSE_PASS');
  for (const failure of ['not-ready', 'partial-buffer', 'old-profile', 'replay', 'lost-ack', 'missing-stopped']) {
    const child = new EventEmitter(); child.pid = 4243;
    child.stdin = new EventEmitter(); child.stdout = new EventEmitter(); child.stderr = new EventEmitter();
    const commands = []; let terminal = false; let armWrites = 0; let spawnCalls = 0; let hookCalls = 0;
    child.stdin.write = /** Chỉ fake process boundary; factory/parser/arm/close đều là implementation thật. */ (value) => {
      if (value === 'ARM\n') {
        armWrites++;
        if (failure !== 'lost-ack') child.stdout.emit('data', Buffer.from('{"kind":"ARMED"}\n'));
      }
    };
    child.stdin.end = /** STOP phải đi tới owned child rồi mới phát readback và terminal giả, không tự hoàn tất từ intent. */ (value) => {
      commands.push(value);
      if (failure !== 'missing-stopped') child.stdout.emit('data', Buffer.from(JSON.stringify({ kind: 'STOPPED', cleanup }) + '\n'));
      terminal = true; child.emit('exit', 0);
    };
    for (const stream of [child.stdin, child.stdout, child.stderr]) {
      stream.destroy = /** Chỉ giả release pipe trong process fake, không đóng tài nguyên hệ thống. */ () => {};
    }
    const password = 'Aa1' + 'e'.repeat(32);
    const fixture = startFixture(password, failure === 'old-profile' ? 'default' : 'rate-limit', [password],
      /** Thay đúng capability spawn tại constructor, không patch guard/helper hoặc tạo Docker/SDK child. */
      (command, arguments_, options) => {
        spawnCalls++; assert.equal(command, 'python');
        assert.ok(arguments_.includes('ops/auth/native_lab_fixture.py'));
        assert.equal(options.shell, false); return child;
      },
      /** Đếm notification trước owned close; lỗi hook synthetic không được bỏ cleanup gốc. */
      () => { hookCalls++; if (failure === 'old-profile') throw new Error('PRIVATE_HOOK_SENTINEL'); });
    child.emit('spawn');
    if (!['not-ready', 'missing-stopped'].includes(failure)) {
      child.stdout.emit('data', Buffer.from(JSON.stringify({ kind: 'READY', runId: appId, userIds: [], emails: [] }) + '\n'));
    }
    if (failure === 'partial-buffer') child.stdout.emit('data', Buffer.from('{"kind":"ARM'));
    if (failure === 'replay') assert.ok(Number.isFinite(await fixture.arm()));
    await assert.rejects(/** Gọi trực tiếp returned arm để bắt precondition bị chuyển ra ngoài guarded helper. */
      () => fixture.arm());
    assert.equal(terminal, true); assert.deepEqual(commands, ['STOP\n']); assert.equal(spawnCalls, 1);
    assert.equal(hookCalls, 1);
    if (['replay', 'lost-ack'].includes(failure)) assert.equal(armWrites, 1);
    else assert.equal(armWrites, 0);
    // Caller finally dùng returned close thật: thành công hoặc failure đều phải memoize, không gửi STOP lần hai.
    try { await fixture.close(); } catch (error) { assert.equal(error.message, 'NATIVE_FIXTURE_CLEANUP_FAILED'); }
    assert.deepEqual(commands, ['STOP\n']);
    assert.equal(hookCalls, 1);
  }
  console.log('NATIVE_RATE_ARM_FACTORY_OWNED_CLOSE_PASS');
  {
    const child = new EventEmitter(); child.pid = 4244;
    child.stdin = new EventEmitter(); child.stdout = new EventEmitter(); child.stderr = new EventEmitter();
    const commands = []; let notified = 0; let settled = false;
    child.stdin.write = /** Không ACK ARM để kiểm close vẫn giữ child đang pending. */ () => {};
    child.stdin.end = /** Thu STOP nhưng chưa phát exit, giữ hai sự kiện độc lập. */ (value) => { commands.push(value); };
    for (const stream of [child.stdin, child.stdout, child.stderr]) {
      stream.destroy = /** Chỉ release stream synthetic của đúng child fake. */ () => {};
    }
    const password = 'Aa1' + 'f'.repeat(32);
    const owned = startFixture(password, 'rate-limit', [password],
      /** Thay boundary spawn bằng child fake đã tạo, không mở tiến trình hệ điều hành. */ () => child,
      /** Ghi nhận failure notification trước khi có actual owned terminal giả. */ () => { notified++; });
    child.emit('spawn');
    const arming = owned.arm();
    arming.catch(/** Theo dõi rejection nhưng không tự phát receipt child exit. */ () => { settled = true; });
    await Promise.resolve();
    assert.equal(notified, 1); assert.deepEqual(commands, ['STOP\n']); assert.equal(settled, false);
    child.stdout.emit('data', Buffer.from(JSON.stringify({ kind: 'STOPPED', cleanup }) + '\n'));
    child.emit('exit', 0);
    await assert.rejects(/** Chỉ nhận failure sau đúng child exit và STOPPED, không sau hook. */ () => arming);
    await owned.close();
    assert.equal(notified, 1); assert.deepEqual(commands, ['STOP\n']);
  }
  console.log('NATIVE_ARM_FAILURE_HOOK_BEFORE_OWNED_TERMINAL_PASS');
  console.log('NATIVE_RATE_ARM_ANCHOR_DEADLINE_FRAME_PASS');
  console.log('NATIVE_PASSWORD_ORDER_SESSION_BUDGET_SECRET_PASS');
}

try { await main(); } catch (error) {
  // Chỉ assertion code viết hoa được phép thoát; actual/expected và input test luôn bị loại bỏ.
  const safeCode = typeof error?.message === 'string' && /^[A-Z][A-Z0-9_]{0,95}$/.test(error.message)
    ? 'NATIVE_PROTOCOL_FAILURE_' + error.message : 'NATIVE_DAEMON_PROTOCOL_FAILED';
  console.error(safeCode); console.error('NATIVE_PROTOCOL_STAGE_' + protocolStage.toUpperCase().replaceAll('-', '_') + '_FAILED');
  process.exitCode = 1;
}
