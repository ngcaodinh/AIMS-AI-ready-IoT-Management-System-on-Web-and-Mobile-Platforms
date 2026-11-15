import assert from 'node:assert/strict';
import net from 'node:net';
import tls from 'node:tls';
import { once } from 'node:events';
import { setTimeout as delay } from 'node:timers/promises';
import { createCertificates } from './memory_tls_material.mjs';
import { startLocalHttpsProxy } from './local_https_proxy.mjs';
import { createHttpMetadataCapture } from './http_metadata_capture.mjs';

const targetId = '11111111-1111-4111-8111-111111111111';
const privateSentinel = 'SYNTHETIC_OBSERVED_TRANSPORT_PRIVATE';

/**
 * Chờ predicate metadata trong thời gian test hữu hạn, không lấy timeout làm kết quả transport hợp lệ.
 * Input
 * Param: ready — chỉ đọc state owned của case.
 */
async function waitFor(ready) {
  const deadline = performance.now() + 3000;
  while (!ready()) {
    assert.ok(performance.now() < deadline, 'OBSERVED_PROXY_TEST_TIMEOUT');
    await delay(10);
  }
}

/**
 * Giữ upstream/proxy/capture của từng case, luôn chờ owned close và wipe certificate material.
 * Input
 * Param: material — chứng chỉ/PFX riêng của suite, không ghi private key.
 * Param: handler — upstream giả nhận request trong test.
 * Param: verify — assertion dùng đúng endpoint của case.
 * Param: failConsumer — inject callback lỗi đồng bộ để kiểm fail-closed.
 */
async function withObserved(material, handler, verify, failConsumer = false) {
  const events = [];
  const legacy = [];
  const sockets = new Set();
  const capture = createHttpMetadataCapture({ targetWorkspaceId: targetId,
    onEvent:
      /** Chỉ giữ public metadata của case và lỗi sentinel giả khi kiểm consumer fault.
       * Input
       * Param: event — object đã qua allowlist capture, không có payload.
       */
      (event) => {
        if (failConsumer) throw Error(privateSentinel);
        events.push(event);
      } });
  const upstream = net.createServer(
    /** Track upstream owned để finally đóng được cả kết nối lỗi hoặc còn treo.
     * Input
     * Param: socket — raw socket giả của upstream loopback.
     */
    (socket) => {
      sockets.add(socket);
      socket.on('error', /** Transport test giữ lỗi trong assertions, không log raw request. */ () => {});
      socket.on('close', /** Bỏ đúng handle terminal khỏi cleanup set. */ () => sockets.delete(socket));
      handler(socket);
    });
  let proxy;
  try {
    upstream.listen(0, '127.0.0.1');
    await once(upstream, 'listening');
    proxy = await startLocalHttpsProxy(material, { port: 0, upstreamPort: upstream.address().port },
      /** Legacy callback6enum vẫn nhận metadata riêng trong branch quan sát mới.
       * Input
       * Param: kind — enum của first request line hiện hành.
       */
      (kind) => { legacy.push(kind); }, { httpMetadata: capture });
    assert.equal(typeof proxy.httpSnapshot, 'function', 'OBSERVED_PROXY_CAPABILITY_MISSING');
    await verify({ proxy, capture, events, legacy });
  } finally {
    if (proxy) { await proxy.close(); await proxy.terminal; assert.equal(proxy.httpSnapshot().rawActive, 0); assert.equal(proxy.httpSnapshot().active, 0); }
    for (const socket of sockets) socket.destroy();
    const terminal = once(upstream, 'close');
    upstream.close();
    await terminal;
  }
}

/**
 * Dùng TLS thật với đúng CA của case, đọc nguyên bytes tới terminal hoặc reset do fault.
 * Input
 * Param: material — public CA synthetic của proxy.
 * Param: port — port OS cấp cho proxy đã bind.
 * Param: request — bytes giả không credential thật.
 * Output: nguyên Buffer response, reset được trả riêng bằng cờ.
 */
async function exchange(material, port, request) {
  const socket = tls.connect({ host: '127.0.0.1', port, servername: 'localhost',
    ca: material.certificate, rejectUnauthorized: true });
  const chunks = [];
  let reset = false; let timedOut = false;
  const timer = setTimeout(/** Deadline test hủy đúng client của case. */ () => { timedOut = true; socket.destroy(Error('TEST_TIMEOUT')); }, 3000);
  try {
    await once(socket, 'secureConnect');
    assert.equal(socket.authorized, true);
    socket.write(request);
    try { for await (const chunk of socket) chunks.push(chunk); }
    catch { reset = true; }
  } finally { clearTimeout(timer); socket.destroy(); }
  assert.equal(timedOut, false, 'OBSERVED_PROXY_TEST_TIMEOUT');
  return { bytes: Buffer.concat(chunks), reset };
}

const certificates = createCertificates();
try {
  const material = certificates.valid;
  const request = Buffer.from('GET /api/v1/workspaces/' + targetId + ' HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\nCookie: ' + privateSentinel + '\r\n\r\n');
  const response = Buffer.from('HTTP/1.1 404 ' + privateSentinel + '\r\nContent-Length: 2\r\nConnection: close\r\nSet-Cookie: ' + privateSentinel + '\r\n\r\n{}');
  await withObserved(material,
    /** Upstream gửi nguyên response sau request, giữ payload giả để so bytes sau TLS.
     * Input
     * Param: socket — kết nối backend test.
     */
    (socket) => socket.once('data',
      /** ACK request giả bằng response chứa sentinel để kiểm redaction.
       * Input
       * Param: chunk — request bytes đã đi qua proxy.
       */
      (chunk) => { assert.deepEqual(chunk, request); socket.end(response); }),
    /** Kiểm bytes, target/status/ledger và seal terminal của actual TLS.
     * Input
     * Param: state — đúng proxy/capture/events/legacy thuộc case.
     */
    async ({ proxy, capture, events, legacy }) => {
      const result = await exchange(material, proxy.port, request);
      assert.deepEqual(result.bytes, response);
      assert.equal(result.reset, false);
      await waitFor(/** Close không được báo trước raw và secure handles thực sự terminal. */
        () => capture.snapshot().rawActive === 0 && capture.snapshot().active === 0);
      const snapshot = proxy.httpSnapshot();
      assert.equal(snapshot.proxyAvailable, true);
      assert.equal(snapshot.requests, 1);
      assert.equal(snapshot.statuses, 1);
      assert.equal(snapshot.closed, 1);
      assert.deepEqual(legacy, ['OTHER']);
      assert.deepEqual(events.map(
        /** Ledger target đúng cả request/status/terminal, không ghép qua timing suy đoán. */
        (event) => [event.event, event.kind, event.matchesTarget]),
      [['REQUEST','WORKSPACE_DETAIL',true],['STATUS','WORKSPACE_DETAIL',true],['CLOSED','WORKSPACE_DETAIL',true]]);
      assert.equal(events[1].status, 404);
      assert.equal(JSON.stringify({ events, snapshot }).includes(privateSentinel), false);
      assert.equal(JSON.stringify(events).includes(targetId), false);
      assert.equal(await proxy.close(), true);
      await proxy.terminal;
      assert.equal(capture.snapshot().sealed, true);
      assert.equal(proxy.httpSnapshot().proxyAvailable, false);
    });
  console.log('OBSERVED_PROXY_TLS_BYTES_TARGET_CLOSE_PASS');

  await withObserved(material, /** Raw handshake case không được tới upstream handler. */
    () => { throw Error('UNEXPECTED_UPSTREAM'); },
    /** Raw TCP chưa bắt tay vẫn phải giữ non-idle và chặn seal tới owned close.
     * Input
     * Param: state — endpoint đang hoạt động để mở raw client.
     */
    async ({ proxy, capture }) => {
      const raw = net.connect({ host: '127.0.0.1', port: proxy.port });
      raw.on('error', /** Teardown socket chủ động không xuất lỗi. */ () => {});
      try {
        await once(raw, 'connect');
        await waitFor(/** Quan sát raw connection đã được listener admit. */ () => capture.snapshot().rawActive === 1);
        assert.equal(proxy.httpSnapshot().active, 0);
        assert.equal(proxy.httpSnapshot().requests, 0);
        assert.equal(await proxy.close(), true);
        await proxy.terminal;
        assert.equal(capture.snapshot().rawActive, 0);
        assert.equal(capture.snapshot().sealed, true);
      } finally { raw.destroy(); }
    });
  console.log('OBSERVED_PROXY_PENDING_RAW_HANDSHAKE_PASS');


  await withObserved(material,
    /** Giữ upstream sau request để STATUS phải thể hiện exchange còn pending.
     * Input
     * Param: socket — upstream owned chưa trả status line.
     */
    (socket) => socket.once('data', /** Chỉ nhận request, việc chờ response là fault scenario chủ động. */ () => {}),
    /** Không dùng request count đơn lẻ làm idle fence khi TLS/upstream vẫn mở.
     * Input
     * Param: state — proxy/capture/events của case pending.
     */
    async ({ proxy, capture, events }) => {
      const result = exchange(material, proxy.port, Buffer.from('POST /api/v1/auth/login HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\nConnection: close\r\n\r\n'));
      await waitFor(/** Chờ actual request được transport forward trước snapshot pending. */ () => capture.snapshot().requests === 1);
      const pending = proxy.httpSnapshot();
      assert.equal(pending.proxyAvailable, true);
      assert.equal(pending.rawActive, 1);
      assert.equal(pending.active, 1);
      assert.equal(pending.statuses, 0);
      assert.equal(pending.closed, 0);
      assert.equal(await proxy.close(), true);
      await proxy.terminal;
      assert.equal((await result).bytes.length, 0);
      const final = proxy.httpSnapshot();
      assert.equal(final.rawActive, 0); assert.equal(final.active, 0);
      assert.equal(final.incomplete, 1); assert.equal(final.sealed, true);
      assert.deepEqual(events.map(
        /** Status thiếu phải giữ false tới terminal, không sinh status 200 giả.
         * Input
         * Param: event — ledger entry synthetic của case.
         * Output: loại event đã capture.
         */
        (event) => event.event), ['REQUEST', 'CLOSED']);
      assert.equal(events[1].statusObserved, false);
    });
  console.log('OBSERVED_PROXY_INFLIGHT_MISSING_STATUS_FENCE_PASS');

  const held = new Map();
  await withObserved(material,
    /** Giữ hai upstream độc lập để đảo thứ tự response và kiểm correlation bằng request ID.
     * Input
     * Param: socket — handle upstream của một actual TLS connection.
     */
    (socket) => socket.once('data',
      /** Chỉ phân biệt hai request synthetic, không đưa URL vào ledger output.
       * Input
       * Param: chunk — request bytes cố định của case.
       */
      (chunk) => held.set(chunk.toString('ascii').startsWith('GET /api/v1/me ') ? 'profile' : 'detail', socket)),
    /** Response B đến trước A vẫn phải nối đúng target và ordinal, không ghép bằng thứ tự status.
     * Input
     * Param: state — proxy/capture/events riêng của case.
     */
    async ({ proxy, capture, events }) => {
      const profile = exchange(material, proxy.port, Buffer.from('GET /api/v1/me HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n'));
      await waitFor(/** Cố định admission ordinal đầu tiên trước mở connection thứ hai. */ () => capture.snapshot().requests === 1 && held.has('profile'));
      const detail = exchange(material, proxy.port, request);
      await waitFor(/** Cả hai actual upstream phải nhận request trước đảo response. */ () => capture.snapshot().requests === 2 && held.has('detail'));
      held.get('detail').end(response);
      await waitFor(/** Kiểm status của B thực sự emit trước khi upstream A trả response. */ () => capture.snapshot().statuses === 1);
      held.get('profile').end('HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}');
      const results = await Promise.all([profile, detail]);
      for (const result of results) assert.equal(result.reset, false);
      await waitFor(/** Chờ cả hai secure exchanges terminal trước kiểm ledger. */ () => capture.snapshot().closed === 2);
      assert.deepEqual(events.filter(
        /** Lọc public event STATUS, không dùng bytes response để ghép request.
         * Input
         * Param: event — một ledger entry của hai connections.
         * Output: event có status line.
         */
        (event) => event.event === 'STATUS').map(
        /** Kiểm trực tiếp ordinal/category/target/status của từng response ngược thứ tự.
         * Input
         * Param: event — STATUS đã chọn.
         * Output: tuple correlation bounded.
         */
        (event) => [event.requestId, event.kind, event.matchesTarget, event.status]),
      [[2, 'WORKSPACE_DETAIL', true, 404], [1, 'PROFILE_READ', false, 200]]);
      assert.equal(capture.snapshot().incomplete, 0);
      assert.equal(await proxy.close(), true);
      await proxy.terminal;
    });
  console.log('OBSERVED_PROXY_REVERSED_CONNECTION_CORRELATION_PASS');


  await withObserved(material, /** Raw saturation không được mở connection backend. */
    () => { throw Error('UNEXPECTED_UPSTREAM'); },
    /** Cap raw vượt bound phải làm proxy unavailable, không được phát fence khỏe sau reject.
     * Input
     * Param: state — proxy/capture owned của saturation case.
     */
    async ({ proxy, capture }) => {
      const clients = [];
      const clientClosures = [];
      try {
        for (let index = 0; index < 32; index++) {
          const client = net.connect({ host: '127.0.0.1', port: proxy.port });
          clients.push(client);
          client.on('error', /** Saturation teardown chỉ chốt transport, không in SDK error. */ () => {});
          clientClosures.push(new Promise(
            /** Giữ đúng client close ACK để test không bỏ lại raw handle khi assertion lỗi.
             * Input
             * Param: resolve — completion của client synthetic này.
             */
            (resolve) => client.once('close', resolve)));
          await once(client, 'connect');
        }
        await waitFor(/** Tất cả32slots phải admit trước mở peer vượt cap. */ () => capture.snapshot().rawActive === 32);
        assert.equal(proxy.httpSnapshot().proxyAvailable, true);
        const overflow = net.connect({ host: '127.0.0.1', port: proxy.port });
        clients.push(overflow);
        overflow.on('error', /** Peer thứ33 bị từ chối, lỗi giữ trong test outcome. */ () => {});
        clientClosures.push(new Promise(
          /** Chờ peer vượt cap close riêng với32clients đã admit.
           * Input
           * Param: resolve — close ACK của overflow client.
           */
          (resolve) => overflow.once('close', resolve)));
        await once(overflow, 'connect');
        await waitFor(/** Chờ rejection thật của peer thứ33 trước kiểm sticky unavailable. */ () => overflow.closed);
        assert.equal(proxy.httpSnapshot().proxyAvailable, false, 'RAW_SATURATION_MUST_INVALIDATE_PROXY');
        assert.equal(await proxy.closed, false);
        await proxy.terminal;
        assert.equal(capture.snapshot().rawActive, 0);
        assert.equal(capture.snapshot().active, 0);
        assert.equal(capture.snapshot().requests, 0);
      } finally {
        for (const client of clients) client.destroy();
        await Promise.all(clientClosures);
      }
    });
  console.log('OBSERVED_PROXY_RAW_SATURATION_FAIL_CLOSED_PASS');

  for (const failure of ['interim', 'partial-status', 'consumer']) {
    await withObserved(material,
      /** Trả status lỗi chỉ trong upstream synthetic, không tạo auth side effect.
       * Input
       * Param: socket — connection của một fault.
       */
      (socket) => socket.once('data', /** Status first line lỗi phải fail capture trước success marker. */
        () => socket.end(failure === 'interim' ? 'HTTP/1.1 100 Continue\r\n\r\n' :
          failure === 'partial-status' ? 'HTTP/1.1 200' : response)),
      /** Chờ same proxy fail-closed, terminal không bị thay bởi reset client.
       * Input
       * Param: state — owned proxy/capture/events cần đối chiếu.
       */
      async ({ proxy, capture, events }) => {
        await exchange(material, proxy.port, request);
        await proxy.terminal;
        assert.equal(await proxy.closed, false);
        assert.equal(capture.snapshot().healthy, false);
        assert.equal(proxy.httpSnapshot().proxyAvailable, false);
        assert.equal(capture.snapshot().rawActive, 0);
        assert.equal(capture.snapshot().active, 0);
        assert.equal(events.some(
          /** Fault này chưa được công nhận final HTTP status thành công.
           * Input
           * Param: event — ledger entry cần kiểm có STATUS hay chưa.
           * Output: event thuộc nhóm STATUS.
           */
          (event) => event.event === 'STATUS'), false);
      }, failure === 'consumer');
  }
  console.log('OBSERVED_PROXY_PROTOCOL_CONSUMER_FAILURE_TERMINAL_PASS');
} finally { for (const material of Object.values(certificates)) material.pfx.fill(0); }
