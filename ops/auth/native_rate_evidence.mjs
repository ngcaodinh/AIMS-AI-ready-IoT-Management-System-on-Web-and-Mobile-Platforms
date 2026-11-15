import assert from 'node:assert/strict';

const stages = ['rate-before', 'rate-wrong-1', 'rate-wrong-2', 'rate-wrong-3', 'rate-wrong-4',
  'rate-wrong-5', 'rate-limited', 'rate-mid-cooldown', 'rate-expired', 'rate-login', 'rate-logout'];
const counterKeys = ['AUTH_LOGIN', 'AUTH_LOGOUT', 'PROFILE_READ', 'WORKSPACE_LIST', 'PASSWORD_CHANGE', 'OTHER'];

/** Chuẩn hóa tối đa16 UUID/revoked public; không nhận token hoặc ép kiểu dữ liệu snapshot. */
export function nativeSessionMap(rows) {
  assert.ok(Array.isArray(rows) && rows.length <= 16, 'SESSION_SNAPSHOT_INVALID');
  const result = new Map();
  for (const row of rows) {
    assert.ok(row && Object.keys(row).length === 2 && typeof row.revoked === 'boolean' &&
      typeof row.sessionId === 'string' && /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/.test(row.sessionId) &&
      !result.has(row.sessionId), 'SESSION_SNAPSHOT_INVALID');
    result.set(row.sessionId, row.revoked);
  }
  return result;
}

/**
 * Sở hữu các observer snapshot của một rate phase; SQL terminal vẫn thuộc fixture.close, không thuộc Promise timeout.
 * Input: fixture.snapshot/close là capability owned; readCounts chỉ đọc6enum; now/timers chỉ thay trong host tests.
 * Output: capsule không có credential, signal đánh thức SDK RPC khi proof thất bại; settle giữ raw I/O ownership.
 * Side effects: đúng3snapshot full theo thứ tự; không phát STOP ở đây vì wrapper phải dừng SDK trước.
 */
export function createNativeRateEvidence({ fixture, readCounts, workDeadline, externalSignal, assertExternalActive,
  now = performance.now.bind(performance),
  timers = { setTimeout, clearTimeout } }) {
  assert.ok(fixture && typeof fixture.snapshot === 'function' && typeof readCounts === 'function' &&
    Number.isFinite(workDeadline), 'NATIVE_RATE_EVIDENCE_INVALID');
  const controller = new AbortController();
  let resolveFailure;
  const failed = new Promise(/** Failure notification không reject ngoài observer đang sở hữu nó. */
    (resolve) => { resolveFailure = resolve; });
  let failure = false; let sealed = false; let position = 0; let phaseDeadline; let frameworkPassed = false;
  let initial; let outstanding = 3;
  const receipts = new Map();

  /** Đóng vĩnh viễn mọi work fence và báo pending RPC ngay; không giả SQL đã dừng. */
  function fail() {
    if (!failure) { failure = true; controller.abort(); resolveFailure(); }
    for (const receipt of receipts.values()) timers.clearTimeout(receipt.timer);
  }
  externalSignal?.addEventListener('abort', fail);
  if (externalSignal?.aborted) fail();

  /** Kiểm clock/deadline ngay cả khi event loop chưa chạy timeout callback. */
  function assertActive() {
    try { assertExternalActive?.(); } catch {
      fail(); throw new Error('NATIVE_RATE_EVIDENCE_UNAVAILABLE');
    }
    const current = now();
    if (!Number.isFinite(current) || current >= workDeadline || sealed || failure ||
      [...receipts.values()].some(/** Receipt chưa hoàn tất không được mở lại130s từ lúc poll. */
        (receipt) => !receipt.valid && current >= receipt.deadline)) {
      fail(); throw new Error('NATIVE_RATE_EVIDENCE_UNAVAILABLE');
    }
    // Tail125s gồm status15s, ba PID queries15s và SDK cleanup95s; không mở rộng work window.
    if (phaseDeadline !== undefined && !frameworkPassed) {
      if (current >= phaseDeadline || workDeadline - current < phaseDeadline - current + outstanding * 130_000 + 125_000) {
        fail(); throw new Error('NATIVE_RATE_EVIDENCE_UNAVAILABLE');
      }
    } else if (frameworkPassed && workDeadline - current < outstanding * 130_000 + 125_000) {
      fail(); throw new Error('NATIVE_RATE_EVIDENCE_UNAVAILABLE');
    }
  }

  /** Kiểm sáu counters ở từng boundary; OTHER không được bù route hoặc request thiếu. */
  function checkCounts(index) {
    const counts = readCounts();
    assert.ok(counts && Object.keys(counts).length === 6 && counterKeys.every(
      /** Chỉ nonnegative safe integer; boolean hoặc tên thay thế không phải counter ACK. */
      (key) => Object.hasOwn(counts, key) && Number.isSafeInteger(counts[key]) && counts[key] >= 0), 'NATIVE_RATE_COUNTER_INVALID');
    const login = index <= 6 ? index : index <= 8 ? 6 : 7;
    assert.ok(counts.AUTH_LOGIN === login && counts.AUTH_LOGOUT === (index === 10 ? 1 : 0) &&
      counts.WORKSPACE_LIST === (index >= 9 ? 1 : 0) && counts.PASSWORD_CHANGE === 0 && counts.OTHER === 0 &&
      (index >= 9 ? counts.PROFILE_READ > 0 : counts.PROFILE_READ === 0), 'NATIVE_RATE_COUNTER_INVALID');
  }

  /** Chốt map độc lập với object trả về, không cho caller mutate baseline sau validation. */
  function validateRows(kind, rows) {
    const result = nativeSessionMap(rows);
    if (kind === 'baseline') { initial = result; return; }
    for (const [id, revoked] of initial) assert.equal(result.get(id), revoked, 'NATIVE_RATE_SESSION_INVALID');
    if (kind === 'mid') assert.equal(result.size, initial.size, 'NATIVE_RATE_SESSION_INVALID');
    else {
      assert.equal(result.size, initial.size + 1, 'NATIVE_RATE_SESSION_INVALID');
      const added = [...result.keys()].filter(/** Chỉ UUID được thêm bởi login đúng của App. */ (id) => !initial.has(id));
      assert.equal(added.length, 1, 'NATIVE_RATE_SESSION_INVALID');
      assert.equal(result.get(added[0]), true, 'NATIVE_RATE_SESSION_INVALID');
    }
  }

  /**
   * Chốt130s trước write, attach raw handlers ngay; observer failure không cấp snapshot khác hoặc giảm outstanding.
   * Input: kind chỉ baseline/mid/final do capsule quyết định; giữ SDK stop95s và hai post-PID queries10s.
   */
  function startSnapshot(kind) {
    assertActive();
    assert.ok(!receipts.has(kind), 'NATIVE_RATE_SNAPSHOT_ORDER_INVALID');
    const receipt = { valid: false, deadline: Math.min(now() + 130_000, workDeadline - 105_000) };
    assert.ok(receipt.deadline > now(), 'NATIVE_RATE_EVIDENCE_UNAVAILABLE');
    receipts.set(kind, receipt);
    receipt.timer = timers.setTimeout(fail, receipt.deadline - now());
    receipt.operation = Promise.resolve().then(
      /** Fence trước request thực; timeout trước microtask không được phát SQL mới. */
      () => { assertActive(); return fixture.snapshot('full'); }).then(
      /** Validate chỉ khi đúng deadline/fence; late rows không được đổi baseline hoặc outstanding. */
      (rows) => {
        if (failure || sealed) return;
        try {
          assertActive(); validateRows(kind, rows); assertActive();
          receipt.valid = true; outstanding--; timers.clearTimeout(receipt.timer);
          assertActive();
        } catch { fail(); }
      },
      /** Chỉ fixed failure, không giữ SQL/error/rows; raw observer rejection đã có handler ngay. */
      () => { fail(); });
    // Promise này bounded; receipt.operation riêng vẫn phải đợi sau owned fixture terminal khi observer timeout.
    receipt.observed = Promise.race([receipt.operation, failed]).then(
      /** Completion cũ hoặc failure notification không được xem là receipt hợp lệ. */
      () => { assertActive(); assert.ok(receipt.valid, 'NATIVE_RATE_EVIDENCE_UNAVAILABLE'); });
    // Mid không await ngay trong pause, vẫn cần handler để không unhandled khi proof thất bại.
    receipt.observed.catch(/** Failure đã đi qua controller; wrapper giữ cùng operation trong settle. */ () => {});
    return receipt.observed;
  }

  return Object.freeze({
    signal: controller.signal,
    assertActive,
    baseline:
      /** Host no-CA5s đã xong; giữ2195s trước baseline130s và reserve mới cho ba PID queries. */
      async () => {
        assertActive(); assert.ok(workDeadline - now() >= 2_195_000, 'NATIVE_WORK_BUDGET_INSUFFICIENT');
        checkCounts(0); await startSnapshot('baseline');
        assert.ok(workDeadline - now() >= 2_065_000, 'NATIVE_WORK_BUDGET_INSUFFICIENT');
      },
    phaseStarted:
      /** Deadline do actual runner neo trước valid fixture RPC, không nhận reset từ replay/status. */
      (anchor) => {
        assertActive(); assert.ok(receipts.get('baseline')?.valid && phaseDeadline === undefined &&
          Number.isFinite(anchor) && anchor <= now(), 'NATIVE_RATE_PHASE_INVALID');
        // Cùng anchor do runner lấy một lần; clock lần đọc sau được tiến nhưng không được kéo dài cap.
        phaseDeadline = anchor + 1_260_000; assertActive(); return phaseDeadline;
      },
    checkpoint:
      /** Pure sync boundary trong5s: không SQL, Promise hoặc I/O; admission correct cần mid proof hoàn tất. */
      (stage) => {
        assertActive(); assert.ok(phaseDeadline !== undefined && stages[position] === stage, 'NATIVE_RATE_CHECKPOINT_ORDER_INVALID');
        checkCounts(position);
        if (stage === 'rate-limited') assert.ok(phaseDeadline - now() >= 1_080_000, 'NATIVE_RATE_PHASE_INFEASIBLE');
        if (stage === 'rate-expired') assert.ok(receipts.get('mid')?.valid, 'NATIVE_RATE_MID_SNAPSHOT_REQUIRED');
        position++;
      },
    released:
      /** Chỉ runner gọi sau cả6ACK và finally đóng5s fence; snapshot chạy ngoài UI pause. */
      (stage) => {
        assertActive();
        if (stage === 'rate-limited') {
          assert.equal(position, 7, 'NATIVE_RATE_CHECKPOINT_ORDER_INVALID'); startSnapshot('mid');
        }
      },
    passed:
      /** Framework PASS đúng phase/11stage mới bỏ native reserve; timeout không được đặt phaseRemaining0. */
      () => {
        assertActive(); assert.equal(position, stages.length, 'NATIVE_RATE_CHECKPOINT_INCOMPLETE');
        assert.ok(receipts.get('mid')?.valid, 'NATIVE_RATE_MID_SNAPSHOT_REQUIRED'); checkCounts(10);
        frameworkPassed = true; assertActive();
      },
    final:
      /** Bounded final observer; raw Promise được giữ tới settle, tránh deadlock trong runner onPassed. */
      async () => {
        assertActive(); assert.ok(frameworkPassed && receipts.get('mid')?.valid, 'NATIVE_RATE_SNAPSHOT_ORDER_INVALID');
        await startSnapshot('final'); checkCounts(10); assertActive();
      },
    seal:
      /** Đóng trước SDK stop; finish sau terminal chỉ đọc proofs/counters, không cấp I/O mới. */
      () => {
        sealed = true; resolveFailure(); controller.abort();
        externalSignal?.removeEventListener('abort', fail);
        // Đánh thức bounded observer trước clear timer; raw Promise vẫn do settle/fixture terminal sở hữu.
        for (const receipt of receipts.values()) timers.clearTimeout(receipt.timer);
      },
    finish:
      /** Kiểm cuối sau SDK exit để bắt latePOST, không đòi lại reserve stop đã thực sự hoàn tất. */
      () => {
        try { assertExternalActive?.(); } catch { fail(); }
        assert.ok(!externalSignal?.aborted && !failure && sealed && frameworkPassed && outstanding === 0 && receipts.size === 3 &&
          Number.isFinite(now()) && now() < workDeadline, 'NATIVE_RATE_EVIDENCE_UNAVAILABLE'); checkCounts(10);
      },
    settle:
      /** Chỉ gọi sau fixture.close khi fail; await raw observers không đồng nghĩa SQL terminal nếu thiếu owned close. */
      () => Promise.all([...receipts.values()].map(/** Giữ mọi operation, không abandon mid khi final lỗi. */
        (receipt) => receipt.operation)),
  });
}
