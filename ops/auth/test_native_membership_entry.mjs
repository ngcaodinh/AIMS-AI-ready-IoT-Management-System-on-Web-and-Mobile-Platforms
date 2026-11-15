import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { randomUUID } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { runActualMembership } from './run_native_membership_e2e.mjs';

/** Output: một event-loop turn để fake child/server phát raw terminal trước kiểm settlement. */
const turn = () => new Promise(/** Param: resolve — continuation của testcase, không cấp ACK lifecycle. */
  (resolve) => setImmediate(resolve));

for (const mode of ['success', 'phase-failure', 'bind-failure', 'bind-timeout']) {
  const child = new EventEmitter(); child.pid = 4245;
  child.stdin = new EventEmitter(); child.stdout = new EventEmitter(); child.stderr = new EventEmitter();
  const server = new EventEmitter();
  const runId = randomUUID(); const workspaceId = randomUUID();
  const userIds = Array.from({ length: 5 }, /** Output: UUID synthetic riêng của từng account fixture giả. */ () => randomUUID());
  const state = { stops: 0, closes: 0, phase: false, settled: false, listenerCallback: undefined };
  const timers = new Set();

  /**
   * Đưa metadata fake vào original fixture parser, không phát credential hoặc raw config.
   * Input
   * Param: frame — READY/target/evidence/STOPPED đúng schema của owner.
   */
  function emit(frame) { child.stdout.emit('data', Buffer.from(JSON.stringify(frame) + '\n')); }

  child.stdin.write =
    /** Param: value — private packet hoặc literal command của original factory, không ghi password vào state. */
    (value) => {
      if (value.startsWith('{')) {
        const packet = JSON.parse(value);
        assert.equal(packet.scenario, 'membership-stale'); assert.match(packet.password, /^Aa1[0-9a-f]{32}$/);
        emit({ kind: 'READY', runId, userIds, emails: userIds.map(
          /** Param: id/index — chỉ dùng index để dựng namespace cùng run, UUID không đưa vào email. */
          (id, index) => `probe-${runId}-${index}@example.invalid`) });
      } else if (value === 'MEMBERSHIP_TARGET\n') {
        emit({ kind: 'MEMBERSHIP_TARGET', target: { workspaceId, revision: 1, authorizationVersion: 1, grantGeneration: 1 } });
      } else {
        assert.equal(value, 'MEMBERSHIP_SESSION_EVIDENCE\n');
        emit({ kind: 'MEMBERSHIP_SESSION_EVIDENCE', sessions: [], audit: [] });
      }
      return true;
    };
  child.stdin.end =
    /** Param: value — original cleanup phải gửi đúng STOP một lần và đợi strict8zero + raw exit. */
    (value) => {
      assert.equal(value, 'STOP\n'); state.stops++;
      const cleanup = Object.fromEntries(['role', 'hba', 'users', 'sessions', 'workspaces', 'memberships', 'auditActor', 'limiterBuckets'].map(
        /** Param: name — tám counters fixed của original cleanup contract. */ (name) => [name, 0]));
      emit({ kind: 'STOPPED', cleanup }); child.emit('exit', 0);
    };
  for (const stream of [child.stdin, child.stdout, child.stderr]) {
    stream.destroy = /** Release fake pipe không tự giả child terminal. */ () => {};
  }
  server.address = /** Output: port chỉ có khi fake listener đã phát listening. */
    () => server.listening ? { port: 8443 } : null;
  server.listen = /** Đưa bind/failed-handoff qua original proxy listener guards. */ () => queueMicrotask(
    /** Phát lifecycle event bằng fake OS, original close/terminal implementation vẫn chạy thật. */
    () => {
      if (mode === 'bind-timeout') return;
      server.listening = true; server.emit('listening');
      if (mode === 'bind-failure') { server.listening = false; server.emit('error', Error('PRIVATE_SENTINEL')); }
    });
  server.close = /** Param: callback — giữ raw listener ACK pending ở bind-failure để kiểm ownership. */
    (callback) => {
      state.closes++; state.listenerCallback = callback;
      if (mode !== 'bind-failure') { server.listening = false; callback(); }
    };
  const result = runActualMembership({
    phaseRuntime: { checkPid: /** Param: pid — chỉ preflight absent, không gọi ADB trong host test. */
      (pid) => assert.equal(pid, null) },
    spawnFixtureProcess:
      /** Param: command/arguments_/options — giữ original spawn contract, thay duy nhất OS process boundary. */
      (command, arguments_, options) => {
        assert.equal(command, 'python'); assert.equal(options.shell, false);
        assert.ok(!arguments_.some(/** Param: value — argv không được mang generated TEST credential. */
          (value) => /Aa1[0-9a-f]{32}/.test(value)));
        queueMicrotask(/** Child đã được factory giữ handle trước spawn event. */ () => child.emit('spawn'));
        return child;
      },
    createCertificates: /** Output: material fake để host tests không tạo certificate hoặc gọi OS SDK. */
      async () => ({ valid: { certificate: 'PUBLIC', pfx: Buffer.from([1, 2, 3]) } }),
    certificateInfo: /** Output: validity dài hơn fixture, public DER fake chỉ truyền vào phase fake. */
      () => ({ certificate: 'PUBLIC_DER', notBefore: Date.now() - 60_000, notAfter: Date.now() + 3_300_000 }),
    proxyRuntime: {
      createServer: /** Output: fake OS listener, original proxy vẫn sở hữu close/metadata/terminal. */ () => server,
      setTimeout: /** Param: callback/milliseconds — lưu timer fake, không dùng wallclock đợi test. */
        (callback, milliseconds) => { const timer = { callback, milliseconds }; timers.add(timer); return timer; },
      clearTimeout: /** Param: timer — gỡ đúng fake timer thuộc proxy owner. */ (timer) => timers.delete(timer),
    },
    timers: {
      setTimeout: /** Param: callback/milliseconds — deadline orchestration riêng, không cấp proxy terminal từ timer. */
        (callback, milliseconds) => { assert.equal(milliseconds, 10_000); state.expireSetup = callback; return callback; },
      clearTimeout: /** Param: timer — chỉ gỡ timer setup khi đúng owner, không can thiệp listener. */
        (timer) => { if (state.expireSetup === timer) state.expireSetup = undefined; },
    },
    verifyHostNoCa: /** Phát một raw-close fake qua original capture, không giả HTTP/business response. */ async () => {
      const raw = new EventEmitter(); raw.remotePort = 23456;
      raw.destroy = /** Đóng chính peer fake, raw slot chỉ release qua event close thật của fake. */
        () => raw.emit('close');
      server.emit('connection', raw); raw.destroy();
    },
    runPhase: /** Param: packet/certificate/options — kiểm original factory handoff, không chạy SDK hoặc UI. */
      async (packet, certificate, options) => {
        state.phase = true;
        assert.equal(packet.phase, 'membership-stale'); assert.equal(certificate, 'PUBLIC_DER');
        assert.equal(options.target.workspaceId, workspaceId); options.runtime.assertExternalActive();
        assert.equal(options.readHttpSnapshot().rawOpened, 1);
        if (mode === 'phase-failure') throw Error('PRIVATE_SENTINEL');
        return 8123;
      },
  });
  result.then(/** Quan sát public settlement riêng với STOP intent và listener close callback. */
    () => { state.settled = true; }, /** Failure vẫn phải chờ raw terminal trước settlement. */
    () => { state.settled = true; });
  try {
    if (mode === 'bind-timeout') {
      for (let index = 0; index < 30 && !state.expireSetup; index++) await turn();
      state.expireSetup();
    }
    if (mode === 'bind-failure') {
      for (let index = 0; index < 30 && !state.listenerCallback; index++) await turn();
      assert.equal(state.closes, 1); assert.equal(state.stops, 1); assert.equal(state.settled, false);
      state.listenerCallback();
    }
    if (mode === 'success') assert.equal(await result, 8123);
    else await assert.rejects(/** Output: same actual wrapper invocation, không retry một run khác. */
      () => result, { message: 'NATIVE_MEMBERSHIP_ORCHESTRATION_FAILED' });
    assert.equal(state.stops, 1); assert.equal(state.closes, 1); assert.equal(timers.size, 0);
    assert.equal(state.phase, !['bind-failure', 'bind-timeout'].includes(mode));
    assert.equal(state.expireSetup, undefined);
    if (mode === 'bind-timeout') {
      assert.equal(server.listenerCount('listening'), 1);
      assert.equal(server.listenerCount('error'), 1);
      server.emit('listening'); server.emit('error', Error('PRIVATE_LATE_SENTINEL'));
      await turn();
      assert.equal(state.closes, 1); assert.equal(state.phase, false);
    }
    console.log('MEMBERSHIP_ENTRY_' + mode.toUpperCase().replaceAll('-', '_') + '_PASS');
  } finally {
    if (!state.settled && state.listenerCallback) state.listenerCallback();
    await result.catch(/** Giữ observer tới terminal nếu assertion ở testcase thất bại. */ () => {});
  }
}

const invalid = spawnSync(process.execPath, ['ops/auth/run_native_membership_e2e.mjs', '--invalid'],
  { encoding: 'utf8', windowsHide: true, timeout: 5_000 });
assert.equal(invalid.status, 1); assert.equal(invalid.stdout, '');
assert.equal(invalid.stderr.trim(), 'NATIVE_MEMBERSHIP_ACTUAL_FAILED');
console.log('MEMBERSHIP_ENTRY_INVALID_ARGUMENTS_NO_IO_PASS');
