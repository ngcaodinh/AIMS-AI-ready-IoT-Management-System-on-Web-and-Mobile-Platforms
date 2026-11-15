import assert from 'node:assert/strict';
import { interruptLoginResponse } from './browser_login_response_fault.mjs';

const loginUrl = 'http://localhost:5173/api/v1/auth/login';

/**
 * Tạo CDP/clock giả để kiểm driver mà không mở browser hoặc DB.
 * Input
 * Param: mode — fault boundary cần inject, không mang credential thật.
 * Output: capabilities và state để kiểm command/order/cleanup.
 */
function setup(mode = 'success') {
  const state = { clock: 0, submitted: false, faulted: false, cleared: false, pages: 0, commands: [] };
  const cdp = {
    /** Ghi command giả và inject lỗi theo đúng boundary đã chọn. */
    async send(method, params, options) {
      assert.ok(Number.isFinite(options.timeoutMs) && options.timeoutMs > 0 && options.timeoutMs <= 15_000);
      state.commands.push({ method, params });
      if (mode === 'setup-error' && method === 'Fetch.enable' && params.patterns.length > 0) throw Error('SYNTHETIC_PRIVATE_SENTINEL');
      if (method === 'Fetch.failRequest') {
        if (mode === 'fail-error') throw Error('SYNTHETIC_PRIVATE_SENTINEL');
        state.faulted = true;
        if (mode === 'late-ack' && params.errorReason === 'ConnectionClosed') state.clock = 15_000;
      }
      if (method === 'Fetch.enable' && params.patterns.length === 0) {
        if (mode === 'clear-error') throw Error('SYNTHETIC_PRIVATE_SENTINEL');
        if (mode === 'late-clear') state.clock += 5000;
        state.cleared = true;
      }
    },
    /** Phát request rồi pause rồi failed; các mode chỉ thay một oracle liên quan. */
    async readEvents(options) {
      if (!state.submitted) return { cursor: 0, events: [], truncated: false, hasMore: false };
      state.pages++;
      state.clock += mode === 'no-pause' || mode === 'no-failed' ? 1000 : 100;
      let events = [];
      if (state.pages === 1) {
        const request = { url: mode === 'wrong-url' ? loginUrl + '/other' : loginUrl, method: mode === 'wrong-method' ? 'GET' : 'POST', postData: 'SYNTHETIC_PRIVATE_SENTINEL' };
        events = [{ method: 'Network.requestWillBeSent', sequence: 1, params: { requestId: 'request-1', request } }];
        if (mode === 'duplicate') events.push({ ...events[0], sequence: 2, params: { ...events[0].params, requestId: 'request-2' } });
        if (mode === 'early-failed') events.push({ method: 'Network.loadingFailed', sequence: 2, params: { requestId: 'request-1' } });
      } else if (state.pages === 2 && mode !== 'no-pause') {
        events = [{ method: 'Fetch.requestPaused', sequence: 3, params: {
          requestId: 'fetch-1', networkId: mode === 'wrong-id' ? 'other-request' : 'request-1',
          responseStatusCode: mode === 'wrong-status' ? 401 : 200,
          request: { url: loginUrl, method: 'POST' }, responseHeaders: [{ name: 'private', value: 'SYNTHETIC_PRIVATE_SENTINEL' }],
        } }];
      } else if (state.faulted && mode !== 'no-failed') {
        events = [{ method: 'Network.loadingFailed', sequence: 4, params: { requestId: 'request-1' } }];
      }
      if (mode === 'paged-extra' && state.pages === 4) events = [
        { method: 'Network.requestWillBeSent', sequence: 5, params: { requestId: 'request-2', request: { url: loginUrl, method: 'POST' } } },
        { method: 'Fetch.requestPaused', sequence: 6, params: { requestId: 'fetch-2', networkId: 'request-2', request: { url: loginUrl, method: 'POST' }, responseStatusCode: 200 } },
      ];
      if (mode === 'tail-extra' && state.pages === 4) events = [{ method: 'Fetch.requestPaused', sequence: 5, params: { requestId: 'fetch-2', networkId: 'request-2', request: { url: loginUrl, method: 'POST' }, responseStatusCode: 200 } }];
      if (options.methods.length === 1) events = events.filter(/** Cleanup chỉ nhận pause đã buffered. */
        event => event.method === 'Fetch.requestPaused');
      return { cursor: state.pages + 10, events, truncated: mode === 'truncated', hasMore: mode === 'paged-extra' && state.pages === 3 };
    },
  };
  return {
    state, cdp,
    /** Đánh dấu submit thật của driver hoặc inject lỗi trước request. */
    async submit(options) { assert.ok(options.timeoutMs > 0 && options.timeoutMs <= 15_000); state.submitted = true; if (mode === 'submit-error') throw Error('SYNTHETIC_PRIVATE_SENTINEL'); },
    /** Trả monotonic giả để không cần sleep trong negative tests. */
    now: () => state.clock,
  };
}

/** Kiểm exact fault, deadline, metadata redaction và clear trong mọi nhánh. */
async function main() {
  const positive = setup();
  const receipt = await interruptLoginResponse({ ...positive, url: loginUrl });
  assert.equal(receipt.status, 'PASS');
  assert.equal(receipt.networkId, 'request-1');
  assert.equal(receipt.faultAcknowledged, true);
  assert.equal(receipt.loadingFailedObserved, true);
  assert.equal(receipt.interceptionCleared, true);
  assert.equal(positive.state.commands.filter(/** Chỉ đếm mutation fault, không tính setup/clear. */
    command => command.method === 'Fetch.failRequest').length, 1);
  assert.ok(receipt.faultAckElapsedMilliseconds < 15_000);
  for (const mode of ['wrong-url', 'wrong-method', 'wrong-id', 'wrong-status', 'duplicate', 'early-failed', 'truncated', 'no-pause', 'no-failed', 'submit-error', 'fail-error', 'late-ack', 'clear-error', 'setup-error', 'late-clear', 'paged-extra', 'tail-extra']) {
    const fixture = setup(mode);
    const result = await interruptLoginResponse({ ...fixture, url: loginUrl });
    assert.equal(result.status, 'FAIL', mode);
    assert.equal(result.interceptionCleared, !['clear-error', 'fail-error', 'submit-error', 'truncated', 'late-ack', 'setup-error', 'late-clear'].includes(mode), mode);
    assert.ok(fixture.state.pages <= 33, mode);
    assert.ok(!JSON.stringify(result).includes('SYNTHETIC_PRIVATE_SENTINEL'), mode);
    if (['wrong-id', 'wrong-status'].includes(mode)) {
      const aborts = fixture.state.commands.filter(/** Validation lỗi vẫn phải giải phóng đúng ID đã pause. */
        command => command.method === 'Fetch.failRequest');
      assert.deepEqual(aborts.map(/** Chỉ đối chiếu ID và enum, không raw payload. */
        command => command.params), [{ requestId: 'fetch-1', errorReason: 'Aborted' }]);
    }
    if (mode === 'fail-error') {
      assert.equal(result.commandOutcomeUnconfirmed, true);
      assert.equal(result.unresolvedPausedRequests, 1);
    }
    if (mode === 'paged-extra' || mode === 'tail-extra') {
      assert.ok(fixture.state.commands.some(/** POST trùng ở page sau phải kéo theo giải phóng đúng pause mới. */
        command => command.method === 'Fetch.failRequest' && command.params.requestId === 'fetch-2' && command.params.errorReason === 'Aborted'));
    }
  }
  // Raw command chưa settle phải còn owned, không báo clear/PASS sớm chỉ vì observer đang chờ.
  for (const boundary of ['setup', 'submit', 'fault', 'clear']) {
    const fixture = setup();
    let release;
    let entered;
    const waiting = new Promise(/** Test sở hữu quyền cho raw boundary kết thúc. */
      resolve => { release = resolve; });
    const atBoundary = new Promise(/** Báo raw boundary đã bắt đầu, không dùng sleep đoán scheduling. */
      resolve => { entered = resolve; });
    const originalSend = fixture.cdp.send;
    const originalSubmit = fixture.submit;
    fixture.cdp.send = /** Giữ đúng một command raw pending để kiểm ownership tới terminal. */
      async (method, params, options) => {
        const selected = boundary === 'setup' && method === 'Fetch.enable' && params.patterns.length > 0
          || boundary === 'fault' && method === 'Fetch.failRequest'
          || boundary === 'clear' && method === 'Fetch.enable' && params.patterns.length === 0;
        if (selected) { entered(); await waiting; }
        return originalSend(method, params, options);
      };
    fixture.submit = /** Submit pending cũng không được bị tách khỏi operation đang sở hữu nó. */
      async options => { if (boundary === 'submit') { entered(); await waiting; } return originalSubmit(options); };
    let settled = false;
    const operation = interruptLoginResponse({ ...fixture, url: loginUrl });
    operation.then(/** Chỉ actual controller result mới đánh dấu terminal. */
      () => { settled = true; });
    await atBoundary;
    assert.equal(settled, false);
    assert.equal(fixture.state.cleared, false);
    release();
    assert.equal((await operation).status, 'PASS');
  }
  console.log('BROWSER_LOGIN_RESPONSE_FAULT_22_CASES_PASS');
}

try { await main(); } catch {
  // Assertion có thể chứa fake raw event nên chỉ xuất marker cố định.
  console.error('BROWSER_LOGIN_RESPONSE_FAULT_TEST_FAILED');
  process.exitCode = 1;
}
