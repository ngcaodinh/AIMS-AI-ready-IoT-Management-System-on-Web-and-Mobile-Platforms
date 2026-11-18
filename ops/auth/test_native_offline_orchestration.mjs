import assert from 'node:assert/strict';
import { orchestrateNativeOffline } from './native_offline_orchestration.mjs';
import { createGuestNetworkControl } from './native_guest_network_control.mjs';
import { createFakeMembershipRuntime } from './test_native_membership_consumer.mjs';

const runId = 'aaaaaaaa-1111-4111-8111-111111111111';
const app = '10000000-0000-4000-8000-000000000001';
const setupSession = '10000000-0000-4000-8000-000000000002';
const a = '20000000-0000-4000-8000-000000000001';
const b = '20000000-0000-4000-8000-000000000002';
const offlineLoginStages = ['offline-ready', 'offline-result', 'offline-quiet', 'offline-picker', 'offline-outbox-ready',
  'offline-outbox-persisted', 'offline-outbox-resumed', 'offline-logged-out'];
const offlineLoginPrefixes = [1, 1, 2, 5, 8, 8, 8, 9];
const offlineLoginRequests = [['PROFILE_READ', 401], ['PROFILE_READ', 401], ['AUTH_LOGIN', 200], ['PROFILE_READ', 200],
  ['WORKSPACE_LIST', 200], ['WORKSPACE_DETAIL', 200], ['WORKSPACE_LIST', 200], ['WORKSPACE_DETAIL', 200], ['AUTH_LOGOUT', 204]];
const offlineExpiredStages = ['offline-expired-offline', 'offline-expired-ready', 'offline-expired-persisted',
  'offline-outbox-resumed', 'offline-logged-out'];
const offlineExpiredPrefixes = [0, 0, 0, 0, 1];
const offlineExpiredRequests = [['AUTH_LOGOUT', 204]];

/** Tạo projection SQL synthetic phù hợp profile, không truy cập database thật.
 * Input
 * Param: step — thứ tự readback của fixture giả.
 * Param: expiredProfile — chọn session expired đã seed thay cho flow login offline thường.
 * Param: mode — lỗi synthetic dùng để tạo final row còn active khi cần.
 */
function evidence(step, expiredProfile = false, mode = 'success') {
  if (expiredProfile) {
    const revoked = step >= 5 && mode !== 'final-live';
    return { sessions: [{ sessionId: setupSession, revoked: false }, { sessionId: app, revoked }],
      audit: [{ sessionId: setupSession, eventType: 'LOGIN_SUCCEEDED', outcome: 'SUCCESS', clientType: 'ANDROID' },
        ...(revoked ? [{ sessionId: app, eventType: 'LOGOUT', outcome: 'SUCCESS', clientType: 'ANDROID' }] : [])],
      workspaces: [{ workspaceId: a, name: 'Phòng vận hành A', role: 'ADMIN' },
        { workspaceId: b, name: 'Nhà kính B', role: 'USER' }] };
  }
  const live = step >= 2;
  return { sessions: live ? [{ sessionId: app, revoked: step >= 7 }] : [],
    audit: live ? [{ sessionId: app, eventType: 'LOGIN_SUCCEEDED', outcome: 'SUCCESS', clientType: 'ANDROID' },
      ...(step >= 7 ? [{ sessionId: app, eventType: 'LOGOUT', outcome: 'SUCCESS', clientType: 'ANDROID' }] : [])] : [],
    workspaces: [{ workspaceId: a, name: 'Phòng vận hành A', role: 'ADMIN' }, { workspaceId: b, name: 'Nhà kính B', role: 'USER' }] };
}

/**
 * Tạo runtime giả theo một profile offline để kiểm orchestration và giữ nguyên raw owner.
 * Input
 * Param: mode — lỗi synthetic cố định cần inject vào một boundary.
 * Param: profile — offline-login hoặc offline-expired, không chứa credential hay selector.
 * Output: capability bundle cùng state và raw owner releases do test sở hữu.
 */
function setup(mode, profile = 'offline-login') {
  assert.ok(['offline-login', 'offline-expired'].includes(profile));
  const expiredProfile = profile === 'offline-expired';
  const stages = expiredProfile ? offlineExpiredStages : offlineLoginStages;
  const prefixes = expiredProfile ? offlineExpiredPrefixes : offlineLoginPrefixes;
  const requests = expiredProfile ? offlineExpiredRequests : offlineLoginRequests;
  const fake = createFakeMembershipRuntime('success', profile);
  const { state, runtime } = fake;
  Object.assign(state, { sql: 0, stops: 0, proxyStops: 0, network: 'enabled', networkRestoreAttempts: 0, events: [] });
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
              state.activePhase === 'offline-login' && ['near-prearm', 'prearm-expired'].includes(mode)) {
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
  /**
   * Phát đủ REQUEST/STATUS/CLOSED cho logout 204 để tái hiện capture đến muộn.
   * Side effects: tăng bộ đếm HTTP tổng hợp mà oracle kiểm theo đúng thứ tự.
   */
  function emitLogoutTerminal() {
    assert.equal(count, 8);
    const id = count + 1;
    for (const event of ['REQUEST', 'STATUS', 'CLOSED']) observe({ sequence: ++sequence,
      elapsedMilliseconds: state.clock, event, requestId: id, kind: 'AUTH_LOGOUT', matchesTarget: false,
      ...(event === 'STATUS' ? { status: 204 } : {}),
      ...(event === 'CLOSED' ? { requestObserved: true, statusObserved: true } : {}) });
    count++; byKind.AUTH_LOGOUT++;
  }
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
    ready: /** Output: năm account synthetic và receipt session expired chỉ trong profile tương ứng. */ async () => {
      if (mode === 'slow-ready') state.clock += 35_001;
      return { runId, emails: Array.from({ length: 5 }, /** Param: index — synthetic suffix cùng run. */
        (_, index) => `probe-${runId}-${index}@example.invalid`),
      ...(expiredProfile ? { expiredSessionId: app,
        expiredSessionExpiresAt: new Date(Date.now() - 3_600_000).toISOString() } : {}) };
    },
    offlineEvidence: /** Output: read-only scalar, negative có thể pending qua result ACK. */ async () => {
      const step = state.sql++; state.events.push('sql-' + step);
      if (!expiredProfile && mode === 'resume-baseline-before-app' && step === 6) assert.equal(state.spawned, 1);
      if (mode === 'outbox-admission-expired' && step === 3) state.clock += 10_001;
      if (step === 0 && ['slow-baseline', 'near-prearm', 'prearm-expired', 'baseline-expired'].includes(mode)) {
        state.clock += mode === 'baseline-expired' ? 130_000 : 129_000;
      }
      if (mode === 'baseline-failed' && step === 0) throw Error('PRIVATE');
      if (['negative-pending', 'quiet-sql-failed'].includes(mode) && step === 1) {
        await negativePending;
        if (mode === 'quiet-sql-failed') throw Error('PRIVATE');
      }
      const value = evidence(step, expiredProfile, mode);
      if (mode === 'negative-delta' && step === 1) value.sessions.push({ sessionId: app, revoked: false });
      if (mode === 'final-live' && step === 7) value.sessions[0].revoked = false;
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
  const radio = { airplane_mode_on: 0, wifi_on: 1, mobile_data: 1 };
  const radioWrites = [];
  let expiredRadioAdmission = false;
  const network = mode === 'partial-radio-admission-cleanup'
    ? createGuestNetworkControl({
      commandMode: 'cmd',
      now: runtime.now,
      sleep: /** Poll fake chỉ nhường promise; state convergence đến từ readback. */ async () => {},
      execute: /** Param: args/limit — adapter ADB giả dùng argv cố định và chỉ giữ metadata radio synthetic. */
        async (args, limit) => {
          assert.ok(limit > 0 && limit <= 30_000);
          if (args[1] === 'settings') return `${radio[args[4]]}\n`;
          if (args[1] === 'cmd' && args[2] === 'wifi' && args[3] === 'status') {
            return `Wifi is ${radio.wifi_on === 1 ? 'enabled' : 'disabled'}\n`;
          }
          const service = args[2] === 'phone' ? 'data' : 'wifi';
          const enabled = args[4] === 'enable' || args[4] === 'enabled';
          radioWrites.push(`${service}:${enabled ? 'enable' : 'disable'}`);
          if (!enabled && service === 'data' && !expiredRadioAdmission) {
            expiredRadioAdmission = true;
            state.clock += 111_000;
          }
          radio[service === 'data' ? 'mobile_data' : 'wifi_on'] = enabled ? 1 : 0;
          state.network = radio.mobile_data === 1 && radio.wifi_on === 1 ? 'enabled' :
            radio.mobile_data === 0 && radio.wifi_on === 0 ? 'disabled' : 'partial';
          return '';
        },
    })
    : {
      readState: /** Output: trạng thái fake đúng enum để host kiểm admission và readback. */ async () => {
        if (state.network === 'disabled' && state.activePhase === 'resume') {
          if (mode === 'resume-terminal-before-restore' && count === 8) emitLogoutTerminal();
          if (mode === 'resume-admission-expired') state.clock += 170_001;
        }
        return state.network;
      },
      /**
       * Chuyển trạng thái mạng giả và phát terminal logout đúng lúc app được nối lại.
       * Input
       * Param: desired — trạng thái mạng cố định mà orchestration yêu cầu.
       * Side effects: cập nhật mạng synthetic và metadata HTTP owned bởi test.
       */
      setState: async (desired) => {
        state.events.push('network-' + desired);
        if (desired === 'enabled' && state.spawned === 2 && state.stops === 0 &&
            ['resume-terminal-before-restore', 'resume-admission-expired'].includes(mode)) {
          state.lateResumeWrites = (state.lateResumeWrites ?? 0) + 1;
        }
        if (desired === 'enabled') state.networkRestoreAttempts++;
        state.network = desired === 'off' || (mode === 'restore-partial-failed' &&
          desired === 'enabled' && state.networkRestoreAttempts === 1) ? 'disabled' : 'enabled';
        if (mode === 'off-failed' && desired === 'off') throw Error('PRIVATE');
        if (mode === 'restore-failed' && desired === 'enabled') throw Error('PRIVATE');
        if (mode === 'restore-partial-failed' && desired === 'enabled' && state.networkRestoreAttempts === 1) throw Error('PRIVATE');
        if (mode === 'resume-terminal-early' && desired === 'enabled' &&
            state.accepted.includes('offline-outbox-persisted')) {
          // Worker có thể nhận mạng và hoàn tất revoke trước khi UI phát checkpoint kế tiếp.
          emitLogoutTerminal();
        }
      },
    };
  state.radioWrites = radioWrites;
  state.onStatus = /** Param: status — mô phỏng business HTTP trước native pause, không request từ oracle. */
    (status) => {
      if (!status.checkpoint && state.fixtureWrites === 0 && !state.preArmDelayed &&
          ['near-prearm', 'prearm-expired'].includes(mode)) {
        state.preArmDelayed = true; state.clock += 29_000;
      }
      if (!status.checkpoint) return;
      if (mode === 'outbox-admission-expired' && status.checkpoint === 'offline-outbox-ready') {
        status.checkpointRemainingMilliseconds = 10_000;
      }
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
    network,
    createCertificates: /** Output: private buffer giả được kiểm wipe sau handoff. */ async () => material,
    createFixture: /** Param: password/secrets/hook/token — credentials RAM và seed token chỉ thuộc expired profile. */
      (_, secrets, hook, token) => {
        state.secrets = secrets; onClosing = hook;
        assert.equal(token === undefined, !expiredProfile);
        if (token !== undefined) assert.ok(/^[0-9a-f]{64}$/.test(token) && secrets.includes(token));
        return fixture;
      },
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
  'restore-failed', 'restore-partial-failed', 'partial-radio-admission-cleanup', 'negative-delta', 'final-live', 'pending-cleanup', 'resume-terminal-early',
  'resume-baseline-before-app']) {
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
  if (['success', 'negative-pending', 'slow-baseline', 'slow-sdk', 'near-prearm', 'pending-cleanup',
    'resume-terminal-early', 'resume-baseline-before-app'].includes(mode)) {
    assert.equal(await result, 8123); assert.equal(test.state.sql, 8);
    assert.deepEqual(test.state.accepted, offlineLoginStages);
  } else {
    await assert.rejects(result, { message: 'NATIVE_OFFLINE_ORCHESTRATION_FAILED' });
  }
  assert.equal(test.state.stops, 1); assert.ok(test.state.proxyStops <= 1);
  assert.equal(test.state.network, 'enabled');
  if (mode === 'restore-partial-failed') assert.equal(test.state.networkRestoreAttempts, 2);
  if (mode === 'partial-radio-admission-cleanup') {
    assert.deepEqual(test.state.radioWrites, ['data:disable', 'data:enable', 'wifi:enable']);
  }
  if (test.state.spawned) assert.equal(test.state.sdkExited, true);
  assert.ok(test.state.secrets.every(/** Param: secret — RAM scanner slots đã wipe sau original terminals. */ (secret) => secret === ''));
  assert.deepEqual([...test.material.valid.pfx], [0, 0, 0]);
  if (mode === 'quiet-sql-failed') {
    assert.ok(test.state.accepted.includes('offline-result')); assert.ok(!test.state.accepted.includes('offline-quiet'));
  }
  if (['prearm-expired', 'startup-expired', 'baseline-expired'].includes(mode)) assert.equal(test.state.fixtureWrites < 2, true);
  console.log('OFFLINE_COORDINATOR_' + mode.toUpperCase().replaceAll('-', '_') + '_PASS');
}

for (const mode of ['outbox-admission-expired', 'resume-terminal-before-restore', 'resume-admission-expired']) {
  const test = setup(mode);
  const outcome = await orchestrateNativeOffline(test.caps).then(
    /** Thành công ngoài dự kiến được chuẩn hóa thành null để so với failure contract. */ () => null,
    /** Param: error — chỉ giữ fixed error object, không in hay nối exception gốc. */ (error) => error);
  assert.equal(outcome?.message, 'NATIVE_OFFLINE_ORCHESTRATION_FAILED',
    JSON.stringify({ mode, events: test.state.events, accepted: test.state.accepted, clock: test.state.clock }));
  assert.equal(test.state.network, 'enabled');
  assert.equal(test.state.lateResumeWrites ?? 0, 0);
  if (mode === 'outbox-admission-expired') {
    assert.equal(test.state.events.filter((event) => event === 'network-off').length, 1,
      JSON.stringify({ events: test.state.events, clock: test.state.clock, sql: test.state.sql }));
  }
  console.log('OFFLINE_COORDINATOR_' + mode.toUpperCase().replaceAll('-', '_') + '_PASS');
}

// Kịch bản hết hạn phải giữ nguyên session qua offline/restart và chỉ chốt sau POST logout terminal.
{
  const test = setup('success', 'offline-expired');
  const processId = await orchestrateNativeOffline({ ...test.caps, seedExpiredSession: true });
  assert.equal(processId, 8123);
  assert.equal(test.state.sql, 6);
  assert.deepEqual(test.state.accepted, offlineExpiredStages);
  assert.equal(test.state.network, 'enabled');
  assert.ok(test.state.secrets.every((secret) => secret === ''));
  console.log('OFFLINE_COORDINATOR_EXPIRED_SESSION_TERMINAL_PASS');
}

{
  const test = setup('final-live', 'offline-expired');
  await assert.rejects(orchestrateNativeOffline({ ...test.caps, seedExpiredSession: true }),
    { message: 'NATIVE_OFFLINE_ORCHESTRATION_FAILED' });
  assert.equal(test.state.network, 'enabled');
  assert.ok(test.state.secrets.every((secret) => secret === ''));
  console.log('OFFLINE_COORDINATOR_EXPIRED_SESSION_STILL_LIVE_REJECTED_PASS');
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
