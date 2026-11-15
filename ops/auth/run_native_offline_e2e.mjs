import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { pathToFileURL } from 'node:url';
import { startFixture, assertNativePid, verifyHostNoCa } from './run_native_e2e.mjs';
import { createCertificates } from './memory_tls_material.mjs';
import { startLocalHttpsProxy } from './local_https_proxy.mjs';
import { createHttpMetadataCapture } from './http_metadata_capture.mjs';
import { createGuestNetworkControl, requireShellWifiPermission } from './native_guest_network_control.mjs';
import { runSdk } from './run_native_network_probe.mjs';
import { orchestrateNativeOffline } from './native_offline_orchestration.mjs';

const adb = 'C:/Users/LENOVO/AppData/Local/Android/sdk/platform-tools/adb.exe';
const device = 'emulator-5554';

/**
 * Chạy main-engine offline với fixture DB thật trên đúng Pixel_7/API36 đã có capability proof.
 * Input
 * Param: runtime — trusted adapters cho host test, actual CLI dùng SDK/DB/proxy thật.
 * Output: PID sau UI offline/recovery/A-B/logout và cleanup, không trả credentials.
 * Errors: fixed failure khi AVD/permission/baseline sai, không sửa host network hoặc role ngoài fixture.
 */
export async function runActualOffline(runtime = {}) {
  const root = process.cwd();
  const execute = runtime.execute ??
    /** Param: args/limit — fixed AVD SDK argv, drain original child trước return. */
    ((args, limit) => runSdk(adb, ['-s', device, ...args], root, limit));
  (runtime.phaseRuntime?.checkPid ?? assertNativePid)(null);
  const name = await execute(['emu', 'avd', 'name'], 10_000);
  assert.ok(name.split(/\r?\n/).some(/** Param: line — console framing, chỉ chấp nhận exact owned AVD. */
    (line) => line.trim() === 'Pixel_7'));
  assert.equal((await execute(['shell', 'getprop', 'ro.build.version.sdk'], 10_000)).trim(), '36');
  requireShellWifiPermission(await execute(['shell', 'dumpsys', 'package', 'com.android.shell'], 10_000));
  const network = createGuestNetworkControl({ execute, commandMode: 'cmd' });
  return orchestrateNativeOffline({
    createFixture:
      /** Param: password/secrets/onClosing — private pipe RAM và synchronous original STOP hook. */
      (password, secrets, onClosing) => startFixture(password, 'offline-login', secrets,
        runtime.spawnFixtureProcess ?? spawn, onClosing),
    createCertificates,
    startProxy:
      /** Param: material/B/observe/onOwned — pin exact detail B và registry trước async bind. */
      (material, workspaceId, observe, onOwned) => {
        const httpMetadata = createHttpMetadataCapture({ targetWorkspaceId: workspaceId, onEvent: observe });
        return startLocalHttpsProxy(material, {}, undefined, { ...runtime.proxyRuntime, httpMetadata, onOwned });
      },
    verifyHostNoCa, network, ...runtime,
  });
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    assert.ok(process.argv.length === 3 && process.argv[2] === '--offline', 'NATIVE_OFFLINE_ARGUMENTS_INVALID');
    await runActualOffline();
    console.log('NATIVE_OFFLINE_ACTUAL_OWNED_TERMINAL_PASS');
  } catch {
    console.error('NATIVE_OFFLINE_ACTUAL_FAILED'); process.exitCode = 1;
  }
}
