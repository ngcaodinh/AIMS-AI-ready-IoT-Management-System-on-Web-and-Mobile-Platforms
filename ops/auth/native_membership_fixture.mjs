import assert from 'node:assert/strict';
import { nativeSessionMap } from './native_rate_evidence.mjs';

const uuid = /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/;
const scopes = { full: 'SNAPSHOT\n', disabled: 'SNAPSHOT_DISABLED\n',
  limited: 'SNAPSHOT_LIMITED\n', empty: 'SNAPSHOT_EMPTY\n' };

/**
 * Kiểm shape metadata private, không cho field phụ mang command hoặc credentials.
 * Input
 * Param: value — object sau JSON parser của owned shim.
 * Param: keys — field allowlist do source chọn.
 * Output: true khi đúng các own keys, không array/null.
 */
function exactKeys(value, keys) {
  return value !== null && typeof value === 'object' && !Array.isArray(value) &&
    Object.keys(value).length === keys.length && keys.every(
      /** Param: key — field bắt buộc phải hiện diện bằng own property. */
      (key) => Object.hasOwn(value, key));
}

/** Output: fixed error không phản chiếu raw frame hoặc dependency exception. */
function failure() {
  return new Error('NATIVE_MEMBERSHIP_FIXTURE_FAILED');
}

/**
 * Chốt private READY namespace trước gửi command, copy arrays để caller không retarget owner.
 * Input
 * Param: frame — READY do owned child gửi, không file/journal.
 * Output: copy metadata5accounts có canonical UUID và email đúng run.
 */
function parseReady(frame, profile) {
  const expired = profile === 'offline-expired';
  assert.ok(exactKeys(frame, expired
    ? ['kind','runId','userIds','emails','expiredSessionId','expiredSessionExpiresAt']
    : ['kind','runId','userIds','emails']) && frame.kind === 'READY' &&
    typeof frame.runId === 'string' && uuid.test(frame.runId) &&
    Array.isArray(frame.userIds) && frame.userIds.length === 5 && new Set(frame.userIds).size === 5 &&
    frame.userIds.every(/** Param: id — UUID synthetic của account theo vị trí. */
      (id) => typeof id === 'string' && uuid.test(id)) &&
    Array.isArray(frame.emails) && frame.emails.length === 5 && frame.emails.every(
      /**
       * Kiểm từng identity theo run để không nhận email ngoài fixture.
       * Input
       * Param: email — identity synthetic cần đối chiếu.
       * Param: index — account0–4 xác định suffix namespace.
       * Output: email khớp namespace.
       */
      (email, index) => email === `probe-${frame.runId}-${index}@example.invalid`));
  const ready = { kind: 'READY', runId: frame.runId, userIds: [...frame.userIds], emails: [...frame.emails] };
  if (expired) {
    const expiry = frame.expiredSessionExpiresAt;
    const parsed = typeof expiry === 'string' ? Date.parse(expiry) : NaN;
    assert.ok(typeof frame.expiredSessionId === 'string' && uuid.test(frame.expiredSessionId) &&
      typeof expiry === 'string' && /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/.test(expiry) &&
      Number.isFinite(parsed) && new Date(parsed).toISOString() === expiry && parsed < Date.now() - 60_000);
    ready.expiredSessionId = frame.expiredSessionId;
    ready.expiredSessionExpiresAt = expiry;
  }
  return ready;
}

/**
 * Decode target hoặc commit receipt, không dùng UUID channel làm authority DB.
 * Input
 * Param: frame — target metadata của fixed pending command.
 * Param: baseline — target đã commit local khi đối chiếu suspended receipt.
 * Output: copy target exact schema với version còn represent an toàn trong Number.
 */
function parseTarget(frame, baseline) {
  const suspended = frame.kind === 'MEMBERSHIP_SUSPENDED';
  const keys = ['workspaceId','revision','authorizationVersion','grantGeneration'];
  if (suspended) keys.push('status');
  assert.ok(exactKeys(frame, ['kind','target']) &&
    ['MEMBERSHIP_TARGET','MEMBERSHIP_SUSPENDED'].includes(frame.kind) &&
    exactKeys(frame.target, keys));
  const target = frame.target;
  assert.ok(typeof target.workspaceId === 'string' && uuid.test(target.workspaceId));
  for (const key of ['revision','authorizationVersion','grantGeneration']) {
    const maximum = !suspended && key !== 'grantGeneration' ? Number.MAX_SAFE_INTEGER - 1 : Number.MAX_SAFE_INTEGER;
    assert.ok(Number.isSafeInteger(target[key]) && target[key] > 0 && target[key] <= maximum);
  }
  if (suspended) {
    assert.ok(baseline && target.workspaceId === baseline.workspaceId && target.status === 'SUSPENDED' &&
      target.revision === baseline.revision + 1 && target.authorizationVersion === baseline.authorizationVersion + 1 &&
      target.grantGeneration === baseline.grantGeneration);
  }
  return { ...target };
}


/**
 * Copy nested metadata đã validate để caller không sửa session/audit receipt trong parser ledger.
 * Input
 * Param: value — object có sessions/audit arrays đã schema check.
 * Output: object mới, từng row mới và chỉ metadata public.
 */
function copyEvidence(value) {
  return {
    sessions: value.sessions.map(/** Param: row — sessionId/revoked đã validate. */ (row) => ({ ...row })),
    audit: value.audit.map(/** Param: row — audit public không chứa payload hoặc actor profile. */ (row) => ({ ...row })),
    ...(value.workspaces ? { workspaces: value.workspaces.map(
      /** Param: row — A/B metadata đã kiểm theo run, copy để caller không sửa matcher tương lai. */
      (row) => ({ ...row })) } : {}),
  };
}

/**
 * Decode audit cùng sessions của một read-only SQL snapshot, không coi nó là business PASS.
 * Input
 * Param: frame — exact private receipt do owned shim phát sau query.
 * Output: copy evidence≤16sessions/≤32audit, audit chỉ gắn session cùng projection.
 */
function parseEvidence(frame, offline = false) {
  assert.ok(exactKeys(frame, offline ? ['kind','sessions','audit','workspaces'] : ['kind','sessions','audit']) && frame.kind === 'MEMBERSHIP_SESSION_EVIDENCE' &&
    Array.isArray(frame.audit) && frame.audit.length <= 32);
  const sessions = nativeSessionMap(frame.sessions);
  for (const row of frame.audit) {
    assert.ok(exactKeys(row, ['sessionId','eventType','outcome','clientType']) &&
      typeof row.sessionId === 'string' && sessions.has(row.sessionId) &&
      ['LOGIN_SUCCEEDED','LOGOUT'].includes(row.eventType) &&
      ['SUCCESS','FAILURE'].includes(row.outcome) && row.clientType === 'ANDROID');
  }
  if (offline) {
    assert.ok(Array.isArray(frame.workspaces) && frame.workspaces.length === 2 &&
      new Set(frame.workspaces.map(
        /** Param: row — UUID allowlist từ owned projection, chưa dùng làm authority. */
        (row) => row?.workspaceId)).size === 2);
    const expected = new Set(['Phòng vận hành A:ADMIN', 'Nhà kính B:USER']);
    for (const row of frame.workspaces) {
      assert.ok(exactKeys(row, ['workspaceId','name','role']) && typeof row.workspaceId === 'string' && uuid.test(row.workspaceId) &&
        expected.delete(`${row.name}:${row.role}`));
    }
    assert.equal(expected.size, 0);
  }
  // Giữ audit duplicates để final oracle có thể phát hiện multiple writes theo cùng App UUID.
  return copyEvidence(frame);
}

/**
 * Giữ one-pending ownership và clock/deadline cho profile membership của đúng fixture.
 * Input
 * Param: options — capabilities nội bộ, không nhận từ CLI hoặc JSON packet.
 * Param: options.workDeadline —20phút đã neo trước spawn, không reset sau READY.
 * Param: options.send — synchronous private pipe writer cho literal command.
 * Param: options.wait — observer frame của cùng child, nhận kind/deadline tuyệt đối.
 * Param: options.available — lifecycle/partial-buffer/closing guard của owner.
 * Param: options.close — original fixture close phải chờ terminal/8zero, không kill shim từ timeout.
 * Param: options.now — trusted monotonic clock, injection chỉ cho host tests.
 * Output: controller target/suspend/snapshot và parser hook, chưa là native business oracle.
 */
export function createNativeMembershipFixture({ workDeadline, send, wait, available, close, profile = 'membership-stale', now = /** Clock mặc định monotonic của host, không lấy wallclock hoặc packet. */ () => performance.now() }) {
  assert.ok(['membership-stale', 'offline-login', 'offline-expired'].includes(profile));
  const offline = profile !== 'membership-stale';
  assert.ok(Number.isFinite(workDeadline) && [send, wait, available, close, now].every(
    /** Param: capability — dependency phải là function do host sở hữu. */ (capability) => typeof capability === 'function'));
  let identity; let baseline; let pending; let targetSent = false; let suspendSent = false;
  let failed = false; let last = -1; let closing;

  /** Output: monotonic sample hợp lệ, mọi lỗi/rollback/nonfinite đều fixed và failed sticky. */
  function sample() {
    try {
      const value = now();
      if (!Number.isFinite(value) || value < 0 || value < last) throw failure();
      last = value; return value;
    } catch { failed = true; throw failure(); }
  }

  /** Đợi cùng original close một lần, cleanup rejection không được phản chiếu raw error vào caller. */
  async function failClosed() {
    failed = true;
    closing ??= Promise.resolve().then(
      /** Original owner giữ raw child/operation tới terminal, callback không giả exit từ deadline. */ () => close());
    try { await closing; } catch { /* Owner close vẫn giữ failure/handle, không xuất raw diagnostics. */ }
    throw failure();
  }

  /**
   * Nhận metadata sau scanner/parser và trước push vào frame ledger, chỉ pending command có receipt.
   * Input
   * Param: frame — object bounded từ owned child, không giữ raw body.
   * Errors: schema/order/replay/unsolicited receipt lỗi làm proof failed sticky.
   */
  function accept(frame) {
    if (!['READY','MEMBERSHIP_TARGET','MEMBERSHIP_SUSPENDED','SNAPSHOT','MEMBERSHIP_SESSION_EVIDENCE'].includes(frame?.kind)) return;
    try {
      if (frame.kind === 'READY') {
        assert.ok(!failed && !identity && !pending && available() === true && sample() < workDeadline);
        identity = parseReady(frame, profile); return;
      }
      let receipt;
      if (offline) assert.ok(frame.kind === 'MEMBERSHIP_SESSION_EVIDENCE');
      if (frame.kind === 'MEMBERSHIP_SESSION_EVIDENCE') receipt = parseEvidence(frame, offline);
      else if (frame.kind === 'SNAPSHOT') {
        assert.ok(exactKeys(frame, ['kind','scope','sessions']) && Object.hasOwn(scopes, frame.scope));
        nativeSessionMap(frame.sessions);
        receipt = frame.sessions.map(
          /** Param: row — UUID/revoked đã validate, copy tránh sửa ledger qua caller. */ (row) => ({ ...row }));
      } else receipt = parseTarget(frame, baseline);
      // Receipt hợp lệ của command đã gửi có thể tới trong close sau observer failure.
      // Nó không phục hồi proof, nhưng vẫn cho owner đọc STOPPED/terminal để phân loại cleanup riêng.
      if (failed && (pending?.kind === frame.kind ||
          (frame.kind === 'MEMBERSHIP_TARGET' && targetSent) ||
          (frame.kind === 'MEMBERSHIP_SUSPENDED' && suspendSent))) return;
      assert.ok(!failed && pending && pending.kind === frame.kind && !pending.received &&
        available() && sample() < pending.deadline &&
        (frame.kind !== 'SNAPSHOT' || pending.scope === frame.scope));
      pending.received = true; pending.receipt = receipt;
    } catch { failed = true; throw failure(); }
  }

  /**
   * Admission và commit một command local, chưa coi observer timeout là SQL terminal.
   * Input
   * Param: kind — fixed response enum cho target, suspend, evidence hoặc snapshot.
   * Param: scope — account enum chỉ áp snapshot.
   * Output: copy receipt sau clock/lifecycle fence, failure chỉ trả sau owned close đã settle.
   */
  async function command(kind, scope, sessionId) {
    let owner;
    try {
      assert.ok(!failed && identity && !pending && available() === true);
      if (offline) assert.ok(kind === 'MEMBERSHIP_SESSION_EVIDENCE');
      const cap = kind === 'MEMBERSHIP_SUSPENDED' ? 20_000 : 130_000;
      const current = sample();
      assert.ok(workDeadline - current >= cap);
      let literal;
      if (kind === 'MEMBERSHIP_TARGET') {
        assert.ok(!targetSent); targetSent = true; literal = 'MEMBERSHIP_TARGET\n';
      } else if (kind === 'MEMBERSHIP_SUSPENDED') {
        assert.ok(baseline && !suspendSent); suspendSent = true; literal = 'SUSPEND_B\n';
      } else if (kind === 'MEMBERSHIP_SESSION_EVIDENCE') {
        assert.ok(offline || baseline); literal = 'MEMBERSHIP_SESSION_EVIDENCE\n';
      } else {
        assert.ok(kind === 'SNAPSHOT' && Object.hasOwn(scopes, scope)); literal = scopes[scope];
      }
      owner = { kind, scope, sessionId, deadline: current + cap, received: false };
      pending = owner;
      send(literal);
      assert.ok(!failed && available() === true && sample() < owner.deadline);
      await wait(kind, owner.deadline);
      assert.ok(!failed && pending === owner && owner.received && available() === true && sample() < owner.deadline);
      if (kind === 'MEMBERSHIP_TARGET') baseline = { ...owner.receipt };
      if (kind === 'MEMBERSHIP_SESSION_EVIDENCE') return copyEvidence(owner.receipt);
      return Array.isArray(owner.receipt) ? owner.receipt.map(
        /** Param: row — trả copy session metadata đã được schema check, không cho caller sửa pending receipt. */
        (row) => ({ ...row })) : { ...owner.receipt };
    } catch { return await failClosed(); }
    finally { if (pending === owner) pending = undefined; }
  }

  return Object.freeze({
    accept,
    ready:
      /** Output: copy READY đã pin, failed/closed/expired không cấp metadata admission nữa. */
      () => {
        try {
          if (failed || !identity || available() !== true || sample() >= workDeadline) throw failure();
          return parseReady(identity, profile);
        } catch { failed = true; throw failure(); }
      },
    target: /** Resolve B đúng một lần, không mở selector/UUID từ caller. */ () => command('MEMBERSHIP_TARGET'),
    suspend: /** Suspend B đã chốt đúng một lần, không replay unknown commit. */ () => command('MEMBERSHIP_SUSPENDED'),
    sessionEvidence: /** Đọc sessions/audit của account0 pinned, không nhận selector từ caller. */
      () => command('MEMBERSHIP_SESSION_EVIDENCE'),
    snapshot:
      /** Param: scope — fixed account enum; không chồng SQL với target/suspend pending. */
      (scope = 'full') => command('SNAPSHOT', scope),
  });
}
