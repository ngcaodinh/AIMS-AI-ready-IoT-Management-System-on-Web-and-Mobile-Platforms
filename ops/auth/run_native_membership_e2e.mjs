import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { pathToFileURL } from 'node:url';
import { startFixture, assertNativePid, verifyHostNoCa } from './run_native_e2e.mjs';
import { createCertificates } from './memory_tls_material.mjs';
import { startLocalHttpsProxy } from './local_https_proxy.mjs';
import { createHttpMetadataCapture } from './http_metadata_capture.mjs';
import { orchestrateNativeMembership } from './native_membership_orchestration.mjs';

/**
 * Nối các factory đã có vào một actual membership run, không nhận secrets/configuration từ CLI.
 * Input
 * Param: runtime — trusted OS/SDK boundaries cho host tests, actual CLI luôn dùng defaults.
 * Output: own PID sau native UI/H2/session/audit và original cleanup terminals.
 * Errors: fixed orchestration failure, không thay DB target hoặc retry mutation unknown.
 */
export async function runActualMembership(runtime = {}) {
  const checkPid = runtime.phaseRuntime?.checkPid ?? assertNativePid;
  checkPid(null);
  return orchestrateNativeMembership({
    createFixture:
      /**
       * Giữ original TTL20phút và pre-STOP hook, credential chỉ private pipe.
       * Input
       * Param: password — CSPRNG TEST chỉ RAM của coordinator.
       * Param: secrets — shared scanner giữ credential tới owned terminal.
       * Param: onClosing — synchronous external abort trước original STOP.
       */
      (password, secrets, onClosing) => startFixture(password, 'membership-stale', secrets,
        runtime.spawnFixtureProcess ?? spawn, onClosing),
    createCertificates,
    startProxy:
      /**
       * Chỉ capture first-line metadata với pinned B, không thêm payload/header observer.
       * Input
       * Param: material — TLS material RAM vừa tạo.
       * Param: workspaceId — UUID B do original fixture target resolver pin.
       * Param: onEvent — strict H2 oracle đồng bộ của same run.
       * Param: onOwned — nhận raw proxy owner trước async bind để cleanup cả setup failure.
       */
      (material, workspaceId, onEvent, onOwned) => {
        const httpMetadata = createHttpMetadataCapture({ targetWorkspaceId: workspaceId, onEvent });
        return startLocalHttpsProxy(material, {}, undefined, { ...runtime.proxyRuntime, httpMetadata, onOwned });
      },
    verifyHostNoCa,
    ...runtime,
  });
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    // Intent literal riêng để import hoặc nhầm arguments không tự tạo fixture/mutation.
    assert.ok(process.argv.length === 3 && process.argv[2] === '--stale', 'NATIVE_MEMBERSHIP_ARGUMENTS_INVALID');
    await runActualMembership();
    console.log('NATIVE_MEMBERSHIP_ACTUAL_OWNED_TERMINAL_PASS');
  } catch {
    console.error('NATIVE_MEMBERSHIP_ACTUAL_FAILED');
    process.exitCode = 1;
  }
}
