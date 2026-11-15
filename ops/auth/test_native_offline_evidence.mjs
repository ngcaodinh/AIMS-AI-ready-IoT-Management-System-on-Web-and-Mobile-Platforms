import assert from 'node:assert/strict';
import { createMembershipHttpOracle } from './native_membership_evidence.mjs';
import { createOfflineSessionOracle } from './native_offline_evidence.mjs';

const seed = '10000000-0000-4000-8000-000000000001';
const app = '10000000-0000-4000-8000-000000000002';
const a = '20000000-0000-4000-8000-000000000001';
const b = '20000000-0000-4000-8000-000000000002';
const stages = ['offline-ready', 'offline-result', 'offline-quiet', 'offline-picker', 'offline-logged-out'];
const prefixes = [1, 1, 2, 5, 9];
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
    const done = loggedIn(); done.sessions[1].revoked = mode === 'final-live' ? false : true;
    done.audit.push(audit(app, 'LOGOUT'));
    if (mode === 'final-duplicate') done.audit.push(audit(app, 'LOGOUT'));
    if (mode === 'final-seed') done.sessions[0].revoked = false;
    test.final(done);
  });
  assert.throws(/** Oracle đã fail không nhận lại snapshot negative đúng. */ () => test.negative(baseline()));
  console.log('OFFLINE_SQL_' + mode.toUpperCase().replaceAll('-', '_') + '_PASS');
}
