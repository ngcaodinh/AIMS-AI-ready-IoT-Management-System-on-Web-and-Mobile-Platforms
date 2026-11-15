import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { orchestrateNativeRate } from './native_rate_orchestration.mjs';
import { runActualRate } from './run_native_e2e.mjs';

const runId = 'aaaaaaaa-1111-4111-8111-111111111111';
const ready = { runId, emails: Array.from({ length: 5 }, (_, i) => `probe-${runId}-${i}@example.invalid`) };
const turn = () => new Promise((resolve) => setImmediate(resolve));

/**
 * Cấp fixture/proxy/clock giả để kiểm admission và raw cleanup ownership của coordinator thật.
 * Input
 * Param: mode — enum test success hoặc failure/lifetime boundary, không config CLI.
 * Output: capabilities giả cùng state và terminal release do test kiểm soát.
 */
function setup(mode = 'success') {
  const state = { clock: 0, wall: 1_000_000, events: [], stops: 0, proxyCloses: 0 };
  const unavailable = new AbortController();
  let terminalRelease; let fixtureRelease; let onClosing; let fixtureClose;
  const terminal = new Promise((resolve) => { terminalRelease = resolve; });
  const fixtureTerminal = new Promise((resolve) => { fixtureRelease = resolve; });
  const material = { valid: { certificate: 'PUBLIC_CERTIFICATE', pfx: Buffer.from([1, 2, 3]) } };
  const fixture = {
    ready: async () => { state.events.push('ready'); if (mode === 'ready') throw Error(); return ready; },
    arm: async () => {
      state.events.push('arm');
      if (mode === 'arm') { onClosing(); await fixture.close(); throw Error(); }
      const deadline = state.clock + 2_400_000;
      state.clock += mode === 'arm-late' ? 5001 : 10;
      return mode === 'arm-bad-anchor' ? state.clock + 2_400_001 : deadline;
    },
    snapshot: async () => [],
    close: () => {
      if (!fixtureClose) fixtureClose = (async () => {
        state.stops++; state.events.push('fixture-stop'); onClosing();
        if (['delayed-arm', 'both-pending'].includes(mode)) await fixtureTerminal;
        if (mode === 'fixture-cleanup-failed') throw Error();
      })();
      return fixtureClose;
    },
  };
  const proxy = { signal: unavailable.signal, terminal,
    close: () => {
      state.proxyCloses++; state.events.push('proxy-close'); unavailable.abort();
      if (!['proxy-pending', 'both-pending', 'bind-handoff'].includes(mode)) terminalRelease();
      return Promise.resolve(!['proxy-pending', 'both-pending', 'bind-handoff'].includes(mode));
    },
  };
  const caps = {
    now: () => state.clock, wallNow: () => state.wall,
    createFixture: (password, secrets, hook) => {
      assert.match(password, /^Aa1[0-9a-f]{32}$/); state.secrets = secrets; onClosing = hook; return fixture;
    },
    createCertificates: () => {
      state.events.push('certificate'); if (mode === 'certificate') throw Error();
      if (mode === 'startup-late') state.clock = 900_000;
      return material;
    },
    certificateInfo: () => ({ certificate: 'PUBLIC_DER_BASE64', notBefore: 0,
      notAfter: mode === 'cert-short' ? 3_399_999 : mode === 'cert-edge' ? 3_400_010 : 4_300_000 }),
    startProxy: async (_material, observe, onOwned) => {
      state.events.push('proxy'); state.observe = observe;
      onOwned?.(proxy);
      if (mode === 'bind-handoff') { unavailable.abort(); await terminal; throw Error(); }
      if (mode === 'bind') throw Error();
      if (mode === 'proxy-aged') state.clock += 600_001;
      if (mode === 'cert-wall') state.wall = 4_300_000;
      if (mode === 'clock-backwards') state.clock = -1;
      return proxy;
    },
    createPacket: (_ready, password) => {
      state.packet = { version: 1, phase: 'rate-limit', emails: ready.emails, password, wrongPassword: 'Aa2' + 'e'.repeat(32) };
      return state.packet;
    },
    verifyHostNoCa: /** No-CA giả chỉ tiêu clock để kiểm conservative reserve trước SDK phase. */ async (signal) => {
      state.events.push('no-ca'); assert.equal(signal, unavailable.signal);
      if (mode === 'no-ca') throw Error();
      if (mode === 'no-ca-late') state.clock += 210_001;
      if (mode === 'no-ca-pid-reserve') state.clock += 205_001;
    },
    runPhase: async (packet, certificate, owned, readCounts, deadline, runtime) => {
      state.events.push('phase'); assert.equal(deadline, 2_400_000); assert.equal(certificate, 'PUBLIC_DER_BASE64');
      assert.equal(runtime.externalSignal, unavailable.signal); runtime.assertExternalActive();
      assert.equal(state.secrets.length, 2); assert.equal(state.secrets[1], packet.wrongPassword);
      assert.deepEqual([...material.valid.pfx], [0, 0, 0]);
      assert.equal(readCounts().AUTH_LOGIN, 0);
      state.observe('AUTH_LOGIN'); assert.equal(readCounts().AUTH_LOGIN, 1);
      if (mode === 'phase') { await owned.close(); throw Error(); }
      if (mode === 'phase-proxy-stop') { unavailable.abort(); runtime.assertExternalActive(); }
      if (mode === 'phase-wall-expired') { state.wall = 4_300_000; runtime.assertExternalActive(); }
      if (mode === 'phase-late') state.clock = 2_400_000;
      return 1234;
    },
  };
  if (['delayed-arm', 'both-pending'].includes(mode)) fixture.arm = async () => { onClosing(); await fixture.close(); throw Error(); };
  return { state, caps, material, terminalRelease, fixtureRelease };
}

const originalLog = console.log;
const modes = ['success', 'cert-edge', 'ready', 'certificate', 'bind', 'startup-late', 'proxy-aged', 'cert-wall', 'cert-short',
  'clock-backwards', 'arm', 'arm-late', 'arm-bad-anchor', 'no-ca', 'no-ca-late', 'no-ca-pid-reserve', 'phase', 'phase-proxy-stop',
  'phase-wall-expired', 'phase-late', 'fixture-cleanup-failed', 'proxy-pending', 'delayed-arm', 'both-pending', 'bind-handoff'];
for (const mode of modes) {
  const test = setup(mode); let settled = false;
  const markers = []; console.log = (message) => markers.push(message);
  const result = orchestrateNativeRate(test.caps);
  result.then(() => { settled = true; }, () => { settled = true; });
  try {
    if (['proxy-pending', 'delayed-arm', 'both-pending', 'bind-handoff'].includes(mode)) {
      for (let i = 0; i < 20 && !test.state.stops; i++) await turn();
      assert.equal(test.state.proxyCloses, 1); assert.equal(test.state.stops, 1); assert.equal(settled, false);
      assert.deepEqual(markers, []);
      if (['proxy-pending', 'bind-handoff'].includes(mode)) test.terminalRelease(); else test.fixtureRelease();
      if (mode === 'both-pending') { await turn(); assert.equal(settled, false); test.terminalRelease(); }
    }
    if (['success', 'cert-edge'].includes(mode)) {
      assert.equal(await result, 1234);
      assert.deepEqual(test.state.events, ['ready', 'certificate', 'proxy', 'arm', 'no-ca', 'phase', 'proxy-close', 'fixture-stop']);
      assert.deepEqual(markers, ['NATIVE_RATE_OWNED_TERMINAL_ORCHESTRATION_PASS']);
    } else { await assert.rejects(() => result); assert.deepEqual(markers, []); }
    assert.equal(test.state.stops, 1);
    assert.ok(test.state.proxyCloses <= 1);
    if (!['ready', 'certificate'].includes(mode)) assert.deepEqual([...test.material.valid.pfx], [0, 0, 0]);
    if (test.state.packet) { assert.equal(test.state.packet.password, ''); assert.equal(test.state.packet.wrongPassword, ''); }
    assert.ok(test.state.secrets.every((secret) => secret === ''));
    if (['proxy-aged', 'cert-wall'].includes(mode)) assert.ok(!test.state.events.includes('arm'));
    if (!['success', 'cert-edge', 'phase', 'phase-proxy-stop', 'phase-wall-expired', 'phase-late', 'fixture-cleanup-failed', 'proxy-pending'].includes(mode)) {
      assert.ok(!test.state.events.includes('phase'));
    }
  } finally {
    test.terminalRelease(); test.fixtureRelease(); await result.catch(() => {});
    console.log = originalLog;
  }
}
console.log('NATIVE_RATE_ORCHESTRATION_OWNERSHIP_LIFETIME_FAILURES_PASS');

/** Exercise the production wrapper's original fixture/proxy factories, substituting only OS boundaries. */
for (const handoffFailure of [false, true]) {
  const child = new EventEmitter(); child.pid = 4245;
  child.stdin = new EventEmitter(); child.stdout = new EventEmitter(); child.stderr = new EventEmitter();
  const server = new EventEmitter();
  const state = { stopped: 0, closes: 0, phase: false, settled: false };
  const timers = new Set(); let listenerCallback;
  child.stdin.write = (value) => {
    if (value === 'ARM\n') child.stdout.emit('data', Buffer.from('{"kind":"ARMED"}\n'));
    else {
      const packet = JSON.parse(value); assert.equal(packet.scenario, 'rate-limit');
      assert.match(packet.password, /^Aa1[0-9a-f]{32}$/);
      child.stdout.emit('data', Buffer.from(JSON.stringify({ kind: 'READY', ...ready, userIds: [] }) + '\n'));
    }
  };
  child.stdin.end = (value) => {
    assert.equal(value, 'STOP\n'); state.stopped++;
    const cleanup = Object.fromEntries(['role', 'hba', 'users', 'sessions', 'workspaces', 'memberships', 'auditActor', 'limiterBuckets'].map((key) => [key, 0]));
    child.stdout.emit('data', Buffer.from(JSON.stringify({ kind: 'STOPPED', cleanup }) + '\n')); child.emit('exit', 0);
  };
  for (const stream of [child.stdin, child.stdout, child.stderr]) stream.destroy = () => {};
  server.address = () => server.listening ? { port: 12345 } : null;
  server.listen = () => queueMicrotask(() => {
    server.listening = true; server.emit('listening');
    if (handoffFailure) { server.listening = false; server.emit('error', new Error('PRIVATE_BIND_SENTINEL')); }
  });
  server.close = (callback) => { state.closes++; listenerCallback = callback; if (!handoffFailure) callback(); };
  const savedLog = console.log;
  const markers = []; console.log = (message) => markers.push(message);
  const result = runActualRate({
    spawnFixtureProcess: (command, args, options) => {
      assert.equal(command, 'python'); assert.equal(options.shell, false);
      assert.ok(!args.some((arg) => /Aa[12][0-9a-f]{32}/.test(arg)));
      queueMicrotask(() => child.emit('spawn')); return child;
    },
    proxyRuntime: { createServer: () => server,
      setTimeout: (callback, milliseconds) => { const timer = { callback, milliseconds }; timers.add(timer); return timer; },
      clearTimeout: (timer) => timers.delete(timer) },
    verifyHostNoCa: async () => {},
    runPhase: async () => { state.phase = true; return 1234; },
  });
  result.then(() => { state.settled = true; }, () => { state.settled = true; });
  try {
    if (handoffFailure) {
      for (let i = 0; i < 30 && !state.stopped; i++) await turn();
      assert.equal(state.stopped, 1); assert.equal(state.closes, 1);
      assert.equal(state.phase, false); assert.equal(state.settled, false); assert.deepEqual(markers, []);
      listenerCallback(); await assert.rejects(() => result); assert.deepEqual(markers, []);
    } else {
      assert.equal(await result, 1234); assert.equal(state.phase, true);
      assert.deepEqual(markers, ['NATIVE_RATE_OWNED_TERMINAL_ORCHESTRATION_PASS']);
    }
    assert.equal(state.stopped, 1); assert.equal(state.closes, 1); assert.equal(timers.size, 0);
  } finally { listenerCallback?.(); await result.catch(() => {}); console.log = savedLog; }
}
console.log('NATIVE_RATE_PRODUCTION_FACTORY_HANDOFF_INTEGRATION_PASS');
