import assert from 'node:assert/strict';
import { assertNativePid } from './run_native_e2e.mjs';

/**
 * Tạo OS boundary giả để kiểm receipt PID, không gọi ADB hoặc tác động device.
 * Input
 * Param: result — projection status/stdout/stderr/error/signal synthetic do ca test chọn.
 * Output: callback đồng bộ trả đúng projection sau khi kiểm executable, serial và timeout.
 */
function fakeCommand(result) {
  /**
   * Kiểm serial/package và giới hạn OS trước khi cấp projection do test chọn.
   * Input
   * Param: command — executable ADB cố định của oracle.
   * Param: arguments_ — serial, shell và query package do oracle truyền.
   * Param: options — encoding, timeout, buffer cap và chế độ ẩn cửa sổ.
   * Output: projection OS giả được giữ trong closure, không tạo process thật.
   */
  return (command, arguments_, options) => {
      assert.ok(command.endsWith('/platform-tools/adb.exe'));
      assert.deepEqual(arguments_.slice(0, 3), ['-s', 'emulator-5554', 'shell']);
      assert.ok(arguments_.slice(3).join(' ').includes('dev.nexa.nexa_iot'));
      assert.equal(options.timeout, 5000);
      assert.equal(options.windowsHide, true);
      assert.equal(options.maxBuffer, 4096);
      return result;
    };
}

/** Kiểm ma trận absent/live PID, transport lỗi, receipt dư và timeout bằng OS boundary giả. */
function main() {
  assert.throws(
    /** Device offline không có shell receipt nên không chứng minh native death. */
    () => assertNativePid(null, fakeCommand({ status: 1, stdout: '', stderr: 'error: device offline\n' })));
  assert.throws(
    /** Exit1 không receipt vẫn bị từ chối kể cả stderr không có nội dung. */
    () => assertNativePid(null, fakeCommand({ status: 1, stdout: '', stderr: '' })));
  assert.doesNotThrow(
    /** Chỉ shell thành công với literal absent mới cho phép phase tiếp theo. */
    () => assertNativePid(null, fakeCommand({ status: 0, stdout: 'NATIVE_PACKAGE_ABSENT\r\n', stderr: '' })));
  assert.doesNotThrow(
    /** PID sống phải khớp chính xác PID native đã được protocol xác thực. */
    () => assertNativePid(8123, fakeCommand({ status: 0, stdout: '8123\n', stderr: '' })));
  for (const result of [
    { status: 0, stdout: '8123\n', stderr: '' },
    { status: 0, stdout: 'NATIVE_PACKAGE_ABSENT\nextra', stderr: '' },
    { status: 0, stdout: 'NATIVE_PACKAGE_ABSENT\n', stderr: 'transport warning' },
    { status: null, stdout: '', stderr: '', signal: 'SIGTERM' },
    { status: 0, stdout: 'NATIVE_PACKAGE_ABSENT\n', stderr: '', error: new Error('PRIVATE_OS_ERROR') },
    { status: 2, stdout: '', stderr: '' },
    { status: 0, stdout: '', stderr: '' },
  ]) assert.throws(
    /** Receipt dư, timeout, lỗi shell hoặc process còn sống đều không được hiểu thành absent. */
    () => assertNativePid(null, fakeCommand(result)));
  for (const value of ['8123 8124', '81230', 'NATIVE_PACKAGE_ABSENT', '']) assert.throws(
    /** Không chấp nhận prefix PID, multiprocess hoặc literal absent cho kiểm process đang sống. */
    () => assertNativePid(8123, fakeCommand({ status: 0, stdout: value, stderr: '' })));
  console.log('NATIVE_PID_EXPLICIT_SHELL_RECEIPT_PASS');
}

try { main(); } catch (error) {
  // Chỉ fixed marker, không xuất stderr OS hoặc assertion actual/expected.
  const line = /test_native_pid\.mjs:(\d+)/.exec(error.stack)?.[1] ?? 'UNKNOWN';
  console.error(`NATIVE_PID_EXPLICIT_SHELL_RECEIPT_FAILED line=${line}`); process.exitCode = 1;
}
