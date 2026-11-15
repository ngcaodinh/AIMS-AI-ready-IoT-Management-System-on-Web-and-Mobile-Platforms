import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { createHttpMetadataControl, parseObservedProxyArguments } from './http_metadata_control.mjs';

/**
 * Tạo stdout/control giả có ACK sync hoặc pending để kiểm ownership writer và framing.
 * Input
 * Param: pending — giữ write callback tới khi case chủ động release.
 * Output: controller, data snapshot và fake output boundary không I/O.
 */
function setup(pending = false) {
  const lines = [];
  const callbacks = [];
  let stops = 0;
  const output = new EventEmitter();
  output.write =
    /** Nhận bytes metadata synthetic và giữ callback theo mode.
     * Input
     * Param: line — JSON line đã lọc do controller xuất.
     * Param: callback — ACK write do controller sở hữu tới completion.
     */
    (line, callback) => {
      lines.push(line);
      if (pending) callbacks.push(callback); else callback();
      return true;
    };
  const snapshot = { healthy: true, sealed: false, sequence: 0, elapsedMilliseconds: 0,
    rawOpened: 0, rawActive: 0, opened: 0, active: 0, requests: 0, statuses: 0,
    closed: 0, incomplete: 0, byKind: { AUTH_LOGIN: 0, PROFILE_READ: 0, WORKSPACE_LIST: 0,
      WORKSPACE_DETAIL: 0, PASSWORD_CHANGE: 0, AUTH_LOGOUT: 0, OTHER: 0 },
    proxyAvailable: true };
  const control = createHttpMetadataControl({ output,
    snapshot: /** Chỉ đưa snapshot copy public để controller không thể sửa fixture gốc. Output: snapshot cùng category copy. */ () => ({ ...snapshot, byKind: { ...snapshot.byKind } }),
    stop: /** Chốt số yêu cầu shutdown, không giả proxy đã terminal. */ () => { stops++; } });
  return { control, output, lines, callbacks, snapshot,
    stops: /** Đọc count hiện hành để kiểm stop idempotent. Output: số yêu cầu shutdown. */ () => stops };
}

/** Kiểm CLI chỉ mở observed mode và target UUID khi flag theo đúng allowlist. */
function verifyArguments() {
  assert.equal(parseObservedProxyArguments([]), null);
  assert.deepEqual(parseObservedProxyArguments(['--observe-http']), {});
  const uuid = '11111111-1111-4111-8111-111111111111';
  assert.deepEqual(parseObservedProxyArguments(['--observe-http', '--target-workspace=' + uuid]), { targetWorkspaceId: uuid });
  for (const args of [['--observe-http','extra'], ['--target-workspace=' + uuid],
    ['--observe-http','--target-workspace=PRIVATE_SENTINEL'], ['--observe-http','--observe-http']]) {
    assert.throws(/** Argument sai không được phản chiếu vào lỗi. */
      () => parseObservedProxyArguments(args), /INVALID_PROXY_ARGUMENTS/);
  }
  console.log('HTTP_CONTROL_ARGUMENT_ALLOWLIST_PASS');
}

/** Kiểm fragmented/multi-frame/CRLF, event sequencing và final fence sau terminal. */
async function verifyFrames() {
  const test = setup();
  test.control.onInput(Buffer.from('STA'));
  assert.equal(test.lines.length, 0);
  test.control.onInput(Buffer.from('TUS\r\nSTATUS\n'));
  assert.equal(test.lines.length, 2);
  assert.deepEqual(test.lines.map(
    /** Snapshot metadata được gửi tuần tự theo frame ID riêng.
     * Input
     * Param: line — JSON line controller đã gửi vào fake output.
     * Output: frame ordinal dùng kiểm thứ tự.
     */
    (line) => JSON.parse(line).frameSequence), [1, 2]);
  test.control.publish({ event:'REQUEST', sequence:1, elapsedMilliseconds:1, requestId:1, kind:'AUTH_LOGIN', matchesTarget:false });
  test.snapshot.sequence = 1; test.snapshot.elapsedMilliseconds = 1;
  test.snapshot.rawOpened = 1; test.snapshot.opened = 1; test.snapshot.active = 1;
  test.snapshot.requests = 1; test.snapshot.byKind.AUTH_LOGIN = 1;
  test.control.onInput(Buffer.from('STATUS\nSTOP\nSTATUS\n'));
  assert.equal(test.stops(), 1);
  assert.equal(test.lines.length, 4);
  test.control.onEnd();
  assert.equal(test.stops(), 1);
  test.control.publish({ event:'CLOSED',sequence:2,elapsedMilliseconds:2,requestId:1,kind:'AUTH_LOGIN',matchesTarget:false,requestObserved:true,statusObserved:false });
  test.snapshot.sequence = 2; test.snapshot.elapsedMilliseconds = 2;
  test.snapshot.active = 0; test.snapshot.closed = 1; test.snapshot.incomplete = 1;
  test.snapshot.proxyAvailable = false; test.snapshot.sealed = true;
  await test.control.finish();
  const final = JSON.parse(test.lines.at(-2));
  assert.equal(test.lines.at(-1), 'LOCAL_HTTPS_PROXY_STOPPED\n');
  assert.equal(final.frame, 'FINAL');
  assert.equal(final.snapshot.incomplete, 1);
  assert.equal(final.snapshot.active, 0);
  assert.equal(final.snapshot.sealed, true);
  assert.equal(test.control.failed, false);
  console.log('HTTP_CONTROL_SPLIT_FRAMES_ORDER_AND_FINAL_PASS');
}

/** Kiểm malformed/oversize/partial EOF, unsafe field và sequence gap đều fail-closed. */
async function verifyFaults() {
  for (const bytes of ['BAD\n', 'STATUSX\n', 'S'.repeat(17), 'STATUS\rX\n', '\xff\n']) {
    const test = setup();
    test.control.onInput(Buffer.from(bytes, 'latin1'));
    assert.equal(test.control.failed, true);
    assert.equal(test.stops(), 1);
    assert.equal(test.lines.length, 0);
    await assert.rejects(test.control.finish(), /HTTP_METADATA_CONTROL_FAILED/);
  }
  const partial = setup(); partial.control.onInput(Buffer.from('STA')); partial.control.onEnd();
  assert.equal(partial.control.failed, true);
  await assert.rejects(partial.control.finish(), /HTTP_METADATA_CONTROL_FAILED/);
  for (const event of [
    { event:'REQUEST',sequence:2,elapsedMilliseconds:1,requestId:1,kind:'AUTH_LOGIN',matchesTarget:false },
    { event:'REQUEST',sequence:1,elapsedMilliseconds:1,requestId:1,kind:'AUTH_LOGIN',matchesTarget:false,body:'PRIVATE_SENTINEL' },
    { event:'STATUS',sequence:1,elapsedMilliseconds:1,requestId:1,kind:'OTHER',matchesTarget:false,status:100 },
  ]) {
    const test = setup();
    assert.throws(/** Metadata bất thường không được stringify vào stdout. */
      () => test.control.publish(event), /HTTP_METADATA_CONTROL_FAILED/);
    assert.equal(test.lines.join('').includes('PRIVATE_SENTINEL'), false);
    assert.equal(test.control.failed, true);
    await assert.rejects(test.control.finish(), /HTTP_METADATA_CONTROL_FAILED/);
  }
  const inconsistent = setup(); inconsistent.snapshot.rawActive = 1;
  inconsistent.control.onInput(Buffer.from('STATUS\n'));
  assert.equal(inconsistent.control.failed, true);
  assert.equal(inconsistent.lines.length, 0);
  await assert.rejects(inconsistent.control.finish(), /HTTP_METADATA_CONTROL_FAILED/);
  console.log('HTTP_CONTROL_PROTOCOL_SCHEMA_AND_SEQUENCE_FAULT_PASS');
}

/** Kiểm callback write còn pending, backpressure và EPIPE giữ shutdown và failure tới actual ACK. */
async function verifyWriter() {
  const pending = setup(true);
  pending.control.onInput(Buffer.from('STATUS\n'));
  pending.snapshot.sealed = true; pending.snapshot.proxyAvailable = false;
  let done = false;
  const finish = pending.control.finish().then(/** Chỉ đổi cờ sau tất cả owned write ACK. */ () => { done = true; });
  await Promise.resolve(); await Promise.resolve();
  assert.equal(done, false);
  while (pending.callbacks.length) pending.callbacks.shift()();
  await finish;
  assert.equal(done, true);
  for (const mode of ['backpressure','epipe','callback-error']) {
    const test = setup(mode === 'callback-error');
    if (mode === 'backpressure') test.output.write =
      /** Stdout backpressure phải chốt failure dù callback đã ACK đồng bộ.
       * Input
       * Param: line — frame synthetic, không cần xử lý trong fault này.
       * Param: callback — write ACK được gọi trước khi báo backpressure.
       * Output: false để mô phỏng Writable đã đầy.
       */
      (line, callback) => { callback(); return false; };
    if (mode === 'epipe') test.output.emit('error', Error('PRIVATE_SENTINEL'));
    else test.control.onInput(Buffer.from('STATUS\n'));
    if (mode === 'callback-error') test.callbacks.shift()(Error('PRIVATE_SENTINEL'));
    assert.equal(test.control.failed, true);
    assert.equal(test.stops(), 1);
    await assert.rejects(test.control.finish(), /HTTP_METADATA_CONTROL_FAILED/);
  }
  console.log('HTTP_CONTROL_WRITE_ACK_BACKPRESSURE_EPIPE_PASS');
}


/** Kiểm bounded receipts/frame budget và FINAL chỉ là provisional khi write ACK còn lỗi. */
async function verifyLimitsAndFinalFailure() {
  const pending = setup(true);
  for (let index = 0; index < 65; index++) pending.control.onInput(Buffer.from('STATUS\n'));
  assert.equal(pending.control.failed, true);
  assert.equal(pending.lines.length, 64);
  assert.equal(pending.stops(), 1);
  const completion = pending.control.finish();
  const rejected = assert.rejects(completion, /HTTP_METADATA_CONTROL_FAILED/);
  while (pending.callbacks.length) pending.callbacks.shift()();
  await rejected;

  const capped = setup();
  for (let index = 0; index < 4097; index++) capped.control.onInput(Buffer.from('STATUS\n'));
  assert.equal(capped.control.failed, true);
  assert.equal(capped.lines.length, 4096);
  assert.equal(capped.stops(), 1);
  await assert.rejects(capped.control.finish(), /HTTP_METADATA_CONTROL_FAILED/);

  const finalFault = setup(true);
  finalFault.snapshot.sealed = true; finalFault.snapshot.proxyAvailable = false;
  const finalCompletion = finalFault.control.finish();
  const finalRejected = assert.rejects(finalCompletion, /HTTP_METADATA_CONTROL_FAILED/);
  assert.equal(JSON.parse(finalFault.lines[0]).frame, 'FINAL');
  finalFault.callbacks.shift()(Error('PRIVATE_SENTINEL'));
  while (finalFault.callbacks.length) finalFault.callbacks.shift()();
  await finalRejected;
  assert.equal(finalFault.control.failed, true);
  assert.equal(finalFault.stops(), 1);

  const repeated = setup();
  repeated.snapshot.sealed = true; repeated.snapshot.proxyAvailable = false;
  const first = repeated.control.finish();
  assert.equal(repeated.control.finish(), first);
  await first;
  assert.equal(repeated.lines.length, 2);
  console.log('HTTP_CONTROL_PENDING_FRAME_CAP_AND_PROVISIONAL_FINAL_PASS');
}

/** Kiểm counter/event fence cùng monotonic clock không bị reset hoặc counter đúng một phần vượt qua. */
async function verifySnapshotFences() {
  for (const fault of ['sequence-total', 'category-total', 'raw-owner', 'clock', 'extra-field', 'unsealed-final']) {
    const test = setup();
    if (fault === 'sequence-total') { test.snapshot.rawOpened = 1; test.snapshot.opened = 1; test.snapshot.closed = 1; }
    if (fault === 'category-total') test.snapshot.byKind.AUTH_LOGIN = 1;
    if (fault === 'raw-owner') test.snapshot.rawActive = 1;
    if (fault === 'clock') test.snapshot.elapsedMilliseconds = -1;
    if (fault === 'extra-field') test.snapshot.body = 'PRIVATE_SENTINEL';
    if (fault !== 'unsealed-final') {
      test.control.onInput(Buffer.from('STATUS\n'));
      assert.equal(test.control.failed, true, 'SNAPSHOT_FAULT_MUST_FAIL_BEFORE_FINAL');
      assert.equal(test.lines.length, 0);
    }
    await assert.rejects(test.control.finish(), /HTTP_METADATA_CONTROL_FAILED/);
    assert.equal(test.control.failed, true);
    assert.equal(test.lines.join('').includes('PRIVATE_SENTINEL'), false);
  }
  const rollback = setup();
  rollback.snapshot.elapsedMilliseconds = 2;
  rollback.control.onInput(Buffer.from('STATUS\n'));
  rollback.snapshot.elapsedMilliseconds = 1;
  rollback.control.onInput(Buffer.from('STATUS\n'));
  assert.equal(rollback.lines.length, 1);
  await assert.rejects(rollback.control.finish(), /HTTP_METADATA_CONTROL_FAILED/);
  console.log('HTTP_CONTROL_COUNTER_CLOCK_AND_FINAL_FENCES_PASS');
}

verifyArguments();
await verifyFrames();
await verifyFaults();
await verifyWriter();


await verifyLimitsAndFinalFailure();
await verifySnapshotFences();
