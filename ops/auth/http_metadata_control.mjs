import { X509Certificate } from 'node:crypto';

const kinds = Object.freeze(['AUTH_LOGIN', 'PROFILE_READ', 'WORKSPACE_LIST',
  'WORKSPACE_DETAIL', 'PASSWORD_CHANGE', 'AUTH_LOGOUT', 'OTHER']);
const uuidPattern = /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/;
const snapshotKeys = ['healthy', 'sealed', 'sequence', 'elapsedMilliseconds', 'rawOpened',
  'rawActive', 'opened', 'active', 'requests', 'statuses', 'closed', 'incomplete', 'byKind', 'proxyAvailable'];

/**
 * Chỉ mở observed CLI bằng flag cố định và UUID synthetic tùy chọn, chặn cấu hình endpoint từ argv.
 * Input
 * Param: args — danh sách argument sau tên script, không được phản chiếu khi lỗi.
 * Output: null cho CLI cũ, object cấu hình capture cho observed CLI.
 * Errors: INVALID_PROXY_ARGUMENTS khi flag, thứ tự hoặc UUID ngoài allowlist.
 */
export function parseObservedProxyArguments(args) {
  if (args.length === 0) return null;
  if (args[0] === '--observe-http' && args.length === 1) return {};
  if (args[0] === '--observe-http' && args.length === 2 &&
      args[1].startsWith('--target-workspace=') && uuidPattern.test(args[1].slice(19))) {
    return { targetWorkspaceId: args[1].slice(19) };
  }
  throw new Error('INVALID_PROXY_ARGUMENTS');
}

/**
 * Kiểm object chỉ chứa các own enumerable field dự kiến trước khi stringify metadata.
 * Input
 * Param: value — object nội bộ từ capture, không nhận object tùy ý từ network.
 * Param: keys — tập tên field bắt buộc.
 * Output: boolean schema khớp hoàn toàn, không cho extra field lọt vào stdout.
 */
function exactKeys(value, keys) {
  return value !== null && typeof value === 'object' && !Array.isArray(value) &&
    Object.keys(value).length === keys.length && keys.every(
      /** Đối chiếu từng field bắt buộc để thiếu field không được thay bằng extra payload.
       * Input
       * Param: key — tên field từ schema cố định.
       * Output: field tồn tại trực tiếp trên object.
       */
      (key) => Object.hasOwn(value, key));
}

/**
 * Sở hữu framing control và stdout metadata có giới hạn, chờ write ACK trước khi công nhận final.
 * Input
 * Param: options — capabilities output, snapshot và stop do CLI cấp, không phải cấu hình network.
 * Param: options.output — Writable nhận JSON lines và public certificate, phát lỗi stdout.
 * Param: options.snapshot — đọc capture/proxy state đồng bộ ở cùng event loop.
 * Param: options.stop — chỉ yêu cầu đóng proxy owned, terminal vẫn do caller await riêng.
 * Output: publish/onInput/onEnd/ready/finish/settle và cờ failed sticky.
 * Errors: chỉ fixed code, không đưa exception hoặc input control ra log.
 * Side effects: lỗi schema, backpressure hoặc EPIPE yêu cầu stop một lần. Listener error được giữ tới process exit để nhận lỗi muộn sau write callback.
 */
export function createHttpMetadataControl({ output, snapshot, stop }) {
  if (!output || typeof output.write !== 'function' || typeof output.on !== 'function' ||
      typeof snapshot !== 'function' || typeof stop !== 'function') {
    throw new Error('HTTP_METADATA_CONTROL_FAILED');
  }
  let failed = false;
  let stopping = false;
  let finished = false;
  let readySent = false;
  let frameSequence = 0;
  let eventSequence = 0;
  let lastElapsed = 0;
  let input = '';
  let completion;
  const pending = new Set();

  /** Yêu cầu shutdown idempotent trước callback để lỗi đồng bộ không gọi stop lặp hoặc đệ quy. */
  function requestStop() {
    if (stopping) return;
    stopping = true;
    try { stop(); } catch { failed = true; }
  }

  /** Giữ lỗi vĩnh viễn và dừng endpoint, không stringify hoặc echo dữ liệu gây lỗi. */
  function fail() {
    failed = true;
    requestStop();
  }
  output.on('error', fail);

  /**
   * Gửi line hữu hạn và theo dõi từng callback thật, giữ tối đa64 write pending cùng4096 frame.
   * Input
   * Param: line — JSON đã validate hoặc literal/public certificate đã chuẩn hóa.
   * Side effects: write false, throw hoặc callback error đều sticky failure và stop.
   */
  function write(line) {
    if (failed || finished || pending.size >= 64 || Buffer.byteLength(line) > 4096) {
      fail();
      return;
    }
    let resolveWrite;
    let acknowledged = false;
    const receipt = new Promise(
      /** Cấp receipt trước gọi write vì fake/real Writable có thể ACK đồng bộ.
       * Input
       * Param: resolve — completion của đúng owned write này.
       */
      (resolve) => { resolveWrite = resolve; });
    pending.add(receipt);
    /** Chốt ACK một lần, không để duplicate callback xóa write khác hoặc thay outcome lỗi.
     * Input
     * Param: error — lỗi Writable cần chuyển thành fixed failure.
     */
    function acknowledge(error) {
      if (acknowledged) { fail(); return; }
      acknowledged = true;
      if (error) fail();
      pending.delete(receipt);
      resolveWrite();
    }
    try {
      if (!output.write(line, acknowledge)) fail();
    } catch { acknowledge(true); }
  }

  /**
   * Xuất JSON line có frame ordinal riêng để snapshot xen event vẫn giữ thứ tự kiểm chứng.
   * Input
   * Param: frame — EVENT, SNAPSHOT hoặc FINAL nội bộ.
   * Param: data — object đã qua schema, không chứa payload HTTP.
   */
  function send(frame, data) {
    if (frameSequence >= 4096) { fail(); return; }
    write(JSON.stringify({ frame, frameSequence: ++frameSequence, ...data }) + '\n');
  }

  /**
   * Chặn clock rollback, NaN và thời gian âm trước xuất mọi event/snapshot.
   * Input
   * Param: elapsed — milliseconds monotonic tính từ capture khởi tạo.
   * Output: boolean cùng cập nhật high-watermark khi hợp lệ.
   */
  function acceptClock(elapsed) {
    if (!Number.isFinite(elapsed) || elapsed < lastElapsed) return false;
    lastElapsed = elapsed;
    return true;
  }

  /**
   * Lấy snapshot copy và kiểm các bất biến ledger trước tạo temporal fence.
   * Output: snapshot allowlist, hoặc fixed error khi counter/sequence/clock bất nhất.
   */
  function readSnapshot() {
    const value = snapshot();
    if (!exactKeys(value, snapshotKeys) || !exactKeys(value.byKind, kinds) ||
        typeof value.healthy !== 'boolean' || typeof value.sealed !== 'boolean' ||
        typeof value.proxyAvailable !== 'boolean' || value.sequence !== eventSequence ||
        !acceptClock(value.elapsedMilliseconds)) throw new Error('HTTP_METADATA_CONTROL_FAILED');
    const counters = ['rawOpened', 'rawActive', 'opened', 'active', 'requests', 'statuses', 'closed', 'incomplete'];
    for (const key of counters) {
      if (!Number.isSafeInteger(value[key]) || value[key] < 0) throw new Error('HTTP_METADATA_CONTROL_FAILED');
    }
    let classified = 0;
    for (const kind of kinds) {
      if (!Number.isSafeInteger(value.byKind[kind]) || value.byKind[kind] < 0) throw new Error('HTTP_METADATA_CONTROL_FAILED');
      classified += value.byKind[kind];
    }
    if (value.rawOpened > 1024 || value.rawActive > 32 || value.active > 32 ||
        value.rawActive > value.rawOpened || value.opened > value.rawOpened ||
        value.active + value.closed !== value.opened || value.requests > value.opened ||
        value.statuses > value.requests || value.incomplete > value.closed ||
        classified !== value.requests || (value.healthy && value.sequence !== value.requests + value.statuses + value.closed)) throw new Error('HTTP_METADATA_CONTROL_FAILED');
    return { ...value, byKind: { ...value.byKind } };
  }

  /**
   * Nhận event đã redact từ capture và chỉ xuất own schema enum/number/boolean có sequence liên tục.
   * Input
   * Param: event — REQUEST/STATUS/CLOSED do capture trusted cấp đồng bộ.
   * Errors: lỗi schema/write khiến consumer throw fixed code để proxy fail-closed ngay.
   */
  function publish(event) {
    try {
      if (failed || finished) throw new Error('HTTP_METADATA_CONTROL_FAILED');
      const keys = ['event', 'sequence', 'elapsedMilliseconds', 'requestId', 'kind', 'matchesTarget'];
      if (event?.event === 'STATUS') keys.push('status');
      else if (event?.event === 'CLOSED') keys.push('requestObserved', 'statusObserved');
      else if (event?.event !== 'REQUEST') throw new Error('HTTP_METADATA_CONTROL_FAILED');
      if (!exactKeys(event, keys) || event.sequence !== eventSequence + 1 ||
          !Number.isSafeInteger(event.requestId) || event.requestId < 1 || event.requestId > 1024 ||
          !kinds.includes(event.kind) || typeof event.matchesTarget !== 'boolean' ||
          (event.matchesTarget && event.kind !== 'WORKSPACE_DETAIL') ||
          !acceptClock(event.elapsedMilliseconds) ||
          (event.event === 'STATUS' && (!Number.isInteger(event.status) || event.status < 200 || event.status > 599)) ||
          (event.event === 'CLOSED' && (typeof event.requestObserved !== 'boolean' ||
            typeof event.statusObserved !== 'boolean' || (event.statusObserved && !event.requestObserved)))) {
        throw new Error('HTTP_METADATA_CONTROL_FAILED');
      }
      eventSequence = event.sequence;
      send('EVENT', { ...event });
      if (failed) throw new Error('HTTP_METADATA_CONTROL_FAILED');
    } catch {
      fail();
      throw new Error('HTTP_METADATA_CONTROL_FAILED');
    }
  }

  /**
   * Parse control từng byte với frame tối đa16bytes, hỗ trợ split/coalesced/CRLF mà không giữ vô hạn.
   * Input
   * Param: chunk — Buffer stdin chỉ nhận STATUS hoặc STOP, không có credential.
   */
  function onInput(chunk) {
    if (stopping || failed || finished) return;
    try {
      if (!Buffer.isBuffer(chunk)) throw new Error('HTTP_METADATA_CONTROL_FAILED');
      for (const byte of chunk) {
        if (byte === 10) {
          const command = input.endsWith('\r') ? input.slice(0, -1) : input;
          input = '';
          if (command === 'STOP') { requestStop(); return; }
          if (command !== 'STATUS') throw new Error('HTTP_METADATA_CONTROL_FAILED');
          send('SNAPSHOT', { snapshot: readSnapshot() });
          if (failed) return;
        } else {
          if (input.length >= 16 || (byte !== 13 && (byte < 65 || byte > 90))) {
            throw new Error('HTTP_METADATA_CONTROL_FAILED');
          }
          input += String.fromCharCode(byte);
        }
      }
    } catch { fail(); }
  }

  /** EOF partial là protocol failure, EOF sạch chỉ yêu cầu đóng owned proxy. */
  function onEnd() {
    if (input.length) fail();
    else requestStop();
  }

  /**
   * Xuất readiness literal và public certificate sau bind bằng cùng writer được theo dõi ACK.
   * Input
   * Param: certificate — public PEM/DER của TLS endpoint đang owned, không nhận PFX/private key.
   * Errors: certificate sai hoặc readiness lặp gây fixed failure.
   */
  function ready(certificate) {
    try {
      if (readySent || stopping || failed || finished) throw new Error('HTTP_METADATA_CONTROL_FAILED');
      const encoded = new X509Certificate(certificate).raw.toString('base64');
      readySent = true;
      write('LOCAL_HTTPS_PROXY_READY origin=https://10.0.2.2:8443 upstream=127.0.0.1:3000 ttlMinutes=50\n');
      write('AUTH_LAB_CA_CERT=' + encoded + '\n');
      if (failed) throw new Error('HTTP_METADATA_CONTROL_FAILED');
    } catch { fail(); throw new Error('HTTP_METADATA_CONTROL_FAILED'); }
  }

  /** Chờ mọi owned write callback, không lấy timeout/backpressure làm ACK đã hoàn thành. */
  async function settle() {
    while (pending.size) await Promise.all([...pending]);
  }

  /**
   * Chốt FINAL sau caller đã await proxy raw terminal, chỉ nhận sealed idle healthy snapshot.
   * Output: Promise idempotent chờ FINAL và STOPPED write ACK, reject fixed code nếu stdout/proxy fence lỗi.
   */
  function finish() {
    if (completion) return completion;
    completion =
      /** Final writer vẫn giữ error listener tới process exit để nhận EPIPE phát muộn sau callback. */
      (async () => {
        if (!failed) {
          try {
            const value = readSnapshot();
            if (!value.healthy || !value.sealed || value.proxyAvailable ||
                value.rawActive !== 0 || value.active !== 0) throw new Error('HTTP_METADATA_CONTROL_FAILED');
            send('FINAL', { snapshot: value });
            write('LOCAL_HTTPS_PROXY_STOPPED\n');
          } catch { fail(); }
        }
        finished = true;
        await settle();
        if (failed) throw new Error('HTTP_METADATA_CONTROL_FAILED');
      })();
    return completion;
  }

  return { publish, onInput, onEnd, ready, finish, settle,
    /** Đọc failure sticky cho owner, không suy ra proxy terminal từ cờ này.
     * Output: boolean failure hiện hành.
     */
    get failed() { return failed; } };
}
