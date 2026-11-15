import assert from 'node:assert/strict';
import { createCertificates } from './memory_tls_material.mjs';
import { once } from 'node:events';
import tls from 'node:tls';

/**
 * Kiểm một phiên TLS bằng validation mặc định của SDK và deadline xuyên suốt connect/auth/read/end.
 * Input
 * Param: port — listener loopback do probe sở hữu.
 * Param: certificate — CA riêng cho case; undefined dùng mặc định để kiểm no-trust.
 * Param: servername — hostname cần SDK kiểm, null kiểm IP host trực tiếp.
 * Param: expectedError — mã lỗi TLS phải xuất hiện; null yêu cầu authorized và marker đúng.
 * Output: resolve khi đúng nhánh, reject nếu sai hoặc quá10giây; luôn destroy socket riêng.
 */
async function verifyClient(port, certificate, servername, expectedError = null) {
  const socket = tls.connect({ host: '127.0.0.1', port, ca: certificate,
    ...(servername === null ? {} : { servername }), minVersion: 'TLSv1.2',
    rejectUnauthorized: true });
  // Đếm theo wall deadline, không reset bởi data trickle hoặc handshake đã xong.
  const timer = setTimeout(
    /** Đóng đúng client để cả connect và read đều kết thúc khi hết budget. */
    () => socket.destroy(new Error('TLS_CASE_TIMEOUT')), 10_000);
  try {
    const chunks = [];
    let length = 0;
    for await (const chunk of socket) {
      length += chunk.length;
      assert.ok(length <= 1, 'INVALID_TLS_MARKER');
      chunks.push(chunk);
    }
    assert.equal(expectedError, null, 'EXPECTED_TLS_REJECTION');
    assert.equal(socket.authorized, true, 'TLS_NOT_AUTHORIZED');
    assert.deepEqual(Buffer.concat(chunks), Buffer.from([65]));
  } catch (error) {
    if (expectedError === null || error.code !== expectedError) throw new Error('TLS_CASE_FAILED');
  } finally {
    clearTimeout(timer);
    socket.destroy();
  }
}

/**
 * Sở hữu listener loopback và raw sockets kể cả handshake thất bại; không giữ endpoint sau case.
 * Input
 * Param: material — PFX RAM do child tạo, không được log hoặc lưu xuống file.
 * Param: verify — nhóm case tuần tự nhận port OS cấp của listener.
 * Output: hoàn tất nhóm case và đóng server trong5giây, lỗi không được coi là PASS.
 */
async function withServer(material, verify) {
  const sockets = new Set();
  let serverFailed = false;
  const server = tls.createServer({ pfx: material.pfx, minVersion: 'TLSv1.2', handshakeTimeout: 5_000 },
    /**
     * Gửi marker cố định sau handshake thật; không đọc auth hoặc dữ liệu người dùng.
     * Input
     * Param: socket — TLS socket thuộc listener probe.
     */
    (socket) => {
      socket.on('error',
        /** Ghi lỗi sau handshake bằng cờ cố định để không phát stack/material hoặc báo PASS giả. */
        () => { serverFailed = true; });
      socket.end(Buffer.from([65]));
    });
  server.on('error',
    /** Giữ lỗi listener trong boundary của probe; case/deadline và assertion cuối quyết định thất bại. */
    () => { serverFailed = true; });
  server.on('connection',
    /**
     * Track raw socket trước handshake để cleanup cũng sở hữu peer bị từ chối/chưa xác thực.
     * Input
     * Param: socket — TCP socket do listener nhận, không phải process/session ngoài probe.
     */
    (socket) => {
      sockets.add(socket);
      socket.on('close',
        /** Bỏ đúng handle đã đóng khỏi tập cleanup. */
        () => sockets.delete(socket));
    });
  server.on('tlsClientError',
    /** Nhánh từ chối TLS được client assertion kiểm; không log lỗi/certificate của peer. */
    () => {});
  try {
    server.listen(0, '127.0.0.1');
    await once(server, 'listening');
    const address = server.address();
    assert.equal(address.address, '127.0.0.1');
    await verify(address.port);
  } finally {
    for (const socket of sockets) socket.destroy();
    const closed = once(server, 'close');
    server.close();
    let timer;
    try {
      await Promise.race([closed, new Promise(
        /**
         * Đặt budget cleanup hữu hạn, không treo test sau assertion/handshake lỗi.
         * Input
         * Param: resolve — completion không dùng vì timer chỉ biểu diễn lỗi.
         * Param: reject — báo không đóng listener đúng hạn.
         */
        (resolve, reject) => { timer = setTimeout(
          /** Báo lỗi cố định khi ownership chưa được drain đúng hạn. */
          () => reject(new Error('TLS_CLEANUP_TIMEOUT')), 5_000); })]);
    } finally { clearTimeout(timer); }
    assert.equal(serverFailed, false, 'TLS_SERVER_FAILED');
  }
}

/** Chạy sáu handshake thật; chỉ in marker sau assertion, không phát certificate/private material. */
async function main() {
  const certificates = createCertificates();
  try {
    await withServer(certificates.valid,
      /**
       * Kiểm trusted DNS/IP và ba rejection độc lập trên cùng leaf hợp lệ.
       * Input
       * Param: port — endpoint loopback đã được parent chốt ownership.
       */
      async (port) => {
        await verifyClient(port, certificates.valid.certificate, 'localhost');
        console.log('TLS_TRUSTED_LOCALHOST_PASS');
        await verifyClient(port, certificates.valid.certificate, null);
        console.log('TLS_TRUSTED_IP_PASS');
        await verifyClient(port, undefined, 'localhost', 'DEPTH_ZERO_SELF_SIGNED_CERT');
        console.log('TLS_NO_TRUST_REJECTED');
        await verifyClient(port, certificates.other.certificate, 'localhost', 'DEPTH_ZERO_SELF_SIGNED_CERT');
        console.log('TLS_WRONG_CA_REJECTED');
        await verifyClient(port, certificates.valid.certificate, 'wrong.example.invalid', 'ERR_TLS_CERT_ALTNAME_INVALID');
        console.log('TLS_WRONG_HOST_REJECTED');
      });
    await withServer(certificates.expired,
      /**
       * Kiểm expiry dù client tin đúng leaf; không tắt xác minh thời gian của SDK.
       * Input
       * Param: port — listener certificate hết hạn do probe sở hữu.
       */
      async (port) => {
        await verifyClient(port, certificates.expired.certificate, 'localhost', 'CERT_HAS_EXPIRED');
        console.log('TLS_EXPIRED_REJECTED');
      });
    console.log('MEMORY_TLS_6_CASES_PASS');
  } finally {
    for (const value of Object.values(certificates)) value.pfx.fill(0);
  }
}

try { await main(); } catch {
  // Không đưa error object/child output vào log vì có thể mang private material của capture/SDK.
  console.error('MEMORY_TLS_PROBE_FAILED');
  process.exitCode = 1;
}
