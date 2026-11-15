import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import path from 'node:path';
import { createNativeRateEvidence } from './native_rate_evidence.mjs';
import { calculateNativeRpcDeadline, nativePhaseBudget, runNativePhase, runNativeRatePhase, createNativeRatePacket } from './run_native_e2e.mjs';

const fixturePassword = 'Aa1' + 'd'.repeat(32);
const fixtureRunId = 'aaaaaaaa-1111-4111-8111-111111111111';
const fixtureEmails = Array.from({ length: 5 }, (_, index) => `probe-${fixtureRunId}-${index}@example.invalid`);
// Các nhãn test độc lập với implementation để bắt thiếu/đảo thứ tự11intent được plan chốt.
const checkpointStages = ['rate-before', 'rate-wrong-1', 'rate-wrong-2', 'rate-wrong-3', 'rate-wrong-4',
  'rate-wrong-5', 'rate-limited', 'rate-mid-cooldown', 'rate-expired', 'rate-login', 'rate-logout'];

/**
 * Thay đúng SDK process/clock boundary để gọi consumer thật mà không chạy SDK, ADB, DB hoặc product API.
 * Input
 * Param: mode — ca success hoặc deadline/transport failure cố định của suite.
 * Param: phase — rate-limit hoặc full cũ để kiểm compatibility, không CLI/runtime config sản phẩm.
 * Output: capabilities host giả cùng counters/clock public cho assertions; không lưu packet hoặc credential.
 */
function fakeSdkRuntime(mode, phase) {
  const state = { clock: 0, spawned: 0, commands: [], fixtureWrites: 0, statusReplies: 0, phaseStart: undefined, passed: false, sdkExited: false, cleanupExitCode: 0,
    checkpointIndex: 0, checkpointWrites: 0, acceptedCheckpoints: [] };
  const child = new EventEmitter(); child.pid = 9123;
  child.stdin = new EventEmitter(); child.stdout = new EventEmitter(); child.stderr = new EventEmitter();
  const appId = 'bbbbbbbb-2222-4222-8222-222222222222';
  state.exitSdk = /** Phát actual exit event của fake child để kiểm final observer không chặn fixture STOP. */
    () => { state.sdkExited = true; child.emit('exit', 0); };
  state.failSdkBoundary = /** Pipe error là failure đang sống; runner vẫn phải gọi cleanup RPC trước STOP fixture. */
    () => child.stdin.emit('error', new Error('PRIVATE_PIPE_SENTINEL'));

  /** Xuất daemon envelope qua parser thật, chỉ metadata fake không có credential hoặc SDK trace. */
  function emit(messages) { child.stdout.emit('data', Buffer.from(JSON.stringify(messages) + '\n')); }

  child.stdin.write =
    /**
     * Trả response qua cùng stdout pipe giả sau khi consumer đăng ký pending; mô phỏng late data mà timer chưa tick.
     * Input
     * Param: value — RPC serialized trong RAM; không log hoặc giữ fixture password.
     */
    (value) => {
      const [request] = JSON.parse(value);
      state.commands.push(request.method);
      if (request.method === 'app.stop') {
        emit([{ event: 'app.stop', params: { appId } }, { id: request.id, result: {} }]);
        return;
      }
      if (request.method === 'daemon.shutdown') {
        emit([{ id: request.id, result: {} }]);
        if (mode.startsWith('evidence-external-wait-')) return;
        if (mode === 'evidence-cleanup-unconfirmed') { state.awaitingExit = true; return; }
        state.sdkExited = true; child.emit('exit', state.cleanupExitCode); return;
      }
      assert.equal(request.method, 'app.callServiceExtension');
      if (mode === 'write-error') throw new Error('SYNTHETIC_PRIVATE_WRITE_FAILURE');
      const extension = request.params.methodName;
      let result;
      let echo;
      if (extension.endsWith('.fixture')) {
        const packet = JSON.parse(request.params.params.packet);
        if (packet.version !== 1) result = { accepted: false };
        else {
          state.fixtureWrites++;
          if (state.fixtureWrites === 1) state.phaseStart = state.clock;
          if (mode === 'phase-no-reset') state.clock += 1000;
          result = { accepted: state.fixtureWrites === 1 };
          if (state.fixtureWrites === 1 && mode.startsWith('evidence-echo-')) {
            echo = mode.endsWith('-correct') ? packet.password : packet.wrongPassword;
          }
        }
      } else if (extension.endsWith('.checkpoint')) {
        state.checkpointWrites++;
        const parameters = request.params.params;
        const expected = checkpointStages[state.checkpointIndex];
        const accepted = Object.keys(parameters).length === 1 && parameters.stage === expected;
        if (accepted) { state.acceptedCheckpoints.push(expected); state.checkpointIndex++; }
        result = { accepted };
        if (mode === 'checkpoint-ack-total') state.clock += 1000;
      } else {
        assert.ok(extension.endsWith('.status'));
        state.statusReplies++;
        result = { phase, status: 'WAITING' };
        if (state.fixtureWrites >= 2) {
          if (mode === 'phase-no-reset' && state.clock < state.phaseStart + 1_260_000 - 500) {
            state.clock = Math.min(state.clock + 28_000, state.phaseStart + 1_260_000 - 500);
          } else if (phase === 'rate-limit' && mode !== 'phase-no-reset' && mode !== 'checkpoint-premature-pass'
            && state.checkpointIndex < checkpointStages.length) {
            let stage = checkpointStages[state.checkpointIndex];
            if (mode === 'checkpoint-repeat' && state.checkpointIndex === 1) stage = checkpointStages[0];
            if (mode === 'checkpoint-order') stage = checkpointStages[1];
            result = { phase, status: mode === 'checkpoint-on-pass' ? 'PASS' : 'WAITING', checkpoint: stage,
              checkpointRemainingMilliseconds: 5000 };
            if (mode === 'evidence-late-429' && state.checkpointIndex === 6) state.clock = state.phaseStart + 180_001;
            if (mode === 'checkpoint-missing') delete result.checkpointRemainingMilliseconds;
            if (mode === 'checkpoint-remaining-only') delete result.checkpoint;
            if (mode === 'checkpoint-boolean') result.checkpointRemainingMilliseconds = true;
            if (mode === 'checkpoint-zero') result.checkpointRemainingMilliseconds = 0;
            if (mode === 'checkpoint-oversized') result.checkpointRemainingMilliseconds = 5001;
            if (mode === 'checkpoint-status-late') state.clock += 5000;
          } else {
            if (mode === 'phase-no-reset') state.clock = state.phaseStart + 1_260_000 + 1;
            result = { phase, status: 'PASS', nativeProcessId: 8123 };
          }
        }
      }
      // Mỗi channel RPC25s riêng còn hợp lệ, nhưng tổng ba response75s phải vượt cap chung60s.
      if (mode === 'channel-total') state.clock += 25_000;
      if (mode === 'rpc-late') state.clock += 30_001;
      if (mode === 'fixture-unknown' && state.fixtureWrites === 1) state.clock += 1_260_001;
      if (state.fixtureWrites >= 2 && extension.endsWith('.status')) {
        if (mode === 'checkpoint-foreign-phase' || (mode === 'checkpoint-final-foreign-phase' && result.status === 'PASS')) result.phase = 'foreign-phase';
        if (mode === 'checkpoint-missing-phase' || (mode === 'checkpoint-final-missing-phase' && result.status === 'PASS')) delete result.phase;
      }
      const response = [{ id: request.id, result }];
      if (mode === 'evidence-mid-rpc-pending' && extension.endsWith('.status') && state.checkpointIndex === 7) {
        state.blockedReply = /** Reply vẫn có thể về sau abort; pending id cũ không được tạo ACK/work mới. */
          () => emit(response);
        return;
      }
      emit(response);
      if (echo) {
        const stream = mode.includes('-stdout-') ? child.stdout : child.stderr;
        stream.emit('data', Buffer.from(echo.slice(0, 17)));
        stream.emit('data', Buffer.from(echo.slice(17)));
      }
      if (mode === 'duplicate-response') emit(response);
    };
  for (const stream of [child.stdin, child.stdout, child.stderr]) {
    stream.destroy = /** Release fake stream không đụng system process/descriptor. */ () => {};
  }
  child.kill = /** Ca unconfirmed cố tình không phát exit dù kill được yêu cầu; không lấy intent làm terminal. */
    () => { assert.equal(mode, 'evidence-cleanup-unconfirmed', 'UNEXPECTED_FORCE_KILL'); state.killRequested = true; return false; };
  child.unref = /** Fake unref không giải phóng exit Promise hoặc sửa terminal flag. */
    () => { assert.equal(mode, 'evidence-cleanup-unconfirmed', 'UNEXPECTED_DETACH'); state.unrefRequested = true; };
  return { state,
    checkPid: /** Oracle OS được thay rõ ràng để suite host không gọi ADB. */ () => {},
    workDeadline: 2_400_000,
    now: /** Clock tiến mỗi lần đọc bắt lỗi resample equality mà clock đứng yên che mất. */
      () => { if (mode === 'evidence-advancing-clock') state.clock += 0.01; return state.clock; },
    pause:
      /**
       * Cho notification fake vào event loop trong khi tiến clock host để kiểm deadline xác định.
       * Input
       * Param: milliseconds — khoảng poll consumer yêu cầu, không sleep thời gian App.
       */
      async (milliseconds) => {
        state.clock += milliseconds;
        if (mode.startsWith('evidence-external-wait-')) {
          state.waitPolls = (state.waitPolls ?? 0) + 1;
          if (state.waitPolls === 1) state.abortExternal();
          if (state.waitPolls === 5) state.exitSdk();
        }
        await new Promise(
        /** Cho owned SDK event được xử lý trước poll tiếp, không tự gán started/terminal. */
        (resolve) => setImmediate(resolve)); },
    spawnNativeProcess:
      /**
       * Cấp đúng child giả và phát event sau khi factory thật gắn observer; kiểm argv không có password.
       * Input
       * Param: command — Dart executable cố định, không được khởi chạy trong test.
       * Param: arguments_ — argv SDK public của consumer.
       * Param: options — process options phải tắt shell và dùng private pipes.
       */
      (command, arguments_, options) => {
        state.spawned++; assert.ok(command.endsWith('dart.exe')); assert.equal(options.shell, false);
        assert.ok(!arguments_.join(' ').includes(fixturePassword));
        assert.ok(!arguments_.some(/** Cả hai synthetic secret shapes đều không được đi qua compiler/SDK argv. */
          (value) => /Aa[12][0-9a-f]{32}/.test(value)));
        if (mode === 'spawn-late') state.clock += 360_001;
        queueMicrotask(
          /** Phát đúng ownership/start/channel metadata, không thay trực tiếp state của consumer. */
          () => {
            child.emit('spawn');
            if (mode === 'startup-diagnostic-exit') {
              emit([{ event: 'app.start', params: { appId, deviceId: 'emulator-5554', directory: path.resolve('mobile'), mode: 'debug', launchMode: 'run' } },
                { event: 'app.log', params: { appId, log: 'NATIVE_AUTH_TEST_CHANNEL_READY' } }]);
              child.stderr.emit('data', Buffer.from('Error initial'));
              child.stderr.emit('data', Buffer.from('izing DevFS http://127.0.0.1:9999/PRIVATE_DEBUG_TOKEN/'));
              emit([{ event: 'app.stop', params: { appId, error: { message: 'PRIVATE_DIAGNOSTIC_SENTINEL' } } }]);
              state.sdkExited = true; child.emit('exit', 3); return;
            }
            const events = [{ event: 'app.start', params: { appId, deviceId: 'emulator-5554', directory: path.resolve('mobile'), mode: 'debug', launchMode: 'run' } }];
            if (mode !== 'evidence-external-wait-startup') events.push({ event: 'app.started', params: { appId } });
            if (!mode.startsWith('evidence-external-wait-')) events.push({ event: 'app.log', params: { appId, log: 'NATIVE_AUTH_TEST_CHANNEL_READY' } });
            emit(events);
          });
        return child;
      },
  };
}

/** Kiểm deadline arithmetic và actual runner wiring bằng SDK giả; mọi failure phải còn owned cleanup path. */
async function main() {
  const firstRatePacket = createNativeRatePacket({ runId: fixtureRunId, emails: fixtureEmails }, fixturePassword);
  const secondRatePacket = createNativeRatePacket({ runId: fixtureRunId, emails: fixtureEmails }, fixturePassword);
  assert.ok(/^Aa2[0-9a-f]{32}$/.test(firstRatePacket.wrongPassword));
  assert.notEqual(firstRatePacket.wrongPassword, secondRatePacket.wrongPassword);
  assert.notEqual(firstRatePacket.wrongPassword, fixturePassword);
  assert.notEqual(firstRatePacket.emails, fixtureEmails);
  firstRatePacket.password = ''; firstRatePacket.wrongPassword = '';
  secondRatePacket.password = ''; secondRatePacket.wrongPassword = '';
  assert.deepEqual(nativePhaseBudget('rate-limit'), { testMilliseconds: 1_260_000, reserveMilliseconds: 2_065_000 });
  assert.equal(calculateNativeRpcDeadline({ workDeadline: 100_000, channelDeadline: 60_000 }, 0), 30_000);
  assert.equal(calculateNativeRpcDeadline({ workDeadline: 100_000, channelDeadline: 60_000, phaseDeadline: 70_000 }, 50_000), 60_000);
  assert.equal(calculateNativeRpcDeadline({ workDeadline: 55_000, phaseDeadline: 70_000 }, 50_000), 55_000);
  assert.equal(calculateNativeRpcDeadline({ workDeadline: 100_000, phaseDeadline: 70_000, checkpointDeadline: 51_000 }, 50_000), 51_000);
  for (const bounds of [{}, { workDeadline: Infinity }, { workDeadline: 100, phaseDeadline: null },
    { workDeadline: 100, channelDeadline: 50 }, { workDeadline: 100, checkpointDeadline: 50 }, { workDeadline: 50 }]) {
    assert.throws(/** Scope thiếu, nonfinite hoặc đã hết không cấp RPC mới. */
      () => calculateNativeRpcDeadline(bounds, 50), { message: 'NATIVE_DAEMON_RPC_TIMEOUT' });
  }
  console.log('NATIVE_RATE_RPC_ABSOLUTE_MIN_PASS');
  for (const mode of ['success', 'duplicate-response', 'channel-total', 'rpc-late', 'fixture-unknown', 'phase-no-reset', 'work-expired', 'spawn-late', 'write-error', 'missing-work', 'legacy']) {
    const phase = mode === 'legacy' ? 'full' : 'rate-limit';
    const runtime = fakeSdkRuntime(mode, phase);
    if (mode === 'missing-work') delete runtime.workDeadline;
    const diagnostics = []; const originalLog = console.log; const originalError = console.error;
    console.log = /** Giữ routine markers trong RAM để suite chỉ xuất kết quả fixed của từng gate. */ (value) => { diagnostics.push(String(value)); };
    console.error = /** Capture diagnostic public; raw private write sentinel không được lọt ra stdout/stderr. */ (value) => { diagnostics.push(String(value)); };
    try {
      const operation = runNativePhase({ version: 1, phase, emails: [], password: fixturePassword }, 'PUBLIC_TEST_CERTIFICATE',
        /** Oracle fake chạy sau SDK framework PASS; work expiry phải vẫn bị guard trước success cuối. */
        async () => { runtime.state.passed = true; if (mode === 'work-expired') runtime.state.clock = runtime.workDeadline + 1; },
        fixturePassword, /** Sync pure callback của các ca deadline không làm I/O trong pause. */ () => {}, runtime);
      if (['success', 'duplicate-response', 'legacy'].includes(mode)) {
        assert.equal(await operation, 8123); assert.equal(runtime.state.passed, true);
      } else await assert.rejects(/** Các deadline/transport failure không được nhận PASS từ scripted reply muộn. */ () => operation);
      if (mode === 'missing-work') assert.equal(runtime.state.spawned, 0);
      else {
        assert.equal(runtime.state.spawned, 1);
        assert.ok(runtime.state.commands.includes('daemon.shutdown'));
        if (mode !== 'spawn-late') assert.ok(runtime.state.commands.includes('app.stop'));
      }
      if (['channel-total', 'fixture-unknown'].includes(mode)) assert.equal(runtime.state.fixtureWrites, 1);
      if (['rpc-late', 'write-error', 'missing-work'].includes(mode)) assert.equal(runtime.state.fixtureWrites, 0);
      if (mode === 'phase-no-reset') {
        assert.equal(runtime.state.fixtureWrites, 2); assert.ok(runtime.state.statusReplies > 3);
        assert.equal(runtime.state.clock, runtime.state.phaseStart + 1_260_001);
        assert.equal(runtime.state.passed, false);
      }
      if (mode === 'work-expired') assert.equal(runtime.state.passed, true);
      if (['success', 'duplicate-response', 'legacy'].includes(mode)) assert.equal(runtime.state.fixtureWrites, 2);
      assert.ok(diagnostics.every(/** Diagnostic lỗi chỉ fixed metadata, không echo fixture hoặc raw pipe failure. */
        (value) => !value.includes(fixturePassword) && !value.includes('SYNTHETIC_PRIVATE_WRITE_FAILURE')));
    } finally { console.log = originalLog; console.error = originalError; }
  }
  console.log('NATIVE_RATE_RPC_CONSUMER_PHASE_CLEANUP_PASS');
  for (const outcome of ['late-resolve', 'late-reject', 'cleanup-failure', 'pid-tail-reserve']) {
    const runtime = fakeSdkRuntime('success', 'rate-limit');
    if (outcome === 'cleanup-failure') runtime.state.cleanupExitCode = 1;
    let releaseOracle; let oracleEntered = false; let runnerSettled = false; let lateEffects = 0;
    const pendingOracle = new Promise(
      /** Giữ I/O oracle pending thật; chỉ test release sau khi kiểm SDK cleanup đã diễn ra. */
      (resolve, reject) => {
        releaseOracle = /** Late error cũng phải có handler và không được biến thành PASS hoặc raw output. */
          () => outcome === 'late-reject' ? reject(new Error('SYNTHETIC_PRIVATE_ORACLE_REJECTION')) : resolve();
      });
    const diagnostics = []; const unhandled = [];
    const originalLog = console.log; const originalError = console.error;
    const trackUnhandled = /** Ghi late rejection sai ownership mà không log raw reason. */ () => { unhandled.push(true); };
    process.on('unhandledRejection', trackUnhandled);
    console.log = /** Chỉ thu public phase markers, không xuất raw SDK hoặc oracle I/O. */ (value) => { diagnostics.push(String(value)); };
    console.error = /** Thu fixed UNCONFIRMED/failure để chứng minh pending không bị coi là cancelled. */ (value) => { diagnostics.push(String(value)); };
    let operation;
    try {
      operation = runNativePhase({ version: 1, phase: 'rate-limit', emails: [], password: fixturePassword }, 'PUBLIC_TEST_CERTIFICATE',
        /**
         * Oracle trusted phải kiểm context sau I/O trước mọi side effect; timeout không tự cancel Promise.
         * Input
         * Param: processId — PID public của native fake đã framework PASS.
         * Param: admission — fence do runner đóng khi hết work/oracle budget hoặc cleanup bắt đầu.
         */
        async (processId, admission) => {
          assert.equal(processId, 8123); oracleEntered = true;
          await pendingOracle; admission.assertActive(); lateEffects++;
        }, fixturePassword, /** Oracle checkpoint chỉ giữ boundary để tới pending completion oracle. */ () => {}, runtime);
      operation.then(/** Ghi completion để phát hiện return trước khi owned I/O settle. */ () => { runnerSettled = true; },
        /** Ghi rejection sau cleanup/I/O mà không tạo unhandled Promise phụ. */ () => { runnerSettled = true; });
      for (let turn = 0; turn < 20 && !oracleEntered; turn++) await new Promise(
        /** Cho fake SDK hoàn tất handshake và oracle bắt đầu, không sleep hoặc ép callback settle. */
        (resolve) => setImmediate(resolve));
      assert.equal(oracleEntered, true);
      runtime.state.clock = runtime.workDeadline + (outcome === 'pid-tail-reserve' ? -100_000 : 1);
      for (let turn = 0; turn < 20 && !runtime.state.sdkExited; turn++) await new Promise(
        /** Cho deadline observer chạy SDK cleanup trong khi oracle vẫn pending. */
        (resolve) => setImmediate(resolve));
      assert.ok(runtime.state.commands.includes('app.stop') && runtime.state.commands.includes('daemon.shutdown'));
      assert.equal(runtime.state.sdkExited, true); assert.equal(runnerSettled, false); assert.equal(lateEffects, 0);
      assert.ok(diagnostics.some(/** Pending I/O phải được ghi nhận fixed unknown thay vì cancelled/success. */
        (value) => value.includes('NATIVE_RATE_ORACLE_IO_UNCONFIRMED')));
      releaseOracle();
      await assert.rejects(/** Late completion vẫn FAIL; SDK cleanup failure không được oracle late result che đi. */
        () => operation, { message: 'NATIVE_PREFLIGHT_CASE_FAILED' });
      await new Promise(/** Giữ unhandled observer qua event-loop turn sau late resolve/reject. */
        (resolve) => setImmediate(resolve));
      assert.equal(lateEffects, 0); assert.equal(unhandled.length, 0);
      assert.ok(diagnostics.every(/** Lỗi oracle không được phản chiếu sentinel hoặc credential. */
        (value) => !value.includes('SYNTHETIC_PRIVATE_ORACLE_REJECTION') && !value.includes(fixturePassword)));
    } finally {
      releaseOracle();
      console.log = originalLog; console.error = originalError;
      process.removeListener('unhandledRejection', trackUnhandled);
    }
  }
  console.log('NATIVE_RATE_PENDING_ORACLE_OWNED_CLEANUP_PASS');
  for (const mode of ['checkpoint-success', 'checkpoint-missing', 'checkpoint-remaining-only', 'checkpoint-boolean', 'checkpoint-zero',
    'checkpoint-oversized', 'checkpoint-status-late', 'checkpoint-ack-total', 'checkpoint-repeat', 'checkpoint-order',
    'checkpoint-on-pass', 'checkpoint-premature-pass', 'checkpoint-callback-throw', 'checkpoint-callback-late',
    'checkpoint-callback-value', 'checkpoint-then-getter', 'checkpoint-foreign-phase', 'checkpoint-missing-phase',
    'checkpoint-final-foreign-phase', 'checkpoint-final-missing-phase']) {
    const runtime = fakeSdkRuntime(mode, 'rate-limit');
    const callbacks = []; const checkpointGuards = []; const diagnostics = []; const originalLog = console.log; const originalError = console.error;
    console.log = /** Giữ marker routine của actual runner trong RAM, suite chỉ xuất fixed result. */ (value) => { diagnostics.push(String(value)); };
    console.error = /** Không forward exception hoặc callback sentinel, chỉ kiểm boundary output. */ (value) => { diagnostics.push(String(value)); };
    try {
      const operation = runNativePhase({ version: 1, phase: 'rate-limit', emails: [], password: fixturePassword }, 'PUBLIC_TEST_CERTIFICATE',
        undefined, fixturePassword,
        /**
         * Sync oracle dùng guard thực để kiểm cumulative ACK budget và invalid callback result.
         * Input
         * Param: stage — nhãn intent hiện tại đã được parser/sequence kiểm.
         * Param: admission — guard immutable của chính checkpoint, không thể mở lại sau return.
         */
        (stage, admission) => {
          for (const previous of checkpointGuards) assert.throws(
            /** Guard stage trước phải đóng vĩnh viễn, không được scope mới mở lại authority còn trong5s cũ. */
            () => previous.assertActive(), { message: 'NATIVE_RATE_CHECKPOINT_UNAVAILABLE' });
          checkpointGuards.push(admission);
          admission.assertActive(); callbacks.push(stage);
          if (mode === 'checkpoint-callback-throw') throw new Error('SYNTHETIC_PRIVATE_CHECKPOINT_FAILURE');
          if (mode === 'checkpoint-callback-late') { runtime.state.clock += 5000; admission.assertActive(); }
          if (mode === 'checkpoint-callback-value') return 1;
          if (mode === 'checkpoint-then-getter') return {
            /** Getter lỗi kiểm boundary sanitization, không khởi tạo I/O hoặc thực thi then capability. */
            get then() {
            // Getter thất bại không cho phép suy đã hủy một I/O mà harness không lấy được capability.
            throw new Error('SYNTHETIC_PRIVATE_CHECKPOINT_FAILURE');
          } };
        }, runtime);
      if (mode === 'checkpoint-success') {
        assert.equal(await operation, 8123);
        assert.deepEqual(callbacks, checkpointStages); assert.deepEqual(runtime.state.acceptedCheckpoints, checkpointStages);
        assert.equal(runtime.state.checkpointWrites, 66);
      } else await assert.rejects(/** Mọi metadata/sequence/timing violation phải ngăn native success và chạy cleanup. */ () => operation);
      assert.ok(runtime.state.commands.includes('app.stop') && runtime.state.commands.includes('daemon.shutdown'));
      if (['checkpoint-missing', 'checkpoint-remaining-only', 'checkpoint-boolean', 'checkpoint-zero', 'checkpoint-oversized',
        'checkpoint-status-late', 'checkpoint-order', 'checkpoint-on-pass', 'checkpoint-premature-pass',
        'checkpoint-foreign-phase', 'checkpoint-missing-phase'].includes(mode)) {
        assert.equal(callbacks.length, 0); assert.equal(runtime.state.checkpointWrites, 0);
      }
      if (mode === 'checkpoint-ack-total') { assert.equal(callbacks.length, 1); assert.equal(runtime.state.checkpointWrites, 5); }
      if (mode.startsWith('checkpoint-callback') || mode === 'checkpoint-then-getter') assert.equal(runtime.state.checkpointWrites, 0);
      if (mode === 'checkpoint-repeat') assert.equal(callbacks.length, 1);
      if (mode.startsWith('checkpoint-final-')) {
        assert.deepEqual(callbacks, checkpointStages); assert.equal(runtime.state.checkpointWrites, 66);
        assert.ok(!diagnostics.includes('NATIVE_INTEGRATION_TARGET_RATE-LIMIT_PASS'));
      }
      assert.ok(diagnostics.every(/** Error boundary không phản chiếu raw callback hoặc mật khẩu. */
        (value) => !value.includes('SYNTHETIC_PRIVATE_CHECKPOINT_FAILURE') && !value.includes(fixturePassword)));
    } finally { console.log = originalLog; console.error = originalError; }
  }
  console.log('NATIVE_RATE_CHECKPOINT_ORDER_SHARED_DEADLINE_PASS');
  for (const outcome of ['resolve', 'reject', 'then-throws']) {
    const runtime = fakeSdkRuntime('checkpoint-success', 'rate-limit');
    let release; let entered = false; let runnerSettled = false; let lateEffect = 0;
    const pending = new Promise(
      /** Giữ callback sai hợp đồng pending để chứng minh SDK cleanup không bỏ I/O ownership. */
      (resolve, reject) => {
        release = /** Late rejection chỉ thuộc fake callback, không được leak hoặc unhandled. */
          () => outcome === 'reject' ? reject(new Error('SYNTHETIC_PRIVATE_CHECKPOINT_FAILURE')) : resolve();
      });
    const diagnostics = []; const unhandled = []; const originalLog = console.log; const originalError = console.error;
    const trackUnhandled = /** Ghi late Promise rejection mà không phản chiếu reason. */ () => { unhandled.push(true); };
    process.on('unhandledRejection', trackUnhandled);
    console.log = /** Chỉ thu public runner markers để không xuất routine logs của fake process. */ (value) => { diagnostics.push(String(value)); };
    console.error = /** Giữ UNCONFIRMED/failure markers để kiểm pending callback không bị giả cancel. */ (value) => { diagnostics.push(String(value)); };
    let operation;
    try {
      operation = runNativePhase({ version: 1, phase: 'rate-limit', emails: [], password: fixturePassword }, 'PUBLIC_TEST_CERTIFICATE',
        undefined, fixturePassword,
        /**
         * Cố tình trả async capability sai contract; fence phải đóng ngay và ACK chưa được gửi.
         * Input
         * Param: stage — stage đầu tiên từ checkpoint thật của runner fake SDK.
         * Param: admission — guard immutable được capture để kiểm late effect sau await.
         */
        (stage, admission) => {
          assert.equal(stage, 'rate-before'); admission.assertActive(); entered = true;
          if (outcome === 'then-throws') return { then:
            /** Thenable throw đồng bộ vẫn là invalid return có handler, không raw error hoặc ACK. */
            () => { throw new Error('SYNTHETIC_PRIVATE_CHECKPOINT_FAILURE'); } };
          return pending.then(
            /** Guard sau I/O phải từ chối late callback effect dù SDK đã cleanup trước đó. */
            () => { admission.assertActive(); lateEffect++; });
        }, runtime);
      operation.then(/** Theo dõi completion để không admit fixture mới khi callback I/O vẫn pending. */ () => { runnerSettled = true; },
        /** Gắn failure observer sớm để test không tạo unhandled Promise phụ. */ () => { runnerSettled = true; });
      for (let turn = 0; turn < 20 && !runtime.state.sdkExited; turn++) await new Promise(
        /** Cho actual runner nhận invalid result và bắt đầu own cleanup, không resolve I/O trước assertion. */
        (resolve) => setImmediate(resolve));
      assert.equal(entered, true); assert.equal(runtime.state.sdkExited, true); assert.equal(runtime.state.checkpointWrites, 0);
      if (outcome !== 'then-throws') {
        assert.equal(runnerSettled, false);
        assert.ok(diagnostics.includes('NATIVE_RATE_CHECKPOINT_IO_UNCONFIRMED'));
      }
      release();
      await assert.rejects(/** Resolve/reject muộn đều giữ checkpoint FAIL, không trở thành success sau cleanup. */ () => operation);
      await new Promise(/** Giữ unhandled observer thêm một event-loop turn sau thenable settle. */ (resolve) => setImmediate(resolve));
      assert.equal(lateEffect, 0); assert.equal(unhandled.length, 0);
      assert.ok(diagnostics.every(/** Public output chỉ fixed enums, không callback sentinel/fixture password. */
        (value) => !value.includes('SYNTHETIC_PRIVATE_CHECKPOINT_FAILURE') && !value.includes(fixturePassword)));
    } finally {
      release(); console.log = originalLog; console.error = originalError;
      process.removeListener('unhandledRejection', trackUnhandled);
    }
  }
  console.log('NATIVE_RATE_CHECKPOINT_INVALID_ASYNC_OWNERSHIP_PASS');
  await rateEvidenceIntegration();
  await externalAbortDuringSdkWait();
  await startupDiagnosticIntegration();
  await nativePidGateIntegration();
}

/** Kiểm gate trước spawn và sau actual SDK exit, kể cả khi startup lỗi hoặc SDK chưa terminal. */
async function nativePidGateIntegration() {
  for (const scenario of ['before-present', 'before-query-error', 'success', 'after-present', 'after-query-error',
    'startup-present', 'startup-absent', 'sdk-pending', 'spawn-throw']) {
    const mode = scenario.startsWith('startup-') ? 'startup-diagnostic-exit'
      : scenario === 'sdk-pending' ? 'evidence-cleanup-unconfirmed' : 'success';
    const runtime = fakeSdkRuntime(mode, 'full');
    const queries = []; const logs = [];
    runtime.checkPid = /** Chỉ trả receipt giả, kiểm runner không đọc PID khi SDK còn có thể launch app. */
      (pid) => {
        assert.equal(pid, null);
        queries.push({ spawned: runtime.state.spawned, sdkExited: runtime.state.sdkExited });
        if (queries.length === 1 && scenario.startsWith('before-')) throw new Error('PRIVATE_PID_QUERY_FAILURE');
        if (queries.length === 2 && ['after-present', 'after-query-error', 'startup-present'].includes(scenario)) {
          throw new Error('PRIVATE_PID_QUERY_FAILURE');
        }
      };
    if (scenario === 'sdk-pending') runtime.cleanupBudgetMilliseconds = 1;
    if (scenario === 'spawn-throw') runtime.spawnNativeProcess = /** Spawn không tạo handle nên chỉ baseline PID được kiểm. */
      () => { runtime.state.spawned++; throw new Error('PRIVATE_SPAWN_FAILURE'); };
    const savedLog = console.log; const savedError = console.error;
    console.log = /** Giữ routine marker để assertion không xuất dữ liệu lỗi. */ (value) => logs.push(String(value));
    console.error = /** Chỉ kiểm marker fixed từ consumer, không echo private boundary errors. */ (value) => logs.push(String(value));
    try {
      const operation = runNativePhase({ version: 1, phase: 'full', emails: fixtureEmails, password: fixturePassword },
        'PUBLIC_CERT', undefined, fixturePassword, undefined, runtime);
      if (scenario === 'success') assert.equal(await operation, 8123);
      else await assert.rejects(/** Gate PID hoặc startup/SDK lỗi đều phải giữ overall failure. */ () => operation,
        scenario.startsWith('startup-') ? { message: 'NATIVE_PREFLIGHT_CASE_FAILED' } : undefined);
      assert.deepEqual(queries[0], { spawned: 0, sdkExited: false });
      if (scenario.startsWith('before-')) assert.equal(runtime.state.spawned, 0);
      if (scenario.startsWith('before-') || ['sdk-pending', 'spawn-throw'].includes(scenario)) assert.equal(queries.length, 1);
      else {
        assert.equal(queries.length, 2);
        assert.deepEqual(queries[1], { spawned: 1, sdkExited: true });
      }
      if (['after-present', 'after-query-error', 'startup-present', 'sdk-pending'].includes(scenario)) {
        assert.ok(logs.includes('NATIVE_PACKAGE_STOP_UNCONFIRMED'));
      }
      assert.ok(logs.every(/** Không phản chiếu lỗi OS/fixture vào diagnostics. */
        (line) => !line.includes('PRIVATE_') && !line.includes(fixturePassword)));
    } finally {
      if (scenario === 'sdk-pending') runtime.state.exitSdk();
      console.log = savedLog; console.error = savedError;
    }
  }
  console.log('NATIVE_PID_SPAWN_TERMINAL_FAILURE_GATE_PASS');
}

async function startupDiagnosticIntegration() {
  const runtime = fakeSdkRuntime('startup-diagnostic-exit', 'preflight');
  const logs = []; const savedLog = console.log; const savedError = console.error;
  console.log = (value) => logs.push(String(value)); console.error = (value) => logs.push(String(value));
  try {
    await assert.rejects(() => runNativePhase({ version: 1, phase: 'preflight', emails: fixtureEmails, password: fixturePassword },
      undefined, undefined, fixturePassword, undefined, runtime));
    const output = logs.find((line) => line.startsWith('{"kind":"NATIVE_STARTUP_DIAGNOSTIC"'));
    assert.ok(output);
    const diagnostic = JSON.parse(output).startupObservations;
    assert.equal(diagnostic.sdkExitKind, 'CODE_3'); assert.equal(diagnostic.stopErrorField, 'PRESENT');
    assert.equal(diagnostic.rawMarkerSeen, true); assert.equal(diagnostic.ownedMarkerSeen, true);
    assert.ok(diagnostic.tags.includes('DEVFS_FAILURE'));
    assert.ok(logs.every((line) => !line.includes('PRIVATE_DEBUG_TOKEN') && !line.includes('PRIVATE_DIAGNOSTIC_SENTINEL')));
  } finally { console.log = savedLog; console.error = savedError; }
  console.log('NATIVE_STARTUP_DIAGNOSTICS_ACTUAL_RUNNER_BOUNDARY_PASS');
}

async function externalAbortDuringSdkWait() {
  const beforeSpawn = fakeSdkRuntime('success', 'rate-limit');
  const unavailable = new AbortController(); unavailable.abort();
  const evidence = createNativeRateEvidence({ fixture: { snapshot: async () => [] }, readCounts: () => ({}),
    externalSignal: unavailable.signal, workDeadline: beforeSpawn.workDeadline, now: beforeSpawn.now });
  const prePacket = createNativeRatePacket({ runId: fixtureRunId, emails: fixtureEmails }, fixturePassword);
  const originalPreLog = console.log; const originalPreError = console.error;
  console.log = () => {}; console.error = () => {};
  try {
    await assert.rejects(() => runNativePhase(prePacket, 'PUBLIC_CERTIFICATE', undefined, fixturePassword, undefined,
      { ...beforeSpawn, rateEvidence: evidence }));
    assert.equal(beforeSpawn.state.spawned, 0);
  } finally { evidence.seal(); console.log = originalPreLog; console.error = originalPreError; }
  for (const stage of ['startup', 'channel']) {
    const runtime = fakeSdkRuntime(`evidence-external-wait-${stage}`, 'rate-limit');
    const controller = new AbortController(); runtime.externalSignal = controller.signal;
    runtime.state.abortExternal = () => controller.abort();
    let releaseFixture; let fixtureStop = false; let settled = false;
    const fixtureTerminal = new Promise((resolve) => { releaseFixture = resolve; });
    const packet = createNativeRatePacket({ runId: fixtureRunId, emails: fixtureEmails }, fixturePassword);
    const originalLog = console.log; const originalError = console.error;
    console.log = () => {}; console.error = () => {};
    const operation = runNativeRatePhase(packet, 'PUBLIC_CERTIFICATE', {
      snapshot: async () => [],
      close: async () => { fixtureStop = true; await fixtureTerminal; },
    }, () => ({ AUTH_LOGIN: 0, AUTH_LOGOUT: 0, PROFILE_READ: 0, WORKSPACE_LIST: 0, PASSWORD_CHANGE: 0, OTHER: 0 }),
    runtime.workDeadline, runtime);
    operation.then(() => { settled = true; }, () => { settled = true; });
    try {
      for (let i = 0; i < 100 && !runtime.state.commands.includes('daemon.shutdown'); i++) await new Promise((resolve) => setImmediate(resolve));
      assert.ok(runtime.state.commands.includes('daemon.shutdown'));
      assert.equal(runtime.state.waitPolls, 1); assert.equal(runtime.state.sdkExited, false);
      assert.equal(fixtureStop, false); assert.equal(settled, false);
      runtime.state.exitSdk();
      for (let i = 0; i < 20 && !fixtureStop; i++) await new Promise((resolve) => setImmediate(resolve));
      assert.equal(fixtureStop, true); assert.equal(settled, false);
      releaseFixture(); await assert.rejects(() => operation);
      assert.equal(runtime.state.fixtureWrites, 0);
    } finally {
      runtime.state.exitSdk(); releaseFixture(); await operation.catch(() => {});
      console.log = originalLog; console.error = originalError;
    }
  }
  console.log('NATIVE_RATE_SDK_STARTUP_CHANNEL_ABORT_WAKE_PASS');
}

/**
 * Gọi wrapper/capsule/parser/SDK cleanup thật qua process boundary giả, không chỉ test một bản sao ledger.
 * Snapshot raw và owned fixture exit được giữ tách biệt để observer rejection không giả SQL terminal.
 */
async function rateEvidenceIntegration() {
  const seed = { sessionId: '11111111-1111-4111-8111-111111111111', revoked: false };
  const app = { sessionId: '22222222-2222-4222-8222-222222222222', revoked: true };
  const counterModes = ['counter-schema-negative-baseline', 'counter-duplicate-0'];
  // Baseline0 không thể thiếu POST hợp lệ; -1 chỉ là schema negative riêng trước SDK.
  // Checkpoint0 được inject sau spawn để baseline hợp lệ không che nhánh rate-before.
  for (let index = 1; index < checkpointStages.length; index++) {
    counterModes.push(`counter-missing-${index}`, `counter-duplicate-${index}`);
  }
  for (const mode of [...counterModes, 'mid-extra', 'mid-missing', 'mid-replaced',
    'final-missing', 'final-replaced', 'final-changed', 'live-pid-mismatch', 'wrapper-post-pid',
    'success', 'advancing-clock', 'late-429', 'mid-rpc-pending', 'external-rpc-pending', 'baseline-pending', 'final-pending', 'final-late-reject',
    'final-sdk-exit', 'final-sdk-boundary',
    'baseline-observer-error', 'observer-error', 'changed-mid', 'active-final', 'counter-after-stop', 'counter-before-login', 'cleanup-failure',
    'cleanup-unconfirmed', 'echo-stdout-correct', 'echo-stdout-wrong', 'echo-stderr-correct', 'echo-stderr-wrong']) {
    const counterCase = /^counter-(missing|duplicate)-(\d+)$/.exec(mode);
    const counterIndex = counterCase ? Number(counterCase[2]) : undefined;
    const midPending = ['mid-rpc-pending', 'external-rpc-pending'].includes(mode);
    const runtime = fakeSdkRuntime(`evidence-${midPending ? 'mid-rpc-pending' : mode}`, 'rate-limit');
    const unavailable = new AbortController();
    if (mode === 'external-rpc-pending') runtime.externalSignal = unavailable.signal;
    const timers = new Set(); const snapshots = []; const pidChecks = [];
    const snapshotMutations = [];
    let rawRelease; let closeRelease; let closeEntered = false; let fixtureTerminal = false; let settled = false;
    const raw = new Promise(/** Raw observer giả còn pending tới lúc test trả completion thật. */
      (resolve, reject) => { rawRelease = { resolve, reject }; });
    const fixtureExit = new Promise(/** Fixture close chỉ resolve khi actual owned shim terminal/readback giả được cấp. */
      (resolve) => { closeRelease = resolve; });
    if (mode === 'cleanup-failure') runtime.state.cleanupExitCode = 1;
    if (mode === 'cleanup-unconfirmed') runtime.cleanupBudgetMilliseconds = 2;
    runtime.evidenceTimers = {
      setTimeout: /** Timer capability thật trong capsule, chỉ thay scheduling để không đợi130s trong host suite. */
        (callback, milliseconds) => { const timer = { callback, deadline: runtime.state.clock + milliseconds }; timers.add(timer); return timer; },
      clearTimeout: /** Chỉ release timer owned, không giải phóng raw SQL Promise. */ (timer) => { timers.delete(timer); },
    };
    runtime.checkPid = /** PID oracle không gọi ADB trong test, nhưng wrapper phải kiểm trước/sauSDK stop đúng thứ tự. */
      (pid) => {
        pidChecks.push(pid);
        if ((mode === 'live-pid-mismatch' && pid === 8123) ||
          (mode === 'wrapper-post-pid' && pidChecks.length === 4)) {
          throw new Error('NATIVE_PID_MISMATCH');
        }
      };
    const fixture = {
      snapshot:
        /** Ba SNAPSHOT full thật của wrapper; mid chỉ được start sau42ACK thuộc7stage đầu. */
        async (scope) => {
          assert.equal(scope, 'full'); const number = snapshots.length + 1;
          snapshots.push({ number, checkpointWrites: runtime.state.checkpointWrites, sdkExited: runtime.state.sdkExited });
          if (number === 2) assert.equal(runtime.state.checkpointWrites, 42);
          if (number === 3) assert.deepEqual(runtime.state.acceptedCheckpoints, checkpointStages);
          if ((mode === 'baseline-pending' && number === 1) || (midPending && number === 2) ||
            (['final-pending', 'final-late-reject', 'final-sdk-exit', 'final-sdk-boundary'].includes(mode) && number === 3)) return raw;
          if (mode === 'baseline-observer-error' && number === 1) throw new Error('PRIVATE_SNAPSHOT_SENTINEL');
          if (mode === 'observer-error' && number === 2) throw new Error('PRIVATE_SNAPSHOT_SENTINEL');
          if (mode === 'changed-mid' && number === 2) return [{ ...seed, revoked: true }];
          // Receipt test xác nhận malformed rows đã tới capsule, tránh xanh do lỗi trước snapshot.
          if ((number === 2 && ['mid-extra', 'mid-missing', 'mid-replaced'].includes(mode)) ||
            (number === 3 && ['final-missing', 'final-replaced', 'final-changed'].includes(mode))) snapshotMutations.push(mode);
          // Cùng size nhưng đổi UUID phải bị bắt bởi identity guard, không chỉ size check.
          if (number === 2 && mode === 'mid-extra') return [seed, app];
          if (number === 2 && mode === 'mid-missing') return [];
          if (number === 2 && mode === 'mid-replaced') return [{ ...app, revoked: seed.revoked }];
          if (number === 3 && mode === 'final-missing') return [app];
          if (number === 3 && mode === 'final-replaced') return [app,
            { sessionId: '33333333-3333-4333-8333-333333333333', revoked: false }];
          if (number === 3 && mode === 'final-changed') return [{ ...seed, revoked: true }, app];
          return number === 3 ? [seed, mode === 'active-final' ? { ...app, revoked: false } : app] : [seed];
        },
      close:
        /** Phải thử owned STOP sau SDK cleanup kể cả khi SDK exitcode lỗi; baseline chưa có SDK thì đóng ngay. */
        async () => {
          closeEntered = true;
          if (mode === 'cleanup-unconfirmed') {
            assert.equal(runtime.state.sdkExited, false); assert.equal(runtime.state.awaitingExit, true);
            assert.equal(runtime.state.killRequested, true); assert.equal(runtime.state.unrefRequested, true);
          } else if (runtime.state.spawned > 0) assert.equal(runtime.state.sdkExited, true);
          await fixtureExit; fixtureTerminal = true;
        },
    };
    const diagnostics = []; const unhandled = []; const originalLog = console.log; const originalError = console.error;
    const trackUnhandled = /** Không lưu raw Promise reason có thể chứa dữ liệu SQL. */ () => { unhandled.push(true); };
    process.on('unhandledRejection', trackUnhandled);
    console.log = /** Thu marker để bắt phase PASS sớm trước SDK/fixture gates. */ (value) => { diagnostics.push(String(value)); };
    console.error = /** Chỉ fixed diagnostics được phép qua output boundary. */ (value) => { diagnostics.push(String(value)); };
    let operation;
    const ratePacket = createNativeRatePacket({ runId: fixtureRunId, emails: fixtureEmails }, fixturePassword);
    const wrongPassword = ratePacket.wrongPassword;
    try {
      operation = runNativeRatePhase(ratePacket,
        'PUBLIC_TEST_CERTIFICATE', fixture,
        /** Cùng6counter dùng bởi wrapper/capsule ở mọistage và sauSDKstop. */
        () => {
          const i = Math.min(runtime.state.checkpointIndex, 10);
          const result = { AUTH_LOGIN: i <= 6 ? i : i <= 8 ? 6 : 7,
            AUTH_LOGOUT: i === 10 ? 1 : 0, PROFILE_READ: i >= 9 ? 1 : 0, WORKSPACE_LIST: i >= 9 ? 1 : 0,
            PASSWORD_CHANGE: 0, OTHER: 0 };
          if (mode === 'counter-after-stop' && runtime.state.sdkExited) result.AUTH_LOGIN++;
          if (mode === 'counter-before-login' && i === 6) result.PROFILE_READ++;
          if (mode === 'counter-schema-negative-baseline') result.AUTH_LOGIN = -1;
          if (counterCase && i === counterIndex && (counterIndex !== 0 || runtime.state.spawned > 0)) {
            result.AUTH_LOGIN += counterCase[1] === 'missing' ? -1 : 1;
          }
          return result;
        }, runtime.workDeadline, runtime);
      operation.then(/** Theo dõi outer completion, không bỏ Promise rejection ngoài test. */ () => { settled = true; },
        /** Lỗi chỉ được settle sau same owned cleanup/raw operations. */ () => { settled = true; });
      if (['baseline-pending', 'mid-rpc-pending', 'external-rpc-pending', 'final-pending', 'final-late-reject', 'final-sdk-exit', 'final-sdk-boundary'].includes(mode)) {
        const expected = mode === 'baseline-pending' ? 1 : midPending ? 2 : 3;
        for (let turn = 0; turn < 100 && (snapshots.length < expected || (midPending && !runtime.state.blockedReply)); turn++) {
          await new Promise(/** Cho actual runner tới pending RPC trước khi snapshot timer fail. */ (resolve) => setImmediate(resolve));
        }
        assert.equal(snapshots.length, expected);
        if (midPending) assert.equal(typeof runtime.state.blockedReply, 'function');
        if (mode === 'final-sdk-exit') runtime.state.exitSdk();
        else if (mode === 'final-sdk-boundary') runtime.state.failSdkBoundary();
        else if (mode === 'external-rpc-pending') unavailable.abort();
        else {
          const timer = [...timers][0]; assert.ok(timer);
          runtime.state.clock = timer.deadline; timer.callback();
        }
      }
      if (['success', 'advancing-clock'].includes(mode)) {
        assert.equal(await operation, 8123); assert.equal(closeEntered, false);
        assert.deepEqual(pidChecks, [null, 8123, null, null]); assert.equal(snapshots.length, 3);
        assert.ok(diagnostics.includes('NATIVE_RATE_HOST_EVIDENCE_PASS'));
      } else {
        for (let turn = 0; turn < 100 && !closeEntered; turn++) await new Promise(
          /** Cleanup observer2ms cần clock thật tiến, chỉ case unconfirmed chờ notification ngắn. */
          (resolve) => mode === 'cleanup-unconfirmed' ? setTimeout(resolve, 1) : setImmediate(resolve));
        assert.equal(closeEntered, true); assert.equal(settled, false); assert.equal(fixtureTerminal, false);
        assert.ok(!diagnostics.includes('NATIVE_RATE_HOST_EVIDENCE_PASS'));
        // Observer đã reject hoặc timer đã hết không đủ: outer vẫn pending tới owned fixture terminal/cleanup.
        closeRelease();
        if (mode === 'cleanup-unconfirmed') {
          await new Promise(/** Fixture terminal xong vẫn chưa giải phóng SDK ownership. */ (resolve) => setImmediate(resolve));
          assert.equal(fixtureTerminal, true); assert.equal(settled, false); assert.equal(runtime.state.sdkExited, false);
          runtime.state.exitSdk();
        }
        if (['baseline-pending', 'mid-rpc-pending', 'external-rpc-pending', 'final-pending', 'final-late-reject', 'final-sdk-exit', 'final-sdk-boundary'].includes(mode)) {
          await new Promise(/** Cho fixture terminal trước assertion raw Promise còn thuộc wrapper. */ (resolve) => setImmediate(resolve));
          assert.equal(fixtureTerminal, true); assert.equal(settled, false);
          if (midPending) runtime.state.blockedReply();
          if (mode === 'final-late-reject') rawRelease.reject(new Error('PRIVATE_SNAPSHOT_SENTINEL'));
          else rawRelease.resolve([seed]);
        }
        await assert.rejects(/** Không trường hợp late/failure nào được nâng lên success bởi cleanup hoặc rows muộn. */ () => operation);
        assert.equal(fixtureTerminal, true);
        if (mode === 'late-429') assert.equal(runtime.state.acceptedCheckpoints.length, 6);
        if (midPending) assert.equal(runtime.state.acceptedCheckpoints.length, 7);
        if (mode === 'baseline-pending') assert.equal(runtime.state.spawned, 0);
        if (counterCase) {
          // Không ACK cho stage có POST lệch dù SDK và fixture cleanup cuối cùng đều thành công.
          assert.equal(runtime.state.acceptedCheckpoints.length, counterIndex);
          assert.equal(runtime.state.spawned, 1);
          if (counterIndex === 0) assert.equal(snapshots.length, 1);
        }
        if (mode === 'counter-schema-negative-baseline') {
          assert.equal(runtime.state.spawned, 0); assert.equal(snapshots.length, 0);
        }
        if (['mid-extra', 'mid-missing', 'mid-replaced'].includes(mode)) {
          assert.equal(snapshots.length, 2); assert.deepEqual(snapshotMutations, [mode]);
          assert.ok(runtime.state.acceptedCheckpoints.length >= 7 && runtime.state.acceptedCheckpoints.length <= 8);
          assert.ok(!runtime.state.acceptedCheckpoints.includes('rate-expired'));
        }
        if (['final-missing', 'final-replaced', 'final-changed'].includes(mode)) {
          assert.equal(snapshots.length, 3); assert.deepEqual(snapshotMutations, [mode]);
          assert.deepEqual(runtime.state.acceptedCheckpoints, checkpointStages);
        }
        if (mode === 'live-pid-mismatch') assert.equal(snapshots.length, 2);
        if (mode === 'wrapper-post-pid') assert.deepEqual(pidChecks, [null, 8123, null, null]);
      }
      assert.ok(!diagnostics.includes('NATIVE_INTEGRATION_TARGET_RATE-LIMIT_PASS'));
      assert.ok(diagnostics.every(/** Không echo private SQL sentinel hoặc credential synthetic. */
        (value) => !value.includes('PRIVATE_SNAPSHOT_SENTINEL') && !value.includes(fixturePassword) && !value.includes(wrongPassword)));
      assert.equal(ratePacket.password, ''); assert.equal(ratePacket.wrongPassword, '');
      assert.equal(timers.size, 0); assert.equal(unhandled.length, 0);
    } finally {
      rawRelease.resolve([seed]); closeRelease();
      if (mode === 'cleanup-unconfirmed') runtime.state.exitSdk();
      if (operation) await operation.catch(/** Teardown giữ Promise ownership ngay cả khi assertion của test fail. */ () => {});
      console.log = originalLog; console.error = originalError; process.removeListener('unhandledRejection', trackUnhandled);
    }
  }
  console.log('NATIVE_RATE_ACTUAL_WRAPPER_SNAPSHOT_OWNERSHIP_PASS');
  for (const invalid of ['phase', 'counts', 'deadline']) {
    let closed = false; let release; let settled = false;
    const exit = new Promise(/** Invalid input không được làm mất owned fixture đã READY. */ (resolve) => { release = resolve; });
    const invalidPacket = createNativeRatePacket({ runId: fixtureRunId, emails: fixtureEmails }, fixturePassword);
    if (invalid === 'phase') invalidPacket.phase = 'invalid';
    const operation = runNativeRatePhase(invalidPacket, 'PUBLIC_CERT',
      { snapshot: /** Constructor fail trước snapshot nên không có SQL mới. */ () => assert.fail('UNEXPECTED_SNAPSHOT'),
        close: /** Owned STOP phải được thử cả khi capsule chưa khởi tạo. */ async () => { closed = true; await exit; } },
      invalid === 'counts' ? undefined : /** Counter input hợp lệ không dùng trong case config invalid khác. */ () => ({}),
      invalid === 'deadline' ? NaN : 2_400_000);
    operation.then(/** Không return success trên invalid configuration. */ () => { settled = true; },
      /** Theo dõi failure nhưng phải pending tới owned exit. */ () => { settled = true; });
    await Promise.resolve(); assert.equal(closed, true); assert.equal(settled, false);
    release(); await assert.rejects(/** Invalid input giữ cleanup ownership trước reject. */ () => operation);
  }
  console.log('NATIVE_RATE_CONFIGURATION_FAILURE_OWNED_STOP_PASS');
  for (const malformed of ['missing-wrong', 'same-secret', 'invalid-shape', 'extra-field', 'wrong-version', 'wrong-namespace', 'frozen']) {
    const packet = createNativeRatePacket({ runId: fixtureRunId, emails: fixtureEmails }, fixturePassword);
    if (malformed === 'missing-wrong') delete packet.wrongPassword;
    if (malformed === 'same-secret') packet.wrongPassword = packet.password;
    if (malformed === 'invalid-shape') packet.wrongPassword = 'not-a-private-secret';
    if (malformed === 'extra-field') packet.extra = true;
    if (malformed === 'wrong-version') packet.version = 2;
    if (malformed === 'wrong-namespace') packet.emails[1] = 'different@example.invalid';
    if (malformed === 'frozen') Object.freeze(packet);
    let closed = false;
    await assert.rejects(/** Malformed packet không được tới snapshot/SDK nhưng vẫn phải close owned fixture. */
      () => runNativeRatePhase(packet, 'PUBLIC_CERT', {
        snapshot: /** Không SQL cho packet chưa qua validation. */ () => assert.fail('UNEXPECTED_SNAPSHOT'),
        close: /** Chỉ mock lifecycle boundary, không role/DB mutation trong host suite. */ async () => { closed = true; },
      }, /** Counter capability không được gọi trước validation. */ () => assert.fail('UNEXPECTED_COUNTER'), 2_400_000,
      { spawnNativeProcess: /** Không spawn SDK khi private packet malformed. */ () => assert.fail('UNEXPECTED_SDK') }));
    assert.equal(closed, true);
  }
  console.log('NATIVE_RATE_PRIVATE_PACKET_TWO_SECRET_SCAN_PASS');
}

try { await main(); } catch (error) {
  // Không xuất assertion/argv/packet, kết quả host chỉ marker cố định; không phải native actual evidence.
  const line = /test_native_rpc_deadline\.mjs:(\d+)/.exec(error.stack)?.[1] ?? 'UNKNOWN';
  console.error(`NATIVE_RATE_RPC_DEADLINE_FAILED line=${line}`); process.exitCode = 1;
}
