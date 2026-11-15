import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { parseGsmDataState, verifyNetworkRoute, startProbeUpstream, runSdk } from './run_native_network_probe.mjs';

for (const state of ['home', 'roaming', 'searching', 'denied', 'unregistered']) {
  assert.equal(parseGsmDataState('gsm voice state: home\r\ngsm data state: ' + state + '\r\nOK\r\n'), state);
}
for (const text of ['OK', 'gsm data state: home\ngsm data state: off\nOK', 'gsm data state: invalid\nOK']) {
  assert.throws(/** Output: parser nhận cùng console text hiện hành, không đọc device. */
    () => parseGsmDataState(text), { message: 'NETWORK_GSM_STATE_INVALID' });
}
console.log('NETWORK_PROBE_GSM_STATE_SCHEMA_PASS');

{
  let state = 'home'; let count = 0; let releaseProbe; let expire; let settled = false;
  const calls = [];
  const pending = new Promise(/** Param: resolve — SDK/raw native probe chưa terminal tới khi testcase release. */
    (resolve) => { releaseProbe = resolve; });
  const result = verifyNetworkRoute({
    readState: /** Output: same modem state fake, không đọc Android thật. */ async () => state,
    setState: /** Param: value — saved enum hoặc off, ghi ordering restore trước raw completion. */ async (value) => {
      calls.push(value); state = value === 'off' ? 'unregistered' : value;
    },
    probe: /** Output: second raw probe cố ý pending xuyên deadline, baseline/restored reachable. */ async () => {
      count++; return count === 2 ? pending : 'REACHABLE';
    },
    timers: {
      setTimeout: /** Param: callback/milliseconds — thao tác timer giả không tự trả ACK modem hoặc SDK. */
        (callback, milliseconds) => { assert.equal(milliseconds, 360_000); expire = callback; return callback; },
      clearTimeout: /** Không release pending probe khi chỉ hủy observer timer. */ () => {},
    },
  });
  result.then(/** Theo dõi public outcome, timeout không được tự giả terminal. */
    () => { settled = true; }, /** Failure cũng phải đợi raw probe trước terminal. */ () => { settled = true; });
  try {
    for (let index = 0; index < 20 && count !== 2; index++) await Promise.resolve();
    assert.equal(count, 2); expire();
    for (let index = 0; index < 20 && state !== 'home'; index++) await Promise.resolve();
    assert.deepEqual(calls, ['off', 'home']); assert.equal(state, 'home'); assert.equal(settled, false);
    releaseProbe('UNAVAILABLE');
    await assert.rejects(/** Output: same invocation sau late SDK completion, không cấp lại PASS. */
      () => result, { message: 'NETWORK_MODEM_PROBE_FAILED' });
  } finally { releaseProbe('UNAVAILABLE'); await result.catch(/** Giữ raw observer khi test assertion lỗi. */ () => {}); }
}
console.log('NETWORK_PROBE_TIMEOUT_RESTORES_BEFORE_RAW_TERMINAL_PASS');

for (const mode of ['success', 'timeout', 'bind-error', 'clock-late']) {
  const server = new EventEmitter();
  let expire; let owner; let acknowledgeClose; let settled = false; let clock = 0;
  server.listen = /** Fake bind chỉ phát listening khi testcase cho phép, không mở cổng thật. */ () => {
    if (mode === 'success') queueMicrotask(/** Event loop handoff mô phỏng async listening. */
      () => { server.listening = true; server.emit('listening'); });
    if (mode === 'bind-error') queueMicrotask(/** Bind conflict fake không được cấp ready. */
      () => server.emit('error', Error('SYNTHETIC_BIND_FAILURE')));
    if (mode === 'clock-late') queueMicrotask(/** Timer chưa chạy nhưng listening tới đúng deadline đã mất admission. */
      () => { clock = 10_000; server.listening = true; server.emit('listening'); });
  };
  server.close = /** Param: callback — giữ raw close pending để timeout không tự thành terminal. */
    (callback) => { acknowledgeClose = callback; };
  const result = startProbeUpstream({
    createServer: /** Output: fake OS listener, helper giữ original bind/abort/cleanup logic. */ () => server,
    onOwned: /** Param: value — raw owner phải được cấp trước khi async bind có thể lỗi. */
      (value) => { owner = value; },
    setTimeout: /** Param: callback/milliseconds — timer fake chỉ phát intent timeout, không raw ACK. */
      (callback, milliseconds) => { assert.equal(milliseconds, 10_000); expire = callback; return callback; },
    clearTimeout: /** Timer cancellation không phát close event của server. */ () => {},
    now: /** Output: fake monotonic clock không phụ thuộc thứ tự callback timer. */ () => clock,
  });
  result.then(/** Quan sát settlement độc lập với owner close intent. */
    () => { settled = true; }, /** Failure cũng phải chờ raw event close thật. */ () => { settled = true; });
  if (mode === 'success') {
    assert.equal(await result, owner); const closing = owner.close();
    acknowledgeClose(); server.listening = false; server.emit('close'); assert.equal(await closing, true);
  } else {
    if (mode === 'timeout') expire();
    for (let index = 0; index < 10 && !acknowledgeClose; index++) await Promise.resolve();
    assert.equal(typeof acknowledgeClose, 'function'); assert.equal(settled, false);
    acknowledgeClose(); server.emit('close');
    await assert.rejects(/** Output: same helper invocation, không cấp listener hoặc retry sau bind fault. */
      () => result, { message: 'NETWORK_UPSTREAM_BIND_FAILED' });
    server.emit('listening'); server.emit('error', Error('SYNTHETIC_LATE_EVENT'));
    assert.equal(owner.healthy(), false);
  }
  console.log('NETWORK_PROBE_UPSTREAM_' + mode.toUpperCase().replaceAll('-', '_') + '_PASS');
}

for (const mode of ['effective', 'ineffective', 'baseline-fail', 'off-write-fail', 'off-readback-fail',
  'off-probe-fail', 'restore-write-fail', 'restore-readback-fail', 'restored-probe-fail', 'probe-clock-late']) {
  const calls = []; let state = 'roaming'; let reads = 0; let probes = 0; let clock = 0;
  const result = verifyNetworkRoute({
    readState: /** Output: console enum giả, mode fault không được coi là restore ACK hợp lệ. */ async () => {
      reads++;
      if (mode === 'off-readback-fail' && reads === 3) return 'home';
      if (mode === 'restore-readback-fail' && reads === 4) return 'home';
      return state;
    },
    setState: /** Param: value — off hoặc đúng baseline roaming, không mở arbitrary command. */ async (value) => {
      calls.push(value);
      if ((mode === 'off-write-fail' && value === 'off') || (mode === 'restore-write-fail' && value === 'roaming')) throw Error();
      state = value === 'off' ? 'unregistered' : value;
    },
    probe: /** Output: observation fake kiểm ordering, không coi kết quả này là actual network proof. */ async () => {
      probes++;
      if ((mode === 'baseline-fail' && probes === 1) || (mode === 'off-probe-fail' && probes === 2) ||
          (mode === 'restored-probe-fail' && probes === 3)) throw Error();
      if (mode === 'probe-clock-late' && probes === 2) clock = 360_000;
      return probes === 2 && mode !== 'ineffective' ? 'UNAVAILABLE' : 'REACHABLE';
    },
    now: /** Output: fake clock để late completion không cần chờ timer hoặc đợi360giây. */ () => clock,
  });
  if (mode === 'effective') assert.equal(await result, 'EFFECTIVE');
  else if (mode === 'ineffective') assert.equal(await result, 'INEFFECTIVE');
  else await assert.rejects(/** Output: cùng invocation, không retry để che fault mutation/restore. */
    () => result, { message: 'NETWORK_MODEM_PROBE_FAILED' });
  assert.deepEqual(calls, mode === 'baseline-fail' ? [] : ['off', 'roaming']);
  console.log('NETWORK_PROBE_' + mode.toUpperCase().replaceAll('-', '_') + '_PASS');
}

for (const mode of ['success', 'clock-late', 'timeout-pending']) {
  const child = new EventEmitter(); child.stdout = new EventEmitter(); child.stderr = new EventEmitter();
  let clock = 0; let expire; let settled = false;
  const result = runSdk('SYNTHETIC_SDK', [], '.', 30_000, {
    spawn: /** Output: fake SDK child, original runSdk giữ spawn/data/raw-close và clock guards. */
      () => { queueMicrotask(/** Spawn ACK và stdout tới sau khi observers đã đăng ký. */
        () => { child.emit('spawn'); child.stdout.emit('data', Buffer.from('SDK_OUTPUT')); }); return child; },
    now: /** Output: fake monotonic để kiểm deadline dù timer chưa được dispatch. */ () => clock,
    setTimeout: /** Param: callback — giữ timeout intent riêng với close ACK của SDK. */
      (callback) => { expire = callback; return callback; },
    clearTimeout: /** Hủy timer không tạo raw terminal. */ () => {},
  });
  result.then(/** Theo dõi settlement phải sau raw close. */ () => { settled = true; },
    /** Lỗi timeout vẫn chưa cho phép bỏ raw child ownership. */ () => { settled = true; });
  await Promise.resolve();
  if (mode === 'clock-late') clock = 30_000;
  if (mode === 'timeout-pending') { expire(); await Promise.resolve(); assert.equal(settled, false); }
  child.emit('close', 0);
  if (mode === 'success') assert.equal(await result, 'SDK_OUTPUT');
  else await assert.rejects(/** Output: same SDK invocation, không retry child mới sau deadline. */
    () => result, { message: 'NETWORK_SDK_COMMAND_FAILED' });
  console.log('NETWORK_PROBE_SDK_' + mode.toUpperCase().replaceAll('-', '_') + '_PASS');
}
