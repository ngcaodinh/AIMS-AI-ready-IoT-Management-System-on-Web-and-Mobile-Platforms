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
 * Chốt baseline/negative/live-mid/final của cùng account0, fail sticky sau bất kỳ mismatch.
 * Input
 * Param: baseline — snapshot trước valid packet, có hai workspace và seed sessions/audit.
 * Output: targetWorkspaceId B và ba validator theo thứ tự, không authority mutation DB.
 */
export function createOfflineSessionOracle(baseline) {
  const initial = copyEvidence(baseline);
  let position = 0; let failed = false; let mid; let appSessionId;
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
        mid = current.sessions;
      } else {
        assert.equal(validateSessionDelta(initial.sessions, mid, current.sessions), appSessionId);
        validateMembershipAudit(initial.audit, current.audit, appSessionId);
      }
      position++;
    } catch { failed = true; throw new Error('NATIVE_OFFLINE_SESSION_INVALID'); }
  }
  return Object.freeze({ targetWorkspaceId,
    negative: /** Param: value — offline failure xong, trước explicit login mới. */ (value) => accept(0, value),
    mid: /** Param: value — picker có AppUUID active trước A/B/logout. */ (value) => accept(1, value),
    final: /** Param: value — cùng AppUUID revoked và login/logout audit exact. */ (value) => accept(2, value),
  });
}
