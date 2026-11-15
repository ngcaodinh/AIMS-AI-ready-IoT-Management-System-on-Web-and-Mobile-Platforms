import assert from 'node:assert/strict';
import net from 'node:net';
import tls from 'node:tls';
import { once } from 'node:events';
import { Transform } from 'node:stream';
import { pathToFileURL } from 'node:url';
import { X509Certificate } from 'node:crypto';
import { createCertificates } from './memory_tls_material.mjs';
import { createHttpMetadataCapture } from './http_metadata_capture.mjs';
import { createHttpMetadataControl, parseObservedProxyArguments } from './http_metadata_control.mjs';

// Budget công cụ lab: App giới hạn15s/128KiB; bridge cho headroom hữu hạn, không phục vụ production.
const defaults = Object.freeze({ port: 8443, upstreamPort: 3000, maxConnections: 32,
  handshakeMilliseconds: 5_000, idleMilliseconds: 20_000, connectionMilliseconds: 30_000,
  lifetimeMilliseconds: 50 * 60_000, maxBytes: 1024 * 1024 });

/**
 * Giới hạn byte trước forward để peer không vượt budget bằng chunk cuối quá lớn.
 * Input
 * Param: maximum — tổng bytes tối đa một hướng trong toàn kết nối.
 * Param: observer — callback enum đồng bộ tùy chọn; chỉ request direction có oracle này.
 * Output: Transform giữ backpressure và lỗi cố định; không buffer toàn payload.
 */
function createByteLimit(maximum, observer) {
  let length = 0;
  // Chỉ giữ tối đa256 bytes đến CRLF đầu, không giữ header/body/query sau khi phân loại enum.
  let prefix = observer ? Buffer.alloc(256) : undefined;
  let prefixLength = 0;
  return new Transform({
    /**
     * Chỉ chuyển nguyên chunk còn trong budget; không log byte hoặc nội dung auth.
     * Input
     * Param: chunk — bytes stream cần chuyển.
     * Param: encoding — encoding do stream cung cấp, không dùng vì chunk là Buffer.
     * Param: callback — báo chunk hợp lệ hoặc lỗi để đóng cả kết nối.
     */
    transform(chunk, encoding, callback) {
      length += chunk.length;
      if (length > maximum) { callback(new Error('PROXY_BYTE_LIMIT')); return; }
      try {
        if (prefix) {
          for (const byte of chunk) {
            if (prefixLength === prefix.length) throw new Error('PROXY_REQUEST_LINE_LIMIT');
            prefix[prefixLength++] = byte;
            if (byte === 10) {
              const line = prefix.subarray(0, prefixLength);
              // Chỉ first-page đúng literal mới là workspace canary; query/detail/lookalike không được bù refresh bị thiếu.
              const kind = line.equals(Buffer.from('POST /api/v1/auth/login HTTP/1.1\r\n')) ? 'AUTH_LOGIN' :
                line.equals(Buffer.from('GET /api/v1/me HTTP/1.1\r\n')) ? 'PROFILE_READ' :
                  line.equals(Buffer.from('GET /api/v1/workspaces HTTP/1.1\r\n')) ? 'WORKSPACE_LIST' :
                    line.equals(Buffer.from('POST /api/v1/auth/password HTTP/1.1\r\n')) ? 'PASSWORD_CHANGE' :
                      line.equals(Buffer.from('POST /api/v1/auth/logout HTTP/1.1\r\n')) ? 'AUTH_LOGOUT' : 'OTHER';
              prefix.fill(0); prefix = undefined;
              observer(kind);
              break;
            }
          }
        }
        callback(null, chunk);
      } catch {
        // Callback lỗi hoặc prefix quá cap không được forward chunk hay log raw request.
        prefix?.fill(0); prefix = undefined;
        callback(new Error('PROXY_REQUEST_OBSERVER_FAILED'));
      }
    },
    /**
     * Xóa prefix chưa đủ CRLF khi disconnect; không giữ metadata request trong stream đã terminal.
     * Input
     * Param: error — lỗi stream đã có, không phản chiếu nội dung ra log.
     * Param: callback — completion cleanup do Node stream cung cấp.
     */
    destroy(error, callback) { prefix?.fill(0); prefix = undefined; callback(error); },
  });
}

/**
 * Mở cầu nối TLS loopback có ownership; tùy chọn chỉ dành test nội bộ, CLI dùng defaults cố định.
 * Input
 * Param: material — PFX/public cert RAM do helper sở hữu, không được log/lưu file.
 * Param: options — port/budget test synthetic; host cả hai phía luôn127.0.0.1.
 * Param: observer — callback enum đồng bộ tùy chọn của runner; chỉ quan sát request line đầu mỗi connection.
 * Output: port, signal unavailable, raw terminal và close/closed idempotent; bounded false không phải terminal.
 * Param: runtime — trusted TLS server/timer và optional httpMetadata cho instrumentation lab, không nhận capability từ mạng.
 * Errors: bind/config/TLS setup bị từ chối; không khởi động hoặc dừng upstream backend.
 */
export async function startLocalHttpsProxy(material, options = {}, observer, runtime = {}) {
  assert.ok(observer === undefined || typeof observer === 'function', 'INVALID_PROXY_OBSERVER');
  const httpMetadata = runtime.httpMetadata;
  assert.ok(httpMetadata === undefined || httpMetadata &&
    ['openRaw', 'openExchange', 'snapshot', 'seal'].every(
      /** Capture capability chỉ dành owner trusted, thiếu method bị chặn trước mở socket.
       * Input
       * Param: method — tên method nội bộ bắt buộc của capture.
       */
      (method) => typeof httpMetadata[method] === 'function'), 'INVALID_HTTP_METADATA_CAPTURE');
  const configuration = { ...defaults, ...options };
  for (const [key, value] of Object.entries(configuration)) {
    assert.ok(Object.hasOwn(defaults, key) && Number.isSafeInteger(value) &&
      value >= (key === 'port' ? 0 : 1) &&
      value <= (key === 'port' || key === 'upstreamPort' ? 65_535 : defaults[key]), 'INVALID_PROXY_CONFIGURATION');
  }
  // Test dùng port OS cấp cho upstream; runtime CLI vẫn cố định3000.
  assert.ok(configuration.upstreamPort <= 65_535, 'INVALID_PROXY_CONFIGURATION');
  const rawSockets = new Set();
  const streams = new Set();
  // Listener chỉ bind127.0.0.1, remotePort phân biệt các raw connections đang sống trong cùng listener.
  const metadataRawOwners = new Map();
  const metadataClosures = new Set();
  const schedule = runtime.setTimeout ?? setTimeout;
  const cancel = runtime.clearTimeout ?? clearTimeout;
  const unavailable = new AbortController();
  let finishTerminal;
  const terminal = new Promise(
    /** Giữ raw terminal riêng với bounded close để không nhầm cleanup timeout thành đã nhả handle.
     * Input
     * Param: resolve — ACK chỉ gọi sau toàn bộ listener/stream/capture closure.
     */
    (resolve) => { finishTerminal = resolve; });
  let stopping = false;
  let failed = false;
  let listenerClosed = false;
  let listeningAcquired = false;
  let finish;
  let cleanup;
  let lifetime;
  const closed = new Promise(
    /**
     * Giữ completion không reject để timer/signal không tạo unhandled rejection.
     * Input
     * Param: resolve — trả kết quả cleanup cố định cho owner đang await.
     */
    (resolve) => { finish = resolve; });

  /** Đóng đúng listener/stream do bridge sở hữu; mọi caller dùng chung một completion hữu hạn. */
  function close() {
    if (stopping) return closed;
    stopping = true;
    unavailable.abort();
    cancel(lifetime);
    cleanup = schedule(
      /** Báo cleanup chưa ACK đúng hạn; không kill process/port ngoài ownership. */
      () => { finish(false); }, 5_000);
    const pending = [];
    for (const stream of new Set([...streams, ...rawSockets])) {
      if (!stream.closed) pending.push(new Promise(
        /**
         * Chờ close ACK từng handle thay vì coi destroy() là đã terminal.
         * Input
         * Param: resolve — completion khi owned stream phát close thực.
         */
        (resolve) => stream.once('close', resolve)));
      try { stream.destroy(); } catch { failed = true; }
    }
    pending.push(new Promise(
      /**
       * Chờ listener nhả port để không báo STOPPED trước cleanup socket/upstream.
       * Input
       * Param: resolve — completion sau Node close callback.
       */
      (resolve) => {
        if (listenerClosed) { resolve(); return; }
        try { server.close(
        /**
         * Ghi trạng thái cố định, không đưa exception có thể chứa endpoint/data ra console.
         * Input
         * Param: error — close error do Node trả về.
         */
        (error) => {
          if (error) {
            failed = true;
            if (listenerClosed) resolve(); else server.once('close', resolve);
          } else { listenerClosed = true; resolve(); }
        });
        } catch {
          failed = true;
          if (listenerClosed) resolve(); else server.once('close', resolve);
        }
      }));
    pending.push(...metadataClosures);
    void Promise.all(pending).then(
      /** Chỉ seal sau mọi socket/pipe/ledger closure, rồi mới ACK owned terminal của proxy. */
      () => {
        if (httpMetadata) {
          try { httpMetadata.seal(); } catch { failed = true; }
        }
        cancel(cleanup); finish(!failed); finishTerminal();
      });
    return closed;
  }

  /** Metadata fault làm proxy unavailable ngay và giữ cleanup owned tới raw terminal. */
  function failMetadata() {
    failed = true;
    void close();
  }

  const server = (runtime.createServer ?? tls.createServer)({ pfx: material.pfx, minVersion: 'TLSv1.2',
    handshakeTimeout: configuration.handshakeMilliseconds },
    /**
     * Chuyển stream sau TLS tới duy nhất HTTP backend loopback; không sửa HTTP hoặc replay mutation.
     * Input
     * Param: socket — TLS peer đã handshake; auth/authorization vẫn do backend kiểm.
     */
    (socket) => {
      if (stopping) { socket.destroy(); return; }
      socket.disableRenegotiation();
      let metadata;
      if (httpMetadata) {
        try {
          // Secure socket dùng endpoint công khai của Node để tìm đúng capability raw đã admit, không đọc private parent.
          const rawOwner = metadataRawOwners.get(socket.remotePort);
          assert.ok(rawOwner, 'HTTP_METADATA_RAW_OWNER_MISSING');
          metadata = httpMetadata.openExchange(rawOwner);
        } catch { socket.destroy(); failMetadata(); return; }
      }
      const upstream = net.connect({ host: '127.0.0.1', port: configuration.upstreamPort });
      const requestLimit = createByteLimit(configuration.maxBytes, observer);
      const responseLimit = createByteLimit(configuration.maxBytes);
      const owned = [socket, upstream, requestLimit, responseLimit];
      if (metadata) owned.push(metadata.request, metadata.response);
      /** Kết thúc cả hai hướng khi lỗi/timeout; metadata lỗi cũng đóng proxy, giữ outcome transport riêng. */
      function abort() {
        for (const stream of owned) stream.destroy();
        if (metadata && !httpMetadata.snapshot().healthy) failMetadata();
      }
      if (metadata) {
        const pendingClose = Promise.all(owned.map(
          /** Chờ toàn bộ handle của exchange, kể cả upstream và TLS socket ngoài hai capture pipes.
           * Input
           * Param: stream — handle owned phải phát close trước ledger CLOSED.
           */
          (stream) => new Promise(
            /** Gắn close observer trước pipe/error để không mất terminal event nhanh.
             * Input
             * Param: resolve — ACK raw close của handle.
             */
            (resolve) => { if (stream.closed) resolve(); else stream.once('close', resolve); }))).then(
          /** Chốt metadata sau owned terminal, failure không được biến thành clean shutdown. */
          () => {
            try {
              metadata.close();
              if (!httpMetadata.snapshot().healthy) failMetadata();
            } catch { failMetadata(); }
          }).finally(
            /** Bỏ đúng Promise đã settled, proxy.close vẫn chờ mọi closure còn pending. */
            () => metadataClosures.delete(pendingClose));
        metadataClosures.add(pendingClose);
      }
      for (const stream of owned) {
        streams.add(stream);
        stream.on('error', abort);
        stream.on('close', /** Bỏ đúng stream terminal, không giữ payload sau operation. */
          () => streams.delete(stream));
      }
      socket.on('close', abort);
      upstream.on('close',
        /** Bình thường phải để pipe flush TLS; close bất thường mới hủy response đang dở. */
        () => { if (!upstream.readableEnded) abort(); });
      socket.setTimeout(configuration.idleMilliseconds, abort);
      upstream.setTimeout(configuration.idleMilliseconds, abort);
      if (metadata) {
        socket.pipe(requestLimit).pipe(metadata.request).pipe(upstream);
        upstream.pipe(responseLimit).pipe(metadata.response).pipe(socket);
      } else {
        socket.pipe(requestLimit).pipe(upstream);
        upstream.pipe(responseLimit).pipe(socket);
      }
    });
  server.on('connection',
    /**
     * Giới hạn raw peer trước handshake và deadline toàn phiên để chống trickle giữ tài nguyên.
     * Input
     * Param: socket — raw TCP socket do listener sở hữu, kể cả TLS chưa hợp lệ.
     */
    (socket) => {
      socket.on('error', /** Lỗi raw đã chuyển thành close; không log stack/data của peer. */ () => {});
      if (stopping || rawSockets.size >= configuration.maxConnections) {
        socket.destroy();
        // Observed run mất coverage khi cap từ chối peer trước raw admission, phải hủy toàn bộ proof của lượt.
        if (!stopping && httpMetadata) failMetadata();
        return;
      }
      rawSockets.add(socket);
      const remotePort = socket.remotePort;
      let rawOwner;
      const deadline = schedule(/** Deadline không reset theo traffic hoặc TLS renegotiation. */
        () => socket.destroy(), configuration.connectionMilliseconds);
      socket.on('close', /** Giải phóng slot và timer khi raw transport terminal. */
        () => {
          cancel(deadline); rawSockets.delete(socket);
          if (rawOwner) {
            // Port có thể được OS tái sử dụng sau close, chỉ xóa entry vẫn thuộc chính raw handle này.
            if (metadataRawOwners.get(remotePort) === rawOwner) metadataRawOwners.delete(remotePort);
            rawOwner();
          }
        });
      if (httpMetadata) {
        try {
          assert.ok(Number.isSafeInteger(remotePort) && remotePort > 0 && remotePort <= 65535 &&
            !metadataRawOwners.has(remotePort), 'HTTP_METADATA_RAW_OWNER_INVALID');
          rawOwner = httpMetadata.openRaw();
          metadataRawOwners.set(remotePort, rawOwner);
        } catch { socket.destroy(); failMetadata(); }
      }
    });
  server.on('tlsClientError',
    /**
     * Đóng peer handshake lỗi/quá hạn; chỉ nhận event không bảo đảm raw transport đã đóng.
     * Input
     * Param: error — lỗi SDK, không log vì có thể chứa peer material.
     * Param: socket — TLS socket thuộc listener cần hủy để nhả raw slot.
     */
    (error, socket) => socket.destroy());
  server.on('error',
    /** Sau bind, lỗi listener đóng bridge fail-closed; trước bind do once(listening) trả lỗi cho owner. */
    () => { failed = true; if (listeningAcquired) void close(); else unavailable.abort(); });
  server.on('listening', /** Chốt ownership bind trước lỗi listener để shutdown đúng nhánh. */ () => { listeningAcquired = true; });
  server.on('close', /** Listener đóng ngoài yêu cầu là failure, vẫn giữ cleanup owned tới terminal. */ () => {
    listenerClosed = true;
    if (!stopping) { failed = true; void close(); }
  });
  // Cấp ownership trước async bind để caller vẫn cleanup được khi bind lỗi, chỉ chốt port sau readiness.
  const owner = { port: undefined, close, closed, terminal, signal: unavailable.signal };
  if (httpMetadata) {
    /** Snapshot đồng bộ phải kiểm cả availability proxy và raw/secure capture khi lập temporal fence. */
    owner.httpSnapshot = () => ({ ...httpMetadata.snapshot(), proxyAvailable: !failed && !stopping });
  }
  try {
    assert.equal(runtime.onOwned?.(owner), undefined, 'PROXY_OWNERSHIP_HOOK_INVALID');
    assert.ok(!stopping, 'PROXY_BIND_FAILED');
    // close/abort phải đánh thức bind pending, catch vẫn giữ raw terminal trước trả failure.
    const listening = once(server, 'listening', { signal: unavailable.signal });
    listening.catch(/** Rejection đã được await bên dưới, drain sớm để không tạo unhandled khi close trong startup. */ () => {});
    server.listen(configuration.port, '127.0.0.1');
    await listening;
    const address = server.address();
    assert.ok(!failed && !stopping && server.listening && address && Number.isSafeInteger(address.port), 'PROXY_BIND_FAILED');
    owner.port = address.port;
    lifetime = schedule(/** Hết thời gian lab phải đóng owned endpoint dù không còn user thao tác. */
      () => { void close(); }, configuration.lifetimeMilliseconds);
    return owner;
  } catch {
    close(); await terminal;
    throw new Error('PROXY_BIND_FAILED');
  }
}

/**
 * Chạy CLI TLS cố định cho emulator, observed mode xuất ledger bounded qua writer có ACK.
 * Side effects: sở hữu8443 tối đa50phút, chỉ giữ public certificate và metadata, đóng đúng owned proxy.
 */
async function main() {
  const observed = parseObservedProxyArguments(process.argv.slice(2));
  const started = Date.now();
  const certificates = createCertificates();
  let proxy;
  let input = '';
  /** Đóng bridge owned, raw terminal vẫn được await riêng trong observed mode. */
  function stop() { if (proxy) void proxy.close(); }
  const control = observed ? createHttpMetadataControl({ output: process.stdout,
    snapshot:
      /** Chụp đúng ledger/availability của proxy owned, không dùng counter từ backend khác. */
      () => proxy.httpSnapshot(), stop }) : undefined;
  const capture = observed ? createHttpMetadataCapture({ ...observed, onEvent: control.publish }) : undefined;
  /**
   * Giữ parser legacy khi noargs, observed mode giao frame bounded cho controller riêng.
   * Input
   * Param: chunk — control bytes stdin, chỉ nhận lệnh quản lý proxy.
   */
  function onInput(chunk) {
    if (control) { control.onInput(chunk); return; }
    if (chunk.length + input.length > 16 || !/^[STOP\r\n]*$/.test(chunk.toString('ascii'))) { stop(); return; }
    input += chunk.toString('ascii');
    if (input.endsWith('\n')) stop();
  }
  /** EOF observed cần kiểm partial frame trước shutdown, EOF legacy giữ hành vi hiện có. */
  function onEnd() { if (control) control.onEnd(); else stop(); }
  try {
    proxy = await startLocalHttpsProxy(certificates.valid,
      { lifetimeMilliseconds: Math.max(1, defaults.lifetimeMilliseconds - (Date.now() - started)) },
      undefined, control ? { httpMetadata: capture,
        onOwned:
          /** Giữ ownership trước async bind để lỗi stdout/startup vẫn có endpoint được cleanup.
           * Input
           * Param: owner — handle do proxy cấp trước bind.
           */
          (owner) => { proxy = owner; if (control.failed) void owner.close(); } } : {});
    for (const value of Object.values(certificates)) value.pfx.fill(0);
    process.stdin.on('data', onInput);
    process.stdin.on('end', onEnd);
    process.on('SIGINT', stop);
    process.on('SIGTERM', stop);
    if (control) control.ready(certificates.valid.certificate);
    else {
      console.log('LOCAL_HTTPS_PROXY_READY origin=https://10.0.2.2:8443 upstream=127.0.0.1:3000 ttlMinutes=50');
      console.log(`AUTH_LAB_CA_CERT=${new X509Certificate(certificates.valid.certificate).raw.toString('base64')}`);
    }
    process.stdin.resume();
    if (!await proxy.closed) throw new Error('PROXY_SHUTDOWN_FAILED');
    if (control) { await proxy.terminal; await control.finish(); }
    else console.log('LOCAL_HTTPS_PROXY_STOPPED');
  } finally {
    if (proxy) {
      await proxy.close();
      if (control) await proxy.terminal;
    }
    if (control) await control.settle();
    process.stdin.off('data', onInput);
    process.stdin.off('end', onEnd);
    process.off('SIGINT', stop);
    process.off('SIGTERM', stop);
    process.stdin.pause();
    for (const value of Object.values(certificates)) value.pfx.fill(0);
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try { await main(); } catch {
    // Không đưa exception/child capture/private material hoặc auth payload vào console.
    console.error('LOCAL_HTTPS_PROXY_FAILED');
    process.exitCode = 1;
  }
}
