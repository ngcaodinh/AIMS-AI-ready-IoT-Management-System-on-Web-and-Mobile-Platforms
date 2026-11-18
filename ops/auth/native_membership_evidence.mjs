import assert from 'node:assert/strict';
import { setTimeout as delay } from 'node:timers/promises';
import { nativeSessionMap } from './native_rate_evidence.mjs';
import { assertNativePid, runNativePhase, validateSessionDelta } from './run_native_e2e.mjs';

const uuid = /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/;
const stages = ['membership-before-login', 'membership-picker', 'membership-denied',
  'membership-only-a', 'membership-a-opened', 'membership-logged-out'];
const prefixes = [0, 3, 4, 5, 6, 7];
const requests = [['AUTH_LOGIN', 200], ['PROFILE_READ', 200], ['WORKSPACE_LIST', 200],
  ['WORKSPACE_DETAIL', 404], ['WORKSPACE_LIST', 200], ['WORKSPACE_DETAIL', 200], ['AUTH_LOGOUT', 204]];
const kinds = ['AUTH_LOGIN', 'PROFILE_READ', 'WORKSPACE_LIST', 'PASSWORD_CHANGE',
  'AUTH_LOGOUT', 'WORKSPACE_DETAIL', 'OTHER'];

/**
 * Kiểm exact keys để metadata không thành channel payload hoặc extension tự cấp authority.
 * Input
 * Param: value — public metadata chưa tin cậy.
 * Param: keys — fixed schema của boundary đang kiểm.
 */
function exactKeys(value, keys) {
  return value && typeof value === 'object' && !Array.isArray(value) &&
    Object.keys(value).length === keys.length && keys.every(
      /** Input Param: key — thuộc tính required, không đọc property từ prototype. */
      (key) => Object.hasOwn(value, key));
}

/**
 * Chốt HTTP metadata theo temporal prefix, status và target; không giữ header/body/URL/secret.
 * Input
 * Param: profile — preset nội bộ membership-stale, offline-login hoặc offline-expired với bảng request cố định.
 * Output: baseline/checkpoint/current/final oracle fail sticky, observe được H2 capture gọi đồng bộ.
 */
export function createMembershipHttpOracle(profile = 'membership-stale') {
  assert.ok(['membership-stale', 'offline-login', 'offline-expired'].includes(profile));
  const offline = profile === 'offline-login';
  const offlineExpired = profile === 'offline-expired';
  const expectedStages = offlineExpired ? ['offline-expired-offline', 'offline-expired-ready',
    'offline-expired-persisted', 'offline-outbox-resumed', 'offline-logged-out'] : offline ? ['offline-ready', 'offline-result', 'offline-quiet', 'offline-picker',
    'offline-outbox-ready', 'offline-outbox-persisted', 'offline-outbox-resumed', 'offline-logged-out'] : stages;
  const expectedPrefixes = offlineExpired ? [0, 0, 0, 0, 1] : offline ? [1, 1, 2, 5, 8, 8, 8, 9] : prefixes;
  const expectedRequests = offlineExpired ? [['AUTH_LOGOUT', 204]] : offline ? [['PROFILE_READ', 401], ['PROFILE_READ', 401],
    ['AUTH_LOGIN', 200], ['PROFILE_READ', 200], ['WORKSPACE_LIST', 200],
    ['WORKSPACE_DETAIL', 200], ['WORKSPACE_LIST', 200], ['WORKSPACE_DETAIL', 200], ['AUTH_LOGOUT', 204]] : requests;
  const targetIndex = offlineExpired ? -1 : offline ? 7 : 3;
  const records = new Map();
  let sequence = 0; let lastElapsed = 0; let position = -1; let baseline = false;
  let failed = false; let finished = false;

  /**
   * Mọi fault đóng proof vĩnh viễn để caller không thử snapshot khác sau mismatch.
   * Input
   * Param: operation — assertion read-only hoặc cập nhật ledger của một fixed boundary.
   */
  function guarded(operation) {
    try {
      assert.ok(!failed && !finished);
      return operation();
    } catch {
      failed = true;
      throw new Error('NATIVE_MEMBERSHIP_HTTP_INVALID');
    }
  }

  /**
   * Kiểm healthy/idle và cumulative counters cùng ledger, bao raw TLS negative không có HTTP.
   * Input
   * Param: value — snapshot public từ đúng proxy/capture owner.
   * Param: count — cumulative prefix fixed của stage.
   * Param: rawNegative — một host negative ở baseline, hai sau native noCA.
   */
  function snapshot(value, count, rawNegative) {
    assert.ok(exactKeys(value, ['healthy','sealed','sequence','elapsedMilliseconds','rawOpened','rawActive',
      'opened','active','requests','statuses','closed','incomplete','byKind','proxyAvailable']));
    assert.ok(value.healthy === true && value.sealed === false && value.proxyAvailable === true &&
      value.sequence === sequence && Number.isFinite(value.elapsedMilliseconds) &&
      value.elapsedMilliseconds >= lastElapsed && value.rawOpened === count + rawNegative &&
      value.rawActive === 0 && value.active === 0 && value.opened === count &&
      value.requests === count && value.statuses === count && value.closed === count &&
      value.incomplete === 0 && records.size === count && exactKeys(value.byKind, kinds));
    lastElapsed = value.elapsedMilliseconds;
    const expected = Object.fromEntries(kinds.map(
      /** Input Param: kind — category allowlist, chốt zero trước khi cộng prefix dự kiến. */
      (kind) => [kind, 0]));
    for (let index = 0; index < count; index++) expected[expectedRequests[index][0]]++;
    for (const kind of kinds) assert.equal(value.byKind[kind], expected[kind]);
    for (const record of records.values()) assert.ok(record.status && record.closed);
  }

  /**
   * Gắn REQUEST/STATUS/CLOSED vào đúng id, cho phép transport close xen nhau giữa các connection.
   * Input
   * Param: event — metadata bounded của capture, request order vẫn exact theo business intents.
   */
  function observe(event) {
    guarded(
      /** Chỉ REQUEST mới cấp id tiếp theo, STATUS/CLOSED không được bù request thiếu hoặc foreign target. */
      () => {
        const extra = event?.event === 'STATUS' ? ['status'] :
          event?.event === 'CLOSED' ? ['requestObserved','statusObserved'] : [];
        assert.ok(exactKeys(event, ['sequence','elapsedMilliseconds','event','requestId','kind','matchesTarget', ...extra]) &&
          ['REQUEST','STATUS','CLOSED'].includes(event.event) &&
          event.sequence === sequence + 1 && Number.isFinite(event.elapsedMilliseconds) &&
          event.elapsedMilliseconds >= lastElapsed && Number.isSafeInteger(event.requestId) &&
          event.requestId > 0 && event.requestId <= expectedRequests.length);
        sequence = event.sequence; lastElapsed = event.elapsedMilliseconds;
        if (event.event === 'REQUEST') {
          const index = records.size;
          assert.ok(event.requestId === index + 1 && index < expectedRequests.length &&
            event.kind === expectedRequests[index][0] && event.matchesTarget === (index === targetIndex));
          records.set(event.requestId, { kind: event.kind, target: event.matchesTarget, status: false, closed: false });
          return;
        }
        const record = records.get(event.requestId);
        assert.ok(record && !record.closed && event.kind === record.kind && event.matchesTarget === record.target);
        if (event.event === 'STATUS') {
          assert.ok(!record.status && event.status === expectedRequests[event.requestId - 1][1]);
          record.status = true;
        } else {
          assert.ok(record.status && event.requestObserved === true && event.statusObserved === true);
          record.closed = true;
        }
      });
  }

  /**
   * Pin hostNoCA raw1 trước SDK, không cho request business lọt vào baseline.
   * Input
   * Param: value — snapshot idle sau host TLS negative được owner xác minh.
   */
  function begin(value) {
    guarded(/** Baseline chỉ một lần và trước mọi metadata HTTP. */ () => {
      assert.ok(!baseline && sequence === 0 && position === -1);
      snapshot(value, 0, 1); baseline = true;
    });
  }

  /**
   * Commit đúng stage sau khi UI pause và transport thật idle, không auto retry lỗi metadata.
   * Input
   * Param: stage — enum fixed tiếp theo.
   * Param: value — snapshot tại boundary, không dữ liệu body/UI.
   */
  function checkpoint(stage, value) {
    guarded(/** Snapshot sai không được advance position rồi che bằng request ở stage kế. */ () => {
      assert.ok(baseline && position + 1 < expectedStages.length && stage === expectedStages[position + 1]);
      snapshot(value, expectedPrefixes[position + 1], 2); position++;
    });
  }

  /**
   * Recheck cùng prefix sau SQL pause để bắt request phát muộn trước ACK.
   * Input
   * Param: value — snapshot hiện hành của đúng proxy owner.
   */
  function assertCurrent(value) {
    guarded(/** Không mở stage hoặc deadline mới khi chỉ kiểm freshness counters. */ () => {
      assert.ok(baseline && position >= 0);
      snapshot(value, expectedPrefixes[position], 2);
    });
  }

  /**
   * Chốt sau SDK stop và post-PID gate, không nhận thêm business event sau đó.
   * Input
   * Param: value — final idle snapshot khi proxy vẫn available.
   */
  function finish(value) {
    guarded(/** Mọi UI checkpoint và exact request/status/close của preset đều bắt buộc trước final. */ () => {
      assert.ok(position === expectedStages.length - 1);
      snapshot(value, expectedRequests.length, 2); finished = true;
    });
  }
  return Object.freeze({ observe, baseline: begin, checkpoint, assertCurrent, finish });
}

/**
 * Copy audit scalar exact schema/bounds, giữ duplicates để validator đếm đúng cardinality.
 * Input
 * Param: rows — read-only projection của fixture, không audit payload hoặc token.
 */
export function auditRows(rows) {
  assert.ok(Array.isArray(rows) && rows.length <= 32, 'NATIVE_MEMBERSHIP_AUDIT_INVALID');
  return rows.map(
    /**
     * Không normalize UUID/event để metadata sai không trở thành proof hợp lệ.
     * Input
     * Param: row — một public audit tuple, mọi extension đều bị chặn.
     */
    (row) => {
      assert.ok(exactKeys(row, ['sessionId','eventType','outcome','clientType']) &&
        typeof row.sessionId === 'string' && uuid.test(row.sessionId) &&
        ['LOGIN_SUCCEEDED','LOGOUT'].includes(row.eventType) &&
        ['SUCCESS','FAILURE'].includes(row.outcome) && row.clientType === 'ANDROID',
      'NATIVE_MEMBERSHIP_AUDIT_INVALID');
      return { sessionId: row.sessionId, eventType: row.eventType, outcome: row.outcome, clientType: row.clientType };
    });
}

/**
 * Đếm audit tuples để giữ baseline nguyên vẹn và App mới có đúng một login/logout SUCCESS.
 * Input
 * Param: baseline — audit trước SDK, copy immutable do wrapper giữ.
 * Param: final — audit sau UI logout, cùng scope account0 owned.
 * Param: appSessionId — UUID mới đã được validateSessionDelta bind, không bearer.
 */
export function validateMembershipAudit(baseline, final, appSessionId) {
  assert.ok(typeof appSessionId === 'string' && uuid.test(appSessionId), 'NATIVE_MEMBERSHIP_AUDIT_INVALID');
  const before = auditRows(baseline); const after = auditRows(final);
  const baselineCounts = new Map(); const finalCounts = new Map();
  let login = 0; let logout = 0;
  for (const row of before) {
    assert.notEqual(row.sessionId, appSessionId, 'NATIVE_MEMBERSHIP_AUDIT_INVALID');
    const key = JSON.stringify(row); baselineCounts.set(key, (baselineCounts.get(key) ?? 0) + 1);
  }
  for (const row of after) {
    if (row.sessionId === appSessionId) {
      assert.equal(row.outcome, 'SUCCESS', 'NATIVE_MEMBERSHIP_AUDIT_INVALID');
      if (row.eventType === 'LOGIN_SUCCEEDED') login++; else logout++;
    } else {
      const key = JSON.stringify(row); finalCounts.set(key, (finalCounts.get(key) ?? 0) + 1);
    }
  }
  assert.ok(login === 1 && logout === 1 && baselineCounts.size === finalCounts.size, 'NATIVE_MEMBERSHIP_AUDIT_INVALID');
  for (const [key, count] of baselineCounts) assert.equal(finalCounts.get(key), count, 'NATIVE_MEMBERSHIP_AUDIT_INVALID');
}

/**
 * Nối UI checkpoint, H2 và scoped DB evidence qua SDK consumer thật, không mở CLI actual.
 * Input
 * Param: packet — synthetic credentials RAM của own fixture, phase membership-stale.
 * Param: certificate — public DER base64, không PFX private.
 * Param: options — owned fixture/target/baseline/http oracle và runtime capabilities nội bộ.
 * Output: own PID sau framework/oracles/SDKstop/post-PID, không trả secret hoặc DB metadata.
 * Errors: fixed failure sau owned cleanup. Caller còn giữ proxy và fixture lifetime toàn orchestration.
 */
export async function runNativeMembershipPhase(packet, certificate, options) {
  const { fixture, target, baseline, httpOracle, readHttpSnapshot, workDeadline, runtime = {} } = options;
  const pause = runtime.pause ?? delay;
  const checkPid = runtime.checkPid ?? assertNativePid;
  let sdkExit; let processId; let success = false; let cleanupPassed = true;
  let mid; let appSessionId; let fixtureClosing;

  /**
   * Memoize trước callback để reentrant abort/STOP không gọi close hai lần.
   * Output: true chỉ khi original fixture.close hoàn tất, rejection được giữ bằng false để không unhandled.
   */
  function beginFixtureClose() {
    if (!fixtureClosing) {
      let settleClose;
      fixtureClosing = new Promise(
        /**
         * Giữ wrapper observer trước khi close có thể phát abort đồng bộ.
         * Input
         * Param: resolve — chốt terminal result của đúng original close, không timer giả.
         */
        (resolve) => { settleClose = resolve; });
      try {
        Promise.resolve(fixture?.close()).then(
          /** Chỉ original close resolve mới cấp cleanup acknowledgement cho wrapper. */
          () => settleClose(typeof fixture?.close === 'function'),
          /** Lỗi owner vẫn phải settle observer và cấm PASS, không in raw error. */
          () => settleClose(false));
      } catch { settleClose(false); }
    }
    return fixtureClosing;
  }
  try {
    assert.ok(fixture && typeof fixture.close === 'function' && typeof fixture.snapshot === 'function' &&
      typeof fixture.suspendMembershipB === 'function' && typeof fixture.membershipSessionEvidence === 'function');
    assert.ok(packet?.version === 1 && packet.phase === 'membership-stale' && typeof packet.password === 'string' &&
      packet.password.length === 35 && /^Aa1[0-9a-f]{32}$/.test(packet.password) && Array.isArray(packet.emails) &&
      packet.emails.length === 5 && typeof packet.emails[0] === 'string');
    const runId = /^probe-(.+)-0@example\.invalid$/.exec(packet.emails[0])?.[1];
    assert.ok(runId && uuid.test(runId) && packet.emails.every(
      /** Input Param: email/index — đúng năm namespace synthetic, không địa chỉ sản phẩm tùy ý. */
      (email, index) => email === 'probe-' + runId + '-' + index + '@example.invalid'));
    assert.ok(exactKeys(target, ['workspaceId','revision','authorizationVersion','grantGeneration']) &&
      typeof target.workspaceId === 'string' && uuid.test(target.workspaceId));
    for (const key of ['revision','authorizationVersion','grantGeneration']) {
      assert.ok(Number.isSafeInteger(target[key]) && target[key] > 0 && target[key] < Number.MAX_SAFE_INTEGER);
    }
    const pinnedTarget = { ...target };
    assert.ok(exactKeys(baseline, ['sessions','audit']));
    nativeSessionMap(baseline.sessions);
    const initialSessions = baseline.sessions.map(/** Input Param: row — UUID/revoked public đã parse, copy tránh mutation ngoài wrapper. */
      (row) => ({ ...row }));
    const initialAudit = auditRows(baseline.audit);
    assert.ok(httpOracle && typeof readHttpSnapshot === 'function');

    /**
     * Chỉ poll transport idle trong pause được SDK cấp, không tạo window mới hoặc coi incomplete là idle hợp lệ.
     * Input
     * Param: admission — fence checkpoint monotonic, external abort đóng ngay.
     */
    async function idle(admission) {
      while (true) {
        admission.assertActive();
        const snapshot = readHttpSnapshot();
        assert.ok(snapshot?.healthy === true && snapshot.proxyAvailable === true && snapshot.sealed === false);
        if (snapshot.rawActive === 0 && snapshot.active === 0) return snapshot;
        await pause(25);
        admission.assertActive();
      }
    }

    processId = await runNativePhase(packet, certificate,
      /**
       * Bind same AppUUID revoked và exact audit sau UI logout, trước SDK stop trong final130s.
       * Input
       * Param: ownedPid — PID đã bind từ native initial status, không authority DB.
       * Param: admission — immutable final oracle fence.
       */
      async (ownedPid, admission) => {
        admission.assertActive();
        assert.ok(Number.isSafeInteger(ownedPid) && ownedPid > 0 && mid && appSessionId);
        httpOracle.assertCurrent(readHttpSnapshot());
        const final = await fixture.membershipSessionEvidence();
        admission.assertActive();
        assert.ok(exactKeys(final, ['sessions','audit']));
        assert.equal(validateSessionDelta(initialSessions, mid, final.sessions), appSessionId);
        validateMembershipAudit(initialAudit, final.audit, appSessionId);
        httpOracle.assertCurrent(readHttpSnapshot());
        admission.assertActive();
      }, packet.password,
      /**
       * Chỉ picker có SQL mid+suspend, năm stage khác chỉ kiểm H2 dưới fixed5s.
       * Input
       * Param: stage — native stage fixed đã được SDK consumer validate.
       * Param: admission — fence cắt bởi native/work/checkpoint deadline.
       */
      async (stage, admission) => {
        const snapshot = await idle(admission);
        admission.assertActive(); httpOracle.checkpoint(stage, snapshot);
        if (stage === 'membership-picker') {
          const rows = await fixture.snapshot('full');
          admission.assertActive();
          appSessionId = validateSessionDelta(initialSessions, rows);
          mid = rows.map(/** Input Param: row — snapshot mid scalar đã validate, giữ copy riêng qua final await. */
            (row) => ({ ...row }));
          httpOracle.assertCurrent(readHttpSnapshot());
          admission.assertActive();
          const receipt = await fixture.suspendMembershipB();
          admission.assertActive();
          assert.ok(exactKeys(receipt, ['workspaceId','revision','authorizationVersion','grantGeneration','status']) &&
            receipt.workspaceId === pinnedTarget.workspaceId && receipt.status === 'SUSPENDED' &&
            receipt.revision === pinnedTarget.revision + 1 &&
            receipt.authorizationVersion === pinnedTarget.authorizationVersion + 1 &&
            receipt.grantGeneration === pinnedTarget.grantGeneration);
          httpOracle.assertCurrent(readHttpSnapshot());
        }
        admission.assertActive();
      }, { ...runtime, workDeadline,
        onPhaseClosing:
          /**
           * Failure bắt đầu fixture STOP trước khi SDK consumer drain raw callback pending.
           * Input
           * Param: phasePassed — business oracle đã thành công, SDKcleanup/postPID vẫn chưa được chứng nhận.
           * Side effects: chỉ khởi động close memoized, luôn return undefined để SDKcleanup tiến đồng thời.
           */
          (phasePassed) => {
            if (!phasePassed) beginFixtureClose();
          },
        captureSdkExit:
          /** Input Param: exit — raw owned SDK completion, không timeout observer hoặc app.stop ACK. */
          (exit) => { sdkExit = exit; },
      });
    checkPid(null);
    httpOracle.finish(readHttpSnapshot());
    success = true;
  } catch {
    success = false;
  } finally {
    if (!success) {
      // Fixture có thể đã tự close khi command lỗi. Idempotent close vẫn phải drain cùng original owner.
      const results = await Promise.allSettled([beginFixtureClose(), sdkExit]);
      cleanupPassed = results[0].status === 'fulfilled' && results[0].value === true &&
        results[1].status === 'fulfilled' && (sdkExit === undefined || results[1].value === 0);
    }
    if (packet && typeof packet === 'object' && Object.getOwnPropertyDescriptor(packet, 'password')?.writable) packet.password = '';
  }
  assert.ok(success && cleanupPassed, 'NATIVE_MEMBERSHIP_PHASE_FAILED');
  return processId;
}
