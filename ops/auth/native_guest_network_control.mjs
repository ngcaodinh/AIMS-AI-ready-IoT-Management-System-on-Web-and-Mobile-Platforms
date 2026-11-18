import assert from 'node:assert/strict';

/**
 * Yêu cầu bằng chứng quyền Wi-Fi trong đúng block package shell trước khi harness được phép fault.
 * Input
 * Param: output — stdout bounded/complete của dumpsys package com.android.shell đã raw terminal.
 * Output: trả bình thường chỉ khi install permissions trong package exact có một grant true theo format SDK đã pin.
 * Errors: NOT_PROVEN khi missing/false/duplicate/conflict/format lạ; không khẳng định effective permission denied.
 */
export function requireShellWifiPermission(output) {
  assert.ok(typeof output === 'string', 'SHELL_WIFI_PERMISSION_NOT_PROVEN');
  const lines = output.split('\n').map(
    /** Param: line — chỉ bỏ CR framing cuối dòng Windows, CR giữa token phải bị grammar từ chối. */
    (line) => line.replace(/\r+$/, ''));
  const headers = [];
  for (let index = 0; index < lines.length; index++) {
    if (/^  Package \[com\.android\.shell\] \([0-9a-fA-F]+\):\s*$/.test(lines[index])) headers.push(index);
  }
  assert.ok(headers.length === 1, 'SHELL_WIFI_PERMISSION_NOT_PROVEN');
  let end = headers[0] + 1;
  while (end < lines.length && !/^\S|^  \S/.test(lines[end])) end++;
  // Block phải có boundary kế tiếp: stdout bị cắt trước đó không được cấp quyền từ một dòng grant lẻ.
  assert.ok(end < lines.length, 'SHELL_WIFI_PERMISSION_NOT_PROVEN');
  const packageLines = lines.slice(headers[0] + 1, end);
  const sections = [];
  for (let index = 0; index < packageLines.length; index++) {
    if (packageLines[index] === '    install permissions:') sections.push(index);
  }
  assert.ok(sections.length === 1, 'SHELL_WIFI_PERMISSION_NOT_PROVEN');
  let sectionEnd = sections[0] + 1;
  while (sectionEnd < packageLines.length && !/^ {0,4}\S/.test(packageLines[sectionEnd])) sectionEnd++;
  const permissionLines = packageLines.slice(sections[0] + 1, sectionEnd).filter(
    /** Param: line — bỏ dòng trống framing, vẫn giữ indentation để từ chối grant trong nested/user section. */
    (line) => line.trim().length > 0);
  // SDK API36 bổ sung flags cho sibling grant; chỉ nhận metadata uppercase bounded trong đúng section/sáu space.
  const grantPattern = /^ {6}([A-Za-z][A-Za-z0-9._]*): granted=(true|false)(?:, flags=\[[ A-Z_|]{0,128}\])?$/;
  assert.ok(permissionLines.every(
    /** Param: line — không mở rộng section hoặc nhận nested/user grant khi cho phép suffix flags. */
    (line) => grantPattern.test(line)), 'SHELL_WIFI_PERMISSION_NOT_PROVEN');
  const grants = permissionLines.filter(
    /** Param: line — chỉ quyền Wi-Fi đúng trong install section đã pin, không runtime user/shared UID khác. */
    (line) => line.startsWith('      android.permission.CHANGE_WIFI_STATE:'));
  assert.ok(grants.length === 1 && grantPattern.exec(grants[0])?.[2] === 'true',
    'SHELL_WIFI_PERMISSION_NOT_PROVEN');
}

/**
 * Đọc đúng một bit settings của AVD, từ chối unknown hoặc nhiều dòng thay vì đoán trạng thái.
 * Input
 * Param: output — stdout của original SDK command đã terminal; CRCRLF chỉ là framing Windows.
 * Output: bit 0 hoặc 1, không coi bit này là bằng chứng native route đã bị cắt.
 * Errors: fixed schema error, không phản chiếu dữ liệu từ device.
 */
export function parseGuestNetworkBit(output) {
  assert.ok(typeof output === 'string' && /^\s*[01]\s*$/.test(output), 'GUEST_NETWORK_STATE_INVALID');
  return Number(output.trim());
}

/**
 * Lấy đúng một radio enum từ cmd wifi status, không lưu/xuất SSID/MAC hay các trường khác.
 * Input
 * Param: output — stdout bounded của runtime Wi-Fi status đã terminal trên API36.
 * Output: bit1/0 theo enabled/disabled; đây là readback radio bổ sung, không là route oracle.
 * Errors: fixed schema failure nếu unknown, duplicate hoặc CR giữa token.
 */
export function parseGuestWifiStatus(output) {
  assert.ok(typeof output === 'string', 'GUEST_WIFI_RADIO_INVALID');
  const lines = output.split('\n').map(
    /** Param: line — chỉ normalize newline framing, không loại ký tự giữa state token. */
    (line) => line.replace(/\r+$/, ''));
  const wifiLines = lines.filter(
    /** Param: line — chỉ xem nhóm prefix radio/connection đã biết, không phản chiếu nội dung mạng. */
    (line) => line.startsWith('Wifi is '));
  const states = wifiLines.filter(
    /** Param: line — connection diagnostics không phải enum bật/tắt và không được tính là duplicate. */
    (line) => /^Wifi is (enabled|disabled)$/.test(line));
  assert.ok(states.length === 1 && states[0] === lines[0] && wifiLines.every(
    /** Param: line — chỉ bỏ qua hai shape connection của AOSP; unknown radio vẫn phải fail closed. */
    (line) => /^Wifi is (enabled|disabled)$/.test(line) || line === 'Wifi is not connected' ||
      /^Wifi is connected to(?: |:)/.test(line)),
    'GUEST_WIFI_RADIO_INVALID');
  return states[0] === 'Wifi is enabled' ? 1 : 0;
}

/**
 * Điều khiển hai kết nối guest bằng fixed svc/API24 hoặc cmd/API36, baseline cả hai bật và airplane tắt.
 * Input
 * Param: execute — trusted SDK capability với argv fixed và observer budget, phải đợi original raw close.
 * Param: commandMode — svc mặc định hoặc cmd có runtime Wi-Fi readback, không nhận arbitrary argv.
 * Param: now — monotonic clock; không đọc wallclock hoặc môi trường host.
 * Param: sleep — poll delay có thể fake trong host tests, không cấp ACK từ timer.
 * Output: readState/setState cùng fixed verifier policy; partial không được admission baseline.
 * Side effects: fixed svc/cmd data/Wi-Fi trong AVD owned, không settings put hoặc thay host network.
 * Errors: fixed boundary khi command/readback/deadline sai, restore vẫn attempt cả hai write.
 */
export function createGuestNetworkControl({ execute, commandMode = 'svc', now = performance.now.bind(performance),
  sleep = /** Param: milliseconds — bounded poll, vẫn cần readback thật sau delay. */
    (milliseconds) => new Promise(/** Param: resolve — hoàn tất delay không đại diện SDK terminal. */
      (resolve) => setTimeout(resolve, milliseconds)) }) {
  assert.ok(commandMode === 'svc' || commandMode === 'cmd', 'GUEST_NETWORK_MODE_INVALID');
  let last = 0;

  /** Output: monotonic đã kiểm để completion clock-late/rollback không được cấp admission. */
  function clock() {
    const value = now();
    assert.ok(Number.isFinite(value) && value >= last, 'GUEST_NETWORK_DEADLINE_FAILED');
    last = value; return value;
  }

  /** Param: deadline — absolute budget; Output: thời gian còn lại, zero/late là failure. */
  function remaining(deadline) {
    const value = deadline - clock();
    assert.ok(value > 0, 'GUEST_NETWORK_DEADLINE_FAILED');
    return value;
  }

  /**
   * Đọc airplane/wifi/data bằng fixed keys, không dump settings hay dữ liệu kết nối cá nhân.
   * Input
   * Param: deadline — budget chung cho cả ba read; mặc định10s khi verifier gọi độc lập.
   * Output: enabled/disabled/partial; airplane khác0 hoặc schema sai phải reject.
   */
  async function readState(deadline = clock() + 10_000) {
    const bits = [];
    for (const key of ['airplane_mode_on', 'wifi_on', 'mobile_data']) {
      const output = await execute(['shell', 'settings', 'get', 'global', key], remaining(deadline));
      remaining(deadline); bits.push(parseGuestNetworkBit(output));
    }
    assert.equal(bits[0], 0, 'GUEST_NETWORK_AIRPLANE_CHANGED');
    if (commandMode === 'cmd') {
      const output = await execute(['shell', 'cmd', 'wifi', 'status'], remaining(deadline));
      remaining(deadline);
      if (parseGuestWifiStatus(output) !== bits[1]) return 'partial';
    }
    return bits[1] === bits[2] ? (bits[1] === 1 ? 'enabled' : 'disabled') : 'partial';
  }

  /**
   * Disable có thứ tự; restore attempt cả data/wifi dù write đầu lỗi, lỗi được giữ sticky.
   * Input
   * Param: state — chỉ off hoặc enabled từ verifier policy đã chốt, không arbitrary SDK command.
 * Param: admission — checkpoint authority tùy chọn, được kiểm trước từng radio write để chặn lệnh muộn.
   * Output: sau original command terminal và state convergence10s; không dựa exit0 của svc làm ACK.
   * Errors: failure sau các restore attempts/readback, không overlap cùng raw command đang pending.
   */
  async function setState(state, admission) {
    assert.ok(state === 'off' || state === 'enabled', 'GUEST_NETWORK_COMMAND_INVALID');
    const restoring = state === 'enabled'; let failed = false;
    for (const service of ['data', 'wifi']) {
      const args = commandMode === 'svc' ? ['shell', 'svc', service, restoring ? 'enable' : 'disable'] :
        service === 'data' ? ['shell', 'cmd', 'phone', 'data', restoring ? 'enable' : 'disable'] :
          ['shell', 'cmd', 'wifi', 'set-wifi-enabled', restoring ? 'enabled' : 'disabled'];
      // Kiểm quyền giai đoạn trước từng lệnh vô tuyến vì lệnh ADB trước có thể trả về sau khi quyền hết hạn.
      admission?.assertActive();
      try { await execute(args, 30_000); }
      catch { failed = true; if (!restoring) break; }
    }
    const deadline = clock() + 10_000;
    try {
      while (await readState(deadline) !== (restoring ? 'enabled' : 'disabled')) {
        await sleep(Math.min(100, remaining(deadline)));
      }
      remaining(deadline);
    } catch { failed = true; }
    assert.ok(!failed, 'GUEST_NETWORK_COMMAND_UNCONFIRMED');
  }

  return { readState, setState, baselineStates: ['enabled'], disconnectedState: 'disabled' };
}
