import assert from 'node:assert/strict';
import { orchestrateNativeMembership } from './native_membership_orchestration.mjs';
import { createHttpMetadataCapture } from './http_metadata_capture.mjs';

const runId = 'aaaaaaaa-1111-4111-8111-111111111111';
const workspaceId = 'bbbbbbbb-2222-4222-8222-222222222222';

/** Output: một vòng event loop để quan sát pending owners, không giả timer hoặc terminal. */
const turn = () => new Promise(/** Param: resolve — continuation sau synchronous abort/close fanout. */
  (resolve) => setImmediate(resolve));

/**
 * Tạo clocks/fixture/proxy/phase giả, giữ HTTP capture thật để kiểm bootstrap oracle.
 * Input
 * Param: mode — fault hoặc boundary cố định do testcase chọn, không nhận CLI configuration.
 * Output: caps cho orchestrator cùng state/release để test sở hữu terminal pending.
 */
function setup(mode) {
  const state = { clock: 0, wall: 1_000_000, events: [], stops: 0, proxyCloses: 0 };
  const abort = new AbortController();
  let closeHook; let capture; let proxyRelease; let fixtureRelease; let fixtureClosing; let bindRelease;
  const bindPending = new Promise(/** Param: resolve — raw setup Promise do test giữ tới late completion. */
    (resolve) => { bindRelease = resolve; });
  const proxyTerminal = new Promise(/** Param: resolve — raw proxy terminal riêng với bounded close result. */
    (resolve) => { proxyRelease = resolve; });
  const fixtureTerminal = new Promise(/** Param: resolve — original fixture cleanup completion do test giữ. */
    (resolve) => { fixtureRelease = resolve; });
  const materials = { valid: { certificate: 'PUBLIC_CERTIFICATE', pfx: Buffer.from([1, 2, 3]) } };
  const fixture = {
    workDeadline: 1_200_000,
    ready: /** Output: namespace synthetic chuẩn, mode slow cố ý tiêu quá admission1165s. */ async () => {
      state.events.push('ready');
      if (mode === 'ready') throw Error('PRIVATE_SENTINEL');
      if (mode === 'slow-ready') state.clock = 35_001;
      if (mode === 'exact-admission') state.clock = 35_000;
      return { runId, emails: Array.from({ length: 5 },
        /** Param: index — suffix account0–4 cùng runId. */ (_, index) => `probe-${runId}-${index}@example.invalid`) };
    },
    membershipTarget: /** Output: target pinned, delay giả kiểm130s đã được khấu trừ conservative. */ async () => {
      state.events.push('target');
      if (mode === 'target') throw Error('PRIVATE_SENTINEL');
      if (mode === 'target-late') state.clock = 165_001;
      return { workspaceId, revision: 1, authorizationVersion: 1, grantGeneration: 1 };
    },
    membershipSessionEvidence: /** Output: baseline giả chưa có native login. */ async () => {
      state.events.push('baseline');
      if (mode === 'baseline') throw Error('PRIVATE_SENTINEL');
      if (mode === 'baseline-late') state.clock = 295_001;
      return { sessions: [], audit: [] };
    },
    snapshot: /** Boundary chỉ dùng trong phase consumer, chưa gọi tại bootstrap. */ async () => [],
    suspendMembershipB: /** Boundary giả, orchestration không tự mutation ngoài phase. */ async () => {},
    close: /** Chốt close promise trước hook để test reentrancy và concurrent cleanup. */ () => {
      if (!fixtureClosing) {
        let finish;
        fixtureClosing = new Promise(/** Param: resolve — observer ghi trước callback closeHook có thể reenter. */
          (resolve) => { finish = resolve; });
        state.stops++; state.events.push('fixture-close'); closeHook();
        fixtureTerminal.then(/** Chỉ terminal release thật mới settle cleanup observer. */
          () => finish());
        if (mode === 'fixture-cleanup') return Promise.reject(Error('PRIVATE_SENTINEL'));
        if (mode !== 'both-pending') fixtureRelease();
      }
      return fixtureClosing;
    },
  };
  const proxy = {
    signal: abort.signal, terminal: proxyTerminal,
    httpSnapshot: /** Output: capture snapshot cộng lifecycle của đúng proxy giả. */
      () => ({ ...capture.snapshot(), proxyAvailable: !abort.signal.aborted }),
    close: /** Bounded false không release raw terminal ở pending mode. */ () => {
      state.proxyCloses++; state.events.push('proxy-close'); abort.abort();
      if (!['proxy-pending', 'both-pending', 'bind-handoff'].includes(mode)) proxyRelease();
      return Promise.resolve(!['proxy-pending', 'both-pending', 'bind-handoff', 'proxy-cleanup'].includes(mode));
    },
  };
  const caps = {
    now: /** Output: monotonic giả để test absolute budget, không clock thật. */ () => state.clock,
    wallNow: /** Output: wallclock giả kiểm certificate expiry độc lập. */ () => state.wall,
    createFixture: /** Param: password/secrets/hook — RAM credential và original pre-STOP hook của orchestrator. */
      (password, secrets, hook) => {
        assert.match(password, /^Aa1[0-9a-f]{32}$/); state.secrets = secrets; closeHook = hook;
        fixture.workDeadline = state.clock + 1_200_000;
        if (mode === 'bad-anchor') fixture.workDeadline++;
        return fixture;
      },
    createCertificates: /** Output: PFX giả có thể kiểm zero sau handoff hoặc setup failure. */ async () => {
      state.events.push('certificate');
      if (mode === 'certificate') throw Error('PRIVATE_SENTINEL');
      if (mode === 'certificate-warmup') state.clock = 60_000;
      return materials;
    },
    certificateInfo: /** Output: validity bounds công khai, không trả PFX private. */ () => ({
      certificate: 'PUBLIC_DER_BASE64', notBefore: 0, notAfter: mode === 'cert-short' ? 1_899_999 : 4_300_000,
    }),
    startProxy: /** Param: material/target/observe/onOwned — TLS handoff, pinned matcher và owned raw proxy publication. */
      async (material, target, observe, onOwned) => {
        assert.equal(target, workspaceId);
        capture = createHttpMetadataCapture({ targetWorkspaceId: target, onEvent: observe,
          now: /** Output: capture dùng cùng monotonic host clock. */ () => state.clock });
        state.events.push('proxy');
        if (mode === 'late-owned') await bindPending;
        onOwned(proxy);
        if (mode === 'bind-timeout') await bindPending;
        if (mode === 'tls-late') state.clock = 10_000;
        if (mode === 'bind-handoff') { abort.abort(); await proxyTerminal; throw Error('PRIVATE_SENTINEL'); }
        if (mode === 'bind') throw Error('PRIVATE_SENTINEL');
        if (mode === 'proxy-late') state.clock = 300_001;
        if (mode === 'wall-expired') state.wall = 4_300_000;
        if (mode === 'clock-backwards') state.clock = -1;
        return proxy;
      },
    verifyHostNoCa: /** Param: signal — external abort của same owned proxy, raw handshake giả chưa có HTTP. */
      async (signal) => {
        assert.equal(signal, abort.signal); state.events.push('no-ca');
        capture.openRaw()();
        if (mode === 'no-ca') throw Error('PRIVATE_SENTINEL');
        if (mode === 'no-ca-late') state.clock = 305_001;
        if (mode === 'no-ca-local-late') state.clock = 10_000;
        if (mode === 'extra-raw') capture.openRaw()();
      },
    timers: {
      setTimeout: /** Param: callback/milliseconds — owner setup timer giả để kiểm đóng chủ động khi await đang pending. */
        (callback, milliseconds) => { assert.equal(milliseconds, 10_000); state.expireSetup = callback; return callback; },
      clearTimeout: /** Param: timer — cleanup timer chỉ gỡ callback cùng owner, không gọi terminal release. */
        (timer) => { if (state.expireSetup === timer) state.expireSetup = undefined; },
    },
    runPhase: /** Param: packet/certificate/options — handoff vào consumer, fake này chỉ kiểm orchestration boundaries. */
      async (packet, certificate, options) => {
        state.events.push('phase'); state.packet = packet;
        assert.equal(certificate, 'PUBLIC_DER_BASE64'); assert.equal(options.workDeadline, fixture.workDeadline);
        assert.equal(options.target.workspaceId, workspaceId); assert.deepEqual(options.baseline, { sessions: [], audit: [] });
        assert.deepEqual([...materials.valid.pfx], [0, 0, 0]);
        options.runtime.assertExternalActive();
        if (mode === 'phase') throw Error('PRIVATE_SENTINEL');
        if (mode === 'phase-proxy-abort') { abort.abort(); options.runtime.assertExternalActive(); }
        if (mode === 'phase-fixture-close') { await options.fixture.close(); options.runtime.assertExternalActive(); }
        if (mode === 'phase-expired') state.clock = 1_200_000;
        if (mode === 'phase-after-tls-window') state.clock = 10_001;
        if (mode === 'phase-pid') return 0;
        return 8123;
      },
  };
  return { state, caps, proxyRelease, fixtureRelease, bindRelease, materials };
}

const successes = ['success', 'exact-admission', 'phase-after-tls-window', 'certificate-warmup'];
const modes = [...successes, 'ready', 'slow-ready', 'bad-anchor', 'target', 'target-late', 'baseline',
  'baseline-late', 'certificate', 'tls-late', 'cert-short', 'bind', 'bind-handoff', 'proxy-late', 'wall-expired',
  'clock-backwards', 'no-ca', 'no-ca-late', 'no-ca-local-late', 'extra-raw', 'phase', 'phase-proxy-abort',
  'phase-fixture-close', 'phase-expired', 'phase-pid', 'fixture-cleanup', 'proxy-cleanup', 'proxy-pending', 'both-pending',
  'bind-timeout', 'late-owned'];
for (const mode of modes) {
  const test = setup(mode); let settled = false;
  const result = orchestrateNativeMembership(test.caps);
  result.then(/** Bắt settlement để pending terminal không được biến thành cleanup PASS sớm. */
    () => { settled = true; }, /** Failure vẫn là settlement, không raw exception output. */
    () => { settled = true; });
  try {
    if (['bind-timeout', 'late-owned'].includes(mode)) {
      for (let index = 0; index < 30 && !test.state.events.includes('proxy'); index++) await turn();
      assert.equal(test.state.stops, 0, mode);
      test.state.expireSetup();
      assert.equal(test.state.stops, 1, mode); assert.equal(settled, false, mode);
      assert.equal(test.state.proxyCloses, mode === 'late-owned' ? 0 : 1, mode);
      test.bindRelease();
    }
    if (['proxy-pending', 'both-pending', 'bind-handoff'].includes(mode)) {
      for (let index = 0; index < 30 && !test.state.stops; index++) await turn();
      assert.equal(test.state.stops, 1, mode); assert.equal(test.state.proxyCloses, 1, mode);
      assert.equal(settled, false, mode);
      test.fixtureRelease(); await turn();
      assert.equal(settled, false, mode);
      test.proxyRelease();
    }
    if (successes.includes(mode)) assert.equal(await result, 8123, mode);
    else await assert.rejects(/** Output: chính pending coordinator Promise, không tạo run mới khi kiểm failure. */
      () => result, { message: 'NATIVE_MEMBERSHIP_ORCHESTRATION_FAILED' }, mode);
    assert.equal(test.state.stops, mode === 'certificate' ? 0 : 1, mode); assert.ok(test.state.proxyCloses <= 1, mode);
    assert.ok((test.state.secrets ?? []).every(/** Param: secret — mọi slot credential phải bị wipe sau owned terminal. */
      (secret) => secret === ''), mode);
    assert.deepEqual([...test.materials.valid.pfx], test.state.events.includes('certificate') && mode !== 'certificate' ? [0, 0, 0] : [1, 2, 3], mode);
    if (test.state.packet) assert.equal(test.state.packet.password, '', mode);
    assert.equal(test.state.expireSetup, undefined, mode);
    if (['slow-ready', 'bad-anchor'].includes(mode)) assert.ok(!test.state.events.includes('target'), mode);
    console.log('MEMBERSHIP_ORCHESTRATION_' + mode.toUpperCase().replaceAll('-', '_') + '_PASS');
  } finally {
    test.fixtureRelease(); test.proxyRelease(); test.bindRelease();
    await result.catch(/** Đã assert outcome, vẫn giữ observer khi test assertion lỗi. */ () => {});
  }
}
