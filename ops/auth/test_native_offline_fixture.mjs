import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { randomUUID } from 'node:crypto';
import { startFixture } from './run_native_e2e.mjs';
import { createOfflineSessionOracle } from './native_offline_evidence.mjs';

/** Dựng shim fake qua parser/startFixture thật, không spawn DB/SDK hoặc chứa credential thật. */
function fakeOfflineFixture(fault = 'none') {
  const child = new EventEmitter(); child.pid = 9876;
  child.stdin = new EventEmitter(); child.stdout = new EventEmitter(); child.stderr = new EventEmitter();
  const runId = randomUUID(); const sessionId = randomUUID();
  const ready = { kind: 'READY', runId,
    userIds: Array.from({ length: 5 }, /** UUID public synthetic riêng từng account. */ () => randomUUID()),
    emails: Array.from({ length: 5 }, /** Param: index — suffix fixed namespace. */ (_, index) => `probe-${runId}-${index}@example.invalid`) };
  const evidence = { kind: 'MEMBERSHIP_SESSION_EVIDENCE', sessions: [{ sessionId, revoked: false }],
    audit: [{ sessionId, eventType: 'LOGIN_SUCCEEDED', outcome: 'SUCCESS', clientType: 'ANDROID' }],
    workspaces: [{ workspaceId: randomUUID(), name: 'Phòng vận hành A', role: 'ADMIN' },
      { workspaceId: randomUUID(), name: 'Nhà kính B', role: 'USER' }] };
  const state = { commands: [], stopWrites: 0, terminal: false };

  /** Param: frame — object synthetic gửi vào scanner/parser thật bằng owned pipe. */
  function emit(frame) { child.stdout.emit('data', Buffer.from(JSON.stringify(frame) + '\n')); }
  child.stdin.write =
    /** Param: value — private packet hoặc literal command, không in password trong output. */
    (value) => {
      if (value.startsWith('{')) {
        const packet = JSON.parse(value);
        assert.equal(packet.scenario, 'offline-login');
        return;
      }
      state.commands.push(value);
      assert.equal(value, 'MEMBERSHIP_SESSION_EVIDENCE\n');
      const frame = structuredClone(evidence);
      if (fault === 'extra') frame.workspaces[0].extra = 'untrusted';
      if (fault === 'duplicate') frame.workspaces[1].workspaceId = frame.workspaces[0].workspaceId;
      if (fault === 'role') frame.workspaces[0].role = 'USER';
      if (fault === 'missing') delete frame.workspaces;
      if (fault === 'foreign-audit') frame.audit[0].sessionId = randomUUID();
      if (fault === 'overflow') frame.sessions = Array.from({ length: 17 },
        /** Giữ UUID unique để test đúng row bound, không fail sớm do duplicate. */
        () => ({ sessionId: randomUUID(), revoked: false }));
      emit(frame);
    };
  child.stdin.end =
    /** Chỉ STOP owned mới phát cleanup/exit, fake vẫn đi qua original8zero validator. */
    (value) => {
      assert.equal(value, 'STOP\n'); state.stopWrites++;
      emit({ kind: 'STOPPED', cleanup: { role: 0, hba: 0, users: 0, sessions: 0, workspaces: 0,
        memberships: 0, auditActor: 0, limiterBuckets: 0, pushInstallations: 0, websocketTickets: 0,
        outboxEvents: 0, outboxConsumptions: 0, globalIdempotencyRecords: 0 } });
      state.terminal = true; child.emit('exit', 0);
    };
  for (const stream of [child.stdin, child.stdout, child.stderr]) {
    stream.destroy = /** Không dùng destroy làm fake terminal acknowledgement. */ () => {};
  }
  const owner = startFixture('Aa1' + 'a'.repeat(32), 'offline-login', undefined,
    /** Cấp original fake child, parser/close/schema guards vẫn là implementation thật. */ () => child);
  child.emit('spawn'); emit(ready);
  return { owner, state, ready, evidence };
}

/** Kiểm scope read-only/immutable/schema/cleanup của offline fixture adapter thực qua fake child. */
async function main() {
  {
    const seedSessionId = randomUUID();
    const appSessionId = randomUUID();
    const workspaceRows = [
      { workspaceId: randomUUID(), name: 'Phòng vận hành A', role: 'ADMIN' },
      { workspaceId: randomUUID(), name: 'Nhà kính B', role: 'USER' },
    ];
    const baseline = {
      sessions: [{ sessionId: seedSessionId, revoked: false }],
      audit: [{ sessionId: seedSessionId, eventType: 'LOGIN_SUCCEEDED', outcome: 'SUCCESS', clientType: 'ANDROID' }],
      workspaces: workspaceRows,
    };
    const mid = {
      sessions: [...baseline.sessions, { sessionId: appSessionId, revoked: false }],
      audit: [...baseline.audit, { sessionId: appSessionId, eventType: 'LOGIN_SUCCEEDED', outcome: 'SUCCESS', clientType: 'ANDROID' }],
      workspaces: workspaceRows,
    };
    const final = {
      sessions: [...baseline.sessions, { sessionId: appSessionId, revoked: true }],
      audit: [...baseline.audit,
        { sessionId: appSessionId, eventType: 'LOGIN_SUCCEEDED', outcome: 'SUCCESS', clientType: 'ANDROID' },
        { sessionId: appSessionId, eventType: 'LOGOUT', outcome: 'SUCCESS', clientType: 'ANDROID' }],
      workspaces: workspaceRows,
    };
    const oracle = createOfflineSessionOracle(baseline);
    oracle.negative(baseline);
    oracle.mid(mid);
    assert.equal(oracle.appSessionId, appSessionId);
    oracle.unchanged(mid);
    oracle.unchanged(mid);
    oracle.unchanged(mid);
    oracle.final(final);
    assert.throws(
      /** Audit final không được hợp thức hóa thêm trạng thái pending sau khi logout đã commit. */
      () => oracle.unchanged(final),
      { message: 'NATIVE_OFFLINE_SESSION_INVALID' },
    );
  }
  console.log('OFFLINE_SESSION_PENDING_RESTART_ORACLE_PASS');
  {
    const { owner, state, ready, evidence } = fakeOfflineFixture();
    assert.deepEqual(await owner.ready(), ready);
    const first = await owner.offlineEvidence();
    assert.deepEqual(first, { sessions: evidence.sessions, audit: evidence.audit, workspaces: evidence.workspaces });
    first.workspaces[0].role = 'USER';
    assert.equal((await owner.offlineEvidence()).workspaces[0].role, 'ADMIN');
    assert.deepEqual(state.commands, ['MEMBERSHIP_SESSION_EVIDENCE\n', 'MEMBERSHIP_SESSION_EVIDENCE\n']);
    await owner.close(); assert.equal(state.terminal, true); assert.equal(state.stopWrites, 1);
  }
  console.log('OFFLINE_FIXTURE_READ_COPY_OWNED_CLOSE_PASS');
  for (const action of ['membershipTarget', 'suspendMembershipB', 'snapshot']) {
    const { owner, state } = fakeOfflineFixture();
    await owner.ready();
    await assert.rejects(owner[action]());
    assert.deepEqual(state.commands, []);
    assert.equal(state.stopWrites, 1);
    assert.equal(state.terminal, true);
    console.log(`OFFLINE_FIXTURE_NO_${action.toUpperCase()}_PASS`);
  }
  for (const fault of ['extra', 'duplicate', 'role', 'missing', 'foreign-audit', 'overflow']) {
    const { owner, state } = fakeOfflineFixture(fault);
    await owner.ready();
    await assert.rejects(owner.offlineEvidence());
    assert.equal(state.stopWrites, 1);
    assert.equal(state.terminal, true);
    console.log(`OFFLINE_FIXTURE_${fault.toUpperCase().replaceAll('-', '_')}_REJECT_PASS`);
  }
}

await main();
