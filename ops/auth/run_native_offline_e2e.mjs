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
  const fixtureScenario = runtime.seedExpiredSession === true ? 'offline-expired' : 'offline-login';
  const execute = runtime.execute ??
    /** Param: args/limit — fixed AVD SDK argv, drain original child trước return. */
    ((args, limit) => runSdk(adb, ['-s', device, ...args], root, limit));
  (runtime.phaseRuntime?.checkPid ?? assertNativePid)(null);
  const name = await execute(['emu', 'avd', 'name'], 10_000);
  assert.ok(name.split(/\r?\n/).some(/** Param: line — console framing, chỉ chấp nhận exact owned AVD. */
    (line) => line.trim() === 'Pixel_7'));
  assert.equal((await execute(['shell', 'getprop', 'ro.build.version.sdk'], 10_000)).trim(), '36');
  // Offline E2E cần trạng thái thiết bị riêng; chỉ xóa dữ liệu package app trên AVD đã pin, không chạm thiết bị khác.
  assert.equal((await execute(['shell', 'pm', 'clear', 'dev.nexa.nexa_iot'], 10_000)).trim(), 'Success',
    'NATIVE_OFFLINE_APP_RESET_FAILED');
  requireShellWifiPermission(await execute(['shell', 'dumpsys', 'package', 'com.android.shell'], 10_000));
  const network = createGuestNetworkControl({ execute, commandMode: 'cmd' });
  return orchestrateNativeOffline({
    createFixture:
      /** Param: password/secrets/onClosing/token — private pipe RAM và token chỉ cho insert fixture expired. */
      (password, secrets, onClosing, expiredSessionToken) => startFixture(password, fixtureScenario, secrets,
        runtime.spawnFixtureProcess ?? spawn, onClosing, expiredSessionToken),
    createCertificates,
    startProxy:
      /** Param: material/B/observe/onOwned — pin exact detail B và registry trước async bind. */
      (material, workspaceId, observe, onOwned) => {
        const httpMetadata = createHttpMetadataCapture({ targetWorkspaceId: workspaceId, onEvent:
          /** Chỉ phân loại oracle reject bằng enum/counter, không phát URL, header, body hoặc credential.
           * Input
           * Param: event — metadata bounded của HTTP capture do proxy sở hữu.
           */
          (event) => {
            try { return observe(event); } catch {
              const eventKind = ['REQUEST', 'STATUS', 'CLOSED'].includes(event?.event) ? event.event : 'OTHER';
              const requestKind = ['AUTH_LOGIN', 'PROFILE_READ', 'WORKSPACE_LIST', 'WORKSPACE_DETAIL',
                'PASSWORD_CHANGE', 'AUTH_LOGOUT', 'OTHER'].includes(event?.kind) ? event.kind : 'OTHER';
              const status = Number.isInteger(event?.status) && event.status >= 200 && event.status <= 599
                ? event.status : 'NONE';
              console.error(`NATIVE_OFFLINE_HTTP_ORACLE_REJECTED_${eventKind}_${requestKind}_${status}`);
              throw new Error('NATIVE_OFFLINE_HTTP_ORACLE_REJECTED');
            }
          } });
        return startLocalHttpsProxy(material, {}, undefined, { ...runtime.proxyRuntime, httpMetadata, onOwned });
      },
    verifyHostNoCa, network, ...runtime,
  });
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    assert.ok(process.argv.length === 3 && ['--offline', '--offline-expired'].includes(process.argv[2]),
      'NATIVE_OFFLINE_ARGUMENTS_INVALID');
    const expired = process.argv[2] === '--offline-expired';
    await runActualOffline({ seedExpiredSession: expired });
    console.log(expired ? 'NATIVE_OFFLINE_EXPIRED_ACTUAL_OWNED_TERMINAL_PASS' : 'NATIVE_OFFLINE_ACTUAL_OWNED_TERMINAL_PASS');
  } catch {
    console.error('NATIVE_OFFLINE_ACTUAL_FAILED'); process.exitCode = 1;
  }
}
