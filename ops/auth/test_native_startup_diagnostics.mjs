import assert from 'node:assert/strict';
import { createNativeStartupDiagnostics } from './native_startup_diagnostics.mjs';

let clock = 100;
const probe = createNativeStartupDiagnostics(() => clock);
const owner = 'aaaaaaaa-1111-4111-8111-111111111111';
const secret = 'Aa1' + 'f'.repeat(32);
const uri = 'http://127.0.0.1:9999/PRIVATE_DEBUG_TOKEN/';
probe.message({ event: 'app.start', params: { appId: owner } }, owner);
clock += 20;
probe.rawLine(JSON.stringify([{ event: 'app.log', params: { appId: 'other', log: 'NATIVE_AUTH_TEST_CHANNEL_READY' } }]));
probe.message({ event: 'app.log', params: { appId: 'other', log: 'NATIVE_AUTH_TEST_CHANNEL_READY Error initializing DevFS' } }, owner);
assert.equal(probe.snapshot().ownedMarkerSeen, false); assert.deepEqual(probe.snapshot().tags, []);
clock += 10;
probe.message({ event: 'app.log', params: { appId: owner, log: 'NATIVE_AUTH_TEST_CHANNEL_READY' } }, owner);
probe.stderr('Error initial'); probe.stderr('izing DevFS ' + uri + secret);
probe.message({ event: 'app.log', params: { appId: owner, log: 'TimeoutException after 0:01:00.000000: Future not completed ' + secret } }, owner);
clock += 60;
probe.message({ event: 'app.stop', params: { appId: owner, error: { trace: uri + secret } } }, owner);
probe.exit(3, null); clock += 1; probe.pipesClosed();
const result = probe.snapshot();
assert.equal(result.sdkExitKind, 'CODE_3'); assert.equal(result.stopErrorField, 'PRESENT');
assert.equal(result.rawMarkerSeen, true); assert.equal(result.ownedMarkerSeen, true);
assert.equal(result.sdkPipesClosed, true);
assert.ok(result.tags.includes('DEVFS_FAILURE')); assert.ok(result.tags.includes('SIXTY_SECOND_TIMEOUT'));
assert.deepEqual(result.receiptMs, { appStart: 0, appStarted: null, rawMarker: 20, ownedMarker: 30, appStop: 90, sdkExit: 90 });
assert.equal(JSON.stringify(result).includes(secret), false); assert.equal(JSON.stringify(result).includes(uri), false);
assert.equal(JSON.stringify(result).includes('trace'), false);
for (const [code, signal, expected] of [[0, null, 'CODE_0'], [1, null, 'CODE_1'], [2, null, 'CODE_2'],
  [-1073740791, null, 'OTHER_CODE'], [null, 'SIGTERM', 'SIGNAL']]) {
  const diag = createNativeStartupDiagnostics(() => 0); diag.exit(code, signal);
  diag.message({ event: 'app.log', params: { appId: owner, log: uri + secret } }, owner);
  assert.equal(diag.snapshot().sdkExitKind, expected);
  assert.equal(JSON.stringify(diag.snapshot()).includes(secret), false);
  assert.equal(JSON.stringify(diag.snapshot()).includes(uri), false);
}
const late = createNativeStartupDiagnostics(() => clock);
late.exit(0, null); clock += 10;
late.message({ event: 'app.log', params: { appId: owner, log: 'NATIVE_AUTH_TEST_CHANNEL_READY' } }, owner);
assert.equal(late.snapshot().receiptMs.sdkExit, 0); assert.equal(late.snapshot().receiptMs.ownedMarker, 10);
late.clear();
console.log('NATIVE_STARTUP_DIAGNOSTICS_REDACTION_OWNERSHIP_ORDER_PASS');
