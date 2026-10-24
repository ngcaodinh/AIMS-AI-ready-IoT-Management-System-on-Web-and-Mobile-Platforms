"""Race hai connection PostgreSQL thật; chỉ fixture được định danh, không DB phụ."""

import re
from uuid import uuid4
from types import SimpleNamespace

from concurrency_checks import SqlSession, wait_for_block
import verify_database as lab


# Giữ mutation đầu chưa commit; quan sát pg_blocking_pids của contender rồi mới nhả lock.
def race(sql, statements, isolation="READ COMMITTED"):
    """Input
    Param: sql — adapter DB canonical đã kiểm identity.
    Param: statements — hai SQL fixture nội bộ cần chạy đồng thời.
    Param: isolation — READ COMMITTED hoặc REPEATABLE READ để chốt snapshot transaction.
    Output: hai CompletedProcess để kiểm winner/lỗi thực tế.
    """
    first = second = None
    try:
        first = SqlSession(lab.CONTAINER, lab.MIGRATOR, "iot_platform_lab", isolation)
        second = SqlSession(lab.CONTAINER, lab.MIGRATOR, "iot_platform_lab", isolation)
        first.send(statements[0] + "\n\\echo FIRST_MUTATED")
        first.wait_for("FIRST_MUTATED")
        second.send(statements[1])
        wait_for_block(sql, "iot_platform_lab", first.backend_pid, second.backend_pid)
        results = []
        for session in (first, second):
            code, output = session.finish()
            results.append(SimpleNamespace(returncode=code, stderr=output, stdout=output))
        return results
    finally:
        if first is not None:
            first.close()
        if second is not None:
            second.close()


# SKIP LOCKED phải trả0 ngay khi claim đầu còn chưa commit, không cần đợi hoặc đoán thời gian.
def verify_skip_locked_claim(sql):
    """Input
    Param: sql — adapter DB canonical đã kiểm namespace.
    Errors: RuntimeError nếu claimant thứhai nhận lại hàng đang được khóa hoặc process lỗi.
    """
    first = second = None
    try:
        first = SqlSession(lab.CONTAINER, lab.MIGRATOR, "iot_platform_lab", "READ COMMITTED")
        second = SqlSession(lab.CONTAINER, lab.MIGRATOR, "iot_platform_lab", "READ COMMITTED")
        statement = "SELECT count(*) AS claimed_count FROM claim_outbox('RACE',30,1) \\gset\n\\echo CLAIM_COUNT :claimed_count"
        first.send(statement)
        if first.wait_for("CLAIM_COUNT ") != "CLAIM_COUNT 1":
            raise RuntimeError("First claimant did not lock one outbox item")
        second.send(statement)
        if second.wait_for("CLAIM_COUNT ") != "CLAIM_COUNT 0":
            raise RuntimeError("Second claimant did not skip the locked outbox item")
        if first.finish()[0] or second.finish()[0]:
            raise RuntimeError("Claim transaction did not commit")
    finally:
        if first is not None:
            first.close()
        if second is not None:
            second.close()


def verify_outbox_expiry_after_wait(sql):
    """Kiểm native complete không settle sau expiry xảy ra trong thời gian chờ row lock.
    Input
    Param: sql — adapter canonical đã kiểm DB trống, chỉ fixture event UUID mới của hàm này.
    Output: PASS khi complete trả false sau locker rollback không đổi tuple.
    Errors: RuntimeError nếu không thấy blocked backend thật hoặc native function chấp nhận lease hết hạn.
    Side effects: hai row synthetic được dọn theo UUID trong finally, không tạo DB mới.
    """
    event = str(uuid4())
    first = second = None
    sql(f"""BEGIN;
    INSERT INTO outbox_events(outbox_event_id,event_key,event_type,payload_schema_version,payload)
     VALUES('{event}','lease-expiry-probe:{event}','TEST',1,'{{}}');
    INSERT INTO outbox_consumptions(outbox_event_id,consumer_code,state,available_at,lease_until,lease_generation,attempt_count)
     VALUES('{event}','LEASE_EXPIRY_PROBE','PROCESSING',clock_timestamp(),clock_timestamp()+interval '300 seconds',1,1);
    COMMIT;""")
    try:
        first = SqlSession(lab.CONTAINER, lab.MIGRATOR, "iot_platform_lab", "READ COMMITTED")
        second = SqlSession(lab.CONTAINER, lab.MIGRATOR, "iot_platform_lab", "READ COMMITTED")
        # Đặt deadline sau khi hai connection đã sẵn sàng, tránh startup latency làm ca test hết hạn trước lock.
        sql(f"UPDATE outbox_consumptions SET lease_until=clock_timestamp()+interval '3 seconds' WHERE outbox_event_id='{event}';")
        first.send(f"SELECT 1 FROM outbox_consumptions WHERE outbox_event_id='{event}' FOR UPDATE;\n\\echo LEASE_LOCKED")
        first.wait_for("LEASE_LOCKED")
        second.send(f"SELECT complete_outbox('{event}','LEASE_EXPIRY_PROBE',1) AS accepted \\gset\n\\echo LEASE_RESULT :accepted")
        wait_for_block(sql, "iot_platform_lab", first.backend_pid, second.backend_pid)
        # Chỉ trì hoãn sau bằng chứng khóa; rollback locker giữ nguyên tuple và deadline cũ.
        first.send("SELECT pg_sleep(3.1);\n\\echo LEASE_EXPIRED")
        first.wait_for("LEASE_EXPIRED")
        if first.finish("ROLLBACK;")[0]:
            raise RuntimeError("Outbox expiry locker failed")
        code, output = second.finish()
        if code or "LEASE_RESULT f" not in output:
            raise RuntimeError("Outbox complete accepted lease expired while waiting for rolled-back lock")
        return "PASS:outbox_complete_clock_rechecked_after_lock_wait"
    finally:
        if first is not None:
            first.close()
        if second is not None:
            second.close()
        sql(f"BEGIN; DELETE FROM outbox_consumptions WHERE outbox_event_id='{event}'; DELETE FROM outbox_events WHERE outbox_event_id='{event}'; COMMIT;")


# Một transaction thua vì invariant/serialization; lỗi hạ tầng không được coi là guard đạt.
def assert_one_winner(results):
    """Input
    Param: results — hai kết quả engine từ race.
    Errors: RuntimeError nếu không đúng một success hoặc loser sai SQLSTATE.
    """
    winners = [result for result in results if result.returncode == 0]
    losers = [result for result in results if result.returncode != 0]
    if len(winners) != 1 or len(losers) != 1 or not any(state in losers[0].stderr for state in ("23514", "40001")):
        raise RuntimeError("Concurrency did not produce exactly one valid invariant winner: " + str([result.stderr for result in results]))


# Fixture schema đã có; setup chỉ IAM/ticket/outbox để cleanup theo FK tường minh an toàn.
def verify(sql, fixture_sql):
    """Chứng minh race không mất last Admin/quota hoặc double consume/claim.
    Input
    Param: sql — adapter duy nhất tới DB canonical trống, không nhận URI/secret.
    Param: fixture_sql — BEGIN và IAM fixture tổng hợp có pg_temp.fixture_id.
    Output: năm PASS; Side effects: commit fixture tạm rồi cleanup đúng identity trong finally.
    """
    sql(fixture_sql + """
    SET CONSTRAINTS ALL DEFERRED;
    INSERT INTO users(user_id,email_normalized,password_hash,account_status,activation_provenance)
     VALUES(pg_temp.fixture_id(3),'race-admin@example.invalid','invalid-test-verifier','ACTIVE','TEST_FIXTURE');
    INSERT INTO memberships(workspace_id,user_id,role,current_grant_generation) VALUES(pg_temp.fixture_id(101),pg_temp.fixture_id(3),'ADMIN',1);
    INSERT INTO membership_grants(workspace_id,user_id,grant_generation) VALUES(pg_temp.fixture_id(101),pg_temp.fixture_id(3),1);
    INSERT INTO sessions(session_id,user_id,token_digest,auth_context_id,limited,client_type,issued_at,expires_at)
     VALUES(pg_temp.fixture_id(411),pg_temp.fixture_id(1),decode(repeat('31',32),'hex'),pg_temp.fixture_id(412),false,'WEB',now(),now()+interval '24 hours');
    INSERT INTO websocket_tickets(ticket_id,ticket_digest,workspace_id,user_id,session_id,grant_generation,workspace_authorization_version,membership_authorization_version,issued_at,expires_at)
     VALUES(pg_temp.fixture_id(2211),decode(repeat('32',32),'hex'),pg_temp.fixture_id(101),pg_temp.fixture_id(1),pg_temp.fixture_id(411),1,1,1,now(),now()+interval '30 seconds');
    INSERT INTO outbox_events VALUES(pg_temp.fixture_id(2201),pg_temp.fixture_id(101),'race-claim','TEST',1,'{}',now());
    INSERT INTO outbox_consumptions(outbox_event_id,consumer_code,available_at) VALUES(pg_temp.fixture_id(2201),'RACE',now());
    SET CONSTRAINTS ALL IMMEDIATE;
    COMMIT;
    """)
    results = []
    try:
        for isolation, label in (("READ COMMITTED", "read_committed"), ("REPEATABLE READ", "repeatable_read")):
            sql("UPDATE memberships SET role='ADMIN' WHERE workspace_id='00000000-0000-0000-0000-000000000101';")
            statements = []
            for user_number in (1, 3):
                statements.append(f"""UPDATE memberships SET role='USER' WHERE workspace_id='00000000-0000-0000-0000-000000000101'
                 AND user_id='00000000-0000-0000-0000-{user_number:012d}';""")
            assert_one_winner(race(sql, statements, isolation))
            count = sql("SELECT count(*) FROM memberships WHERE workspace_id='00000000-0000-0000-0000-000000000101' AND role='ADMIN' AND status='ACTIVE';").stdout.strip()
            if count != "1":
                raise RuntimeError("Last administrator was lost")
            results.append("PASS:race_last_admin_" + label)

        # Chuẩn bị creator ở quota4 rồi hai transaction tranh slot thứ5.
        for workspace_number in (103, 104, 105):
            sql(workspace_transaction(workspace_number))
        assert_one_winner(race(sql, (workspace_transaction(106).replace("BEGIN;", "").replace("COMMIT;", ""),
                                     workspace_transaction(107).replace("BEGIN;", "").replace("COMMIT;", ""))))
        if sql("SELECT count(*) FROM workspaces WHERE created_by_user_id='00000000-0000-0000-0000-000000000001';").stdout.strip() != "5":
            raise RuntimeError("Creator quota race exceeded limit")
        results.append("PASS:race_workspace_creator_quota")

        consume = "SELECT consume_websocket_ticket(decode(repeat('32',32),'hex')) AS accepted \\gset\n\\echo RESULT :accepted"
        ticket_results = race(sql, (consume, consume))
        if any(result.returncode for result in ticket_results) or sorted(re.search(r"RESULT ([tf])", result.stdout).group(1) for result in ticket_results) != ["f", "t"]:
            raise RuntimeError("Ticket did not have exactly one consumer")
        results.append("PASS:race_ticket_single_consumer")

        verify_skip_locked_claim(sql)
        results.append("PASS:race_outbox_single_claimant")
        results.append(verify_outbox_expiry_after_wait(sql))
        return results
    finally:
        # Chỉ các ID thuộc fixture này; nếu có reference lạ FK sẽ chặn thay vì cascade xóa dữ liệu.
        sql("""BEGIN; SET CONSTRAINTS ALL DEFERRED;
        DELETE FROM websocket_tickets WHERE ticket_id='00000000-0000-0000-0000-000000002211';
        DELETE FROM sessions WHERE session_id='00000000-0000-0000-0000-000000000411';
        DELETE FROM outbox_consumptions WHERE outbox_event_id='00000000-0000-0000-0000-000000002201';
        DELETE FROM outbox_events WHERE outbox_event_id='00000000-0000-0000-0000-000000002201';
        DELETE FROM membership_grants WHERE workspace_id IN('00000000-0000-0000-0000-000000000101','00000000-0000-0000-0000-000000000102','00000000-0000-0000-0000-000000000103','00000000-0000-0000-0000-000000000104','00000000-0000-0000-0000-000000000105','00000000-0000-0000-0000-000000000106','00000000-0000-0000-0000-000000000107');
        DELETE FROM memberships WHERE workspace_id IN('00000000-0000-0000-0000-000000000101','00000000-0000-0000-0000-000000000102','00000000-0000-0000-0000-000000000103','00000000-0000-0000-0000-000000000104','00000000-0000-0000-0000-000000000105','00000000-0000-0000-0000-000000000106','00000000-0000-0000-0000-000000000107');
        DELETE FROM workspaces WHERE workspace_id IN('00000000-0000-0000-0000-000000000101','00000000-0000-0000-0000-000000000102','00000000-0000-0000-0000-000000000103','00000000-0000-0000-0000-000000000104','00000000-0000-0000-0000-000000000105','00000000-0000-0000-0000-000000000106','00000000-0000-0000-0000-000000000107');
        DELETE FROM users WHERE user_id IN('00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000003');
        SET CONSTRAINTS ALL IMMEDIATE; COMMIT;""")


# Tên/UUID được tạo từ số literal nội bộ, không đưa user input vào SQL.
def workspace_transaction(workspace_number):
    """Input
    Param: workspace_number — ID fixture103..107 do verify chọn.
    Output: transaction tạo workspace+creator grant atomically; Errors:ValueError nếu ngoài namespace.
    """
    if workspace_number not in range(103, 108):
        raise ValueError("Unexpected fixture workspace")
    workspace_id = f"00000000-0000-0000-0000-{workspace_number:012d}"
    return f"""BEGIN; SET LOCAL statement_timeout='8s'; SET CONSTRAINTS ALL DEFERRED;
    INSERT INTO workspaces(workspace_id,name,created_by_user_id) VALUES('{workspace_id}','Concurrency fixture','00000000-0000-0000-0000-000000000001');
    INSERT INTO memberships(workspace_id,user_id,role,current_grant_generation) VALUES('{workspace_id}','00000000-0000-0000-0000-000000000001','ADMIN',1);
    INSERT INTO membership_grants(workspace_id,user_id,grant_generation) VALUES('{workspace_id}','00000000-0000-0000-0000-000000000001',1);
    SET CONSTRAINTS ALL IMMEDIATE; COMMIT;"""
