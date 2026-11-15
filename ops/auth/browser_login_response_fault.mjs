import assert from 'node:assert/strict';

const methods = ['Network.requestWillBeSent', 'Fetch.requestPaused', 'Network.loadingFailed'];
const deadlineMilliseconds = 15_000;

/**
 * Làm mất đúng response login200 trước deadline UX để kiểm recovery trên browser thật.
 * Input
 * Param: cdp — capability của tab CUA hiện tại, không tạo kết nối browser riêng.
 * Param: submit — callback click nhận timeoutMs hữu hạn trong cùng CUA call, không tự replay request.
 * Param: url — endpoint login localhost5173 của lab đã sở hữu.
 * Param: now — clock monotonic, chỉ thay bằng clock giả trong host tests.
 * Output: receipt PASS/FAIL chỉ có identity, sequence và timing, không có auth material.
 * Errors: lỗi boundary được chuyển thành marker cố định; clear lỗi vẫn là FAIL.
 * Side effects
 * Bật interception Fetch hẹp, submit một lần, fail đúng response200 và luôn thử clear.
 * Commit-before-fault cần source chain đã review và DB readback riêng sau invocation.
 */
export async function interruptLoginResponse({ cdp, submit, url, now = performance.now.bind(performance) }) {
  const receipt = { status: 'FAIL', stage: 'ADMISSION', faultAcknowledged: false, loadingFailedObserved: false, interceptionCleared: false, interceptionClearAcknowledged: false, commandOutcomeUnconfirmed: false };
  let armed = false;
  let started;
  let cursor;
  let pages = 0;
  let lastElapsed = 0;
  let requestCount = 0;
  let networkId;
  let paused;
  let hasMoreEvents = false;
  const pendingPauses = new Set();

  /**
   * Giữ uncertainty khi capability trả lỗi quan sát, không suy command remote đã hủy.
   * Input
   * Param: method — command CDP thuộc setup/fault/cleanup đã được driver chọn.
   * Param: params — tham số public của command, không mang credential.
   * Param: timeoutMs — budget chờ hữu hạn, kiểm lại monotonic sau khi raw promise settle.
   * Output: kết quả capability khi ACK tới trong budget.
   * Errors: marker cố định và cờ unconfirmed nếu ACK trễ hoặc command reject.
   */
  async function send(method, params, timeoutMs = 5000) {
    const callStarted = now();
    try {
      const result = await cdp.send(method, params, { timeoutMs });
      const waited = now() - callStarted;
      assert.ok(Number.isFinite(waited) && waited >= 0 && waited < timeoutMs);
      return result;
    }
    catch { receipt.commandOutcomeUnconfirmed = true; throw Error('COMMAND_UNCONFIRMED'); }
  }

  /**
   * Ghi ownership pause trước validation để nhánh lỗi vẫn giải phóng đúng request đã giữ.
   * Input
   * Param: events — batch từ capability của đúng tab, chỉ lấy method và Fetch request ID.
   * Side effects: thêm ID vào tập pending, không giữ raw header hoặc body.
   */
  function capturePauses(events) {
    for (const event of events) {
      if (event.method === 'Fetch.requestPaused') {
        const identifier = event.params?.requestId;
        assert.ok(typeof identifier === 'string' && identifier.length > 0);
        pendingPauses.add(identifier);
      }
    }
  }

  /** Kiểm clock đơn điệu sau mỗi await; Output là elapsed hợp lệ, lỗi nếu ACK đã trễ deadline. */
  function elapsed() {
    const value = now() - started;
    assert.ok(Number.isFinite(value) && value >= lastElapsed && value < deadlineMilliseconds);
    lastElapsed = value;
    return value;
  }

  /** Đọc event có cursor hữu hạn; Output là batch owned, lỗi/truncate giữ verdict chưa xác nhận. */
  async function readPage() {
    assert.ok(++pages <= 32);
    const remaining = deadlineMilliseconds - elapsed();
    const page = await cdp.readEvents({ afterSequence: cursor, methods, limit: 1000, timeoutMs: Math.max(1, Math.min(1000, Math.floor(remaining))) });
    assert.ok(Array.isArray(page.events));
    capturePauses(page.events);
    if (page.truncated) receipt.commandOutcomeUnconfirmed = true;
    assert.ok(!page.truncated && Number.isSafeInteger(page.cursor) && page.cursor >= cursor);
    assert.equal(typeof page.hasMore, 'boolean');
    cursor = page.cursor;
    hasMoreEvents = page.hasMore;
    elapsed();
    return page.events;
  }

  try {
    assert.equal(url, 'http://localhost:5173/api/v1/auth/login');
    assert.equal(typeof submit, 'function');
    await send('Network.enable', {});
    armed = true;
    await send('Fetch.enable', { patterns: [{ urlPattern: url, resourceType: 'Fetch', requestStage: 'Response' }] });
    const baseline = await cdp.readEvents({ methods });
    assert.ok(Number.isSafeInteger(baseline.cursor));
    cursor = baseline.cursor;
    started = now();
    receipt.clickStartedUtc = new Date().toISOString();
    receipt.stage = 'SUBMIT';
    try { await submit({ timeoutMs: Math.floor(deadlineMilliseconds - elapsed()) }); }
    catch { receipt.commandOutcomeUnconfirmed = true; throw Error('SUBMIT_UNCONFIRMED'); }
    elapsed();
    receipt.stage = 'WAIT_RESPONSE';
    while (!paused) {
      for (const event of await readPage()) {
        const params = event.params ?? {};
        if (event.method === 'Network.requestWillBeSent' && params.request?.url === url) {
          assert.equal(params.request.method, 'POST');
          assert.equal(++requestCount, 1);
          assert.ok(typeof params.requestId === 'string' && params.requestId.length > 0);
          networkId = params.requestId;
          receipt.requestSequence = event.sequence;
        }
        if (event.method === 'Fetch.requestPaused') {
          assert.ok(!paused && requestCount === 1 && params.networkId === networkId);
          assert.equal(params.request?.url, url);
          assert.equal(params.request.method, 'POST');
          assert.equal(params.responseStatusCode, 200);
          assert.ok(typeof params.requestId === 'string' && params.requestId.length > 0);
          paused = params.requestId;
          receipt.networkId = networkId;
          receipt.fetchRequestId = paused;
          receipt.responseStatus = 200;
          receipt.pauseSequence = event.sequence;
          receipt.pauseElapsedMilliseconds = elapsed();
        }
        if (event.method === 'Network.loadingFailed' && params.requestId === networkId) throw Error('EARLY_FAILED');
      }
    }
    receipt.stage = 'FAULT';
    elapsed();
    await send('Fetch.failRequest', { requestId: paused, errorReason: 'ConnectionClosed' }, Math.max(1, Math.floor(deadlineMilliseconds - elapsed())));
    pendingPauses.delete(paused);
    receipt.faultAcknowledged = true;
    receipt.faultAckElapsedMilliseconds = elapsed();
    receipt.stage = 'WAIT_FAILED';
    while (!receipt.loadingFailedObserved || hasMoreEvents) {
      for (const event of await readPage()) {
        const params = event.params ?? {};
        if (event.method === 'Network.requestWillBeSent' && params.request?.url === url) throw Error('EXTRA_LOGIN');
        if (event.method === 'Fetch.requestPaused') throw Error('EXTRA_PAUSE');
        if (event.method === 'Network.loadingFailed' && params.requestId === networkId) {
          receipt.loadingFailedObserved = true;
          receipt.failedSequence = event.sequence;
          receipt.failedElapsedMilliseconds = elapsed();
        }
      }
    }
    receipt.eventFenceSequence = cursor;
    receipt.status = 'PASS';
  } catch {
    // Không đưa raw CDP exception/event có thể chứa postData hoặc header ra receipt.
    receipt.error = 'BROWSER_LOGIN_RESPONSE_FAULT_UNCONFIRMED';
  } finally {
    if (armed) {
      const cleanupStarted = now();
      try {
        // Drain cả Network/Fetch tới fence hữu hạn; failed ở page đầu không được che POST ở page sau.
        let more = true;
        let cleanupPages = 0;
        while (more) {
          assert.ok(++cleanupPages <= 32 && now() - cleanupStarted < 5000);
          const tail = await cdp.readEvents({ afterSequence: cursor, methods, limit: 1000, timeoutMs: 1 });
          assert.ok(Array.isArray(tail.events));
          capturePauses(tail.events);
          assert.ok(!tail.truncated && Number.isSafeInteger(tail.cursor) && typeof tail.hasMore === 'boolean');
          cursor = tail.cursor;
          more = tail.hasMore;
          for (const event of tail.events) {
            if (event.method === 'Fetch.requestPaused') receipt.status = 'FAIL';
            if (event.method === 'Network.requestWillBeSent' && event.params?.request?.url === url) receipt.status = 'FAIL';
          }
        }
      } catch {
        receipt.commandOutcomeUnconfirmed = true;
      }
      for (const identifier of pendingPauses) {
        try {
          const remaining = 5000 - (now() - cleanupStarted);
          assert.ok(Number.isFinite(remaining) && remaining > 0);
          await send('Fetch.failRequest', { requestId: identifier, errorReason: 'Aborted' }, Math.max(1, Math.floor(remaining)));
          pendingPauses.delete(identifier);
        } catch {
          receipt.commandOutcomeUnconfirmed = true;
        }
      }
      receipt.unresolvedPausedRequests = pendingPauses.size;
      try {
        // Connector dành Document cho navigation, hỗ trợ clear bằng empty patterns.
        await send('Fetch.enable', { patterns: [] });
        receipt.interceptionClearAcknowledged = true;
        receipt.interceptionCleared = pendingPauses.size === 0 && !receipt.commandOutcomeUnconfirmed;
        if (!receipt.interceptionCleared) receipt.status = 'FAIL';
      } catch {
        receipt.status = 'FAIL';
        receipt.error = 'BROWSER_LOGIN_RESPONSE_FAULT_CLEAR_FAILED';
      }
    }
  }
  return receipt;
}
