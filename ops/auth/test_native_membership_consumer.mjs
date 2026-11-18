import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { containsNativeSecret, nativePhaseBudget, runNativePhase } from './run_native_e2e.mjs';

const password = 'Aa1' + 'c'.repeat(32);
const runId = 'aaaaaaaa-1111-4111-8111-111111111111';
const stages = ['membership-before-login', 'membership-picker', 'membership-denied',
  'membership-only-a', 'membership-a-opened', 'membership-logged-out'];

/**
 * Mô phỏng đúng pipe/process/clock boundary cho consumer thật, không SDK/ADB/SQL hoặc auth API.
 * Input
 * Param: mode — fault cố định của test, chỉ metadata synthetic.
 * Param: phase — membership/offline outbox/offline resume, chỉ điều chỉnh SDK metadata synthetic.
 * Output: trusted runtime cùng state do case sở hữu và terminal event giả phải quan sát rõ.
 */
export function createFakeMembershipRuntime(mode, phase = 'membership-stale') {
  assert.ok(['membership-stale', 'offline-login', 'offline-expired', 'offline-resume'].includes(phase));
  const offline = ['offline-login', 'offline-expired'].includes(phase);
  const offlineOutboxStages = ['offline-ready', 'offline-result', 'offline-quiet', 'offline-picker',
    'offline-outbox-ready', 'offline-outbox-persisted'];
  const offlineResumeStages = ['offline-outbox-resumed', 'offline-logged-out'];
  const offlineExpiredStages = ['offline-expired-offline', 'offline-expired-ready', 'offline-expired-persisted'];
  const offlineCaps = { 'offline-ready': 110_000, 'offline-result': 110_000, 'offline-quiet': 170_000,
    'offline-picker': 170_000, 'offline-outbox-ready': 170_000, 'offline-outbox-persisted': 170_000,
    'offline-expired-offline': 110_000, 'offline-expired-ready': 170_000,
    'offline-expired-persisted': 170_000,
    'offline-outbox-resumed': 170_000, 'offline-logged-out': 120_000 };
  const state = { clock: 0, spawned: 0, accepted: [], callbacks: [], fixtureWrites: 0,
    commands: [], index: 0, sdkExited: false, returned: false,
    activePhase: phase === 'offline-resume' ? 'resume' : phase };
  /** Chọn chuỗi checkpoint gắn với packet hiện hành, để mỗi process khởi động lại từ stage đầu. */
  function currentPhaseStages() {
    if (state.activePhase === 'offline-login') return offlineOutboxStages;
    if (state.activePhase === 'offline-expired') return offlineExpiredStages;
    if (state.activePhase === 'resume') return offlineResumeStages;
    return stages;
  }
  /** Xác định phase cần gate thời gian offline mà không làm thay clock liên tiến trình. */
  function currentPhaseIsOffline() {
    return state.activePhase === 'offline-login' || state.activePhase === 'offline-expired' || state.activePhase === 'resume';
  }
  const external = new AbortController();
  if (mode === 'external-pre-spawn') external.abort();
  const child = new EventEmitter();
  child.pid = 9123;
  child.stdin = new EventEmitter(); child.stdout = new EventEmitter(); child.stderr = new EventEmitter();
  const appId = 'bbbbbbbb-2222-4222-8222-222222222222';
  let finishSdk;
  state.sdkExit = new Promise(
    /**
     * Giữ observer fake terminal riêng, SDKstop không tự hoàn tất SQL callback.
     * Input
     * Param: resolve — completion capability chỉ được gọi sau child exit event fake.
     */
    (resolve) => { finishSdk = resolve; });
  /**
   * Gửi metadata fake vào parser thật, không sửa state/ownership của runner.
   * Input
   * Param: messages — envelope SDK synthetic do case sở hữu, không chứa credential.
   */
  function emit(messages) { child.stdout.emit('data', Buffer.from(JSON.stringify(messages) + '\n')); }
  child.stdin.write =
    /**
     * Reply đúng request id, ghi fixed commands để kiểm thứ tự cleanup và ACK.
     * Input
     * Param: value — JSON SDK request private trong RAM, không log packet/secret.
     */
    (value) => {
      const [request] = JSON.parse(value);
      state.commands.push(request.method);
      if (request.method === 'app.stop') {
        emit([{ event: 'app.stop', params: { appId } }, { id: request.id, result: {} }]); return;
      }
      if (request.method === 'daemon.shutdown') {
        emit([{ id: request.id, result: {} }]);
        state.sdkExited = true; child.emit('exit', 0); finishSdk(); return;
      }
      assert.equal(request.method, 'app.callServiceExtension');
      const extension = request.params.methodName;
      let result;
      if (extension.endsWith('.fixture')) {
        const packet = JSON.parse(request.params.params.packet);
        if (packet.version === 1 && packet.phase === 'resume') state.activePhase = 'resume';
        result = { accepted: packet.version === 1 && state.fixtureWrites++ === 0 };
        if (mode === 'channel-late') state.clock += 25_000;
      } else if (extension.endsWith('.checkpoint')) {
        const params = request.params.params;
        const expected = currentPhaseStages()[state.index];
        const accepted = Object.keys(params).length === 1 && params.stage === expected;
        if (accepted) { state.accepted.push(expected); state.index++; }
        result = { accepted };
        if (mode === 'ack-total' && state.reportedStage === 'membership-picker') state.clock += 6000;
      } else {
        result = { phase: state.activePhase, status: 'WAITING', nativeProcessId: 8123,
          ...(['offline-login', 'offline-expired'].includes(state.activePhase) && state.fixtureWrites < 2
            ? { preArmRemainingMilliseconds: 240_000 } : {}) };
        if (state.fixtureWrites >= 2) {
          if (state.index === currentPhaseStages().length || mode === 'early-pass') result.status = 'PASS';
          else {
            let stage = currentPhaseStages()[state.index];
            if (mode === 'stage-order') stage = currentPhaseStages()[1];
            const remaining = currentPhaseIsOffline() ? offlineCaps[stage] : stage === 'membership-picker' ? 210_000 : 5000;
            result.checkpoint = stage; state.reportedStage = stage;
            result.checkpointRemainingMilliseconds = remaining;
            if (mode === 'oversized' || (mode === 'picker-oversized' && stage === 'membership-picker')) result.checkpointRemainingMilliseconds = remaining + 1;
            if (mode === 'picker-send-anchor' && stage === 'membership-picker') state.clock += 10_000;
            if (mode === 'missing-remaining') delete result.checkpointRemainingMilliseconds;
            if (mode === 'status-late') state.clock += remaining;
          }
          if (mode === 'foreign-phase') result.phase = 'full';
          if (mode === 'foreign-pid' || (mode === 'final-foreign-pid' && result.status === 'PASS')) result.nativeProcessId = 8124;
          if (mode === 'final-foreign-phase' && result.status === 'PASS') result.phase = 'full';
          if (mode === 'phase-late') state.clock += currentPhaseIsOffline() ? 675_000 : 420_000;
        }
        if (mode === 'channel-late') state.clock += 25_000;
      }
      if (mode === 'external-channel' && extension.endsWith('.status')) {
        queueMicrotask(/** Abort phải đánh thức pending RPC, không chờ reply hoặc timer30s. */ () => external.abort());
        return;
      }
      if (extension.endsWith('.status')) {
        // Hook chỉ cấp metadata synthetic cho wrapper tests, không sửa ownership parser hoặc RPC result.
        assert.equal(state.onStatus?.(result), undefined);
      }
      emit([{ id: request.id, result }]);
    };
  for (const stream of [child.stdin, child.stdout, child.stderr]) {
    stream.destroy = /** Release fake stream chỉ ghi nhận ownership của host test. */ () => {};
  }
  child.kill = /** SDK fake phải cleanup qua protocol, force kill làm case thất bại. */
    () => { assert.fail('UNEXPECTED_FORCE_KILL'); };
  child.unref = /** Không dùng detach thay fake terminal exit event. */
    () => { assert.fail('UNEXPECTED_DETACH'); };
  const runtime = {
    externalSignal: external.signal,
    assertExternalActive: /** Chỉ owner signal còn live mới cho admission business work. */ () => {
      assert.equal(external.signal.aborted, false);
    },
    workDeadline: mode === 'insufficient' ? (offline ? 1_149_999 : 894_999)
      : mode === 'slow-pid-admission' ? (offline ? 1_150_000 : 895_000) : 2_000_000,
    now: /** Output: clock monotonic synthetic, không SDK/native runtime evidence. */ () => state.clock,
    pause:
      /**
       * Tiến poll clock và nhường event loop để observer pending/SDK có thể settle riêng.
       * Input
       * Param: milliseconds — khoảng poll do consumer yêu cầu.
       */
      async (milliseconds) => {
        state.clock += milliseconds;
        if (mode === 'external-startup') external.abort();
        await new Promise(/** Để pipe và promise fake được dispatch trước poll tiếp. */ (resolve) => setImmediate(resolve));
      },
    checkPid: /** Oracle OS synthetic, slow read phải trừ vào reserve trước spawn lần nữa. */ () => { if (mode === 'slow-pid-admission') state.clock++; },
    spawnNativeProcess:
      /**
       * Cấp child fake sau khi kiểm argv không có secret và private pipes không shell.
       * Input
       * Param: command — executable cố định consumer định chạy.
       * Param: arguments_ — compiler/SDK args chỉ có config công khai.
       * Param: options — phải giữ shell=false.
       */
      (command, arguments_, options) => {
        state.spawned++;
        const configuredPhase = arguments_.find(
          /** Param: argument — fixed Flutter define carrying only the current integration phase. */
          (argument) => argument.startsWith('--dart-define=AUTH_E2E_PHASE='),
        )?.slice('--dart-define=AUTH_E2E_PHASE='.length);
        assert.ok(configuredPhase);
        if (configuredPhase !== state.activePhase) {
          state.activePhase = configuredPhase;
          state.fixtureWrites = 0;
          state.index = 0;
          state.reportedStage = undefined;
        }
        assert.ok(command.endsWith('dart.exe'));
        assert.equal(options.shell, false);
        assert.ok(!arguments_.join(' ').includes(password));
        if (mode === 'startup-late') state.clock += 180_001;
        queueMicrotask(
          /** Chỉ metadata app.start/start/channel có provenance đúng mới mở fixture RPC. */
          () => {
            child.emit('spawn');
            emit([
              { event: 'app.start', params: { appId, deviceId: 'emulator-5554',
                directory: path.resolve('mobile'), mode: 'debug', launchMode: 'run' } },
              ...(mode === 'external-startup' ? [] : [{ event: 'app.started', params: { appId } }]),
              { event: 'app.log', params: { appId, log: 'NATIVE_AUTH_TEST_CHANNEL_READY' } },
            ]);
          });
        return child;
      },
  };
  return { state, runtime, external };
}

/** Kiểm async consumer thật và mọi failure vẫn own pending callback sau SDK cleanup, chỉ host fake. */
async function main() {
  assert.deepEqual(nativePhaseBudget('membership-stale'), { testMilliseconds: 420_000, reserveMilliseconds: 895_000 });
  assert.deepEqual(nativePhaseBudget('offline-expired'), { testMilliseconds: 675_000, reserveMilliseconds: 1_150_000 });
  console.log('MEMBERSHIP_PHASE_BUDGET_PASS');
  for (const mode of ['success', 'insufficient', 'slow-pid-admission', 'startup-late', 'channel-late', 'stage-order',
    'oversized', 'picker-oversized', 'picker-send-anchor', 'missing-remaining', 'status-late', 'foreign-phase', 'foreign-pid', 'final-foreign-pid', 'final-foreign-phase', 'phase-late',
    'early-pass', 'callback-failed', 'callback-late', 'ack-total', 'oracle-late',
    'checkpoint-pending', 'oracle-pending', 'external-pre-spawn', 'external-startup',
    'external-channel', 'external-checkpoint-pending', 'external-oracle-pending',
    'closing-hook-throw', 'closing-hook-async', 'closing-hook-value', 'closing-hook-pending']) {
    const { state, runtime, external } = createFakeMembershipRuntime(mode);
    if (mode.startsWith('closing-hook-')) {
      runtime.onPhaseClosing =
        /**
         * Invalid hook không được bỏ SDKcleanup hoặc cho overall PASS.
         * Input
         * Param: phasePassed — chỉ framework/business phase đã xong, SDKcleanup chưa được xác nhận.
         */
        (phasePassed) => {
          assert.equal(phasePassed, true);
          assert.equal(state.sdkExited, false);
          if (mode === 'closing-hook-throw') throw new Error('PRIVATE_CLOSING_HOOK_FAILURE');
          if (mode === 'closing-hook-async') return Promise.resolve();
          if (mode === 'closing-hook-pending') return pending;
          return true;
        };
    }
    const packet = { version: 1, phase: 'membership-stale', password,
      emails: stages.slice(0, 5).map(
        /**
         * Tạo đúng năm identities synthetic để private packet giữ shape production fixture.
         * Input
         * Param: stage — giá trị placeholder không dùng làm identity hoặc authority.
         * Param: index — vị trí0–4 trong cùng run namespace.
         */
        (stage, index) => 'probe-' + runId + '-' + index + '@example.invalid') };
    let releasePending;
    let savedAdmission;
    const pending = new Promise(
      /**
       * Tách completion callback khỏi SDK terminal để bắt consumer return sớm.
       * Input
       * Param: resolve — own capability của test, được gọi sau witness SDK đã exit.
       */
      (resolve) => { releasePending = resolve; });
    const run = runNativePhase(packet, 'PUBLIC_CERTIFICATE',
      /**
       * Oracle host fake sau UI PASS, giữ admission trước/sau async và không giả DB proof.
       * Input
       * Param: pid — native PID synthetic đã bind từ initial status.
       * Param: admission — fence immutable của final130s/work reserve.
       */
      async (pid, admission) => {
        assert.equal(pid, 8123); admission.assertActive(); savedAdmission = admission;
        if (mode === 'oracle-late') state.clock += 130_001;
        if (mode === 'oracle-pending') { state.clock += 130_001; await pending; }
        if (mode === 'external-oracle-pending') { external.abort(); await pending; }
        admission.assertActive();
      }, password,
      /**
       * Mô phỏng mid snapshot130s+suspend20s trong picker, fast stages chỉ sync counters.
       * Input
       * Param: stage — fixed sequence consumer vừa xác minh.
       * Param: admission — fence không thể dùng lại sau ACK hoặc timeout.
       */
      async (stage, admission) => {
        state.callbacks.push(stage); admission.assertActive(); savedAdmission = admission;
        if (stage === 'membership-picker') {
          if (mode === 'callback-failed') throw new Error('PRIVATE_CALLBACK_FAILURE');
          state.clock += mode === 'callback-late' || mode === 'checkpoint-pending' ? 210_001 : mode === 'picker-send-anchor' ? 200_001 : 150_000;
          if (mode === 'checkpoint-pending') await pending;
          if (mode === 'external-checkpoint-pending') { external.abort(); await pending; }
          await Promise.resolve();
        }
        admission.assertActive();
      }, runtime);
    const observed = run.then(
      /**
       * Ghi consumer return thật, SDK terminal hoặc timeout chưa đủ kết luận.
       * Input
       * Param: value — PID public của scope PASS, không state hoặc credential.
       */
      (value) => { state.returned = true; return { value }; },
      /** Giữ fixed failure flag để assertions không in exception nội bộ/packet. */
      () => { state.returned = true; return { failed: true }; });
    if (mode.endsWith('-pending')) {
      await state.sdkExit;
      await new Promise(
        /**
         * Một event-loop turn làm lộ return sớm nếu consumer bỏ pending ownership.
         * Input
         * Param: resolve — chỉ nhường event loop, không resolve callback SQL fake đang pending.
         */
        (resolve) => setImmediate(resolve));
      assert.equal(state.returned, false);
      assert.throws(savedAdmission.assertActive);
      releasePending();
    }
    const outcome = await observed;
    if (mode === 'success') {
      assert.deepEqual(outcome, { value: 8123 });
      assert.deepEqual(state.accepted, stages);
      assert.deepEqual(state.callbacks, stages);
      assert.throws(savedAdmission.assertActive);
    } else {
      assert.equal(outcome.failed, true, mode);
      if (['insufficient', 'slow-pid-admission', 'external-pre-spawn'].includes(mode)) assert.equal(state.spawned, 0);
      else {
        assert.equal(state.sdkExited, true);
        if (mode !== 'startup-late') assert.ok(state.commands.includes('app.stop'));
        assert.ok(state.commands.includes('daemon.shutdown'));
        assert.equal(packet.password, '');
      }
      if (['callback-failed', 'callback-late', 'checkpoint-pending', 'ack-total', 'picker-send-anchor', 'external-checkpoint-pending'].includes(mode)) {
        assert.deepEqual(state.callbacks, stages.slice(0, 2));
      }
    }
    console.log('MEMBERSHIP_CONSUMER_' + mode.toUpperCase().replaceAll('-', '_') + '_PASS');
  }

  {
    const { state, runtime } = createFakeMembershipRuntime('success', 'offline-expired');
    runtime.beforePacket =
      /** Offline phase phải hoàn tất owned preparation trước token packet và Android main. */
      async (admission) => { admission.assertActive(); };
    const expiredToken = 'a'.repeat(64);
    const expiredPacket = { version: 1, phase: 'offline-expired', password,
      emails: stages.slice(0, 5).map(
        /** Param: stage/index — chỉ dựng email synthetic theo cùng namespace của runner. */
        (stage, index) => 'probe-' + runId + '-' + index + '@example.invalid'),
      expiredSessionToken: expiredToken, expiredSessionId: 'bbbbbbbb-2222-4222-8222-222222222222',
      expiredSessionExpiresAt: new Date(Date.now() - 3_600_000).toISOString() };
    const result = await runNativePhase(expiredPacket, 'PUBLIC_CERTIFICATE',
      /** Param: pid/admission — completion fake sau exact checkpoint và SDK exit. */
      async (pid, admission) => { assert.equal(pid, 8123); admission.assertActive(); },
      [password, expiredToken],
      /** Param: stage/admission — host test chỉ ACK chuỗi expiry cố định đã được profile pin. */
      async (stage, admission) => { state.callbacks.push(stage); admission.assertActive(); },
      runtime);
    assert.equal(result, 8123);
    assert.deepEqual(state.accepted, ['offline-expired-offline', 'offline-expired-ready',
      'offline-expired-persisted']);
    assert.deepEqual(state.callbacks, state.accepted);
    assert.equal(containsNativeSecret('prefix' + expiredToken + 'suffix', [password, expiredToken]), true);
    console.log('OFFLINE_EXPIRED_CONSUMER_CHECKPOINTS_PASS');
  }
}
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) await main();
