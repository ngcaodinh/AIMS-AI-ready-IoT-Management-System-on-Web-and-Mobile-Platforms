import assert from 'node:assert/strict';
import { createGuestNetworkControl, parseGuestNetworkBit, requireShellWifiPermission, parseGuestWifiStatus } from './native_guest_network_control.mjs';
import { verifyNetworkRoute } from './run_native_network_probe.mjs';

for (const output of ['0\n', '1\r\r\n', ' 1\r\n']) {
  assert.equal(parseGuestNetworkBit(output), Number(output.trim()));
}
for (const output of ['null', '2', '1\n0', '1\n1', 'enabled', '', '10']) {
  assert.throws(/** Output: cùng input malformed, không đọc AVD hoặc settings thật. */
    () => parseGuestNetworkBit(output), { message: 'GUEST_NETWORK_STATE_INVALID' });
}
console.log('GUEST_NETWORK_STRICT_BIT_SCHEMA_PASS');

const packageHeader = 'Packages:\n  Package [com.android.shell] (abc123):\n    install permissions:\n';
const granted = '      android.permission.CHANGE_WIFI_STATE: granted=true\n';
requireShellWifiPermission((packageHeader + granted + 'Shared users:\n').replaceAll('\n', '\r\r\n'));
for (const output of [packageHeader + granted, packageHeader + 'Shared users:\n' + granted,
  packageHeader + granted + granted + 'Shared users:\n',
  packageHeader + granted.replace('true', 'false') + 'Shared users:\n',
  packageHeader + granted + granted.replace('true', 'false') + 'Shared users:\n',
  packageHeader.replace('com.android.shell', 'com.android.shell.fake') + granted + 'Shared users:\n',
  packageHeader + granted + packageHeader + granted + 'Shared users:\n',
  packageHeader.replace('install permissions:', 'non-permission-section:') + granted + 'Shared users:\n',
  packageHeader.replace('install permissions:', 'User 10:\n      runtime permissions:') + '  ' + granted + 'Shared users:\n',
  packageHeader + '      nested-section:\n  ' + granted + 'Shared users:\n']) {
  assert.throws(/** Output: malformed/out-of-scope grant không cấp quyền fault cho harness. */
    () => requireShellWifiPermission(output), { message: 'SHELL_WIFI_PERMISSION_NOT_PROVEN' });
}
console.log('GUEST_NETWORK_SHELL_PERMISSION_SCOPE_PASS');

for (const grantBody of [
  granted + '      android.permission.ACCESS_WIFI_STATE: granted=true, flags=[ SYSTEM_FIXED|GRANTED_BY_DEFAULT ]\n',
  granted + '      android.permission.OTHER: granted=false, flags=[]\n',
  granted.replace('true\n', 'true, flags=[ SYSTEM_FIXED ]\n'),
]) requireShellWifiPermission(packageHeader + grantBody + 'Shared users:\n');
for (const malformedGrant of [
  granted.replace('true\n', 'true, flags=[ lower_case ]\n'),
  granted.replace('true\n', 'true, flags=[ SYSTEM_FIXED\n'),
  granted.replace('true\n', 'true, flags=[' + 'X'.repeat(129) + ']\n'),
  granted.replace('true\n', 'true, granted=false\n'),
  granted.replace('true', 'tr\rue'),
  granted.replace('CHANGE_WIFI_STATE', 'CHANGE_WIFI_\rSTATE'),
]) assert.throws(/** Output: flags/mid-token CR sai không được biến thành proof quyền. */
  () => requireShellWifiPermission(packageHeader + malformedGrant + 'Shared users:\n'));
console.log('GUEST_NETWORK_API36_PERMISSION_FLAGS_PASS');

assert.equal(parseGuestWifiStatus('Wifi is enabled\r\r\nOther diagnostic fields\r\n'), 1);
assert.equal(parseGuestWifiStatus('Wifi is disabled\n'), 0);
assert.equal(parseGuestWifiStatus('Wifi is enabled\nWifi is not connected\n'), 1);
assert.equal(parseGuestWifiStatus('Wifi is enabled\nWifi is connected to SYNTHETIC_NETWORK\n'), 1);
for (const output of ['', 'Wifi is unknown', 'Wifi is enabled\nWifi is disabled',
  'Wifi is unknown\nWifi is enabled', 'Wifi is enabled\nWifi is unknown',
  'prefix\nWifi is enabled', 'Wifi is en\rabled']) {
  assert.throws(/** Output: radio state schema sai hoặc trùng phải reject, không đọc thông tin mạng khác. */
    () => parseGuestWifiStatus(output), { message: 'GUEST_WIFI_RADIO_INVALID' });
}
console.log('GUEST_NETWORK_RADIO_SCHEMA_PASS');

assert.throws(/** Output: profile ngoài allowlist phải reject trước khi bất kỳ SDK command nào được cấp. */
  () => createGuestNetworkControl({ commandMode: 'arbitrary',
    execute: /** Không được gọi khi profile sai, tránh fallback thành mutation ngoài policy. */
      async () => { throw Error('UNEXPECTED_SDK_CALL'); } }), { message: 'GUEST_NETWORK_MODE_INVALID' });
console.log('GUEST_NETWORK_COMMAND_PROFILE_ALLOWLIST_PASS');

{
  const fake = fakeGuest('effective', 'cmd'); let admissionChecks = 0;
  const admission = {
    /** Chỉ cho phép lệnh data đầu tiên để lộ write Wi-Fi thiếu fence giữa hai ADB calls. */
    assertActive() {
      admissionChecks++;
      if (admissionChecks > 1) throw new Error('NATIVE_OFFLINE_PREARM_UNAVAILABLE');
    },
  };
  await assert.rejects(() => fake.control.setState('off', admission),
    { message: 'NATIVE_OFFLINE_PREARM_UNAVAILABLE' });
  assert.deepEqual(fake.writes, ['data:disable']);
  console.log('GUEST_NETWORK_ADMISSION_BETWEEN_RADIOS_PASS');
}

/**
 * Mô hình guest settings/SDK cho invariant ordering, không giả làm actual route proof.
 * Input
 * Param: mode — fixed fault enum của testcase, chỉ ảnh hưởng in-memory fake.
 * Param: commandMode — svc hoặc cmd để kiểm cùng invariants qua đúng fixed argv của từng SDK profile.
 * Output: original adapter cùng bits/writes, fake clock và raw-pending release capability.
 */
function fakeGuest(mode, commandMode = 'svc') {
  const bits = { airplane_mode_on: mode === 'airplane' ? 1 : 0,
    wifi_on: mode === 'unsupported' ? 0 : 1, mobile_data: 1 };
  const writes = []; let clock = 0; let release; let off = false; let restoring = false; let radioOffReads = 0;
  const control = createGuestNetworkControl({
    commandMode,
    now: /** Output: fake monotonic, late read phải bị guard dù timer chưa chạy. */ () => clock,
    sleep: /** Param: delay — chỉ tiến fake clock, không đợi10giây trong host test. */
      async (delay) => { clock += delay; },
    execute: /** Param: args/limit — fixed adapter argv, chốt budget và mô phỏng raw SDK terminal. */
      async (args, limit) => {
        assert.ok(limit > 0 && limit <= 30_000);
        if (args[1] === 'settings') {
          assert.deepEqual(args.slice(0, 4), ['shell', 'settings', 'get', 'global']);
          const key = args[4]; assert.ok(Object.hasOwn(bits, key));
          if (mode === 'malformed' && off && !restoring) return '1\n0';
          if (mode === 'clock-late' && off && !restoring) clock += 10_000;
          return bits[key] + '\r\r\n';
        }
        if (commandMode === 'cmd' && args[2] === 'wifi' && args[3] === 'status') {
          assert.deepEqual(args, ['shell', 'cmd', 'wifi', 'status']);
          if (off && !restoring) {
            radioOffReads++;
            if (mode === 'radio-clock-late') clock += 10_000;
            if (mode === 'radio-malformed') return 'Wifi is unknown\n';
            if (mode === 'radio-mismatch-off' || (mode === 'radio-transition' && radioOffReads === 1)) return 'Wifi is enabled\n';
          }
          return 'Wifi is ' + (mode === 'radio-mismatch-restore' && restoring ? 'disabled' : bits.wifi_on ? 'enabled' : 'disabled') + '\n';
        }
        let service; let action;
        if (commandMode === 'cmd') {
          assert.equal(args[1], 'cmd');
          service = args[2] === 'phone' ? 'data' : 'wifi';
          action = args[4] === 'enabled' || args[4] === 'enable' ? 'enable' : 'disable';
          assert.deepEqual(args, service === 'data' ? ['shell', 'cmd', 'phone', 'data', action] :
            ['shell', 'cmd', 'wifi', 'set-wifi-enabled', action === 'enable' ? 'enabled' : 'disabled']);
        } else { assert.equal(args[1], 'svc'); service = args[2]; action = args[3]; }
        assert.ok(['data', 'wifi'].includes(service) && ['enable', 'disable'].includes(action));
        writes.push(service + ':' + action);
        if (action === 'disable') off = true; else restoring = true;
        if (mode !== 'no-readback') bits[service === 'wifi' ? 'wifi_on' : 'mobile_data'] = action === 'enable' ? 1 : 0;
        if ((mode === 'first-side-effect-fail' && service === 'data' && action === 'disable') ||
            (mode === 'second-side-effect-fail' && service === 'wifi' && action === 'disable') ||
            (mode === 'restore-data-fail' && service === 'data' && action === 'enable') ||
            (mode === 'restore-wifi-fail' && service === 'wifi' && action === 'enable')) throw Error('FAKE_SDK_FAILURE');
        if ((mode === 'off-pending' && service === 'data' && action === 'disable') ||
            (mode === 'restore-pending' && service === 'data' && action === 'enable')) {
          await new Promise(/** Param: resolve — giữ raw command pending, không cho restore overlap hoặc release owner sớm. */
            (resolve) => { release = resolve; });
        }
        return '';
      },
  });
  return { control, bits, writes,
    release: /** Chỉ testcase mới cho original fake command terminal, không tạo retry command. */ () => release?.(),
    hasPending: /** Output: đã tới raw pending boundary để testcase quan sát ordering. */ () => typeof release === 'function' };
}

for (const commandMode of ['svc', 'cmd']) {
const markerPrefix = commandMode === 'cmd' ? 'GUEST_NETWORK_CMD_' : 'GUEST_NETWORK_';
for (const key of ['wifi_on', 'mobile_data', 'airplane_mode_on']) {
  const fake = fakeGuest('effective', commandMode); let release; let probes = 0;
  const pending = new Promise(/** Param: resolve — giữ baseline canary để mô phỏng state đổi trong SDK wait. */
    (resolve) => { release = resolve; });
  const result = verifyNetworkRoute({ ...fake.control,
    probe: /** Output: positive canary tới muộn không tự cấp quyền thay state khác saved baseline. */
      async () => { probes++; return pending; } });
  const observed = assert.rejects(/** Same run phải bị chặn trước off và không restore network đã đổi bên ngoài. */ () => result);
  try {
    for (let index = 0; index < 100 && probes === 0; index++) await Promise.resolve();
    assert.equal(probes, 1); fake.bits[key] = key === 'airplane_mode_on' ? 1 : 0;
    release('REACHABLE'); await observed;
    assert.deepEqual(fake.writes, []); assert.equal(probes, 1);
    assert.equal(fake.bits[key], key === 'airplane_mode_on' ? 1 : 0);
  } finally { release('REACHABLE'); await observed; }
  console.log(markerPrefix + 'BASELINE_CHANGED_' + key.toUpperCase() + '_PASS');
}

for (const mode of ['effective', 'ineffective', 'unsupported', 'airplane', 'first-side-effect-fail',
  'second-side-effect-fail', 'restore-data-fail', 'restore-wifi-fail', 'malformed', 'clock-late', 'no-readback',
  ...(commandMode === 'cmd' ? ['radio-mismatch-off', 'radio-mismatch-restore', 'radio-malformed', 'radio-clock-late', 'radio-transition'] : [])]) {
  const fake = fakeGuest(mode, commandMode); let probes = 0;
  const result = verifyNetworkRoute({ ...fake.control,
    probe: /** Output: fake route chỉ phục vụ verifier ordering, actual canary cần AVD riêng. */ async () => {
      probes++; return probes === 2 && mode !== 'ineffective' ? 'UNAVAILABLE' : 'REACHABLE';
    },
  });
  if (mode === 'effective' || mode === 'ineffective' || mode === 'radio-transition') {
    assert.equal(await result, mode === 'ineffective' ? 'INEFFECTIVE' : 'EFFECTIVE'); assert.equal(probes, 3);
  } else await assert.rejects(/** Output: same invocation; malformed/partial/late không được cấp PASS. */ () => result);
  if (['unsupported', 'airplane'].includes(mode)) {
    assert.deepEqual(fake.writes, []); assert.equal(probes, 0);
  } else {
    assert.deepEqual(fake.writes.slice(-2), ['data:enable', 'wifi:enable']);
    assert.equal(fake.bits.wifi_on, 1); assert.equal(fake.bits.mobile_data, 1);
    if (mode === 'first-side-effect-fail') assert.equal(fake.writes.includes('wifi:disable'), false);
  }
  console.log(markerPrefix + mode.toUpperCase().replaceAll('-', '_') + '_PASS');
}

for (const mode of ['off-pending', 'restore-pending']) {
  const fake = fakeGuest(mode, commandMode); let probes = 0; let settled = false;
  const result = verifyNetworkRoute({ ...fake.control,
    probe: /** Output: baseline/restored reachable, off unavailable; command vẫn là original fake SDK. */
      async () => ++probes === 2 ? 'UNAVAILABLE' : 'REACHABLE' });
  result.then(/** Public outcome phải giữ pending tới raw terminal. */ () => { settled = true; },
    /** Failure cũng không được giả SDK đã terminal. */ () => { settled = true; });
  try {
    for (let index = 0; index < 100 && !fake.hasPending(); index++) await Promise.resolve();
    assert.equal(fake.hasPending(), true); assert.equal(settled, false);
    assert.deepEqual(fake.writes, mode === 'off-pending' ? ['data:disable'] : ['data:disable', 'wifi:disable', 'data:enable']);
    fake.release(); assert.equal(await result, 'EFFECTIVE');
    assert.deepEqual(fake.writes, ['data:disable', 'wifi:disable', 'data:enable', 'wifi:enable']);
  } finally { fake.release(); await result.catch(/** Đợi original observer cả khi assertion testcase thất bại. */ () => {}); }
  console.log(markerPrefix + mode.toUpperCase().replaceAll('-', '_') + '_PASS');
}

{
  const fake = fakeGuest('effective', commandMode); let probes = 0; let expire; let release; let settled = false;
  const pending = new Promise(/** Param: resolve — raw SDK probe thứ hai giữ pending tới testcase release. */
    (resolve) => { release = resolve; });
  const result = verifyNetworkRoute({ ...fake.control,
    probe: /** Output: same raw off probe không terminal chỉ vì observer360s đã hết hạn. */
      async () => ++probes === 2 ? pending : 'REACHABLE',
    timers: {
      setTimeout: /** Param: callback/limit — timeout intent fake không đồng nhất raw command hoặc restore ACK. */
        (callback, limit) => { assert.equal(limit, 360_000); expire = callback; return callback; },
      clearTimeout: /** Hủy timer không release original probe hoặc guest SDK commands. */ () => {},
    },
  });
  result.then(/** Public outcome chưa được settle trong lúc probe pending. */ () => { settled = true; },
    /** Timeout là failure sticky nhưng vẫn phải giữ raw terminal. */ () => { settled = true; });
  try {
    for (let index = 0; index < 150 && probes !== 2; index++) await Promise.resolve();
    assert.equal(probes, 2); expire();
    for (let index = 0; index < 150 && fake.bits.wifi_on !== 1; index++) await Promise.resolve();
    assert.deepEqual(fake.writes, ['data:disable', 'wifi:disable', 'data:enable', 'wifi:enable']);
    assert.equal(settled, false); assert.equal(probes, 2);
    release('UNAVAILABLE'); await assert.rejects(/** Original invocation sau late SDK settle phải giữ failure. */ () => result);
    assert.equal(probes, 3);
  } finally { release('UNAVAILABLE'); await result.catch(/** Drain original observer nếu assertion lỗi. */ () => {}); }
  console.log(markerPrefix + 'PROBE_TIMEOUT_RESTORE_AND_DRAIN_PASS');
}
}
