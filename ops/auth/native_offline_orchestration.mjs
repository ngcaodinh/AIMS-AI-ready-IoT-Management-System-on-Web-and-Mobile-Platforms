import assert from 'node:assert/strict';
import { randomBytes, X509Certificate } from 'node:crypto';
import { setTimeout as delay } from 'node:timers/promises';
import { createMembershipHttpOracle } from './native_membership_evidence.mjs';
import { createOfflineSessionOracle } from './native_offline_evidence.mjs';
import { assertNativePid, runNativePhase } from './run_native_e2e.mjs';

/**
 * Điều phối offline trong một native engine, cùng fixture20phút và proxy H2 owned.
 * Input
 * Param: capabilities — factories TLS/fixture/proxy, SDK consumer và guest network đã pin API36.
 * Param: capabilities.network — readState/setState chỉ quyền mạng của AVD owned.
 * Param: capabilities.phaseRuntime — fake SDK/clock trong host tests, không nhận CLI authority.
 * Param: capabilities.now/wallNow/pause/timers — đồng hồ, bounded poll và timer ownership.
 * Output: PID sau UI/H2/SQL, original SDK/fixture/proxy terminal và restore mạng.
 * Errors: fixed failure, secrets chỉ RAM, pending SQL luôn được drain trước return.
 */
export async function orchestrateNativeOffline({ createFixture, createCertificates, startProxy, verifyHostNoCa,
  network, runPhase = runNativePhase, phaseRuntime = {}, now = performance.now.bind(performance),
  wallNow = Date.now, pause = delay, timers = { setTimeout, clearTimeout },
  certificateInfo =
    /** Param: material — chỉ xuất public DER và validity, không trả private PFX. */
    (material) => {
      const value = new X509Certificate(material.certificate);
      return { certificate: value.raw.toString('base64'), notBefore: Date.parse(value.validFrom), notAfter: Date.parse(value.validTo) };
    } }) {
  let password = 'Aa1' + randomBytes(16).toString('hex');
  const secrets = [password]; const unavailable = new AbortController();
  let fixture; let proxy; let materials; let packet; let certificate; let certificateDeadline; let workDeadline;
  let fixtureClosing; let proxyClosing; let restoring; let changed = false; let restored = false;
  let closing = false; let failed = false; let success = false; let lastNow = 0; let processId;
  let setupTimer; let sqlTimer; let pendingSql; let prepare; let negative; let sessionOracle; let sdkExit;
  let stage = 'BASELINE'; let sqlReads = 0;
  const http = createMembershipHttpOracle('offline-login');

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

  /** Khóa admission trước STOP, không nhả registry SQL hoặc SDK từ timer/abort. */
  function fail() {
    failed = true; unavailable.abort(); closeProxy(); closeFixture();
  }

  /** Fixture/proxy mất availability ngoài cleanup là failure sticky. */
  function ownerUnavailable() {
    if (!closing) fail();
  }

  /** Param: owner — raw proxy registry trước async bind để failure vẫn cleanup đúng instance. */
  function ownProxy(owner) {
    if (proxy === owner) return;
    assert.ok(!proxy && owner && owner.signal instanceof AbortSignal && owner.terminal instanceof Promise);
    proxy = owner; proxy.terminal.catch(/** Drain rejection nhưng không giả terminal PASS. */ () => {});
    proxy.signal.addEventListener('abort', ownerUnavailable); wipe();
    if (proxy.signal.aborted || unavailable.signal.aborted) { fail(); closeProxy(); }
  }

  /**
   * Read-only SQL một owner tại một thời điểm, fixed130s và giữ raw operation tới finally.
   * Param: validate — oracle scalar nhận đúng một receipt sau post-await lifetime check.
   */
  function readSql(validate) {
    active(235_000); assert.ok(!pendingSql);
    const deadline = clock() + 130_000;
    sqlTimer = timers.setTimeout(fail, 130_000);
    const operation = Promise.resolve().then(/** Fence ngay trước original SQL command. */
      () => { active(); return fixture.offlineEvidence(); }).then(
      /** Param: rows — completion thật, late/aborted receipt không được cấp authority. */
      (rows) => { active(); assert.ok(clock() < deadline); validate(rows); active(); sqlReads++; });
    pendingSql = operation;
    operation.then(/** SQL terminal nhả registry, timeout không tự nhả. */
      () => { timers.clearTimeout(sqlTimer); pendingSql = undefined; },
      /** Original rejection báo external failure ngay, không unhandled. */
      () => { timers.clearTimeout(sqlTimer); pendingSql = undefined; fail(); });
    return operation;
  }

  /** Restore attempt có cùng raw owner, lỗi restore không được che bằng second attempt mới. */
  function restore() {
    if (!restoring) {
      let settle; restoring = new Promise(/** Registry trước SDK network operation để cleanup join cùng owner. */
        (resolve) => { settle = resolve; });
      Promise.resolve().then(/** Luôn khôi phục cả data và Wi-Fi qua controller cố định. */
        () => network.setState('enabled')).then(/** Readback riêng sau original write terminal. */
        async () => { assert.equal(await network.readState(), 'enabled'); restored = true; }).then(
        /** Chỉ restore/readback cùng owner thành công mới ACK. */ () => settle(true),
        /** Failure vẫn cho các owner khác cleanup đồng thời. */ () => { fail(); settle(false); });
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
    const before = clock(); fixture = createFixture(password, secrets, ownerUnavailable); const after = clock();
    workDeadline = fixture.workDeadline;
    assert.ok(Number.isFinite(workDeadline) && workDeadline - 1_200_000 >= before && workDeadline - 1_200_000 <= after);
    stage = 'READY'; const ready = await fixture.ready(); active(1_165_000);
    packet = { version: 1, phase: 'offline-login', emails: [...ready.emails], password };
    // Baseline130s song song startup180s, TLS chỉ bind sau khi biết B. Valid packet chờ toàn prepare này.
    prepare = readSql(/** Param: rows — snapshot baseline pin account/workspaces trước mọi UI login. */
      (rows) => { sessionOracle = createOfflineSessionOracle(rows); }).then(
      /** Dùng setup10s bên trong pre-ARM240s, không lấy completion SQL làm mốc gia hạn fixture. */
      async () => {
        stage = 'TLS_SETUP';
        active(); const deadline = clock() + 10_000;
        setupTimer = timers.setTimeout(fail, 10_000);
        ownProxy(await startProxy(materials.valid, sessionOracle.targetWorkspaceId, http.observe, ownProxy));
        active(); await verifyHostNoCa(proxy.signal); active();
        while (proxy.httpSnapshot().rawActive !== 0) {
          assert.ok(clock() < deadline); active(); await pause(25);
        }
        assert.ok(clock() < deadline); active(); http.baseline(proxy.httpSnapshot());
        timers.clearTimeout(setupTimer); setupTimer = undefined;
      });
    prepare.catch(/** Handler trước SDK await, giữ same prepare để drain sau stop. */ () => fail());
    active(1_150_000);
    processId = await runPhase(packet, certificate.certificate,
      /** Param: pid/admission — final oracle sau UI logout, trước SDK cleanup trong130s. */
      async (pid, admission) => {
        stage = 'FINAL_SQL';
        admission.assertActive(); active(235_000); assert.ok(Number.isSafeInteger(pid) && pid > 0);
        http.assertCurrent(await idle(admission));
        await readSql(/** Param: rows — AppUUID revoked cùng exact audit và seed unchanged. */
          (rows) => sessionOracle.final(rows));
        admission.assertActive(); http.assertCurrent(await idle(admission));
      }, password,
      /** Param: checkpoint/admission — fixed native pause và fence do shared consumer sở hữu. */
      async (checkpoint, admission) => {
        stage = checkpoint.toUpperCase().replaceAll('-', '_');
        http.checkpoint(checkpoint, await idle(admission));
        if (checkpoint === 'offline-ready') {
          assert.equal(await network.readState(), 'enabled'); admission.assertActive(); active();
          changed = true; await network.setState('off');
          admission.assertActive(); active(); assert.equal(await network.readState(), 'disabled');
        } else if (checkpoint === 'offline-result') {
          negative = readSql(/** Param: rows — không session/audit delta khi route thật bị cắt. */
            (rows) => sessionOracle.negative(rows));
          negative.catch(/** Negative tiếp tục owned khi restore ACK trước SQL completion. */ () => fail());
          assert.ok(await restore());
        } else if (checkpoint === 'offline-quiet') {
          assert.ok(negative); await negative;
        } else if (checkpoint === 'offline-picker') {
          await readSql(/** Param: rows — đúng một live AppUUID, hai workspace/roles giữ nguyên. */
            (rows) => sessionOracle.mid(rows));
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
          (passed) => { if (!passed) fail(); },
        captureSdkExit:
          /** Param: exit — raw SDK completion, bounded shutdown timeout không cấp quyền nhả owner này. */
          (exit) => {
            assert.ok(sdkExit === undefined && exit instanceof Promise); sdkExit = exit;
            sdkExit.catch(/** Drain rejection ngay, finally vẫn await cùng original completion. */ () => {});
          },
      });
    stage = 'POST_PID_HTTP'; active(); (phaseRuntime.checkPid ?? assertNativePid)(null); http.finish(proxy.httpSnapshot());
    assert.ok(changed && restored); success = true;
  } catch { console.error('NATIVE_OFFLINE_FAILED_STAGE_' + stage); fail(); }
  finally {
    closing = true; unavailable.abort(); timers.clearTimeout(setupTimer); timers.clearTimeout(sqlTimer); wipe();
    // Restore được join cùng owner trước return, kể cả off command đã đổi state rồi báo lỗi.
    const restoreOwner = changed ? restore() : Promise.resolve(true);
    closeProxy(); closeFixture();
    const result = await Promise.allSettled([restoreOwner, proxyClosing ?? true, fixtureClosing ?? true,
      proxy?.terminal, prepare, negative, pendingSql, sdkExit]);
    if (result.some(/** Param: item — rejection của bất kỳ original owner đều cấm PASS. */
      (item) => item.status !== 'fulfilled') || result.slice(0, 3).some(
      /** Param: item — cleanup phải trả literal true, không suy ACK từ timeout/undefined. */
      (item) => item.value !== true)) failed = true;
    proxy?.signal.removeEventListener('abort', ownerUnavailable);
    if (packet) packet.password = ''; password = ''; secrets.fill('');
  }
  assert.ok(success && !failed, 'NATIVE_OFFLINE_ORCHESTRATION_FAILED');
  return processId;
}
