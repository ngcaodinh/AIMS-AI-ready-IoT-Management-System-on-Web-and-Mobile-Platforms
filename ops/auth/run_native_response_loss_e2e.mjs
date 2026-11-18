import assert from 'node:assert/strict';
import https from 'node:https';
import http from 'node:http';
import { randomBytes, X509Certificate } from 'node:crypto';
import { writeFile } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
import { pathToFileURL } from 'node:url';
import { createCertificates } from './memory_tls_material.mjs';
import { startFixture, runNativePhase, assertNativePid, verifyHostNoCa } from './run_native_e2e.mjs';

let observedStage = 'startup';
let observedCounts = null;

/** Tạo proxy mất duy nhất body login200 đầu sau upstream kết thúc, không giữ header/body sau fault.
 * Input
 * Param: material — PFX/certificate RAM cho localhost, chỉ certificate public đi tới SDK.
 * Output: proxy owner có close/ledger/counts; response fault không gọi retry hoặc sửa backend.
 */
async function startFaultProxy(material) {
  const sockets = new Set();
  const exchanges = new Set();
  const ledger = [];
  const tokens = [];
  let failed = false;
  let lost = false;
  let loginCount = 0;
  let logoutCount = 0;
  const server = https.createServer({ pfx: material.pfx, minVersion: 'TLSv1.2' },
    /** Forward một request gốc, chỉ giữ request identity/method/route/status trong ledger.
     * Param: incoming — request của App thực, credential chỉ stream vào backend loopback.
     * Param: outgoing — response trả App, lần200login đầu bị đóng trước mọi body/header. */
    (incoming, outgoing) => {
      const path = incoming.url;
      const login = incoming.method === 'POST' && path === '/api/v1/auth/login';
      const logout = incoming.method === 'POST' && path === '/api/v1/auth/logout';
      if (login) loginCount++;
      if (logout) logoutCount++;
      const row = { id: ledger.length + 1, method: incoming.method, path, status: null, bodyLost: false };
      ledger.push(row);
      const upstream = http.request({ host: '127.0.0.1', port: 3000, method: incoming.method, path,
        headers: { ...incoming.headers, connection: 'close' }, timeout: 20000 },
        /** Backend chỉ phát login200 sau commitACK, consume đến EOF rồi hủy App socket ở fault đầu.
         * Param: response — upstream stream, không ghi capability hoặc payload vào evidence. */
        (response) => {
          row.status = response.statusCode;
          if (login && response.statusCode === 200) {
            const chunks = [];
            let size = 0;
            response.on('data',
              /** Giữ tối đa128KiB response trong RAM để đăng ký token canary, không xuất body. */
              (chunk) => { size += chunk.length; if (size > 131072) { failed = true; upstream.destroy(); outgoing.destroy(); }
                else chunks.push(Buffer.from(chunk)); });
            response.on('end',
              /** Xóa bytes sau khi lấy canary token, chỉ sống tới final scan của cùng run. */
              () => {
                try { const value = JSON.parse(Buffer.concat(chunks).toString('utf8')).token;
                  assert.ok(typeof value === 'string' && value.length >= 32 && value.length <= 1024); tokens.push(value); }
                catch { failed = true; }
                finally { for (const chunk of chunks) chunk.fill(0); chunks.length = 0; }
              });
          }
          if (login && !lost && response.statusCode === 200) {
            lost = true;
            let length = 0;
            response.on('data',
              /** Chỉ consume/count bytes, không copy token vào log hoặc cache của harness. */
              (chunk) => { length += chunk.length; if (length > 131072) { failed = true; upstream.destroy(); outgoing.destroy(); } });
            response.on('end',
              /** Fault ACK chỉ sau complete body từ provider, App chưa nhận header/body. */
              () => { row.bodyLost = true; outgoing.destroy(); });
          } else {
            outgoing.writeHead(response.statusCode, response.headers);
            response.pipe(outgoing);
          }
          response.on('error',
            /** Upstream read lỗi không được xem là fault sau commit đã xác nhận. */
            () => { failed = true; outgoing.destroy(); });
        });
      exchanges.add(upstream);
      upstream.on('close',
        /** Nhả đúng owner terminal của request backend. */
        () => exchanges.delete(upstream));
      upstream.on('error',
        /** Chỉ lộ cờ lỗi, không giữ exception chứa request/header. */
        () => { failed = true; outgoing.destroy(); });
      upstream.on('timeout',
        /** Đóng request vượt20s, không retry mutation. */
        () => { failed = true; upstream.destroy(); outgoing.destroy(); });
      incoming.pipe(upstream);
    });
  server.on('connection',
    /** Giữ socket ownership đến close thật để finally dọn cả handshake chưa hoàn tất. */
    (socket) => { sockets.add(socket); socket.on('close',
      /** Nhả reference sau terminal, không đọc remote identifiers. */
      () => sockets.delete(socket)); });
  await new Promise(
    /** Chỉ resolve khi localhost8443 bind xong, error giữ fixed diagnostic. */
    (resolve, reject) => { server.once('error',
      /** Bind failure không cho tiếp tục SDK. */
      () => reject(new Error('NATIVE_LOSS_PROXY_START_FAILED'))); server.listen(8443, '127.0.0.1', resolve); });
  return { ledger, tokens,
    counts:
      /** Snapshot boolean/count, không credential. */
      () => ({ login: loginCount, logout: logoutCount, lost, healthy: !failed }),
    close:
      /** Chờ owned listener/socket/exchanges terminal, không dừng backend ngoài fixture. */
      async () => { for (const exchange of exchanges) exchange.destroy(); for (const socket of sockets) socket.destroy();
        await new Promise(
          /** Chỉ hoàn tất sau server close callback thật. */
          (resolve) => server.close(resolve)); assert.equal(sockets.size, 0); assert.equal(exchanges.size, 0); },
  };
}

/** Scan named field và canary trên bytes quan sát đúng process, không ghi fragment/raw values.
 * Input
 * Param: sink — tên cố định app_debug/sdk_stdout/sdk_stderr.
 * Param: bytes — log trong RAM đã cap1MiB.
 * Param: canaries — password/email/actual bearer của cùng fixture.
 * Output: count PASS hữu hạn, sink trống được ghi EMPTY thay vì có evidence giả. */
export function scanDebugOutput(sink, bytes, canaries) {
  const text = bytes.toString('utf8').replaceAll('\\"', '"');
  const canaryMatches = canaries.filter(
    /** Canary literal/URL/Base64 giữ trong RAM, không phản chiếu giá trị match. */
    (value) => text.includes(value) || text.includes(encodeURIComponent(value))
      || text.includes(Buffer.from(value).toString('base64'))).length;
  const namedFieldMatches = [...text.matchAll(/(?:^|[^\w-])["']?(?:authorization|cookie|set-cookie|password|token|email)["']?\s*[:=]\s*(?!["']?(?:\[redacted\]|<redacted>|\*\*\*|null))/gim)].length;
  observedStage = 'debug_scan_' + sink;
  assert.equal(canaryMatches, 0, 'CANARY_MATCH');
  assert.equal(namedFieldMatches, 0, 'NAMED_FIELD_MATCH');
  return { sink, byteCount: bytes.length, canaryCount: canaries.length, canaryMatches, namedFieldMatches,
    status: bytes.length ? 'PASS' : 'EMPTY' };
}

/** Tạo tên evidence riêng cho mỗi fixture để lượt chạy mới không ghi đè lịch sử.
 * Input
 * Param: runId — UUID v4 từ READY của fixture đang được sở hữu; chỉ ký tự UUID được phép đi vào đường dẫn.
 * Output: đường dẫn repo-relative dưới `docs/test-reports/evidence/` cho receipt đã khử dữ liệu thô.
 * Errors: UUID sai định dạng bị từ chối bằng mã cố định trước thao tác file.
 */
export function responseLossEvidencePath(runId) {
  assert.ok(typeof runId === 'string' &&
    /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(runId),
  'NATIVE_RUN_ID_INVALID');
  return `docs/test-reports/evidence/native-response-loss-actual-${runId}.json`;
}

/** Chạy main Android qua fault rồi explicit recover/submit, đối chiếu orphan và revoked session cuối.
 * Side effects: fixture5users/2workspaces, proxy tạm và evidence riêng theo runId; finally dọn fixture/proxy. */
async function main() {
  const materials = createCertificates();
  let password = `Aa1${randomBytes(16).toString('hex')}`;
  const fixture = startFixture(password);
  let proxy;
  let passed = false;
  let snapshot;
  const output = { stdout: Buffer.alloc(0), stderr: Buffer.alloc(0) };
  let debugScan;
  let evidencePath;
  try {
    const ready = await fixture.ready();
    evidencePath = responseLossEvidencePath(ready.runId);
    const baseline = await fixture.snapshot();
    proxy = await startFaultProxy(materials.valid);
    const certificate = new X509Certificate(materials.valid.certificate).raw.toString('base64');
    for (const value of Object.values(materials)) value.pfx.fill(0);
    await verifyHostNoCa();
    const stages = ['loss-result', 'loss-quiet', 'loss-ready', 'loss-picker', 'loss-loggedout'];
    let position = 0;
    await runNativePhase({ version: 1, phase: 'response-loss', emails: ready.emails, password }, certificate,
      /** So final session set với baseline, không coi timeout/body loss là rollback chắc chắn.
       * Param: nativePid — đúng App process còn sống ở UI/framework PASS. */
      async (nativePid) => {
        observedStage = 'final_pid';
        assertNativePid(nativePid);
        assert.equal(position, stages.length);
        observedStage = 'logcat';
        // Dùng cùng SDK executable với assertNativePid; adb không nằm trên PATH của runner.
        const logcat = spawnSync('C:/Users/LENOVO/AppData/Local/Android/sdk/platform-tools/adb.exe', ['-s', 'emulator-5554', 'logcat', '-d', `--pid=${nativePid}`, '-v', 'brief'],
          { encoding: 'buffer', windowsHide: true, timeout: 10000, maxBuffer: 1048576 });
        assert.ok(!logcat.error && !logcat.signal && logcat.status === 0 && Buffer.isBuffer(logcat.stdout), 'APP_DEBUG_CAPTURE_FAILED');
        assert.ok(logcat.stdout.length > 0);
        const canaries = [password, ...ready.emails, ...proxy.tokens];
        observedStage = 'debug_scan';
        debugScan = [scanDebugOutput('app_debug', logcat.stdout, canaries),
          scanDebugOutput('sdk_stdout', output.stdout, canaries), scanDebugOutput('sdk_stderr', output.stderr, canaries)];
        observedStage = 'final_sql';
        snapshot = await fixture.snapshot();
        const initial = new Map(baseline.map(
          /** Chỉ UUID/revoked từ metadata do fixture đã validate. */
          (row) => [row.sessionId, row.revoked]));
        const added = snapshot.filter(
          /** Giữ đúng session mới, không gán seed session cho App. */
          (row) => !initial.has(row.sessionId));
        assert.equal(added.length, 2);
        assert.equal(added.filter(
          /** Một orphan còn sống vì App mất bearer, chỉ bounded TTL server xử lý. */
          (row) => !row.revoked).length, 1);
        for (const row of snapshot.filter(
          /** Seed sessions không bị logout của App mới thay đổi. */
          (row) => initial.has(row.sessionId))) assert.equal(row.revoked, initial.get(row.sessionId));
      }, password,
      /** Host ACK chỉ đúng sequence và request counts ở từng UI boundary, không SQL await trong pause5s.
       * Param: stage — enum do native producer phát, không account/token. */
      (stage) => {
        observedStage = stage;
        assert.equal(stage, stages[position]);
        const counts = proxy.counts();
        observedCounts = counts;
        assert.ok(counts.healthy && counts.lost);
        assert.equal(counts.login, position < 3 ? 1 : 2);
        assert.equal(counts.logout, position === 4 ? 1 : 0);
        if (position < 3) assert.equal(proxy.ledger.filter(
          /** Pending/recovery không có bearer nên chưa được đọc protected resource. */
          (row) => row.method === 'GET').length, 0);
        position++;
      }, {
        onOutput:
          /** Chỉ giữ hai owned SDK pipes tối đa1MiB mỗi sink trong RAM, không forward raw log. */
          (sink, chunk) => {
            assert.ok(Object.hasOwn(output, sink) && output[sink].length + chunk.length <= 1048576);
            output[sink] = Buffer.concat([output[sink], chunk]);
          },
      });
    assertNativePid(null);
    passed = true;
  } finally {
    let proxyClosed = true;
    let fixtureClosed = true;
    try { if (proxy) await proxy.close(); } catch { proxyClosed = false; }
    try { await fixture.close(); } catch { fixtureClosed = false; }
    for (const value of Object.values(materials)) value.pfx.fill(0);
    password = '';
    if (proxy) proxy.tokens.fill('');
    for (const bytes of Object.values(output)) bytes.fill(0);
    // Proxy cleanup lỗi vẫn phải join original fixture terminal, không để role/server sống sau runner.
    assert.ok(proxyClosed && fixtureClosed, 'NATIVE_RESPONSE_LOSS_CLEANUP_UNCONFIRMED');
  }
  assert.ok(passed);
  const receipt = { nativeMain: true, responseCommittedBeforeLoss: true, quietSeconds: 30,
    explicitSubmitOnly: true, debugScan, twoNewSessionsOneOrphanOneRevoked: true, fixtureCleanup: 'EIGHT_ZERO_AND_ORIGINAL_EXIT', ledger: proxy.ledger };
  // `wx` giữ nguyên artifact cũ nếu UUID tình cờ trùng thay vì âm thầm ghi đè lịch sử.
  assert.ok(typeof evidencePath === 'string', 'NATIVE_EVIDENCE_PATH_MISSING');
  await writeFile(evidencePath, JSON.stringify(receipt, null, 2), { flag: 'wx' });
  console.log('NATIVE_RESPONSE_LOSS_ACTUAL_CLEANUP_PASS');
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try { await main(); }
  catch (error) { console.error(JSON.stringify({ kind: 'NATIVE_RESPONSE_LOSS_ACTUAL_FAILED', stage: observedStage, counts: observedCounts,
    assertion: error.code === 'ERR_ASSERTION' ? 'ASSERTION' : 'RUNTIME' })); process.exitCode = 1; }
}
