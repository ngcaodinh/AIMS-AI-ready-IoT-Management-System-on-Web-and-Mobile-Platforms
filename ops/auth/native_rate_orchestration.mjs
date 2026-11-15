import assert from 'node:assert/strict';
import { randomBytes, X509Certificate } from 'node:crypto';

const workMilliseconds = 2_400_000;
const proxyMilliseconds = 3_000_000;
const counterKeys = ['AUTH_LOGIN', 'AUTH_LOGOUT', 'PROFILE_READ', 'WORKSPACE_LIST', 'PASSWORD_CHANGE', 'OTHER'];

/** Public certificate metadata only; private PFX never leaves the TLS factory/owner. */
function describeCertificate(material) {
  const certificate = new X509Certificate(material.certificate);
  return { certificate: certificate.raw.toString('base64'),
    notBefore: Date.parse(certificate.validFrom), notAfter: Date.parse(certificate.validTo) };
}

/**
 * Own one rate run from fixture creation through actual proxy/fixture terminal receipts.
 * Capabilities are trusted process/TLS boundaries for host tests, never CLI/user configuration.
 * The phase capability is runNativeRatePhase in production and owns SDK/PID/session/counter proof.
 */
export async function orchestrateNativeRate({ createFixture, createCertificates, startProxy, createPacket,
  runPhase, verifyHostNoCa, certificateInfo = describeCertificate, phaseRuntime = {},
  now = performance.now.bind(performance), wallNow = Date.now }) {
  let password = `Aa1${randomBytes(16).toString('hex')}`;
  const secrets = [password];
  const counts = Object.fromEntries(counterKeys.map((key) => [key, 0]));
  let fixture; let proxy; let materials; let packet; let certificate;
  let certificateDeadline; let proxyDeadline; let workDeadline;
  let proxyClosing; let fixtureClosing; let phaseStarted = false; let success = false; let failed = false; let processId;
  let lastNow = now(); const startupDeadline = lastNow + 900_000;

  function clock() {
    const current = now();
    assert.ok(Number.isFinite(current) && current >= lastNow, 'NATIVE_RATE_CLOCK_INVALID');
    lastNow = current; return current;
  }

  /** Start proxy close synchronously; failure cannot prevent the original fixture STOP. */
  function closeProxy() {
    if (!proxy || proxyClosing) return;
    let resolveClose;
    proxyClosing = new Promise((resolve) => { resolveClose = resolve; });
    try { Promise.resolve(proxy.close()).then((closed) => resolveClose(closed === true), () => resolveClose(false)); }
    catch { resolveClose(false); }
  }

  function closeFixture() {
    if (!fixtureClosing) {
      let resolveClose;
      fixtureClosing = new Promise((resolve) => { resolveClose = resolve; });
      closeProxy();
      try { Promise.resolve(fixture.close()).then(() => resolveClose(true), () => resolveClose(false)); }
      catch { resolveClose(false); }
    }
    return fixtureClosing.then((closed) => { assert.ok(closed, 'NATIVE_RATE_FIXTURE_CLEANUP_FAILED'); });
  }

  function abortStartup() {
    // During SDK work the evidence controller must stop the SDK before fixture STOP.
    if (!phaseStarted) closeFixture().catch(() => {});
  }

  function ownProxy(owner) {
    assert.ok(!proxy || proxy === owner, 'NATIVE_RATE_PROXY_OWNERSHIP_INVALID');
    proxy = owner;
    assert.ok(proxy?.signal instanceof AbortSignal && proxy.terminal instanceof Promise &&
      typeof proxy.close === 'function', 'NATIVE_RATE_PROXY_INVALID');
    wipePfx();
    proxy.signal.addEventListener('abort', abortStartup);
    if (proxy.signal.aborted) abortStartup();
  }

  function wipePfx() {
    for (const value of Object.values(materials ?? {})) if (Buffer.isBuffer(value?.pfx)) value.pfx.fill(0);
  }

  /** All awaits re-enter this guard; a timer or wall-clock jump cannot renew admission. */
  function active(reserve = 0, fullLifetime = false) {
    const current = clock(); const wall = wallNow();
    assert.ok(Number.isFinite(wall), 'NATIVE_RATE_CLOCK_INVALID');
    assert.ok(current < (workDeadline ?? startupDeadline), 'NATIVE_RATE_LIFETIME_EXPIRED');
    if (proxy) assert.ok(!proxy.signal.aborted && current < proxyDeadline, 'NATIVE_RATE_PROXY_UNAVAILABLE');
    if (certificate) {
      assert.ok(wall >= certificate.notBefore && wall < certificate.notAfter && current < certificateDeadline,
        'NATIVE_RATE_CERTIFICATE_EXPIRED');
    }
    if (fullLifetime) {
      assert.ok(proxyDeadline - current >= workMilliseconds && certificateDeadline - current >= workMilliseconds &&
        certificate.notAfter - wall >= workMilliseconds, 'NATIVE_RATE_LIFETIME_INSUFFICIENT');
    }
    const deadline = workDeadline ?? Math.min(current + workMilliseconds, proxyDeadline, certificateDeadline);
    if (reserve) assert.ok(deadline - current >= reserve, 'NATIVE_WORK_BUDGET_INSUFFICIENT');
  }

  try {
    fixture = createFixture(password, secrets, closeProxy);
    active(); const ready = await fixture.ready(); active();
    packet = createPacket(ready, password); secrets.push(packet.wrongPassword);
    materials = await createCertificates(); active();
    certificate = certificateInfo(materials.valid);
    assert.ok(typeof certificate.certificate === 'string' && certificate.certificate.length > 0 &&
      Number.isFinite(certificate.notBefore) && Number.isFinite(certificate.notAfter), 'NATIVE_RATE_CERTIFICATE_INVALID');
    // Sample monotonic first: conversion cannot grant extra lifetime from a later clock read.
    const sampled = clock(); const sampledWall = wallNow();
    assert.ok(Number.isFinite(sampledWall), 'NATIVE_RATE_CLOCK_INVALID');
    certificateDeadline = sampled + certificate.notAfter - sampledWall;
    active();
    proxyDeadline = clock() + proxyMilliseconds;
    const boundProxy = await startProxy(materials.valid, (kind) => {
      assert.ok(Object.hasOwn(counts, kind), 'NATIVE_RATE_COUNTER_INVALID');
      counts[kind]++; assert.ok(Number.isSafeInteger(counts[kind]), 'NATIVE_RATE_COUNTER_INVALID');
    }, ownProxy);
    ownProxy(boundProxy);
    wipePfx();
    assert.ok(proxy?.signal instanceof AbortSignal && proxy.terminal instanceof Promise &&
      typeof proxy.close === 'function', 'NATIVE_RATE_PROXY_INVALID');
    active(2_205_000, true);
    const armIntent = clock();
    workDeadline = await fixture.arm();
    const armed = clock();
    assert.ok(Number.isFinite(workDeadline) && workDeadline - workMilliseconds >= armIntent &&
      workDeadline - workMilliseconds <= armed && armed - armIntent < 5000, 'NATIVE_FIXTURE_ARM_FAILED');
    active(2_200_000, true);
    await verifyHostNoCa(proxy.signal); active(2_195_000);
    const ownedFixture = { snapshot: (scope) => fixture.snapshot(scope), close: closeFixture };
    phaseStarted = true;
    processId = await runPhase(packet, certificate.certificate, ownedFixture, () => ({ ...counts }), workDeadline,
      { ...phaseRuntime, externalSignal: proxy.signal, assertExternalActive: () => active() });
    active(); assert.ok(Number.isSafeInteger(processId) && processId > 0, 'NATIVE_RATE_PID_INVALID');
    success = true;
  } catch { failed = true; }
  finally {
    wipePfx();
    proxy?.signal.removeEventListener('abort', abortStartup);
    // Initiate both before observing either. A proxy timeout never delays STOP or releases raw ownership.
    closeProxy();
    if (fixture) {
      const observed = closeFixture(); observed.catch(() => {});
    }
    const receipts = await Promise.allSettled([proxyClosing ?? true, fixtureClosing ?? true, proxy?.terminal]);
    if (receipts[0].status !== 'fulfilled' || receipts[0].value !== true ||
      receipts[1].status !== 'fulfilled' || receipts[1].value !== true || receipts[2].status !== 'fulfilled') failed = true;
    if (packet) { packet.password = ''; packet.wrongPassword = ''; }
    password = ''; secrets.fill('');
  }
  assert.ok(success && !failed, 'NATIVE_RATE_ORCHESTRATION_FAILED');
  console.log('NATIVE_RATE_OWNED_TERMINAL_ORCHESTRATION_PASS');
  return processId;
}
