import assert from 'node:assert/strict';
import { createNativeRateEvidence, nativeSessionMap } from './native_rate_evidence.mjs';
import { runNativeRatePhase } from './run_native_e2e.mjs';

const stages = ['rate-before', 'rate-wrong-1', 'rate-wrong-2', 'rate-wrong-3', 'rate-wrong-4',
  'rate-wrong-5', 'rate-limited', 'rate-mid-cooldown', 'rate-expired', 'rate-login', 'rate-logout'];
const seed = { sessionId: '11111111-1111-4111-8111-111111111111', revoked: false };
const app = { sessionId: '22222222-2222-4222-8222-222222222222', revoked: true };

/** Fake clock/timers và fixture I/O cho capsule thật; không thay App/server clock hoặc mở SDK/DB. */
function setup(mode = 'success', external = {}) {
  const state = { clock: 0, requests: 0, index: 0, timers: new Set(), rows: [{ ...seed }] };
  let release;
  const raw = new Promise(/** Giữ SQL observer giả pending để kiểm deadline không giả terminal. */
    (resolve, reject) => { release = { resolve, reject }; });
  const evidence = createNativeRateEvidence({ ...external, workDeadline: 2_400_000,
    now: /** Ca advancing không cho hai lần đọc clock giả luôn bằng nhau như happy-path. */
      () => { if (mode === 'advancing-clock') state.clock += 0.01; return state.clock; },
    timers: {
      setTimeout: /** Không chạy timer thật130s; test phải chủ động fire hoặc kiểm late reply theo clock. */
        (callback, delay) => { const timer = { callback, deadline: state.clock + delay }; state.timers.add(timer); return timer; },
      clearTimeout: /** Xóa đúng timer owned, không thay clocks hoặc settled flag. */ (timer) => { state.timers.delete(timer); },
    },
    readCounts: /** Đọc cùng schema6counter; ca malformed cố tình thay tên để bắt length-only guard. */
      () => {
        const i = state.index;
        const result = { AUTH_LOGIN: i <= 6 ? i : i <= 8 ? 6 : 7, AUTH_LOGOUT: i === 10 ? 1 : 0,
          PROFILE_READ: i >= 9 ? 1 : 0, WORKSPACE_LIST: i >= 9 ? 1 : 0, PASSWORD_CHANGE: 0, OTHER: 0 };
        if (mode === 'bad-counter') { delete result.OTHER; result.REPLACEMENT = 0; }
        return result;
      },
    fixture: { snapshot:
      /** Chỉ full scope, ba response được sắp theo fixture thật: baseline, sau429, sau logout. */
      async (scope) => {
        assert.equal(scope, 'full'); const number = ++state.requests;
        if ((mode === 'pending' && number === 2) || (mode === 'pending-final' && number === 3)
          || (mode === 'pending-baseline' && number === 1)) return raw;
        if (mode === 'late-baseline') state.clock += 130_000;
        if (mode === 'observer-error' && number === 2) throw new Error('PRIVATE_SQL_SENTINEL');
        if (number === 3) return [seed, mode === 'active-final' ? { ...app, revoked: false } : app];
        return mode === 'changed-mid' && number === 2 ? [{ ...seed, revoked: true }] : state.rows;
      },
    },
  });
  return { state, evidence, release };
}

/** Cho cùng Promise pipeline chạy qua effect/validation; không timeout/sleep thời gian native. */
async function turns() { for (let i = 0; i < 8; i++) await Promise.resolve(); }

/** Đi tới boundary429 bằng từng pure checkpoint, không bỏ thứ tự hoặc bù counters. */
async function toLimited(test) {
  await test.evidence.baseline(); test.evidence.phaseStarted(test.state.clock);
  for (let i = 0; i <= 6; i++) {
    test.state.index = i; test.evidence.checkpoint(stages[i]); test.evidence.released(stages[i]);
  }
  await turns();
}

/**
 * Đi qua đủ11checkpoint để kiểm reserve sau framework PASS bằng cùng capsule thật.
 * Input
 * Param: test — fake fixture/clock và evidence capsule do setup tạo.
 */
async function toFrameworkPassed(test) {
  await toLimited(test);
  for (let index = 7; index < stages.length; index++) {
    test.state.index = index; test.evidence.checkpoint(stages[index]); test.evidence.released(stages[index]);
  }
  test.evidence.passed();
}

/** Kiểm tail125s và admission2195s, không đổi work2400s hoặc phase1260s. */
async function threePidReserveBoundaries() {
  const baseline = setup(); baseline.state.clock = 205_001;
  try {
    await assert.rejects(/** Còn2194999ms không đủ baseline và reserve của ba PID queries. */
      () => baseline.evidence.baseline());
    assert.equal(baseline.state.requests, 0);
  } finally { baseline.evidence.seal(); await baseline.evidence.settle(); }
  for (const remaining of [125_000, 124_999]) {
    const test = setup(); await toFrameworkPassed(test); await test.evidence.final();
    test.state.clock = 2_400_000 - remaining;
    try {
      if (remaining === 125_000) assert.doesNotThrow(/** Equality chỉ đủ admission, chưa phải terminal success. */
        () => test.evidence.assertActive());
      else assert.throws(/** Thiếu1ms phải fail closed dù work chưa hết và mọi snapshot đã valid. */
        () => test.evidence.assertActive());
    } finally { test.evidence.seal(); await test.evidence.settle(); }
  }
  const pending = setup('pending-final'); await toFrameworkPassed(pending);
  pending.state.clock = 2_400_000 - 130_000 - 125_000;
  let rejected = false;
  const final = pending.evidence.final().catch(/** Giữ bounded failure observer khi raw SQL còn pending. */
    () => { rejected = true; });
  await turns(); pending.state.clock++;
  try {
    assert.throws(/** Outstanding final130s cũng phải cộng tail125s, không dùng tail120s cũ. */
      () => pending.evidence.assertActive());
  } finally {
    pending.evidence.seal(); pending.release.resolve([seed, app]);
    await pending.evidence.settle(); await final;
  }
  assert.equal(rejected, true);
  console.log('NATIVE_RATE_THREE_PID_RESERVE_BOUNDARIES_PASS');
}

/** Root capsule checks; wrapper symbol bắt buộc tồn tại để không ghi PASS cho module chưa có actual consumer. */
async function main() {
  await threePidReserveBoundaries();
  assert.equal(typeof runNativeRatePhase, 'function');
  assert.equal(nativeSessionMap([seed]).size, 1);
  assert.throws(/** Duplicate UUID không được làm mất row khi chuẩn hóa Map. */ () => nativeSessionMap([seed, seed]));
  const success = setup(); await toLimited(success);
  for (let i = 7; i < stages.length; i++) {
    success.state.index = i; success.evidence.checkpoint(stages[i]); success.evidence.released(stages[i]);
  }
  success.evidence.passed(); await success.evidence.final(); success.evidence.seal(); success.evidence.finish(); await success.evidence.settle();
  assert.equal(success.state.requests, 3); assert.equal(success.state.timers.size, 0);
  console.log('NATIVE_RATE_SNAPSHOT_LEDGER_SUCCESS_PASS');

  for (const mode of ['late-baseline', 'bad-counter']) {
    const test = setup(mode); await assert.rejects(/** Baseline trước SDK phải bounded và counters/schema đúng. */ () => test.evidence.baseline());
    test.evidence.seal(); await test.evidence.settle();
  }
  for (const mode of ['changed-mid', 'observer-error', 'active-final']) {
    const test = setup(mode); await toLimited(test);
    if (mode !== 'active-final') assert.throws(/** Mid lỗi không được admit correct hoặc đọc proof cũ. */ () => test.evidence.assertActive());
    else {
      for (let i = 7; i < stages.length; i++) { test.state.index = i; test.evidence.checkpoint(stages[i]); }
      test.evidence.passed(); await assert.rejects(/** Final session phải revoked sau logout ACK, không chỉ UUID mới. */ () => test.evidence.final());
    }
    test.evidence.seal(); await test.evidence.settle();
  }
  const late = setup(); await late.evidence.baseline(); late.evidence.phaseStarted(0);
  for (let i = 0; i < 6; i++) { late.state.index = i; late.evidence.checkpoint(stages[i]); }
  late.state.clock = 180_001; late.state.index = 6;
  assert.throws(/** Whole work vẫn dư nhưng phase1260 không còn1080s bắt buộc; không ACK429. */
    () => late.evidence.checkpoint(stages[6]), { message: 'NATIVE_RATE_PHASE_INFEASIBLE' });
  late.evidence.seal(); await late.evidence.settle();
  console.log('NATIVE_RATE_SNAPSHOT_SESSION_FEASIBILITY_NEGATIVES_PASS');

  const reserve = setup(); await reserve.evidence.baseline(); reserve.state.clock = 900_000;
  assert.throws(/** Phase remaining cộng2snapshot+tail/PID/stop phải còn đủ work, không chỉ check work>0. */
    () => reserve.evidence.phaseStarted(reserve.state.clock));
  reserve.evidence.seal(); await reserve.evidence.settle();
  const beforeWrite = setup(); const baseline = beforeWrite.evidence.baseline();
  beforeWrite.state.clock = 130_000;
  await assert.rejects(/** Deadline neo trước microtask: hết130s trước write thì SQL không được bắt đầu. */ () => baseline);
  assert.equal(beforeWrite.state.requests, 0); beforeWrite.evidence.seal(); await beforeWrite.evidence.settle();
  const mutated = setup(); await mutated.evidence.baseline(); mutated.state.rows[0].revoked = true;
  mutated.evidence.phaseStarted(0);
  for (let i = 0; i <= 6; i++) {
    mutated.state.index = i; mutated.evidence.checkpoint(stages[i]); mutated.evidence.released(stages[i]);
  }
  await turns();
  assert.throws(/** Baseline phải là map đã copy, response object bị sửa không được thay evidence gốc. */ () => mutated.evidence.assertActive());
  mutated.evidence.seal(); await mutated.evidence.settle();
  console.log('NATIVE_RATE_SNAPSHOT_DYNAMIC_RESERVE_BEFORE_WRITE_PASS');

  const pending = setup('pending'); await toLimited(pending);
  pending.state.index = 8;
  assert.throws(/** Không cho correct khi mid SQL chưa có receipt validated. */ () => pending.evidence.checkpoint(stages[8]));
  pending.state.clock = 130_000;
  for (const timer of [...pending.state.timers]) timer.callback();
  assert.equal(pending.evidence.signal.aborted, true);
  let settled = false;
  const ownership = pending.evidence.settle().then(/** Chỉ raw observer settle mới kết thúc capsule ownership. */ () => { settled = true; });
  await turns(); assert.equal(settled, false);
  pending.evidence.seal(); pending.release.resolve([seed]); await ownership;
  assert.throws(/** Late rows sau seal không được giảm outstanding hoặc tạo PASS. */ () => pending.evidence.finish());
  assert.equal(pending.state.requests, 2);
  console.log('NATIVE_RATE_SNAPSHOT_PENDING_FENCE_PASS');
  const advancing = setup('advancing-clock'); await advancing.evidence.baseline();
  advancing.evidence.phaseStarted(advancing.state.clock);
  advancing.evidence.seal(); await advancing.evidence.settle();
  const sealed = setup('pending-final'); await toLimited(sealed);
  for (let i = 7; i < stages.length; i++) { sealed.state.index = i; sealed.evidence.checkpoint(stages[i]); }
  sealed.evidence.passed();
  let finalRejected = false;
  const finalObserver = sealed.evidence.final().then(
    /** Không completion nào được phép từ pending raw sau seal. */ () => { assert.fail('UNEXPECTED_FINAL_SUCCESS'); },
    /** Bounded observer phải reject ngay, raw I/O vẫn do settle giữ. */ () => { finalRejected = true; });
  await turns(); sealed.evidence.seal(); await turns();
  assert.equal(finalRejected, true);
  sealed.release.resolve([seed, app]); await sealed.evidence.settle(); await finalObserver;
  console.log('NATIVE_RATE_ADVANCING_CLOCK_SEAL_WAKE_PASS');
  const unavailable = new AbortController();
  const external = setup('pending-baseline', { externalSignal: unavailable.signal });
  let rejected = false;
  const externalBaseline = external.evidence.baseline().catch(() => { rejected = true; });
  await turns(); assert.equal(external.state.requests, 1);
  unavailable.abort(); await turns();
  assert.equal(external.evidence.signal.aborted, true); assert.equal(rejected, true);
  let rawSettled = false;
  const rawOwnership = external.evidence.settle().then(() => { rawSettled = true; });
  await turns(); assert.equal(rawSettled, false);
  external.evidence.seal(); external.release.resolve([seed]);
  await rawOwnership; await externalBaseline; assert.throws(() => external.evidence.finish());
  const already = setup('success', { externalSignal: unavailable.signal });
  await assert.rejects(() => already.evidence.baseline()); assert.equal(already.state.requests, 0);
  already.evidence.seal(); await already.evidence.settle();
  const expired = setup('success', { assertExternalActive: () => { throw new Error('PRIVATE_CERTIFICATE_SENTINEL'); } });
  await assert.rejects(() => expired.evidence.baseline()); assert.equal(expired.state.requests, 0);
  expired.evidence.seal(); await expired.evidence.settle();
  console.log('NATIVE_RATE_EXTERNAL_ABORT_RAW_OWNERSHIP_PASS');
}

try { await main(); } catch {
  // Chỉ enum kết quả; không in snapshot row, error SQL hoặc credential.
  console.error('NATIVE_RATE_EVIDENCE_TEST_FAILED'); process.exitCode = 1;
}
