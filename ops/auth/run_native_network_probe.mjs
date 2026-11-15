import assert from 'node:assert/strict';
import http from 'node:http';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { pathToFileURL } from 'node:url';
import { X509Certificate } from 'node:crypto';
import { createCertificates } from './memory_tls_material.mjs';
import { startLocalHttpsProxy } from './local_https_proxy.mjs';
import { createHttpMetadataCapture } from './http_metadata_capture.mjs';
import { createGuestNetworkControl, requireShellWifiPermission } from './native_guest_network_control.mjs';

const adb = 'C:/Users/LENOVO/AppData/Local/Android/sdk/platform-tools/adb.exe';
const device = 'emulator-5554';
const dataStates = ['home', 'roaming', 'searching', 'denied', 'unregistered'];

/**
 * Đọc đúng một trạng thái GPRS từ console SDK, không suy theo airplane flag hoặc Wi-Fi.
 * Input
 * Param: output — stdout bounded của đúng adb emu gsm status đã terminal exit0.
 * Output: enum data state để restore đúng baseline.
 * Errors: fixed schema failure, không phản chiếu raw console output.
 */
export function parseGsmDataState(output) {
  const matches = [...output.matchAll(/^gsm data state:\s*(\w+)\s*$/gm)];
  assert.ok(matches.length === 1 && dataStates.includes(matches[0][1]) && /(?:^|\n)OK\s*$/.test(output),
    'NETWORK_GSM_STATE_INVALID');
  return matches[0][1];
}

/**
 * Kiểm network fault giữa hai positive canary, luôn restore sau original off command terminal.
 * Input
 * Param: readState — console hoặc guest settings readback của cùng AVD owned.
 * Param: setState — chỉ off hoặc saved enum, command phải đợi raw terminal/readback.
 * Param: baselineStates — fixed allowlist modem hoặc guest11, không CLI supplied.
 * Param: disconnectedState — fixed expected readback của fault, không là native route proof.
 * Param: probe — native HTTP/TLS observation, failure TLS/protocol phải reject riêng.
 * Param: timers — fixed360s probe observer, fake injection chỉ dành host test ownership.
 * Param: now — monotonic clock, kiểm completion tới muộn ngay cả timer callback chưa chạy.
 * Output: EFFECTIVE hoặc INEFFECTIVE sau baseline/restore thành công.
 * Errors: fixed failure khi operation hoặc restore thiếu ACK, không tự retry mutation.
 */
export async function verifyNetworkRoute({ readState, setState, probe, baselineStates = dataStates,
  disconnectedState = 'unregistered', timers = { setTimeout, clearTimeout },
  now = performance.now.bind(performance) }) {
  let changed = false; let failed = false; let restored = false; let observation;
  let restoring; let probeTimer;
  const baseline = await readState();
  assert.ok(baselineStates.includes(baseline), 'NETWORK_MODEM_PROBE_FAILED');

  /** Output: memoized restore/readback, phát lệnh trước khi chờ raw SDK probe đã timeout. */
  function beginRestore() {
    if (!restoring) {
      let settle;
      restoring = new Promise(/** Param: resolve — chốt observer trước callback SDK có thể hoàn tất/reenter. */
        (resolve) => { settle = resolve; });
      void (
        /** Khôi phục saved enum dù off outcome lỗi, readback không phụ thuộc write ACK để ghi UNCONFIRMED đúng. */
        async () => {
          try { await setState(baseline); } catch { failed = true; }
          try { restored = await readState() === baseline; } catch { restored = false; }
          if (!restored) failed = true;
        }
      )().then(/** Restore observer không được reject unhandled trong lúc raw probe còn pending. */
        () => settle(), /** Lỗi dependency ngoài anticipated boundary vẫn giữ failure/settled observer. */
        () => { failed = true; settle(); });
    }
    return restoring;
  }
  try {
    assert.equal(await probe(), 'REACHABLE');
    // Canary có thể chờ SDK lâu: revalidate saved baseline sát admission để không restore state đã đổi trước fault.
    assert.equal(await readState(), baseline);
    // Thay đổi sau guard là in-flight trên AVD owned; không tuyên bố check và SDK write là atomic.
    changed = true;
    await setState('off');
    assert.equal(await readState(), disconnectedState);
    const started = now();
    assert.ok(Number.isFinite(started) && started >= 0);
    const deadline = started + 360_000;
    probeTimer = timers.setTimeout(
      /** Deadline khóa PASS và restore modem đồng thời raw SDK pending, không giả hủy child hoặc release proxy. */
      () => { failed = true; beginRestore(); }, 360_000);
    observation = await probe();
    const completed = now();
    assert.ok(Number.isFinite(completed) && completed >= started && completed < deadline);
    timers.clearTimeout(probeTimer); probeTimer = undefined;
    assert.ok(['REACHABLE', 'UNAVAILABLE'].includes(observation));
  } catch { failed = true; }
  finally {
    timers.clearTimeout(probeTimer);
    if (changed) {
      await beginRestore();
      if (restored) {
        try { assert.equal(await probe(), 'REACHABLE'); } catch { failed = true; }
      } else failed = true;
    }
  }
  assert.ok(!failed && changed && restored, 'NETWORK_MODEM_PROBE_FAILED');
  return observation === 'UNAVAILABLE' ? 'EFFECTIVE' : 'INEFFECTIVE';
}

/**
 * Chạy command SDK riêng với argv không secret, giữ raw close tới terminal kể cả timeout quan sát.
 * Input
 * Param: executable — SDK Node/ADB/Dart executable do source chốt.
 * Param: arguments_ — fixed console/probe arguments, certificate là public DER.
 * Param: cwd — repo hoặc mobile workspace của command.
 * Param: limit — budget quan sát ms, hết hạn chỉ chốt failure và vẫn drain đúng child.
 * Param: runtime — trusted spawn/timer/monotonic fake cho host tests, không CLI config.
 * Output: stdout bounded của original child exit0, không forward SDK trace ra console.
 * Errors: fixed failure sau raw child close, không restart hoặc kill process ngoài ownership.
 */
export async function runSdk(executable, arguments_, cwd, limit = 30_000, runtime = {}) {
  const now = runtime.now ?? performance.now.bind(performance);
  const started = now();
  assert.ok(Number.isFinite(started) && started >= 0 && Number.isFinite(limit) && limit > 0);
  const child = (runtime.spawn ?? spawn)(executable, arguments_, { cwd, windowsHide: true, shell: false, stdio: ['ignore', 'pipe', 'pipe'] });
  let output = ''; let bytes = 0; let failed = false; let spawned = false;
  const timer = (runtime.setTimeout ?? setTimeout)(/** Timeout không chứng minh child đã dừng, raw close vẫn phải được đợi. */
    () => { failed = true; }, limit);
  child.on('spawn', /** Ghi actual spawn để phân biệt lỗi trước tạo process với post-spawn error. */
    () => { spawned = true; });
  child.on('error', /** Spawn/error không được forward exception có path hoặc SDK state. */
    () => { failed = true; });
  child.stdout.on('data',
    /** Param: chunk — stdout SDK không credential, giữ tối đa128KiB rồi tiếp tục drain mà cấm PASS. */
    (chunk) => { bytes += chunk.length; if (bytes <= 131_072) output += chunk.toString('utf8'); else failed = true; });
  child.stderr.on('data', /** Stderr vẫn drain để tránh pipe blocked, không giữ diagnostic ngoài scope. */ () => {});
  const terminal = await new Promise(/** Param: resolve — completion chỉ từ raw close sau exit và pipes. */
    (resolve) => child.once('close', resolve));
  (runtime.clearTimeout ?? clearTimeout)(timer);
  const completed = now();
  assert.ok(spawned && !failed && terminal === 0 && Number.isFinite(completed) &&
    completed >= started && completed < started + limit, 'NETWORK_SDK_COMMAND_FAILED');
  return output;
}

/**
 * Bind canary HTTP với deadline và raw listener/socket ownership, không mở auth hoặc DB.
 * Input
 * Param: runtime — trusted createServer/timers/onOwned cho host test, CLI dùng Node HTTP thật.
 * Output: healthy/close/terminal owner sau listening, hoặc failure sau raw terminal khi bind lỗi.
 * Errors: fixed failure, timer/abort chỉ khởi động close và không tự cấp terminal ACK.
 */
export async function startProbeUpstream(runtime = {}) {
  const sockets = new Set();
  const unavailable = new AbortController();
  const schedule = runtime.setTimeout ?? setTimeout;
  const cancel = runtime.clearTimeout ?? clearTimeout;
  const now = runtime.now ?? performance.now.bind(performance);
  let finish; let stopping = false; let failed = false; let listenerClosed = false; let timer;
  const terminal = new Promise(/** Param: resolve — chỉ raw listener close và mọi socket close mới hoàn tất owner. */
    (resolve) => { finish = resolve; });
  const server = (runtime.createServer ?? http.createServer)(
    /** Param: request/response — GET/me canary fixed không credential, không truy vấn hoặc mutation DB. */
    (request, response) => {
      if (request.method !== 'GET' || request.url !== '/api/v1/me' || request.headers.authorization || request.headers.cookie) {
        failed = true; response.writeHead(400, { Connection: 'close' }); response.end(); return;
      }
      response.writeHead(401, { 'Content-Type': 'application/json', Connection: 'close' });
      response.end('{"error":{"code":"AUTH_REQUIRED"}}');
    });

  /** Chốt raw terminal sau các event close thật, không suy từ close intent hay ERR_SERVER_NOT_RUNNING. */
  function finishIfClosed() {
    if (listenerClosed && sockets.size === 0) finish();
  }

  /** Output: completion của same raw owner, literal true chỉ khi shutdown không gặp lỗi. */
  function close() {
    if (!stopping) {
      stopping = true; unavailable.abort(); cancel(timer);
      for (const socket of sockets) socket.destroy();
      try {
        server.close(/** Param: error — callback không thay event close, lỗi vẫn phải giữ raw terminal. */
          (error) => { if (error && error.code !== 'ERR_SERVER_NOT_RUNNING') failed = true; });
      } catch { failed = true; }
    }
    return terminal.then(/** Output: socket/listener đều đã terminal, sticky fault cấm cleanup PASS. */
      () => !failed);
  }

  server.on('connection', /** Param: socket — chỉ giữ connection do canary listener này accept. */
    (socket) => {
      sockets.add(socket);
      socket.on('error', /** Raw socket error được drain qua close, không forward diagnostics. */ () => {});
      socket.once('close', /** Nhả registry theo close event của chính connection đó. */
        () => { sockets.delete(socket); finishIfClosed(); });
      if (stopping) socket.destroy();
    });
  server.on('close', /** Listener tự đóng ngoài owner request là fault, vẫn giữ raw terminal. */
    () => { listenerClosed = true; if (!stopping) { failed = true; void close(); } finishIfClosed(); });
  server.on('error', /** Lỗi bind/runtime khóa admission và yêu cầu owned close. */
    () => { failed = true; void close(); });
  const owner = { terminal, close, healthy: /** Output: availability của same owned canary endpoint. */
    () => !failed && !stopping && server.listening === true };
  try {
    assert.equal(runtime.onOwned?.(owner), undefined);
    const ready = once(server, 'listening', { signal: unavailable.signal });
    ready.catch(/** Gắn observer trước listen/abort để rejection nhanh không bị unhandled. */ () => {});
    const started = now();
    assert.ok(Number.isFinite(started) && started >= 0);
    timer = schedule(/** Deadline chủ động cancel bind, catch vẫn await raw owner terminal. */
      () => { failed = true; void close(); }, 10_000);
    assert.ok(!stopping);
    server.listen(3000, '127.0.0.1');
    await ready;
    const completed = now();
    assert.ok(owner.healthy() && Number.isFinite(completed) && completed >= started && completed < started + 10_000);
    cancel(timer);
    return owner;
  } catch {
    void close(); await terminal;
    throw new Error('NETWORK_UPSTREAM_BIND_FAILED');
  }
}

/**
 * Dựng canary synthetic loopback và quan sát baseline/off/restored trên native engine, không DB/auth fixture.
 * Input
 * Param: mode — fixed modem/guest API24 hoặc api36 trên Pixel_7; guest chỉ baseline11/airplane0.
 * Output: MODEM fault enum sau restore và owned proxy/upstream cleanup.
 * Errors: fixed boundary, không dùng feasibility result làm UI offline acceptance.
 */
export async function runNativeNetworkProbe(mode = 'modem') {
  assert.ok(mode === 'modem' || mode === 'guest' || mode === 'api36');
  const root = process.cwd();
  const guestMode = mode === 'guest' || mode === 'api36';
  const expectedAvd = mode === 'api36' ? 'Pixel_7' : 'Nexa_Auth_API24';
  const expectedApi = mode === 'api36' ? '36' : '24';
  const outcomePrefix = mode === 'api36' ? 'NETWORK_API36_GUEST_ROUTE_' :
    mode === 'guest' ? 'NETWORK_GUEST_ROUTE_' : 'NETWORK_MODEM_ROUTE_';
  let guest;
  let materials; let proxy; let upstream;
  let count = 0; let result; let passed = false; let stage = 'INVENTORY';
  let bindTimer; let bindExpired = false;
  const capture = createHttpMetadataCapture({ onEvent:
    /** Metadata consumer đồng bộ, chỉ capture snapshot dùng để so canary, không giữ request body. */ () => {} });
  try {
    const name = await runSdk(adb, ['-s', device, 'emu', 'avd', 'name'], root);
    assert.ok(name.split(/\r?\n/).some(
      /** Param: line — console Windows có thể dùng CRCRLF, trim framing trước đối chiếu exact AVD name. */
      (line) => line.trim() === expectedAvd));
    if (guestMode) {
      assert.equal((await runSdk(adb, ['-s', device, 'shell', 'getprop', 'ro.build.version.sdk'], root)).trim(), expectedApi);
      // Flag wifi_on/help không chứng minh shell được phép đổi Wi-Fi; thiếu proof phải dừng trước cert/port/fault.
      stage = 'SHELL_WIFI_PERMISSION_NOT_PROVEN';
      requireShellWifiPermission(await runSdk(adb, ['-s', device, 'shell', 'dumpsys', 'package', 'com.android.shell'], root));
      stage = 'GUEST_BASELINE';
      guest = createGuestNetworkControl({ commandMode: mode === 'api36' ? 'cmd' : 'svc', execute:
        /** Param: args/limit — adapter chỉ cấp fixed svc/cmd/settings argv, original SDK phải terminal trước settle. */
        (args, limit) => runSdk(adb, ['-s', device, ...args], root, limit) });
      assert.equal(await guest.readState(), 'enabled');
    }
    materials = createCertificates();
    const publicCertificate = new X509Certificate(materials.valid.certificate).raw.toString('base64');
    stage = 'UPSTREAM';
    upstream = await startProbeUpstream({ onOwned:
      /** Param: owner — registry trước bind, finally phải giữ same upstream raw terminal khi setup lỗi. */
      (owner) => { upstream = owner; } });
    stage = 'TLS';
    const bindStarted = performance.now();
    bindTimer = setTimeout(/** Đánh thức original proxy bind bằng close/AbortSignal, không coi timer là raw terminal. */
      () => { bindExpired = true; if (proxy) void proxy.close(); }, 10_000);
    proxy = await startLocalHttpsProxy(materials.valid, {}, undefined, { httpMetadata: capture,
      onOwned: /** Param: owner — giữ raw proxy capability trước async bind để finally cleanup cả bind error. */
        (owner) => { proxy = owner; if (bindExpired) void proxy.close(); } });
    clearTimeout(bindTimer); bindTimer = undefined;
    assert.ok(!bindExpired && performance.now() - bindStarted < 10_000);
    for (const material of Object.values(materials)) material.pfx.fill(0);
    result = await verifyNetworkRoute({
      ...(guest ?? {}),
      readState: /** Output: baseline/readback enum của cùng emulator đã pin. */ async () => {
        if (guest) return guest.readState();
        const output = await runSdk(adb, ['-s', device, 'emu', 'gsm', 'status'], root);
        return parseGsmDataState(output);
      },
      setState: /** Param: state — off hoặc saved enum, ACK và raw terminal đều bắt buộc trước stage kế. */ async (state) => {
        if (guest) {
          stage = state === 'off' ? 'GUEST_OFF' : 'GUEST_RESTORE';
          await guest.setState(state);
          console.log('NETWORK_GUEST_STATE_CONFIRMED_' + state.toUpperCase());
          return;
        }
        assert.ok(state === 'off' || dataStates.includes(state));
        stage = state === 'off' ? 'MODEM_OFF' : 'MODEM_RESTORE';
        const output = await runSdk(adb, ['-s', device, 'emu', 'gsm', 'data', state], root);
        assert.ok(/(?:^|\n)OK\s*$/.test(output));
        console.log('NETWORK_MODEM_DATA_COMMAND_ACK_' + state.toUpperCase());
      },
      probe: /** Output: native enum sau framework exit0 và proxy idle, không suy network từ GSM ACK. */ async () => {
        stage = 'NATIVE_ROUTE_PROBE';
        const before = proxy.httpSnapshot();
        const output = await runSdk('C:/src/flutter/bin/cache/dart-sdk/bin/dart.exe', [
          '--packages=C:/src/flutter/packages/flutter_tools/.dart_tool/package_config.json',
          'C:/src/flutter/bin/cache/flutter_tools.snapshot', '--suppress-analytics', 'test', '--no-pub', '--no-uninstall',
          'integration_test/native_network_probe_test.dart', '-d', device, '--reporter', 'expanded',
          '--dart-define=AUTH_LAB_CA_CERT=' + publicCertificate,
        ], root + '/mobile', 360_000);
        const observations = [...output.matchAll(/NATIVE_NETWORK_PROBE_(REACHABLE|UNAVAILABLE)/g)];
        assert.ok(observations.length === 1 && output.includes('All tests passed!'));
        const route = observations[0][1];
        const failures = [...output.matchAll(/NATIVE_NETWORK_FAILURE_(SOCKET|TIMEOUT)/g)];
        assert.ok(route === 'REACHABLE' ? failures.length === 0 : failures.length === 1);
        const deadline = performance.now() + 5_000;
        while (proxy.httpSnapshot().rawActive || proxy.httpSnapshot().active) {
          assert.ok(performance.now() < deadline);
          await new Promise(/** Param: resolve — poll raw transport terminal riêng với native SDK completion. */
            (resolve) => setTimeout(resolve, 25));
        }
        const after = proxy.httpSnapshot();
        const delta = route === 'REACHABLE' ? 1 : 0;
        assert.ok(upstream.healthy() && after.healthy && !after.sealed && after.proxyAvailable && after.incomplete === 0 &&
          after.requests === before.requests + delta && after.statuses === after.requests && after.closed === after.requests &&
          after.byKind.PROFILE_READ === after.requests);
        count++;
        console.log(JSON.stringify({ kind: 'NATIVE_NETWORK_ROUTE_OBSERVED', probe: count, route,
          failureKind: failures[0]?.[1] ?? 'NONE',
          requests: after.requests, statuses: after.statuses, closed: after.closed, incomplete: after.incomplete }));
        return route;
      },
    });
    passed = true;
  } catch {
    console.error(outcomePrefix + 'PROBE_FAILED_STAGE_' + stage);
  } finally {
    clearTimeout(bindTimer);
    for (const material of Object.values(materials ?? {})) material.pfx.fill(0);
    if (proxy) {
      const bounded = await proxy.close();
      await proxy.terminal;
      if (bounded !== true) passed = false;
    }
    if (upstream) {
      const closed = await upstream.close();
      await upstream.terminal;
      if (closed !== true) passed = false;
    }
  }
  assert.ok(passed, 'NETWORK_MODEM_PROBE_FAILED');
  console.log(outcomePrefix + result);
  return result;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    const modes = { '--modem-feasibility': 'modem', '--guest-feasibility': 'guest', '--api36-guest-feasibility': 'api36' };
    assert.ok(process.argv.length === 3 && Object.hasOwn(modes, process.argv[2]));
    const result = await runNativeNetworkProbe(modes[process.argv[2]]);
    process.exitCode = result === 'EFFECTIVE' ? 0 : 2;
  } catch {
    console.error('NETWORK_MODEM_PROBE_FAILED'); process.exitCode = 1;
  }
}
