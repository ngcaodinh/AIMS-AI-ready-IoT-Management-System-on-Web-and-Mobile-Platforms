import assert from 'node:assert/strict';
import { createMembershipHttpOracle, validateMembershipAudit, runNativeMembershipPhase } from './native_membership_evidence.mjs';
import { createFakeMembershipRuntime } from './test_native_membership_consumer.mjs';

const seed = '10000000-0000-4000-8000-000000000001';
const app = '10000000-0000-4000-8000-000000000002';
const workspace = '20000000-0000-4000-8000-000000000002';
const stages = ['membership-before-login', 'membership-picker', 'membership-denied',
  'membership-only-a', 'membership-a-opened', 'membership-logged-out'];
const prefixes = [0, 3, 4, 5, 6, 7];
const requests = [['AUTH_LOGIN', 200], ['PROFILE_READ', 200], ['WORKSPACE_LIST', 200],
  ['WORKSPACE_DETAIL', 404], ['WORKSPACE_LIST', 200], ['WORKSPACE_DETAIL', 200], ['AUTH_LOGOUT', 204]];

/**
 * Giữ ledger H2 metadata synthetic độc lập với oracle cần kiểm, không sockets hoặc server.
 * Output: feed/snapshot và observer strict, raw1 mô phỏng host TLS negative trước SDK.
 */
function createHistory() {
  const oracle = createMembershipHttpOracle();
  const byKind = { AUTH_LOGIN: 0, PROFILE_READ: 0, WORKSPACE_LIST: 0, PASSWORD_CHANGE: 0,
    AUTH_LOGOUT: 0, WORKSPACE_DETAIL: 0, OTHER: 0 };
  let sequence = 0; let count = 0; let rawOpened = 1;
  /** Chụp shape H2 public đúng capture, caller nhận copy không sửa ledger host test. */
  function snapshot() {
    return { healthy: true, sealed: false, sequence, elapsedMilliseconds: sequence,
      rawOpened, rawActive: 0, opened: count, active: 0, requests: count,
      statuses: count, closed: count, incomplete: 0, byKind: { ...byKind }, proxyAvailable: true };
  }
  oracle.baseline(snapshot());
  /**
   * Feed exact request/status/close tới prefix mong đợi, tạo metadata bằng bảng case độc lập.
   * Input
   * Param: wanted — tổng request đã thực hiện ở UI checkpoint synthetic.
   * Param: fault — optional fixed fault field của event để kiểm sticky rejection.
   */
  function feed(wanted, fault) {
    rawOpened = 2 + wanted;
    while (count < wanted) {
      const index = count;
      const [kind, status] = requests[index] ?? ['AUTH_LOGIN', 200];
      const base = { requestId: index + 1, kind, matchesTarget: index === 3 };
      for (const event of ['REQUEST', 'STATUS', 'CLOSED']) {
        const value = { sequence: ++sequence, elapsedMilliseconds: sequence, event, ...base,
          ...(event === 'STATUS' ? { status } : {}),
          ...(event === 'CLOSED' ? { requestObserved: true, statusObserved: true } : {}) };
        if (fault === 'status' && event === 'STATUS') value.status = 200 === status ? 204 : 200;
        if (fault === 'target' && index === 3) value.matchesTarget = false;
        if (fault === 'schema') value.extra = true;
        oracle.observe(value);
      }
      byKind[kind]++;
      count++;
    }
  }
  return { oracle, feed, snapshot };
}

/**
 * Tạo row audit synthetic đúng schema, không auth material hoặc audit payload tự do.
 * Input
 * Param: sessionId — UUID public thuộc baseline/App của case.
 * Param: eventType — fixed login/logout event, outcome thành công mặc định.
 */
function audit(sessionId, eventType) {
  return { sessionId, eventType, outcome: 'SUCCESS', clientType: 'ANDROID' };
}

/** Kiểm oracle bằng metadata độc lập và wrapper qua private SDK consumer thật với fake boundaries. */
async function main() {
  const history = createHistory();
  for (let index = 0; index < stages.length; index++) {
    history.feed(prefixes[index]);
    history.oracle.checkpoint(stages[index], history.snapshot());
    history.oracle.assertCurrent(history.snapshot());
  }
  history.oracle.finish(history.snapshot());
  assert.throws(/** Final oracle không được mở lại checkpoint sau SDK stop. */
    () => history.oracle.checkpoint(stages[0], history.snapshot()));
  console.log('MEMBERSHIP_HTTP_FULL_SEQUENCE_PASS');

  for (const mode of ['status', 'target', 'schema', 'prefix', 'order', 'active', 'raw-active',
    'incomplete', 'unhealthy', 'unavailable', 'extra-kind', 'sequence', 'raw-extra']) {
    const test = createHistory();
    assert.throws(
      /** Cố ý đổi đúng một boundary để mọi mismatch fail sticky, không nâng counter khác bù. */
      () => {
        if (['status', 'target', 'schema'].includes(mode)) test.feed(mode === 'target' ? 4 : 1, mode);
        else if (mode === 'sequence') test.oracle.observe({ sequence: 2, elapsedMilliseconds: 1,
          event: 'REQUEST', requestId: 1, kind: 'AUTH_LOGIN', matchesTarget: false });
        else {
          test.feed(mode === 'prefix' ? 1 : 0);
          const value = test.snapshot();
          if (mode === 'active') value.active = 1;
          if (mode === 'raw-active') value.rawActive = 1;
          if (mode === 'incomplete') value.incomplete = 1;
          if (mode === 'unhealthy') value.healthy = false;
          if (mode === 'unavailable') value.proxyAvailable = false;
          if (mode === 'extra-kind') value.byKind.EXTRA = 0;
          if (mode === 'raw-extra') value.rawOpened++;
          test.oracle.checkpoint(mode === 'order' ? stages[1] : stages[0], value);
        }
      });
    assert.throws(/** Fault không được phục hồi bằng snapshot hợp lệ được đưa sau đó. */
      () => test.oracle.checkpoint(stages[0], test.snapshot()));
    console.log('MEMBERSHIP_HTTP_FENCE_' + mode.toUpperCase().replaceAll('-', '_') + '_PASS');
  }

  const initialAudit = [audit(seed, 'LOGIN_SUCCEEDED')];
  const finalAudit = [...initialAudit, audit(app, 'LOGIN_SUCCEEDED'), audit(app, 'LOGOUT')];
  validateMembershipAudit(initialAudit, finalAudit, app);
  console.log('MEMBERSHIP_AUDIT_EXACT_PASS');
  for (const mode of ['missing', 'duplicate', 'failed', 'foreign', 'baseline-changed', 'extra-field', 'client']) {
    const value = finalAudit.map(/** Input Param: row — copy audit scalars để fault không sửa baseline của ca khác. */
      (row) => ({ ...row }));
    if (mode === 'missing') value.pop();
    if (mode === 'duplicate') value.push(audit(app, 'LOGOUT'));
    if (mode === 'failed') value[2].outcome = 'FAILURE';
    if (mode === 'foreign') value[2].sessionId = workspace;
    if (mode === 'baseline-changed') value[0].eventType = 'LOGOUT';
    if (mode === 'extra-field') value[2].extra = true;
    if (mode === 'client') value[2].clientType = 'WEB';
    assert.throws(/** Exact App events và baseline multiset không nhận delta hoặc schema khác. */
      () => validateMembershipAudit(initialAudit, value, app));
    console.log('MEMBERSHIP_AUDIT_FENCE_' + mode.toUpperCase().replaceAll('-', '_') + '_PASS');
  }

  for (const mode of ['success', 'suspend-failed', 'audit-failed', 'late-http', 'cleanup-pending',
    'pending-mid-until-close', 'pending-suspend-until-close', 'pending-final-until-close']) {
    const { state, runtime, external } = createFakeMembershipRuntime('success');
    const http = createHistory();
    state.onStatus =
      /**
       * Mô phỏng HTTP business đã xong trước status pause, không phát event từ assertion của wrapper.
       * Input
       * Param: status — native status fake mà SDK pipe sắp reply.
       */
      (status) => {
        if (status.checkpoint) http.feed(prefixes[stages.indexOf(status.checkpoint)]);
        if (mode === 'late-http' && status.status === 'PASS') http.feed(8);
      };
    let closed = false; let closeStarted = false; let releaseClose; let closeCalls = 0;
    let closeBeforeSdkShutdown = false;
    let releaseFixture; let rejectFixture;
    const pendingFixture = new Promise(
      /**
       * Callback chỉ settle khi original close bắt đầu, không dùng SDK exit làm SQL completion.
       * Input
       * Param: resolve — giao late receipt ở suspend/final sau STOP.
       * Param: reject — giao failure ở mid sau STOP, không giữ raw error.
       */
      (resolve, reject) => { releaseFixture = resolve; rejectFixture = reject; });
    pendingFixture.catch(/** Drain reject ngay cả khi case lỗi trước khi tới operation dự kiến. */ () => {});
    const closePending = new Promise(/** Own cleanup completion fake tách khỏi SDK terminal. */
      (resolve) => { releaseClose = resolve; });
    const fixture = {
      snapshot:
        /** Mid snapshot chỉ ở picker trước suspend, không tạo App login hoặc audit giả để bù. */
        async () => {
          assert.deepEqual(state.accepted, [stages[0]]);
          state.clock += 129_000;
          if (mode === 'pending-mid-until-close') {
            state.clock += 81_001;
            await pendingFixture;
          }
          return [{ sessionId: seed, revoked: false }, { sessionId: app, revoked: false }];
        },
      suspendMembershipB:
        /** One-shot commit receipt synthetic, failure không được cấp ACK picker. */
        async () => {
          if (mode === 'suspend-failed' || mode === 'cleanup-pending') throw new Error('PRIVATE_SUSPEND_FAILURE');
          state.clock += 19_000;
          if (mode === 'pending-suspend-until-close') {
            state.clock += 62_001;
            await pendingFixture;
          }
          return { workspaceId: workspace, revision: 2, authorizationVersion: 2, grantGeneration: 1, status: 'SUSPENDED' };
        },
      membershipSessionEvidence:
        /** Final snapshot cùng AppUUID đã revoke, audit-failed cố ý thiếu LOGOUT. */
        async () => {
          assert.deepEqual(state.accepted, stages);
          state.clock += 129_000;
          if (mode === 'pending-final-until-close') {
            state.clock += 1001;
            await pendingFixture;
          }
          return { sessions: [{ sessionId: seed, revoked: false }, { sessionId: app, revoked: true }],
            audit: mode === 'audit-failed' ? finalAudit.slice(0, 2) : finalAudit };
        },
      close:
        /** Sync abort trước await cleanup fake, caller phải giữ tới completion thật. */
        async () => {
          closeCalls++;
          closeBeforeSdkShutdown = !state.commands.includes('app.stop');
          closeStarted = true; external.abort();
          if (mode === 'pending-mid-until-close') rejectFixture(new Error('PRIVATE_FIXTURE_CLOSED'));
          else releaseFixture();
          if (mode === 'cleanup-pending' || mode.startsWith('pending-')) await closePending;
          closed = true;
        },
    };
    const packet = { version: 1, phase: 'membership-stale', password: 'Aa1' + 'c'.repeat(32),
      emails: Array.from({ length: 5 },
        /** Input Param: index — account0–4 đúng namespace synthetic riêng của case. */
        (_, index) => 'probe-aaaaaaaa-1111-4111-8111-111111111111-' + index + '@example.invalid') };
    let returned = false;
    const run = runNativeMembershipPhase(packet, 'PUBLIC_CERTIFICATE', {
      fixture, target: { workspaceId: workspace, revision: 1, authorizationVersion: 1, grantGeneration: 1 },
      baseline: { sessions: [{ sessionId: seed, revoked: false }], audit: initialAudit },
      httpOracle: http.oracle, readHttpSnapshot: http.snapshot, workDeadline: runtime.workDeadline, runtime,
    }).then(
      /** Input Param: value — PID public khi scoped fake wrapper PASS. */
      (value) => { returned = true; return { value }; },
      /** Chỉ fixed failure boolean, không giữ hoặc log private oracle exception. */
      () => { returned = true; return { failed: true }; });
    if (mode === 'cleanup-pending') {
      await state.sdkExit;
      await new Promise(/** Nhường một event-loop turn để close thực sự bắt đầu. */ (resolve) => setImmediate(resolve));
      assert.equal(closeStarted, true); assert.equal(returned, false); releaseClose();
    }
    let automaticCloseStarted = true;
    if (mode.startsWith('pending-')) {
      await state.sdkExit;
      await new Promise(/** Cho SDK observers/failure hook chạy trước kiểm close, không resolve raw fixture I/O. */
        (resolve) => setImmediate(resolve));
      automaticCloseStarted = closeStarted;
      if (!closeStarted) {
        // Teardown fallback chỉ drain ca RED, không dùng nó làm expected cleanup proof.
        const fallbackClose = fixture.close();
        releaseClose();
        await fallbackClose;
      } else releaseClose();
    }
    const result = await run;
    if (mode.startsWith('pending-')) {
      assert.equal(automaticCloseStarted, true, 'FIXTURE_CLOSE_MUST_START_BEFORE_CALLBACK_SETTLES');
      assert.equal(closeBeforeSdkShutdown, true, 'FIXTURE_CLOSE_MUST_START_BEFORE_SDK_SHUTDOWN');
      assert.deepEqual(state.accepted, mode === 'pending-final-until-close' ? stages : [stages[0]]);
    }
    if (mode === 'success') {
      assert.deepEqual(result, { value: 8123 }); assert.equal(closed, false);
      await fixture.close();
    } else { assert.equal(result.failed, true); assert.equal(closed, true); }
    assert.equal(packet.password, '');
    assert.equal(closeCalls, 1, 'ORIGINAL_FIXTURE_CLOSE_EXACTLY_ONCE');
    console.log('MEMBERSHIP_WRAPPER_' + mode.toUpperCase().replaceAll('-', '_') + '_PASS');
  }
}
await main();
