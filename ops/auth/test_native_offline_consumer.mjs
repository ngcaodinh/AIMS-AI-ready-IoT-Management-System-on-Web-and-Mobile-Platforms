import assert from 'node:assert/strict';
import { nativePhaseBudget, runNativePhase } from './run_native_e2e.mjs';
import { createFakeMembershipRuntime } from './test_native_membership_consumer.mjs';

const stages = ['offline-ready', 'offline-result', 'offline-quiet', 'offline-picker', 'offline-logged-out'];
const password = 'Aa1' + 'd'.repeat(32);

/** Kiểm profile/ordering/prepare fence trên SDK fake; không emulator/TLS/DB hoặc raw credentials stdout. */
async function main() {
  assert.deepEqual(nativePhaseBudget('offline-login'), { testMilliseconds: 675_000, reserveMilliseconds: 1_150_000 });
  console.log('OFFLINE_PHASE_BUDGET_PASS');
  const { state, runtime } = createFakeMembershipRuntime('success', 'offline-login');
  let prepared = false;
  runtime.beforePacket =
    /** Baseline được mô phỏng hoàn tất trước valid packet; callback không có authority SDK hoặc wire config. */
    async (admission) => {
      admission.assertActive();
      assert.equal(state.fixtureWrites, 0);
      prepared = true;
      admission.assertActive();
    };
  const observed = [];
  const packet = { version: 1, phase: 'offline-login', password,
    emails: Array.from({ length: 5 },
      /** Param: index — vị trí trong cùng synthetic namespace, không account thật. */
      (_, index) => `probe-aaaaaaaa-1111-4111-8111-111111111111-${index}@example.invalid`) };
  const pid = await runNativePhase(packet, 'public-certificate',
    /** Native result chỉ được oracle sau đủ5checkpoint đã ACK và trước SDK cleanup. */
    async (nativePid, admission) => { admission.assertActive(); assert.equal(nativePid, 8123); }, password,
    /** Param: stage — fixed stage từ fake SDK đã được shared consumer kiểm schema/thứ tự. */
    async (stage, admission) => { admission.assertActive(); assert.equal(prepared, true); observed.push(stage); }, runtime);
  assert.equal(pid, 8123);
  assert.deepEqual(observed, stages);
  assert.deepEqual(state.accepted, stages);
  assert.equal(state.sdkExited, true);
  assert.equal(packet.password, '');
  console.log('OFFLINE_CONSUMER_ORDERED_PREPARE_PASS');

  for (const mode of ['insufficient', 'slow-pid-admission', 'stage-order', 'oversized', 'missing-remaining',
    'foreign-phase', 'foreign-pid', 'early-pass', 'phase-late', 'prepare-throw', 'prepare-late',
    'prepare-clock-backward', 'prepare-missing', 'prearm-zero', 'prearm-oversized', 'prearm-missing']) {
    const fake = createFakeMembershipRuntime(mode, 'offline-login');
    fake.runtime.beforePacket =
      /** Fault chỉ trong trusted fake callback; không command/SQL qua wire. */
      async (admission) => {
        admission.assertActive();
        if (mode === 'prepare-throw') throw new Error('SYNTHETIC_PRIVATE_FAILURE');
        if (mode === 'prepare-late') fake.state.clock += 240_000;
        if (mode === 'prepare-clock-backward') {
          fake.state.clock += 100; admission.assertActive(); fake.state.clock -= 1;
        }
        admission.assertActive();
      };
    if (mode === 'prepare-missing') delete fake.runtime.beforePacket;
    if (mode.startsWith('prearm-')) fake.state.onStatus =
      /** Native pre-ARM receipt chưa trusted; schema sai phải chặn trước baseline callback/packet. */
      (value) => {
        if (fake.state.fixtureWrites === 0) {
          if (mode === 'prearm-missing') delete value.preArmRemainingMilliseconds;
          else value.preArmRemainingMilliseconds = mode === 'prearm-zero' ? 0 : 240_001;
        }
      };
    const value = { ...packet, password };
    await assert.rejects(runNativePhase(value, 'public-certificate',
      /** Final oracle không cần mutation để fake phase có thể tới completion. */
      async () => {}, password,
      /** Callback giữ contract async, mọi stage phải được consumer fence trước ACK. */
      async (_, admission) => { admission.assertActive(); }, fake.runtime));
    if (fake.state.spawned) assert.equal(fake.state.sdkExited, true);
    if (mode.startsWith('prepare-') || mode.startsWith('prearm-')) assert.equal(fake.state.fixtureWrites, 0);
    console.log(`OFFLINE_CONSUMER_${mode.toUpperCase().replaceAll('-', '_')}_PASS`);
  }

  for (const location of ['prepare', 'checkpoint']) {
    for (const abort of [false, true]) {
      const fake = createFakeMembershipRuntime('success', 'offline-login');
      let resolvePending;
      const pending = new Promise(
        /** Giữ original fake I/O tới khi SDK đã exit; deadline không được coi Future settled. */
        (resolve) => { resolvePending = resolve; });
      let captured;
      fake.runtime.beforePacket =
        /** Pre-ARM có thể còn SQL pending; callback không được nhả ownership khi observer hết hạn. */
        async (admission) => {
          admission.assertActive();
          if (location === 'prepare') {
            captured = admission;
            if (abort) fake.external.abort();
            await pending;
            admission.assertActive();
          }
        };
      let returned = false;
      const run = runNativePhase({ ...packet, password }, 'public-certificate',
        /** Không có DB oracle thật trong fake SDK test. */
        async () => {}, password,
        /** Dừng đúng first checkpoint khi cần kiểm late callback ownership. */
        async (_, admission) => {
          admission.assertActive();
          if (location === 'checkpoint') {
            captured = admission;
            if (abort) fake.external.abort();
            await pending;
            admission.assertActive();
          }
        }, fake.runtime);
      const observed = run.then(
        /** Bất kỳ return sớm nào trước raw I/O đều bị test nhìn thấy. */
        () => { returned = true; },
        /** Giữ rejection observer ngay, assertion nguyên gốc kiểm sau release. */
        () => { returned = true; });
      await fake.state.sdkExit;
      assert.equal(returned, false);
      assert.throws(captured.assertActive);
      resolvePending();
      await assert.rejects(run);
      await observed;
      assert.equal(returned, true);
      console.log(`OFFLINE_${location.toUpperCase()}_PENDING_${abort ? 'ABORT' : 'DEADLINE'}_OWNED_PASS`);
    }
  }
}

await main();
