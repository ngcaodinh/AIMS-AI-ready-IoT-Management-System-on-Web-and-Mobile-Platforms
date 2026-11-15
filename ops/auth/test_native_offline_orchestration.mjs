import assert from 'node:assert/strict';
import { orchestrateNativeOffline } from './native_offline_orchestration.mjs';
import { createFakeMembershipRuntime } from './test_native_membership_consumer.mjs';

const runId = 'aaaaaaaa-1111-4111-8111-111111111111';
const app = '10000000-0000-4000-8000-000000000001';
const a = '20000000-0000-4000-8000-000000000001';
const b = '20000000-0000-4000-8000-000000000002';
const stages = ['offline-ready', 'offline-result', 'offline-quiet', 'offline-picker', 'offline-logged-out'];
const prefixes = [1, 1, 2, 5, 9];
const requests = [['PROFILE_READ', 401], ['PROFILE_READ', 401], ['AUTH_LOGIN', 200], ['PROFILE_READ', 200],
  ['WORKSPACE_LIST', 200], ['WORKSPACE_DETAIL', 200], ['WORKSPACE_LIST', 200], ['WORKSPACE_DETAIL', 200], ['AUTH_LOGOUT', 204]];

/** Param: step — snapshot0baseline/1negative/2mid/3final synthetic, không DB. */
function evidence(step) {
  const live = step >= 2;
  return { sessions: live ? [{ sessionId: app, revoked: step === 3 }] : [],
    audit: live ? [{ sessionId: app, eventType: 'LOGIN_SUCCEEDED', outcome: 'SUCCESS', clientType: 'ANDROID' },
      ...(step === 3 ? [{ sessionId: app, eventType: 'LOGOUT', outcome: 'SUCCESS', clientType: 'ANDROID' }] : [])] : [],
    workspaces: [{ workspaceId: a, name: 'Phòng vận hành A', role: 'ADMIN' }, { workspaceId: b, name: 'Nhà kính B', role: 'USER' }] };
}

/** Param: mode — fixed failure injection. Output: coordinator capabilities cùng raw owner releases. */
function setup(mode) {
  const fake = createFakeMembershipRuntime('success', 'offline-login');
  const { state, runtime } = fake;
  Object.assign(state, { sql: 0, stops: 0, proxyStops: 0, network: 'enabled', events: [] });
  const sdkPause = runtime.pause; let startupWaited = false;
  runtime.pause =
    /** Param: milliseconds — nhường baseline/TLS settle rồi mô phỏng SDK startup còn chậm, cùng absolute clock. */
    async (milliseconds) => {
      await sdkPause(milliseconds);
      if (!startupWaited && ['slow-sdk', 'near-prearm', 'prearm-expired', 'startup-expired'].includes(mode)) {
        startupWaited = true; state.clock = mode === 'startup-expired' ? 180_000 : 179_500;
      }
    };
  const spawnSdk = runtime.spawnNativeProcess;
  runtime.spawnNativeProcess =
    /** Param: command/arguments_/options — delegate fake SDK rồi thêm latency riêng cho malformed RPC. */
    (command, arguments_, options) => {
      const child = spawnSdk(command, arguments_, options); const write = child.stdin.write;
      child.stdin.write =
        /** Param: value — JSON fake request, chỉ fault malformed packet trước valid ARM. */
        (value) => {
          const [request] = JSON.parse(value);
          if (request.params?.methodName?.endsWith('.fixture') && request.params.params.packet === '{}' &&
              ['near-prearm', 'prearm-expired'].includes(mode)) {
            state.clock += mode === 'prearm-expired' ? 31_500 : 29_000;
          }
          return write(value);
        };
      return child;
    };
  const proxyAbort = new AbortController(); let onClosing; let observe; let count = 0; let sequence = 0; let raw = 0;
  let fixtureClosing; let releaseFixture; let releaseProxy; let releaseNegative;
  const fixtureTerminal = new Promise(/** Param: resolve — original fixture terminal được test giữ riêng. */
    (resolve) => { releaseFixture = resolve; });
  const proxyTerminal = new Promise(/** Param: resolve — proxy raw terminal không suy từ close result. */
    (resolve) => { releaseProxy = resolve; });
  const negativePending = new Promise(/** Param: resolve — kiểm SQL vẫn owned sau result ACK. */
    (resolve) => { releaseNegative = resolve; });
  const byKind = { AUTH_LOGIN: 0, PROFILE_READ: 0, WORKSPACE_LIST: 0, PASSWORD_CHANGE: 0,
    AUTH_LOGOUT: 0, WORKSPACE_DETAIL: 0, OTHER: 0 };
  const material = { valid: { certificate: 'PUBLIC_CERT', pfx: Buffer.from([1, 2, 3]) } };
  const proxy = {
    signal: proxyAbort.signal, terminal: proxyTerminal,
    httpSnapshot: /** Output: cumulative metadata fake độc lập với oracle expected preset. */
      () => ({ healthy: true, sealed: false, sequence, elapsedMilliseconds: state.clock, rawOpened: raw,
        rawActive: 0, opened: count, active: 0, requests: count, statuses: count, closed: count,
        incomplete: 0, byKind: { ...byKind }, proxyAvailable: !proxyAbort.signal.aborted }),
    close: /** Bounded ACK trước raw terminal ở pending mode, phải giữ consumer chưa return. */
      async () => { state.proxyStops++; proxyAbort.abort(); if (mode !== 'pending-cleanup') releaseProxy(); return true; },
  };
  const fixture = {
    workDeadline: 1_200_000,
    ready: /** Output: exact synthetic5accounts, slow READY phải trừ admission. */ async () => {
      if (mode === 'slow-ready') state.clock += 35_001;
      return { runId, emails: Array.from({ length: 5 }, /** Param: index — synthetic suffix cùng run. */
        (_, index) => `probe-${runId}-${index}@example.invalid`) };
    },
    offlineEvidence: /** Output: read-only scalar, negative có thể pending qua result ACK. */ async () => {
      const step = state.sql++; state.events.push('sql-' + step);
      if (step === 0 && ['slow-baseline', 'near-prearm', 'prearm-expired', 'baseline-expired'].includes(mode)) {
        state.clock += mode === 'baseline-expired' ? 130_000 : 129_000;
      }
      if (mode === 'baseline-failed' && step === 0) throw Error('PRIVATE');
      if (['negative-pending', 'quiet-sql-failed'].includes(mode) && step === 1) {
        await negativePending;
        if (mode === 'quiet-sql-failed') throw Error('PRIVATE');
      }
      const value = evidence(step);
      if (mode === 'negative-delta' && step === 1) value.sessions.push({ sessionId: app, revoked: false });
      if (mode === 'final-live' && step === 3) value.sessions[0].revoked = false;
      return value;
    },
    close: /** Memoize trước hook reentry và chỉ resolve khi original fixture terminal release. */ () => {
      if (!fixtureClosing) {
        let settle; fixtureClosing = new Promise(/** Param: resolve — owned close observer. */ (resolve) => { settle = resolve; });
        state.stops++; onClosing();
        fixtureTerminal.then(/** Original terminal là authority hoàn tất cleanup. */ () => settle());
        if (mode !== 'pending-cleanup') releaseFixture();
        if (['negative-pending', 'quiet-sql-failed'].includes(mode)) releaseNegative();
      }
      return fixtureClosing;
    },
  };
  state.onStatus = /** Param: status — mô phỏng business HTTP trước native pause, không request từ oracle. */
    (status) => {
      if (!status.checkpoint && state.fixtureWrites === 0 && !state.preArmDelayed &&
          ['near-prearm', 'prearm-expired'].includes(mode)) {
        state.preArmDelayed = true; state.clock += 29_000;
      }
      if (!status.checkpoint) return;
      const wanted = prefixes[stages.indexOf(status.checkpoint)]; raw = 2 + wanted;
      while (count < wanted) {
        const [kind, response] = requests[count]; const id = count + 1;
        for (const event of ['REQUEST', 'STATUS', 'CLOSED']) observe({ sequence: ++sequence,
          elapsedMilliseconds: state.clock, event, requestId: id, kind, matchesTarget: count === 7,
          ...(event === 'STATUS' ? { status: response } : {}),
          ...(event === 'CLOSED' ? { requestObserved: true, statusObserved: true } : {}) });
        count++; byKind[kind]++;
      }
      if (['negative-pending', 'quiet-sql-failed'].includes(mode) && status.checkpoint === 'offline-quiet') {
        assert.ok(state.accepted.includes('offline-result')); assert.ok(!state.accepted.includes('offline-quiet'));
        setImmediate(/** Original SQL completion mới cho quiet ACK, không đợi timeout giả. */ () => releaseNegative());
      }
    };
  return { state, releaseFixture, releaseProxy, material, caps: {
    now: runtime.now, phaseRuntime: runtime, pause: runtime.pause, wallNow: /** Wallclock public ổn định. */ () => 1000,
    certificateInfo: /** Output: validity test đủ dài cho1200s, không chứng chỉ thật. */
      () => ({ certificate: 'PUBLIC_CERT', notBefore: 0, notAfter: 4_000_000 }),
    timers: { setTimeout: /** Param: callback/ms — host fake kiểm completion clock, không tạo real long timer. */
      (callback, milliseconds) => ({ callback, milliseconds }), clearTimeout: /** Fake không có timer OS. */ () => {} },
    network: {
      readState: /** Output: exact guest enum fake, ineffective off phải fail trước login. */ async () => state.network,
      setState: /** Param: desired — only fixed off/restore, ghi lại order để kiểm cleanup. */ async (desired) => {
        state.events.push('network-' + desired);
        state.network = desired === 'off' ? 'disabled' : 'enabled';
        if (mode === 'off-failed' && desired === 'off') throw Error('PRIVATE');
        if (mode === 'restore-failed' && desired === 'enabled') throw Error('PRIVATE');
      },
    },
    createCertificates: /** Output: private buffer giả được kiểm wipe sau handoff. */ async () => material,
    createFixture: /** Param: password/secrets/hook — cùng RAM credential và original STOP hook. */
      (_, secrets, hook) => { state.secrets = secrets; onClosing = hook; return fixture; },
    startProxy: /** Param: TLS/target/callback/onOwned — pin B trước bind và registry trước await. */
      async (_, target, callback, onOwned) => {
        assert.equal(target, b); observe = callback; onOwned(proxy);
        if (mode === 'bind-failed') throw Error('PRIVATE');
        return proxy;
      },
    verifyHostNoCa: /** Output: một raw TLS rejection ngoài HTTP, có thể tiêu9s setup trong overlap case. */ async () => {
      raw++; if (['near-prearm', 'prearm-expired'].includes(mode)) state.clock += 9000;
    },
  } };
}

for (const mode of ['success', 'negative-pending', 'slow-baseline', 'slow-sdk', 'near-prearm', 'prearm-expired',
  'startup-expired', 'baseline-expired', 'quiet-sql-failed', 'slow-ready', 'baseline-failed', 'bind-failed', 'off-failed',
  'restore-failed', 'negative-delta', 'final-live', 'pending-cleanup']) {
  const test = setup(mode); let returned = false;
  const result = orchestrateNativeOffline(test.caps);
  result.then(/** Settlement vẫn phải chờ mọi raw owners. */ () => { returned = true; },
    /** Rejection cũng là return, không được xảy ra khi raw terminal còn pending. */ () => { returned = true; });
  if (mode === 'pending-cleanup') {
    while (!test.state.stops) await new Promise(/** Nhường fake SDK pipe tới cleanup boundary. */ (resolve) => setImmediate(resolve));
    assert.equal(returned, false); test.releaseFixture();
    await new Promise(/** Fixture xong vẫn chờ raw proxy terminal. */ (resolve) => setImmediate(resolve));
    assert.equal(returned, false); test.releaseProxy();
  }
  if (['success', 'negative-pending', 'slow-baseline', 'slow-sdk', 'near-prearm', 'pending-cleanup'].includes(mode)) {
    assert.equal(await result, 8123); assert.equal(test.state.sql, 4); assert.deepEqual(test.state.accepted, stages);
  } else await assert.rejects(result, { message: 'NATIVE_OFFLINE_ORCHESTRATION_FAILED' });
  assert.equal(test.state.stops, 1); assert.ok(test.state.proxyStops <= 1);
  assert.equal(test.state.network, 'enabled');
  if (test.state.spawned) assert.equal(test.state.sdkExited, true);
  assert.ok(test.state.secrets.every(/** Param: secret — RAM scanner slots đã wipe sau original terminals. */ (secret) => secret === ''));
  assert.deepEqual([...test.material.valid.pfx], [0, 0, 0]);
  if (mode === 'quiet-sql-failed') {
    assert.ok(test.state.accepted.includes('offline-result')); assert.ok(!test.state.accepted.includes('offline-quiet'));
  }
  if (['prearm-expired', 'startup-expired', 'baseline-expired'].includes(mode)) assert.equal(test.state.fixtureWrites < 2, true);
  console.log('OFFLINE_COORDINATOR_' + mode.toUpperCase().replaceAll('-', '_') + '_PASS');
}

// Consumer có thể hết bounded shutdown observer trước raw SDK exit, coordinator vẫn phải giữ owner đó.
{
  const test = setup('success'); let releaseSdk; let returned = false;
  const sdkTerminal = new Promise(/** Param: resolve — raw SDK completion độc lập với phase failure. */
    (resolve) => { releaseSdk = resolve; });
  test.caps.runPhase =
    /** Param: packet/certificate/final/password/checkpoint/runtime — boundary SDK giả chỉ kiểm raw-exit handoff. */
    async (packet, certificate, final, password, checkpoint, runtime) => {
      runtime.captureSdkExit?.(sdkTerminal); runtime.onPhaseClosing(false);
      throw Error('SYNTHETIC_SHUTDOWN_UNCONFIRMED');
    };
  const operation = orchestrateNativeOffline(test.caps);
  operation.then(/** Không được trả success khi original SDK còn pending. */ () => { returned = true; },
    /** Failure cũng phải giữ ownership tới raw SDK terminal. */ () => { returned = true; });
  try {
    for (let index = 0; index < 20; index++) await new Promise(/** Nhường mọi cleanup observer fake tới settled. */
      (resolve) => setImmediate(resolve));
    assert.equal(test.state.stops, 1); assert.equal(returned, false, 'SDK_RAW_EXIT_MUST_REMAIN_OWNED');
  } finally {
    releaseSdk(1);
    await assert.rejects(operation, { message: 'NATIVE_OFFLINE_ORCHESTRATION_FAILED' });
  }
  console.log('OFFLINE_COORDINATOR_PENDING_SDK_FAILURE_OWNED_PASS');
}
