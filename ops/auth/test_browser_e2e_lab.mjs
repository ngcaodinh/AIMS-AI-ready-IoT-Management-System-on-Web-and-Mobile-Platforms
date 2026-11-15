import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { generateKeyPairSync } from 'node:crypto';
import { runBrowserLab, createBrowserLabControl } from './run_browser_e2e_lab.mjs';
import { decryptBrowserFixture } from './browser_fixture_handoff.mjs';

/** Cho lifecycle giả chạy qua microtask, không sleep hoặc làm DB/SDK I/O. */
async function turns() { for (let index = 0; index < 12; index++) await Promise.resolve(); }

/**
 * Cấp boundary fixture/clock/timer giả để kiểm coordinator thật không tạo dữ liệu lab.
 * Input
 * Param: mode — success, delayed cleanup hoặc failure trước/sau READY.
 * Output: state/capabilities và release handles do test sở hữu.
 */
function setup(mode) {
  const controller = new AbortController();
  const state = { clock: 0, creates: 0, closes: 0, frames: [], timers: new Set() };
  let releaseReady; let releaseClose;
  const waitingReady = new Promise(/** Giữ READY pending cho kiểm STOP trước handoff. */
    (resolve) => { releaseReady = resolve; });
  const waitingClose = new Promise(/** Không dùng intent STOP thay terminal của owned fixture. */
    (resolve) => { releaseClose = resolve; });
  const runId = 'aaaaaaaa-1111-4111-8111-111111111111';
  const ready = { runId, emails: Array.from({ length: 5 }, /** Tạo email synthetic tại index0–4. */
    (_, index) => `probe-${runId}-${index}@example.invalid`) };
  const fixture = {
    ready: /** Trả READY hoặc giữ pending, không giả child terminal. */
      async () => { if (mode === 'early-stop') return waitingReady; if (mode === 'late-ready') state.clock = 1_200_000; return ready; },
    close: /** Đóng fake fixture đúng1lần, có thể chờ raw terminal hoặc lỗi cleanup. */
      async () => {
        state.closes++;
        if (mode === 'early-stop') releaseReady(ready);
        if (mode === 'pending-close') await waitingClose;
        if (mode === 'cleanup-error') throw new Error('PRIVATE_CLEANUP_SENTINEL');
      },
  };
  const runtime = {
    createFixture: /** Chỉ ghi credential trong RAM test, không xuất nó ra report. */
      (password) => { state.creates++; state.password = password; return fixture; },
    now: /** Clock monotonic do test kiểm soát, không đổi clock của sản phẩm. */ () => state.clock,
    setTimeout: /** Giữ watchdog giả để test chủ động kích hoạt. */
      (callback) => { state.timers.add(callback); return callback; },
    clearTimeout: /** Xóa đúng watchdog của coordinator. */ (callback) => { state.timers.delete(callback); },
    writeFrame: /** Frame handoff chỉ ciphertext/public metadata, cleanup chỉ fixed kind. */
      (frame) => { if (mode === 'output-error') throw new Error('PRIVATE_OUTPUT_SENTINEL'); state.frames.push(frame); },
  };
  return { controller, state, runtime, releaseReady, releaseClose };
}

/** Kiểm privacy, STOP/EOF/deadline và raw cleanup ownership qua coordinator thật. */
async function main() {
  const keyPair = generateKeyPairSync('rsa', { modulusLength: 2048 });
  const publicKey = keyPair.publicKey.export({ format: 'der', type: 'spki' }).toString('base64');
  for (const mode of ['success', 'pending-close', 'early-stop', 'late-ready', 'output-error', 'cleanup-error', 'expired', 'eof']) {
    const test = setup(mode); let settled = false;
    const operation = runBrowserLab(publicKey, test.controller.signal, test.runtime);
    operation.then(/** Theo dõi true completion của coordinator. */ () => { settled = true; },
      /** Rejection vẫn là terminal của helper, không có nghĩa cleanup thành công. */ () => { settled = true; });
    await turns();
    if (!['early-stop', 'late-ready', 'output-error'].includes(mode)) {
      const frame = test.state.frames[0];
      assert.equal(frame.kind, 'BROWSER_LAB_READY'); assert.ok(frame.remainingMilliseconds > 0);
      assert.equal(decryptBrowserFixture(frame.ciphertext, keyPair.privateKey).password, test.state.password);
      assert.ok(!JSON.stringify(frame).includes(test.state.password));
    }
    if (mode === 'expired') { test.state.clock = 1_200_000; for (const timer of [...test.state.timers]) timer(); }
    else test.controller.abort(mode === 'eof' ? 'EOF' : 'STOP');
    await turns();
    if (mode === 'pending-close') {
      assert.equal(test.state.closes, 1); assert.equal(settled, false);
      assert.ok(!test.state.frames.some(/** Chưa raw terminal thì chưa có cleanup marker. */
        (frame) => frame.kind === 'BROWSER_LAB_OWNED_CLEANUP_PASS'));
      test.releaseClose();
    }
    if (['success', 'pending-close'].includes(mode)) await operation;
    else await assert.rejects(/** Mọi boundary failure giữ fixed error sau khi thử original cleanup. */
      () => operation, { message: 'BROWSER_LAB_FAILED' });
    assert.equal(test.state.closes, 1); assert.equal(test.state.timers.size, 0);
    if (['early-stop', 'late-ready'].includes(mode)) assert.ok(!test.state.frames.some(
      /** Không phát credential sau STOP hoặc budget đã hết. */ (frame) => frame.kind === 'BROWSER_LAB_READY'));
    if (mode === 'cleanup-error') assert.ok(!test.state.frames.some(
      /** Cleanup failure không phát receipt thành công. */ (frame) => frame.kind === 'BROWSER_LAB_OWNED_CLEANUP_PASS'));
  }
  const cancelled = setup('success'); cancelled.controller.abort('STOP');
  await assert.rejects(/** Already aborted không được spawn fixture. */
    () => runBrowserLab(publicKey, cancelled.controller.signal, cancelled.runtime));
  assert.equal(cancelled.state.creates, 0);
  const raced = setup('success');
  raced.runtime.now = /** Abort giữa precheck và listener registration vẫn phải được nhận trước spawn. */
    () => { raced.controller.abort('STOP'); return 0; };
  const racedOperation = runBrowserLab(publicKey, raced.controller.signal, raced.runtime);
  racedOperation.catch(/** Giữ rejection observer ngay trong ca race, không xuất exception. */ () => {});
  try {
    await turns(); assert.equal(raced.state.creates, 0);
    await assert.rejects(/** Missed abort không được publish credential hoặc để helper chờ vô hạn. */ () => racedOperation);
  } finally {
    for (const timer of [...raced.state.timers]) timer();
    await racedOperation.catch(/** Release raw helper Promise trước ca kế tiếp. */ () => {});
  }
  const invalid = setup('success');
  await assert.rejects(/** Recipient sai bị chặn trước DB I/O. */
    () => runBrowserLab('invalid', invalid.controller.signal, invalid.runtime));
  assert.equal(invalid.state.creates, 0);

  for (const inputCase of ['split-stop', 'eof', 'invalid', 'output-error']) {
    const input = new EventEmitter(); const output = new EventEmitter();
    input.setEncoding = /** Fake stream không đọc OS handle. */ () => {};
    input.pause = /** Ghi nhận control input được dừng sau command/cleanup. */ () => { input.paused = true; };
    const control = createBrowserLabControl(input, output);
    if (inputCase === 'split-stop') { input.emit('data', 'ST'); assert.equal(control.signal.aborted, false); input.emit('data', 'OP\n'); }
    if (inputCase === 'eof') input.emit('end');
    if (inputCase === 'invalid') input.emit('data', 'X'.repeat(65));
    if (inputCase === 'output-error') output.emit('error', new Error('PRIVATE_PIPE_SENTINEL'));
    assert.equal(control.signal.aborted, true);
    assert.equal(control.signal.reason, inputCase === 'split-stop' ? 'STOP' : 'UNAVAILABLE');
    control.closeInput(); assert.equal(input.paused, true);
  }
  await outputFailureDuringCleanup(publicKey);
  await pendingHandoffOwnership(publicKey);
  await originalFactoryIntegration(publicKey);
  console.log('BROWSER_LAB_PRIVATE_HANDOFF_STOP_DEADLINE_OWNERSHIP_PASS');
}

/**
 * STOP không được che stdout failure tới sau trong khi cleanup vẫn pending.
 * Input
 * Param: publicKey — SPKI synthetic để helper tạo frame không có plaintext.
 */
async function outputFailureDuringCleanup(publicKey) {
  const test = setup('pending-close'); const input = new EventEmitter(); const output = new EventEmitter();
  input.setEncoding = /** Fake input không có OS handle. */ () => {};
  input.pause = /** Dừng fake input không tác động process khác. */ () => {};
  const control = createBrowserLabControl(input, output); let settled = false;
  const operation = runBrowserLab(publicKey, control.signal, { ...test.runtime, assertControlAvailable: control.assertAvailable });
  operation.then(/** Theo dõi return để bắt fake completion trước cleanup terminal. */ () => { settled = true; },
    /** Failure vẫn phải giữ raw cleanup tới terminal. */ () => { settled = true; });
  await turns(); control.stop(); await turns();
  output.emit('error', new Error('PRIVATE_OUTPUT_AFTER_STOP'));
  assert.equal(settled, false); assert.equal(test.state.closes, 1);
  test.releaseClose();
  try {
    await assert.rejects(/** Output failure phải giữ overall failure dù first abort reason là STOP. */
      () => operation, { message: 'BROWSER_LAB_FAILED' });
    assert.ok(!test.state.frames.some(/** Không phát success receipt trên channel đã unavailable. */
      (frame) => frame.kind === 'BROWSER_LAB_OWNED_CLEANUP_PASS'));
  } finally { control.closeInput(); }
}

/**
 * STOP bắt đầu fixture cleanup ngay, nhưng pending output vẫn giữ ownership tới callback settle.
 * Input
 * Param: publicKey — public SPKI của test, không có private key trong helper.
 */
async function pendingHandoffOwnership(publicKey) {
  const test = setup('success'); let releaseWrite; let settled = false;
  const writing = new Promise(/** Giữ owned write pending như pipe chưa trả callback. */
    (resolve) => { releaseWrite = resolve; });
  test.runtime.writeFrame = /** Chỉ READY write bị giữ, cleanup write hoàn tất đồng bộ. */
    (frame) => { test.state.frames.push(frame); return frame.kind === 'BROWSER_LAB_READY' ? writing : undefined; };
  const operation = runBrowserLab(publicKey, test.controller.signal, test.runtime);
  operation.then(/** Return trước write callback là lỗi ownership. */ () => { settled = true; },
    /** Ghi rejection để không tạo unhandled Promise trong ca negative. */ () => { settled = true; });
  await turns(); test.controller.abort('STOP'); await turns();
  try {
    assert.equal(test.state.closes, 1); assert.equal(settled, false);
    assert.ok(!test.state.frames.some(/** Chưa được phát cleanup success khi handoff write còn pending. */
      (frame) => frame.kind === 'BROWSER_LAB_OWNED_CLEANUP_PASS'));
  } finally { releaseWrite(); }
  await operation;
}

/**
 * Dùng original fixture factory thật, chỉ thay OS child để kiểm observer exit và STOPPED protocol.
 * Input
 * Param: publicKey — SPKI của keypair synthetic đã tạo trong main, không có private material.
 */
async function originalFactoryIntegration(publicKey) {
  const runId = 'aaaaaaaa-1111-4111-8111-111111111111';
  for (const earlyExit of [false, true]) {
    const controller = new AbortController(); const frames = []; const child = new EventEmitter(); child.pid = 4245;
    child.stdin = new EventEmitter(); child.stdout = new EventEmitter(); child.stderr = new EventEmitter();
    child.stdin.write = /** Trả original READY qua byte protocol, không output credential nhận được. */
      (value) => {
        assert.match(JSON.parse(value).password, /^Aa1[0-9a-f]{32}$/);
        child.stdout.emit('data', Buffer.from(JSON.stringify({ kind: 'READY', runId, userIds: [],
          emails: Array.from({ length: 5 }, /** Email tại index0–4 thuộc cùng fixture. */
            (_, index) => `probe-${runId}-${index}@example.invalid`) }) + '\n'));
      };
    child.stdin.end = /** Normal STOP trả exact8zero và actual child exit event của boundary giả. */
      (value) => {
        assert.equal(value, 'STOP\n');
        const cleanup = Object.fromEntries(['role', 'hba', 'users', 'sessions', 'workspaces', 'memberships', 'auditActor', 'limiterBuckets'].map(
          /** Mỗi cleanup scope fake có đúng count nguyên0. */ (key) => [key, 0]));
        child.stdout.emit('data', Buffer.from(JSON.stringify({ kind: 'STOPPED', cleanup }) + '\n'));
        child.emit('exit', 0);
      };
    for (const stream of [child.stdin, child.stdout, child.stderr]) stream.destroy = /** Không đóng OS resource trong host test. */ () => {};
    const operation = runBrowserLab(publicKey, controller.signal, {
      spawnFixtureProcess: /** Original factory nhận đúng child giả, không spawn Python hoặc DB. */ () => child,
      writeFrame: /** Exit1 sau handoff phải phát unavailable và không được cleanup PASS. */
        (frame) => {
          frames.push(frame);
          if (frame.kind === 'BROWSER_LAB_READY') {
            if (earlyExit) child.emit('exit', 1);
            else controller.abort('STOP');
          }
        },
    });
    if (earlyExit) await assert.rejects(/** Child chết sớm luôn giữ helper failure. */
      () => operation, { message: 'BROWSER_LAB_FAILED' });
    else await operation;
    assert.equal(frames.some(/** Scope marker chỉ có sau original8zero/exit0. */
      (frame) => frame.kind === 'BROWSER_LAB_OWNED_CLEANUP_PASS'), !earlyExit);
    if (earlyExit) assert.ok(frames.some(/** Root nhận public unavailable trước khi có thể làm browser intent mới. */
      (frame) => frame.kind === 'BROWSER_LAB_UNAVAILABLE'));
  }
}

try { await main(); } catch (error) {
  // Chỉ vị trí test, không đưa credential, key hoặc callback error vào stdout.
  const line = /test_browser_e2e_lab\.mjs:(\d+)/.exec(error.stack)?.[1] ?? 'UNKNOWN';
  console.error(`BROWSER_LAB_TEST_FAILED line=${line}`); process.exitCode = 1;
}
