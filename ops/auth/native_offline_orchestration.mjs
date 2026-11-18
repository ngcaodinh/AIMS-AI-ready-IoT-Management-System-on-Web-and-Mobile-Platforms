import assert from 'node:assert/strict';
import { randomBytes, X509Certificate } from 'node:crypto';
import { setTimeout as delay } from 'node:timers/promises';
import { createMembershipHttpOracle } from './native_membership_evidence.mjs';
import { createOfflineExpiredSessionOracle, createOfflineSessionOracle } from './native_offline_evidence.mjs';
import { assertNativePid, runNativePhase } from './run_native_e2e.mjs';

/**
 * Điều phối offline logout/restart qua hai native process, cùng fixture20phút và proxy H2 owned.
 * Input
 * Param: capabilities — factories TLS/fixture/proxy, SDK consumer và guest network đã pin API36.
 * Param: capabilities.network — readState/setState chỉ quyền mạng của AVD owned.
 * Param: capabilities.seedExpiredSession — tạo row expired bằng INSERT với TTL24h nguyên vẹn.
 * Param: capabilities.phaseRuntime — fake SDK/clock trong host tests, không nhận CLI authority.
 * Param: capabilities.now/wallNow/pause/timers — đồng hồ, bounded poll và timer ownership.
 * Output: PID resume sau UI/H2/SQL, cả SDK/fixture/proxy terminal và restore mạng.
 * Errors: fixed failure, secrets chỉ RAM, pending SQL luôn được drain trước return.
 */
export async function orchestrateNativeOffline({ createFixture, createCertificates, startProxy, verifyHostNoCa,
  network, runPhase = runNativePhase, phaseRuntime = {}, now = performance.now.bind(performance),
  wallNow = Date.now, pause = delay, timers = { setTimeout, clearTimeout }, seedExpiredSession = false,
  certificateInfo =
    /** Param: material — chỉ xuất public DER và validity, không trả private PFX. */
    (material) => {
      const value = new X509Certificate(material.certificate);
      return { certificate: value.raw.toString('base64'), notBefore: Date.parse(value.validFrom), notAfter: Date.parse(value.validTo) };
    } }) {
  let password = 'Aa1' + randomBytes(16).toString('hex');
  let expiredSessionToken = seedExpiredSession ? randomBytes(32).toString('hex') : undefined;
  const secrets = [password, ...(expiredSessionToken ? [expiredSessionToken] : [])];
  const unavailable = new AbortController();
  let fixture; let proxy; let materials; let packet; let certificate; let certificateDeadline; let workDeadline;
  let fixtureClosing; let proxyClosing; let restoring; let changed = false; let restored = false;
  let closing = false; let failed = false; let failureReported = false; let success = false; let lastNow = 0; let processId;
  let setupTimer; let sqlTimer; let pendingSql; let prepare; let negative; let sessionOracle;
  const sdkExits = [];
  let stage = 'BASELINE'; let sqlReads = 0;
  const phase = seedExpiredSession ? 'offline-expired' : 'offline-login';
  const http = createMembershipHttpOracle(phase);

  /** Output: monotonic finite sample, rollback/throw đều cấm PASS và giữ cleanup. */
  function clock() {
    const value = now(); assert.ok(Number.isFinite(value) && value >= lastNow); lastNow = value; return value;
  }

  /** Param: reserve — ledger còn lại, certificate kiểm cả wallclock và monotonic. */
  function active(reserve = 0) {
    const current = clock(); const wall = wallNow();
    assert.ok(!unavailable.signal.aborted && Number.isFinite(workDeadline) && Number.isFinite(wall) &&
      wall >= certificate.notBefore && wall < certificate.notAfter && current < workDeadline &&
      Math.min(workDeadline, certificateDeadline, current + certificate.notAfter - wall) - current >= reserve);
    if (proxy) assert.ok(!proxy.signal.aborted);
  }

  /** Xóa mọi private buffer sau TLS handoff hoặc setup failure. */
  function wipe() {
    for (const material of Object.values(materials ?? {})) if (Buffer.isBuffer(material?.pfx)) material.pfx.fill(0);
  }

  /** Output: same original fixture close, literal true chỉ sau terminal/8zero. */
  function closeFixture() {
    if (!fixture || fixtureClosing) return fixtureClosing;
    let settle; fixtureClosing = new Promise(/** Param: resolve — registry trước synchronous closing hook. */
      (resolve) => { settle = resolve; });
    try { Promise.resolve(fixture.close()).then(/** Original factory đã kiểm 8zero. */ () => settle(true),
      /** Không forward raw DB exception. */ () => settle(false)); } catch { settle(false); }
    return fixtureClosing;
  }

  /** Output: memoized proxy observer, raw terminal vẫn được await riêng. */
  function closeProxy() {
    if (!proxy || proxyClosing) return proxyClosing;
    let settle; proxyClosing = new Promise(/** Param: resolve — owner trước reentrant abort callback. */
      (resolve) => { settle = resolve; });
    try { Promise.resolve(proxy.close()).then(/** Param: result — strict cleanup acknowledgement. */
      (result) => settle(result === true), /** Raw terminal vẫn giữ khi observer reject. */ () => settle(false)); }
    catch { settle(false); }
    return proxyClosing;
  }

  /** Khóa admission trước STOP và chỉ phát một enum nguyên nhân để định vị owner bị lỗi.
   * Input
   * Param: reason — nguyên nhân cố định từ callsite; không chứa exception, payload hay identity.
   */
  function fail(reason = 'UNCLASSIFIED') {
    if (!failureReported) {
      failureReported = true;
      console.error(`NATIVE_OFFLINE_FIRST_FAILURE_${reason}_AT_${stage}`);
    }
    failed = true; unavailable.abort(); closeProxy(); closeFixture();
  }

  /** Fixture/proxy mất availability ngoài cleanup là failure sticky. */
  function ownerUnavailable() {
    if (!closing) fail('PROXY_UNAVAILABLE');
  }

  /** Param: owner — raw proxy registry trước async bind để failure vẫn cleanup đúng instance. */
  function ownProxy(owner) {
    if (proxy === owner) return;
    assert.ok(!proxy && owner && owner.signal instanceof AbortSignal && owner.terminal instanceof Promise);
    proxy = owner; proxy.terminal.catch(/** Drain rejection nhưng không giả terminal PASS. */ () => {});
    proxy.signal.addEventListener('abort', ownerUnavailable); wipe();
    if (proxy.signal.aborted || unavailable.signal.aborted) { fail('PROXY_UNAVAILABLE'); closeProxy(); }
  }

  /**
   * Read-only SQL một owner tại một thời điểm, fixed130s và giữ raw operation tới finally.
   * Param: validate — oracle scalar nhận đúng một receipt sau post-await lifetime check.
   */
  function readSql(validate) {
    active(235_000); assert.ok(!pendingSql);
    const deadline = clock() + 130_000;
    sqlTimer = timers.setTimeout(
      /** SQL timeout chỉ đóng admission; không biến timeout thành receipt terminal. */
      () => fail('SQL_TIMEOUT'), 130_000);
    const operation = Promise.resolve().then(/** Fence ngay trước original SQL command. */
      () => { active(); return fixture.offlineEvidence(); }).then(
      /** Param: rows — completion thật, late/aborted receipt không được cấp authority. */
      (rows) => { active(); assert.ok(clock() < deadline); validate(rows); active(); sqlReads++; });
    pendingSql = operation;
    operation.then(/** SQL terminal nhả registry, timeout không tự nhả. */
      () => { timers.clearTimeout(sqlTimer); pendingSql = undefined; },
      /** Original rejection báo external failure ngay, không unhandled. */
      () => { timers.clearTimeout(sqlTimer); pendingSql = undefined; fail('SQL_FAILED'); });
    return operation;
  }

  /**
   * Khôi phục mạng theo một owner duy nhất; admission chỉ chặn lần ghi mới, cleanup vẫn được phép phục hồi.
   * Input
   * Param: admission — quyền checkpoint tùy chọn; bỏ trống chỉ ở cleanup cuối để không khóa restore.
   * Output: true chỉ sau khi guest readback xác nhận mạng đã bật.
   * Side effects: một lần ghi có admission; cleanup được phép retry sau khi owner gốc đã kết thúc lỗi.
   */
  function restore(admission) {
    if (!restoring) {
      let settle;
      const owner = new Promise(/** Param: resolve — registry trước lệnh mạng để cleanup join cùng owner. */
        (resolve) => { settle = resolve; });
      restoring = owner;
      /** Lỗi giữ failure sticky nhưng nhả owner đã terminal để finally có thể retry phục hồi mạng. */
      const failRestore = () => {
        fail('NETWORK_RESTORE_FAILED');
        if (restoring === owner) restoring = undefined;
        settle(false);
      };
      try {
        // Chuyển quyền giai đoạn xuống bộ điều khiển để kiểm lại trước từng lần ghi trạng thái vô tuyến.
        if (admission) { admission.assertActive(); active(); }
        Promise.resolve(network.setState('enabled', admission)).then(/** Readback riêng sau lệnh mạng gốc đã kết thúc. */
          async () => {
            if (admission) { admission.assertActive(); active(); }
            assert.equal(await network.readState(), 'enabled');
            if (admission) { admission.assertActive(); active(); }
            restored = true;
          }).then(
          /** Chỉ restore/readback cùng owner thành công mới ACK. */ () => settle(true),
          failRestore);
      } catch {
        failRestore();
      }
    }
    return restoring;
  }

  /** Param: admission — fence checkpoint/prepare, poll idle không cấp thêm deadline. */
  async function idle(admission) {
    while (true) {
      active(); admission.assertActive();
      const value = proxy.httpSnapshot();
      assert.ok(value.healthy && value.proxyAvailable && !value.sealed);
      if (value.rawActive === 0 && value.active === 0) return value;
      await pause(25);
    }
  }

  try {
    assert.equal(await network.readState(), 'enabled');
    materials = await createCertificates(); certificate = certificateInfo(materials.valid);
    const sampled = clock(); const wall = wallNow();
    assert.ok(typeof certificate.certificate === 'string' && certificate.certificate.length &&
      Number.isFinite(certificate.notBefore) && Number.isFinite(certificate.notAfter) && Number.isFinite(wall));
    certificateDeadline = sampled + certificate.notAfter - wall;
    const before = clock(); fixture = createFixture(password, secrets, ownerUnavailable, expiredSessionToken); const after = clock();
    workDeadline = fixture.workDeadline;
    assert.ok(Number.isFinite(workDeadline) && workDeadline - 1_200_000 >= before && workDeadline - 1_200_000 <= after);
    stage = 'READY'; const ready = await fixture.ready(); active(1_165_000);
    packet = { version: 1, phase, emails: [...ready.emails], password };
    if (seedExpiredSession) {
      packet.expiredSessionToken = expiredSessionToken;
      packet.expiredSessionId = ready.expiredSessionId;
      packet.expiredSessionExpiresAt = ready.expiredSessionExpiresAt;
    }
    expiredSessionToken = undefined;
    // Baseline130s song song startup180s, TLS chỉ bind sau khi biết B. Valid packet chờ toàn prepare này.
    prepare = readSql(/** Param: rows — snapshot baseline pin account/workspaces trước mọi UI login. */
      (rows) => {
        sessionOracle = seedExpiredSession
          ? createOfflineExpiredSessionOracle(rows, ready.expiredSessionId, ready.expiredSessionExpiresAt)
          : createOfflineSessionOracle(rows);
      }).then(
      /** Dùng setup10s bên trong pre-ARM240s, không lấy completion SQL làm mốc gia hạn fixture. */
      async () => {
        stage = 'TLS_SETUP';
        active(); const deadline = clock() + 10_000;
        setupTimer = timers.setTimeout(
          /** Hết10s setup phải đóng owner thay vì cấp thêm thời gian cho proxy. */
          () => fail('TLS_SETUP_TIMEOUT'), 10_000);
        stage = 'TLS_PROXY_START';
        ownProxy(await startProxy(materials.valid, sessionOracle.targetWorkspaceId, http.observe, ownProxy));
        stage = 'TLS_HOST_NO_CA';
        active(); await verifyHostNoCa(proxy.signal); active();
        stage = 'TLS_PROXY_DRAIN';
        while (proxy.httpSnapshot().rawActive !== 0) {
          assert.ok(clock() < deadline); active(); await pause(25);
        }
        stage = 'TLS_METADATA_BASELINE';
        assert.ok(clock() < deadline); active();
        const baseline = proxy.httpSnapshot();
        // Chỉ công bố counter allowlist để phân biệt raw TLS no-CA với request HTTP ngoài dự kiến.
        console.log(JSON.stringify({ kind: 'NATIVE_OFFLINE_TLS_BASELINE', healthy: baseline.healthy,
          sealed: baseline.sealed, sequence: baseline.sequence, elapsedMilliseconds: baseline.elapsedMilliseconds,
          byKind: baseline.byKind, rawOpened: baseline.rawOpened,
          rawActive: baseline.rawActive, opened: baseline.opened, active: baseline.active,
          requests: baseline.requests, statuses: baseline.statuses, closed: baseline.closed,
          incomplete: baseline.incomplete, proxyAvailable: baseline.proxyAvailable }));
        http.baseline(baseline);
        console.log('NATIVE_OFFLINE_TLS_BASELINE_VALID');
        timers.clearTimeout(setupTimer); setupTimer = undefined;
      });
    prepare.catch(/** Handler trước SDK await, giữ cùng prepare để drain sau stop. */ () => fail('PREPARE_FAILED'));
    active(1_150_000);
    processId = await runPhase(packet, certificate.certificate,
      /** Kiểm logout offline chưa đổi DB trước khi SDK cleanup cho phép process restart. */
      async (pid, admission) => {
        stage = 'OUTBOX_PENDING_SQL';
        admission.assertActive(); active(235_000); assert.ok(Number.isSafeInteger(pid) && pid > 0);
        http.assertCurrent(await idle(admission));
        await readSql(/** Param: rows — session/audit vẫn nguyên vẹn trong khi app offline chờ terminal. */
          (rows) => sessionOracle.unchanged(rows));
        admission.assertActive(); http.assertCurrent(await idle(admission));
      }, secrets,
      /** Param: checkpoint/admission — fixed native pause và fence do shared consumer sở hữu. */
      async (checkpoint, admission) => {
        stage = checkpoint.toUpperCase().replaceAll('-', '_');
        http.checkpoint(checkpoint, await idle(admission));
        if (seedExpiredSession && checkpoint === 'offline-expired-offline') {
          assert.equal(await network.readState(), 'enabled'); admission.assertActive(); active();
          changed = true; await network.setState('off', admission);
          admission.assertActive(); active(); assert.equal(await network.readState(), 'disabled');
        } else if (seedExpiredSession && ['offline-expired-ready', 'offline-expired-persisted'].includes(checkpoint)) {
          assert.equal(await network.readState(), 'disabled');
          await readSql((rows) => sessionOracle.unchanged(rows));
        } else if (checkpoint === 'offline-ready') {
          assert.equal(await network.readState(), 'enabled'); admission.assertActive(); active();
          changed = true; await network.setState('off', admission);
          admission.assertActive(); active(); assert.equal(await network.readState(), 'disabled');
        } else if (checkpoint === 'offline-result') {
          negative = readSql(/** Param: rows — không session/audit delta khi route thật bị cắt. */
            (rows) => sessionOracle.negative(rows));
          negative.catch(/** Negative tiếp tục owned khi restore ACK trước SQL completion. */ () => fail('NEGATIVE_SQL_FAILED'));
          assert.ok(await restore(admission));
        } else if (checkpoint === 'offline-quiet') {
          assert.ok(negative); await negative;
        } else if (checkpoint === 'offline-picker') {
          await readSql(/** Param: rows — đúng một live AppUUID, hai workspace/roles giữ nguyên. */
            (rows) => sessionOracle.mid(rows));
        } else if (checkpoint === 'offline-outbox-ready') {
          assert.equal(await network.readState(), 'enabled'); admission.assertActive(); active();
          await readSql(/** Param: rows — session/audit còn nguyên trước gesture logout offline. */
            (rows) => sessionOracle.unchanged(rows));
          // Re-arm cùng restore owner sau lần guest-off đầu để cleanup có thể bật mạng lần hai.
          restored = false; restoring = undefined; changed = true;
          admission.assertActive(); active();
          await network.setState('off', admission);
          admission.assertActive(); active(); assert.equal(await network.readState(), 'disabled');
        } else if (checkpoint === 'offline-outbox-persisted') {
          assert.equal(await network.readState(), 'disabled');
          await readSql(/** Param: rows — logout offline chưa revoke/audit session trước khi restart. */
            (rows) => sessionOracle.unchanged(rows));
        }
        admission.assertActive(); active(); http.assertCurrent(await idle(admission));
        const snapshot = proxy.httpSnapshot();
        console.log(JSON.stringify({ kind: 'NATIVE_OFFLINE_CHECKPOINT', stage: checkpoint, requests: snapshot.requests,
          statuses: snapshot.statuses, closed: snapshot.closed, incomplete: snapshot.incomplete, sqlReads }));
      }, { ...phaseRuntime, workDeadline, externalSignal: unavailable.signal,
        assertExternalActive: /** Cùng lifetime/abort authority, không nhận guard từ CLI. */ () => active(),
        beforePacket: /** Param: admission — SDK pre-ARM fence, chờ original prepare và giữ910s. */
          async (admission) => { admission.assertActive(); await prepare; admission.assertActive(); active(910_000); },
        onPhaseClosing: /** Param: passed — failure phải đóng fixture để pending SQL drain trước return. */
          (passed) => { if (!passed) fail('NATIVE_PHASE_FAILED'); },
        captureSdkExit:
          /** Param: exit — raw SDK completion, bounded shutdown timeout không cấp quyền nhả owner này. */
          (exit) => {
            assert.ok(exit instanceof Promise); sdkExits.push(exit);
            exit.catch(/** Drain rejection ngay, finally vẫn await cùng original completion. */ () => {});
          },
      });
    stage = 'FIRST_PHASE_CLEANUP';
    (phaseRuntime.checkPid ?? assertNativePid)(null);
    assert.equal(await network.readState(), 'disabled');
    stage = 'RESUME_DB_BASELINE';
    await readSql(/** Param: rows — lưu baseline khi process cũ đã dừng để tránh dùng hết retry của app resume. */
      (rows) => sessionOracle.unchanged(rows));
    active(); http.assertCurrent(proxy.httpSnapshot());
    stage = 'RESUME';
    const resumePacket = { version: 1, phase: 'resume', emails: [...packet.emails], password: '' };
    processId = await runPhase(resumePacket, certificate.certificate,
      /** Đối chiếu exact revoke/audit sau secure outbox nhận server terminal 204. */
      async (pid, admission) => {
        stage = 'RESUME_FINAL_SQL';
        admission.assertActive(); active(105_000); assert.ok(Number.isSafeInteger(pid) && pid > 0);
        await readSql(/** Param: rows — đúng AppUUID được revoke, audit login/logout và seed giữ nguyên. */
          (rows) => sessionOracle.final(rows));
        admission.assertActive(); await idle(admission); http.assertCurrent(proxy.httpSnapshot());
      }, secrets,
      async (checkpoint, admission) => {
        stage = checkpoint.toUpperCase().replaceAll('-', '_');
        http.checkpoint(checkpoint, await idle(admission));
        if (checkpoint === 'offline-outbox-resumed') {
          stage = 'RESUME_NETWORK_STATE';
          assert.equal(await network.readState(), 'disabled');
          admission.assertActive(); active();
          // SQL baseline đã đọc khi app dừng; exact prefix chặn request muộn trước khi mạng được bật.
          http.assertCurrent(await idle(admission));
          stage = 'RESUME_NETWORK_RESTORE';
          assert.ok(await restore(admission));
        }
        if (checkpoint === 'offline-outbox-resumed') stage = 'RESUME_HTTP_RECONCILE';
        admission.assertActive(); active();
        const current = await idle(admission);
        if (checkpoint === 'offline-outbox-resumed') {
          // Bật mạng có thể phát logout hợp lệ ngay; capture oracle vẫn kiểm exact POST/204 tại checkpoint kế.
          assert.ok(current.healthy && !current.sealed && current.proxyAvailable &&
            current.rawActive === 0 && current.active === 0);
        } else {
          http.assertCurrent(current);
        }
        const snapshot = proxy.httpSnapshot();
        console.log(JSON.stringify({ kind: 'NATIVE_OFFLINE_CHECKPOINT', stage: checkpoint, requests: snapshot.requests,
          statuses: snapshot.statuses, closed: snapshot.closed, incomplete: snapshot.incomplete, sqlReads }));
      }, { ...phaseRuntime, offlineLogoutResume: true, workDeadline, externalSignal: unavailable.signal,
        assertExternalActive: /** Cùng lifetime/abort authority, không nhận guard từ CLI. */ () => active(),
        onPhaseClosing: /** Param: passed — failure phải đóng fixture/proxy để mọi operation có terminal. */
          (passed) => { if (!passed) fail('NATIVE_PHASE_FAILED'); },
        captureSdkExit: /** Param: exit — giữ raw SDK completion của phase resume tới cleanup cuối. */
          (exit) => {
            assert.ok(exit instanceof Promise); sdkExits.push(exit);
            exit.catch(/** Drain rejection ngay, finally vẫn await cùng original completion. */ () => {});
          },
      });
    stage = 'POST_PID_HTTP'; active(); (phaseRuntime.checkPid ?? assertNativePid)(null);
    http.finish(proxy.httpSnapshot());
    assert.ok(changed && restored); success = true;
  } catch { console.error('NATIVE_OFFLINE_FAILED_STAGE_' + stage); fail('ORCHESTRATION_FAILED'); }
  finally {
    closing = true; unavailable.abort(); timers.clearTimeout(setupTimer); timers.clearTimeout(sqlTimer); wipe();
    // Restore được join cùng owner trước return, kể cả off command đã đổi state rồi báo lỗi.
    const restoreOwner = changed ? restore() : Promise.resolve(true);
    closeProxy(); closeFixture();
    const result = await Promise.allSettled([restoreOwner, proxyClosing ?? true, fixtureClosing ?? true,
      proxy?.terminal, prepare, negative, pendingSql, ...sdkExits]);
    if (result.some(/** Param: item — rejection của bất kỳ original owner đều cấm PASS. */
      (item) => item.status !== 'fulfilled') || result.slice(0, 3).some(
      /** Param: item — cleanup phải trả literal true, không suy ACK từ timeout/undefined. */
      (item) => item.value !== true)) failed = true;
    proxy?.signal.removeEventListener('abort', ownerUnavailable);
    if (packet) { packet.password = ''; packet.expiredSessionToken = ''; }
    password = ''; secrets.fill('');
  }
  assert.ok(success && !failed, 'NATIVE_OFFLINE_ORCHESTRATION_FAILED');
  return processId;
}
