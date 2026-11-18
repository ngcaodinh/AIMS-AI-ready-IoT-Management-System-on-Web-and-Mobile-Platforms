import assert from 'node:assert/strict';
import { createMembershipHttpOracle } from './native_membership_evidence.mjs';
import { createOfflineExpiredSessionOracle, createOfflineSessionOracle } from './native_offline_evidence.mjs';

const seed = '10000000-0000-4000-8000-000000000001';
const app = '10000000-0000-4000-8000-000000000002';
const a = '20000000-0000-4000-8000-000000000001';
const b = '20000000-0000-4000-8000-000000000002';
const stages = ['offline-ready', 'offline-result', 'offline-quiet', 'offline-picker',
  'offline-outbox-ready', 'offline-outbox-persisted', 'offline-outbox-resumed', 'offline-logged-out'];
const prefixes = [1, 1, 2, 5, 8, 8, 8, 9];
const requests = [['PROFILE_READ', 401], ['PROFILE_READ', 401], ['AUTH_LOGIN', 200], ['PROFILE_READ', 200],
  ['WORKSPACE_LIST', 200], ['WORKSPACE_DETAIL', 200], ['WORKSPACE_LIST', 200], ['WORKSPACE_DETAIL', 200], ['AUTH_LOGOUT', 204]];

/** Output: lịch sử H2 độc lập theo bảng case, không socket/DB hoặc dữ liệu auth. */
function history() {
  const oracle = createMembershipHttpOracle('offline-login');
  let sequence = 0; let count = 0; let raw = 1;
  const byKind = { AUTH_LOGIN: 0, PROFILE_READ: 0, WORKSPACE_LIST: 0, PASSWORD_CHANGE: 0,
    AUTH_LOGOUT: 0, WORKSPACE_DETAIL: 0, OTHER: 0 };
  /** Output: bản copy metadata public giống schema capture thực. */
  function snapshot() {
    return { healthy: true, sealed: false, sequence, elapsedMilliseconds: sequence, rawOpened: raw,
      rawActive: 0, opened: count, active: 0, requests: count, statuses: count, closed: count,
      incomplete: 0, byKind: { ...byKind }, proxyAvailable: true };
  }
  oracle.baseline(snapshot());
  /** Param: wanted/fault — cumulative prefix và một lỗi metadata để chứng minh fail closed. */
  function feed(wanted, fault) {
    raw = 2 + wanted;
    while (count < wanted) {
      const [kind, status] = requests[count] ?? ['AUTH_LOGIN', 200];
      const base = { requestId: count + 1, kind, matchesTarget: count === 7 };
      for (const event of ['REQUEST', 'STATUS', 'CLOSED']) {
        const value = { sequence: ++sequence, elapsedMilliseconds: sequence, event, ...base,
          ...(event === 'STATUS' ? { status } : {}),
          ...(event === 'CLOSED' ? { requestObserved: true, statusObserved: true } : {}) };
        if (fault === 'status' && event === 'STATUS') value.status = 201;
        if (fault === 'target') value.matchesTarget = !value.matchesTarget;
        if (fault === 'extra') value.extra = true;
        oracle.observe(value);
      }
      count++; byKind[kind]++;
    }
  }
  return { oracle, feed, snapshot };
}

/** Param: id/eventType — public audit tuple synthetic. Output: fixed Android success event. */
function audit(id, eventType) {
  return { sessionId: id, eventType, outcome: 'SUCCESS', clientType: 'ANDROID' };
}

/** Output: fixture projection synthetic có seed và hai workspace, mỗi call copy mới. */
function baseline() {
  return { sessions: [{ sessionId: seed, revoked: true }], audit: [audit(seed, 'LOGIN_SUCCEEDED')],
    workspaces: [{ workspaceId: a, name: 'Phòng vận hành A', role: 'ADMIN' },
      { workspaceId: b, name: 'Nhà kính B', role: 'USER' }] };
}

/** Output: mid/final synthetic đúng một AppUUID, không credential hoặc token. */
function loggedIn() {
  const value = baseline();
  value.sessions.push({ sessionId: app, revoked: false }); value.audit.push(audit(app, 'LOGIN_SUCCEEDED'));
  return value;
}

const http = history();
for (let index = 0; index < stages.length; index++) {
  http.feed(prefixes[index]); http.oracle.checkpoint(stages[index], http.snapshot());
  http.oracle.assertCurrent(http.snapshot());
}
http.oracle.finish(http.snapshot());
console.log('OFFLINE_HTTP_NINE_REQUEST_PREFIX_PASS');
for (const mode of ['status', 'target', 'extra', 'prefix', 'raw-extra', 'active', 'incomplete', 'order', 'unavailable']) {
  const test = history();
  assert.throws(/** Một boundary sai phải đóng proof, không retry snapshot khác. */ () => {
    test.feed(mode === 'prefix' ? 2 : 1, ['status', 'target', 'extra'].includes(mode) ? mode : undefined);
    const value = test.snapshot();
    if (mode === 'raw-extra') value.rawOpened++;
    if (mode === 'active') value.active++;
    if (mode === 'incomplete') value.incomplete++;
    if (mode === 'unavailable') value.proxyAvailable = false;
    test.oracle.checkpoint(mode === 'order' ? stages[1] : stages[0], value);
  });
  assert.throws(/** Sticky fault không phục hồi bằng valid prefix sau đó. */
    () => test.oracle.checkpoint(stages[0], test.snapshot()));
  console.log('OFFLINE_HTTP_' + mode.toUpperCase().replaceAll('-', '_') + '_PASS');
}

const initial = baseline(); const session = createOfflineSessionOracle(initial);
assert.equal(session.targetWorkspaceId, b);
initial.sessions[0].revoked = false;
session.negative(baseline());
const mid = loggedIn(); session.mid(mid); mid.sessions[1].revoked = true;
const final = loggedIn(); final.sessions[1].revoked = true; final.audit.push(audit(app, 'LOGOUT'));
session.unchanged(loggedIn());
session.unchanged(loggedIn());
session.unchanged(loggedIn());
session.final(final);
assert.throws(/** Final không được replay để mở một acceptance mới. */ () => session.final(final));
console.log('OFFLINE_SQL_NEGATIVE_MID_FINAL_COPY_PASS');
for (const mode of ['negative-session', 'negative-audit', 'workspace', 'mid-revoked', 'mid-audit', 'mid-extra', 'final-live', 'final-duplicate', 'final-seed']) {
  const test = createOfflineSessionOracle(baseline());
  assert.throws(/** Chỉ một fault từng stage, không thay schema hay baseline các ca khác. */ () => {
    const negative = baseline();
    if (mode === 'negative-session') negative.sessions[0].revoked = false;
    if (mode === 'negative-audit') negative.audit = [];
    if (mode === 'workspace') negative.workspaces[1].workspaceId = app;
    test.negative(negative);
    const live = loggedIn();
    if (mode === 'mid-revoked') live.sessions[1].revoked = true;
    if (mode === 'mid-audit') live.audit.push(audit(app, 'LOGOUT'));
    if (mode === 'mid-extra') live.sessions.push({ sessionId: a, revoked: false });
    test.mid(live);
    test.unchanged(loggedIn());
    test.unchanged(loggedIn());
    test.unchanged(loggedIn());
    const done = loggedIn(); done.sessions[1].revoked = mode === 'final-live' ? false : true;
    done.audit.push(audit(app, 'LOGOUT'));
    if (mode === 'final-duplicate') done.audit.push(audit(app, 'LOGOUT'));
    if (mode === 'final-seed') done.sessions[0].revoked = false;
    test.final(done);
  });
  assert.throws(/** Oracle đã fail không nhận lại snapshot negative đúng. */ () => test.negative(baseline()));
  console.log('OFFLINE_SQL_' + mode.toUpperCase().replaceAll('-', '_') + '_PASS');
}

/** Output: projection SQL gồm phiên seed expired cùng session/audit login đã có khi fixture được provision. */
function expiredBaseline(sessionId = app, revoked = false) {
  return { sessions: [{ sessionId: seed, revoked: false }, { sessionId, revoked }],
    audit: [audit(seed, 'LOGIN_SUCCEEDED')],
    workspaces: [{ workspaceId: a, name: 'Phòng vận hành A', role: 'ADMIN' },
      { workspaceId: b, name: 'Nhà kính B', role: 'USER' }] };
}

{
  const expiresAt = new Date(Date.now() - 60 * 60 * 1000).toISOString();
  const oracle = createOfflineExpiredSessionOracle(expiredBaseline(), app, expiresAt);
  assert.equal(oracle.targetWorkspaceId, b);
  oracle.unchanged(expiredBaseline());
  const final = expiredBaseline(app, true);
  final.audit.push(audit(app, 'LOGOUT'));
  oracle.final(final);
  assert.throws(() => oracle.final(final));
  console.log('OFFLINE_EXPIRED_SQL_FINAL_SESSION_AUDIT_PASS');
  for (const invalid of [expiredBaseline(seed), expiredBaseline(app, true)]) {
    assert.throws(() => createOfflineExpiredSessionOracle(invalid, app, expiresAt));
  }
  const targetAudit = expiredBaseline();
  targetAudit.audit.push(audit(app, 'LOGIN_SUCCEEDED'));
  assert.throws(() => createOfflineExpiredSessionOracle(targetAudit, app, expiresAt));
  // Không cho E2E đạt PASS vacuous nếu fixture thiếu session/audit setup để kiểm tra preservation.
  const missingSetup = { ...expiredBaseline(), sessions: [{ sessionId: app, revoked: false }], audit: [] };
  assert.throws(() => createOfflineExpiredSessionOracle(missingSetup, app, expiresAt));
  assert.throws(() => createOfflineExpiredSessionOracle(expiredBaseline(), app,
    new Date(Date.now() + 60 * 60 * 1000).toISOString()));

  const concurrentChange = expiredBaseline(app, true);
  concurrentChange.sessions[0].revoked = true;
  concurrentChange.audit.push(audit(app, 'LOGOUT'));
  const preservation = createOfflineExpiredSessionOracle(expiredBaseline(), app, expiresAt);
  assert.throws(() => preservation.final(concurrentChange));
  console.log('OFFLINE_EXPIRED_SQL_PRESERVES_SETUP_SESSION_PASS');
}

{
  const oracle = createMembershipHttpOracle('offline-expired');
  let sequence = 0; let count = 0;
  const byKind = { AUTH_LOGIN: 0, PROFILE_READ: 0, WORKSPACE_LIST: 0, PASSWORD_CHANGE: 0,
    AUTH_LOGOUT: 0, WORKSPACE_DETAIL: 0, OTHER: 0 };
  /** Output: snapshot capture cho phiên expired, không có protected read hoặc login request. */
  function expiredSnapshot() {
    return { healthy: true, sealed: false, sequence, elapsedMilliseconds: sequence, rawOpened: count + 2,
      rawActive: 0, opened: count, active: 0, requests: count, statuses: count, closed: count,
      incomplete: 0, byKind: { ...byKind }, proxyAvailable: true };
  }
  oracle.baseline({ ...expiredSnapshot(), rawOpened: 1 });
  for (const stage of ['offline-expired-offline', 'offline-expired-ready', 'offline-expired-persisted',
    'offline-outbox-resumed']) {
    oracle.checkpoint(stage, expiredSnapshot()); oracle.assertCurrent(expiredSnapshot());
  }
  const request = { requestId: 1, kind: 'AUTH_LOGOUT', matchesTarget: false };
  for (const event of ['REQUEST', 'STATUS', 'CLOSED']) {
    sequence++;
    oracle.observe({ sequence, elapsedMilliseconds: sequence, event, ...request,
      ...(event === 'STATUS' ? { status: 204 } : {}),
      ...(event === 'CLOSED' ? { requestObserved: true, statusObserved: true } : {}) });
  }
  count = 1; byKind.AUTH_LOGOUT = 1;
  oracle.checkpoint('offline-logged-out', expiredSnapshot()); oracle.finish(expiredSnapshot());
  console.log('OFFLINE_EXPIRED_HTTP_SINGLE_TERMINAL_LOGOUT_PASS');
}
