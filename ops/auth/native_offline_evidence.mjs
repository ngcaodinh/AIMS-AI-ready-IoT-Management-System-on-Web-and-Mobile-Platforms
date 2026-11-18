import assert from 'node:assert/strict';
import { auditRows, validateMembershipAudit } from './native_membership_evidence.mjs';
import { nativeSessionMap } from './native_rate_evidence.mjs';
import { validateSessionDelta } from './run_native_e2e.mjs';

const uuid = /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/;

/**
 * Copy projection public và chặn schema lạ trước khi dùng làm oracle offline.
 * Input
 * Param: value — một MVCC snapshot sessions/audit/workspaces do fixture owned đọc.
 * Output: dữ liệu scalar mới, không giữ tham chiếu mutable từ caller hoặc credential.
 */
function copyEvidence(value) {
  assert.ok(value && Object.keys(value).length === 3 && ['sessions', 'audit', 'workspaces'].every(
    /** Param: key — ba trường projection bắt buộc, không nhận extension. */
    (key) => Object.hasOwn(value, key)));
  nativeSessionMap(value.sessions);
  const audit = auditRows(value.audit);
  assert.ok(Array.isArray(value.workspaces) && value.workspaces.length === 2);
  const workspaces = value.workspaces.map(
    /** Param: row — ID/name/role public, chỉ cặp A/Admin và B/User của fixture. */
    (row) => {
      assert.ok(row && Object.keys(row).length === 3 && typeof row.workspaceId === 'string' && uuid.test(row.workspaceId) &&
        ((row.name === 'Phòng vận hành A' && row.role === 'ADMIN') || (row.name === 'Nhà kính B' && row.role === 'USER')));
      return { workspaceId: row.workspaceId, name: row.name, role: row.role };
    });
  assert.notEqual(workspaces[0].workspaceId, workspaces[1].workspaceId);
  assert.notEqual(workspaces[0].name, workspaces[1].name);
  return { sessions: value.sessions.map(/** Param: row — copy UUID/revoked theo key order cố định sau strict validate. */
    (row) => ({ sessionId: row.sessionId, revoked: row.revoked })),
    audit, workspaces };
}

/**
 * So sánh multiset scalar public, không phụ thuộc thứ tự SQL và vẫn phát hiện duplicate.
 * Input
 * Param: before — tập baseline đã copy và validate.
 * Param: after — tập snapshot kế tiếp đã validate.
 */
function sameRows(before, after) {
  assert.deepEqual(before.map(/** Param: row — tuple với thứ tự keys cố định bởi copyEvidence. */
    (row) => JSON.stringify(row)).sort(), after.map(/** Param: row — cùng schema, duplicate giữ cardinality. */
    (row) => JSON.stringify(row)).sort());
}

/**
 * Chốt baseline/negative/live-mid/pending/revoked của cùng account0, fail sticky sau bất kỳ mismatch.
 * Input
 * Param: baseline — snapshot trước valid packet, có hai workspace và seed sessions/audit.
 * Output: targetWorkspaceId B, App session ID sau login và validator DB theo thứ tự.
 */
export function createOfflineSessionOracle(baseline) {
  const initial = copyEvidence(baseline);
  let position = 0; let failed = false; let mid; let appSessionId; let unchangedCount = 0; let finished = false;
  const targetWorkspaceId = initial.workspaces.find(/** Param: row — workspace B đã pin bằng name/role owned. */
    (row) => row.role === 'USER').workspaceId;

  /**
   * Validate và advance chỉ sau toàn bộ assertions, fault khóa oracle vĩnh viễn.
   * Input
   * Param: expected — vị trí fixed của negative/mid/final.
   * Param: value — snapshot mới từ original SQL operation đã terminal.
   */
  function accept(expected, value) {
    try {
      assert.ok(!failed && position === expected);
      const current = copyEvidence(value);
      sameRows(initial.workspaces, current.workspaces);
      if (expected === 0) {
        sameRows(initial.sessions, current.sessions);
        sameRows(initial.audit, current.audit);
      } else if (expected === 1) {
        appSessionId = validateSessionDelta(initial.sessions, current.sessions);
        // Live-mid chỉ có login thành công của App, logout phải chưa tồn tại.
        const added = current.audit.filter(/** Param: row — audit thuộc đúng AppUUID vừa bind. */
          (row) => row.sessionId === appSessionId);
        assert.deepEqual(added, [{ sessionId: appSessionId, eventType: 'LOGIN_SUCCEEDED', outcome: 'SUCCESS', clientType: 'ANDROID' }]);
        sameRows(initial.audit, current.audit.filter(/** Param: row — các audit seed phải giữ nguyên. */
          (row) => row.sessionId !== appSessionId));
        mid = current;
      } else {
        assert.ok(unchangedCount >= 3 && !finished);
        assert.equal(validateSessionDelta(initial.sessions, mid.sessions, current.sessions), appSessionId);
        validateMembershipAudit(initial.audit, current.audit, appSessionId);
        finished = true;
      }
      position++;
    } catch { failed = true; throw new Error('NATIVE_OFFLINE_SESSION_INVALID'); }
  }

  /** Xác nhận DB không đổi trước terminal để restart không che mất mutation ngoài luồng logout.
   * Input
   * Param: value — snapshot sessions/audit/workspaces mới từ fixture owner đã hoàn tất.
   * Errors: sai stage, session/audit/workspace delta hoặc replay làm oracle fail sticky.
   */
  function acceptUnchanged(value) {
    try {
      assert.ok(!failed && !finished && position === 2 && mid && appSessionId);
      const current = copyEvidence(value);
      sameRows(mid.sessions, current.sessions);
      sameRows(mid.audit, current.audit);
      sameRows(mid.workspaces, current.workspaces);
      unchangedCount++;
    } catch { failed = true; throw new Error('NATIVE_OFFLINE_SESSION_INVALID'); }
  }

  return Object.freeze({ targetWorkspaceId,
    /** ID session mới do delta DB đã bind, dùng để đối chiếu final DB readback trong scope synthetic. */
    get appSessionId() {
      assert.ok(!failed && position >= 2 && appSessionId, 'NATIVE_OFFLINE_SESSION_INVALID');
      return appSessionId;
    },
    negative: /** Param: value — offline failure xong, trước explicit login mới. */ (value) => accept(0, value),
    mid: /** Param: value — picker có AppUUID active trước A/B/logout. */ (value) => accept(1, value),
    unchanged: acceptUnchanged,
    final: /** Param: value — cùng AppUUID revoked và login/logout audit exact. */ (value) => accept(2, value),
  });
}

/**
 * Chốt session Android expired đã seed và giữ nguyên setup session/audit do fixture tạo trước lượt app.
 * Input
 * Param: baseline — snapshot có target expired, ít nhất một setup session và audit setup cần bảo toàn.
 * Param: sessionId — UUID do fixture sở hữu, dùng bind đúng row giữa baseline và final.
 * Param: expiresAt — thời hạn chính xác trả về từ PostgreSQL khi insert, phải ở quá khứ.
 * Output: unchanged/final validators và workspace đích cho proxy matcher.
 * Errors: lỗi schema, thiếu setup row, thời gian chưa hết hạn hoặc delta session/audit/workspace trả fixed failure.
 */
export function createOfflineExpiredSessionOracle(baseline, sessionId, expiresAt) {
  assert.ok(typeof sessionId === 'string' && uuid.test(sessionId) &&
    typeof expiresAt === 'string' &&
    /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/.test(expiresAt) &&
    Number.isFinite(Date.parse(expiresAt)) && Date.parse(expiresAt) < Date.now() - 60_000,
  'NATIVE_OFFLINE_EXPIRED_SESSION_INVALID');
  const initial = copyEvidence(baseline);
  const targetRows = initial.sessions.filter(
    /** Param: row — chỉ tìm session UUID do fixture báo sau insert, không suy từ thứ tự DB. */
    (row) => row.sessionId === sessionId);
  // Bắt buộc có session/audit độc lập để SQL E2E chứng minh preservation, tránh một oracle đạt PASS vacuous.
  const setupSessionIds = new Set(initial.sessions
    .filter((row) => row.sessionId !== sessionId)
    .map((row) => row.sessionId));
  const hasSetupAudit = initial.audit.some((row) => setupSessionIds.has(row.sessionId));
  assert.ok(targetRows.length === 1 && targetRows[0].revoked === false &&
    setupSessionIds.size > 0 && hasSetupAudit &&
    initial.audit.every(/** Param: row — mọi setup audit phải gắn session cùng projection. */
      (row) => initial.sessions.some(
        /** Param: session — allowlist session đã được strict copy trước khi kiểm audit. */
        (session) => session.sessionId === row.sessionId)) &&
    !initial.audit.some(/** Param: row — token expired chưa được dùng trước khi outbox khởi chạy. */
      (row) => row.sessionId === sessionId),
  'NATIVE_OFFLINE_EXPIRED_SESSION_INVALID');
  const targetWorkspaceId = initial.workspaces.find(
    /** Param: row — workspace USER dùng làm matcher ổn định, không nhận selector từ CLI. */
    (row) => row.role === 'USER')?.workspaceId;
  assert.ok(targetWorkspaceId, 'NATIVE_OFFLINE_EXPIRED_SESSION_INVALID');
  let finished = false;
  let failed = false;

  /**
   * So sánh snapshot trước terminal để chứng minh logout offline chưa sửa DB.
   * Param: value — projection mới từ cùng owned fixture.
   * Errors: mismatch đóng oracle vĩnh viễn để snapshot sau không thể che lỗi.
   */
  function unchanged(value) {
    try {
      assert.ok(!failed && !finished);
      const current = copyEvidence(value);
      sameRows(initial.sessions, current.sessions);
      sameRows(initial.audit, current.audit);
      sameRows(initial.workspaces, current.workspaces);
    } catch { failed = true; throw new Error('NATIVE_OFFLINE_EXPIRED_SESSION_INVALID'); }
  }

  /**
   * Chấp nhận revoke target cùng đúng một audit LOGOUT, đồng thời giữ nguyên session/audit provision khác.
   * Param: value — projection final sau server trả terminal và worker dọn outbox.
   * Errors: session, audit hoặc workspace delta khác expected trả fixed failure.
   */
  function final(value) {
    try {
      assert.ok(!failed && !finished);
      const current = copyEvidence(value);
      sameRows(initial.workspaces, current.workspaces);
      const expectedSessions = initial.sessions.map(
        /** Chỉ đổi revoked của UUID expired; session provision khác phải giữ nguyên trạng thái. */
        (row) => row.sessionId === sessionId ? { sessionId, revoked: true } : { ...row });
      const expectedAudit = [...initial.audit, {
        sessionId, eventType: 'LOGOUT', outcome: 'SUCCESS', clientType: 'ANDROID',
      }];
      sameRows(expectedSessions, current.sessions);
      sameRows(expectedAudit, current.audit);
      finished = true;
    } catch { failed = true; throw new Error('NATIVE_OFFLINE_EXPIRED_SESSION_INVALID'); }
  }

  return Object.freeze({ targetWorkspaceId, sessionId, expiresAt, unchanged, final });
}
