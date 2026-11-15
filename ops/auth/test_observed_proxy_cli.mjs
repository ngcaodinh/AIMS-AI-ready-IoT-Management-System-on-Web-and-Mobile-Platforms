import assert from 'node:assert/strict';
import net from 'node:net';
import tls from 'node:tls';
import { once } from 'node:events';
import { spawn } from 'node:child_process';
import { X509Certificate } from 'node:crypto';
import { setTimeout as delay } from 'node:timers/promises';

const target = '11111111-1111-4111-8111-111111111111';
const sentinel = 'SYNTHETIC_CLI_PRIVATE_PAYLOAD';
const readyLine = 'LOCAL_HTTPS_PROXY_READY origin=https://10.0.2.2:8443 upstream=127.0.0.1:3000 ttlMinutes=50';

/**
 * Đợi predicate bằng thời gian host hữu hạn, timeout luôn là test failure.
 * Input
 * Param: predicate — đọc state riêng của child/socket, không query DB.
 */
async function waitFor(predicate) {
  const deadline = performance.now() + 10000;
  while (!predicate()) {
    assert.ok(performance.now() < deadline, 'OBSERVED_CLI_TEST_TIMEOUT');
    await delay(10);
  }
}

/**
 * Mở một child CLI thuộc test và giữ output bounded trong RAM tới actual close.
 * Input
 * Param: args — allowlisted hoặc malformed synthetic argv cho negative cases.
 * Output: child, done và read-only output accessor, không log cert hoặc raw error.
 */
function startCli(args = ['--observe-http', '--target-workspace=' + target]) {
  const child = spawn(process.execPath, ['ops/auth/local_https_proxy.mjs', ...args],
    { stdio: ['pipe', 'pipe', 'pipe'], windowsHide: true });
  let output = '';
  let errors = '';
  let timedOut = false;
  let overflow = false;
  let spawnFailed = false;
  child.on('error', /** Spawn failure chỉ giữ cờ, không echo SDK exception. */ () => { spawnFailed = true; });
  child.stdin.on('error', /** Negative child đóng sớm có thể EPIPE stdin, outcome lấy từ actual child exit. */ () => {});
  child.stdout.on('data',
    /** Chỉ thu stdout public/schema để assertion, cap tránh test tích lũy output vô hạn.
     * Input
     * Param: chunk — bytes stdout từ child owned.
     */
    (chunk) => { output += chunk.toString('utf8'); if (output.length > 131072) { overflow = true; child.kill(); } });
  child.stderr.on('data',
    /** Stderr chỉ hợp lệ ở fixed failure marker, giữ bounded để assertion sau close.
     * Input
     * Param: chunk — stderr của chính CLI test.
     */
    (chunk) => { errors += chunk.toString('utf8'); if (errors.length > 4096) { overflow = true; child.kill(); } });
  const timer = setTimeout(/** Deadline kill chỉ dành child test, luôn đánh failure thay vì cleanup PASS. */
    () => { timedOut = true; child.kill(); }, 15000);
  const done = new Promise(
    /** Chờ close gồm cả stdio, không coi exit event riêng lẻ là output đã drain.
     * Input
     * Param: resolve — completion chứa actual exit code của child.
     */
    (resolve) => child.once('close',
      /** Đóng timer sau child và output streams đã terminal.
       * Input
       * Param: code — exit code do OS báo.
       * Param: signal — signal termination nếu test phải kill.
       */
      (code, signal) => { clearTimeout(timer); resolve({ code, signal }); }));
  return { child, done,
    /** Chụp state test để poll readiness hoặc assert sau terminal.
     * Output: public output cùng các cờ lỗi, không có credential thật.
     */
    read() { return { output, errors, timedOut, overflow, spawnFailed }; } };
}

/**
 * Chạy case sau readiness rồi luôn chờ đúng child terminal, kể cả assertion lỗi.
 * Input
 * Param: verify — assertions chủ động gửi control/TLS vào child owned.
 * Output: captured output chỉ trả cho caller host test.
 */
async function withCli(verify) {
  const cli = startCli();
  try {
    await waitFor(/** Chờ public cert line hoàn chỉnh, không suy readiness từ process spawn. */
      () => /^AUTH_LAB_CA_CERT=[A-Za-z0-9+/]+=*\n/m.test(cli.read().output) || cli.child.exitCode !== null);
    assert.equal(cli.child.exitCode, null, 'OBSERVED_CLI_EARLY_EXIT');
    const lines = cli.read().output.split('\n');
    assert.equal(lines[0], readyLine);
    const encoded = lines[1].slice('AUTH_LAB_CA_CERT='.length);
    const certificate = new X509Certificate(Buffer.from(encoded, 'base64'));
    assert.equal(certificate.raw.toString('base64'), encoded);
    await verify(cli, certificate.toString());
    const terminal = await cli.done;
    const result = cli.read();
    assert.equal(result.timedOut, false); assert.equal(result.overflow, false);
    assert.equal(result.spawnFailed, false); assert.equal(terminal.signal, null);
    assert.equal(result.output.includes(sentinel), false);
    assert.equal(result.errors.includes(sentinel), false);
    return { ...result, code: terminal.code };
  } finally {
    if (cli.child.exitCode === null) cli.child.kill();
    await cli.done;
    const probe = net.createServer();
    try {
      probe.listen(8443, '127.0.0.1'); await once(probe, 'listening');
    } finally {
      if (probe.listening) {
        const closed = once(probe, 'close'); probe.close(); await closed;
      }
    }
  }
}

/**
 * Chỉ đọc JSON frames từ stdout đã có ready/cert, kiểm frame sequence liên tục.
 * Input
 * Param: output — captured stdout synthetic.
 * Output: array JSON frames, không phản chiếu line khi parse/assert lỗi.
 */
function frames(output) {
  const result = output.split('\n').slice(0, -1).filter(
    /** Readiness và STOPPED là literal ngoài JSON protocol.
     * Input
     * Param: line — một stdout line.
     * Output: line thuộc JSON metadata.
     */
    (line) => line.startsWith('{')).map(
    /** Parse bounded JSON do CLI xuất để kiểm schema/order.
     * Input
     * Param: line — JSON metadata line.
     * Output: frame object.
     */
    (line) => JSON.parse(line));
  result.forEach(
    /** Frame ordinal bao gồm snapshots xen giữa events, không tái sử dụng capture sequence.
     * Input
     * Param: frame — metadata frame.
     * Param: index — vị trí emission liên tục bắt đầu từ0.
     */
    (frame, index) => assert.equal(frame.frameSequence, index + 1));
  return result;
}

/**
 * Lấy STATUS lặp hữu hạn tới khi snapshot thực tế thỏa điều kiện, tránh race accept TCP với stdin.
 * Input
 * Param: cli — child observer đang owned, đã readiness.
 * Param: matches — predicate chỉ đọc snapshot public để xác nhận raw admission.
 * Output: snapshot khớp từ đúng một STATUS hoàn chỉnh, timeout hoặc early exit làm test fail.
 */
async function snapshotWhere(cli, matches) {
  const deadline = performance.now() + 3000;
  while (performance.now() < deadline) {
    const previous = frames(cli.read().output).length;
    cli.child.stdin.write('STATUS\n');
    await waitFor(
      /** Chờ frame hoàn chỉnh sau command, không parse partial stdout chunk như JSON.
       * Output: có metadata mới hoặc child đã exit để assertion xử lý.
       */
      () => frames(cli.read().output).length > previous || cli.child.exitCode !== null);
    assert.equal(cli.child.exitCode, null, 'OBSERVED_CLI_EARLY_EXIT');
    const latest = frames(cli.read().output).at(-1);
    if (latest.frame === 'SNAPSHOT' && matches(latest.snapshot)) return latest.snapshot;
    await delay(10);
  }
  throw Error('OBSERVED_CLI_SNAPSHOT_TIMEOUT');
}

/**
 * Kiểm success chỉ sau FINAL idle/healthy/sealed và marker STOPPED thuộc actual child exit0.
 * Input
 * Param: result — stdout/stderr/exitcode sau original child close.
 * Output: final snapshot public để case kiểm exact counters.
 */
function assertFinal(result) {
  assert.equal(result.code, 0); assert.equal(result.errors, '');
  assert.ok(result.output.endsWith('LOCAL_HTTPS_PROXY_STOPPED\n'));
  const lines = result.output.trimEnd().split('\n');
  assert.equal(lines[0], readyLine);
  assert.match(lines[1], /^AUTH_LAB_CA_CERT=[A-Za-z0-9+/]+=*$/);
  assert.equal(frames(result.output).length, lines.length - 3);
  const finals = frames(result.output).filter(
    /** FINAL phải có đúng một lần trong stream hoàn chỉnh.
     * Input
     * Param: frame — frame đã parse.
     * Output: frame terminal.
     */
    (frame) => frame.frame === 'FINAL');
  assert.equal(finals.length, 1);
  const snapshot = finals[0].snapshot;
  assert.equal(snapshot.healthy, true); assert.equal(snapshot.sealed, true);
  assert.equal(snapshot.proxyAvailable, false);
  assert.equal(snapshot.rawActive, 0); assert.equal(snapshot.active, 0);
  assert.equal(snapshot.closed, snapshot.opened);
  return snapshot;
}

/**
 * Đọc actual TLS response với đúng public CA CLI, timeout là failure riêng.
 * Input
 * Param: certificate — public certificate child vừa publish sau bind.
 * Param: request — request bytes synthetic chứa sentinel để kiểm redaction.
 * Output: response bytes nguyên dạng tới TLS close.
 */
async function exchange(certificate, request) {
  const socket = tls.connect({ host: '127.0.0.1', port: 8443, servername: 'localhost',
    ca: certificate, rejectUnauthorized: true });
  let timedOut = false;
  const timer = setTimeout(/** Test deadline không được thay transport-close evidence. */
    () => { timedOut = true; socket.destroy(Error('OBSERVED_CLI_TLS_TIMEOUT')); }, 3000);
  try {
    await once(socket, 'secureConnect');
    assert.equal(socket.authorized, true);
    socket.write(request);
    const chunks = [];
    for await (const chunk of socket) chunks.push(chunk);
    assert.equal(timedOut, false);
    return Buffer.concat(chunks);
  } finally { clearTimeout(timer); socket.destroy(); }
}

const request = Buffer.from('GET /api/v1/workspaces/' + target +
  ' HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\nCookie: ' + sentinel + '\r\n\r\n');
const response = Buffer.from('HTTP/1.1 404 ' + sentinel +
  '\r\nContent-Length: 2\r\nConnection: close\r\nSet-Cookie: ' + sentinel + '\r\n\r\n{}');
const sockets = new Set();
const upstream = net.createServer(
  /** Backend giả loopback đúng3000, không có DB hoặc auth side effect.
   * Input
   * Param: socket — handle owned của test, nhận request một lần.
   */
  (socket) => {
    sockets.add(socket);
    socket.on('error', /** Teardown synthetic giữ exception trong test boundary. */ () => {});
    socket.on('close', /** Xóa đúng handle đã terminal khỏi cleanup set. */ () => sockets.delete(socket));
    socket.once('data',
      /** So bytes request và trả status/body/cookie giả nguyên dạng.
       * Input
       * Param: chunk — request synthetic sau TLS proxy.
       */
      (chunk) => { assert.deepEqual(chunk, request); socket.end(response); });
  });
try {
  upstream.listen(3000, '127.0.0.1'); await once(upstream, 'listening');
  const result = await withCli(
    /** Kiểm control split/coalesced, raw pending và actual request target/status/close.
     * Input
     * Param: cli — child đã readiness, sở hữu stdin/stdout của case.
     * Param: certificate — public CA để verify TLS thật.
     */
    async (cli, certificate) => {
      cli.child.stdin.write('STA'); await delay(30);
      assert.equal(frames(cli.read().output).length, 0);
      cli.child.stdin.write('TUS\r\nSTATUS\n');
      await waitFor(/** Chờ đủ hai ACK snapshot trước mở transport. */ () => frames(cli.read().output).length === 2);
      const raw = net.connect(8443, '127.0.0.1');
      raw.on('error', /** Hủy raw handshake owned không được log SDK payload. */ () => {});
      try {
        await once(raw, 'connect');
        await snapshotWhere(cli,
          /** Chỉ snapshot có raw non-idle mới chứng minh handshake pending.
           * Input
           * Param: snapshot — STATUS public của child owned.
           * Output: raw slot còn sống và secure chưa admit.
           */
          (snapshot) => snapshot.rawActive === 1 && snapshot.active === 0);
      } finally { raw.destroy(); }
      assert.deepEqual(await exchange(certificate, request), response);
      await waitFor(/** Ledger CLOSED chỉ tới sau owned exchange terminal. */
        () => frames(cli.read().output).some(
          /** Chọn CLOSED của request synthetic duy nhất.
           * Input
           * Param: frame — frame stdout đang đọc.
           * Output: exchange terminal đã emit.
           */
          (frame) => frame.event === 'CLOSED'));
      cli.child.stdin.write('STOP\nSTATUS\n');
    });
  const final = assertFinal(result);
  assert.equal(final.rawOpened, 2); assert.equal(final.opened, 1);
  assert.equal(final.requests, 1); assert.equal(final.statuses, 1);
  assert.equal(final.byKind.WORKSPACE_DETAIL, 1); assert.equal(final.incomplete, 0);
  const ledger = frames(result.output).filter(
    /** Tách ledger khỏi snapshot để so đúng ba event request/status/close.
     * Input
     * Param: frame — public JSON frame.
     * Output: frame event.
     */
    (frame) => frame.frame === 'EVENT');
  assert.deepEqual(ledger.map(
    /** Kiểm target chỉ là boolean, không xuất UUID/URL thực.
     * Input
     * Param: event — ledger entry của actual request.
     * Output: tuple correlation.
     */
    (event) => [event.event, event.requestId, event.kind, event.matchesTarget]),
  [['REQUEST',1,'WORKSPACE_DETAIL',true],['STATUS',1,'WORKSPACE_DETAIL',true],['CLOSED',1,'WORKSPACE_DETAIL',true]]);
  assert.equal(ledger[1].status, 404);
  assert.equal(result.output.includes(target), false);
  console.log('OBSERVED_CLI_TLS_STATUS_RAW_AND_FINAL_PASS');


  const saturated = await withCli(
    /** Giữ32raw peer rồi mở33rd để original CLI phải exit1, không FINAL/STOPPED khỏe.
     * Input
     * Param: cli — child riêng của saturation case, chưa có request HTTP.
     */
    async (cli) => {
      const clients = [];
      const closures = [];
      try {
        for (let index = 0; index < 33; index++) {
          if (index === 32) await snapshotWhere(cli,
            /** Admission phải đủ32 trước fault để tránh case chỉ mở rồi đóng dưới cap.
             * Input
             * Param: snapshot — STATUS hoàn chỉnh của đúng child.
             * Output: cả32raw slots còn sống.
             */
            (snapshot) => snapshot.rawActive === 32);
          const socket = net.connect({ host: '127.0.0.1', port: 8443 });
          clients.push(socket);
          socket.on('error', /** Overflow/reset chỉ đi vào assertions outcome, không in peer error. */ () => {});
          closures.push(new Promise(
            /** Mọi client test phải terminal kể cả khi original child hoặc assertion lỗi.
             * Input
             * Param: resolve — close ACK của đúng raw client.
             */
            (resolve) => socket.once('close', resolve)));
          await once(socket, 'connect');
        }
        await cli.done;
      } finally {
        for (const socket of clients) socket.destroy();
        await Promise.all(closures);
      }
    });
  assert.equal(saturated.code, 1);
  assert.equal(saturated.errors, 'LOCAL_HTTPS_PROXY_FAILED\n');
  assert.equal(saturated.output.includes('"frame":"FINAL"'), false);
  assert.equal(saturated.output.includes('LOCAL_HTTPS_PROXY_STOPPED'), false);
  console.log('OBSERVED_CLI_RAW_SATURATION_NO_FINAL_PASS');

  for (const mode of ['eof', 'partial-eof', 'invalid', 'oversize', 'epipe']) {
    const fault = await withCli(
      /** Mỗi fault dùng child riêng để failure sticky không bị case sau reset.
       * Input
       * Param: cli — child owned đã có readiness.
       */
      async (cli) => {
        if (mode === 'eof') cli.child.stdin.end();
        else if (mode === 'partial-eof') cli.child.stdin.end('STA');
        else if (mode === 'epipe') { cli.child.stdout.destroy(); cli.child.stdin.write('STATUS\n'); }
        else cli.child.stdin.write(mode === 'invalid' ? 'BAD\n' : 'S'.repeat(17));
      });
    if (mode === 'eof') assertFinal(fault);
    else {
      assert.equal(fault.code, 1);
      assert.equal(fault.errors, 'LOCAL_HTTPS_PROXY_FAILED\n');
      assert.equal(fault.output.includes('"frame":"FINAL"'), false);
      assert.equal(fault.output.includes('LOCAL_HTTPS_PROXY_STOPPED'), false);
    }
    console.log('OBSERVED_CLI_' + mode.toUpperCase().replace('-', '_') + '_PASS');
  }

  for (const args of [['--observe-http','extra'], ['--target-workspace=' + target]]) {
    const cli = startCli(args);
    const terminal = await cli.done;
    assert.equal(terminal.code, 1); assert.equal(terminal.signal, null);
    assert.equal(cli.read().output, '');
    assert.equal(cli.read().errors, 'LOCAL_HTTPS_PROXY_FAILED\n');
    assert.equal(cli.read().timedOut, false);
  }
  console.log('OBSERVED_CLI_INVALID_ARGV_NO_PUBLICATION_PASS');

  const collision = net.createServer();
  collision.listen(8443, '127.0.0.1'); await once(collision, 'listening');
  try {
    const cli = startCli();
    const terminal = await cli.done;
    assert.equal(terminal.code, 1); assert.equal(terminal.signal, null);
    assert.equal(cli.read().output, '');
    assert.equal(cli.read().errors, 'LOCAL_HTTPS_PROXY_FAILED\n');
    assert.equal(cli.read().timedOut, false);
    assert.equal(collision.listening, true);
  } finally { const closed = once(collision, 'close'); collision.close(); await closed; }
  console.log('OBSERVED_CLI_BIND_COLLISION_OWNERSHIP_PASS');
} finally {
  for (const socket of sockets) socket.destroy();
  if (upstream.listening) {
    const closed = once(upstream, 'close'); upstream.close(); await closed;
  }
}
