import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { EventEmitter } from 'node:events';
import { createNativeMembershipFixture } from './native_membership_fixture.mjs';
import { startFixture } from './run_native_e2e.mjs';

/** Output: namespace READY synthetic, không đọc account hoặc credential ngoài test.
 * Param: expired — bật metadata hết hạn chỉ cho profile offline expired.
 */
function readyFrame(expired = false) {
  const runId = randomUUID();
  const frame = { kind: 'READY', runId, userIds: Array.from({ length: 5 },
    /** Mỗi vị trí là UUID public riêng để không có alias account trong fixture. */
    () => randomUUID()), emails: Array.from({ length: 5 },
    /** Param: index — vị trí account synthetic trong namespace của run. */
      (_, index) => `probe-${runId}-${index}@example.invalid`) };
  if (expired) {
    frame.expiredSessionId = randomUUID();
    frame.expiredSessionExpiresAt = new Date(Date.now() - 3_600_000).toISOString();
  }
  return frame;
}

/** Output: target B public tại baseline, các version có chỗ tăng an toàn trong Number. */
function targetFrame() {
  return { kind: 'MEMBERSHIP_TARGET', target: { workspaceId: randomUUID(),
    revision: 7, authorizationVersion: 9, grantGeneration: 3 } };
}

/**
 * Dựng trusted boundary giả và clock riêng để kiểm controller không chờ SQL hoặc timer thật.
 * Input
 * Param: overrides — thay wait/send/close khi test cần operation pending hoặc dependency lỗi.
 * Output: controller, state clock/calls và frames synthetic.
 */
function harness(overrides = {}) {
  const state = { now: 10, available: true, commands: [], closes: 0 };
  const ready = readyFrame(overrides.profile === 'offline-expired'); const target = targetFrame(); let control;
  const seed = randomUUID();
  const evidence = {kind:'MEMBERSHIP_SESSION_EVIDENCE',sessions:[{sessionId:seed,revoked:false}],
    audit:[{sessionId:seed,eventType:'LOGIN_SUCCEEDED',outcome:'SUCCESS',clientType:'ANDROID'}]};
  const suspended = { kind: 'MEMBERSHIP_SUSPENDED', target: { ...target.target, status: 'SUSPENDED',
    revision: 8, authorizationVersion: 10 } };
  control = createNativeMembershipFixture({ workDeadline: 1_200_010,
    profile: overrides.profile ?? 'membership-stale',
    now: /** Clock chỉ thuộc host test, có fault injection để kiểm fixed error. */ () => {
      if (state.clockError) throw new Error('SYNTHETIC_CLOCK_ERROR');
      return state.now;
    },
    available: /** Lifecycle fake có thể lỗi, raw exception phải bị lọc ở controller boundary. */ () => {
      if(state.availabilityError)throw new Error('SYNTHETIC_AVAILABILITY_ERROR');
      return state.available;
    },
    send: /** Param: command — literal phải được gửi một lần qua boundary owned. */
      (command) => { state.commands.push(command); overrides.send?.(command); },
    wait: overrides.wait ?? (
      /** Chỉ accept frame sau send để test buộc parser và command phải cùng pending capability. */
      async (kind) => {
        const frame = kind === 'SNAPSHOT' ? { kind, scope: 'full', sessions: [] }
          : kind === 'MEMBERSHIP_SESSION_EVIDENCE' ? evidence : kind === 'MEMBERSHIP_TARGET' ? target : suspended;
        control.accept(frame); return frame;
      }),
    close: /** Close owned phải được await, test có thể giữ raw operation chưa terminal. */ async () => {
      state.closes++; await overrides.close?.();
    },
  });
  if (!overrides.skipReady) control.accept(ready);
  return { control, state, ready, target, suspended, evidence };
}

/** Kiểm semantic schema/order/deadline và close ownership trước khi factory được mở profile mới. */
async function controllerCases() {
  {
    const { control, state, ready, target } = harness();
    const expectedReady = structuredClone(ready);
    const identity = control.ready(); identity.userIds[0] = randomUUID();
    assert.deepEqual(control.ready(), expectedReady);
    assert.deepEqual(ready, expectedReady);
    assert.deepEqual(await control.snapshot('full'), []);
    const result = await control.target(); assert.deepEqual(result, target.target);
    result.revision = 500;
    const changed = await control.suspend();
    assert.deepEqual(changed, { ...target.target, status: 'SUSPENDED', revision: 8, authorizationVersion: 10 });
    assert.deepEqual(state.commands, ['SNAPSHOT\n','MEMBERSHIP_TARGET\n','SUSPEND_B\n']);
    assert.equal(state.closes, 0);
  }
  console.log('MEMBERSHIP_CONTROLLER_ORDER_COPY_PASS');
  for (const bad of [
    { kind: 'READY', runId: randomUUID(), userIds: [], emails: [] },
    { ...readyFrame(), extra: 'SYNTHETIC_UNTRUSTED' },
    { ...readyFrame(), runId: 'ABCDEFAB-1234-4567-89AB-ABCDEFABCDEF' },
  ]) {
    const { control } = harness({ skipReady:true });
    assert.throws(/** Duplicate hoặc invalid READY không được thay identity đã chốt. */ () => control.accept(bad),
      { message: 'NATIVE_MEMBERSHIP_FIXTURE_FAILED' });
    assert.throws(/** Failed latch không được dùng identity cũ để tiếp tục. */ () => control.ready());
  }
  console.log('MEMBERSHIP_CONTROLLER_READY_SCHEMA_PASS');
  {
    const { control, ready } = harness({ profile: 'offline-expired' });
    assert.deepEqual(control.ready(), ready);
    for (const patch of [
      { expiredSessionId: 'ABCDEFAB-1234-4567-89AB-ABCDEFABCDEF' },
      { expiredSessionExpiresAt: new Date(Date.now() + 60_000).toISOString() },
      { expiredSessionExpiresAt: '2020-02-31T00:00:00.000Z' },
      { extra: 'UNTRUSTED' },
    ]) {
      const candidate = { ...readyFrame(true), ...patch };
      const { control: invalid } = harness({ profile: 'offline-expired', skipReady: true });
      assert.throws(() => invalid.accept(candidate), { message: 'NATIVE_MEMBERSHIP_FIXTURE_FAILED' });
      assert.throws(() => invalid.ready(), { message: 'NATIVE_MEMBERSHIP_FIXTURE_FAILED' });
    }
  }
  console.log('MEMBERSHIP_CONTROLLER_EXPIRED_READY_METADATA_PASS');
  for (const mutation of ['extra','boolean','unsafe','uppercase','wrong-kind','unsolicited']) {
    const { control, state, target } = harness();
    const frame = structuredClone(target);
    if (mutation === 'extra') frame.target.extra = 'SYNTHETIC_UNTRUSTED';
    if (mutation === 'boolean') frame.target.revision = true;
    if (mutation === 'unsafe') frame.target.authorizationVersion = Number.MAX_SAFE_INTEGER;
    if (mutation === 'uppercase') frame.target.workspaceId = 'ABCDEFAB-1234-4567-89AB-ABCDEFABCDEF';
    if (mutation === 'wrong-kind') frame.kind = 'MEMBERSHIP_SUSPENDED';
    assert.throws(/** Receipt không có pending owner luôn bị từ chối trước khi được public commit. */
      () => control.accept(frame), { message: 'NATIVE_MEMBERSHIP_FIXTURE_FAILED' });
    await assert.rejects(/** Không send sau parser failure. */ () => control.target());
    assert.equal(state.commands.length, 0);
    assert.equal(state.closes, 1);
  }
  console.log('MEMBERSHIP_CONTROLLER_UNSOLICITED_FAIL_CLOSED_PASS');
  for (const failure of ['target-replay','suspend-before-target','suspend-replay','invalid-scope']) {
    const { control, state } = harness();
    if (failure === 'target-replay' || failure === 'suspend-replay') await control.target();
    if (failure === 'suspend-replay') await control.suspend();
    const before = state.commands.length;
    await assert.rejects(/** Precondition sai phải await close, không gửi command mới. */
      () => failure === 'target-replay' ? control.target()
        : failure === 'invalid-scope' ? control.snapshot('foreign') : control.suspend());
    assert.equal(state.commands.length, before);
    assert.equal(state.closes, 1);
  }
  console.log('MEMBERSHIP_CONTROLLER_REPLAY_SCOPE_PASS');

  for (const bad of ['extra','boolean','unsafe','uppercase','wrong-kind',
      'wrong-workspace','wrong-revision','wrong-grant','wrong-status','snapshot-extra','snapshot-duplicate','snapshot-scope']) {
    let handle;
    const { control, state, target, suspended } = harness({
      wait:
        /** Receipts sai tới đúng pending command để schema/CAS guards được kiểm độc lập order guard. */
        async (kind) => {
          let frame = structuredClone(kind === 'MEMBERSHIP_TARGET' ? target
            : kind === 'MEMBERSHIP_SUSPENDED' ? suspended : { kind:'SNAPSHOT',scope:'full',sessions:[] });
          if (bad === 'extra') frame.target.extra = 'SYNTHETIC_UNTRUSTED';
          if (bad === 'boolean') frame.target.revision = true;
          if (bad === 'unsafe') frame.target.authorizationVersion = Number.MAX_SAFE_INTEGER;
          if (bad === 'uppercase') frame.target.workspaceId = 'ABCDEFAB-1234-4567-89AB-ABCDEFABCDEF';
          if (bad === 'wrong-kind') frame.kind = 'MEMBERSHIP_SUSPENDED';
          if (kind === 'MEMBERSHIP_SUSPENDED') {
            if (bad === 'wrong-workspace') frame.target.workspaceId = randomUUID();
            if (bad === 'wrong-revision') frame.target.revision++;
            if (bad === 'wrong-grant') frame.target.grantGeneration++;
            if (bad === 'wrong-status') frame.target.status = 'ACTIVE';
          }
          if (bad === 'snapshot-extra') frame.sessions = [{ sessionId:randomUUID(),revoked:false,extra:true }];
          if (bad === 'snapshot-duplicate') {
            const row = { sessionId:randomUUID(),revoked:false }; frame.sessions = [row,row];
          }
          if (bad === 'snapshot-scope') frame.scope = 'disabled';
          handle.control.accept(frame);
        },
    });
    handle = { control, state };
    if (bad.startsWith('wrong-') && bad !== 'wrong-kind') {
      // Target phase phải hợp lệ trước khi kiểm CAS của suspended receipt.

      await control.target();
      await assert.rejects(/** Wrong B/version/status/grant không được đổi pinned target. */ () => control.suspend());
    } else if (bad.startsWith('snapshot-')) {
      await assert.rejects(/** Session decoder và scope phải đúng pending account. */ () => control.snapshot('full'));
    } else await assert.rejects(/** Shape/version sai phải bị parser chặn trong đúng pending target. */ () => control.target());
    assert.equal(state.closes, 1);
  }
  console.log('MEMBERSHIP_CONTROLLER_PENDING_SCHEMA_CAS_PASS');

  for (const failure of ['late','rollback','nonfinite','clock-throw','exit','missing-receipt']) {
    let handle;
    const { control, state, target } = harness({
      wait: /** Sau receipt valid, dependency vẫn có thể trả về muộn hoặc child đã exit. */ async () => {
        if (failure !== 'missing-receipt') handle.control.accept(target);
        if (failure === 'late') handle.state.now = 130_010;
        if (failure === 'rollback') handle.state.now = 9;
        if (failure === 'nonfinite') handle.state.now = NaN;
        if (failure === 'clock-throw') handle.state.clockError = true;
        if (failure === 'exit') handle.state.available = false;
      },
    });
    handle = { control, state };
    await assert.rejects(/** Post-await clock/lifecycle/receipt phải còn hợp lệ, không chỉ nhìn kind. */
      () => control.target(), { message: 'NATIVE_MEMBERSHIP_FIXTURE_FAILED' });
    assert.equal(state.commands.length, 1);
    assert.equal(state.closes, 1);
  }
  console.log('MEMBERSHIP_CONTROLLER_POST_AWAIT_FENCE_PASS');
  {
    const { control, state } = harness();
    state.now = 1_100_011;
    await assert.rejects(/** Work còn ít hơn cap130s phải dừng trước write. */ () => control.target());
    assert.equal(state.commands.length, 0);
  }
  console.log('MEMBERSHIP_CONTROLLER_WORK_ADMISSION_PASS');

  for (const fault of ['unavailable','exception','clock']) {
    const {control,state} = harness();
    if(fault === 'unavailable')state.available=false;
    if(fault === 'exception')state.availabilityError=true;
    if(fault === 'clock')state.clockError=true;
    assert.throws(/** READY accessor cũng phải lọc raw dependency errors bằng cùng fixed boundary. */
      () => control.ready(), {message:'NATIVE_MEMBERSHIP_FIXTURE_FAILED'});
    await assert.rejects(/** Failure latch không cho gửi SQL tiếp sau READY dependency lỗi. */ () => control.target());
    assert.equal(state.commands.length,0); assert.equal(state.closes,1);
  }
  console.log('MEMBERSHIP_CONTROLLER_READY_DEPENDENCY_FENCE_PASS');

  {
    let releaseClose; let releaseWait; let entered;
    const waiting = new Promise(/** Giữ raw wait cho tới close thật giả đã settle. */ (resolve) => { releaseWait = resolve; });
    const closing = new Promise(/** Chưa có terminal thì method failure chưa được trả cho caller. */ (resolve) => { releaseClose = resolve; });
    const started = new Promise(/** Báo first command đang pending, tránh dựa sleep. */ (resolve) => { entered = resolve; });
    const { control, state, target } = harness({
      wait: /** Pending operation vẫn thuộc raw owner khi command thứ hai bị từ chối. */ async () => { entered(); await waiting; },
      close: /** Receipt valid tới trong cleanup không được phục hồi proof đã failed. */ async () => {
        await closing; control.accept(target); releaseWait();
      },
    });
    const first = assert.rejects(/** First command phải bị hủy proof cùng owner sau overlap. */ () => control.target());
    await started;
    let settled = false;
    const second = assert.rejects(/** Không chồng snapshot vào target pending. */ () => control.snapshot('full')).then(
      /** Đánh dấu public failure chỉ sau close capability đã terminal. */ () => { settled = true; });
    await Promise.resolve(); await Promise.resolve();
    assert.equal(settled, false); assert.equal(state.commands.length, 1);
    releaseClose(); await Promise.all([first, second]);
    assert.equal(state.closes, 1);
  }
  console.log('MEMBERSHIP_CONTROLLER_OVERLAP_OWNED_CLOSE_PASS');
}

await controllerCases();



/**
 * Tạo owned child giả đi qua factory/parser/close thật, không spawn DB hoặc SDK.
 * Input
 * Param: options — profile/receipt/STOP fault do case chọn, không production configuration.
 * Output: owner và state với manual finish để kiểm original terminal.
 */
function fakeFixture(options = {}) {
  const child = new EventEmitter(); child.pid = 5243;
  child.stdin = new EventEmitter(); child.stdout = new EventEmitter(); child.stderr = new EventEmitter();
  const state = { commands: [], terminal: false, stopWrites: 0 };
  const ready = readyFrame(options.scenario === 'offline-expired'); const target = targetFrame();
  const suspended = { kind:'MEMBERSHIP_SUSPENDED',target:{...target.target,status:'SUSPENDED',revision:8,authorizationVersion:10} };
  const cleanup = { role:0,hba:0,users:0,sessions:0,workspaces:0,memberships:0,auditActor:0,limiterBuckets:0,
    pushInstallations:0,websocketTickets:0,outboxEvents:0,outboxConsumptions:0,globalIdempotencyRecords:0 };
  const seed = randomUUID();
  const evidence = {kind:'MEMBERSHIP_SESSION_EVIDENCE',sessions:[{sessionId:seed,revoked:false}],
    audit:[{sessionId:seed,eventType:'LOGIN_SUCCEEDED',outcome:'SUCCESS',clientType:'ANDROID'}]};
  const password = 'Aa1'+'d'.repeat(32);
  const expiredSessionToken = options.scenario === 'offline-expired' ? 'e'.repeat(64) : undefined;
  const sensitiveSecrets = [password, ...(expiredSessionToken ? [expiredSessionToken] : [])];

  /** Param: frame — metadata test gửi vào parser thật sau secret scanner. */
  function emit(frame) { child.stdout.emit('data',Buffer.from(JSON.stringify(frame)+'\n')); }
  /** Chỉ phát cleanup và exit khi case xác nhận owned child fake đã terminal. */
  function finish() { emit({kind:'STOPPED',cleanup}); state.terminal=true; child.emit('exit',0); }
  child.stdin.write =
    /** Param: value — private packet/literal, chỉ ghi tên command public vào state test. */
    (value) => {
      if (value.startsWith('{')) { state.privatePacket = JSON.parse(value); return true; }
      state.commands.push(value);
      if (options.reply) { options.reply(value,emit,{target,suspended}); return true; }
      if (value === 'MEMBERSHIP_TARGET\n') emit(target);
      else if (value === 'SUSPEND_B\n') emit(suspended);
      else if (value === 'SNAPSHOT\n') emit({kind:'SNAPSHOT',scope:'full',sessions:[]});
      else if (value === 'MEMBERSHIP_SESSION_EVIDENCE\n') emit(evidence);
      return true;
    };
  child.stdin.end =
    /** Param: value — STOP phải giữ một intent, chưa phải terminal khi manualStop đang bật. */
    (value) => { assert.equal(value,'STOP\n'); state.stopWrites++; if(!options.manualStop)finish(); };
  for (const stream of [child.stdin,child.stdout,child.stderr]) {
    stream.destroy = /** Release pipe fake, không tự gán child terminal từ thao tác destroy. */ () => {};
  }
  let spawnedAt;
  const before = performance.now();
  const fixture = startFixture(password,options.scenario??'membership-stale',sensitiveSecrets,
    /** Thay duy nhất spawn capability, các schema/command/deadline/cleanup guards là source thật. */
    () => { spawnedAt=performance.now(); return child; }, undefined, expiredSessionToken);
  options.beforeReady?.();
  child.emit('spawn'); emit(ready);
  return {fixture,state,child,target,suspended,password,expiredSessionToken,finish,before,spawnedAt};
}

/** Kiểm adapter nối đúng controller/parser/close trên child sở hữu, không dùng fake method của fixture. */
async function factoryCases() {
  {
    const {fixture,state,target,before,spawnedAt} = fakeFixture();
    assert.ok(fixture.workDeadline >= before+1_200_000 && fixture.workDeadline <= spawnedAt+1_200_000);
    const ready = await fixture.ready(); ready.userIds[0]=randomUUID();
    assert.notEqual((await fixture.ready()).userIds[0],ready.userIds[0]);
    assert.deepEqual(await fixture.membershipTarget(),target.target);
    assert.deepEqual(await fixture.snapshot(),[]);
    assert.equal((await fixture.suspendMembershipB()).status,'SUSPENDED');
    await fixture.close();
    assert.equal(state.terminal,true); assert.equal(state.stopWrites,1);
  }
  console.log('MEMBERSHIP_FACTORY_REAL_BOUNDARY_PASS');

  {
    const { fixture, state, expiredSessionToken } = fakeFixture({ scenario: 'offline-expired' });
    const ready = await fixture.ready();
    assert.equal(state.privatePacket.expiredSessionToken, expiredSessionToken);
    assert.equal(ready.expiredSessionId.length, 36);
    assert.ok(Date.parse(ready.expiredSessionExpiresAt) < Date.now() - 60_000);
    await fixture.close();
  }
  console.log('MEMBERSHIP_FACTORY_EXPIRED_PRIVATE_PACKET_PASS');

  {
    const originalNow = performance.now; let clock = 100;
    performance.now = /** Clock thay trong process test riêng để kiểm startup boundary, không đổi SDK/DB. */ () => clock;
    let owned;
    try {
      owned = fakeFixture({ beforeReady:
        /** READY tại đúng startup cap không được bypass bằng gọi method trước ready(). */
        () => { clock = 900_100; } });
      await assert.rejects(/** Target không được gửi dù work20m vẫn còn sau startup15m đã hết. */
        () => owned.fixture.membershipTarget(), { message:'NATIVE_MEMBERSHIP_FIXTURE_FAILED' });
      assert.equal(owned.state.commands.length,0); assert.equal(owned.state.terminal,true);
    } finally {
      performance.now = originalNow;
      if(owned) {try {await owned.fixture.close();} catch { /* Late READY giữ failure, owner vẫn được drain. */ }}
    }
  }
  console.log('MEMBERSHIP_FACTORY_STARTUP_BOUNDARY_PASS');

  for(const failure of ['partial','secret','old-profile']) {
    const {fixture,state,child,password} = fakeFixture({scenario:failure==='old-profile'?'default':'membership-stale'});
    await fixture.ready();
    if(failure==='partial')child.stdout.emit('data',Buffer.from('{"kind":'));
    if(failure==='secret') {
      child.stderr.emit('data',Buffer.from(password.slice(0,12)));
      child.stderr.emit('data',Buffer.from(password.slice(12)));
    }
    await assert.rejects(/** Precondition sai không được gửi target SQL, failure vẫn giữ close ownership. */
      () => fixture.membershipTarget());
    assert.equal(state.commands.length,0); assert.equal(state.terminal,true); assert.equal(state.stopWrites,1);
    try {await fixture.close();} catch { /* Malformed channel giữ cleanup failure, raw terminal vẫn đã quan sát. */ }
  }
  console.log('MEMBERSHIP_FACTORY_PRECONDITION_SECRET_CLOSE_PASS');
  for(const fault of ['extra','duplicate','wrong-suspend']) {
    const {fixture,state} = fakeFixture({reply:
      /** Gửi receipt sai từ owned pipe để bắt parser/controller guard, không patch validator. */
      (command,emit,frames) => {
        if(command==='MEMBERSHIP_TARGET\n') {
          emit(fault==='extra'?{...frames.target,extra:true}:frames.target);
          if(fault==='duplicate')emit(frames.target);
        } else if(command==='SUSPEND_B\n')emit({...frames.suspended,target:{...frames.suspended.target,workspaceId:randomUUID()}});
      }});
    await fixture.ready();
    if(fault==='wrong-suspend') {
      await fixture.membershipTarget();
      await assert.rejects(/** Commit receipt của B khác không được ACK. */ () => fixture.suspendMembershipB());
    } else await assert.rejects(/** Extra hoặc duplicate frame phải poison business proof. */ () => fixture.membershipTarget());
    assert.equal(state.terminal,true);
    try {await fixture.close();} catch { /* Receipt protocol lỗi không được biến thành cleanup success. */ }
  }
  console.log('MEMBERSHIP_FACTORY_RECEIPT_SCHEMA_REPLAY_PASS');
  {
    const {fixture,state,finish}=fakeFixture({manualStop:true});
    await fixture.ready(); await fixture.membershipTarget();
    let settled=false;
    const rejected=assert.rejects(/** Replay phải chờ original child exit/8zero trước trả failure. */
      () => fixture.membershipTarget()).then(
      /** Public rejection chỉ settle sau owned terminal. */ () => {settled=true;});
    await Promise.resolve(); await Promise.resolve(); await new Promise(
      /** Cho close helper một event-loop turn để write STOP, không fake clock business. */
      (resolve) => setImmediate(resolve));
    assert.equal(state.stopWrites,1); assert.equal(state.terminal,false); assert.equal(settled,false);
    finish(); await rejected; await fixture.close();
    assert.equal(state.stopWrites,1);
  }
  console.log('MEMBERSHIP_FACTORY_REPLAY_AWAITS_ORIGINAL_TERMINAL_PASS');
}

await factoryCases();



/** Kiểm full sessions/audit evidence trước khi host dùng nó làm final session oracle. */
async function evidenceCases() {
  {
    const {control,state,target,evidence}=harness();
    await control.target();
    const expected=structuredClone(evidence);
    const actual=await control.sessionEvidence();
    assert.deepEqual(actual,{sessions:expected.sessions,audit:expected.audit});
    actual.sessions[0].revoked=true; actual.audit[0].eventType='LOGOUT';
    assert.deepEqual(evidence,expected);
    assert.deepEqual(state.commands,['MEMBERSHIP_TARGET\n','MEMBERSHIP_SESSION_EVIDENCE\n']);
    assert.equal(state.closes,0);
  }
  console.log('MEMBERSHIP_SESSION_EVIDENCE_SCHEMA_COPY_PASS');
  for(const fault of ['header-extra','sessions-overflow','audit-overflow','session-duplicate','foreign-session',
      'event-type','outcome','client','audit-extra']) {
    let handle;
    const {control,state,target,evidence}=harness({wait:
      /** Gửi audit receipt sai trong đúng pending kind để kiểm schema độc lập với sequence. */
      async(kind)=>{
        const frame=structuredClone(kind==='MEMBERSHIP_TARGET'?target:evidence);
        if(kind==='MEMBERSHIP_SESSION_EVIDENCE'){
          if(fault==='header-extra')frame.extra=true;
          if(fault==='sessions-overflow')frame.sessions=Array.from({length:17},
            /** Mỗi row mới có UUID riêng để overflow không bị duplicate guard che. */ ()=>({sessionId:randomUUID(),revoked:false}));
          if(fault==='audit-overflow')frame.audit=Array(33).fill(frame.audit[0]);
          if(fault==='session-duplicate')frame.sessions.push(frame.sessions[0]);
          if(fault==='foreign-session')frame.audit[0].sessionId=randomUUID();
          if(fault==='event-type')frame.audit[0].eventType='PASSWORD_CHANGED';
          if(fault==='outcome')frame.audit[0].outcome='UNKNOWN';
          if(fault==='client')frame.audit[0].clientType='WEB';
          if(fault==='audit-extra')frame.audit[0].extra='SYNTHETIC_UNTRUSTED';
        }
        handle.control.accept(frame);
      }});
    handle={control,state};
    await control.target();
    await assert.rejects(/** Không nhận incomplete/foreign/unknown schema như oracle hợp lệ. */
      ()=>control.sessionEvidence(),{message:'NATIVE_MEMBERSHIP_FIXTURE_FAILED'});
    assert.equal(state.closes,1);
  }
  {
    let handle;
    const {control,evidence,target}=harness({wait:
      /** Audit duplicates phải giữ nguyên để business oracle sau này đếm đúng thay vì che multiple writes. */
      async(kind)=>{
        const frame=structuredClone(kind==='MEMBERSHIP_TARGET'?target:evidence);
        if(kind==='MEMBERSHIP_SESSION_EVIDENCE')frame.audit.push({...frame.audit[0]});
        handle.control.accept(frame);
      }});
    handle={control};
    await control.target(); assert.equal((await control.sessionEvidence()).audit.length,2);
  }

  {
    const {control,state}=harness();
    await assert.rejects(/** Evidence không được gửi trước owned target đã chốt. */
      ()=>control.sessionEvidence(),{message:'NATIVE_MEMBERSHIP_FIXTURE_FAILED'});
    assert.equal(state.commands.length,0); assert.equal(state.closes,1);
  }
  {
    const {control,state}=harness();
    await control.target(); state.now=1_100_011;
    await assert.rejects(/** Read evidence phải còn đủ cap130s, không mở budget mới sau target. */
      ()=>control.sessionEvidence(),{message:'NATIVE_MEMBERSHIP_FIXTURE_FAILED'});
    assert.equal(state.commands.length,1); assert.equal(state.closes,1);
  }

  console.log('MEMBERSHIP_SESSION_EVIDENCE_NEGATIVES_PASS');
  {
    const {fixture,state}=fakeFixture();
    await fixture.ready(); await fixture.membershipTarget();
    const actual=await fixture.membershipSessionEvidence();
    assert.equal(actual.sessions.length,1);
    assert.equal(actual.audit[0].sessionId,actual.sessions[0].sessionId);
    assert.equal(actual.audit[0].eventType,'LOGIN_SUCCEEDED');
    await fixture.close(); assert.equal(state.terminal,true);
  }
  console.log('MEMBERSHIP_FACTORY_SESSION_EVIDENCE_PASS');
}

await evidenceCases();
