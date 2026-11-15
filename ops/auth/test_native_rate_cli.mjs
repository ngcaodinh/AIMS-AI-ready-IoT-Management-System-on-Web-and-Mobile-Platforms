import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { runNativeRateCli } from './run_native_rate_e2e.mjs';

/** Kiểm entry dùng orchestrator sẵn có, chờ terminal và không nhận cấu hình qua CLI. */
async function main() {
  let calls = 0; let release; let settled = false;
  const terminal = new Promise(
    /** Test giữ terminal pending, không giả cleanup hoàn tất khi scenario mới được gọi. */
    (resolve) => { release = resolve; });
  const operation = runNativeRateCli([], /** Scenario host giả, không DB/SDK/proxy I/O. */
    () => { calls++; return terminal; });
  operation.then(/** Chỉ ghi settled khi entry thật sự trả về. */ () => { settled = true; });
  await Promise.resolve();
  assert.equal(calls, 1); assert.equal(settled, false);
  release(8123); assert.equal(await operation, 8123);

  await assert.rejects(/** Lỗi orchestration phải giữ failure, không trả thành công cho caller. */
    () => runNativeRateCli([], /** Failure fake không chứa credential thật. */
      async () => { throw new Error('PUBLIC_SCENARIO_FAILURE'); }), { message: 'PUBLIC_SCENARIO_FAILURE' });
  await assert.rejects(/** Synchronous factory throw cũng không được biến thành success. */
    () => runNativeRateCli([], /** Chỉ mô phỏng factory trước khi có owned resource. */
      () => { throw new Error('PUBLIC_FACTORY_FAILURE'); }), { message: 'PUBLIC_FACTORY_FAILURE' });

  for (const arguments_ of [undefined, null, {}, ['--rate-limit'], ['--full-session'], ['--timeout=1'],
    ['https://example.invalid'], ['--password=PUBLIC_ARGUMENT_SENTINEL'], ['']]) {
    await assert.rejects(/** Không gọi scenario khi shape hoặc argument khác empty argv. */
      () => runNativeRateCli(arguments_, /** Assertion này bắt factory bị gọi trước validation. */
        () => assert.fail('UNEXPECTED_SCENARIO')));
  }

  const executable = fileURLToPath(new URL('./run_native_rate_e2e.mjs', import.meta.url));
  for (const argument of ['--rate-limit', '--timeout=1', '--password=PUBLIC_ARGUMENT_SENTINEL']) {
    // Chỉ chạy child CLI với input sai, entry phải từ chối trước khi tạo fixture hoặc SDK.
    const child = spawnSync(process.execPath, [executable, argument],
      { encoding: 'utf8', timeout: 5000, windowsHide: true, maxBuffer: 4096 });
    assert.ok(!child.error && !child.signal);
    assert.equal(child.status, 1);
    assert.equal(child.stdout, '');
    assert.equal(child.stderr.trim(), 'NATIVE_RATE_E2E_FAILED');
    assert.ok(!child.stderr.includes('PUBLIC_ARGUMENT_SENTINEL'));
  }
  console.log('NATIVE_RATE_CLI_ARGUMENT_TERMINAL_REDACTION_PASS');
}

try { await main(); } catch (error) {
  // Chỉ xuất vị trí test, không phản chiếu argv/scenario error hoặc captured process output.
  const line = /test_native_rate_cli\.mjs:(\d+)/.exec(error.stack)?.[1] ?? 'UNKNOWN';
  console.error(`NATIVE_RATE_CLI_TEST_FAILED line=${line}`); process.exitCode = 1;
}
