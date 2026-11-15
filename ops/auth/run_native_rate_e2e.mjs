import assert from 'node:assert/strict';
import { pathToFileURL } from 'node:url';
import { runActualRate } from './run_native_e2e.mjs';

/**
 * Chạy đúng rate scenario đã review và đợi orchestration terminal, không nhận cấu hình từ CLI.
 * Input
 * Param: arguments_ — argv sau tên script, bắt buộc mảng rỗng.
 * Param: runScenario — boundary trusted chỉ dành host test; CLI luôn dùng runActualRate hiện hữu.
 * Output: PID đã qua native/session/counter và owned cleanup proof từ orchestrator.
 * Errors: từ chối argument trước fixture/SDK; lỗi scenario được giữ để CLI trả failure.
 */
export async function runNativeRateCli(arguments_, runScenario = runActualRate) {
  assert.ok(Array.isArray(arguments_) && arguments_.length === 0, 'NATIVE_RATE_ARGUMENTS_INVALID');
  return await runScenario();
}

// Import bởi host tests không chạy DB/SDK. CLI chỉ phát failure cố định, không echo argv/raw error.
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try { await runNativeRateCli(process.argv.slice(2)); } catch {
    console.error('NATIVE_RATE_E2E_FAILED'); process.exitCode = 1;
  }
}
