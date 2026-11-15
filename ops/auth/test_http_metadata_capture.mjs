import assert from 'node:assert/strict';
import { once } from 'node:events';
import { createHttpMetadataCapture } from './http_metadata_capture.mjs';

const targetId = '11111111-1111-4111-8111-111111111111';
const otherId = '22222222-2222-4222-8222-222222222222';
const privateSentinel = 'SYNTHETIC_PRIVATE_CAPTURE_SENTINEL';

/**
 * Chuyển từng chunk synthetic qua Transform thật, giữ bytes để so sánh trong test.
 * Input
 * Param: stream — Transform của một hướng capture.
 * Param: chunks — các Buffer giả, chỉ có sentinel test.
 * Output: bytes được forward nguyên bản sau finish.
 */
async function forward(stream, chunks) {
  const output = [];
  stream.on('data', /** Giữ chunk synthetic để kiểm pass-through, không đưa payload ra console. */
    (chunk) => output.push(chunk));
  const ended = once(stream, 'end');
  for (const chunk of chunks) stream.write(chunk);
  stream.end();
  await ended;
  return Buffer.concat(output);
}

/**
 * Tạo capture mới có clock monotonic test, giữ ledger metadata công khai.
 * Input
 * Param: options — chỉ override trusted callback/target/clock cho case âm.
 * Output: capture và events đã thu để kiểm schema/redaction.
 */
function setup(options = {}) {
  const events = [];
  const capture = createHttpMetadataCapture({
    onEvent: /**
       * Copy public event đã allowlist, không nhận bytes từ stream.
       * Input
       * Param: event — event metadata hoặc pointer nội bộ của case, được kiểm theo schema và ledger hiện hành.
       */
      (event) => { events.push(event); },
    targetWorkspaceId: targetId,
    ...options,
  });
  return { capture, events };
}

/**
 * Đóng cả hai Transform rồi chốt connection terminal đúng một lần.
 * Input
 * Param: exchange — các pipe do capture cấp cho request/status.
 */
async function closeExchange(exchange) {
  await Promise.all([exchange.request, exchange.response].map(
    /**
     * Chờ đúng close của từng Transform, bao gồm autoDestroy sau end hoặc destroy do lỗi.
     * Input
     * Param: stream — Transform đang thuộc case, chỉ dùng theo dõi bytes và close ACK.
     */
    (stream) => new Promise(
      /**
       * Error được case âm kiểm riêng, closure vẫn giữ tới close thực.
       * Input
       * Param: resolve — completion closure của Promise, chỉ gọi khi trạng thái terminal đã được quan sát.
       */
      (resolve) => {
        if (stream.closed) { resolve(); return; }
        stream.on('error', /** Consumer test chỉ bỏ fixed error đã kiểm, không log payload. */ () => {});
        stream.once('close', resolve);
        stream.destroy();
      })));
  exchange.close();
}

/** Kiểm split/coalesced line, route target, counters và snapshots không cấp quyền mutate ledger. */
async function verifyPositive() {
  for (const split of [false, true]) {
    const { capture, events } = setup();
    const closeRaw = capture.openRaw();
    const exchange = capture.openExchange(closeRaw);
    const request = Buffer.from('GET /api/v1/workspaces/' + targetId + ' HTTP/1.1\r\nCookie: ' + privateSentinel + '\r\n\r\n' + privateSentinel);
    const response = Buffer.from('HTTP/1.1 404 ' + privateSentinel + '\r\nSet-Cookie: ' + privateSentinel + '\r\n\r\n' + privateSentinel);
    const requestChunks = split ? [...request].map(
      /**
       * Một byte mỗi chunk buộc CRLF và prefix đi qua nhiều lần transform.
       * Input
       * Param: byte — một byte synthetic của case, dùng chia chunk tại mọi ranh giới.
       */
      (byte) => Buffer.from([byte])) : [request];
    const responseChunks = split ? [...response].map(
      /**
       * Một byte mỗi chunk kiểm status trước khi header/body được forward.
       * Input
       * Param: byte — một byte synthetic của case, dùng chia chunk tại mọi ranh giới.
       */
      (byte) => Buffer.from([byte])) : [response];
    assert.deepEqual(await forward(exchange.request, requestChunks), request);
    assert.deepEqual(await forward(exchange.response, responseChunks), response);
    assert.equal(capture.snapshot().rawActive, 1);
    await closeExchange(exchange);
    // Raw transport có thể còn sống sau secure exchange, snapshot không được công bố idle sớm.
    assert.equal(capture.snapshot().active, 0);
    assert.equal(capture.snapshot().rawActive, 1);
    closeRaw();
    const snapshot = capture.snapshot();
    assert.equal(snapshot.healthy, true);
    assert.equal(snapshot.rawActive, 0);
    assert.equal(snapshot.requests, 1);
    assert.equal(snapshot.statuses, 1);
    assert.equal(snapshot.closed, 1);
    assert.equal(snapshot.incomplete, 0);
    assert.equal(snapshot.byKind.WORKSPACE_DETAIL, 1);
    assert.equal(events[0].matchesTarget, true);
    assert.equal(events[1].status, 404);
    assert.deepEqual(events.map(
      /**
       * Chỉ đọc enum lifecycle để kiểm thứ tự và số events.
       * Input
       * Param: event — event metadata hoặc pointer nội bộ của case, được kiểm theo schema và ledger hiện hành.
       */
      (event) => event.event), ['REQUEST', 'STATUS', 'CLOSED']);
    assert.deepEqual(events.map(
      /**
       * Mỗi event phải cùng local exchange ID, không có UUID request/server.
       * Input
       * Param: event — event metadata hoặc pointer nội bộ của case, được kiểm theo schema và ledger hiện hành.
       */
      (event) => event.requestId), [1, 1, 1]);
    assert.equal(JSON.stringify({ events, snapshot }).includes(privateSentinel), false);
    assert.equal(JSON.stringify({ events, snapshot }).includes(targetId), false);
    snapshot.byKind.WORKSPACE_DETAIL = 999;
    assert.throws(
      /** Event public bất biến, consumer không sửa lịch sử metadata sau emission. */
      () => { events[0].kind = 'MUTATED'; }, TypeError);
    assert.equal(capture.snapshot().byKind.WORKSPACE_DETAIL, 1);
    closeRaw(); exchange.close();
    assert.equal(capture.snapshot().closed, 1);
    capture.seal();
    assert.equal(capture.snapshot().sealed, true);
  }
  console.log('HTTP_CAPTURE_SPLIT_BYTES_TARGET_REDACTION_SNAPSHOT_PASS');
}

/** Kiểm từng route literal, target khác và query không được bù vào canary list/detail. */
async function verifyRoutes() {
  const lines = [
    ['POST /api/v1/auth/login', 'AUTH_LOGIN'],
    ['GET /api/v1/me', 'PROFILE_READ'],
    ['GET /api/v1/workspaces', 'WORKSPACE_LIST'],
    ['GET /api/v1/workspaces/' + otherId, 'WORKSPACE_DETAIL'],
    ['POST /api/v1/auth/password', 'PASSWORD_CHANGE'],
    ['POST /api/v1/auth/logout', 'AUTH_LOGOUT'],
    ['GET /api/v1/workspaces?limit=1', 'OTHER'],
    ['GET /api/v1/workspaces/' + targetId + '?secret=' + privateSentinel, 'OTHER'],
  ];
  const { capture, events } = setup();
  for (const [line, kind] of lines) {
    const closeRaw = capture.openRaw();
    const exchange = capture.openExchange(closeRaw);
    await forward(exchange.request, [Buffer.from(line + ' HTTP/1.1\r\n\r\n')]);
    await forward(exchange.response, [Buffer.from('HTTP/1.1 200 OK\r\n\r\n')]);
    await closeExchange(exchange); closeRaw();
    assert.equal(events.at(-3).kind, kind);
    assert.equal(events.at(-3).matchesTarget, false);
  }
  assert.equal(capture.snapshot().requests, lines.length);
  assert.equal(capture.snapshot().rawOpened, lines.length);
  console.log('HTTP_CAPTURE_ROUTE_ALLOWLIST_AND_TARGET_MISMATCH_PASS');
}

/** Kiểm thiếu status có unknown rõ và raw handshake chưa đủ thành request hoặc idle. */
async function verifyIncomplete() {
  const { capture, events } = setup();
  const closeRaw = capture.openRaw();
  assert.equal(capture.snapshot().rawActive, 1);
  assert.equal(capture.snapshot().requests, 0);
  const exchange = capture.openExchange(closeRaw);
  await forward(exchange.request, [Buffer.from('POST /api/v1/auth/login HTTP/1.1\r\n')]);
  await closeExchange(exchange); closeRaw();
  const snapshot = capture.snapshot();
  assert.equal(snapshot.healthy, true);
  assert.equal(snapshot.incomplete, 1);
  assert.equal(snapshot.statuses, 0);
  assert.equal(events.at(-1).statusObserved, false);
  assert.equal(events.at(-1).requestObserved, true);
  console.log('HTTP_CAPTURE_MISSING_STATUS_RAW_ACTIVE_PASS');
}

/**
 * Gây protocol fault riêng và kiểm stream lỗi fixed cùng sticky unhealthy.
 * Input
 * Param: mode — lỗi first-line hoặc lifecycle cần kiểm.
 */
async function verifyProtocolFault(mode) {
  const { capture, events } = setup();
  const closeRaw = capture.openRaw();
  const exchange = capture.openExchange(closeRaw);
  try {
    if (mode !== 'status-before-request' && !mode.startsWith('request-')) {
      await forward(exchange.request, [Buffer.from('GET /api/v1/me HTTP/1.1\r\n')]);
    }
    const stream = mode.startsWith('request-') ? exchange.request : exchange.response;
    const line = mode === 'request-oversize' ? 'G'.repeat(257) :
      mode === 'request-malformed' ? 'GET /api/v1/me HTTP/2.0\r\n' :
      mode === 'request-partial' ? 'GET /api/v1/me' :
      mode === 'interim-status' ? 'HTTP/1.1 100 Continue\r\n' :
      mode === 'status-malformed' ? 'HTTP/1.1 700 ' + privateSentinel + '\r\n' :
      mode === 'status-partial' ? 'HTTP/1.1 200' : 'HTTP/1.1 200 OK\r\n';
    await assert.rejects(forward(stream, [Buffer.from(line)]),
      /**
       * Chỉ fixed error được chấp nhận, không echo reason/request line.
       * Input
       * Param: error — lỗi đã bắt tại boundary test, chỉ đối chiếu fixed code và không log nội dung.
       */
      (error) => error.message === 'HTTP_METADATA_CAPTURE_FAILED');
    assert.equal(capture.snapshot().healthy, false);
    assert.equal(JSON.stringify(events).includes(privateSentinel), false);
    assert.throws(
      /** Capture lỗi không cấp exchange mới để che failure hoặc reset counters. */
      () => capture.openExchange(), /HTTP_METADATA_CAPTURE_FAILED/);
  } finally { await closeExchange(exchange); closeRaw(); }
}

/** Kiểm bound raw/exchange, clock rollback và callback không đồng bộ/throw không được tạo proof khỏe. */
async function verifyBoundaries() {
  for (const mode of ['request-oversize', 'request-malformed', 'request-partial',
    'status-before-request', 'interim-status', 'status-malformed', 'status-partial']) {
    await verifyProtocolFault(mode);
  }
  const { capture } = setup();
  const raws = Array.from({ length: 32 },
    /** Mở đủ raw slots theo cap của proxy hiện hành. */
    () => capture.openRaw());
  assert.throws(
    /** Raw thứ33 không được cấp slot bằng snapshot secureActive0. */
    () => capture.openRaw(), /HTTP_METADATA_CAPTURE_FAILED/);
  assert.equal(capture.snapshot().healthy, false);
  for (const close of raws) close();
  for (const callback of [
    /** Consumer đồng bộ lỗi phải được redact. */
    () => { throw new Error(privateSentinel); },
    /** Consumer async không đủ ACK nên bị từ chối và rejection được drain. */
    () => Promise.reject(new Error(privateSentinel)),
  ]) {
    const { capture: failed } = setup({ onEvent: callback });
    const closeRaw = failed.openRaw();
    const exchange = failed.openExchange(closeRaw);
    await assert.rejects(forward(exchange.request, [Buffer.from('GET /api/v1/me HTTP/1.1\r\n')]),
      /**
       * Không phản chiếu exception của consumer trong stream error.
       * Input
       * Param: error — lỗi đã bắt tại boundary test, chỉ đối chiếu fixed code và không log nội dung.
       */
      (error) => error.message === 'HTTP_METADATA_CAPTURE_FAILED');
    assert.equal(failed.snapshot().healthy, false);
    await closeExchange(exchange); closeRaw();
  }
  let clock = 10;
  const { capture: timed } = setup({ now: /** Clock trusted được điều khiển riêng trong host negative. */ () => clock });
  clock = 9;
  assert.equal(timed.snapshot().healthy, false);
  const { capture: limited } = setup();
  for (let i = 0; i < 1024; i++) limited.openRaw()();
  assert.throws(
    /** Lifetime cap không reset khi mọi raw trước đã đóng. */
    () => limited.openRaw(), /HTTP_METADATA_CAPTURE_FAILED/);
  assert.throws(
    /** Target malformed phải bị từ chối trước mọi stream allocation. */
    () => setup({ targetWorkspaceId: privateSentinel }), /HTTP_METADATA_CONFIGURATION_INVALID/);
  console.log('HTTP_CAPTURE_PROTOCOL_CLOCK_CALLBACK_AND_CAP_PASS');
}


/** Kiểm premature close/seal và callback cấu hình đã được pin, tránh snapshot idle hoặc target đổi giữa lượt. */
async function verifyLifecycle() {
  const { capture } = setup();
  const closeRaw = capture.openRaw();
  const exchange = capture.openExchange(closeRaw);
  assert.throws(
    /** Chưa có close ACK của pipes không được giảm active thành0. */
    () => exchange.close(), /HTTP_METADATA_CAPTURE_FAILED/);
  assert.equal(capture.snapshot().active, 1);
  await closeExchange(exchange); closeRaw();
  assert.equal(capture.snapshot().healthy, false);
  const { capture: pending } = setup();
  const pendingRaw = pending.openRaw();
  assert.throws(
    /** Handshake đang dở cũng ngăn seal khỏe dù chưa có secure exchange. */
    () => pending.seal(), /HTTP_METADATA_CAPTURE_FAILED/);
  pendingRaw();
  const { capture: sealed } = setup();
  sealed.seal();
  assert.throws(
    /** Admission sau final fence là failure, không hồi sinh capture cũ. */
    () => sealed.openRaw(), /HTTP_METADATA_CAPTURE_FAILED/);
  const pinnedEvents = [];
  const options = { targetWorkspaceId: targetId,
    onEvent: /**
       * Callback ban đầu là capability bất biến của capture.
       * Input
       * Param: event — event metadata hoặc pointer nội bộ của case, được kiểm theo schema và ledger hiện hành.
       */
      (event) => { pinnedEvents.push(event); } };
  const pinned = createHttpMetadataCapture(options);
  options.targetWorkspaceId = otherId;
  options.onEvent = /** Callback caller thay sau startup không được capture dùng. */
    () => { throw Error(privateSentinel); };
  const raw = pinned.openRaw();
  const observed = pinned.openExchange(raw);
  await forward(observed.request, [Buffer.from('GET /api/v1/workspaces/' + targetId + ' HTTP/1.1\r\n')]);
  await forward(observed.response, [Buffer.from('HTTP/1.1 200 OK\r\n')]);
  await closeExchange(observed); raw();
  assert.equal(pinnedEvents[0].matchesTarget, true);
  assert.equal(pinned.snapshot().healthy, true);
  console.log('HTTP_CAPTURE_TERMINAL_SEAL_AND_PINNED_CONFIG_PASS');
}

await verifyPositive();
await verifyRoutes();
await verifyIncomplete();
await verifyBoundaries();


await verifyLifecycle();

/** Kiểm schema event chính xác và các mốc256bytes, nhiều exchange/clock lỗi được giữ tách biệt. */
async function verifyExactSchemasAndEdges() {
  const { capture, events } = setup();
  const raw = capture.openRaw();
  const exchange = capture.openExchange(raw);
  // 256 bao gồm cả CRLF, prefix chỉ được vượt cap khi byte kế tiếp thật sự tới.
  const route = '/x' + 'a'.repeat(239);
  const line = 'GET ' + route + ' HTTP/1.1\r\n';
  assert.equal(Buffer.byteLength(line), 256);
  await forward(exchange.request, [Buffer.from(line)]);
  await forward(exchange.response, [Buffer.from('HTTP/1.1 599\r\n')]);
  await closeExchange(exchange); raw();
  assert.deepEqual(Object.keys(events[0]).sort(),
    ['sequence', 'elapsedMilliseconds', 'event', 'requestId', 'kind', 'matchesTarget'].sort());
  assert.deepEqual(Object.keys(events[1]).sort(),
    ['sequence', 'elapsedMilliseconds', 'event', 'requestId', 'kind', 'matchesTarget', 'status'].sort());
  assert.deepEqual(Object.keys(events[2]).sort(),
    ['sequence', 'elapsedMilliseconds', 'event', 'requestId', 'kind', 'matchesTarget',
      'requestObserved', 'statusObserved'].sort());
  assert.deepEqual(events.map(
    /**
     * Sequence liên tục không phụ thuộc số snapshot đọc giữa events.
     * Input
     * Param: event — event metadata hoặc pointer nội bộ của case, được kiểm theo schema và ledger hiện hành.
     */
    (event) => event.sequence), [1, 2, 3]);
  assert.equal(events[0].kind, 'OTHER');
  assert.equal(events[1].status, 599);
  const { capture: noRaw } = setup();
  assert.throws(
    /** Secure exchange không được tự tạo transport admission chưa có raw slot. */
    () => noRaw.openExchange(), /HTTP_METADATA_CAPTURE_FAILED/);
  for (const mode of ['status-oversize', 'status-invalid-utf8', 'request-bare-lf']) {
    const { capture: failed } = setup();
    const closeRaw = failed.openRaw();
    const current = failed.openExchange(closeRaw);
    try {
      const requestFault = mode === 'request-bare-lf';
      if (!requestFault) await forward(current.request, [Buffer.from('GET /api/v1/me HTTP/1.1\r\n')]);
      const bytes = requestFault ? Buffer.from('GET /api/v1/me HTTP/1.1\n') :
        mode === 'status-oversize' ? Buffer.from('HTTP/1.1 200 ' + 'x'.repeat(250) + '\r\n') :
          Buffer.from([72,84,84,80,47,49,46,49,32,50,48,48,32,255,13,10]);
      await assert.rejects(forward(requestFault ? current.request : current.response, [bytes]),
        /**
         * Payload malformed chỉ cho fixed failure, không lộ raw bytes qua error.
         * Input
         * Param: error — lỗi đã bắt tại boundary test, chỉ đối chiếu fixed code và không log nội dung.
         */
        (error) => error.message === 'HTTP_METADATA_CAPTURE_FAILED');
      assert.equal(failed.snapshot().healthy, false);
    } finally { await closeExchange(current); closeRaw(); }
  }
  // Hai request cùng lúc phải giữ identity/status riêng ngay cả response ngược thứ tự.
  const paired = setup();
  const closeA = paired.capture.openRaw();
  const closeB = paired.capture.openRaw();
  const a = paired.capture.openExchange(closeA);
  const b = paired.capture.openExchange(closeB);
  await forward(a.request, [Buffer.from('GET /api/v1/me HTTP/1.1\r\n')]);
  await forward(b.request, [Buffer.from('GET /api/v1/workspaces/' + targetId + ' HTTP/1.1\r\n')]);
  await forward(b.response, [Buffer.from('HTTP/1.1 404 Gone\r\n')]);
  await forward(a.response, [Buffer.from('HTTP/1.1 200 OK\r\n')]);
  await closeExchange(b); closeB();
  await closeExchange(a); closeA();
  const statuses = paired.events.filter(
    /**
     * Chỉ chọn status metadata do capture emit, không đọc payload HTTP.
     * Input
     * Param: event — event metadata hoặc pointer nội bộ của case, được kiểm theo schema và ledger hiện hành.
     */
    (event) => event.event === 'STATUS');
  assert.deepEqual(statuses.map(
    /**
     * Tuple công khai giữ ID/kind/target/status để phát hiện nối sai response.
     * Input
     * Param: event — event metadata hoặc pointer nội bộ của case, được kiểm theo schema và ledger hiện hành.
     */
    (event) => [event.requestId, event.kind, event.matchesTarget, event.status]),
  [[2, 'WORKSPACE_DETAIL', true, 404], [1, 'PROFILE_READ', false, 200]]);
  paired.capture.seal();
  assert.equal(paired.capture.snapshot().healthy, true);
  let time = 1;
  const clocked = setup({ now:
    /** Sample nonfinite phải sticky failure, các sample tốt sau đó không tự phục hồi. */
    () => time }).capture;
  time = Number.NaN;
  assert.equal(clocked.snapshot().healthy, false);
  time = 2;
  assert.equal(clocked.snapshot().healthy, false);
  console.log('HTTP_CAPTURE_EXACT_SCHEMA_LINE_EDGES_AND_CONCURRENT_PAIR_PASS');
}

await verifyExactSchemasAndEdges();


assert.throws(
  /** Clock startup lỗi chỉ được fixed configuration error, không phản chiếu exception của capability. */
  () => setup({ now: /** Fault clock trusted chỉ chứa sentinel synthetic. */ () => { throw Error(privateSentinel); } }),
  /HTTP_METADATA_CONFIGURATION_INVALID/);

/** Cấm secure admission dùng lại raw đã đóng/đã dùng hoặc capability thuộc capture khác. */
async function verifyRawOwnership() {
  for (const mode of ['duplicate', 'closed', 'foreign']) {
    const { capture } = setup();
    const first = capture.openRaw();
    const spare = capture.openRaw();
    const exchange = mode === 'duplicate' ? capture.openExchange(first) : undefined;
    const outsider = setup().capture.openRaw();
    if (mode === 'closed') first();
    try {
      assert.throws(
        /** Aggregate raw count còn dương cũng không cấp lại quyền cho handle đã dùng hoặc ngoài owner. */
        () => capture.openExchange(mode == 'foreign' ? outsider : first),
        /HTTP_METADATA_CAPTURE_FAILED/);
      assert.equal(capture.snapshot().healthy, false);
    } finally {
      if (exchange) await closeExchange(exchange);
      first(); spare(); outsider();
    }
  }
  console.log('HTTP_CAPTURE_RAW_CAPABILITY_OWNERSHIP_PASS');
}
await verifyRawOwnership();

/** Kiểm destroy khi prefix còn dở và callback về value thông thường, giữ sticky unhealthy sau teardown. */
async function verifyDestroyAndConsumerAck() {
  const { capture } = setup();
  const closeRaw = capture.openRaw();
  const exchange = capture.openExchange(closeRaw);
  exchange.request.resume();
  exchange.request.write(Buffer.from('GET /api/'));
  await closeExchange(exchange); closeRaw();
  assert.equal(capture.snapshot().healthy, false);
  const { capture: denied } = setup({ onEvent:
    /** Consumer return value chưa phải ACK undefined theo contract đồng bộ. */
    () => true });
  const raw = denied.openRaw();
  const active = denied.openExchange(raw);
  try {
    await assert.rejects(forward(active.request, [Buffer.from('GET /api/v1/me HTTP/1.1\r\n')]),
      /**
       * Consumer ack sai chỉ xuất fixed capture error.
       * Input
       * Param: error — lỗi boundary đã bắt, chỉ so fixed code để tránh echo raw metadata.
       */
      (error) => error.message === 'HTTP_METADATA_CAPTURE_FAILED');
    assert.equal(denied.snapshot().healthy, false);
  } finally { await closeExchange(active); raw(); }
  console.log('HTTP_CAPTURE_PARTIAL_DESTROY_AND_CONSUMER_ACK_PASS');
}
await verifyDestroyAndConsumerAck();
