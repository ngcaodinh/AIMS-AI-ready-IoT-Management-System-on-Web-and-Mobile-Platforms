import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { randomBytes, randomUUID, X509Certificate } from 'node:crypto';
import tls from 'node:tls';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { setTimeout as delay } from 'node:timers/promises';
import { createCertificates } from './memory_tls_material.mjs';
import { startLocalHttpsProxy } from './local_https_proxy.mjs';
import { createNativeRateEvidence, nativeSessionMap as snapshotMap } from './native_rate_evidence.mjs';
import { orchestrateNativeRate } from './native_rate_orchestration.mjs';
import { createNativeStartupDiagnostics } from './native_startup_diagnostics.mjs';
import { createNativeMembershipFixture } from './native_membership_fixture.mjs';

const mobileDirectory = path.resolve('mobile');
const deviceId = 'emulator-5554';

/**
 * Chọn budget cố định theo phase đã review trước BUILD, không nhận threshold từ CLI/packet.
 * Input
 * Param: phase — enum integration phase nội bộ.
 * Output: native test cap và whole-phase reserve, ms; phase khác allowlist bị từ chối.
 */
export function nativePhaseBudget(phase) {
  if (phase === 'offline-login') return { testMilliseconds: 675_000, reserveMilliseconds: 1_150_000 };
  if (phase === 'rate-limit') return { testMilliseconds: 1_260_000, reserveMilliseconds: 2_065_000 };
  if (phase === 'membership-stale') return { testMilliseconds: 420_000, reserveMilliseconds: 895_000 };
  if (phase === 'response-loss') return { testMilliseconds: 240_000, reserveMilliseconds: 960_000 };
  if (phase === 'password') return { testMilliseconds: 240_000, reserveMilliseconds: 960_000 };
  if (phase === 'password-relogin') return { testMilliseconds: 180_000, reserveMilliseconds: 900_000 };
  assert.ok(['preflight', 'full', 'resume', 'access'].includes(phase), 'INVALID_NATIVE_PHASE');
  return { testMilliseconds: 60_000, reserveMilliseconds: 480_000 };
}

/**
 * Chặn spawn/success khi work deadline không còn đủ reserve, không xem timeout là resource terminal.
 * Input
 * Param: deadline — mốc monotonic của owner work window, membership neo trước fixture spawn.
 * Param: reserve — số ms cố định do orchestrator chọn từ ledger.
 * Param: now — clock snapshot hiện tại, test dùng giá trị synthetic để kiểm boundary.
 */
export function requireWorkBudget(deadline, reserve, now = performance.now()) {
  assert.ok(Number.isFinite(deadline) && Number.isFinite(now) && Number.isSafeInteger(reserve) && reserve >= 0 &&
    deadline - now >= reserve, 'NATIVE_WORK_BUDGET_INSUFFICIENT');
}

/**
 * Cắt RPC30s bởi các deadline tuyệt đối đang hoạt động, không mở window mới sau response hoặc checkpoint.
 * Input
 * Param: bounds — workDeadline bắt buộc từ ARM; channel/phase/checkpoint deadlines chỉ có khi scope tương ứng còn hoạt động.
 * Param: now — monotonic sample trước RPC; clock giả chỉ dành host test.
 * Output: deadline tuyệt đối sớm nhất; không nhận timeout numeric từ CLI/fixture.
 * Errors: fixed timeout khi thiếu/nonfinite/đã hết scope, trước bất kỳ write nào.
 */
export function calculateNativeRpcDeadline(bounds, now = performance.now()) {
  assert.ok(bounds && Number.isFinite(now) && Number.isFinite(bounds.workDeadline), 'NATIVE_DAEMON_RPC_TIMEOUT');
  const deadlines = [now + 30_000, bounds.workDeadline];
  for (const name of ['channelDeadline', 'phaseDeadline', 'checkpointDeadline']) {
    if (bounds[name] !== undefined) {
      assert.ok(Number.isFinite(bounds[name]), 'NATIVE_DAEMON_RPC_TIMEOUT');
      deadlines.push(bounds[name]);
    }
  }
  const deadline = Math.min(...deadlines);
  assert.ok(deadline > now, 'NATIVE_DAEMON_RPC_TIMEOUT');
  return deadline;
}

/**
 * Scan toàn bộ secrets của run trước discard output, không chỉ password của packet phase hiện tại.
 * Input
 * Param: value — chunk/tail RAM của owned SDK/fixture, không log khi match.
 * Param: secrets — password cũ/mới có shape synthetic, không chấp nhận list rỗng để tắt guard.
 * Output: true nếu có secret trong chuỗi đã nối qua chunk boundary.
 */
export function containsNativeSecret(value, secrets) {
  assert.ok(Array.isArray(secrets) && secrets.length >= 1 && secrets.length <= 2 && secrets.every(
    /**
     * Chỉ scanner test dùng synthetic secret hữu hạn, không nhận empty-string làm match mọi output.
     * Input
     * Param: secret — credential của owned fixture cần chặn xuất ra log.
     */
    (secret) => typeof secret === 'string' && /^Aa[12][0-9a-f]{32}$/.test(secret)), 'INVALID_NATIVE_SECRET_SCAN');
  return secrets.some(
    /**
     * Kiểm từng credential gốc/mới mà không phản chiếu giá trị nào trong failure.
     * Input
     * Param: secret — chuỗi cần match trong RAM output.
     */
    (secret) => value.includes(secret));
}

/**
 * Kiểm delta session bằng UUID/revoked public, giữ seed baseline và phát hiện relogin ở cold restore.
 * Input
 * Param: baseline — snapshot trước App, có thể chứa phiên seed để tạo workspace.
 * Param: full — snapshot sau App login phải chỉ thêm một phiên chưa revoked.
 * Param: after — tùy chọn snapshot sau resume/logout, chỉ App UUID được chuyển revoked=true.
 * Output: UUID phiên App duy nhất; mọi lệch schema/tập/flag đều fail bằng lỗi cố định.
 */
export function validateSessionDelta(baseline, full, after) {
  const initial = snapshotMap(baseline); const loggedIn = snapshotMap(full);
  assert.equal(loggedIn.size, initial.size + 1, 'SESSION_LOGIN_DELTA_INVALID');
  for (const [id, revoked] of initial) assert.equal(loggedIn.get(id), revoked, 'SESSION_BASELINE_CHANGED');
  const added = [...loggedIn.keys()].filter(
    /**
     * Chỉ UUID mới thuộc App run này, không suy tất cả session hiện hành đều của App.
     * Input
     * Param: id — UUID public cần đối chiếu với baseline.
     */
    (id) => !initial.has(id));
  assert.equal(added.length, 1, 'SESSION_LOGIN_DELTA_INVALID');
  assert.equal(loggedIn.get(added[0]), false, 'SESSION_ALREADY_REVOKED');
  if (after !== undefined) {
    const loggedOut = snapshotMap(after);
    assert.equal(loggedOut.size, loggedIn.size, 'SESSION_LOGOUT_SET_CHANGED');
    for (const [id, revoked] of loggedIn) {
      assert.equal(loggedOut.get(id), id === added[0] ? true : revoked, 'SESSION_LOGOUT_DELTA_INVALID');
    }
  }
  return added[0];
}

/**
 * Kiểm denied account không có session delta và empty account chỉ có một phiên đã logout ACK.
 * Input
 * Param: disabledBefore — baseline metadata account disabled owned.
 * Param: disabledAfter — metadata cùng account sau ca UI, phải giữ nguyên mọi entry.
 * Param: emptyBefore — baseline metadata account no-membership owned.
 * Param: emptyAfter — sau wrong/correct login và logout, thêm đúng một UUID revoked=true.
 * Output: UUID mới đã revoked; schema/tập/flag khác contract đều FAIL.
 */
export function validateAccessSessionDelta(disabledBefore, disabledAfter, emptyBefore, emptyAfter) {
  const deniedInitial = snapshotMap(disabledBefore); const deniedFinal = snapshotMap(disabledAfter);
  assert.equal(deniedFinal.size, deniedInitial.size, 'DENIED_SESSION_CHANGED');
  for (const [id, revoked] of deniedInitial) assert.equal(deniedFinal.get(id), revoked, 'DENIED_SESSION_CHANGED');
  const initial = snapshotMap(emptyBefore); const completed = snapshotMap(emptyAfter);
  assert.equal(completed.size, initial.size + 1, 'EMPTY_SESSION_DELTA_INVALID');
  for (const [id, revoked] of initial) assert.equal(completed.get(id), revoked, 'EMPTY_BASELINE_CHANGED');
  const added = [...completed.keys()].filter(
    /**
     * Chỉ row thêm từ login UI của lượt thử; seed metadata luôn giữ nguyên.
     * Input
     * Param: id — UUID public cần so với baseline owned.
     */
    (id) => !initial.has(id));
  assert.equal(added.length, 1, 'EMPTY_SESSION_DELTA_INVALID');
  assert.equal(completed.get(added[0]), true, 'EMPTY_SESSION_NOT_REVOKED');
  return added[0];
}

/**
 * Giữ thứ tự checkpoint và exact login/workspace/logout counters để stale UI/no-op không được OTHER bù.
 * Output: checkpoint/finish chỉ nhận public enums/counters, không I/O hoặc credential.
 */
export function createAccessCheckpointOracle() {
  const stages = [['before-disabled', 0, 0, 0], ['disabled-rejected', 1, 0, 0], ['wrong-rejected', 2, 0, 0],
    ['empty-ready', 3, 1, 0], ['empty-refreshed', 3, 2, 0], ['logged-out', 3, 2, 1]];
  let position = 0;
  /**
   * Kiểm schema counter và exact số request ở boundary đã chọn.
   * Input
   * Param: counts — snapshot enum counters của proxy owned.
   * Param: login — số POST login phải đạt tại stage, không chấp nhận thiếu/thừa.
   * Param: workspace — số GET first-page workspace phải đạt độc lập OTHER.
   * Param: logout — số POST logout đúng stage; không coi password change hoặc UI rỗng là logout request.
   */
  function checkCounts(counts, login, workspace, logout) {
    assert.ok(counts && Object.keys(counts).length === 6, 'ACCESS_COUNTER_INVALID');
    for (const key of ['AUTH_LOGIN', 'AUTH_LOGOUT', 'PROFILE_READ', 'WORKSPACE_LIST', 'PASSWORD_CHANGE', 'OTHER']) {
      assert.ok(Number.isSafeInteger(counts[key]) && counts[key] >= 0, 'ACCESS_COUNTER_INVALID');
    }
    assert.equal(counts.AUTH_LOGIN, login, 'ACCESS_LOGIN_COUNT_INVALID');
    assert.equal(counts.WORKSPACE_LIST, workspace, 'ACCESS_WORKSPACE_COUNT_INVALID');
    assert.equal(counts.PASSWORD_CHANGE, 0, 'ACCESS_UNEXPECTED_PASSWORD_CHANGE');
    assert.equal(counts.AUTH_LOGOUT, logout, 'ACCESS_LOGOUT_COUNT_INVALID');
    if (workspace > 0) assert.ok(counts.PROFILE_READ > 0, 'ACCESS_PROFILE_CANARY_MISSING');
  }
  return {
    checkpoint:
      /**
       * Chỉ tiến sequence sau đúng stage và count; lỗi không tạo ACK cho native bước tiếp.
       * Input
       * Param: stage — enum checkpoint từ status native đang pause.
       * Param: counts — counter snapshot trước ACK, không phải cumulative count đổi baseline tùy ý.
       */
      (stage, counts) => {
        assert.ok(position < stages.length && stages[position][0] === stage, 'ACCESS_CHECKPOINT_ORDER_INVALID');
        checkCounts(counts, stages[position][1], stages[position][2], stages[position][3]); position++;
      },
    finish:
      /**
       * Không bỏ checkpoint hoặc request phát muộn sau lần UI cuối, cả trước/sau SDKstop.
       * Input
       * Param: counts — final counter snapshot cùng owned proxy.
       */
      (counts) => { assert.equal(position, stages.length, 'ACCESS_CHECKPOINT_INCOMPLETE'); checkCounts(counts, 3, 2, 1); },
  };
}

/**
 * Kiểm hai delta sau password ACK và new-login/logout, không đồng nhất revoke với session mới.
 * Input
 * Param: baseline — metadata account limited trước native login.
 * Param: changed — sau password204/clear ACK phải chỉ thêm1limitedUUID revoked.
 * Param: after — sau new login/logout phải chỉ thêm1newUUID revoked và giữ map changed.
 * Output: hai UUID distinct theo thứ tự tạo, không bearer/verifier.
 */
export function validatePasswordSessionDelta(baseline, changed, after) {
  const limited = validateAccessSessionDelta([], [], baseline, changed);
  if (after === undefined) return [limited];
  const full = validateAccessSessionDelta([], [], changed, after);
  assert.notEqual(limited, full, 'PASSWORD_SESSION_REUSED');
  return [limited, full];
}

/**
 * Gắn password stages với exact mutation/logout và limited allowlist, không nhận protected request như ACK hợp lệ.
 * Output: checkpoint và finishPhase giữ cùng sequence xuyên hai native process, không I/O/secrets.
 */
export function createPasswordCheckpointOracle() {
  const stages = [['password-before', 0, 0, 0, 0], ['limited-ready', 1, 0, 0, 0],
    ['invalid-short', 1, 0, 0, 0], ['invalid-uppercase', 1, 0, 0, 0], ['invalid-lowercase', 1, 0, 0, 0],
    ['invalid-digit', 1, 0, 0, 0], ['invalid-confirm', 1, 0, 0, 0], ['current-rejected', 1, 1, 0, 0], ['password-changed', 1, 2, 0, 0],
    ['relogin-before', 1, 2, 0, 0], ['old-rejected', 2, 2, 0, 0], ['new-empty', 3, 2, 1, 0], ['password-logout', 3, 2, 1, 1]];
  let position = 0;
  /**
   * Kiểm schema6enum và exact login/password/workspace/logout; limited không được gọi profile hoặc route ngoài allowlist.
   * Input
   * Param: counts — snapshot counters trước ACK, không có payload/request raw.
   * Param: expected — stage tuple chứa label và4count cố định của plan; password ACK không phát logout POST.
   */
  function check(counts, expected) {
    assert.ok(counts && Object.keys(counts).length === 6, 'PASSWORD_COUNTER_INVALID');
    for (const key of ['AUTH_LOGIN', 'AUTH_LOGOUT', 'PASSWORD_CHANGE', 'WORKSPACE_LIST', 'PROFILE_READ', 'OTHER']) {
      assert.ok(Number.isSafeInteger(counts[key]) && counts[key] >= 0, 'PASSWORD_COUNTER_INVALID');
    }
    assert.equal(counts.AUTH_LOGIN, expected[1], 'PASSWORD_LOGIN_COUNT_INVALID');
    assert.equal(counts.PASSWORD_CHANGE, expected[2], 'PASSWORD_MUTATION_COUNT_INVALID');
    assert.equal(counts.WORKSPACE_LIST, expected[3], 'PASSWORD_WORKSPACE_COUNT_INVALID');
    assert.equal(counts.AUTH_LOGOUT, expected[4], 'PASSWORD_LOGOUT_COUNT_INVALID');
    // OTHER gồm devices/realtime/control và mọi route lạ; password scenario không cần các request đó.
    assert.equal(counts.OTHER, 0, 'PASSWORD_UNEXPECTED_PROTECTED_REQUEST');
    if (expected[3] === 0) assert.equal(counts.PROFILE_READ, 0, 'PASSWORD_LIMITED_PROFILE_REQUEST');
    if (expected[3] > 0) assert.ok(counts.PROFILE_READ > 0, 'PASSWORD_PROFILE_CANARY_MISSING');
  }
  return {
    checkpoint:
      /**
       * Tiến đúng1stage sau counters hợp lệ, không chấp nhận bỏ stage/replay/out-of-order.
       * Input
       * Param: stage — fixed enum native đang pause.
       * Param: counts — observer snapshot trước ACK, không đổi baseline giữa các phase.
       */
      (stage, counts) => {
        assert.ok(position < stages.length && stages[position][0] === stage, 'PASSWORD_CHECKPOINT_ORDER_INVALID');
        check(counts, stages[position]); position++;
      },
    finishPhase:
      /**
       * Đóng mỗi phase đúng sequence và counters cả trước/sau SDKstop để bắt request muộn.
       * Input
       * Param: phase — password hoặc password-relogin, không default fallback.
       * Param: counts — snapshot cuối phase cùng proxy owned.
       */
      (phase, counts) => {
        assert.ok(['password', 'password-relogin'].includes(phase), 'INVALID_PASSWORD_PHASE');
        const expectedPosition = phase === 'password' ? 9 : 13;
        assert.equal(position, expectedPosition, 'PASSWORD_CHECKPOINT_INCOMPLETE');
        check(counts, stages[expectedPosition - 1]);
      },
  };
}

/**
 * Kiểm app.start do child SDK phát trước khi gửi packet; event giống shape không đủ ownership.
 * Input
 * Param: parameters — metadata app.start được parse từ owned stdout.
 * Output: appId hợp lệ; lỗi cố định nếu sai device/mode/directory/launch.
 */
export function validateOwnedApp(parameters) {
  assert.ok(parameters && typeof parameters.appId === 'string' &&
    /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(parameters.appId) &&
    parameters.deviceId === deviceId && parameters.mode === 'debug' && parameters.launchMode === 'run' &&
    typeof parameters.directory === 'string' &&
    path.resolve(parameters.directory).toLowerCase() === mobileDirectory.toLowerCase(),
  'NATIVE_DAEMON_OWNERSHIP_FAILED');
  return parameters.appId;
}

/**
 * Parse envelope SDK hữu hạn; output build thường bị bỏ qua, không coi text log là instruction.
 * Input
 * Param: line — một dòng owned stdout, tối đa64KiB.
 * Output: tối đa16message có event hoặc numeric response id; lỗi cố định không chứa dòng gốc.
 */
export function parseDaemonLine(line) {
  if (line.length > 65_536) throw new Error('NATIVE_DAEMON_PROTOCOL_FAILED');
  if (!line.startsWith('[')) return [];
  try {
    const messages = JSON.parse(line);
    if (!Array.isArray(messages) || messages.length > 16 || messages.some(
      /**
       * Không nhận scalar/arbitrary object làm response hoặc event có quyền điều khiển test.
       * Input
       * Param: message — envelope chưa tin cậy từ SDK output.
       */
      (message) => !message || typeof message !== 'object' || Array.isArray(message) ||
        (typeof message.event !== 'string' && !Number.isSafeInteger(message.id)))) throw new Error();
    return messages;
  } catch { throw new Error('NATIVE_DAEMON_PROTOCOL_FAILED'); }
}

/**
 * Chuẩn hóa ACK/status extension, không truyền raw trace/error input qua error boundary.
 * Input
 * Param: result — payload SDK trả, có thể trực tiếp hoặc bọc result theo tool version.
 * Output: map có accepted/status fixed; không nhận object error hoặc payload ngoài schema.
 */
export function normalizeExtensionResult(result) {
  const value = result?.result ?? result;
  if (!value || typeof value !== 'object' || Array.isArray(value) || value.error ||
    (typeof value.accepted !== 'boolean' && !['WAITING', 'PASS', 'FAIL'].includes(value.status))) {
    throw new Error('NATIVE_EXTENSION_RESULT_FAILED');
  }
  return value;
}

/**
 * Giữ control path cleanup hoạt động khi dữ liệu SDK lỗi, chỉ cho đúng hai command dừng.
 * Input
 * Param: state — terminal/boundaryFailed từ owned SDK observer.
 * Param: method — tên RPC do runner quyết định, không nhận từ fixture.
 * Param: cleanup — chỉ bật ở finally cho app.stop/daemon.shutdown.
 * Output: true nếu có thể gửi; không cho fixture/status sau boundary failure hoặc process terminal.
 */
export function canSendDaemonRequest(state, method, cleanup) {
  if (state.terminal || (cleanup && !['app.stop', 'daemon.shutdown'].includes(method))) return false;
  return !state.boundaryFailed || cleanup;
}

/** Chỉ dispatch checkpoint tới một callback sở hữu; không để phase UI pause không có oracle host. */
export function canHandleNativeCheckpoint(phase, callback) {
  return ['full', 'access', 'password', 'password-relogin', 'response-loss',
    'rate-limit', 'membership-stale', 'offline-login'].includes(phase) && typeof callback === 'function';
}

/** Fail closed nếu request/status counter ở picker không khớp allowlist trước lần chọn workspace đầu. */
export function validateNativePreselectionOracle(checkpoint, counts) {
  const keys = ['AUTH_LOGIN', 'AUTH_LOGOUT', 'PROFILE_READ', 'WORKSPACE_LIST', 'PASSWORD_CHANGE', 'OTHER'];
  assert.equal(checkpoint, 'workspace-picker-before-select', 'NATIVE_PRESELECTION_CHECKPOINT_INVALID');
  assert.ok(counts && typeof counts === 'object' && !Array.isArray(counts) && Object.keys(counts).length === keys.length && keys.every(
    (key) => Object.hasOwn(counts, key) && Number.isSafeInteger(counts[key]) && counts[key] >= 0), 'NATIVE_PRESELECTION_COUNTERS_INVALID');
  assert.equal(counts.AUTH_LOGIN, 1, 'NATIVE_PRESELECTION_LOGIN_COUNT_INVALID');
  assert.ok(counts.PROFILE_READ > 0, 'NATIVE_PRESELECTION_PROFILE_MISSING');
  assert.equal(counts.WORKSPACE_LIST, 1, 'NATIVE_PRESELECTION_WORKSPACE_COUNT_INVALID');
  assert.equal(counts.PASSWORD_CHANGE, 0, 'NATIVE_PRESELECTION_PASSWORD_CHANGE');
  assert.equal(counts.AUTH_LOGOUT, 0, 'NATIVE_PRESELECTION_LOGOUT');
  assert.equal(counts.OTHER, 0, 'NATIVE_DEVICE_OR_RESOURCE_REQUEST_BEFORE_PICKER');
  return true;
}

/**
 * Phân biệt spawn thất bại với lỗi kill/IPC sau spawn, không fake terminal khi SDK còn sống.
 * Input
 * Param: spawned — đã nhận event spawn của đúng child hay chưa.
 * Param: processId — PID do ChildProcess cấp, undefined khi chưa tạo process thành công.
 * Output: true chỉ khi chắc chắn chưa có process; post-spawn error vẫn phải chờ exit thật.
 */
export function isConfirmedSpawnFailure(spawned, processId) {
  return !spawned && processId === undefined;
}

/**
 * Giới hạn quan sát promise, không biến timeout thành terminal hoặc phản chiếu lỗi thô.
 * Input
 * Param: operation — operation/exit observer thuộc SDK runner.
 * Param: milliseconds — budget hữu hạn cho bước cleanup.
 * Output: settled/value nếu resolve, false nếu lỗi/quá hạn; promise gốc vẫn có handler để không unhandled.
 */
async function observeBounded(operation, milliseconds) {
  let timer;
  try {
    return await Promise.race([operation.then(
      /**
       * Chỉ operation resolve mới có giá trị ACK/exit thật.
       * Input
       * Param: value — kết quả operation đang được quan sát.
       */
      (value) => ({ settled: true, value })), new Promise(
      /**
       * Tách deadline quan sát khỏi trạng thái process để không tự tuyên bố đã dừng.
       * Input
       * Param: resolve — outcome unconfirmed khi hết budget.
       */
      (resolve) => { timer = setTimeout(/** Hết budget chỉ báo không xác nhận, không fake exit. */
        () => resolve({ settled: false }), milliseconds); })]);
  } catch { return { settled: false }; }
  finally { clearTimeout(timer); }
}

/**
 * Cleanup SDK trực tiếp sở hữu bằng các bước độc lập; lỗi protocol không được khóa shutdown channel.
 * Input
 * Param: child — handle process Dart SDK do runner spawn trực tiếp, không shell trung gian.
 * Param: getState — snapshot owned app/SDK, timeout không được sửa thành terminal.
 * Param: request — chỉ gửi fixed SDK commands với cleanup-only allowance.
 * Param: exit — promise actual SDK exit event, không phải observer timeout.
 * Param: budgetMilliseconds — deadline mỗi bước, test có thể giảm nhưng không vượt30s.
 * Output: sdkExited/exitCode/forced và snapshot cuối; unconfirmed luôn FAIL, không claim native-death.
 */
export async function shutdownNativeDaemon({ child, getState, request, exit, budgetMilliseconds = 30_000 }) {
  assert.ok(Number.isSafeInteger(budgetMilliseconds) && budgetMilliseconds > 0 && budgetMilliseconds <= 30_000);
  let forced = false;
  if (getState().appId && !getState().terminal) {
    await observeBounded(request('app.stop', { appId: getState().appId }, true), budgetMilliseconds);
  }
  if (!getState().terminal) {
    await observeBounded(request('daemon.shutdown', {}, true), budgetMilliseconds);
  }
  let observed = await observeBounded(exit, budgetMilliseconds);
  if (!observed.settled) {
    forced = true;
    // Chỉ kill đúng Dart handle đã spawn; không kill theo PID lấy từ log hoặc enumerate descendant.
    child.kill();
    observed = await observeBounded(exit, Math.min(budgetMilliseconds, 5_000));
  }
  child.stdin.destroy(); child.stdout.destroy(); child.stderr.destroy();
  if (!observed.settled) child.unref();
  return { sdkExited: observed.settled, exitCode: observed.value, forced, ...getState() };
}

/**
 * Chạy C0 trên Android qua daemon SDK, chưa khởi tạo proxy/DB hoặc credential fixture thật.
 * Side effects: build/install integration target rồi stop đúng app; không uninstall/reset storage.
 */
async function runPreflight() {
  const runId = randomUUID();
  const packet = { version: 1, phase: 'preflight',
    emails: Array.from({ length: 5 },
      /**
       * Tạo namespace synthetic không trùng account thật, không provisioning trong C0.
       * Input
       * Param: value — phần tử chưa dùng của array tạo mới.
       * Param: index — thứ tự fixture0–4.
       */
      (value, index) => `probe-${runId}-${index}@example.invalid`),
    password: `Aa1${randomBytes(16).toString('hex')}` };
  await runNativePhase(packet);
}

/**
 * Chạy một phase native bằng kênh C0 đã kiểm, chỉ public TLS config được đưa vào compiler args.
 * Input
 * Param: packet — fixture one-shot RAM; resume bắt buộc password rỗng, không login mới.
 * Param: certificate — public DER Base64 của proxy, không private PFX.
 * Param: onPassed — trusted oracle host; rate nhận thêm admission fence, phải kiểm trước/sau I/O và trước mọi effect.
 * Param: sensitivePassword — secret gốc hoặc list cũ/mới để scan mọi phase dù packet không còn password.
 * Param: onCheckpoint — rate/access/password sync oracle, membership cho phép async owned SQL trước ACK.
 * Param: runtime — trusted SDK/clock/pause và sync onPhaseClosing(phasePassed) cleanup intent; actual deadlines thuộc owner.
 * Output: native PID đã framework PASS; chỉ return sau app.stop và SDK exit0.
 */
export async function runNativePhase(packet, certificate, onPassed, sensitivePassword = packet.password, onCheckpoint, runtime = {}) {
  const phaseBudget = nativePhaseBudget(packet.phase);
  assert.ok(runtime.onPhaseClosing === undefined || typeof runtime.onPhaseClosing === 'function', 'NATIVE_PHASE_CLOSING_HOOK_INVALID');
  const membership = packet.phase === 'membership-stale';
  const offline = packet.phase === 'offline-login';
  const asyncCheckpoints = membership || offline;
  const controlled = packet.phase === 'rate-limit' || asyncCheckpoints;
  const sourceNow = runtime.now ?? performance.now.bind(performance);
  let lastOfflineNow = 0;
  const monotonicNow = offline ?
    /** Clock offline phải hữu hạn/không lùi xuyên pre-ARM và main; lỗi không được reset deadline để retry. */
    () => {
      const current = sourceNow();
      assert.ok(Number.isFinite(current) && current >= lastOfflineNow, 'NATIVE_OFFLINE_CLOCK_INVALID');
      lastOfflineNow = current;
      return current;
    } : sourceNow;
  const pause = runtime.pause ?? delay;
  const spawnNativeProcess = runtime.spawnNativeProcess ?? spawn;
  const checkPid = runtime.checkPid ?? assertNativePid;
  const workDeadline = runtime.workDeadline;
  const rateEvidence = packet.phase === 'rate-limit' ? runtime.rateEvidence : undefined;
  let rateEvidenceSealed = false;
  // Rate dùng ARM deadline, membership dùng spawn-anchored fixture work deadline, không nhận từ packet/CLI.
  if (asyncCheckpoints) {
    assert.ok(typeof onCheckpoint === 'function' && typeof onPassed === 'function', 'NATIVE_MEMBERSHIP_CALLBACK_REQUIRED');
    assert.ok(runtime.externalSignal === undefined || runtime.externalSignal instanceof AbortSignal, 'NATIVE_MEMBERSHIP_SIGNAL_INVALID');
    assert.ok(runtime.assertExternalActive === undefined || typeof runtime.assertExternalActive === 'function', 'NATIVE_MEMBERSHIP_LIFETIME_INVALID');
  }
  assert.ok(offline ? typeof runtime.beforePacket === 'function' : runtime.beforePacket === undefined,
    'NATIVE_OFFLINE_PREPARATION_REQUIRED');
  if (controlled) requireWorkBudget(workDeadline, phaseBudget.reserveMilliseconds, monotonicNow());
  rateEvidence?.assertActive();
  const preArmDeadline = offline ? monotonicNow() + 240_000 : undefined;
  const rateStartupDeadline = controlled ? monotonicNow() + (asyncCheckpoints ? 180_000 : 360_000) : undefined;
  let preArmPending;
  let preArmSettled = true;
  let preArmClosed = false;
  let rateChannelDeadline = preArmDeadline;
  let ratePhaseDeadline;
  let rateCheckpointDeadline;
  let rateCheckpointClosed = true;
  let rateCheckpointPending;
  let rateCheckpointPendingSettled = true;
  // Giữ tên state legacy để giới hạn diff, controlled membership có sequence/cap riêng.
  const offlineCaps = { 'offline-ready': 110_000, 'offline-result': 110_000,
    'offline-quiet': 170_000, 'offline-picker': 170_000, 'offline-logged-out': 5000 };
  const rateCheckpointStages = offline ? Object.keys(offlineCaps) : membership ? [
    'membership-before-login', 'membership-picker', 'membership-denied',
    'membership-only-a', 'membership-a-opened', 'membership-logged-out',
  ] : ['rate-before', 'rate-wrong-1', 'rate-wrong-2', 'rate-wrong-3', 'rate-wrong-4',
    'rate-wrong-5', 'rate-limited', 'rate-mid-cooldown', 'rate-expired', 'rate-login', 'rate-logout'];
  let rateCheckpointIndex = 0;
  const sensitiveSecrets = Array.isArray(sensitivePassword) ? sensitivePassword : [sensitivePassword];
  containsNativeSecret('', sensitiveSecrets);
  const secretTailLength = Math.max(...sensitiveSecrets.map(
    /**
     * Giữ đủ tail của secret dài nhất để scanner bắt match bị chia qua chunk boundary.
     * Input
     * Param: value — synthetic credential đã validate shape, không xuất khỏi RAM.
     */
    (value) => value.length));
  const publicArguments = packet.phase === 'preflight' ? [] : [
    '--dart-define=AUTH_API_BASE_URL=https://10.0.2.2:8443', `--dart-define=AUTH_LAB_CA_CERT=${certificate}`];
  // Baseline vắng mặt là admission, không phải quyền kill process khác hoặc khóa liên tiến trình.
  if (asyncCheckpoints) assertNativeTiming();
  checkPid(null);
  if (controlled) requireWorkBudget(workDeadline, phaseBudget.reserveMilliseconds, monotonicNow());
  rateEvidence?.assertActive();
  if (asyncCheckpoints) assertNativeTiming();
  // Giống invocation Dart trong Flutterbat chính thức sau bootstrap; direct handle tránh orphan shell.
  const startupDiagnostics = createNativeStartupDiagnostics();
  const child = spawnNativeProcess('C:/src/flutter/bin/cache/dart-sdk/bin/dart.exe',
    ['--packages=C:/src/flutter/packages/flutter_tools/.dart_tool/package_config.json',
      'C:/src/flutter/bin/cache/flutter_tools.snapshot', '--suppress-analytics', 'run', '--no-pub',
      '--machine', '-d', deviceId, '-t', 'integration_test/app_auth_e2e_test.dart',
      `--dart-define=AUTH_E2E_PHASE=${packet.phase}`, '--dart-define=INTEGRATION_TEST_SHOULD_REPORT_RESULTS_TO_NATIVE=false', ...publicArguments],
    { cwd: mobileDirectory, shell: false, windowsHide: true, stdio: ['pipe', 'pipe', 'pipe'] });
  const pending = new Map();
  let appId;
  let started = false;
  let channelReady = false;
  let stopped = false;
  let terminal = false;
  let spawned = false;
  let boundaryFailed = false;
  let boundaryReason = 'NONE';
  let sequence = 0;
  let buffer = '';
  let errorTail = '';
  const done = new Promise(
    /**
     * Quan sát Dart SDK exit thật, không dùng timeout hoặc app.log như terminal ACK/native-death.
     * Input
     * Param: resolve — trả actual exit code của owned SDK process.
     */
    (resolve) => {
      child.on('spawn', /** Ghi sự kiện tạo process thật, không suy từ intent hoặc timeout. */
        () => { spawned = true; });
      child.on('error', /** Chỉ confirmed pre-spawn failure mới không có SDK để đợi; lỗi kill/IPC không là terminal. */
        () => {
          boundaryFailed = true;
          if (isConfirmedSpawnFailure(spawned, child.pid)) { terminal = true; resolve(null); }
        });
      child.on('exit',
        /**
         * Giải phóng mọi pending RPC bằng fixed error và ghi terminal của đúng child.
         * Input
         * Param: code — actual exit code, null nếu SDK bị signal/kill.
         */
        (code, signal) => {
          startupDiagnostics.exit(code, signal);
          terminal = true;
          for (const request of pending.values()) { clearTimeout(request.timer); request.reject(new Error('NATIVE_DAEMON_CLOSED')); }
          pending.clear(); resolve(code);
        });
    });
  child.on('close', () => startupDiagnostics.pipesClosed());
  if (runtime.captureSdkExit) runtime.captureSdkExit(done);
  /** Snapshot failure phải đánh thức pending RPC ngay; cleanup RPC vẫn giữ khả năng dừng owned SDK. */
  function abortEvidenceRequests() {
    for (const [id, operation] of pending) {
      if (!operation.cleanup) {
        clearTimeout(operation.timer); pending.delete(id); operation.reject(new Error('NATIVE_RATE_EVIDENCE_UNAVAILABLE'));
      }
    }
  }
  rateEvidence?.signal.addEventListener('abort', abortEvidenceRequests);
  if (rateEvidence?.signal.aborted) abortEvidenceRequests();
  if (asyncCheckpoints) {
    runtime.externalSignal?.addEventListener('abort', abortEvidenceRequests);
    if (runtime.externalSignal?.aborted) abortEvidenceRequests();
  }
  child.stdout.on('data',
    /**
     * Đọc owned SDK pipe trong RAM, chỉ giữ dòng chưa đủ và discard toàn raw log sau parse.
     * Input
     * Param: chunk — stdout bytes của Flutter daemon, không forward trực tiếp.
     */
    (chunk) => {
      try {
        runtime.onOutput?.('stdout', chunk);
        buffer += chunk.toString('utf8');
        if (containsNativeSecret(buffer, sensitiveSecrets)) throw new Error('SECRET_ECHO');
        let newline;
        while ((newline = buffer.indexOf('\n')) !== -1) {
          const line = buffer.slice(0, newline).replace(/\r$/, ''); buffer = buffer.slice(newline + 1);
          startupDiagnostics.rawLine(line);
          // SDK version có thể bọc marker trong app.log hoặc in raw; marker chỉ cho phép status probe, chưa cấp fixture.
          if (appId && line.includes('NATIVE_AUTH_TEST_CHANNEL_READY')) channelReady = true;
          let messages;
          try { messages = parseDaemonLine(line); }
          catch {
            // Chỉ phân loại dạng framing, không xuất prefix/raw log có thể chứa dữ liệu SDK nhạy cảm.
            boundaryReason = line.startsWith('[{') ? 'MALFORMED_ENVELOPE' : 'BRACKET_OUTPUT';
            throw new Error('NATIVE_DAEMON_PROTOCOL_FAILED');
          }
          for (const message of messages) {
            if (message.event === 'app.start') {
              if (appId) throw new Error('DUPLICATE_APP');
              appId = validateOwnedApp(message.params);
            } else if (message.event === 'app.started') {
              if (!appId || message.params?.appId !== appId) throw new Error('WRONG_APP');
              started = true;
            } else if (message.event === 'app.stop' && message.params?.appId === appId) stopped = true;
            else if (message.event === 'app.log' && message.params?.appId === appId &&
              typeof message.params.log === 'string' && message.params.log.endsWith('NATIVE_AUTH_TEST_CHANNEL_READY')) channelReady = true;
            else if (pending.has(message.id)) {
              const request = pending.get(message.id); pending.delete(message.id); clearTimeout(request.timer);
              if (message.error) {
                // Chỉ phân loại pattern SDK đã biết, không in raw error/trace hoặc dữ liệu packet.
                const sdkError = typeof message.error === 'string' ? message.error : JSON.stringify(message.error);
                const reason = /method not available|Method not found|not registered/i.test(sdkError) ? 'EXTENSION_MISSING' :
                  /uiIsolate|No element|Null check operator|null.*value/i.test(sdkError) ? 'ISOLATE_NOT_READY' :
                  /ext\.flutter|startsWith|Assertion failed/i.test(sdkError) ? 'FLUTTER_PREFIX_REQUIRED' : 'UNCLASSIFIED';
                console.error(`NATIVE_DAEMON_RPC_${reason}`);
                request.reject(new Error('NATIVE_DAEMON_RPC_FAILED'));
              }
              else request.resolve(message.result);
            }
            startupDiagnostics.message(message, appId);
          }
        }
        if (buffer.length > 65_536) throw new Error('OVERSIZE_LINE');
      } catch (error) {
        boundaryFailed = true; buffer = '';
        if (boundaryReason === 'NONE') boundaryReason = ['SECRET_ECHO', 'OVERSIZE_LINE', 'DUPLICATE_APP', 'WRONG_APP',
          'NATIVE_DAEMON_OWNERSHIP_FAILED'].includes(error.message) ? error.message : 'OUTPUT_BOUNDARY';
      }
    });
  child.stderr.on('data',
    /**
     * Chỉ scan secret echo với tail hữu hạn, không giữ hoặc log stderr SDK.
     * Input
     * Param: chunk — captured stderr của owned SDK child.
     */
    (chunk) => {
      try { runtime.onOutput?.('stderr', chunk); } catch { boundaryFailed = true; boundaryReason = 'OUTPUT_OBSERVER_FAILED'; }
      const current = errorTail + chunk.toString('utf8');
      if (containsNativeSecret(current, sensitiveSecrets)) { boundaryFailed = true; boundaryReason = 'SECRET_ECHO'; }
      else startupDiagnostics.stderr(chunk.toString('utf8'));
      errorTail = current.slice(-secretTailLength);
    });
  child.stdin.on('error', /** Pipe đóng phải làm gate thất bại, không in request chứa packet. */
    () => { boundaryFailed = true; boundaryReason = 'STDIN_ERROR'; });

  /** Kiểm active scopes sau mỗi await rate/membership; timeout không chứng minh I/O terminal hoặc mở work mới. */
  function assertNativeTiming() {
    if (asyncCheckpoints) {
      assert.ok(!runtime.externalSignal?.aborted, 'NATIVE_MEMBERSHIP_EXTERNAL_UNAVAILABLE');
      runtime.assertExternalActive?.();
    }
    if (rateEvidence && !rateEvidenceSealed) rateEvidence.assertActive();
    if (controlled) calculateNativeRpcDeadline({ workDeadline, channelDeadline: rateChannelDeadline, phaseDeadline: ratePhaseDeadline,
      checkpointDeadline: rateCheckpointDeadline }, monotonicNow());
  }

  /**
   * Gửi RPC qua pipe riêng; timeout là unknown, không tự retry fixture mutation.
   * Input
   * Param: method — command SDK cố định do runner gọi.
   * Param: params — appId/extension arguments trong RAM, không log.
   * Param: cleanup — chỉ fixed stop/shutdown được phép vượt boundary failure trong finally.
   * Output: SDK result trước min30s/active rate hoặc membership scopes, cleanup giữ allowance riêng hiện hữu.
   */
  function request(method, params = {}, cleanup = false) {
    if (!canSendDaemonRequest({ terminal, boundaryFailed }, method, cleanup)) {
      return Promise.reject(new Error('NATIVE_DAEMON_UNAVAILABLE'));
    }
    let rpcDeadline;
    if (controlled && !cleanup) {
      try {
        rateEvidence?.assertActive();
        rpcDeadline = calculateNativeRpcDeadline({ workDeadline, channelDeadline: rateChannelDeadline, phaseDeadline: ratePhaseDeadline,
          checkpointDeadline: rateCheckpointDeadline }, monotonicNow());
      } catch { return Promise.reject(new Error('NATIVE_DAEMON_RPC_TIMEOUT')); }
    }
    const id = ++sequence;
    return new Promise(
      /**
       * Gắn pending trước write để không bỏ ACK nhanh; mỗi request có deadline riêng.
       * Input
       * Param: resolve — nhận result từ đúng id.
       * Param: reject — lỗi cố định, không bao gồm raw params hoặc SDK trace.
       */
      (resolve, reject) => {
        const milliseconds = rpcDeadline === undefined ? 30_000 : rpcDeadline - monotonicNow();
        if (!(milliseconds > 0)) { reject(new Error('NATIVE_DAEMON_RPC_TIMEOUT')); return; }
        const timer = setTimeout(/** Không coi RPC timeout là mutation chưa được thực hiện. */
          () => { pending.delete(id); reject(new Error('NATIVE_DAEMON_RPC_TIMEOUT')); }, milliseconds);
        pending.set(id, { reject, timer, cleanup,
          resolve:
            /**
             * Reply muộn phải reject ngay cả khi event loop chưa chạy timer; không throw vào parser làm mất pending.
             * Input
             * Param: value — result của đúng request id từ owned SDK, không log.
             */
            (value) => {
              const current = rpcDeadline === undefined ? undefined : monotonicNow();
              if (rpcDeadline !== undefined && (!Number.isFinite(current) || current >= rpcDeadline)) reject(new Error('NATIVE_DAEMON_RPC_TIMEOUT'));
              else resolve(value);
            },
        });
        try {
          if (rpcDeadline !== undefined && monotonicNow() >= rpcDeadline) throw new Error('NATIVE_DAEMON_RPC_TIMEOUT');
          child.stdin.write(JSON.stringify([{ id, method, params }]) + '\n');
        } catch {
          // Guard/write lỗi không giữ timer hoặc pending entry, cũng không đưa raw pipe error/packet ra caller.
          clearTimeout(timer); pending.delete(id); reject(new Error('NATIVE_DAEMON_UNAVAILABLE'));
        }
      });
  }

  /**
   * Chỉ gọi test extensions cố định sau app ownership; checkpoint chỉ dành access đang pause.
   * Input
   * Param: name — fixture/status hoặc checkpoint access do runner hardcode.
   * Param: parameters — packet RAM hoặc map rỗng cho status.
   * Output: fixed ACK/status đã chuẩn hóa.
   */
  async function extension(name, parameters = {}) {
    assert.ok(['fixture', 'status'].includes(name) || (name === 'checkpoint' && canHandleNativeCheckpoint(packet.phase, onCheckpoint)));
    assertNativeTiming();
    const result = normalizeExtensionResult(await request('app.callServiceExtension',
      { appId, methodName: `ext.nexa_auth_test.${name}`, params: parameters }));
    assertNativeTiming();
    return result;
  }

  let passed = false;
  let phaseFailed = false;
  let phaseClosingFailed = false;
  let phaseClosingSettled = true;
  let phaseClosingObservation;
  let nativeProcessId;
  let initialNativeProcessId;
  let stage = 'startup';
  let rateOraclePromise;
  let rateOracleSettled = true;
  let rateOracleFailed = false;
  let rateOracleClosed = false;
  try {
    const startupDeadline = controlled ? rateStartupDeadline : Date.now() + 6 * 60_000;
    while (!started && !terminal && !boundaryFailed && (controlled ? monotonicNow() : Date.now()) < startupDeadline) {
      assertNativeTiming(); await pause(100); assertNativeTiming();
    }
    assert.ok(started && !boundaryFailed && !terminal && (!controlled || monotonicNow() < startupDeadline), 'NATIVE_DAEMON_START_FAILED');
    assertNativeTiming();
    stage = 'channel';
    if (controlled) rateChannelDeadline = offline ? preArmDeadline : monotonicNow() + 60_000;
    const channelDeadline = (controlled ? monotonicNow() : Date.now()) + 10_000;
    while (!channelReady && !terminal && !boundaryFailed && (controlled ? monotonicNow() : Date.now()) < channelDeadline) {
      assertNativeTiming(); await pause(50); assertNativeTiming();
    }
    assert.ok(channelReady && !terminal && !boundaryFailed && (!controlled || monotonicNow() < channelDeadline), 'NATIVE_CHANNEL_NOT_REGISTERED');
    assertNativeTiming();
    stage = 'status';
    const initialStatusStarted = offline ? monotonicNow() : undefined;
    const initial = await extension('status');
    assert.equal(initial.phase, packet.phase); assert.equal(initial.status, 'WAITING');
    if (asyncCheckpoints) {
      assert.ok(Number.isSafeInteger(initial.nativeProcessId) && initial.nativeProcessId > 0, 'NATIVE_MEMBERSHIP_PID_INVALID');
      initialNativeProcessId = initial.nativeProcessId;
    }
    if (offline) {
      stage = 'prepare';
      assert.ok(Number.isSafeInteger(initial.preArmRemainingMilliseconds) && initial.preArmRemainingMilliseconds > 0 &&
        initial.preArmRemainingMilliseconds <= 240_000, 'NATIVE_OFFLINE_PREARM_INVALID');
      // Native remaining neo từ status send, không cộng response latency hoặc tạo fresh240s từ callback.
      rateChannelDeadline = Math.min(rateChannelDeadline, initialStatusStarted + initial.preArmRemainingMilliseconds);
      const prepareDeadline = rateChannelDeadline;
      const admission = Object.freeze({ assertActive:
        /** Guard captured trước callback; baseline còn pending không được gửi packet hoặc làm effect tới muộn. */
        () => {
          assert.ok(!preArmClosed && !terminal && !boundaryFailed && monotonicNow() < prepareDeadline,
            'NATIVE_OFFLINE_PREARM_UNAVAILABLE');
          assertNativeTiming();
        } });
      let preparationFailed = false;
      preArmSettled = false;
      preArmPending = Promise.resolve().then(
        /** Gắn owner trước callback có thể throw/settle ngay; original baseline Future vẫn do orchestrator giữ. */
        async () => { admission.assertActive(); await runtime.beforePacket(admission); admission.assertActive(); }).then(
        /** Chỉ completion thật mới nhả pending, timeout không hủy SQL hoặc cấp cleanup proof. */
        () => { preArmSettled = true; },
        /** Không forward raw baseline/SDK diagnostics vào output. */
        () => { preArmSettled = true; preparationFailed = true; });
      try {
        while (!preArmSettled && !terminal && !boundaryFailed && monotonicNow() < prepareDeadline) {
          assertNativeTiming(); await pause(50); assertNativeTiming();
        }
        admission.assertActive();
        assert.ok(preArmSettled && !preparationFailed, 'NATIVE_OFFLINE_PREARM_UNAVAILABLE');
      } finally { preArmClosed = true; }
    }
    stage = 'malformed';
    assert.equal((await extension('fixture', { packet: '{}' })).accepted, false);
    stage = 'fixture';
    if (offline) requireWorkBudget(workDeadline, 910_000, monotonicNow());
    // Native có thể bắt đầu trước host nhận ACK; controlled cap neo trước valid fixture RPC, replay không reset.
    if (controlled) {
      const phaseAnchor = monotonicNow();
      ratePhaseDeadline = rateEvidence ? rateEvidence.phaseStarted(phaseAnchor) : phaseAnchor + phaseBudget.testMilliseconds;
    }
    assert.equal((await extension('fixture', { packet: JSON.stringify(packet) })).accepted, true);
    stage = 'replay';
    assert.equal((await extension('fixture', { packet: JSON.stringify(packet) })).accepted, false);
    assertNativeTiming();
    if (controlled) rateChannelDeadline = undefined;
    stage = 'result';
    const testDeadline = controlled ? ratePhaseDeadline : Date.now() + phaseBudget.testMilliseconds;
    const acknowledged = new Set();
    let status;
    do {
      const statusRequestStarted = controlled ? monotonicNow() : undefined;
      status = await extension('status');
      if (controlled) {
        // Request id đúng chưa đủ: status phải thuộc chính phase hiện hành trước callback, ACK hoặc PASS.
        assert.equal(status.phase, packet.phase, 'NATIVE_RATE_STATUS_PHASE_MISMATCH');
        if (asyncCheckpoints) assert.equal(status.nativeProcessId, initialNativeProcessId, 'NATIVE_MEMBERSHIP_PID_MISMATCH');
        const hasCheckpoint = Object.hasOwn(status, 'checkpoint');
        const hasRemaining = Object.hasOwn(status, 'checkpointRemainingMilliseconds');
        assert.ok(hasCheckpoint === hasRemaining, 'NATIVE_RATE_CHECKPOINT_INVALID');
        if (hasCheckpoint) {
          assert.ok(status.status === 'WAITING' && status.checkpoint === rateCheckpointStages[rateCheckpointIndex]
            && Number.isSafeInteger(status.checkpointRemainingMilliseconds) && status.checkpointRemainingMilliseconds > 0
            && status.checkpointRemainingMilliseconds <= (offline ? offlineCaps[status.checkpoint] : membership && status.checkpoint === 'membership-picker' ? 210_000 : 5000) && typeof onCheckpoint === 'function', 'NATIVE_RATE_CHECKPOINT_INVALID');
          // Neo remaining từ status send time để không cộng latency vào cap5s hoặc picker210s.
          rateCheckpointDeadline = Math.min(statusRequestStarted + status.checkpointRemainingMilliseconds, workDeadline, ratePhaseDeadline);
          rateCheckpointClosed = false;
          let checkpointClosed = false;
          const checkpointDeadline = rateCheckpointDeadline;
          const admission = Object.freeze({
            assertActive:
              /** Fence capture bất biến, sync rate hoặc async membership đều phải guard trước/sau I/O và trước effect. */
              () => {
                assert.ok(!checkpointClosed && !rateCheckpointClosed && !terminal && !boundaryFailed && monotonicNow() < checkpointDeadline,
                  'NATIVE_RATE_CHECKPOINT_UNAVAILABLE');
                assertNativeTiming();
              },
          });
          try {
            admission.assertActive();
            const result = onCheckpoint(status.checkpoint, admission);
            if (asyncCheckpoints) {
              // Callback SQL có thể pending sau deadline. Gắn handlers ngay và giữ ownership tới completion thật.
              let callbackFailed = false;
              rateCheckpointPendingSettled = false;
              rateCheckpointPending = Promise.resolve(result).then(
                /** Chỉ completion thật mới đóng pending, không dùng deadline làm settled. */
                () => { rateCheckpointPendingSettled = true; },
                /** Giữ fixed failure flag, không forward raw SQL/fixture error vào SDK logs. */
                () => { rateCheckpointPendingSettled = true; callbackFailed = true; });
              while (!rateCheckpointPendingSettled && !terminal && !boundaryFailed && monotonicNow() < checkpointDeadline) {
                assertNativeTiming(); await pause(50); assertNativeTiming();
              }
              admission.assertActive();
              assert.ok(rateCheckpointPendingSettled && !callbackFailed, 'NATIVE_MEMBERSHIP_CHECKPOINT_UNAVAILABLE');
              // Sáu malformed/valid/replay RPC chia sẻ30s, không cấp30s riêng cho từng ACK trong picker210s.
              rateCheckpointDeadline = Math.min(rateCheckpointDeadline, monotonicNow() + 30_000);
            } else if (result !== undefined) {
              checkpointClosed = true;
              rateCheckpointClosed = true;
              // Callback async trái hợp đồng vẫn cần handler/ownership; getter lỗi không được log raw value.
              if (result !== null && (typeof result === 'object' || typeof result === 'function')) {
                const then = result.then;
                if (typeof then === 'function') {
                  rateCheckpointPendingSettled = false;
                  rateCheckpointPending = new Promise(
                    /** Giữ đúng then capability đọc một lần, không gọi lại getter hoặc giả I/O cancellation. */
                    (resolve, reject) => { then.call(result, resolve, reject); }).then(
                    /** Completion thật của invalid callback mới cho phép outer runner trả failure sau SDK cleanup. */
                    () => { rateCheckpointPendingSettled = true; },
                    /** Lọc late error và gắn handler ngay để không unhandled hoặc phản chiếu callback input. */
                    () => { rateCheckpointPendingSettled = true; });
                }
              }
              throw new Error('NATIVE_RATE_CHECKPOINT_CALLBACK_INVALID');
            }
            admission.assertActive();
            assert.equal((await extension('checkpoint', {})).accepted, false);
            assert.equal((await extension('checkpoint', { stage: 'invalid' })).accepted, false);
            assert.equal((await extension('checkpoint', { stage: status.checkpoint === 'rate-before' ? 'rate-logout' : 'rate-before' })).accepted, false);
            assert.equal((await extension('checkpoint', { stage: status.checkpoint, extra: 'invalid' })).accepted, false);
            assert.equal((await extension('checkpoint', { stage: status.checkpoint })).accepted, true);
            assert.equal((await extension('checkpoint', { stage: status.checkpoint })).accepted, false);
            admission.assertActive();
            rateCheckpointIndex++;
          } finally {
            // Fence stage đóng vĩnh viễn, stage sau không mở lại guard hoặc pending I/O cũ.
            checkpointClosed = true;
            rateCheckpointClosed = true;
            rateCheckpointDeadline = undefined;
          }
          // Chỉ sau6ACK thành công và fence5s đã đóng mới được bắt đầu snapshot ngoài UI pause.
          rateEvidence?.released(status.checkpoint);
        }
        if (status.status === 'PASS') assert.equal(rateCheckpointIndex, rateCheckpointStages.length, 'NATIVE_RATE_CHECKPOINT_INCOMPLETE');
      } else if (status.status === 'WAITING' && status.checkpoint && !acknowledged.has(status.checkpoint)) {
        assert.ok(canHandleNativeCheckpoint(packet.phase, onCheckpoint), 'UNEXPECTED_NATIVE_CHECKPOINT');
        // Native dừng trước bước tiếp; counts phải đúng trước ACK nên request ngoài stage không bù được thiếu intent.
        onCheckpoint(status.checkpoint);
        assert.equal((await extension('checkpoint', {})).accepted, false);
        assert.equal((await extension('checkpoint', { stage: 'invalid' })).accepted, false);
        assert.equal((await extension('checkpoint', { stage: status.checkpoint === 'logged-out' ? 'before-disabled' : 'logged-out' })).accepted, false);
        assert.equal((await extension('checkpoint', { stage: status.checkpoint, extra: 'invalid' })).accepted, false);
        assert.equal((await extension('checkpoint', { stage: status.checkpoint })).accepted, true);
        assert.equal((await extension('checkpoint', { stage: status.checkpoint })).accepted, false);
        acknowledged.add(status.checkpoint);
      }
      if (status.status === 'WAITING') await pause(100);
      assertNativeTiming();
    }
    while (status.status === 'WAITING' && (controlled ? monotonicNow() : Date.now()) < testDeadline);
    if (status.status === 'FAIL' && ['fixture', 'no-ca', 'main', 'login', 'picker', 'workspace-a', 'workspace-b', 'logout', 'teardown',
      'before-disabled', 'disabled-rejected', 'wrong-rejected', 'empty-ready', 'empty-refreshed', 'logged-out',
      'password-before', 'limited-ready', 'invalid-short', 'invalid-uppercase', 'invalid-lowercase', 'invalid-digit', 'invalid-confirm',
      'current-rejected', 'password-changed', 'relogin-before', 'old-rejected', 'new-empty', 'password-logout',
      'validation-reset', 'validation-fill', 'validation-before', 'validation-submit', 'validation-result',
      'auth-submit', 'membership-select', 'workspace-refresh', 'session-logout', 'auth-recover', 'offline-select', 'session-back', ...rateCheckpointStages].includes(status.caseStage)) {
      console.error(`NATIVE_CASE_STAGE_${status.caseStage.toUpperCase().replaceAll('-', '_')}_FAILED`);
      if (['NONE', 'BOTH', 'LENGTH_ONLY', 'TARGET_ONLY', 'NEITHER'].includes(status.validationObservation)) {
        console.error(`NATIVE_VALIDATION_OBSERVATION_${status.validationObservation}`);
      }
      // Chẩn đoán tap chỉ dùng enum đóng; raw exception, key và nội dung form không được qua stdout.
      if (['NONE', 'WAIT', 'SCROLL', 'SETTLE', 'DEADLINE', 'TAP', 'PUMP', 'DONE'].includes(status.tapStage) &&
          ['NONE', 'TIMEOUT', 'FLUTTER', 'OTHER'].includes(status.tapFailure) &&
          ['NONE', 'MISS', 'HIT'].includes(status.tapHit)) {
        console.error(`NATIVE_TAP_${status.tapStage}_${status.tapFailure}_${status.tapHit}`);
      }
    }
    assert.ok((controlled ? monotonicNow() < testDeadline : Date.now() <= testDeadline), 'NATIVE_PHASE_BUDGET_EXCEEDED');
    assert.equal(status.status, 'PASS'); assert.ok(Number.isSafeInteger(status.nativeProcessId) && status.nativeProcessId > 0);
    rateEvidence?.passed();
    // Chỉ UI framework PASS đã kiểm đúng hạn mới kết thúc native cap; work deadline vẫn bao oracle/SDK stop.
    if (controlled) ratePhaseDeadline = undefined;
    nativeProcessId = status.nativeProcessId;
    stage = 'oracle';
    if (onPassed && controlled) {
      // Dành SDK cleanup95s và hai post-SDK PID queries10s; timeout không cancel raw SQL.
      const oracleDeadline = asyncCheckpoints ? Math.min(monotonicNow() + 130_000, workDeadline - 105_000) : workDeadline - 105_000;
      const admission = Object.freeze({
        assertActive:
          /** Fence giữ deadline bất biến; trusted callback phải gọi sau await và trước request/effect để chặn late work. */
          () => { assert.ok(!rateOracleClosed && !terminal && !boundaryFailed && monotonicNow() < oracleDeadline, 'NATIVE_RATE_ORACLE_UNAVAILABLE'); },
      });
      admission.assertActive();
      rateOracleSettled = false;
      // Attach cả resolve/reject handler ngay; late rejection không unhandled hoặc phản chiếu raw oracle error.
      rateOraclePromise = Promise.resolve().then(
        /** Quan sát cùng callback I/O với fence trước/sau await, không coi deadline là cancellation. */
        async () => { admission.assertActive(); await onPassed(nativeProcessId, admission); admission.assertActive(); }).then(
        /** Chỉ completion thật của oracle mới đóng pending ownership, không lấy timeout làm settled. */
        () => { rateOracleSettled = true; },
        /** Ghi fixed failure flag, không giữ/forward exception hoặc dữ liệu oracle. */
        () => { rateOracleSettled = true; rateOracleFailed = true; });
      while (!rateOracleSettled && !terminal && !boundaryFailed && monotonicNow() < oracleDeadline) {
        assertNativeTiming(); await pause(50); assertNativeTiming();
      }
      if (!rateOracleSettled) {
        rateOracleClosed = true;
        throw new Error('NATIVE_RATE_ORACLE_UNAVAILABLE');
      }
      admission.assertActive();
      assert.equal(rateOracleFailed, false, 'NATIVE_RATE_ORACLE_UNAVAILABLE');
    } else if (onPassed) await onPassed(nativeProcessId);
    assertNativeTiming();
    passed = true;
    if (rateEvidence) console.log('NATIVE_RATE_UI_ORACLE_OBSERVED');
    else {
      console.log('NATIVE_SDK_FIXTURE_ACK_MALFORMED_REPLAY_PASS');
      console.log(`NATIVE_INTEGRATION_TARGET_${packet.phase.toUpperCase()}_PASS`);
    }
  } catch (error) {
    phaseFailed = true;
    if (['startup', 'channel'].includes(stage)) console.error(JSON.stringify({ kind: 'NATIVE_STARTUP_DIAGNOSTIC',
      phase: packet.phase, stage, started, terminal, spawned, boundaryFailed, boundaryReason, appOwned: Boolean(appId), channelReady,
      startupObservations: startupDiagnostics.snapshot() }));
    // Chỉ in enum giai đoạn/lớp lỗi allowlist; không xuất actual/expected, packet hoặc SDK trace.
    const reason = ['NATIVE_EXTENSION_RESULT_FAILED', 'NATIVE_DAEMON_RPC_FAILED',
      'NATIVE_DAEMON_RPC_TIMEOUT', 'NATIVE_DAEMON_UNAVAILABLE'].includes(error.message)
      ? error.message : error.code === 'ERR_ASSERTION' ? 'ASSERTION' : 'BOUNDARY';
    console.error(`NATIVE_PREFLIGHT_STAGE_${stage.toUpperCase()}_${reason}`);
    throw new Error('NATIVE_PREFLIGHT_CASE_FAILED');
  } finally {
    preArmClosed = true;
    rateOracleClosed = true;
    rateCheckpointClosed = true;
    rateEvidenceSealed = true;
    rateEvidence?.seal();
    rateEvidence?.signal.removeEventListener('abort', abortEvidenceRequests);
    if (asyncCheckpoints) runtime.externalSignal?.removeEventListener('abort', abortEvidenceRequests);
    try {
      // Hook chỉ phát cleanup intent đồng bộ. Không await fixture trước SDKstop hoặc callback pending sẽ tạo vòng chờ.
      const closing = runtime.onPhaseClosing?.(passed);
      if (closing !== undefined) {
        phaseClosingFailed = true;
        phaseClosingSettled = false;
        phaseClosingObservation = Promise.resolve(closing).then(
          /** Chỉ completion thật của hook sai contract mới đóng raw ownership. */
          () => { phaseClosingSettled = true; },
          /** Drain rejection mà không giữ raw fixture/SDK error hoặc cho PASS. */
          () => { phaseClosingSettled = true; });
      }
    } catch { phaseClosingFailed = true; }
    try {
      const result = await shutdownNativeDaemon({ child,
        getState: /** Snapshot chỉ chứa ownership/lifecycle flags, không packet hoặc debugger URI. */
          () => ({ terminal, stopped, appId, boundaryFailed }), request, exit: done,
        // Trusted host test có thể rút observer; helper vẫn chặn >30s, actual không nhận numeric CLI.
        budgetMilliseconds: runtime.cleanupBudgetMilliseconds });
      if (!result.sdkExited) console.error(`NATIVE_SDK_EXIT_UNCONFIRMED ownedSdkPid=${child.pid} appId=${appId ?? 'not-started'}`);
      if (!result.stopped) console.error(`NATIVE_APP_STOP_UNCONFIRMED appId=${appId ?? 'not-started'}`);
      let nativeStopped = false;
      // SDK còn sống vẫn có thể launch app sau readback, nên không dùng PID tức thời làm death proof.
      if (result.sdkExited) {
        try { checkPid(null); nativeStopped = true; } catch {
          // Không in stderr/PID/exception OS; giữ failure riêng và để fixture/proxy finally tiếp tục.
        }
      }
      if (!nativeStopped) console.error('NATIVE_PACKAGE_STOP_UNCONFIRMED');
      const cleanupPassed = result.sdkExited && result.stopped && result.exitCode === 0 &&
        !result.forced && !result.boundaryFailed && nativeStopped;
      if (!cleanupPassed) {
        // Không thay lỗi phase đã ghi bằng lỗi cleanup, nhưng vẫn cấm overall PASS và phase kế tiếp.
        if (phaseFailed) console.error('NATIVE_DAEMON_CLEANUP_FAILED');
        else assert.fail('NATIVE_DAEMON_CLEANUP_FAILED');
      }
    } finally {
      if (preArmPending) {
        if (!preArmSettled) console.error('NATIVE_OFFLINE_PREARM_IO_UNCONFIRMED');
        await preArmPending;
      }
      if (rateCheckpointPending) {
        if (!rateCheckpointPendingSettled) console.error(membership ? 'NATIVE_MEMBERSHIP_CHECKPOINT_IO_UNCONFIRMED' : 'NATIVE_RATE_CHECKPOINT_IO_UNCONFIRMED');
        await rateCheckpointPending;
      }
      // SDK cleanup không chờ oracle, nhưng caller chưa được admit fixture mới khi cùng I/O Promise còn pending.
      if (rateOraclePromise) {
        if (!rateOracleSettled) console.error(membership ? 'NATIVE_MEMBERSHIP_ORACLE_IO_UNCONFIRMED' : 'NATIVE_RATE_ORACLE_IO_UNCONFIRMED');
        await rateOraclePromise;
      }
      if (phaseClosingObservation) {
        if (!phaseClosingSettled) console.error('NATIVE_PHASE_CLOSING_IO_UNCONFIRMED');
        await phaseClosingObservation;
      }
      packet.password = ''; if ('newPassword' in packet) packet.newPassword = '';
      if ('wrongPassword' in packet) packet.wrongPassword = '';
      buffer = ''; errorTail = '';
      startupDiagnostics.clear();
    }
  }
  assert.equal(passed, true);
  assert.equal(phaseClosingFailed, false, 'NATIVE_PHASE_CLOSING_HOOK_FAILED');
  assertNativeTiming();
  console.log('NATIVE_SDK_APP_STOP_CHILD_EXIT_PASS');
  return nativeProcessId;
}

/** Kiểm đúng namespace5identities của READY, không nhận account thật hoặc URL làm fixture. */
function validateRateReady(ready) {
  assert.ok(ready && typeof ready.runId === 'string' &&
    /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(ready.runId) &&
    Array.isArray(ready.emails) && ready.emails.length === 5 && ready.emails.every(
      /** Index và runId phải cùng READY owned, không chỉ năm email nhìn giống synthetic. */
      (email, index) => email === `probe-${ready.runId}-${index}@example.invalid`), 'NATIVE_RATE_PACKET_INVALID');
}

/** Tạo wrong secret CSPRNG trong RAM trước SDK, không argv/env/define/file; caller vẫn sở hữu finally wipe. */
export function createNativeRatePacket(ready, password) {
  validateRateReady(ready);
  assert.ok(typeof password === 'string' && /^Aa1[0-9a-f]{32}$/.test(password), 'NATIVE_RATE_PACKET_INVALID');
  return { version: 1, phase: 'rate-limit', emails: [...ready.emails], password,
    wrongPassword: `Aa2${randomBytes(16).toString('hex')}` };
}

/** Validate5keys/credentials trước snapshot hoặc SDK spawn, để scanner không thiếu secret được native sử dụng. */
function validateNativeRatePacket(packet) {
  const keys = ['version', 'phase', 'emails', 'password', 'wrongPassword'];
  assert.ok(packet && typeof packet === 'object' && !Array.isArray(packet) && Reflect.ownKeys(packet).length === 5 &&
    keys.every(/** Chỉ data properties để finally wipe không gọi accessor ngoài ownership. */
      (key) => Object.getOwnPropertyDescriptor(packet, key)?.value !== undefined) &&
    Object.getOwnPropertyDescriptor(packet, 'password').writable && Object.getOwnPropertyDescriptor(packet, 'wrongPassword').writable &&
    packet.version === 1 && packet.phase === 'rate-limit' &&
    typeof packet.password === 'string' && /^Aa1[0-9a-f]{32}$/.test(packet.password) &&
    typeof packet.wrongPassword === 'string' && /^Aa2[0-9a-f]{32}$/.test(packet.wrongPassword) &&
    packet.password !== packet.wrongPassword && Array.isArray(packet.emails) && typeof packet.emails[0] === 'string',
  'NATIVE_RATE_PACKET_INVALID');
  const runId = /^probe-(.+)-0@example\.invalid$/.exec(packet.emails[0])?.[1];
  validateRateReady({ runId, emails: packet.emails });
}

/**
 * Nối3snapshot/counter/ledger với actual SDK consumer; chưa được mở qua CLI trước B3 và B1b actual.
 * Input: fixture owned đã READY/ARM; workDeadline từ ARM; readCounts đọc proxy6enum, không packet/SQL tùy ý.
 * runtime chỉ cấp process/clock/PID capabilities cho host tests; mặc định vẫn SDK/ADB thật.
 * Failure: dừng SDK trước STOP fixture; giữ cùng SDK exit/raw observers tới terminal, không fake cancellation.
 */
export async function runNativeRatePhase(packet, certificate, fixture, readCounts, workDeadline, runtime = {}) {
  let evidence; let sdkExit; let success = false;
  try {
    // Fixture đã READY/ARM thuộc caller; input/capsule lỗi cũng phải đi qua cùng owned cleanup.
    assert.ok(packet?.phase === 'rate-limit' && fixture && typeof fixture.close === 'function', 'NATIVE_RATE_CONFIGURATION_INVALID');
    validateNativeRatePacket(packet);
    const now = runtime.now ?? performance.now.bind(performance);
    evidence = createNativeRateEvidence({ fixture, readCounts, workDeadline, now, timers: runtime.evidenceTimers,
      externalSignal: runtime.externalSignal, assertExternalActive: runtime.assertExternalActive });
    const checkPid = runtime.checkPid ?? assertNativePid;
    await evidence.baseline();
    const processId = await runNativePhase(packet, certificate,
      /** Final bounded observer không đợi raw I/O vô hạn trong runner; wrapper giữ ownership khi nó timeout. */
      async (ownedPid, admission) => {
        admission.assertActive(); checkPid(ownedPid); admission.assertActive();
        await evidence.final(); admission.assertActive();
      }, [packet.password, packet.wrongPassword],
      /** Pure sync checkpoint không phát SQL; mỗi callback vẫn nằm trong shared5s guard của runner. */
      (stage, admission) => { admission.assertActive(); evidence.checkpoint(stage); admission.assertActive(); },
      { ...runtime, workDeadline, rateEvidence: evidence,
        captureSdkExit: /** Giữ actual child completion để failure không trả quyền mở fixture khác khi SDK chưa terminal. */
          (exit) => { sdkExit = exit; },
      });
    checkPid(null); evidence.finish(); success = true;
    console.log('NATIVE_RATE_HOST_EVIDENCE_PASS');
    return processId;
  } finally {
    try {
      evidence?.seal();
      if (!success) {
        // Kể cả SDK cleanup UNCONFIRMED vẫn thử STOP; không chờ SDK vô hạn trước khi fixture được yêu cầu dừng.
        let fixtureClosed = false;
        try { await fixture?.close(); fixtureClosed = typeof fixture?.close === 'function'; } catch { /* Không bỏ raw ownership khi readback fail. */ }
        await Promise.all([evidence?.settle(), sdkExit]);
        assert.ok(fixtureClosed, 'NATIVE_RATE_FIXTURE_CLEANUP_FAILED');
      } else await evidence.settle();
    } finally {
      // Owned valid packet là data mutable; malformed/frozen input không được ngăn fixture STOP ở phía trên.
      for (const key of ['password', 'wrongPassword']) {
        if (packet && typeof packet === 'object' && Object.getOwnPropertyDescriptor(packet, key)?.writable) packet[key] = '';
      }
    }
  }
}

/**
 * Hỏi đúng package của integration target bằng ADB; không enumerate process hoặc nhận PID làm quyền kill.
 * Input
 * Param: expectedPid — own native PID trước stop; null yêu cầu package đã không còn process.
 * Param: runCommand — boundary thực thi cố định; host test thay OS process bằng kết quả giả.
 */
export function assertNativePid(expectedPid, runCommand = spawnSync) {
  assert.ok(expectedPid === null || Number.isSafeInteger(expectedPid) && expectedPid > 0, 'NATIVE_PID_EXPECTATION_INVALID');
  // Chỉ shell thành công mới phát literal absent. Exit1 của ADB/device/shell không còn là absent proof.
  const query = 'pidof dev.nexa.nexa_iot; auth_pid_status=$?; if [ "$auth_pid_status" -eq 1 ]; then echo NATIVE_PACKAGE_ABSENT; elif [ "$auth_pid_status" -ne 0 ]; then exit 2; fi';
  const result = runCommand('C:/Users/LENOVO/AppData/Local/Android/sdk/platform-tools/adb.exe',
    ['-s', deviceId, 'shell', query],
    { encoding: 'utf8', timeout: 5_000, windowsHide: true, maxBuffer: 4096 });
  assert.ok(result && !result.error && !result.signal && result.status === 0 &&
    typeof result.stdout === 'string' && typeof result.stderr === 'string' && result.stderr.trim() === '', 'NATIVE_PID_QUERY_FAILED');
  const value = result.stdout.trim();
  if (expectedPid === null) assert.equal(value, 'NATIVE_PACKAGE_ABSENT', 'OLD_NATIVE_PROCESS_STILL_PRESENT');
  else assert.equal(value, String(expectedPid), 'NATIVE_PID_OWNERSHIP_FAILED');
}

/**
 * Kiểm host từ chối lab CA trước SDK, chỉ certificate error mong đợi mới là negative PASS.
 * Input
 * Param: signal — availability fence của đúng proxy owned, abort đóng socket thử hiện hành.
 * Errors: fixed assertion khi handshake thành công, timeout hoặc lỗi khác certificate rejection.
 * Side effects: mở một TLS socket loopback8443 rồi destroy trong finally, owner vẫn chờ raw-close metadata.
 */
export async function verifyHostNoCa(signal) {
  const socket = tls.connect({ host: '127.0.0.1', port: 8443, servername: 'localhost', rejectUnauthorized: true });
  const abort = /** Đóng đúng socket thử khi proxy không còn availability, không coi destroy là terminal ACK. */
    () => socket.destroy();
  signal?.addEventListener('abort', abort);
  if (signal?.aborted) abort();
  let timer;
  try {
    const outcome = await new Promise(
      /**
       * Quan sát handshake có deadline; không log lỗi/certificate material.
       * Input
       * Param: resolve — enum SDK code hoặc trạng thái transport.
       */
      (resolve) => {
        timer = setTimeout(/** Deadline không được xem như certificate rejection. */ () => resolve('TIMEOUT'), 5_000);
        socket.on('secureConnect', /** Handshake không CA mà thành công phải FAIL. */ () => resolve('AUTHORIZED'));
        socket.on('error',
          /**
           * Chỉ chọn error code, không đưa SDK trace hoặc peer material ra output.
           * Input
           * Param: error — lỗi TLS Node SDK.
           */
          (error) => resolve(error.code));
        socket.on('close', /** Close thiếu TLS error không phải negative trust evidence. */ () => resolve('CLOSED'));
      });
    assert.equal(outcome, 'DEPTH_ZERO_SELF_SIGNED_CERT', 'HOST_NO_CA_REJECTION_FAILED');
  } finally { signal?.removeEventListener('abort', abort); clearTimeout(timer); socket.destroy(); }
}

/** Internal rate entry point; CLI remains gated until final shared consumer regression/review. */
export async function runActualRate(runtime = {}) {
  return orchestrateNativeRate({
    createFixture: (password, secrets, onClosing) => startFixture(password, 'rate-limit', secrets, runtime.spawnFixtureProcess ?? spawn, onClosing),
    createCertificates,
    startProxy: (material, observer, onOwned) => startLocalHttpsProxy(material, {}, observer, { ...runtime.proxyRuntime, onOwned }),
    createPacket: createNativeRatePacket,
    runPhase: runNativeRatePhase,
    verifyHostNoCa,
    ...runtime,
  });
}

/**
 * Kiểm ARMED của đúng trình tự rate; schema/metadata dư hoặc receipt cũ không cấp work admission.
 * Input
 * Param: frame — public frame bounded từ owned shim, không secret.
 * Param: state — profile và các cờ host đã quan sát trước frame hiện tại.
 * Errors: assertion cố định nếu receipt không thuộc ARM một lần sau READY/write.
 */
export function validateFixtureArmFrame(frame, state) {
  assert.ok(state.scenario === 'rate-limit' && state.readyReceived && state.armSent && !state.alreadyArmed &&
    frame && !Array.isArray(frame) && frame.kind === 'ARMED' && Object.keys(frame).length === 1,
  'NATIVE_FIXTURE_ARM_FAILED');
}

/**
 * Neo work40phút trước write ARM để host không tính dư thời gian từ ACK tới muộn.
 * Input
 * Param: startupDeadline — absolute monotonic limit đã chốt trước spawn, bao cả READY/ARM.
 * Param: sendArm — capability gửi đúng một literal command trên private owned pipe.
 * Param: waitForArmed — đọc receipt mới sau write trong deadline chung, không retry hoặc giả terminal.
 * Param: isAvailable — xác nhận owned child chưa exit/protocol failure trước và sau await.
 * Param: beforeArm — precondition/offset của wrapper; chạy trong cùng guarded cleanup để không bỏ owned child.
 * Param: closeOnFailure — capability bắt buộc chờ STOP/EOF/owned terminal/readback khi ARM bị từ chối.
 * Param: now — monotonic clock; host test có thể dùng clock synthetic, actual dùng performance.now.
 * Output: absolute work deadline; caller chỉ mở work sau success và luôn close trong finally khi lỗi.
 */
export async function armNativeFixture({ startupDeadline, sendArm, waitForArmed, isAvailable, beforeArm, closeOnFailure, now = performance.now.bind(performance) }) {
  assert.equal(typeof closeOnFailure, 'function', 'NATIVE_FIXTURE_ARM_FAILED');
  try {
    assert.equal(typeof beforeArm, 'function', 'NATIVE_FIXTURE_ARM_FAILED');
    beforeArm();
    const anchor = now();
    // ACK5s cho một frame local không DB; shared deadline bị cắt bởi startup15min, không reset sau write.
    const acknowledgementDeadline = Math.min(anchor + 5_000, startupDeadline);
    assert.ok(Number.isFinite(anchor) && Number.isFinite(startupDeadline) && isAvailable() &&
      now() < acknowledgementDeadline, 'NATIVE_FIXTURE_ARM_FAILED');
    sendArm();
    assert.ok(isAvailable() && now() < acknowledgementDeadline, 'NATIVE_FIXTURE_ARM_FAILED');
    const frame = await waitForArmed(acknowledgementDeadline);
    assert.ok(isAvailable() && now() < acknowledgementDeadline, 'NATIVE_FIXTURE_ARM_FAILED');
    // Caller chỉ gọi sau READY; parser kiểm freshness/order riêng, helper cũng không nhận malformed receipt.
    validateFixtureArmFrame(frame, { scenario: 'rate-limit', readyReceived: true, armSent: true, alreadyArmed: false });
    return anchor + 40 * 60_000;
  } catch {
    // Không để future caller quên finally: ARM không xác định phải chờ đúng owned cleanup trước khi trả lỗi.
    try { await closeOnFailure(); } catch { throw new Error('NATIVE_FIXTURE_CLEANUP_FAILED'); }
    throw new Error('NATIVE_FIXTURE_ARM_FAILED');
  }
}

/**
 * Memoize cleanup của một owner để ARM failure và caller finally dùng cùng Promise, không gửi STOP lại.
 * Input
 * Param: owner — child/getState/exit capability của đúng fixture; observer mặc định giữ18phút hiện hữu.
 * Output: cùng cleanup Promise, kể cả khi đã reject; không tìm hoặc kill process khác.
 */
export function closeNativeFixture(owner) {
  if (!owner.closePromise) owner.closePromise = finishClosingNativeFixture(owner);
  return owner.closePromise;
}

/**
 * Dừng fixture bằng STOP hoặc EOF và chỉ xác nhận sau terminal/exit0/exact8zero; timeout vẫn giữ exit observer.
 * Input
 * Param: child — handle/stdio của shim do caller sở hữu, không PID selector tùy ý.
 * Param: getState — lifecycle/STOPPED metadata được observer của chính child cập nhật.
 * Param: exit — Promise chỉ hoàn tất từ owned exit event.
 * Param: observeExit — bounded observer; host tests dùng fake boundary, actual giữ budget18phút.
 * Errors: fixed cleanup failure; timeout/observer error phát fixed UNCONFIRMED, không raw payload/trace.
 */
async function finishClosingNativeFixture({ child, getState, exit, observeExit = observeBounded }) {
  let stopSignalled = true;
  if (!getState().terminal) {
    try { child.stdin.end('STOP\n'); }
    catch {
      // STOP write hỏng vẫn thử EOF để shim finally chạy; cả hai lỗi không được bỏ owned exit observer.
      try { child.stdin.destroy(); } catch { stopSignalled = false; }
    }
  }
  let observed;
  try { observed = await observeExit(exit, 18 * 60_000); }
  catch { observed = { settled: false }; }
  if (!observed.settled || !getState().terminal) {
    observed = { settled: false };
    console.error(`NATIVE_FIXTURE_EXIT_UNCONFIRMED ownedShimPid=${child.pid}`);
    await exit;
  }
  const state = getState();
  // Thử release từng pipe dù pipe trước lỗi; chỉ làm sau terminal quan sát, không fake kill hoặc cleanup ACK.
  for (const stream of [child.stdin, child.stdout, child.stderr]) {
    try { stream.destroy(); } catch { stopSignalled = false; }
  }
  assert.ok(observed.settled && stopSignalled && state.terminal && state.exitCode === 0 && !state.failed && state.stopped,
    'NATIVE_FIXTURE_CLEANUP_FAILED');
  validateFixtureCleanup(state.stopped.cleanup);
}

/**
 * Sở hữu shim có private stdin; mọi output đều framed metadata hữu hạn và không chứa credential.
 * Input
 * Param: password — CSPRNG synthetic chỉ truyền RAM; không argv/env/file.
 * Param: scenario — default20/password35/rate-limit40 sau ARM hoặc membership-stale20 neo trước spawn.
 * Param: sensitiveSecrets — toàn bộ credentials cũ/mới cần scan cả output shim dù chỉ original cấp seed.
 * Param: spawnFixtureProcess — trusted process capability; host tests thay fake child, CLI luôn dùng spawn chuẩn.
 * Param: onClosing — hook đồng bộ thông báo coordinator trước owned STOP, không cấp quyền async tùy ý.
 * Output: ready/snapshot/close, membership methods và workDeadline; close giữ original exit/readback.
 */
export function startFixture(password, scenario = 'default', sensitiveSecrets = [password], spawnFixtureProcess = spawn, onClosing) {
  assert.ok(['default', 'password', 'rate-limit', 'membership-stale', 'offline-login'].includes(scenario), 'INVALID_NATIVE_FIXTURE_SCENARIO');
  assert.ok(onClosing === undefined || typeof onClosing === 'function', 'INVALID_NATIVE_FIXTURE_CLOSE_HOOK');
  const spawnAnchor = performance.now();
  assert.ok(Number.isFinite(spawnAnchor) && spawnAnchor >= 0, 'NATIVE_FIXTURE_CLOCK_INVALID');
  const startupDeadline = scenario === 'offline-login' ? spawnAnchor + 35_000
    : ['rate-limit', 'membership-stale'].includes(scenario) ? spawnAnchor + 15 * 60_000 : undefined;
  const membershipWorkDeadline = ['membership-stale', 'offline-login'].includes(scenario) ? spawnAnchor + 20 * 60_000 : undefined;
  const child = spawnFixtureProcess('python', ['-X', 'utf8', '-B', 'ops/auth/native_lab_fixture.py'],
    { windowsHide: true, shell: false, stdio: ['pipe', 'pipe', 'pipe'] });
  const frames = []; let buffer = ''; let errorTail = ''; let failed = false;
  let terminal = false; let spawned = false; let exitCode;
  let readyReceived = false; let armSent = false; let alreadyArmed = false; let armedWorkDeadline;

  let closingNotified = false; let closingHookFailed = false; let closingHookObservation;
  let membershipOffset;
  const membership = ['membership-stale', 'offline-login'].includes(scenario) ? createNativeMembershipFixture({
    profile: scenario,
    workDeadline: membershipWorkDeadline,
    available:
      /** Partial frame/closing/exit không cấp command admission hoặc public receipt. */
      () => !terminal && !failed && !closingNotified && buffer.length === 0,
    send:
      /** Param: command — literal đã được controller chọn, offset chốt trước synchronous pipe write. */
      (command) => { membershipOffset = frames.length; child.stdin.write(command); },
    wait:
      /**
       * Đợi pending response trong cùng deadline đã chốt trước write.
       * Input
       * Param: kind — response enum của command đang sở hữu.
       * Param: deadline — monotonic cap tuyệt đối, không mở timeout mới.
       * Output: frame mới của same owned child.
       */
      (kind, deadline) => waitFrame(kind, membershipOffset, 0, deadline),
    close: /** Controller failure luôn đợi original shim terminal/readback của same owner. */ () => closeFixture(),
  }) : undefined;

  const done = new Promise(
    /**
     * Chỉ exit của owned shim là terminal; timeout hoặc post-spawn error không tự gán terminal.
     * Input
     * Param: resolve — completion actual shim exit.
     */
    (resolve) => {
      child.on('spawn', /** Ghi ownership sau spawn thành công. */ () => { spawned = true; });
      child.on('error', /** Chỉ lỗi trước spawn mới không có child cần cleanup. */
        () => { failed = true; if (isConfirmedSpawnFailure(spawned, child.pid)) { terminal = true; resolve(); } });
      child.on('exit',
        /**
         * Giữ code thực để cleanup không nhầm shim crash với STOPPED.
         * Input
         * Param: code — exit code của shim do runner sở hữu.
         */
        (code) => { terminal = true; exitCode = code; resolve(); });
    });
  child.stdin.on('error', /** Pipe lỗi là failure, vẫn giữ observer exit để không bỏ cleanup. */ () => { failed = true; });
  child.stdout.on('data',
    /**
     * Parse tối đa8 publicframes, mỗi phần buffer≤16KiB; không forward raw input hoặc exception.
     * Input
     * Param: chunk — bytes từ chính shim child.
     */
    (chunk) => {
      try {
        buffer += chunk.toString('utf8');
        assert.ok(buffer.length <= 16_384 && !containsNativeSecret(buffer, sensitiveSecrets));
        let newline;
        while ((newline = buffer.indexOf('\n')) !== -1) {
          const frame = JSON.parse(buffer.slice(0, newline)); buffer = buffer.slice(newline + 1);
          assert.ok(frame && ['READY', 'ARMED', 'SNAPSHOT', 'STOPPED', 'FAILED', 'CONTROL_FAILED', 'STOP_UNCONFIRMED',
            ...(membership ? ['MEMBERSHIP_TARGET', 'MEMBERSHIP_SUSPENDED', 'MEMBERSHIP_SESSION_EVIDENCE'] : [])].includes(frame.kind) && frames.length < 8);
          // READY trễ không được bypass startup cap bằng cách gọi membership method trước ready().
          if (membership && frame.kind === 'READY') assert.ok(performance.now() < startupDeadline, 'NATIVE_MEMBERSHIP_FIXTURE_FAILED');
          if (membership) membership.accept(frame);
          if (frame.kind === 'READY') {
            if (scenario === 'rate-limit' || membership) assert.ok(!readyReceived && !armSent, 'NATIVE_FIXTURE_ARM_FAILED');
            readyReceived = true;
          } else if (frame.kind === 'ARMED') {
            validateFixtureArmFrame(frame, { scenario, readyReceived, armSent, alreadyArmed });
            alreadyArmed = true;
          }
          frames.push(frame);
          if (['FAILED', 'CONTROL_FAILED', 'STOP_UNCONFIRMED'].includes(frame.kind)) failed = true;
        }
      } catch { failed = true; buffer = ''; }
    });
  child.stderr.on('data',
    /**
     * Scan secret qua chunk boundary rồi discard stderr, không log source/config/trace.
     * Input
     * Param: chunk — bytes stderr owned shim.
     */
    (chunk) => {
      const value = errorTail + chunk.toString('utf8');
      if (containsNativeSecret(value, sensitiveSecrets)) failed = true;
      // Cả hai secret có shape3prefix+32hex=35ký tự; giữ đủ tail để match split ở mọi vị trí.
      errorTail = value.slice(-35);
    });
  child.stdin.write(JSON.stringify(scenario === 'default' ? { version: 1, password } : { version: 1, password, scenario }) + '\n');

  /**
   * Đợi đúng frame sau offset để không dùng lại snapshot cũ; observer timeout không chấm dứt shim.
   * Input
   * Param: kind — enum protocol được host chọn cố định.
   * Param: offset — frame index trước operation để phân biệt từng snapshot.
   * Param: milliseconds — budget quan sát, không phải quyền kill child.
   * Param: monotonicDeadline — rate/membership absolute cap; READY/ARM/work không mở window mới sau await.
   * Output: public frame hoặc fixed error, caller phải close trong finally.
   */
  async function waitFrame(kind, offset, milliseconds, monotonicDeadline) {
    const deadline = Date.now() + milliseconds;
    while (!terminal && !failed && (monotonicDeadline === undefined ? Date.now() < deadline : performance.now() < monotonicDeadline) && !frames.slice(offset).some(
      /**
       * Chỉ match enum protocol, không thực thi hoặc mở URL từ metadata.
       * Input
       * Param: frame — frame đã bounded/parsed.
       */
      (frame) => frame.kind === kind)) await delay(100);
    const frame = frames.slice(offset).find(
      /**
       * Chọn response mới của operation hiện tại.
       * Input
       * Param: value — frame public trong cửa sổ đã chọn.
       */
      (value) => value.kind === kind);
    assert.ok(frame && !failed && (monotonicDeadline === undefined || performance.now() < monotonicDeadline), 'NATIVE_FIXTURE_PROTOCOL_FAILED');
    return frame;
  }
  const cleanupOwner = { child, exit: done,
    getState:
      /** Chỉ lấy metadata lifecycle/readback từ chính child, không dùng timeout làm terminal. */
      () => ({ terminal, failed, exitCode, stopped: frames.find(
        /** STOPPED chỉ có nghĩa sau readback shim; thiếu receipt thì fail closed dù exit0. */
        (frame) => frame.kind === 'STOPPED') }),
  };


  /** Báo coordinator đồng bộ trước STOP, kể cả close nội bộ của ARM. Output: original cleanup promise. */
  function closeFixture() {
    if (!closingNotified) {
      closingNotified = true;
      try {
        const result = onClosing?.();
        if (result !== undefined) {
          closingHookFailed = true;
          // Hook phải đồng bộ; nếu trả async thì giữ raw observer sau STOP, không bỏ ownership.
          closingHookObservation = Promise.resolve(result).catch(
            /** Chỉ giữ observer để drain async hook sai contract, không xuất raw error. */ () => {});
        }
      } catch { closingHookFailed = true; }
    }
    return closeNativeFixture(cleanupOwner).finally(
      /** Buffer output không được giữ sau owned cleanup đã settle, kể cả readback failed. */
      async () => { await closingHookObservation; buffer = ''; errorTail = ''; }).then(
      /** Hook lỗi vẫn làm cleanup failure sau khi original child/async observer đã settle. */ () => {
      assert.ok(!closingHookFailed, 'NATIVE_FIXTURE_CLEANUP_FAILED');
    });
  }

  /** Đọc READY membership qua cùng startup deadline, lỗi phải đợi owned fixture close. */
  async function membershipReady() {
    try {
      await waitFrame('READY', 0, 15 * 60_000, startupDeadline);
      return membership.ready();
    } catch {
      try { await closeFixture(); }
      finally { throw new Error('NATIVE_MEMBERSHIP_FIXTURE_FAILED'); }
    }
  }

  /**
   * Chỉ mở hai literal membership methods cho đúng profile, invalid caller vẫn giữ cleanup ownership.
   * Input
   * Param: operation — target/suspend/sessionEvidence literal do returned methods chọn, không nhận từ CLI.
   * Output: receipt controller hoặc fixed error sau original close.
   */
  async function membershipRequest(operation) {
    if (!membership || typeof membership[operation] !== 'function') {
      try { await closeFixture(); }
      finally { throw new Error('NATIVE_MEMBERSHIP_FIXTURE_FAILED'); }
    }
    return membership[operation]();
  }

  return {
    /** Output: membership work cap neo trước spawn, undefined ở profile cũ. */
    get workDeadline() { return membershipWorkDeadline; },
    ready: /** Rate/membership dùng startup clock trước spawn, membership có strict READY/owned close. */
      () => membership ? membershipReady() : waitFrame('READY', 0, 15 * 60_000, startupDeadline),
    offlineEvidence: /** Đọc sessions/audit/A-B từ một snapshot owned, chỉ profile offline được admission. */
      () => membershipRequest(scenario === 'offline-login' ? 'sessionEvidence' : 'offline-unavailable'),
    membershipTarget: /** Resolve B qua controller của same owned shim, không nhận selector. */
      () => membershipRequest('target'),
    suspendMembershipB: /** Suspend pinned B một lần, receipt chỉ sau operation commit/readback/drain. */
      () => membershipRequest('suspend'),
    membershipSessionEvidence: /** Read-only sessions/audit metadata do same owned control scope, chưa là final oracle PASS. */
      () => membershipRequest('sessionEvidence'),
    arm:
      /** Chốt one-shot rate receipt trên đúng child trước work; caller giữ close/finally cả khi ACK unknown. */
      async () => {
        let offset;
        armedWorkDeadline = await armNativeFixture({ startupDeadline,
          beforeArm:
            /** Đưa mọi precondition vào guarded helper; thiếu READY/replay/partial frame cũng phải close owned fixture. */
            () => {
              assert.ok(scenario === 'rate-limit' && readyReceived && !armSent && !alreadyArmed && buffer.length === 0, 'NATIVE_FIXTURE_ARM_FAILED');
              offset = frames.length;
            },
          closeOnFailure: closeFixture,
          isAvailable: /** Exit hoặc malformed output không được dùng ARMED để cấp admission. */ () => !terminal && !failed,
          sendArm: /** Set intent trước write để parser chỉ nhận receipt thuộc command hiện tại, không retry khi pipe lỗi. */
            () => { armSent = true; child.stdin.write('ARM\n'); },
          waitForArmed:
            /** Đọc frame sau offset với cùng monotonic deadline được helper chốt trước ARM write. */
            (deadline) => waitFrame('ARMED', offset, 5_000, deadline),
        });
        return armedWorkDeadline;
      },
    snapshot:
      /**
       * Đọc metadata account fixture cố định và đối chiếu response scope, không nhận UUID/SQL từ caller.
       * Input
       * Param: scope — full/disabled/limited/empty ánh xạ literal command, mặc định giữ C1 full.
       * Output: bounded session projection do shim đã validate.
       */
      async (scope = 'full') => {
        if (membership) return membership.snapshot(scope);
        const commands = { full: 'SNAPSHOT\n', disabled: 'SNAPSHOT_DISABLED\n', limited: 'SNAPSHOT_LIMITED\n', empty: 'SNAPSHOT_EMPTY\n' };
        assert.ok(Object.hasOwn(commands, scope), 'INVALID_NATIVE_FIXTURE_SCOPE');
        // Rate chưa ACK hoặc hết work không được gửi SQL snapshot; cleanup STOP vẫn được gửi độc lập ở close.
        if (scenario === 'rate-limit') assert.ok(alreadyArmed && Number.isFinite(armedWorkDeadline) && performance.now() < armedWorkDeadline, 'NATIVE_FIXTURE_ARM_FAILED');
        const offset = frames.length; child.stdin.write(commands[scope]);
        const frame = await waitFrame('SNAPSHOT', offset, 130_000,
          scenario === 'rate-limit' ? Math.min(performance.now() + 130_000, armedWorkDeadline) : undefined);
        assert.equal(frame.scope, scope, 'NATIVE_FIXTURE_SCOPE_MISMATCH');
        return frame.sessions;
      },
    close: closeFixture,
  };
}

/**
 * Chỉ nhận đúng8count integer0 từ readback owned, không coi schema cũ hoặc key thay thế là cleanup ACK.
 * Input
 * Param: counts — projection JSON do shim đọc sau launcher finally, không SQL/digest/credential.
 * Errors: assertion cố định khi thiếu/thừa key, sai kiểu hoặc dữ liệu fixture còn lại.
 */
export function validateFixtureCleanup(counts) {
  const keys = ['role', 'hba', 'users', 'sessions', 'workspaces', 'memberships', 'auditActor', 'limiterBuckets'];
  assert.ok(counts && typeof counts === 'object' && !Array.isArray(counts) && Object.keys(counts).length === keys.length && keys.every(
    /** Mỗi scope bắt buộc có tên chính xác và count nguyên0; boolean/null không được ép kiểu thành thành công. */
    (key) => Object.hasOwn(counts, key) && Number.isInteger(counts[key]) && counts[key] === 0), 'NATIVE_FIXTURE_CLEANUP_FAILED');
}

/**
 * Chạy scenario main thật trên fixture owned, giữ server/request/PID và cleanup oracle độc lập UI.
 * Input
 * Param: scenario — full/access/password giữ các case cố định, không URL/config tùy ý.
 */
async function runActualMain(scenario) {
  assert.ok(['full', 'access', 'password'].includes(scenario));
  const certificates = createCertificates();
  const password = `Aa1${randomBytes(16).toString('hex')}`;
  const newPassword = scenario === 'password' ? `Aa2${randomBytes(16).toString('hex')}` : undefined;
  const sensitiveSecrets = newPassword ? [password, newPassword] : [password];
  const fixture = startFixture(password, scenario === 'password' ? 'password' : 'default', sensitiveSecrets);
  const counts = { AUTH_LOGIN: 0, AUTH_LOGOUT: 0, PROFILE_READ: 0, WORKSPACE_LIST: 0, PASSWORD_CHANGE: 0, OTHER: 0 };
  let proxy;
  let stage = 'fixture';
  try {
    const ready = await fixture.ready();
    assert.ok(typeof ready.runId === 'string' && Array.isArray(ready.emails) && ready.emails.length === 5 && ready.emails.every(
      /**
       * Không gửi credential vào identity/URL tùy ý do output giả mạo chọn.
       * Input
       * Param: email — identity synthetic phải đúng namespace của run vừa READY.
       * Param: index — vị trí0–4 do launcher sinh.
       */
      (email, index) => email === `probe-${ready.runId}-${index}@example.invalid`));
    const workDeadline = performance.now() + (scenario === 'password' ? 35 : 20) * 60_000;
    stage = 'proxy';
    proxy = await startLocalHttpsProxy(certificates.valid, {},
      /**
       * Chỉ đếm enum, không giữ route/query/header/body/token trong runner.
       * Input
       * Param: kind — enum từ request-line observer của proxy đã review.
       */
      (kind) => { assert.ok(Object.hasOwn(counts, kind)); counts[kind]++; });
    const certificate = new X509Certificate(certificates.valid.certificate).raw.toString('base64');
    for (const value of Object.values(certificates)) value.pfx.fill(0);
    await verifyHostNoCa();
    if (scenario === 'password') {
      requireWorkBudget(workDeadline, 1_995_000);
      const baseline = await fixture.snapshot('limited');
      requireWorkBudget(workDeadline, 1_860_000);
      const oracle = createPasswordCheckpointOracle();
      let changed;
      stage = 'password';
      const firstPid = await runNativePhase({ version: 1, phase: 'password', emails: ready.emails, password, newPassword }, certificate,
        /**
         * Kiểm limited phiên đã revoked sau204 trước khi process mới có thể login bằng password mới.
         * Input
         * Param: processId — own native PID còn sống ở phase1 framework PASS.
         */
        async (processId) => {
          assertNativePid(processId); oracle.finishPhase('password', { ...counts });
          changed = await fixture.snapshot('limited'); validatePasswordSessionDelta(baseline, changed);
          requireWorkBudget(workDeadline, 0);
        }, sensitiveSecrets,
        /**
         * ACK chỉ khi sequence và counter đúng, không làm SQL/network trong5s UI pause.
         * Input
         * Param: checkpoint — enum password validation/mutation từ native status.
         */
        (checkpoint) => oracle.checkpoint(checkpoint, { ...counts }));
      assertNativePid(null); oracle.finishPhase('password', { ...counts });
      requireWorkBudget(workDeadline, nativePhaseBudget('password-relogin').reserveMilliseconds);
      stage = 'password-relogin';
      const secondPid = await runNativePhase({ version: 1, phase: 'password-relogin', emails: ready.emails, password, newPassword }, certificate,
        /**
         * Old password rejection/new login/logout phải thêm đúng1revokedUUID, không đổi limited map.
         * Input
         * Param: processId — PID phase2 phải khác process đã xác nhận chết.
         */
        async (processId) => {
          assert.notEqual(processId, firstPid); assertNativePid(processId);
          oracle.finishPhase('password-relogin', { ...counts });
          validatePasswordSessionDelta(baseline, changed, await fixture.snapshot('limited'));
          requireWorkBudget(workDeadline, 0);
        }, sensitiveSecrets,
        /**
         * Giữ chung oracle xuyên process nên old/new login không reset counters để che duplicate.
         * Input
         * Param: checkpoint — enum relogin/empty/logout của phase2.
         */
        (checkpoint) => oracle.checkpoint(checkpoint, { ...counts }));
      assert.notEqual(secondPid, firstPid); assertNativePid(null);
      oracle.finishPhase('password-relogin', { ...counts }); requireWorkBudget(workDeadline, 0);
      console.log('NATIVE_ACTUAL_MAIN_PASSWORD_ORACLES_PASS');
    } else if (scenario === 'access') {
      const disabledBaseline = await fixture.snapshot('disabled');
      const emptyBaseline = await fixture.snapshot('empty');
      const accessOracle = createAccessCheckpointOracle();
      stage = 'access';
      await runNativePhase({ version: 1, phase: 'access', emails: ready.emails, password }, certificate,
        /**
         * Đối chiếu đúng owned PID và account session deltas sau native đã logout/frame PASS.
         * Input
         * Param: processId — native PID vẫn sống để host kiểm trước SDK stop.
         */
        async (processId) => {
          assertNativePid(processId); accessOracle.finish({ ...counts });
          validateAccessSessionDelta(disabledBaseline, await fixture.snapshot('disabled'), emptyBaseline, await fixture.snapshot('empty'));
        }, password,
        /**
         * Kiểm exact ordered counters trước ACK native, không DB/network await trong checkpoint budget5s.
         * Input
         * Param: checkpoint — enum UI pause từ status, oracle từ chối stage lạ/out-of-order/replay.
         */
        (checkpoint) => accessOracle.checkpoint(checkpoint, { ...counts }));
      assertNativePid(null); accessOracle.finish({ ...counts });
      console.log('NATIVE_ACTUAL_MAIN_ACCESS_ORACLES_PASS');
    } else {
      const baseline = await fixture.snapshot();
      let full;
      stage = 'full';
      const firstPid = await runNativePhase({ version: 1, phase: 'full', emails: ready.emails, password }, certificate,
        /**
         * Kiểm đúng native PID/server snapshot và chưa có logout trước cold restore sau UI/framework PASS.
         * Input
         * Param: processId — own PID do native extension trả.
         */
        async (processId) => {
          assertNativePid(processId); full = await fixture.snapshot(); validateSessionDelta(baseline, full);
          assert.equal(counts.AUTH_LOGIN, 1); assert.ok(counts.PROFILE_READ > 0);
          assert.equal(counts.AUTH_LOGOUT, 0, 'UNEXPECTED_LOGOUT_BEFORE_RESUME');
        }, sensitiveSecrets,
        /** Exact allowlist at the native picker boundary; any device/resource or unknown request fails closed. */
        (checkpoint) => {
          validateNativePreselectionOracle(checkpoint, { ...counts });
          console.log('NATIVE_PRESELECTION_REQUEST_ORACLE_PASS');
        });
      assertNativePid(null);
      requireWorkBudget(workDeadline, 8 * 60_000);
      // Không để login muộn giữa callback/full SDK cleanup bị hấp thụ vào baseline của phase resume.
      assert.equal(counts.AUTH_LOGIN, 1, 'UNEXPECTED_LOGIN_BETWEEN_PHASES');
      assert.equal(counts.AUTH_LOGOUT, 0, 'UNEXPECTED_LOGOUT_BETWEEN_PHASES');
      const beforeResume = { ...counts };
      stage = 'resume';
      const secondPid = await runNativePhase({ version: 1, phase: 'resume', emails: ready.emails, password: '' }, certificate,
        /**
         * Resume không relogin; đúng một logout POST revoke App UUID, baseline giữ nguyên.
         * Input
         * Param: processId — PID mới phải khác process đã xác nhận chết.
         */
        async (processId) => {
          assert.notEqual(processId, firstPid); assertNativePid(processId);
          validateSessionDelta(baseline, full, await fixture.snapshot());
          assert.equal(counts.AUTH_LOGIN - beforeResume.AUTH_LOGIN, 0);
          assert.equal(counts.AUTH_LOGIN, 1, 'UNEXPECTED_LOGIN_TOTAL');
          assert.equal(counts.AUTH_LOGOUT, 1, 'UNEXPECTED_LOGOUT_TOTAL');
          assert.ok(counts.PROFILE_READ - beforeResume.PROFILE_READ > 0);
        }, password);
      assert.notEqual(firstPid, secondPid); assertNativePid(null);
      assert.equal(counts.AUTH_LOGIN, 1, 'UNEXPECTED_LOGIN_AFTER_RESUME');
      assert.equal(counts.AUTH_LOGOUT, 1, 'UNEXPECTED_LOGOUT_AFTER_RESUME');
      console.log('NATIVE_ACTUAL_MAIN_FULL_RESUME_LOGOUT_ORACLES_PASS');
    }
  } catch {
    console.error(`NATIVE_FULL_SESSION_STAGE_${stage.toUpperCase()}_FAILED`);
    throw new Error('NATIVE_FULL_SESSION_FAILED');
  } finally {
    let proxyClosed = true; let fixtureClosed = true;
    try { if (proxy) proxyClosed = await proxy.close(); } catch { proxyClosed = false; }
    try { await fixture.close(); } catch { fixtureClosed = false; }
    for (const value of Object.values(certificates)) value.pfx.fill(0);
    assert.ok(proxyClosed && fixtureClosed, 'NATIVE_FULL_SESSION_CLEANUP_FAILED');
    console.log('NATIVE_OWNED_PROXY_FIXTURE_CLEANUP_PASS');
  }
  console.log('NATIVE_ACTUAL_MAIN_FIXTURE_CLEANUP_PASS');
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    assert.ok(process.argv.length === 3 && ['--preflight', '--full-session', '--access-cases', '--password-cases'].includes(process.argv[2]), 'NATIVE_E2E_PHASE_NOT_READY');
    if (process.argv[2] === '--preflight') await runPreflight();
    else await runActualMain(process.argv[2] === '--access-cases' ? 'access' : process.argv[2] === '--password-cases' ? 'password' : 'full');
  } catch {
    // Không log raw SDK/exception vì có thể chứa fixture packet hoặc debugger URI.
    console.error('NATIVE_E2E_PREFLIGHT_FAILED'); process.exitCode = 1;
  }
}
