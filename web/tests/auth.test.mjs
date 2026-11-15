import assert from 'node:assert/strict';
import { test } from 'node:test';
import { readFileSync } from 'node:fs';
import { AuthCoordinator } from '../src/features/auth/coordinator.ts';
import { AuthError, login } from '../src/features/auth/api.ts';

const contextId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const otherContextId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const workspaceId = '33333333-3333-4333-8333-333333333333';
const profile = { id: '11111111-1111-4111-8111-111111111111', email: 'member@example.test', mustChangePassword: false };
const metadata = { 'X-Auth-Context-Id': contextId, 'X-CSRF-Token': '<nonfunctional-csrf>' };
const workspace = { id: workspaceId, name: 'Workspace A', status: 'ACTIVE', role: 'ADMIN', revision: 1 };

/** Dựng response tổng hợp cho kiểm parser/coordinator; không thay bằng chứng provider. */
function response(body, status = 200, headers = metadata) {
  return new Response(status === 204 ? null : JSON.stringify(body), { status, headers });
}

/** Cô lập storage, fetch và browser lock cho mỗi test bằng thư viện chuẩn Node. */
function setup(replies) {
  const storage = new Map();
  const calls = [];
  let state;
  let lockTail = Promise.resolve();
  globalThis.window = { setTimeout, clearTimeout };
  globalThis.localStorage = {
    /** Chỉ giữ marker tổng hợp của test trong memory. */
    getItem(key) { return storage.get(key) ?? null; },
    /** Mô phỏng ghi marker đồng bộ như localStorage. */
    setItem(key, value) { storage.set(key, value); },
    /** Xóa marker của đúng origin test. */
    removeItem(key) { storage.delete(key); },
  };
  Object.defineProperty(globalThis, 'navigator', { configurable: true, value: { locks: {
    /** Mô phỏng hàng đợi exclusive để hai coordinator không chạy mutation đồng thời. */
    async request(_name, operation) {
      const result = lockTail.then(operation);
      lockTail = result.catch(
        /** Một operation lỗi phải nhả lock để operation kế tiếp vẫn được xử lý. */
        () => undefined,
      );
      return result;
    },
  } } });
  /** Chỉ phát response theo thứ tự đã khai; request ngoài kịch bản là lỗi test. */
  globalThis.fetch = async (path, init) => {
    calls.push({ path, init });
    const reply = replies.shift();
    assert.notEqual(reply, undefined, `Unexpected request: ${path}`);
    if (reply instanceof Error) throw reply;
    return reply;
  };
  const coordinator = new AuthCoordinator(
    /** Thu snapshot UI để assert không mở picker khi chưa confirmation. */
    (next) => { state = next; },
  );
  return {
    coordinator, calls, storage,
    /** Lấy snapshot mới nhất sau callback bất đồng bộ. */
    getState() { return state; },
  };
}

/** Tạo chuỗi response full chuẩn để test tập trung vào boundary được thay đổi. */
function fullReplies() {
  return [
    response({ me: profile, limited: false, expiresAt: '2026-10-24T00:00:00Z' }),
    response({ ...profile, displayTimezone: 'UTC', preferencesRevision: 1 }),
    response({ items: [workspace], nextCursor: null }),
  ];
}

/**
 * Tạo barrier trong RAM để nhả response hoặc lock đúng mốc intent, không dựa vào sleep.
 * Output: promise đang chờ và resolver do test giữ; không chạm mạng hoặc storage thật.
 */
function deferred() {
  let resolve;
  const promise = new Promise(
    /** Giữ resolver để test hoàn tất tác vụ cũ sau khi đã chuyển phiên. */
    (complete) => { resolve = complete; },
  );
  return { promise, resolve };
}

test('Web parser rejects bearer token even on HTTP 200',
  /** Token trong Web body là vi phạm contract, không coi HTTP 200 là login thành công. */
  async () => {
    setup([response({ me: profile, limited: false, expiresAt: '2026-10-24T00:00:00Z', token: '<nonfunctional-token>' })]);
    await assert.rejects(login('member@example.test', 'synthetic-password-123'), { code: 'PROTOCOL_ERROR' });
  },
);

test('full login confirms context before picker and rechecks selection',
  /** Luồng đầy đủ tới recheck workspace phải giữ đúng thứ tự request. */
  async () => {
    const harness = setup([...fullReplies(), response({ ...workspace, membershipStatus: 'ACTIVE' })]);
    await harness.coordinator.restore();
    await harness.coordinator.signIn('member@example.test', 'synthetic-password-123');
    assert.equal(harness.getState().phase, 'picker');
    assert.equal(harness.getState().selected, undefined);
    await harness.coordinator.choose(workspaceId);
    assert.equal(harness.getState().phase, 'selected');
    assert.deepEqual(harness.calls.map(
      /** Chỉ kiểm route, không ghi payload credential vào log test. */
      (call) => call.path,
    ), ['/api/v1/auth/login', '/api/v1/me', '/api/v1/workspaces', `/api/v1/workspaces/${workspaceId}`]);
    const marker = JSON.parse(harness.storage.get('nexa-auth-intent'));
    assert.equal(marker.phase, 'accepted');
    assert.equal(marker.contextId, contextId);
    assert.equal(Object.hasOwn(marker, 'csrfToken'), false);
    assert.equal(Object.hasOwn(marker, 'password'), false);
  },
);

test('limited confirmation with wrong context never loads workspaces',
  /** 403 đúng code nhưng sai response context vẫn không được chấp nhận phiên limited. */
  async () => {
    const harness = setup([
      response({ me: { ...profile, mustChangePassword: true }, limited: true, expiresAt: '2026-10-24T00:00:00Z' }),
      response({ error: { code: 'PASSWORD_CHANGE_REQUIRED' } }, 403, { ...metadata, 'X-Auth-Context-Id': otherContextId }),
    ]);
    await harness.coordinator.restore();
    await harness.coordinator.signIn('member@example.test', 'synthetic-password-123');
    assert.equal(harness.getState().phase, 'recovery');
    assert.equal(harness.getState().error, 'AUTH_CONTEXT_MISMATCH');
    assert.equal(harness.calls.length, 2);
    assert.equal(JSON.parse(harness.storage.get('nexa-auth-intent')).phase, 'loginUnknown');
  },
);

test('limited confirmation opens password only after matching 403',
  /** Limited không nhận profile hoặc membership từ confirmation. */
  async () => {
    const harness = setup([
      response({ me: { ...profile, mustChangePassword: true }, limited: true, expiresAt: '2026-10-24T00:00:00Z' }),
      response({ error: { code: 'PASSWORD_CHANGE_REQUIRED' } }, 403),
    ]);
    await harness.coordinator.restore();
    await harness.coordinator.signIn('member@example.test', 'synthetic-password-123');
    assert.equal(harness.getState().phase, 'limited');
    assert.equal(harness.getState().profile, undefined);
    assert.equal(harness.calls.length, 2);
  },
);

test('lost response stays unknown across restore until explicit confirmation',
  /** Reload không tự nhận cookie A/B làm login thành công và không replay POST. */
  async () => {
    const harness = setup([new TypeError('synthetic network failure')]);
    await harness.coordinator.restore();
    await harness.coordinator.signIn('member@example.test', 'synthetic-password-123');
    assert.equal(harness.getState().phase, 'recovery');
    await harness.coordinator.restore();
    assert.equal(harness.calls.length, 1);
    assert.equal(harness.getState().candidate, undefined);
    assert.equal(JSON.parse(harness.storage.get('nexa-auth-intent')).phase, 'loginUnknown');
  },
);

test('credential rejection returns to form with no automatic retry',
  /** 401 chắc chắn trước cấp phiên xóa pending marker nhưng không giữ password. */
  async () => {
    const harness = setup([response({ error: { code: 'AUTH_INVALID' } }, 401, {})]);
    await harness.coordinator.restore();
    await harness.coordinator.signIn('member@example.test', 'synthetic-password-123');
    assert.equal(harness.getState().phase, 'login');
    assert.equal(harness.getState().error, 'AUTH_INVALID');
    assert.equal(harness.storage.size, 0);
    assert.equal(harness.calls.length, 1);
  },
);

test('storage failure blocks the login POST',
  /** Không gửi mutation nếu không thể ghi marker để phục hồi UNKNOWN. */
  async () => {
    const harness = setup([]);
    /** Mô phỏng browser từ chối persist marker. */
    globalThis.localStorage.setItem = () => { throw new Error('synthetic storage denial'); };
    await harness.coordinator.restore();
    await harness.coordinator.signIn('member@example.test', 'synthetic-password-123');
    assert.equal(harness.getState().error, 'STORAGE_ERROR');
    assert.equal(harness.getState().phase, 'recovery');
    assert.equal(harness.getState().profile, undefined);
    assert.equal(harness.getState().selected, undefined);
    assert.deepEqual(harness.getState().workspaces, []);
    assert.equal(harness.calls.length, 0);
  },
);

test('logout response loss preserves pending and blocks new login',
  /** Chưa có 204 thì giữ UI khóa và không tạo phiên mới để che logout UNKNOWN. */
  async () => {
    const harness = setup([...fullReplies(), new TypeError('synthetic response loss')]);
    await harness.coordinator.restore();
    await harness.coordinator.signIn('member@example.test', 'synthetic-password-123');
    await harness.coordinator.signOut();
    assert.equal(JSON.parse(harness.storage.get('nexa-auth-intent')).phase, 'logoutPending');
    assert.equal(harness.getState().phase, 'recovery');
    await harness.coordinator.signIn('member@example.test', 'synthetic-password-123');
    assert.equal(harness.getState().error, 'LOGOUT_PENDING');
    assert.equal(harness.calls.length, 4);
  },
);

test('missing browser lock fails closed',
  /** Browser thiếu khả năng tuần tự hóa không được fallback sang read-then-write storage. */
  async () => {
    const harness = setup([]);
    Object.defineProperty(globalThis, 'navigator', { configurable: true, value: {} });
    await harness.coordinator.restore();
    assert.equal(harness.getState().error, 'STORAGE_ERROR');
    assert.equal(harness.calls.length, 0);
    assert.ok(new AuthError('STORAGE_ERROR') instanceof Error);
  },
);

test('login200 followed by me401 stays unknown instead of credential rejection',
  /** Confirmation thất bại không được coi POST trước đó đã chắc chắn bị từ chối. */
  async () => {
    const replies = fullReplies();
    const harness = setup([replies[0], response({ error: { code: 'SESSION_EXPIRED' } }, 401, {})]);
    await harness.coordinator.restore();
    await harness.coordinator.signIn('member@example.test', 'synthetic-password-123');
    assert.equal(harness.getState().phase, 'recovery');
    assert.equal(JSON.parse(harness.storage.get('nexa-auth-intent')).phase, 'loginUnknown');
    assert.equal(harness.calls.length, 2);
  },
);

test('lost logout followed by terminal me401 permits a new login',
  /** Credential terminal không còn dùng được giải phóng marker mà không giả đã quan sát commit. */
  async () => {
    const harness = setup([
      ...fullReplies(), new TypeError('synthetic lost logout'),
      response({ error: { code: 'SESSION_EXPIRED' } }, 401, {}),
    ]);
    await harness.coordinator.restore();
    await harness.coordinator.signIn('member@example.test', 'synthetic-password-123');
    await harness.coordinator.signOut();
    await harness.coordinator.restore();
    await harness.coordinator.discover();
    assert.equal(harness.getState().phase, 'login');
    assert.equal(harness.getState().error, 'LOGOUT_TERMINAL');
    assert.equal(harness.storage.size, 0);
  },
);

test('incorrect password change retains the limited form and session',
  /** Người dùng phải sửa credential ngay trên form limited thay vì rơi vào recovery. */
  async () => {
    const harness = setup([
      response({ me: { ...profile, mustChangePassword: true }, limited: true, expiresAt: '2026-10-24T00:00:00Z' }),
      response({ error: { code: 'PASSWORD_CHANGE_REQUIRED' } }, 403),
      response({ error: { code: 'AUTH_INVALID' } }, 401, {}),
    ]);
    await harness.coordinator.restore();
    await harness.coordinator.signIn('member@example.test', 'synthetic-password-123');
    await harness.coordinator.changePassword('synthetic-password-000', 'Synthetic-password-456');
    assert.equal(harness.getState().phase, 'limited');
    assert.equal(harness.getState().error, 'AUTH_INVALID');
    assert.equal(JSON.parse(harness.storage.get('nexa-auth-intent')).phase, 'accepted');
  },
);

test('late discovery after invalidation cannot publish the previous account',
  /** Response discovery cũ phải bị bỏ cả khi thành công sau logout ở tab khác. */
  async () => {
    let complete;
    const pending = new Promise(
      /** Test điều khiển thời điểm response để tái hiện race mà không sleep. */
      (resolve) => { complete = resolve; },
    );
    const harness = setup([pending]);
    await harness.coordinator.restore();
    const discovery = harness.coordinator.discover();
    harness.coordinator.invalidate();
    complete(response({ ...profile, displayTimezone: 'UTC', preferencesRevision: 1 }));
    await discovery;
    assert.equal(harness.getState().candidate, undefined);
    assert.equal(harness.getState().profile, undefined);
    assert.equal(harness.getState().phase, 'recovery');
  },
);

test('invalidating an existing discovery candidate removes its account data',
  /** Reset phải thay cả các field optional, không merge profile cũ vào state mới. */
  async () => {
    const harness = setup([response({ ...profile, displayTimezone: 'UTC', preferencesRevision: 1 })]);
    await harness.coordinator.restore();
    await harness.coordinator.discover();
    assert.equal(harness.getState().candidate.kind, 'full');
    harness.coordinator.invalidate();
    assert.equal(harness.getState().candidate, undefined);
    assert.equal(harness.getState().profile, undefined);
    assert.equal(harness.getState().selected, undefined);
  },
);

test('two coordinators serialize login mutations through the shared browser lock',
  /** Tab B không được phát POST khi tab A đang giữ mutation lock. */
  async () => {
    let release;
    const pending = new Promise(
      /** Giữ response POST của tab A để kiểm tab B có phải chờ lock. */
      (resolve) => { release = resolve; },
    );
    const firstReplies = fullReplies();
    const harness = setup([pending, firstReplies[1], firstReplies[2], ...fullReplies()]);
    let secondState;
    const second = new AuthCoordinator(
      /** Theo dõi riêng state tab B; storage/lock vẫn được chia sẻ cùng origin. */
      (state) => { secondState = state; },
    );
    await harness.coordinator.restore();
    await second.restore();
    const firstLogin = harness.coordinator.signIn('member@example.test', 'synthetic-password-123');
    await new Promise(setImmediate);
    const secondLogin = second.signIn('member@example.test', 'synthetic-password-123');
    await new Promise(setImmediate);
    assert.equal(harness.calls.length, 1);
    release(firstReplies[0]);
    await Promise.all([firstLogin, secondLogin]);
    assert.equal(harness.calls.length, 6);
    assert.equal(secondState.phase, 'picker');
  },
);

test('queued restore invalidated by cleanup does not start an old request',
  /** Mô phỏng StrictMode cleanup khi restore còn đang chờ Web Lock. */
  async () => {
    let release;
    const barrier = new Promise(
      /** Chặn lock trước cả hai restore để kiểm bỏ generation của instance cũ. */
      (resolve) => { release = resolve; },
    );
    const replies = fullReplies();
    const harness = setup([replies[1], replies[2]]);
    harness.storage.set('nexa-auth-intent', JSON.stringify({ intentId: crypto.randomUUID(), phase: 'accepted', contextId }));
    const blockingLock = navigator.locks.request('nexa-auth-mutation',
      /** Lock ngoài mô phỏng mutation ở tab khác chưa kết thúc. */
      () => barrier,
    );
    const oldRestore = harness.coordinator.restore();
    harness.coordinator.invalidate();
    const newRestore = harness.coordinator.restore();
    release();
    await Promise.all([blockingLock, oldRestore, newRestore]);
    assert.equal(harness.calls.length, 2);
    assert.equal(harness.getState().phase, 'picker');
  },
);

test('invalidated queued login sends no request and preserves the current marker',
  /** Cleanup khi chờ Web Lock phải hủy intent cũ trước mọi POST hoặc ghi marker. */
  async () => {
    const barrier = deferred();
    const harness = setup(fullReplies());
    await harness.coordinator.restore();
    const held = navigator.locks.request('nexa-auth-mutation',
      /** Mô phỏng một tab khác chưa nhả khóa mutation. */
      () => barrier.promise,
    );
    const queued = harness.coordinator.signIn('member@example.test', 'synthetic-password-123');
    harness.coordinator.invalidate();
    const currentMarker = JSON.stringify({ intentId: crypto.randomUUID(), phase: 'accepted', contextId: otherContextId });
    harness.storage.set('nexa-auth-intent', currentMarker);
    barrier.resolve();
    await Promise.all([held, queued]);
    assert.equal(harness.calls.length, 0);
    assert.equal(harness.storage.get('nexa-auth-intent'), currentMarker);
    assert.equal(harness.getState().phase, 'recovery');
  },
);

test('queued retry clears the previous rejected login error before acquiring the lock',
  /** Lỗi401 cũ không được đọc như outcome của credential mới đang chờ; lock vẫn chặn POST lặp. */
  async () => {
    const harness = setup([response({ error: { code: 'AUTH_INVALID' } }, 401, {}), ...fullReplies()]);
    await harness.coordinator.restore();
    await harness.coordinator.signIn('member@example.test', 'synthetic-password-123');
    assert.equal(harness.getState().error, 'AUTH_INVALID');
    const barrier = deferred();
    const held = navigator.locks.request('nexa-auth-mutation',
      /** Giữ Web Lock để quan sát public state ngay lúc retry được giữ chỗ, chưa có request mới. */
      () => barrier.promise,
    );
    const retry = harness.coordinator.signIn('member@example.test', 'synthetic-password-123');
    const queuedState = harness.getState();
    const duplicate = harness.coordinator.signIn('member@example.test', 'synthetic-password-123');
    // Nhả barrier trước assertion để RED không để test giữ một operation đang chờ.
    barrier.resolve();
    await Promise.all([held, retry, duplicate]);
    assert.equal(queuedState.busy, true);
    assert.equal(queuedState.error, '');
    assert.equal(harness.calls.filter(
      /** Đếm route của lần lỗi và duy nhất một retry; không log payload credential. */
      (call) => call.path === '/api/v1/auth/login',
    ).length, 2);
    assert.equal(harness.getState().phase, 'picker');
  },
);

test('same-form queued login locks submit immediately and issues one POST',
  /** Hai submit trước khi lấy khóa vẫn chỉ được giữ một intent credential. */
  async () => {
    const barrier = deferred();
    const harness = setup([...fullReplies(), ...fullReplies()]);
    await harness.coordinator.restore();
    const held = navigator.locks.request('nexa-auth-mutation',
      /** Giữ khóa trước khi cả hai thao tác form được gửi. */
      () => barrier.promise,
    );
    const first = harness.coordinator.signIn('member@example.test', 'synthetic-password-123');
    const busyWhileQueued = harness.getState().busy;
    const second = harness.coordinator.signIn('member@example.test', 'synthetic-password-123');
    barrier.resolve();
    await Promise.all([held, first, second]);
    assert.equal(busyWhileQueued, true);
    assert.equal(harness.calls.filter(
      /** Chỉ đếm route; không đưa credential trong body vào assertion/log. */
      (call) => call.path === '/api/v1/auth/login',
    ).length, 1);
    assert.equal(harness.getState().phase, 'picker');
    assert.equal(harness.getState().busy, false);
  },
);

for (const action of ['choose', 'loadMore']) {
  test(`late ${action} success cannot overwrite the same intent restored in a newer generation`,
    /** Restore giữ intent ID nhưng vẫn tạo vòng đời UI mới; read cũ phải bị fence theo generation. */
    async () => {
      const oldRead = deferred();
      const initialReplies = fullReplies();
      initialReplies[2] = response({ items: [workspace], nextCursor: 'synthetic-cursor' });
      const restoreReplies = fullReplies().slice(1);
      const harness = setup([...initialReplies, oldRead.promise, ...restoreReplies]);
      await harness.coordinator.restore();
      await harness.coordinator.signIn('member@example.test', 'synthetic-password-123');
      const pending = action === 'choose' ? harness.coordinator.choose(workspaceId) : harness.coordinator.loadMore();
      harness.coordinator.invalidate();
      await harness.coordinator.restore();
      const restoredState = harness.getState();
      oldRead.resolve(action === 'choose'
        ? response({ ...workspace, membershipStatus: 'ACTIVE' })
        : response({ items: [{ ...workspace, name: 'Stale workspace name' }], nextCursor: null }));
      await pending;
      assert.deepEqual(harness.getState(), restoredState);
    },
  );
  for (const outcome of ['success', 'error']) {
    test(`late ${action} ${outcome} preserves the newer accepted picker`,
      /** Response đọc cũ phải bị bỏ ở cả success/catch, không xóa state hoặc marker phiên mới. */
      async () => {
        const oldRead = deferred();
        const initialReplies = fullReplies();
        initialReplies[2] = response({ items: [workspace], nextCursor: 'synthetic-cursor' });
        const harness = setup([...initialReplies, oldRead.promise, ...fullReplies()]);
        await harness.coordinator.restore();
        await harness.coordinator.signIn('member@example.test', 'synthetic-password-123');
        const pending = action === 'choose' ? harness.coordinator.choose(workspaceId) : harness.coordinator.loadMore();
        harness.coordinator.invalidate();
        await harness.coordinator.signIn('member@example.test', 'synthetic-password-123');
        const acceptedState = harness.getState();
        const acceptedMarker = harness.storage.get('nexa-auth-intent');
        const oldSuccess = action === 'choose'
          ? response({ ...workspace, membershipStatus: 'ACTIVE' })
          : response({ items: [], nextCursor: null });
        oldRead.resolve(outcome === 'success' ? oldSuccess : response({ error: { code: 'RESOURCE_NOT_FOUND' } }, 404, {}));
        await pending;
        assert.deepEqual(harness.getState(), acceptedState);
        assert.equal(harness.storage.get('nexa-auth-intent'), acceptedMarker);
        assert.equal(harness.getState().phase, 'picker');
      },
    );
  }
}

test('malformed login200 remains unknown across restore without protected data or replay',
  /** Payload200 sai ở từng boundary phải giữ intent UNKNOWN; restore không được tự nhận cookie hiện tại. */
  async () => {
    const valid = { me: profile, limited: false, expiresAt: '2026-10-24T00:00:00Z' };
    const missingExpiry = { ...valid };
    delete missingExpiry.expiresAt;
    const invalidReplies = [
      response(missingExpiry),
      response({ ...valid, limited: 'false' }),
      response({ ...valid, me: { ...profile, id: 'invalid-id' } }),
      response({ ...valid, token: '<nonfunctional-token>' }),
      response(valid, 200, {}),
      new Response('{', { status: 200, headers: metadata }),
    ];
    for (const reply of invalidReplies) {
      const harness = setup([reply]);
      await harness.coordinator.restore();
      await harness.coordinator.signIn('member@example.test', 'synthetic-password-123');
      assert.equal(harness.getState().phase, 'recovery');
      assert.equal(harness.getState().error, 'PROTOCOL_ERROR');
      assert.equal(harness.getState().profile, undefined);
      assert.equal(harness.getState().selected, undefined);
      assert.deepEqual(harness.getState().workspaces, []);
      assert.equal(JSON.parse(harness.storage.get('nexa-auth-intent')).phase, 'loginUnknown');
      await harness.coordinator.restore();
      assert.equal(harness.getState().phase, 'recovery');
      assert.equal(harness.calls.length, 1);
      assert.equal(harness.calls[0].path, '/api/v1/auth/login');
    }
  },
);

test('unreadable login 5xx is reported as service unavailable and remains unknown',
  /** Proxy có thể trả 5xx rỗng khi auth API chưa sẵn sàng; không được gọi sai là lỗi contract hay xác nhận login thất bại. */
  async () => {
    const harness = setup([new Response('', { status: 500 })]);
    await harness.coordinator.restore();
    await harness.coordinator.signIn('member@example.test', 'synthetic-password-123');
    assert.equal(harness.getState().phase, 'recovery');
    assert.equal(harness.getState().error, 'SERVICE_UNAVAILABLE');
    assert.equal(harness.getState().profile, undefined);
    assert.equal(JSON.parse(harness.storage.get('nexa-auth-intent')).phase, 'loginUnknown');
    assert.equal(harness.calls.length, 1);
  },
);

test('missing cookie confirmation401 allows only explicit discovery and safe GET acceptance',
  /** Cookie không đọc được bằng JS; me401 mô phỏng thiếu credential sau POST200 và recovery không replay POST. */
  async () => {
    const full = fullReplies();
    const harness = setup([
      full[0], response({ error: { code: 'SESSION_EXPIRED' } }, 401, {}),
      fullReplies()[1], fullReplies()[1], fullReplies()[2],
    ]);
    await harness.coordinator.restore();
    await harness.coordinator.signIn('member@example.test', 'synthetic-password-123');
    assert.equal(harness.getState().phase, 'recovery');
    assert.equal(harness.getState().profile, undefined);
    await harness.coordinator.restore();
    assert.equal(harness.calls.length, 2);
    await harness.coordinator.discover();
    assert.equal(harness.getState().phase, 'recovery');
    assert.equal(harness.getState().candidate.kind, 'full');
    assert.deepEqual(harness.calls[2].init.headers, {});
    assert.equal(harness.getState().profile, undefined);
    assert.deepEqual(harness.getState().workspaces, []);
    assert.equal(JSON.parse(harness.storage.get('nexa-auth-intent')).phase, 'loginUnknown');
    await harness.coordinator.acceptCandidate();
    assert.equal(harness.getState().phase, 'picker');
    assert.deepEqual(harness.calls.map(
      /** Chỉ lưu route để kiểm recovery dùng GET, không ghi password hoặc cookie. */
      (call) => call.path,
    ), ['/api/v1/auth/login', '/api/v1/me', '/api/v1/me', '/api/v1/me', '/api/v1/workspaces']);
    assert.equal(harness.calls[3].init.headers['X-Auth-Context-Id'], contextId);
    assert.equal(JSON.parse(harness.storage.get('nexa-auth-intent')).phase, 'accepted');
  },
);

test('limited confirmation variants never accept missing context expired unavailable network or full profile',
  /** Mọi confirmation không phải limited403 đúng metadata phải khóa, không ghi accepted hoặc tải workspace. */
  async () => {
    const limitedBody = { me: { ...profile, mustChangePassword: true }, limited: true, expiresAt: '2026-10-24T00:00:00Z' };
    const confirmations = [
      response({ error: { code: 'PASSWORD_CHANGE_REQUIRED' } }, 403, { 'X-CSRF-Token': '<nonfunctional-csrf>' }),
      response({ error: { code: 'PASSWORD_CHANGE_REQUIRED' } }, 403, { 'X-Auth-Context-Id': contextId }),
      response({ error: { code: 'PASSWORD_CHANGE_REQUIRED' } }, 403, { ...metadata, 'X-Auth-Context-Id': otherContextId }),
      response({ error: { code: 'SESSION_EXPIRED' } }, 401, {}),
      response({ error: { code: 'AUTH_CONTEXT_MISMATCH' } }, 409, {}),
      response({ error: { code: 'SERVICE_UNAVAILABLE' } }, 503, {}),
      new TypeError('synthetic connection failure'),
      fullReplies()[1],
    ];
    for (const confirmation of confirmations) {
      const harness = setup([response(limitedBody), confirmation]);
      await harness.coordinator.restore();
      await harness.coordinator.signIn('member@example.test', 'synthetic-password-123');
      assert.equal(harness.getState().phase, 'recovery');
      assert.equal(harness.getState().profile, undefined);
      assert.equal(harness.getState().candidate, undefined);
      assert.equal(harness.getState().selected, undefined);
      assert.deepEqual(harness.getState().workspaces, []);
      assert.equal(harness.calls.length, 2);
      assert.equal(harness.calls[1].path, '/api/v1/me');
      assert.equal(harness.calls[1].init.headers['X-Auth-Context-Id'], contextId);
      assert.equal(JSON.parse(harness.storage.get('nexa-auth-intent')).phase, 'loginUnknown');
      await harness.coordinator.restore();
      assert.equal(harness.calls.length, 2);
      assert.equal(harness.getState().phase, 'recovery');
    }
  },
);

test('full bootstrap GET outages stay unknown until explicit recovery without mutation replay',
  /** me503 hoặc mất mạng sau login200 không mở profile/cache; chỉ discovery chủ động mới gửi GET tiếp. */
  async () => {
    for (const failure of [
      response({ error: { code: 'SERVICE_UNAVAILABLE' } }, 503, {}),
      new TypeError('synthetic connection failure'),
    ]) {
      const harness = setup([fullReplies()[0], failure, fullReplies()[1]]);
      await harness.coordinator.restore();
      await harness.coordinator.signIn('member@example.test', 'synthetic-password-123');
      assert.equal(harness.getState().phase, 'recovery');
      assert.equal(harness.getState().profile, undefined);
      assert.deepEqual(harness.getState().workspaces, []);
      assert.equal(JSON.parse(harness.storage.get('nexa-auth-intent')).phase, 'loginUnknown');
      await harness.coordinator.restore();
      assert.equal(harness.calls.length, 2);
      await harness.coordinator.discover();
      assert.equal(harness.calls.length, 3);
      assert.equal(harness.calls[2].path, '/api/v1/me');
      assert.equal(harness.getState().phase, 'recovery');
      assert.equal(harness.getState().candidate.kind, 'full');
      assert.equal(harness.getState().profile, undefined);
    }
  },
);

test('accepted limited reload reacquires context and CSRF before password or logout mutation',
  /** Marker không có CSRF; restore phải confirmation403 trước mutation mang metadata mới, không tải profile/workspace. */
  async () => {
    for (const mutation of ['password', 'logout']) {
      const freshMetadata = { ...metadata, 'X-CSRF-Token': '<fresh-nonfunctional-csrf>' };
      const harness = setup([
        response({ error: { code: 'PASSWORD_CHANGE_REQUIRED' } }, 403, freshMetadata),
        response(null, 204, {}),
      ]);
      harness.storage.set('nexa-auth-intent', JSON.stringify({ intentId: crypto.randomUUID(), phase: 'accepted', contextId }));
      await harness.coordinator.restore();
      assert.equal(harness.getState().phase, 'limited');
      assert.equal(harness.getState().profile, undefined);
      assert.equal(harness.calls.length, 1);
      assert.equal(harness.calls[0].init.headers['X-Auth-Context-Id'], contextId);
      if (mutation === 'password') await harness.coordinator.changePassword('synthetic-current', 'Synthetic-next-123');
      else await harness.coordinator.signOut();
      assert.equal(harness.calls.length, 2);
      assert.equal(harness.calls[1].path, `/api/v1/auth/${mutation}`);
      assert.equal(harness.calls[1].init.headers['X-Auth-Context-Id'], contextId);
      assert.equal(harness.calls[1].init.headers['X-CSRF-Token'], freshMetadata['X-CSRF-Token']);
      assert.equal(harness.getState().phase, 'login');
      assert.equal(harness.storage.size, 0);
    }
  },
);

test('limited discovery without marker cannot mutate before explicit context confirmation',
  /** Discovery không header chỉ là ứng viên; chưa accept thì password/logout không được phát request. */
  async () => {
    const harness = setup([
      response({ error: { code: 'PASSWORD_CHANGE_REQUIRED' } }, 403),
      response({ error: { code: 'PASSWORD_CHANGE_REQUIRED' } }, 403),
    ]);
    await harness.coordinator.restore();
    await harness.coordinator.discover();
    assert.equal(harness.getState().phase, 'recovery');
    assert.equal(harness.getState().candidate.kind, 'limited');
    assert.equal(harness.storage.size, 0);
    assert.deepEqual(harness.calls[0].init.headers, {});
    await harness.coordinator.signOut();
    await harness.coordinator.changePassword('synthetic-current', 'Synthetic-next-123');
    assert.equal(harness.calls.length, 1);
    await harness.coordinator.acceptCandidate();
    assert.equal(harness.calls.length, 2);
    assert.equal(harness.calls[1].path, '/api/v1/me');
    assert.equal(harness.calls[1].init.headers['X-Auth-Context-Id'], contextId);
    assert.equal(harness.getState().phase, 'limited');
    assert.equal(harness.getState().profile, undefined);
    assert.equal(JSON.parse(harness.storage.get('nexa-auth-intent')).phase, 'accepted');
  },
);

test('pagination is on demand deduplicates IDs and server denial clears stale picker',
  /** Trang rỗng còn cursor không là hết list; tải chủ động giữ cursor đúng và không chọn trước server recheck. */
  async () => {
    const secondWorkspace = { ...workspace, id: '44444444-4444-4444-8444-444444444444', name: 'Workspace B' };
    const replies = fullReplies();
    replies[2] = response({ items: [], nextCursor: 'cursor +/one' });
    const harness = setup([
      ...replies,
      response({ items: [workspace], nextCursor: 'cursor-two' }),
      response({ items: [{ ...workspace, name: 'Updated A' }, secondWorkspace], nextCursor: null }),
      response({ error: { code: 'RESOURCE_NOT_FOUND' } }, 404, {}),
    ]);
    await harness.coordinator.restore();
    await harness.coordinator.signIn('member@example.test', 'synthetic-password-123');
    assert.equal(harness.calls.length, 3);
    assert.equal(harness.getState().phase, 'picker');
    assert.equal(harness.getState().nextCursor, 'cursor +/one');
    assert.deepEqual(harness.getState().workspaces, []);
    assert.equal(harness.getState().selected, undefined);
    await harness.coordinator.loadMore();
    assert.equal(harness.calls.length, 4);
    assert.equal(harness.calls[3].path, '/api/v1/workspaces?cursor=cursor%20%2B%2Fone');
    await harness.coordinator.loadMore();
    assert.equal(harness.calls.length, 5);
    assert.equal(harness.calls[4].path, '/api/v1/workspaces?cursor=cursor-two');
    assert.deepEqual(harness.getState().workspaces, [{ ...workspace, name: 'Updated A' }, secondWorkspace]);
    assert.equal(harness.getState().nextCursor, null);
    assert.equal(harness.getState().selected, undefined);
    await harness.coordinator.loadMore();
    assert.equal(harness.calls.length, 5);
    await harness.coordinator.choose(secondWorkspace.id);
    assert.equal(harness.calls.length, 6);
    assert.equal(harness.calls[5].path, `/api/v1/workspaces/${secondWorkspace.id}`);
    assert.equal(harness.calls[5].init.headers['X-Auth-Context-Id'], contextId);
    assert.equal(harness.getState().phase, 'recovery');
    assert.equal(harness.getState().error, 'RESOURCE_NOT_FOUND');
    assert.deepEqual(harness.getState().workspaces, []);
    assert.equal(harness.getState().selected, undefined);
    assert.equal(harness.getState().profile, undefined);
  },
);

test('pagination error never becomes an empty successful picker',
  /** Lỗi trang sau phải recovery rõ ràng, không giả đã tải hết danh sách hoặc tự gửi lại request. */
  async () => {
    const replies = fullReplies();
    replies[2] = response({ items: [], nextCursor: 'more' });
    const harness = setup([...replies, response({ error: { code: 'SERVICE_UNAVAILABLE' } }, 503, {})]);
    await harness.coordinator.restore();
    await harness.coordinator.signIn('member@example.test', 'synthetic-password-123');
    await harness.coordinator.loadMore();
    assert.equal(harness.calls.length, 4);
    assert.equal(harness.getState().phase, 'recovery');
    assert.equal(harness.getState().error, 'SERVICE_UNAVAILABLE');
    assert.equal(harness.getState().selected, undefined);
    assert.deepEqual(harness.getState().workspaces, []);
    await harness.coordinator.loadMore();
    assert.equal(harness.calls.length, 4);
  },
);

test('shared email policy preserves raw wire input and consumes canonical or rejected provider outcome',
  /** OQ001 là boundary backend; Web giữ nguyên case/whitespace/Unicode trên wire và không tự gộp dot/+tag. */
  async () => {
    const fixture = JSON.parse(readFileSync(new URL('../../contracts/fixtures/auth/email-policy.json', import.meta.url), 'utf8'));
    assert.equal(fixture.policyVersion, 1);
    for (const example of fixture.cases) {
      const body = example.error
        ? { error: { code: 'VALIDATION_ERROR', details: { fieldErrors: [{ path: '/email', code: example.error }] } } }
        : { me: { ...profile, email: example.canonical }, limited: false, expiresAt: '2030-01-01T00:00:00Z' };
      const harness = setup([response(body, example.error ? 422 : 200)]);
      if (example.error) {
        await assert.rejects(login(example.email, ' Aa1e\u0301xxxx '), { code: 'VALIDATION_ERROR', status: 422 });
      } else {
        const result = await login(example.email, ' Aa1e\u0301xxxx ');
        assert.equal(result.me.email, example.canonical);
      }
      assert.equal(harness.calls.length, 1);
      assert.deepEqual(JSON.parse(harness.calls[0].init.body), { email: example.email, password: ' Aa1e\u0301xxxx ', clientType: 'WEB' });
    }
  },
);


test('stale cursor clears cached memberships and restarts only after explicit confirmation',
  /** Quyền đổi giữa pages phải khóa dữ liệu cũ, GET-only recovery và explicit confirm khởi động lại từ page đầu. */
  async () => {
    const replies = fullReplies();
    replies[2] = response({ items: [workspace], nextCursor: 'stale-page' });
    const harness = setup([
      ...replies,
      response({ error: { code: 'CURSOR_INVALID' } }, 400, {}),
      response({ ...profile, displayTimezone: 'UTC', preferencesRevision: 1 }),
      response({ ...profile, displayTimezone: 'UTC', preferencesRevision: 1 }),
      response({ items: [], nextCursor: null }),
    ]);
    await harness.coordinator.restore();
    await harness.coordinator.signIn('member@example.test', 'synthetic-password-123');
    await harness.coordinator.loadMore();
    assert.equal(harness.getState().phase, 'recovery');
    assert.equal(harness.getState().error, 'CURSOR_INVALID');
    assert.deepEqual(harness.getState().workspaces, []);
    assert.equal(harness.getState().profile, undefined);
    assert.equal(harness.getState().selected, undefined);
    await harness.coordinator.choose(workspace.id);
    await harness.coordinator.loadMore();
    assert.equal(harness.calls.length, 4);
    await harness.coordinator.discover();
    assert.equal(harness.getState().phase, 'recovery');
    assert.deepEqual(harness.getState().workspaces, []);
    assert.equal(harness.calls.length, 5);
    await harness.coordinator.acceptCandidate();
    assert.equal(harness.getState().phase, 'picker');
    assert.deepEqual(harness.getState().workspaces, []);
    assert.equal(harness.getState().nextCursor, null);
    assert.equal(harness.calls[6].path, '/api/v1/workspaces');
    assert.equal(harness.calls.filter(
      /** Mọi recovery vẫn chỉ có một login POST ban đầu, không replay mutation. */
      (call) => call.init.method === 'POST').length, 1);
    assert.equal(harness.calls.some(
      /** Selection stale không được tạo workspace/resource GET ở nhánh recovery. */
      (call) => call.path.startsWith('/api/v1/workspaces/')), false);
  },
);
