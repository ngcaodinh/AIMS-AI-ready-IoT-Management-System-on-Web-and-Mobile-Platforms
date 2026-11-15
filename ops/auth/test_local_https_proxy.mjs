import assert from 'node:assert/strict';
import net from 'node:net';
import tls from 'node:tls';
import { once } from 'node:events';
import { spawn } from 'node:child_process';
import { X509Certificate } from 'node:crypto';
import { setTimeout as delay } from 'node:timers/promises';
import { startLocalHttpsProxy } from './local_https_proxy.mjs';
import { createCertificates } from './memory_tls_material.mjs';

const cliReadyPrefix = 'LOCAL_HTTPS_PROXY_READY origin=https://10.0.2.2:8443 upstream=127.0.0.1:3000 ttlMinutes=50';

function assertPublicCliReady(output) {
  const lines = output.trimEnd().split('\n');
  assert.equal(lines.length, 2); assert.equal(lines[0], cliReadyPrefix);
  const match = /^AUTH_LAB_CA_CERT=([A-Za-z0-9+/]+=*)$/.exec(lines[1]);
  assert.ok(match);
  // Public DER certificate, exact round-trip: no PFX/PEM/private field or extra bytes accepted.
  const certificate = new X509Certificate(Buffer.from(match[1], 'base64'));
  assert.equal(certificate.raw.toString('base64'), match[1]);
}

function assertPublicCliStopped(output, readyOutput) {
  assert.equal(output === readyOutput + 'LOCAL_HTTPS_PROXY_STOPPED\n', true);
}

/**
 * Kiểm cầu nối bằng upstream synthetic thật trên loopback; không truy cập DB/auth hoặc log payload.
 * Output: marker chỉ sau so sánh byte HTTP hai chiều và cleanup listener thành công.
 */
async function main() {
  const material = createCertificates();
  const request = Buffer.from('GET /synthetic HTTP/1.1\r\nHost: 10.0.2.2:8443\r\nConnection: close\r\n\r\n');
  const response = Buffer.from('HTTP/1.1 503 Service Unavailable\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}');
  let received;
  const sockets = new Set();
  const upstream = net.createServer(
    /**
     * Nhận một HTTP request synthetic và trả lỗi nguyên bản để phát hiện proxy sửa status/body.
     * Input
     * Param: socket — kết nối riêng của test, luôn được track để cleanup.
     */
    (socket) => {
      sockets.add(socket);
      socket.on('error', /** Giữ lỗi synthetic trong boundary assertion thay vì in exception. */ () => {});
      socket.once('data',
        /**
         * Lưu bytes giả lập để so sánh sau khi client đọc hết; không chứa credential.
         * Input
         * Param: chunk — request bytes synthetic gửi qua TLS bridge.
         */
        (chunk) => { received = chunk; socket.end(response); });
    });
  let proxy;
  let client;
  try {
    upstream.listen(0, '127.0.0.1');
    await once(upstream, 'listening');
    proxy = await startLocalHttpsProxy(material.valid, { port: 0, upstreamPort: upstream.address().port });
    client = tls.connect({ host: '127.0.0.1', port: proxy.port, servername: 'localhost',
      ca: material.valid.certificate, rejectUnauthorized: true, minVersion: 'TLSv1.2' });
    const timeout = setTimeout(/** Chặn test treo khi cầu nối không đóng HTTP response. */
      () => client.destroy(new Error('TEST_TIMEOUT')), 3_000);
    try {
      await once(client, 'secureConnect');
      assert.equal(client.authorized, true);
      client.write(request);
      const chunks = [];
      for await (const chunk of client) chunks.push(chunk);
      assert.deepEqual(Buffer.concat(chunks), response);
      assert.deepEqual(received, request);
    } finally { clearTimeout(timeout); }
    assert.equal(await proxy.close(), true);
    console.log('PROXY_SYNTHETIC_HTTP_EXACT_PASS');
  } finally {
    client?.destroy();
    if (proxy) await proxy.close();
    for (const socket of sockets) socket.destroy();
    const closed = once(upstream, 'close');
    upstream.close();
    await closed;
    for (const value of Object.values(material)) value.pfx.fill(0);
  }
}

/**
 * Đợi close thật với deadline test và không phát lỗi transport ra console.
 * Input
 * Param: socket — owned raw/TLS socket cần quan sát terminal.
 * Output: resolve khi close, reject cố định nếu treo quá3s.
 */
function socketClosed(socket) {
  socket.on('error', /** Test disconnect không cần log exception của SDK. */ () => {});
  if (socket.closed) return Promise.resolve();
  return new Promise(
    /**
     * Gắn quan sát trước khi action đóng để không bỏ lỡ event nhanh.
     * Input
     * Param: resolve — ACK close của socket.
     * Param: reject — báo deadline hết thay vì coi timeout là disconnect hợp lệ.
     */
    (resolve, reject) => {
      const timer = setTimeout(/** Không cho case âm PASS vì test tự treo. */
        () => reject(new Error('TEST_CLOSE_TIMEOUT')), 3_000);
      socket.once('close', /** Close thực giải phóng deadline và hoàn tất quan sát. */
        () => { clearTimeout(timer); resolve(); });
    });
}

/**
 * Sở hữu upstream synthetic và proxy test, luôn cleanup cả hai dù assertion thất bại.
 * Input
 * Param: material — public/PFX RAM dùng TLS thật.
 * Param: handler — xử lý socket upstream chỉ chứa bytes giả.
 * Param: options — budget ngắn để test không chờ timeout production.
 * Param: verify — assertion nhận proxy đã bind.
 * Param: observer — callback enum đồng bộ, chỉ bật trong test oracle request line.
 */
async function withSynthetic(material, handler, options, verify, observer) {
  const sockets = new Set();
  const upstream = net.createServer(
    /**
     * Track socket giả để teardown không đóng process/port ngoài test.
     * Input
     * Param: socket — upstream connection riêng.
     */
    (socket) => {
      sockets.add(socket);
      socket.on('error', /** Lỗi synthetic được kiểm qua consumer, không log payload. */ () => {});
      socket.on('close', /** Bỏ socket đã terminal khỏi cleanup set. */ () => sockets.delete(socket));
      handler(socket);
    });
  let proxy;
  try {
    upstream.listen(0, '127.0.0.1'); await once(upstream, 'listening');
    proxy = await startLocalHttpsProxy(material, { port: 0, upstreamPort: upstream.address().port, ...options }, observer);
    await verify(proxy);
  } finally {
    if (proxy) assert.equal(await proxy.close(), true);
    for (const socket of sockets) socket.destroy();
    const closed = once(upstream, 'close'); upstream.close(); await closed;
  }
}

/**
 * Gửi bytes synthetic qua TLS xác minh thật; response cắt do proxy được trả nguyên bytes đã nhận.
 * Input
 * Param: material — đúng public cert riêng của proxy.
 * Param: port — listener test.
 * Param: request — dữ liệu giả cần gửi.
 * Output: Buffer response; timeout test luôn thất bại, không gộp thành nhánh transport expected.
 */
async function exchange(material, port, request = Buffer.from('synthetic')) {
  const socket = tls.connect({ host: '127.0.0.1', port, servername: 'localhost',
    ca: material.certificate, rejectUnauthorized: true });
  let timedOut = false;
  let authorized = false;
  const timer = setTimeout(/** Hủy owned client để assertion không treo khi bridge chưa thực hiện deadline. */
    () => { timedOut = true; socket.destroy(new Error('TEST_TIMEOUT')); }, 3_000);
  const chunks = [];
  try {
    await once(socket, 'secureConnect');
    assert.equal(socket.authorized, true);
    authorized = true;
    socket.write(request);
    for await (const chunk of socket) chunks.push(chunk);
  } catch {
    // Transport reset là nhánh được case âm kiểm bằng bytes; wall timeout vẫn phải fail bên dưới.
  } finally { clearTimeout(timer); socket.destroy(); }
  assert.equal(timedOut, false, 'TEST_DEADLINE_NOT_PROXY_DEADLINE');
  assert.equal(authorized, true, 'TEST_MUST_COMPLETE_VALID_TLS');
  return Buffer.concat(chunks);
}

/** Chạy bounds/cleanup với actual TLS và upstream giả; không là evidence backend auth hoặc App. */
async function verifyBridgeBounds() {
  const certificates = createCertificates();
  const material = certificates.valid;
  try {
    const large = Buffer.alloc(512 * 1024, 65);
    await withSynthetic(material,
      /**
       * Trả response lớn một lần để phát hiện close quá sớm làm cắt TLS output.
       * Input
       * Param: socket — upstream synthetic.
       */
      (socket) => socket.once('data', /** Gửi dữ liệu giả, không đọc hoặc tạo auth credential. */
        () => socket.end(large)), {},
      /**
       * So sánh toàn response sau upstream FIN, kiểm không mất byte buffered.
       * Input
       * Param: proxy — endpoint test đã bind.
       */
      async (proxy) => assert.deepEqual(await exchange(material, proxy.port), large));
    console.log('PROXY_LARGE_RESPONSE_FLUSH_PASS');

    for (const direction of ['request', 'response']) {
      let received = 0;
      await withSynthetic(material,
        /**
         * Đo bytes fake tới backend hoặc gửi response vượt budget để kiểm cắt trước forward.
         * Input
         * Param: socket — upstream synthetic.
         */
        (socket) => {
          socket.on('data',
            /**
             * Đếm bytes không giữ payload; response oversized chỉ gửi ở nhánh cần test.
             * Input
             * Param: chunk — dữ liệu giả do TLS peer chuyển.
             */
            (chunk) => { received += chunk.length; if (direction === 'response') socket.end(Buffer.alloc(129)); });
        }, { maxBytes: 128 },
        /**
         * Chunk vượt budget không được chuyển tiếp nguyên vẹn hoặc tạo response thành công.
         * Input
         * Param: proxy — endpoint với byte cap test128.
         */
        async (proxy) => {
          const result = await exchange(material, proxy.port, Buffer.alloc(direction === 'request' ? 129 : 1));
          assert.equal(result.length, 0); assert.ok(received <= 128);
        });
      console.log(`PROXY_${direction.toUpperCase()}_CAP_PASS`);
    }
    for (const direction of ['request', 'response']) {
      let received = 0;
      await withSynthetic(material,
        /**
         * ACK chunk đầu trước chunk kế tiếp để tổng budget được kiểm xuyên nhiều lần transform.
         * Input
         * Param: socket — upstream synthetic, không có dữ liệu auth.
         */
        (socket) => socket.on('data',
          /**
           * Đếm request và phát response64+65 ở nhánh response cap; request cap chỉ nhận ACK byte.
           * Input
           * Param: chunk — bytes fake đã qua proxy, dùng chứng minh crossing chunk bị chặn.
           */
          (chunk) => {
            received += chunk.length;
            socket.write(Buffer.alloc(direction === 'request' ? 1 : received === 1 ? 64 : 65, 65));
          }), { maxBytes: 128 },
        /**
         * Chia lượt bằng ACK thật, mỗi chunk riêng dưới128 nhưng tổng129 phải đóng transport.
         * Input
         * Param: proxy — listener có byte cap128 cho mỗi hướng.
         */
        async (proxy) => {
          const client = tls.connect({ host: '127.0.0.1', port: proxy.port, servername: 'localhost',
            ca: material.certificate, rejectUnauthorized: true });
          let timedOut = false;
          const timer = setTimeout(/** Không cho mutation bỏ cumulative cap PASS do test tự hủy. */
            () => { timedOut = true; client.destroy(); }, 2_000);
          try {
            await once(client, 'secureConnect'); assert.equal(client.authorized, true);
            const first = once(client, 'data'); client.write(Buffer.alloc(direction === 'request' ? 64 : 1));
            const chunks = [(await first)[0]];
            client.write(Buffer.alloc(direction === 'request' ? 65 : 1));
            try { for await (const chunk of client) chunks.push(chunk); } catch {
              // Expected transport reset sau crossing chunk; assertion bytes/deadline quyết định PASS.
            }
            assert.equal(Buffer.concat(chunks).length, direction === 'request' ? 1 : 64);
            assert.equal(received, direction === 'request' ? 64 : 2);
            assert.equal(timedOut, false);
          } finally { clearTimeout(timer); client.destroy(); }
        });
      console.log(`PROXY_${direction.toUpperCase()}_CUMULATIVE_CAP_PASS`);
    }
    for (const kind of ['idle', 'wall', 'disconnect']) {
      await withSynthetic(material,
        /**
         * Giữ kết nối hoặc đóng sớm để test consumer chỉ nhận transport failure.
         * Input
         * Param: socket — upstream giả, không phát HTTP success.
         */
        (socket) => { if (kind === 'disconnect') socket.destroy(); },
        kind === 'idle' ? { idleMilliseconds: 200 } : { connectionMilliseconds: 250 },
        /**
         * Đợi bridge đóng trong budget riêng; test deadline3s sẽ bắt timeout không hoạt động.
         * Input
         * Param: proxy — listener với budget ngắn.
         */
        async (proxy) => assert.equal((await exchange(material, proxy.port)).length, 0));
      console.log(`PROXY_${kind.toUpperCase()}_CLOSE_PASS`);
    }
    await withSynthetic(material, /** Không xử lý data vì ca này chỉ kiểm raw pre-handshake ownership. */
      () => {}, { maxConnections: 1, handshakeMilliseconds: 300 },
      /**
       * Peer thứ hai bị đóng trong khi raw peer đầu vẫn chiếm slot, peer đầu hết handshake budget.
       * Input
       * Param: proxy — listener giới hạn một raw connection.
       */
      async (proxy) => {
        const first = net.connect(proxy.port, '127.0.0.1');
        const firstClosed = socketClosed(first); await once(first, 'connect');
        const second = net.connect(proxy.port, '127.0.0.1');
        try {
          await socketClosed(second);
          assert.equal(first.destroyed, false); await firstClosed;
        }
        finally { first.destroy(); second.destroy(); }
      });
    console.log('PROXY_RAW_CAP_HANDSHAKE_PASS');
    const proxy = await startLocalHttpsProxy(material, { port: 0, lifetimeMilliseconds: 200 });
    const raw = net.connect(proxy.port, '127.0.0.1');
    const rawClosed = socketClosed(raw); await once(raw, 'connect');
    assert.equal(await proxy.closed, true); await rawClosed;
    assert.equal(await proxy.close(), true);
    console.log('PROXY_LIFETIME_RAW_CLEANUP_PASS');
    const refused = net.createServer(); refused.listen(0, '127.0.0.1'); await once(refused, 'listening');
    const port = refused.address().port; const refusedClosed = once(refused, 'close'); refused.close(); await refusedClosed;
    const unavailable = await startLocalHttpsProxy(material, { port: 0, upstreamPort: port });
    try { assert.equal((await exchange(material, unavailable.port)).length, 0); }
    finally { assert.equal(await unavailable.close(), true); }
    console.log('PROXY_UPSTREAM_REFUSED_PASS');
    await withSynthetic(material,
      /**
       * Giữ traffic đều để wall deadline không thể được thay bằng idle timeout.
       * Input
       * Param: socket — upstream giả chỉ gửi marker byte.
       */
      (socket) => {
        const timer = setInterval(/** Byte trickle không được reset wall budget của raw connection. */
          () => socket.write(Buffer.from([65])), 40);
        socket.on('close', /** Không để test timer sống sau socket. */ () => clearInterval(timer));
      }, { connectionMilliseconds: 350, idleMilliseconds: 150 },
      /**
       * Trickle có hoạt động nhưng kết nối vẫn đóng trước test deadline3s.
       * Input
       * Param: proxy — endpoint có wall budget độc lập.
       */
      async (proxy) => {
        const result = await exchange(material, proxy.port);
        assert.ok(result.length >= 2 && result.length < 30);
      });
    console.log('PROXY_WALL_TRICKLE_CLOSE_PASS');
  } finally { for (const value of Object.values(certificates)) value.pfx.fill(0); }
}

/**
 * Sở hữu CLI subprocess với captured public-only output; không in capture khi assertion lỗi.
 * Input
 * Param: argumentsList — chỉ arguments giả để kiểm CLI từ chối cấu hình tùy ý.
 * Output: child/ready/done và public output getter; deadline70s kể cả generation60s.
 */
function startCli(argumentsList = []) {
  const child = spawn(process.execPath, ['ops/auth/local_https_proxy.mjs', ...argumentsList],
    { shell: false, windowsHide: true, env: { SystemRoot: 'C:/Windows' }, stdio: ['pipe', 'pipe', 'pipe'] });
  let output = ''; let errors = ''; let readyResolve;
  const ready = new Promise(
    /**
     * Chỉ xác nhận ready khi có public certificate sau marker bind.
     * Input
     * Param: resolve — completion cho test điều khiển CLI.
     */
    (resolve) => { readyResolve = resolve; });
  const timer = setTimeout(/** Chỉ kill child test sở hữu nếu vượt cả startup và shutdown budgets. */
    () => child.kill(), 70_000);
  child.stdout.on('data',
    /**
     * Capture bounded output riêng, không forward public cert hoặc material ngoài schema.
     * Input
     * Param: chunk — CLI stdout đã capture.
     */
    (chunk) => {
      if (output.length + chunk.length > 16_384) { child.kill(); return; }
      output += chunk.toString('utf8');
      if (/AUTH_LAB_CA_CERT=[A-Za-z0-9+/]+=*\r?\n/.test(output)) readyResolve(output);
    });
  child.stderr.on('data',
    /**
     * Giới hạn stderr; assertion chỉ kiểm fixed marker, không in nội dung khi thất bại.
     * Input
     * Param: chunk — captured error output của child.
     */
    (chunk) => { if (errors.length + chunk.length > 1024) child.kill(); else errors += chunk.toString('utf8'); });
  const done = once(child, 'close').then(
    /**
     * Close event bảo đảm stdio đã đóng, không gọi exitCode null là terminal.
     * Input
     * Param: result — exit code/signal của đúng child.
     * Output: snapshot public-only để assertion không đọc process environment.
     */
    (result) => { clearTimeout(timer); readyResolve(null); return { code: result[0], output, errors }; });
  return { child, ready, done };
}

/** Kiểm CLI boundary/lifecycle thật;8443 collision không được kill endpoint bên ngoài ownership. */
async function verifyCli() {
  const invalid = startCli(['--upstream=http://example.invalid']); invalid.child.stdin.end();
  const rejected = await invalid.done;
  assert.equal(rejected.code, 1); assert.equal(rejected.output, '');
  assert.equal(rejected.errors.trim(), 'LOCAL_HTTPS_PROXY_FAILED');
  console.log('PROXY_CLI_ARGUMENTS_REJECTED');
  const occupied = net.createServer(); occupied.listen(8443, '127.0.0.1'); await once(occupied, 'listening');
  try {
    const collision = startCli(); collision.child.stdin.end(); const result = await collision.done;
    assert.equal(result.code, 1); assert.equal(result.output, '');
    assert.equal(result.errors.trim(), 'LOCAL_HTTPS_PROXY_FAILED'); assert.equal(occupied.listening, true);
  } finally { const closed = once(occupied, 'close'); occupied.close(); await closed; }
  console.log('PROXY_CLI_COLLISION_NO_PUBLICATION_PASS');
  const upstreamSockets = new Set();
  const fixedUpstream = net.createServer(
    /**
     * Backend giả tại đúng3000 chứng minh CLI không chỉ in fixed upstream trong ready marker.
     * Input
     * Param: socket — owned connection từ CLI, echo bytes giả và giữ mở đến STOP.
     */
    (socket) => {
      upstreamSockets.add(socket);
      socket.on('error', /** Chặn exception synthetic khi bridge teardown. */ () => {});
      socket.on('close', /** Bỏ handle backend giả đã terminal. */ () => upstreamSockets.delete(socket));
      socket.pipe(socket);
    });
  fixedUpstream.listen(3000, '127.0.0.1'); await once(fixedUpstream, 'listening');
  try {
  for (const control of ['split-stop', 'eof', 'oversized', 'invalid']) {
    const cli = startCli(); let raw; let secure; let check = 'READY';
    try {
      const output = await cli.ready; assert.ok(output);
      check = 'READY_PREFIX';
      assert.ok(output.startsWith(cliReadyPrefix + '\nAUTH_LAB_CA_CERT='));
      check = 'PUBLIC_OUTPUT';
      assertPublicCliReady(output);
      check = 'CONTROL';
      if (control === 'split-stop') {
        raw = net.connect(8443, '127.0.0.1'); await once(raw, 'connect');
        const certificate = output.match(/AUTH_LAB_CA_CERT=([A-Za-z0-9+/]+=*)/)[1];
        secure = tls.connect({ host: '127.0.0.1', port: 8443, servername: 'localhost',
          ca: `-----BEGIN CERTIFICATE-----\n${certificate}\n-----END CERTIFICATE-----`, rejectUnauthorized: true });
        secure.on('error', /** Upstream3000 không sẵn sàng có thể đóng TLS; không log peer exception. */ () => {});
        await once(secure, 'secureConnect');
        const echoed = once(secure, 'data'); secure.write('synthetic-fixed-upstream');
        assert.equal((await echoed)[0].toString('ascii'), 'synthetic-fixed-upstream');
        const rawClosed = socketClosed(raw); const secureClosed = socketClosed(secure);
        cli.child.stdin.write('ST'); await delay(30); assert.equal(cli.child.exitCode, null);
        assert.equal(secure.destroyed, false); assert.equal(raw.destroyed, false);
        cli.child.stdin.write('OP\n'); await rawClosed; await secureClosed;
      } else if (control === 'eof') cli.child.stdin.end();
      else cli.child.stdin.write(control === 'oversized' ? 'S'.repeat(17) : 'BAD\n');
      const result = await cli.done;
      check = 'EXIT_CODE'; assert.equal(result.code, 0);
      check = 'STDERR'; assert.equal(result.errors, '');
      check = 'STOPPED';
      assertPublicCliStopped(result.output, output);
    } catch (error) {
      console.error(`PROXY_CLI_${control.toUpperCase().replace('-', '_')}_${check}_FAILED`);
      throw error;
    } finally {
      raw?.destroy(); secure?.destroy(); if (cli.child.exitCode === null) cli.child.kill(); await cli.done;
    }
    // Rebind chứng minh listener đã nhả, không suy từ timeout hoặc marker riêng lẻ.
    const rebound = net.createServer(); rebound.listen(8443, '127.0.0.1'); await once(rebound, 'listening');
    const closed = once(rebound, 'close'); rebound.close(); await closed;
    console.log(`PROXY_CLI_${control.toUpperCase().replace('-', '_')}_CLEANUP_PASS`);
  }
  } finally {
    for (const socket of upstreamSockets) socket.destroy();
    const closed = once(fixedUpstream, 'close'); fixedUpstream.close(); await closed;
  }
}

/**
 * Chờ một event socket với deadline và close guard để fault forwarding không treo suite.
 * Input
 * Param: socket — owned TLS client của case, caller luôn destroy trong finally.
 * Param: event — secureConnect hoặc data do test chọn cố định.
 * Output: arguments của event; reject khi transport đóng hoặc quá3giây, luôn bỏ listener/timer.
 */
async function boundedSocketEvent(socket, event) {
  const controller = new AbortController();
  const timer = setTimeout(/** Deadline lỗi test không được biến thành transport PASS. */
    () => controller.abort(), 3_000);
  try {
    return await Promise.race([once(socket, event, { signal: controller.signal }),
      once(socket, 'close', { signal: controller.signal }).then(
        /** Peer đóng trước event mong đợi phải fail ngay thay vì để promise treo. */
        () => { throw new Error('TEST_SOCKET_CLOSED'); })]);
  } finally { clearTimeout(timer); controller.abort(); }
}

/** Kiểm oracle chỉ phát enum một lần mỗi connection và không làm thay đổi bytes HTTP synthetic. */
async function verifyRequestObserver() {
  const certificates = createCertificates();
  const material = certificates.valid;
  try {
    // Signature bytes are public data. Altering them preserves X509 structure, not TLS trust/signature validity.
    const publicDer = Buffer.from(new X509Certificate(material.certificate).raw);
    const alignedSignatureOffset = Math.floor((publicDer.length - 6) / 3) * 3;
    Buffer.from('pfxA', 'base64').copy(publicDer, alignedSignatureOffset);
    const encoded = new X509Certificate(publicDer).raw.toString('base64');
    assert.equal(encoded.includes('pfx'), true);
    assertPublicCliReady(`${cliReadyPrefix}\nAUTH_LAB_CA_CERT=${encoded}\n`);
    const syntheticReady = `${cliReadyPrefix}\nAUTH_LAB_CA_CERT=${encoded}\n`;
    assertPublicCliStopped(syntheticReady + 'LOCAL_HTTPS_PROXY_STOPPED\n', syntheticReady);
    assert.throws(() => assertPublicCliStopped(syntheticReady + 'pfx=SYNTHETIC_DELAYED_FIELD\nLOCAL_HTTPS_PROXY_STOPPED\n', syntheticReady));
    for (const invalid of [
      `${cliReadyPrefix}\nAUTH_LAB_CA_CERT=${encoded}\npfx=SYNTHETIC_PRIVATE_FIELD\n`,
      `${cliReadyPrefix}\nAUTH_LAB_CA_CERT=-----BEGIN PRIVATE KEY-----\n`,
      `${cliReadyPrefix}\nAUTH_LAB_CA_CERT=${Buffer.from('not-a-certificate').toString('base64')}\n`,
    ]) assert.throws(() => assertPublicCliReady(invalid));
    console.log('PROXY_PUBLIC_CERT_SCHEMA_ALPHABET_REGRESSION_PASS');
    for (const [line, expected] of [
      ['POST /api/v1/auth/login HTTP/1.1', 'AUTH_LOGIN'],
      ['GET /api/v1/me HTTP/1.1', 'PROFILE_READ'],
      ['POST /api/v1/auth/login?synthetic=1 HTTP/1.1', 'OTHER'],
      ['GET /api/v1/workspaces HTTP/1.1', 'WORKSPACE_LIST'],
      ['GET /api/v1/workspaces?cursor=synthetic HTTP/1.1', 'OTHER'],
      ['POST /api/v1/workspaces HTTP/1.1', 'OTHER'],
      ['GET /api/v1/workspaces/synthetic HTTP/1.1', 'OTHER'],
      ['GET /api/v1/workspaces-extra HTTP/1.1', 'OTHER'],
      ['GET /api/v1/workspaces/ HTTP/1.1', 'OTHER'],
      ['GET /api/v1/workspaces HTTP/1.0', 'OTHER'],
      ['POST /api/v1/auth/password HTTP/1.1', 'PASSWORD_CHANGE'],
      ['POST /api/v1/auth/password?synthetic=1 HTTP/1.1', 'OTHER'],
      ['GET /api/v1/auth/password HTTP/1.1', 'OTHER'],
      ['POST /api/v1/auth/password-extra HTTP/1.1', 'OTHER'],
      ['POST /api/v1/auth/password/ HTTP/1.1', 'OTHER'],
      ['POST /api/v1/auth/logout HTTP/1.1', 'AUTH_LOGOUT'],
      ['POST /api/v1/auth/logout?synthetic=1 HTTP/1.1', 'OTHER'],
      ['GET /api/v1/auth/logout HTTP/1.1', 'OTHER'],
      ['POST /api/v1/auth/logout-extra HTTP/1.1', 'OTHER'],
      ['POST /api/v1/auth/logout/ HTTP/1.1', 'OTHER'],
      ['POST /api/v1/auth/logout HTTP/1.0', 'OTHER'],
    ]) {
      const events = [];
      const request = Buffer.from(`${line}\r\nX-Synthetic: ignored\r\n\r\nbody`);
      await withSynthetic(material,
        /**
         * Echo nguyên bytes giả để chứng minh observer không rewrite request.
         * Input
         * Param: socket — upstream synthetic do test sở hữu.
         */
        (socket) => socket.pipe(socket), {},
        /**
         * Đọc echo đầu tiên rồi đóng client, tránh chờ backend echo tự FIN.
         * Input
         * Param: proxy — listener TLS đã bind.
         */
        async (proxy) => {
          const client = tls.connect({ host: '127.0.0.1', port: proxy.port, servername: 'localhost', ca: material.certificate });
          try {
            await boundedSocketEvent(client, 'secureConnect');
            const echo = boundedSocketEvent(client, 'data'); client.write(request);
            assert.deepEqual((await echo)[0], request);
            assert.deepEqual(events, [expected]);
          } finally { client.destroy(); }
        },
        /**
         * Chỉ lưu enum để phát hiện observer đưa raw line/header/body ra caller.
         * Input
         * Param: kind — giá trị duy nhất callback được phép nhận.
         */
        (kind) => { events.push(kind); });
    }
    console.log('PROXY_REQUEST_OBSERVER_EXACT_ROUTES_PASS');

    // Các mutation và first-page workspace đều phải chờ đủ CRLF; route giả ở body không được emit lần hai.
    for (const [fragments, expected] of [
      [['POST /api/v1/auth/', 'login HTTP/1.1\r', '\n\r\nGET /api/v1/me HTTP/1.1\r\n'], 'AUTH_LOGIN'],
      [['GET /api/v1/work', 'spaces HTTP/1.1\r', '\n\r\nPOST /api/v1/auth/login HTTP/1.1\r\n'], 'WORKSPACE_LIST'],
      [['POST /api/v1/auth/pass', 'word HTTP/1.1\r', '\n\r\nGET /api/v1/workspaces HTTP/1.1\r\n'], 'PASSWORD_CHANGE'],
      [['POST /api/v1/auth/log', 'out HTTP/1.1\r', '\n\r\nPOST /api/v1/auth/login HTTP/1.1\r\n'], 'AUTH_LOGOUT'],
    ]) {
    const events = [];
    await withSynthetic(material,
      /**
       * Echo giúp ACK từng fragment trước fragment sau, không phụ thuộc TCP gộp chunk.
       * Input
       * Param: socket — upstream synthetic.
       */
      (socket) => socket.pipe(socket), {},
      /**
       * Chia cả CRLF và giữ body có route giả, oracle vẫn chỉ emit một lần sau CRLF đầu.
       * Input
       * Param: proxy — endpoint test.
       */
      async (proxy) => {
        const client = tls.connect({ host: '127.0.0.1', port: proxy.port, servername: 'localhost', ca: material.certificate });
        try {
          await boundedSocketEvent(client, 'secureConnect');
          for (const [index, fragment] of fragments.entries()) {
            const echo = boundedSocketEvent(client, 'data'); client.write(fragment);
            assert.equal((await echo)[0].toString(), fragment);
            assert.deepEqual(events, index < 2 ? [] : [expected]);
          }
        } finally { client.destroy(); }
      },
      /**
       * Đếm enum, không giữ payload ngoài oracle của test.
       * Input
       * Param: kind — enum từ observer.
       */
      (kind) => { events.push(kind); });
    }
    console.log('PROXY_REQUEST_OBSERVER_FRAGMENTED_ONCE_PASS');

    for (const fault of ['prefix', 'callback']) {
      const observed = [];
      await withSynthetic(material,
        /**
         * Backend chỉ echo; việc đóng phải do observer của proxy thực hiện.
         * Input
         * Param: socket — owned synthetic connection.
         */
        (socket) => socket.pipe(socket), {},
        /**
         * Prefix quá256 hoặc callback lỗi phải đóng transport trước forward chunk lỗi.
         * Input
         * Param: proxy — endpoint với observer bật.
         */
        async (proxy) => assert.equal((await exchange(material, proxy.port,
          Buffer.from(fault === 'prefix' ? 'X'.repeat(257) : 'GET /api/v1/me HTTP/1.1\r\n\r\n'))).length, 0),
        /**
         * Tiêm lỗi callback không chứa raw input; proxy phải xử lý như lỗi transport.
         * Input
         * Param: kind — chỉ enum, không line/URL/query.
         */
        (kind) => { observed.push(kind); if (fault === 'callback') throw new Error('SYNTHETIC_OBSERVER_FAULT'); });
      assert.deepEqual(observed, fault === 'prefix' ? [] : ['PROFILE_READ']);
    }
    console.log('PROXY_REQUEST_OBSERVER_BOUNDS_FAILURE_PASS');
  } finally { for (const value of Object.values(certificates)) value.pfx.fill(0); }
}

try {
  await verifyRequestObserver(); await main(); await verifyBridgeBounds(); await verifyCli();
  console.log('LOCAL_HTTPS_PROXY_19_BASE_27_OBSERVER_CASES_PASS');
} catch (error) {
  // Không xuất exception/capture chứa material; RED/GREEN chỉ dùng marker và exit code.
  console.error(error.code === 'ERR_ASSERTION' ? 'PROXY_TEST_ASSERTION_FAILED' :
    error.message === 'TEST_CLOSE_TIMEOUT' ? 'PROXY_TEST_CLOSE_TIMEOUT' : 'PROXY_TEST_BOUNDARY_FAILED');
  console.error('LOCAL_HTTPS_PROXY_TEST_FAILED');
  process.exitCode = 1;
}
