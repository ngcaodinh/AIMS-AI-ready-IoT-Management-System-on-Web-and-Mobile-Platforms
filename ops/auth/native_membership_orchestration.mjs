import assert from 'node:assert/strict';
import { randomBytes, X509Certificate } from 'node:crypto';
import { setTimeout as delay } from 'node:timers/promises';
import { createMembershipHttpOracle, runNativeMembershipPhase } from './native_membership_evidence.mjs';

// Ledger mục S2c2b2: fixture20phút neo trước spawn, target130 + baseline130 + TLS10 + native895 giây.
const fixtureMilliseconds = 1_200_000;
const proxyMilliseconds = 3_000_000;

/**
 * Chuyển public certificate thành validity metadata, giữ PFX private trong TLS factory/owner.
 * Input
 * Param: material — material valid của factory nội bộ, certificate là public DER.
 * Output: public DER base64 và wallclock validity bounds, không trả PFX.
 */
function describeCertificate(material) {
  const certificate = new X509Certificate(material.certificate);
  return { certificate: certificate.raw.toString('base64'),
    notBefore: Date.parse(certificate.validFrom), notAfter: Date.parse(certificate.validTo) };
}

/**
 * Điều phối một membership phase với fixed budget và original fixture/proxy/SDK ownership.
 * Input
 * Param: capabilities — trusted factories và OS/clock boundaries cho host tests, không nhận từ CLI hay wire payload.
 * Param: capabilities.createFixture — tạo original membership fixture, nhận password/secrets và pre-STOP hook đồng bộ.
 * Param: capabilities.createCertificates — tạo TLS material RAM của lab.
 * Param: capabilities.startProxy — bind proxy với target matcher/event observer và onOwned trước async bind.
 * Param: capabilities.verifyHostNoCa — xác minh host từ chối CA và đóng raw socket owned.
 * Param: capabilities.runPhase — consumer UI/H2/session/audit/SDK/PID, mặc định implementation thật.
 * Param: capabilities.phaseRuntime — runtime trusted truyền vào consumer, không được ghi đè external fence của coordinator.
 * Param: capabilities.certificateInfo — public validity decoder, injection chỉ cho host tests.
 * Param: capabilities.now — clock monotonic dùng chung với fixture deadline.
 * Param: capabilities.wallNow — wallclock để phát hiện certificate hết hiệu lực khi đồng hồ thay đổi.
 * Param: capabilities.pause — chờ transport idle trong budget hiện có, không reset deadline.
 * Param: capabilities.timers — timer owner cho setup10s, chỉ thay bằng fake trong host tests.
 * Output: PID đã được phase chứng minh, chỉ trả sau original cleanup và raw proxy terminal.
 * Errors: fixed failure sau khi drain owners, không log exception hoặc credential.
 */
export async function orchestrateNativeMembership({ createFixture, createCertificates, startProxy, verifyHostNoCa,
  runPhase = runNativeMembershipPhase, phaseRuntime = {}, certificateInfo = describeCertificate,
  now = performance.now.bind(performance), wallNow = Date.now, pause = delay,
  timers = { setTimeout, clearTimeout } }) {
  let password = 'Aa1' + randomBytes(16).toString('hex');
  const secrets = [password];
  const unavailable = new AbortController();
  let fixture; let proxy; let materials; let packet; let certificate;
  let fixtureClosing; let proxyClosing; let workDeadline; let certificateDeadline; let proxyDeadline; let tlsDeadline;
  let lastNow; let closing = false; let phaseStarted = false; let success = false; let failed = false; let processId;
  let setupTimer;

  /** Output: sample monotonic không lùi/NaN, kể cả clock injection throw đều giữ owned cleanup ở finally. */
  function clock() {
    const current = now();
    assert.ok(Number.isFinite(current) && current >= 0 && (lastNow === undefined || current >= lastNow));
    lastNow = current;
    return current;
  }

  /** Xóa PFX đã bàn giao vào TLS context, hoặc material chưa dùng khi setup thất bại. */
  function wipePfx() {
    for (const value of Object.values(materials ?? {})) {
      if (Buffer.isBuffer(value?.pfx)) value.pfx.fill(0);
    }
  }

  /** Output: memoized bounded proxy close observer, raw terminal vẫn được await riêng ở finally. */
  function beginProxyClose() {
    if (!proxy || proxyClosing) return;
    let settle;
    proxyClosing = new Promise(/** Param: resolve — ghi observer trước synchronous close/abort có thể reenter. */
      (resolve) => { settle = resolve; });
    try {
      Promise.resolve(proxy.close()).then(
        /** Param: result — chỉ literal true mới xác nhận bounded cleanup của proxy. */
        (result) => settle(result === true),
        /** Raw terminal vẫn được giữ sau close rejection, failure không được đổi thành PASS. */
        () => settle(false));
    } catch { settle(false); }
  }

  /** Output: memoized original fixture terminal/8zero observer, không timeout hoặc tự cấp cleanup ACK. */
  function beginFixtureClose() {
    if (!fixture || fixtureClosing) return fixtureClosing;
    let settle;
    fixtureClosing = new Promise(/** Param: resolve — chốt observer trước fixture.close gọi lại pre-STOP hook. */
      (resolve) => { settle = resolve; });
    try {
      Promise.resolve(fixture.close()).then(
        /** Chỉ original factory xác minh terminal/8zero mới resolve close thành công. */ () => settle(true),
        /** Giữ failure riêng, không in diagnostics có thể chứa owned metadata. */ () => settle(false));
    } catch { settle(false); }
    return fixtureClosing;
  }

  /** Khóa SDK admission đồng bộ trước original fixture STOP, đồng thời bắt đầu proxy shutdown. */
  function onFixtureClosing() {
    if (!closing) failed = true;
    unavailable.abort();
    beginProxyClose();
  }

  /** Proxy mất availability phải đóng fixture ngay, giữ pending phase và mọi raw terminal tới settled thật. */
  function onProxyUnavailable() {
    if (!closing) failed = true;
    unavailable.abort();
    beginFixtureClose();
  }

  /**
   * Nhận owner trước async bind để lỗi bind vẫn có raw terminal cần drain.
   * Input
   * Param: owner — capability của đúng startProxy call, handoff và return phải cùng object.
   */
  function ownProxy(owner) {
    if (proxy === owner) return;
    assert.ok(proxy === undefined && owner && typeof owner === 'object');
    proxy = owner;
    assert.ok(proxy.signal instanceof AbortSignal && proxy.terminal instanceof Promise &&
      typeof proxy.close === 'function' && typeof proxy.httpSnapshot === 'function');
    proxy.terminal.catch(/** Gắn rejection observer trước await bind, finally vẫn kiểm kết quả terminal thật. */ () => {});
    wipePfx();
    proxy.signal.addEventListener('abort', onProxyUnavailable);
    if (proxy.signal.aborted) onProxyUnavailable();
    if (unavailable.signal.aborted) beginProxyClose();
  }

  /**
   * Kiểm absolute lifetime và reserve ở từng boundary, không cấp deadline mới sau READY hoặc await.
   * Input
   * Param: reserve — phần ledger còn phải giữ cho các operation tiếp theo, ms.
   */
  function active(reserve = 0) {
    const current = clock();
    assert.ok(!unavailable.signal.aborted && Number.isFinite(workDeadline) && current < workDeadline);
    if (tlsDeadline !== undefined && !phaseStarted) assert.ok(current < tlsDeadline);
    let deadline = workDeadline;
    if (certificate) {
      const wall = wallNow();
      assert.ok(Number.isFinite(wall) && wall >= certificate.notBefore && wall < certificate.notAfter);
      deadline = Math.min(deadline, certificateDeadline, current + certificate.notAfter - wall);
    }
    if (proxy) {
      assert.ok(!proxy.signal.aborted);
      deadline = Math.min(deadline, proxyDeadline);
    }
    assert.ok(deadline - current >= reserve && current < deadline);
  }

  try {
    // Certificate factory đồng bộ có OS timeout riêng. Warm material trước khi cấp fixture20phút.
    materials = await createCertificates();
    certificate = certificateInfo(materials.valid);
    assert.ok(typeof certificate.certificate === 'string' && certificate.certificate.length > 0 &&
      Number.isFinite(certificate.notBefore) && Number.isFinite(certificate.notAfter) &&
      certificate.notAfter > certificate.notBefore);
    const sampled = clock();
    const sampledWall = wallNow();
    assert.ok(Number.isFinite(sampledWall));
    certificateDeadline = sampled + certificate.notAfter - sampledWall;
    const beforeCreate = clock();
    fixture = createFixture(password, secrets, onFixtureClosing);
    const afterCreate = clock();
    workDeadline = fixture.workDeadline;
    assert.ok(Number.isFinite(workDeadline) && workDeadline - fixtureMilliseconds >= beforeCreate &&
      workDeadline - fixtureMilliseconds <= afterCreate);
    active();
    const ready = await fixture.ready();
    active(1_165_000);
    const target = { ...await fixture.membershipTarget() };
    active(1_035_000);
    const baseline = await fixture.membershipSessionEvidence();
    active(905_000);
    packet = { version: 1, phase: 'membership-stale', emails: [...ready.emails], password };
    const httpOracle = createMembershipHttpOracle();
    tlsDeadline = clock() + 10_000;
    setupTimer = timers.setTimeout(
      /** Setup deadline chủ động đóng cả owners, pending bind vẫn phải settle qua original proxy abort/terminal. */
      () => { failed = true; unavailable.abort(); beginProxyClose(); beginFixtureClose(); }, 10_000);
    active(900_000);
    proxyDeadline = clock() + proxyMilliseconds;
    const owner = await startProxy(materials.valid, target.workspaceId, httpOracle.observe, ownProxy);
    ownProxy(owner);
    active(900_000);
    await verifyHostNoCa(proxy.signal);
    active(895_000);
    // destroy() của TLS client chưa phải raw-close ACK. Poll chỉ trong phần budget còn lại trước SDK.
    while (proxy.httpSnapshot().rawActive !== 0) {
      active(895_000);
      await pause(25);
    }
    active(895_000);
    httpOracle.baseline(proxy.httpSnapshot());
    const ownedFixture = {
      snapshot: /** Param: scope — fixed snapshot scope được phase chọn, original factory vẫn validate. */
        (scope) => fixture.snapshot(scope),
      suspendMembershipB: /** Output: same original scoped mutation capability, không selector mới. */
        () => fixture.suspendMembershipB(),
      membershipSessionEvidence: /** Output: same original scoped readback, không SQL tùy ý. */
        () => fixture.membershipSessionEvidence(),
      close: /** Output: failure khi original cleanup không chứng minh terminal/8zero. */ async () => {
        assert.ok(await beginFixtureClose());
      },
    };
    phaseStarted = true;
    timers.clearTimeout(setupTimer);
    setupTimer = undefined;
    processId = await runPhase(packet, certificate.certificate, {
      fixture: ownedFixture, target, baseline, httpOracle, workDeadline,
      readHttpSnapshot: /** Output: metadata của đúng proxy owner, không header/body/credential. */
        () => proxy.httpSnapshot(),
      runtime: { ...phaseRuntime, externalSignal: unavailable.signal,
        assertExternalActive: /** Guard consumer dùng cùng lifetime và abort fence của orchestration. */ () => active() },
    });
    active();
    assert.ok(Number.isSafeInteger(processId) && processId > 0);
    success = true;
  } catch { failed = true; }
  finally {
    closing = true;
    timers.clearTimeout(setupTimer);
    unavailable.abort();
    wipePfx();
    // Khởi động cả hai owners trước khi await để callback pending không tạo vòng chờ STOP/SDK.
    beginProxyClose();
    beginFixtureClose();
    const results = await Promise.allSettled([proxyClosing ?? true, fixtureClosing ?? true, proxy?.terminal]);
    if (results[0].status !== 'fulfilled' || results[0].value !== true ||
      results[1].status !== 'fulfilled' || results[1].value !== true || results[2].status !== 'fulfilled') failed = true;
    proxy?.signal?.removeEventListener('abort', onProxyUnavailable);
    if (packet) packet.password = '';
    password = '';
    secrets.fill('');
  }
  assert.ok(success && !failed, 'NATIVE_MEMBERSHIP_ORCHESTRATION_FAILED');
  return processId;
}
