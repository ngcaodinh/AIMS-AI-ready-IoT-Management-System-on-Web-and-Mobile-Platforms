import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import { pathToFileURL } from 'node:url';
import { startFixture } from './run_native_e2e.mjs';
import { parseBrowserRecipient, encryptBrowserFixture } from './browser_fixture_handoff.mjs';

/**
 * Ghi public frame và giữ write ownership tới callback, không xem callback là recipient đã giải mã.
 * Input
 * Param: frame — ciphertext hoặc public lifecycle metadata do helper dựng, không plaintext.
 * Output: Promise cho owned stdout write, lỗi chỉ có fixed enum.
 * Side effects
 * Ghi một public JSON frame vào stdout của CLI và đợi write callback.
 */
function writeBrowserLabFrame(frame) {
  return new Promise(/** Chờ stream callback thật, không bỏ pending write khi STOP đến. */
    (resolve, reject) => {
      process.stdout.write(JSON.stringify(frame) + '\n',
        /** Chỉ phản chiếu trạng thái write, không raw stream error hoặc frame. */
        (error) => { if (error) reject(new Error('BROWSER_LAB_OUTPUT_UNAVAILABLE')); else resolve(); });
    });
}

/**
 * Giữ original fixture cho browser test, chuyển credential bằng ciphertext và chờ original cleanup.
 * Input
 * Param: encodedRecipient — SPKI public Base64 từ controller, không nhận password hoặc URL.
 * Param: signal — STOP chủ động hoặc control/output unavailable, do owner cấp.
 * Param: runtime — trusted fixture/process/clock/timer/output boundaries và control availability latch.
 * Errors: fixed BROWSER_LAB_FAILED sau cleanup; recipient sai bị từ chối trước fixture.
 * Side effects
 * Spawn original fixture, phát public frame và giữ owned cleanup tới actual terminal.
 */
export async function runBrowserLab(encodedRecipient, signal, runtime = {}) {
  const recipient = parseBrowserRecipient(encodedRecipient);
  assert.ok(signal && typeof signal.addEventListener === 'function' && !signal.aborted, 'BROWSER_LAB_FAILED');
  const now = runtime.now ?? performance.now.bind(performance);
  const setTimer = runtime.setTimeout ?? setTimeout;
  const clearTimer = runtime.clearTimeout ?? clearTimeout;
  const writeFrame = runtime.writeFrame ?? writeBrowserLabFrame;
  // Neo trước spawn. Receipt READY muộn không mở thêm20phút so với watchdog của original shim.
  const deadline = now() + 1_200_000;
  let password = `Aa1${randomBytes(16).toString('hex')}`;
  let fixture; let closing; let unavailableWrite; let stopReason; let resolveStop; let admitted = false; let failed = false;
  const stopped = new Promise(/** Giữ stop intent riêng với actual fixture terminal. */
    (resolve) => { resolveStop = resolve; });

  /** Chốt close promise trước callback để STOP/exit/output failure không reenter hoặc đóng hai lần. */
  function beginClose() {
    if (fixture && !closing) {
      closing = Promise.resolve().then(/** Chỉ original factory sở hữu STOP/8zero/shim exit proof. */ () => fixture.close());
      closing.catch(/** Giữ rejection handler ngay, finally vẫn await original promise và đánh failure. */ () => {});
    }
  }

  /**
   * Dừng admission ngay và bắt đầu cleanup dù phase còn chờ READY.
   * Input
   * Param: reason — enum STOP hoặc UNAVAILABLE, không giữ raw control/process error.
   * Side effects
   * Chốt stop intent, bắt đầu original cleanup và public unavailable write nếu cần.
   */
  function requestStop(reason) {
    if (stopReason) return;
    stopReason = reason; beginClose(); resolveStop();
    if (admitted && reason !== 'STOP') {
      admitted = false;
      unavailableWrite = Promise.resolve().then(/** Public failure write có raw ownership riêng với fixture cleanup. */
        () => writeFrame({ kind: 'BROWSER_LAB_UNAVAILABLE' }));
      unavailableWrite.catch(/** Giữ rejection handler ngay, finally vẫn chờ write thật. */ () => { failed = true; });
    }
  }

  /** Giữ deadline monotonic authoritative trước và sau mỗi await của handoff. */
  function assertActive() {
    runtime.assertControlAvailable?.();
    assert.ok(!stopReason && Number.isFinite(now()) && now() < deadline, 'BROWSER_LAB_FAILED');
  }

  /**
   * Quan sát terminal của đúng shim child mà original factory spawn, không enumerate/kill process.
   * Input
   * Param: command — executable Python được original factory chốt.
   * Param: arguments_ — argv không chứa credential, giữ nguyên từ original factory.
   * Param: options — private stdio và child process options của factory.
   * Output: chính owned child cho original fixture tiếp tục quản lý protocol/cleanup.
   */
  function spawnOwnedFixture(command, arguments_, options) {
    const child = (runtime.spawnFixtureProcess ?? spawn)(command, arguments_, options);
    child.once('exit', /** Fixture chết sớm khóa browser admission; STOP đã chốt vẫn giữ reason gốc. */
      () => requestStop('UNAVAILABLE'));
    child.once('error', /** Spawn/child error không được giữ một READY đã cũ. */
      () => requestStop('UNAVAILABLE'));
    return child;
  }

  const onStop = /** Chỉ STOP chủ động là normal completion của helper, EOF/error giữ unavailable. */
    () => requestStop(signal.reason === 'STOP' ? 'STOP' : 'UNAVAILABLE');
  signal.addEventListener('abort', onStop, { once: true });
  if (signal.aborted) onStop();
  const timer = setTimer(/** Deadline là fail closed, không phải fixture terminal hoặc E2E success. */
    () => requestStop('UNAVAILABLE'), 1_200_000);
  try {
    assertActive();
    const createFixture = runtime.createFixture ?? /** Reuse default20m profile, grants/schema/cleanup không đổi. */
      ((value) => startFixture(value, 'default', [value], spawnOwnedFixture));
    fixture = createFixture(password);
    if (stopReason) beginClose();
    const ready = await fixture.ready(); assertActive();
    const ciphertext = encryptBrowserFixture(ready, password, recipient);
    const remainingMilliseconds = Math.floor(deadline - now()); assertActive();
    admitted = true;
    await writeFrame({ kind: 'BROWSER_LAB_READY', ciphertext, remainingMilliseconds,
      expiresAtUtc: new Date(Date.now() + remainingMilliseconds).toISOString() });
    runtime.assertControlAvailable?.();
    await stopped;
    runtime.assertControlAvailable?.();
    assert.ok(stopReason === 'STOP' && Number.isFinite(now()) && now() < deadline, 'BROWSER_LAB_FAILED');
  } catch { failed = true; }
  finally {
    admitted = false; clearTimer(timer); signal.removeEventListener('abort', onStop); beginClose();
    let cleanupSucceeded = false;
    try { if (closing) { await closing; cleanupSucceeded = true; } } catch { failed = true; }
    password = '';
    try {
      if (unavailableWrite) await unavailableWrite;
      if (cleanupSucceeded) {
        runtime.assertControlAvailable?.();
        await writeFrame({ kind: 'BROWSER_LAB_OWNED_CLEANUP_PASS' });
        runtime.assertControlAvailable?.();
      }
    } catch { failed = true; }
  }
  assert.ok(!failed, 'BROWSER_LAB_FAILED');
}

/**
 * Nhận duy nhất literal STOP qua owned stdin và phát unavailable khi EOF/output pipe lỗi.
 * Input
 * Param: input — stdin của một CLI invocation, tối đa64ký tự control frame.
 * Param: output — stdout được dùng để chuyển ciphertext/public metadata.
 * Output: stop signal, unavailable latch độc lập, availability guard và closeInput sau cleanup.
 * Side effects
 * Gắn listener trên owned input/output, dừng đọc sau command và giữ error handlers tới CLI exit.
 */
export function createBrowserLabControl(input, output) {
  const controller = new AbortController(); const unavailableController = new AbortController(); let buffer = '';
  input.setEncoding('utf8');
  /** Đóng admission, không echo chunk hoặc stream error có thể chứa dữ liệu. */
  function unavailable() { unavailableController.abort(); controller.abort('UNAVAILABLE'); }
  /** EOF sau literal STOP là đóng input bình thường, các EOF khác giữ unavailable. */
  function onEnd() { if (controller.signal.reason !== 'STOP') unavailable(); }
  /**
   * Tích lũy split STOP frame, từ chối input quá dài hoặc command khác.
   * Input
   * Param: chunk — chuỗi từ owned stdin, không phải credential hoặc JSON configuration.
   */
  function onData(chunk) {
    buffer += chunk;
    if (buffer === 'STOP\n' || buffer === 'STOP\r\n') { controller.abort('STOP'); input.pause(); }
    else if (buffer.length > 64 || buffer.includes('\n')) { unavailable(); input.pause(); }
  }
  input.on('data', onData); input.on('end', onEnd); input.on('error', unavailable);
  output.on('error', unavailable);
  return { signal: controller.signal,
    unavailableSignal: unavailableController.signal,
    assertAvailable: /** Failure latch không bị STOP one-shot che mất, kể cả trong pending cleanup. */
      () => { assert.ok(!unavailableController.signal.aborted, 'BROWSER_LAB_OUTPUT_UNAVAILABLE'); },
    stop: /** Signal CLI chủ động yêu cầu original cleanup, không gọi process.exit trước terminal. */
      () => { controller.abort('STOP'); },
    closeInput: /** Dừng owned reads. Error handlers sống tới CLI exit để late EPIPE không bỏ cleanup. */
      () => { input.off('data', onData); input.off('end', onEnd); input.pause(); buffer = ''; },
  };
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const control = createBrowserLabControl(process.stdin, process.stdout);
  control.unavailableSignal.addEventListener('abort', /** Late channel failure sau STOP vẫn giữ process exit1. */
    () => { process.exitCode = 1; }, { once: true });
  process.on('SIGINT', control.stop); process.on('SIGTERM', control.stop);
  process.stderr.on('error', /** Giữ handler tới CLI exit để late stderr EPIPE không thành unhandled error. */
    () => {});
  try {
    assert.equal(process.argv.length, 3, 'BROWSER_RECIPIENT_INVALID');
    await runBrowserLab(process.argv[2], control.signal, { assertControlAvailable: control.assertAvailable });
  } catch { console.error('BROWSER_LAB_FAILED'); process.exitCode = 1; }
  finally {
    process.off('SIGINT', control.stop); process.off('SIGTERM', control.stop); control.closeInput();
  }
}
