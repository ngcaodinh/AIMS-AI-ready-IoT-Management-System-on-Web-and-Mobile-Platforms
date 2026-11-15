import { Transform } from 'node:stream';

const kinds = Object.freeze(['AUTH_LOGIN', 'PROFILE_READ', 'WORKSPACE_LIST',
  'WORKSPACE_DETAIL', 'PASSWORD_CHANGE', 'AUTH_LOGOUT', 'OTHER']);
const workspaceIdPattern = /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/;

/**
 * Phân loại first line đã chốt CRLF, chỉ trả enum và boolean đối chiếu target trong RAM.
 * Input
 * Param: line — tối đa256 bytes request line, chưa có header/body.
 * Param: targetWorkspaceId — UUID synthetic được harness chốt ownership, không được emit.
 * Output: metadata cho request một lần trên connection của App.
 * Errors: protocol khác HTTP/1.1 hoặc request line malformed bị từ chối bằng code cố định.
 */
function classifyRequest(line, targetWorkspaceId) {
  const match = /^([A-Z]+) (\/[\x21-\x7e]*) HTTP\/1\.1\r\n$/.exec(line);
  if (!match) throw new Error('HTTP_METADATA_CAPTURE_FAILED');
  const route = match[1] + ' ' + match[2];
  const literals = {
    'POST /api/v1/auth/login': 'AUTH_LOGIN',
    'GET /api/v1/me': 'PROFILE_READ',
    'GET /api/v1/workspaces': 'WORKSPACE_LIST',
    'POST /api/v1/auth/password': 'PASSWORD_CHANGE',
    'POST /api/v1/auth/logout': 'AUTH_LOGOUT',
  };
  if (Object.hasOwn(literals, route)) return { kind: literals[route], matchesTarget: false };
  const detail = /^GET \/api\/v1\/workspaces\/([0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12})$/.exec(route);
  return detail ? { kind: 'WORKSPACE_DETAIL', matchesTarget: detail[1] === targetWorkspaceId } :
    { kind: 'OTHER', matchesTarget: false };
}

/**
 * Theo dõi bounded metadata của raw TLS và secure exchange, không giữ payload ngoài first line.
 * Input
 * Param: options — trusted object chỉ gồm onEvent, targetWorkspaceId và now.
 * Param: options.onEvent — consumer đồng bộ nhận event allowlist, phải return undefined.
 * Param: options.targetWorkspaceId — UUID synthetic để đối chiếu B trong RAM, optional.
 * Param: options.now — clock monotonic cho host tests, mặc định performance.now.
 * Output: admission raw/exchange và snapshot copy, healthy=false vĩnh viễn sau fault.
 * Errors: cấu hình sai bị chặn trước cấp stream, runtime fault chỉ có fixed code.
 * Side effects: callback metadata tuần tự. Caller vẫn sở hữu việc đóng socket/proxy khi capture lỗi.
 */
export function createHttpMetadataCapture(options) {
  if (!options || typeof options !== 'object' || Array.isArray(options) ||
      Object.keys(options).some(
        /**
         * Cấu hình lạ không được mở thêm payload hoặc callback ngoài giao diện đã review.
         * Input
         * Param: key — tên thuộc tính cấu hình cần đối chiếu với allowlist.
         */
        (key) => !['onEvent', 'targetWorkspaceId', 'now'].includes(key)) ||
      typeof options.onEvent !== 'function' ||
      (options.now !== undefined && typeof options.now !== 'function') ||
      (options.targetWorkspaceId !== undefined && (typeof options.targetWorkspaceId !== 'string' || !workspaceIdPattern.test(options.targetWorkspaceId)))) {
    throw new Error('HTTP_METADATA_CONFIGURATION_INVALID');
  }
  const now = options.now ?? performance.now.bind(performance);
  const onEvent = options.onEvent;
  const targetWorkspaceId = options.targetWorkspaceId;
  let origin;
  try { origin = now(); } catch { throw new Error('HTTP_METADATA_CONFIGURATION_INVALID'); }
  if (!Number.isFinite(origin) || origin < 0) throw new Error('HTTP_METADATA_CONFIGURATION_INVALID');
  let last = origin;
  let sequence = 0;
  let failed = false;
  let sealed = false;
  const rawOwners = new WeakMap();
  let rawOpened = 0;
  let rawActive = 0;
  let opened = 0;
  let active = 0;
  let requests = 0;
  let statuses = 0;
  let closed = 0;
  let incomplete = 0;
  const byKind = Object.fromEntries(kinds.map(
    /**
     * Chốt đầy đủ canary zero ngay trước kết nối đầu để snapshot không thiếu category.
     * Input
     * Param: kind — tên category từ allowlist nội bộ, dùng tạo bộ đếm khởi đầu.
     */
    (kind) => [kind, 0]));

  /** Clock rollback/nonfinite là sticky fault, snapshot sau đó vẫn đọc được trạng thái unhealthy. */
  function elapsed() {
    try {
      const current = now();
      if (!Number.isFinite(current) || current < last) failed = true;
      else last = current;
    } catch { failed = true; }
    return Math.round((last - origin) * 1000) / 1000;
  }

  /** Cấm mọi admission/forward metadata mới sau fault, không reset counter hoặc cho late callback thành success. */
  function assertHealthy() {
    elapsed();
    if (failed || sealed) {
      failed = true;
      throw new Error('HTTP_METADATA_CAPTURE_FAILED');
    }
  }

  /**
   * Emit event allowlist có sequence cùng mốc clock, giữ exception consumer trong fixed boundary.
   * Input
   * Param: metadata — object nội bộ chỉ enum/ordinal/number/boolean.
   */
  function emit(metadata) {
    assertHealthy();
    const event = Object.freeze({ sequence: ++sequence, elapsedMilliseconds: elapsed(), ...metadata });
    if (failed) throw new Error('HTTP_METADATA_CAPTURE_FAILED');
    try {
      const result = onEvent(event);
      if (result !== undefined) {
        // Promise callback không phải ACK đồng bộ. Drain rejection mà không xuất exception hoặc mất ownership.
        Promise.resolve(result).catch(/** Consumer lỗi đã đánh capture unhealthy, chỉ drain raw rejection. */ () => {});
        throw new Error('HTTP_METADATA_CAPTURE_FAILED');
      }
    } catch {
      failed = true;
      throw new Error('HTTP_METADATA_CAPTURE_FAILED');
    }
  }

  /**
   * Cấp raw slot trước handshake và một closure capability riêng của capture.
   * Output: closeRaw idempotent, dùng cho secure admission đúng một lần rồi gọi từ raw close thực.
   */
  function openRaw() {
    assertHealthy();
    if (rawActive >= 32 || rawOpened >= 1024) {
      failed = true;
      throw new Error('HTTP_METADATA_CAPTURE_FAILED');
    }
    rawOpened++;
    rawActive++;
    const state = { ended: false, secured: false };
    /** Trả đúng raw slot đã cấp, giữ secure active độc lập cho tới pipe/socket terminal. */
    function closeRaw() {
      if (state.ended) return;
      state.ended = true;
      rawActive--;
    }
    rawOwners.set(closeRaw, state);
    return closeRaw;
  }

  /**
   * Cấp một request/status observer của TLS exchange đã thuộc proxy.
   * Input
   * Param: rawConnection — closure capability của chính openRaw, chỉ dùng secure admission một lần.
   * Output: hai Transform byte-preserving và close idempotent. Caller chờ mọi owned handle terminal rồi close.
   * Errors: không có raw slot, vượt bound hoặc lỗi first line khiến capture unhealthy vĩnh viễn.
   */
  function openExchange(rawConnection) {
    assertHealthy();
    const raw = rawOwners.get(rawConnection);
    if (!raw || raw.ended || raw.secured || rawActive < 1 || active >= 32) {
      failed = true;
      throw new Error('HTTP_METADATA_CAPTURE_FAILED');
    }
    raw.secured = true;
    const requestId = ++opened;
    active++;
    let requestMetadata;
    let statusObserved = false;
    let exchangeClosed = false;

    /**
     * Tạo pipe chỉ buffer first line256bytes. Bytes header/body tiếp tục forward nguyên dạng.
     * Input
     * Param: direction — request hoặc response do factory chốt, không cấu hình từ mạng.
     * Output: Transform một hướng với prefix luôn wipe trước callback và khi destroy.
     */
    function firstLinePipe(direction) {
      let prefix = Buffer.alloc(256);
      let length = 0;
      return new Transform({
        /**
         * Chốt first line qua chunk boundaries, wipe trước phân loại/emit để consumer không giữ raw buffer.
         * Input
         * Param: chunk — bytes do pipe owned gửi, chỉ forward sau guard của lần transform này.
         * Param: encoding — metadata stream, không dùng vì chunk là Buffer.
         * Param: callback — stream ACK hoặc fixed failure để caller abort proxy.
         */
        transform(chunk, encoding, callback) {
          try {
            assertHealthy();
            if (exchangeClosed) throw new Error('HTTP_METADATA_CAPTURE_FAILED');
            if (prefix) {
              for (const byte of chunk) {
                if (length >= prefix.length) throw new Error('HTTP_METADATA_CAPTURE_FAILED');
                prefix[length++] = byte;
                if (byte !== 10) continue;
                // Chỉ first line được chuyển thành chuỗi ngắn. Header/body không được decode hoặc cache.
                const line = prefix.subarray(0, length).toString('latin1');
                prefix.fill(0);
                prefix = undefined;
                if (direction === 'request') {
                  requestMetadata = classifyRequest(line, targetWorkspaceId);
                  requests++;
                  byKind[requestMetadata.kind]++;
                  emit({ event: 'REQUEST', requestId, ...requestMetadata });
                } else {
                  const status = /^HTTP\/1\.1 ([2-5][0-9]{2})(?: [\x20-\x7e]*)?\r\n$/.exec(line);
                  if (!requestMetadata || !status) throw new Error('HTTP_METADATA_CAPTURE_FAILED');
                  statusObserved = true;
                  statuses++;
                  emit({ event: 'STATUS', requestId, ...requestMetadata, status: Number(status[1]) });
                }
                break;
              }
            }
            callback(null, chunk);
          } catch {
            prefix?.fill(0);
            prefix = undefined;
            failed = true;
            callback(new Error('HTTP_METADATA_CAPTURE_FAILED'));
          }
        },
        /**
         * Partial first line đã có bytes là malformed, zero-byte response được chốt status absent tại close.
         * Input
         * Param: callback — ACK end hoặc fixed error, không echo prefix.
         */
        flush(callback) {
          const partial = prefix && length > 0;
          prefix?.fill(0);
          prefix = undefined;
          if (partial) {
            failed = true;
            callback(new Error('HTTP_METADATA_CAPTURE_FAILED'));
          } else callback();
        },
        /**
         * Xóa prefix dở dang khi socket lỗi trước end. Caller vẫn phải chốt transport closure riêng.
         * Input
         * Param: error — lỗi transport có sẵn, không được đưa vào ledger.
         * Param: callback — completion destroy để owner chờ terminal.
         */
        destroy(error, callback) {
          if (prefix && length > 0) failed = true;
          prefix?.fill(0);
          prefix = undefined;
          if (error) failed = true;
          callback(error ? new Error('HTTP_METADATA_CAPTURE_FAILED') : null);
        },
      });
    }
    const request = firstLinePipe('request');
    const response = firstLinePipe('response');

    /** Chốt secure transport terminal một lần. Missing status giữ incomplete rõ, không suy body/client success. */
    function close() {
      if (exchangeClosed) return;
      // Transform.close đã ACK mới được giảm active; caller cần chờ cả socket/pipe trong proxy integration.
      if (!request.closed || !response.closed) {
        failed = true;
        throw new Error('HTTP_METADATA_CAPTURE_FAILED');
      }
      exchangeClosed = true;
      active--;
      closed++;
      if (!requestMetadata || !statusObserved) incomplete++;
      if (!failed) emit({ event: 'CLOSED', requestId, kind: requestMetadata?.kind ?? 'OTHER',
        matchesTarget: requestMetadata?.matchesTarget ?? false,
        requestObserved: Boolean(requestMetadata), statusObserved });
    }
    return Object.freeze({ request, response, close });
  }

  /** Chụp counters/clock/sequence đồng bộ thành copy riêng, raw/secure active đều tham gia idle fence của harness. */
  function snapshot() {
    const elapsedMilliseconds = elapsed();
    return { healthy: !failed, sealed, sequence, elapsedMilliseconds, rawOpened, rawActive,
      opened, active, requests, statuses, closed, incomplete, byKind: { ...byKind } };
  }

  /** Đóng admission sau proxy terminal. Pending raw/secure giữ failure, không cấp final healthy fence sớm. */
  function seal() {
    if (sealed && !failed) return;
    assertHealthy();
    if (rawActive !== 0 || active !== 0) {
      failed = true;
      throw new Error('HTTP_METADATA_CAPTURE_FAILED');
    }
    sealed = true;
  }

  return Object.freeze({ openRaw, openExchange, snapshot, seal });
}
