"""Khởi chạy HTTP auth trên DB canonical bằng fixture có ownership; không reset dữ liệu hiện hữu."""

import argparse
import getpass
import hashlib
import hmac
import json
import secrets
import subprocess
import sys
import threading
import time
from functools import partial
from datetime import datetime, timedelta, timezone
from pathlib import Path
from uuid import UUID, uuid4

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "ops/database"))
import local_db_bridge as bridge
import verify_database as lab
import verify_repositories as repository
from commit_ack_bridge import CommitAckServer

TABLES = "users,sessions,login_attempt_buckets,workspaces,memberships,membership_grants,user_preferences,push_installations,websocket_tickets,outbox_events,outbox_consumptions,global_idempotency_records"
ROLE = "iot_repository_probe"
DATABASE = "iot_platform_lab"


# Chỉ cấp quyền IAM/bootstrap cần cho lab, không cấp DDL, worker retention hoặc feature thiết bị/template.
def provision(password, run_id):
    """Cấp role SCRAM tạm một giờ với quyền tối thiểu để fixture chạy đủ Auth HTTP và consume ticket.

    Input
    Param: password — credential CSPRNG của role tạm, chỉ dùng trong câu lệnh provision.
    Param: run_id — UUID do launcher sở hữu, dùng đánh dấu provenance của role kiểm thử.
    Side effects: tạo role test, giới hạn quyền theo bảng/function cần cho Auth Lab và cập nhật HBA scoped.
    """
    if len(password) != 64 or any(character not in "0123456789abcdef" for character in password):
        raise ValueError("Invalid generated credential")
    expiry = (datetime.now(timezone.utc) + timedelta(hours=1)).isoformat()
    statement = f"""BEGIN;
DO $$ BEGIN IF EXISTS(SELECT 1 FROM pg_roles WHERE rolname='{ROLE}') THEN
RAISE EXCEPTION 'Auth/repository lab already active'; END IF; END $$;
CREATE ROLE {ROLE} LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS CONNECTION LIMIT 16;
COMMENT ON ROLE {ROLE} IS 'Temporary canonical repository verification:{run_id}';
SET LOCAL password_encryption='scram-sha-256';
ALTER ROLE {ROLE} PASSWORD '{password}' VALID UNTIL '{expiry}';
GRANT CONNECT ON DATABASE {DATABASE} TO {ROLE};
GRANT USAGE ON SCHEMA public TO {ROLE};
GRANT SELECT,INSERT,UPDATE ON users,sessions,login_attempt_buckets,workspaces,memberships,membership_grants,user_preferences,push_installations,websocket_tickets TO {ROLE};
GRANT SELECT,INSERT ON audit_events,outbox_events,outbox_consumptions TO {ROLE};
GRANT SELECT,INSERT,UPDATE,DELETE ON global_idempotency_records TO {ROLE};
GRANT EXECUTE ON FUNCTION public.assert_workspace_capable_admin(uuid) TO {ROLE};
-- Chỉ cấp hàm consume ticket cho role Auth Lab tạm; không mở quyền function cho PUBLIC hoặc role runtime.
GRANT EXECUTE ON FUNCTION public.consume_websocket_ticket(bytea) TO {ROLE};
COMMIT;"""
    # Không truyền stderr psql có thể phản chiếu SQL chứa credential vào exception/log.
    if lab.sql(statement, role=lab.ADMIN, database=DATABASE, check=False).returncode:
        raise RuntimeError("Temporary auth role provisioning failed")
    repository.scoped_hba(True)


def set_fixture_session_read_access(run_id, enabled):
    """Tạm đổi SELECT trên sessions của đúng role fixture để kiểm nhánh DB fail-closed.

    Input
    Param: run_id — UUID phải khớp ownership marker trước khi sửa ACL.
    Param: enabled — true cấp lại SELECT, false thu hồi trong cửa sổ probe có finally restore.
    Errors: RuntimeError cố định nếu role không thuộc lượt chạy hoặc ACL không đạt trạng thái dự kiến.
    Side effects: đổi quyền đọc đúng bảng public.sessions của role fixture; caller luôn phải khôi phục.
    """
    if type(enabled) is not bool or not repository.owns_probe(run_id):
        raise RuntimeError('Auth lab realtime ACL ownership check failed')
    action, direction, expected = (
        ('GRANT', 'TO', 't') if enabled else ('REVOKE', 'FROM', 'f')
    )
    # Chỉ fault một quyền SELECT của principal tổng hợp đã xác minh; transaction/Auth API không bị sửa schema.
    statement = f"{action} SELECT ON TABLE public.sessions {direction} {ROLE};"
    changed = lab.sql(statement, role=lab.ADMIN, database=DATABASE, check=False)
    permission = lab.sql(
        f"SELECT has_table_privilege('{ROLE}', 'public.sessions', 'SELECT');",
        role=lab.ADMIN, database=DATABASE, check=False,
    )
    if changed.returncode or permission.returncode or permission.stdout.strip() != expected:
        raise RuntimeError('Auth lab realtime ACL state could not be confirmed')


# Mỗi identity/digest là giá trị do launcher sinh, không nối input password/email người dùng vào SQL.
def cleanup(run_id, user_ids, email_digests):
    """Xóa đúng graph fixture; email_digests chỉ nhận từ key live, None khi recovery không chứng minh bucket ownership."""
    identities = ",".join("'" + str(UUID(str(value))) + "'::uuid" for value in user_ids)
    if email_digests is not None and not all(len(value) == 64 and all(character in "0123456789abcdef" for character in value) for value in email_digests):
        raise ValueError("Invalid fixture digest")
    # Journal có thể bị sửa; selector trong file không phải bằng chứng đủ để xóa limiter row vô danh.
    # Chỉ live launcher còn key nguồn trong memory mới cấp danh sách digest; recovery giữ nguyên bucket.
    bucket_statement = ""
    if email_digests:
        digests = ",".join("decode('" + value + "','hex')" for value in email_digests)
        bucket_statement = "DELETE FROM login_attempt_buckets WHERE email_digest IN (" + digests + ");"
    # SQL teardown chỉ dùng UUID đã parse; installation gắn active_user_id cần xóa trước session do khóa ngoại.
    statement = f"""BEGIN;
DO $$ BEGIN IF EXISTS(SELECT 1 FROM users WHERE user_id IN ({identities}) AND
(email_normalized NOT LIKE 'probe-{run_id}-%@example.invalid' OR activation_provenance NOT IN ('AUTH_HTTP_LAB:{run_id}','SELF_PASSWORD_CHANGE')))
THEN RAISE EXCEPTION 'Auth fixture ownership mismatch'; END IF; END $$;
DELETE FROM audit_events WHERE actor_user_id IN ({identities});
DELETE FROM outbox_consumptions WHERE outbox_event_id IN (SELECT outbox_event_id FROM outbox_events WHERE event_type='SESSION_REVOKED' AND payload->>'userId' IN (SELECT user_id::text FROM users WHERE user_id IN ({identities})));
DELETE FROM outbox_events WHERE event_type='SESSION_REVOKED' AND payload->>'userId' IN (SELECT user_id::text FROM users WHERE user_id IN ({identities}));
DELETE FROM global_idempotency_records WHERE user_id IN ({identities});
DELETE FROM websocket_tickets WHERE user_id IN ({identities});
-- Push installation tham chiếu cả user/session; dọn theo owner còn tồn tại trước khi xóa session.
DELETE FROM push_installations WHERE active_user_id IN ({identities});
DELETE FROM sessions WHERE user_id IN ({identities});
DELETE FROM membership_grants WHERE user_id IN ({identities});
DELETE FROM memberships WHERE user_id IN ({identities});
DELETE FROM workspaces WHERE created_by_user_id IN ({identities});
DELETE FROM user_preferences WHERE user_id IN ({identities});
DELETE FROM users WHERE user_id IN ({identities});
{bucket_statement}
SET CONSTRAINTS ALL IMMEDIATE;
COMMIT;"""
    if lab.sql(statement, database=DATABASE, check=False).returncode:
        raise RuntimeError("Auth fixture cleanup failed; ownership journal retained")


# Không chiếm role cũ; chỉ đóng role đã kiểm marker lượt chạy trước khi thao tác.
def revoke(run_id):
    """Thu hồi role sau khi trả hết quyền bảng và function, đồng thời đóng đúng session/HBA của lượt chạy.

    Input
    Param: run_id — UUID lượt chạy dùng đối chiếu marker sở hữu role trước mọi mutation.
    Errors: lỗi SQL hoặc HBA được truyền về để caller giữ journal, không báo cleanup thành công.
    Side effects: chỉ đóng principal lab đã sở hữu; không terminate reader hoặc role khác.
    """
    if not repository.owns_probe(run_id):
        return
    # Role/database là hằng nội bộ, không nội suy credential hoặc input người dùng vào SQL đặc quyền.
    statement = f"""ALTER ROLE {ROLE} NOLOGIN;
SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE usename='{ROLE}' AND pid<>pg_backend_pid();
REVOKE ALL ON {TABLES},audit_events FROM {ROLE};
REVOKE ALL ON FUNCTION public.assert_workspace_capable_admin(uuid) FROM {ROLE};
-- Thu hồi capability consume ticket vừa cấp cho fixture trước DROP ROLE để PostgreSQL không giữ grant phụ thuộc.
REVOKE ALL ON FUNCTION public.consume_websocket_ticket(bytea) FROM {ROLE};
REVOKE ALL ON SCHEMA public FROM {ROLE};
REVOKE ALL ON DATABASE {DATABASE} FROM {ROLE};
DROP ROLE {ROLE};"""
    try:
        if lab.sql(statement, role=lab.ADMIN, database=DATABASE, check=False).returncode:
            raise RuntimeError("Temporary auth role cleanup failed")
    finally:
        # Quyền sở hữu đã xác nhận; SQL timeout/lỗi không được giữ lại HBA cho principal lab này.
        repository.scoped_hba(False)


def close_bridge(server, timeout_seconds=5):
    """Đóng bridge theo hai budget độc lập để lỗi listener không bỏ qua cleanup graph/role phía sau.

    Input
    Param: server — bridge thuộc launcher, chỉ đóng sau khi backend child đã terminal.
    Param: timeout_seconds — tối đa 5 giây mỗi bước; test có thể rút ngắn để tái hiện bridge treo.
    Output: True chỉ khi shutdown và server_close đều kết thúc không lỗi; False giữ journal để recovery.
    Side effects: worker daemon có thể còn chờ sau timeout, vì Python không thể hủy an toàn một thread.
    """
    if not 0 < timeout_seconds <= 5:
        raise ValueError('Invalid bridge cleanup budget')

    def invoke(action, outcome):
        """Cô lập lỗi thao tác bridge và chỉ trả trạng thái, tránh lộ thông tin connection.

        Input
        Param: action — một thao tác shutdown hoặc close của bridge đã sở hữu.
        Param: outcome — ô kết quả riêng cho worker, không dùng chung giữa hai bước.
        Side effects: thêm đúng một boolean; caller vẫn phải xác minh thread đã kết thúc.
        """
        try:
            action()
            outcome.append(True)
        except BaseException:
            # Kể cả worker bị ngắt, bước còn lại và cleanup DB vẫn phải được thử; không log exception.
            outcome.append(False)

    completed = []
    for action in (server.shutdown, server.server_close):
        outcome = []
        worker = threading.Thread(target=invoke, args=(action, outcome), daemon=True)
        try:
            worker.start()
            worker.join(timeout_seconds)
            completed.append(not worker.is_alive() and outcome == [True])
        except (RuntimeError, OSError):
            completed.append(False)
    return all(completed)


def verify_realtime_sqlx_checkout(database_port, database_password, checks):
    """Chạy test SQLx/PostgreSQL thật bằng credential chỉ qua stdin, không lưu hoặc in cấu hình.

    Input
    Param: database_port — cổng bridge loopback do chính lượt Auth Lab sở hữu.
    Param: database_password — token CSPRNG của role fixture, truyền riêng cho process test qua stdin.
    Param: checks — danh sách marker nội bộ chỉ nhận tên test đã xác minh.
    Errors: RuntimeError cố định khi test lỗi, timeout hoặc không chạy đúng một test đích.
    Side effects: mở test runner Rust giới hạn 1 connection; test chỉ truy vấn PostgreSQL và đóng checkout lỗi.
    """
    payload = json.dumps({
        "database_port": database_port,
        "database_password": database_password,
    }).encode("utf-8")
    # Credential fixture chỉ qua pipe dành riêng cho process này, không đi theo argument, file hoặc log.
    command = [
        "cargo", "test", "--locked", "--offline", "-p", "iot-platform-backend",
        "--features", "http-server", "--lib",
        "http::realtime::tests::sqlx_canceled_query_closes_checkout_before_permit_release",
        "--", "--ignored", "--exact", "--nocapture",
    ]
    try:
        result = subprocess.run(
            command,
            cwd=ROOT / "backend",
            input=payload,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=180,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        raise RuntimeError("REALTIME_SQLX_TEST_RUNNER_TIMEOUT") from None

    expected = (
        b"test http::realtime::tests::sqlx_canceled_query_closes_checkout_before_permit_release ... ok"
    )
    if result.returncode != 0 or expected not in result.stdout:
        output = (result.stdout + result.stderr).decode("utf-8", errors="replace")
        # Chỉ phát marker allowlist để chẩn đoán; output thô có thể chứa dữ liệu xác thực từ runner.
        if "running 1 test" not in output:
            reason = "REALTIME_SQLX_TEST_BUILD_OR_DISCOVERY_FAILED"
        else:
            failure_markers = (
                ("REALTIME_SQLX_STAGE_CONFIG_VALID", "REALTIME_SQLX_TEST_AUTH_LAB_CONNECT_FAILED"),
                ("REALTIME_SQLX_STAGE_POOL_CONNECTED", "REALTIME_SQLX_TEST_CHECKOUT_FAILED"),
                ("REALTIME_SQLX_STAGE_QUERY_STARTED", "REALTIME_SQLX_TEST_CALLER_DID_NOT_DETACH"),
                ("REALTIME_SQLX_STAGE_CALLER_DETACHED", "REALTIME_SQLX_TEST_QUERY_NOT_CANCELED"),
                ("REALTIME_SQLX_STAGE_QUERY_CANCELED", "REALTIME_SQLX_TEST_EXPLICIT_CLOSE_NOT_STARTED"),
                ("REALTIME_SQLX_STAGE_CHECKOUT_CLOSE_PENDING", "REALTIME_SQLX_TEST_EXPLICIT_CLOSE_FAILED"),
                ("REALTIME_SQLX_STAGE_CHECKOUT_CLOSED", "REALTIME_SQLX_TEST_POOL_RECOVERY_FAILED"),
                ("REALTIME_SQLX_STAGE_POOL_RECOVERED", "REALTIME_SQLX_TEST_PERMIT_RELEASED_EARLY"),
                ("REALTIME_SQLX_STAGE_PERMIT_HELD_AFTER_RECOVERY", "REALTIME_SQLX_TEST_PERMIT_NOT_RELEASED"),
                ("REALTIME_SQLX_STAGE_PERMIT_REACQUIRED", "REALTIME_SQLX_TEST_FOLLOWUP_HANDSHAKE_FAILED"),
                ("REALTIME_SQLX_STAGE_FOLLOWUP_HANDSHAKE_PASSED", "REALTIME_SQLX_TEST_FAILED_DURING_POOL_CLOSE"),
                ("REALTIME_SQLX_STAGE_ADAPTER_CALLER_DETACHED", "REALTIME_SQLX_TEST_ADAPTER_CALLER_DID_NOT_DETACH"),
                ("REALTIME_SQLX_STAGE_ADAPTER_CHECKOUT_CLOSED", "REALTIME_SQLX_TEST_ADAPTER_CHECKOUT_NOT_CLOSED"),
                ("REALTIME_SQLX_STAGE_ADAPTER_POOL_RECOVERED", "REALTIME_SQLX_TEST_ADAPTER_POOL_NOT_RECOVERED"),
                ("REALTIME_SQLX_STAGE_ADAPTER_PERMIT_REACQUIRED", "REALTIME_SQLX_TEST_ADAPTER_PERMIT_NOT_RELEASED"),
                ("REALTIME_SQLX_STAGE_ADAPTER_PROBE_PASSED", "REALTIME_SQLX_TEST_FAILED_AFTER_ADAPTER_PROBE"),
            )
            completed = [marker for stage, marker in failure_markers if stage in output]
            reason = completed[-1] if completed else "REALTIME_SQLX_TEST_FAILED_BEFORE_CONFIG_VALIDATION"
        raise RuntimeError(reason)
    checks.append("realtime-sqlx-canceled-checkout-before-permit-release")
    checks.append("realtime-adapter-session-denial-checkout-close-before-permit-release")


def validate_fixture_password(password):
    """Kiểm password TEST mới trước cấu hình seed, không lưu/log hoặc sửa chuỗi.

    Input
    Param: password — dữ liệu tổng hợp trong RAM, không lấy từ .env hoặc hệ thống.
    Errors: ValueError cố định nếu ngoài9–128 hoặc thiếu Unicode hoa/thường/số0–9.
    """
    if not 9 <= len(password) <= 128 or not any(character.isupper() for character in password) or not any(character.islower() for character in password) or not any(character in '0123456789' for character in password):
        raise ValueError("Test password must contain 9–128 Unicode scalars, uppercase, lowercase and digit0–9")


def stop_lab(process):
    """Dừng đúng child đã sở hữu rồi chờ thoát trước khi dọn fixture.

    Input
    Param: process — handle Popen do chính launcher tạo, không nhận PID từ bên ngoài.
    Errors: không dừng được child thì giữ journal và không được coi cleanup thành công.
    """
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=15)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=15)


def start_lab(config, pool_budget=False, capture_sink=None, output_captures=None):
    """Mở một child và chỉ bàn giao quyền sở hữu khi nhận đúng READY, dọn child khi startup lỗi.

    Input
    Param: config — config lab trong RAM gồm credential; chỉ truyền stdin, không argv/log/env.
    Param: pool_budget — opt-in verify riêng giữ framed stdin mở; normal vẫn đóng sau JSON tới EOF.
    Param: capture_sink — primary/peer khi verify muốn capture stdout/stderr từ lúc Popen.
    Param: output_captures — list nội bộ nhận cặp handle/capture để scan sau khi child terminal.
    Output: handle child sẵn sàng, caller bắt buộc stop trước DB cleanup.
    Errors: lỗi startup/timeout chỉ mang thông báo cố định, không stderr/config nhạy cảm.
    """
    # Chỉ chạy output Cargo đã build; không mở/list thư mục build và không kế thừa env máy.
    binary = ROOT / 'backend/target/x86_64-pc-windows-gnu/debug/auth-lab.exe'
    arguments = [str(binary), '--pool-budget'] if pool_budget else [str(binary)]
    process = subprocess.Popen(arguments, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, encoding='utf-8', env={'SystemRoot': r'C:\Windows'}, creationflags=subprocess.CREATE_NO_WINDOW)
    reader = None
    capture = None
    try:
        if capture_sink is not None:
            if pool_budget or capture_sink not in ('primary', 'peer') or output_captures is None:
                raise ValueError('Invalid backend output capture scope')
            from backend_output_capture import BackendOutputCapture
            capture = BackendOutputCapture(process, capture_sink)
            capture.start()
        deadline = time.monotonic() + 45
        process.stdin.write(json.dumps(config) + ('\n' if pool_budget else ''))
        if pool_budget:
            process.stdin.flush()
        else:
            process.stdin.close()
        if capture is not None:
            while not capture.ready.is_set() and process.poll() is None and time.monotonic() < deadline:
                time.sleep(.1)
            if not capture.ready.is_set() or time.monotonic() >= deadline:
                raise RuntimeError('Auth lab failed to initialize; no secret diagnostics emitted')
            output_captures.append((process, capture))
        else:
            ready = []
            reader = threading.Thread(target=read_ready, args=(process, ready))
            reader.start()
            while not ready and process.poll() is None and time.monotonic() < deadline:
                time.sleep(.1)
            # READY truthy không được short-circuit mất fresh check khi reader/write đã vượt45s.
            if ready != ['AUTH_LAB_READY'] or time.monotonic() >= deadline:
                raise RuntimeError('Auth lab failed to initialize; no secret diagnostics emitted')
            reader.join(timeout=min(1, max(0, deadline - time.monotonic())))
            if reader.is_alive() or time.monotonic() >= deadline:
                raise RuntimeError('Auth lab readiness reader shutdown unverified')
        return process
    except BaseException:
        # Kể cả Ctrl+C trước return, caller chưa có handle nên helper phải thu hồi child này.
        stop_lab(process)
        if capture is not None:
            try:
                capture.finish(process, ())
            except RuntimeError:
                raise RuntimeError('Auth lab startup capture shutdown unverified') from None
        if reader is not None:
            reader.join(timeout=5)
            if reader.is_alive():
                raise RuntimeError('Auth lab startup reader shutdown unverified') from None
        raise


# Kiểm ledger/identity trước mọi mutation; không áp EMPTY_GUARD vì không purge hoặc reset dữ liệu toàn cục.
def run(verify=False, port=3000, operation_holders=None):
    """Chạy lab sở hữu graph, verify dùng hai process để kiểm limiter DB thay vì counter trong RAM.

    Input
    Param: verify — chạy provider suite rồi cleanup, không giữ server tương tác.
    Param: port — cổng loopback primary; verify còn cần port+1 cho peer.
    Param: operation_holders — registry owner nội bộ đã chốt trước run, drain sau backend stop và trước graph cleanup.
    Output: report invariant, stage baseline và latency tổng hợp không secret khi verify.
    Errors: port/input/tool/DB lỗi dừng trước hoặc cleanup đúng ownership, không reset canonical DB.
    Side effects: role tạm1giờ và5accounts/2workspaces được dọn sau khi mọi child đã dừng.
    """
    if not 1024 <= port <= (65534 if verify else 65535):
        raise ValueError('Invalid auth lab port pair')
    lab.inspect_lab()
    count = lab.sql("SELECT count(*) FROM migration_control.applied_migrations WHERE version LIKE 'platform-%';", database=DATABASE).stdout.strip()
    if count != str(len(repository.platform.SOURCE_NAMES)):
        raise RuntimeError("Canonical schema baseline mismatch")
    build = subprocess.run(["cargo", "build", "--bin", "auth-lab", "--features", "http-server", "--locked", "--offline"], cwd=ROOT / "backend", capture_output=True, timeout=300)
    if build.returncode:
        raise RuntimeError("Auth lab build failed; run cargo build for compiler diagnostics")
    # Prefix bảo đảm composition nhưng không tính là entropy; random128bit của fixture vẫn giữ nguyên.
    fixture_password = "Aa1" + secrets.token_hex(16) if verify else getpass.getpass("Chọn mật khẩu TEST mới (9–128 ký tự, có chữ hoa/thường/số0–9; không dùng mật khẩu thật): ")
    validate_fixture_password(fixture_password)
    run_id = uuid4()
    user_ids = [uuid4() for _ in range(5)]
    emails = [f"probe-{run_id}-{index}@example.invalid" for index in range(5)]
    database_password = secrets.token_hex(32)
    signing_key = secrets.token_bytes(32)
    # Capability measurement riêng chỉ dành verify; interactive không có control route hoặc key này.
    measurement_key = secrets.token_bytes(32) if verify else None
    # Gồm email chưa tồn tại để dọn đúng limiter canary, không lưu key hoặc digest vào journal/evidence.
    digest_emails = [*emails, f"probe-{run_id}-unknown@example.invalid"]
    digests = [hmac.new(signing_key, email.encode(), hashlib.sha256).hexdigest() for email in digest_emails]
    journal = ROOT / "ops/auth/ownership" / f"{run_id}.json"
    journal.parent.mkdir(parents=True, exist_ok=True)
    ownership = {"runId": str(run_id), "userIds": list(map(str, user_ids)), "limiterBucketDigests": digests, "purpose": "AUTH_HTTP_LAB", "database": DATABASE}
    # Digest chỉ của email synthetic do run sinh, không phải session digest/secret key; không in vào public evidence.
    journal.write_text(json.dumps(ownership, indent=2), encoding="utf-8")
    server = None
    ack_proxy = None
    processes = []
    fence_holders = list(operation_holders) if operation_holders is not None else []
    clean = False
    checks = []
    concurrency = None
    commit_ack = None
    user_fence = None
    measurements = None
    measurement_baseline = None
    lock_budget = None
    pool_budget = None
    output_captures = []
    output_capture_results = []
    output_capture_failed = False
    request_canaries = None
    request_observer_scope = None
    security_evidence = None
    try:
        provision(database_password, run_id)
        server = bridge.InspectionServer(("127.0.0.1", 0), bridge.InspectionHandler)
        server.allowed_user = ROLE
        server.read_only = False
        threading.Thread(target=server.serve_forever, daemon=True).start()
        if verify:
            # Proxy transparent trong seed/baseline; chỉ arm sau toàn bộ check trước đã kết thúc.
            ack_proxy = CommitAckServer(server.server_address[1])
            ack_proxy.start()
        config = {"databasePort": ack_proxy.server_address[1] if ack_proxy else server.server_address[1], "databasePassword": database_password, "signingKey": list(signing_key), "httpPort": port, "runId": str(run_id), "userIds": list(map(str, user_ids)), "emails": emails, "fixturePassword": fixture_password}
        config.update({'enableMeasurements': verify, 'measurementKey': list(measurement_key) if measurement_key else None})
        if verify:
            from verify_pool_budget import PoolBudgetChild, verify_pool_budget
            # Special pool8 chạy trước primary/peer để role limit16 không bị ba pool cạnh tranh.
            special = start_lab(config, pool_budget=True)
            processes.append(special)
            pool_budget = verify_pool_budget(PoolBudgetChild(special, stop_lab), port, emails,
                                             fixture_password, user_ids, digests, measurement_key, checks)
            # Verifier đã STOPPED+reap; reuse đúng graph seed một lần, không đổi fixture/key/grants.
            config['skipFixtureSeed'] = True
        # Chỉ provider verify cần capture; native fixture bọc start_lab bằng adapter hẹp hơn.
        if verify:
            process = start_lab(config, capture_sink='primary', output_captures=output_captures)
        else:
            process = start_lab(config)
        processes.append(process)
        if verify:
            try:
                # Từ chối đúng quyền SELECT của role fixture để adapter production đi qua nhánh lỗi DB thật.
                set_fixture_session_read_access(run_id, False)
                verify_realtime_sqlx_checkout(server.server_address[1], database_password, checks)
            finally:
                # Phục hồi ACL kể cả khi test compile, query, close hoặc assertion thất bại.
                set_fixture_session_read_access(run_id, True)
            from verify_provider import verify_provider
            from verify_concurrency import verify_concurrency
            from verify_audit_faults import verify_audit_faults
            from verify_commit_ack import verify_commit_ack
            from verify_user_fence import verify_user_fence
            from verify_measurements import verify_measurements
            from verify_measurement_baseline import verify_measurement_baseline
            from verify_lock_budget import verify_lock_budget
            from verify_auth_boundaries import verify_fence_boundaries, verify_limiter_boundary
            from verify_security_evidence import begin_security_bucket_scope, verify_security_evidence, restore_security_buckets
            peer = start_lab({**config, 'httpPort': port + 1, 'skipFixtureSeed': True},
                             capture_sink='peer', output_captures=output_captures)
            processes.append(peer)
            from backend_output_capture import CredentialCanaries
            request_canaries = CredentialCanaries((port, port + 1), (fixture_password, *emails))
            request_observer_scope = request_canaries.observe_requests()
            request_observer_scope.__enter__()
            # Mỗi nhánh security dùng3failure dưới ngưỡng; hoàn trả đúng bucket live-owned trước baseline provider.
            security_scope = begin_security_bucket_scope(emails, user_ids, digests, run_id, signing_key)
            security_evidence = verify_security_evidence(port, emails, fixture_password, user_ids, digests, run_id, measurement_key, checks)
            security_evidence['bucketRestore'] = restore_security_buckets(security_scope)
            checks.extend(verify_provider(
                port, port + 1, emails, fixture_password, run_id, user_ids,
                partial(set_fixture_session_read_access, run_id),
            ))
            # Window chỉ có hai login success account0; kết thúc trước UF/MI/AF, không reset limiter/fixture.
            measurements = verify_measurements(port, port + 1, emails[0], fixture_password, measurement_key, checks)
            # Baseline lặp cần account0/3/4 chưa chịu fault/limiter; mỗi window chỉ có login được đo.
            previous = {window['process']: window['windowId'] for window in measurements['windows']}
            measurement_baseline = verify_measurement_baseline(port, port + 1, emails, fixture_password,
                                                             measurement_key, previous, checks)
            # User lock fault dùng account3 còn ACTIVE/counter0 và nối tiếp generation primary sau M4a.
            primary_generation = max(window['windowId'] for window in measurement_baseline['windows']
                                     if window['process'] == 'primary')
            lock_budget = verify_lock_budget(port, emails, fixture_password, user_ids, digests, run_id,
                                            measurement_key, primary_generation, checks, fence_holders)
            # Sau lock budget, PHC nguồn cho reset còn nguyên; mọi holder mới nhập registry để finally dọn chính xác.
            fence_boundaries = verify_fence_boundaries(port, emails, fixture_password, user_ids, digests, run_id, checks, fence_holders, signing_key)
            user_fence = verify_user_fence(port, emails, fixture_password, user_ids, digests, run_id, checks, fence_holders)
            concurrency = verify_concurrency(port, port + 1, emails, fixture_password, user_ids, checks)
            limiter_boundary = verify_limiter_boundary(port, port + 1, emails, fixture_password, user_ids, digests, signing_key, run_id, checks)
            verify_audit_faults(port, emails[3], fixture_password, user_ids[3], digests[3], run_id, checks)
            commit_ack = verify_commit_ack(port, emails[0], fixture_password, user_ids[0], ack_proxy, checks)
        else:
            print(f"Backend sẵn sàng: http://127.0.0.1:{port}; Web: http://localhost:5173/login")
            for index, label in [(0, "2 workspace (Admin A/User B)"), (1, "disabled"), (2, "bắt buộc đổi password"), (3, "không có workspace")]:
                print(f"{label}: {emails[index]}")
            print("Dùng mật khẩu TEST vừa nhập. Giữ terminal này mở; Ctrl+C để dừng và dọn fixture. Role lab hết hạn sau1giờ.")
            process.wait()
    except KeyboardInterrupt:
        # Verify bị hủy không có evidence đầy đủ; finally vẫn cleanup trước khi main trả exit1 generic.
        if verify:
            raise RuntimeError('Auth verification cancelled') from None
    finally:
        if request_observer_scope is not None:
            request_observer_scope.__exit__(None, None, None)
        stopped = True
        for child in reversed(processes):
            try:
                stop_lab(child)
            except (OSError, subprocess.SubprocessError):
                stopped = False
        if not stopped:
            # Giữ ownership journal và role có expiry nếu child chưa dừng; không xóa graph dưới server sống.
            raise RuntimeError('Auth lab child shutdown unverified; ownership journal retained')
        if verify:
            canaries = request_canaries.values() if request_canaries is not None else ()
            for child, capture in output_captures:
                try:
                    result = capture.finish(child, canaries)
                    output_capture_results.append(result)
                    if any(stream['status'] == 'FAIL' for stream in result['streams']):
                        output_capture_failed = True
                    else:
                        checks.append('backend-output-capture-' + result['process'] + '-terminal')
                except RuntimeError:
                    output_capture_failed = True
                    output_capture_results.append({'process': capture.sink, 'status': 'FAIL'})
            if request_canaries is not None:
                request_canaries.clear()
        # Psql process thoát chưa đủ: từng holder phải đọc metadata xác nhận backend riêng đã biến mất.
        for holder in reversed(fence_holders):
            holder.stop()
        if ack_proxy:
            ack_proxy.stop()
        bridge_closed = close_bridge(server) if server else True
        if repository.owns_probe(run_id):
            try:
                cleanup(run_id, user_ids, digests)
                clean = True
            finally:
                revoke(run_id)
        if not bridge_closed:
            # Child đã dừng nên được phép dọn graph/role, nhưng bridge chưa xác nhận vẫn là cleanup FAIL.
            raise RuntimeError('Auth lab bridge shutdown unverified; ownership journal retained')
        if clean:
            # Anonymous failed-login audit không có actor/session; không được xóa global audit để giả cleanup hoàn toàn.
            # Giữ journal để người vận hành biết scope fixture và audit metadata còn theo retention canonical.
            ownership.update({"applicationFixtureRows": "REMOVED", "anonymousFailureAudit": "MAY_REMAIN_UNTIL_RETENTION"})
            journal.write_text(json.dumps(ownership, indent=2), encoding="utf-8")
        if output_capture_failed:
            raise RuntimeError('Auth lab backend output security scan failed')
    if verify:
        report = {"recordedAt": datetime.now(timezone.utc).isoformat(), "buildId": subprocess.run(["git", "rev-parse", "--short", "HEAD"], cwd=ROOT, capture_output=True, text=True, check=True).stdout.strip() + "-dirty", "database": DATABASE, "checks": checks, "fixtureCleanup": "APPLICATION_ROWS_REMOVED" if clean else "NOT_CONFIRMED", "anonymousFailureAudit": "RETAINED_BY_CANONICAL_POLICY", "ownershipJournal": str(journal.relative_to(ROOT)), "browser": "NOT_RUN", "android": "NOT_RUN", "kind": "real HTTP + PostgreSQL provider, not browser E2E"}
        report['concurrency'] = concurrency
        report['commitAck'] = commit_ack
        report['userFence'] = user_fence
        # Chỉ snapshot enum/numeric đã validate, không đưa config/control key/proof vào report.
        report['measurements'] = measurements
        report['measurementBaseline'] = measurement_baseline
        report['lockBudget'] = lock_budget
        report['poolBudget'] = pool_budget
        report['securityEvidence'] = security_evidence
        report['backendOutputCapture'] = output_capture_results
        report['fenceBoundaries'] = fence_boundaries
        report['limiterBoundary'] = limiter_boundary
        path = ROOT / "ops/auth/evidence/provider-latest.json"
        path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
        print(json.dumps(report, indent=2))


# Đọc đúng một marker lifecycle từ stdout, không đọc hoặc phát tán stderr/config.
def read_ready(process, output):
    """Input: process server do launcher tạo, output list dùng báo ready; không có credential trong marker."""
    output.append(process.stdout.readline().strip())


# Recovery đọc đúng journal ownership trong root đã định; không nhận file ngoài namespace hoặc xóa global bucket.
def recover(journal_path):
    """Input: path journal đã tạo bởi launcher; Side effects: chỉ dọn fixture được marker DB chứng minh sở hữu."""
    journal = Path(journal_path).resolve()
    ownership_root = (ROOT / "ops/auth/ownership").resolve()
    if journal.parent != ownership_root or journal.suffix != ".json":
        raise ValueError("Ownership journal outside the auth lab namespace")
    record = json.loads(journal.read_text(encoding="utf-8"))
    run_id = UUID(record["runId"])
    if journal.stem != str(run_id) or record["purpose"] != "AUTH_HTTP_LAB" or record["database"] != DATABASE or len(record["userIds"]) != 5:
        raise ValueError("Invalid auth lab ownership journal")
    lab.inspect_lab()
    # Role tồn tại có thể thuộc server còn hoạt động; không terminate hay chiếm principal của lượt khác để recovery.
    active_role = lab.sql("SELECT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='iot_repository_probe');", role=lab.ADMIN, database=DATABASE).stdout.strip()
    if active_role != "f":
        raise RuntimeError("Stop the active auth/repository lab before ownership recovery")
    cleanup(run_id, [UUID(value) for value in record["userIds"]], None)
    record.update({"applicationFixtureRows": "REMOVED", "anonymousFailureAudit": "MAY_REMAIN_UNTIL_RETENTION", "limiterBucketCleanup": "NOT_DELETED_RECOVERY_NO_INDEPENDENT_OWNERSHIP"})
    journal.write_text(json.dumps(record, indent=2), encoding="utf-8")
    print("AUTH_LAB_ACCOUNT_FIXTURES_REMOVED; limiter buckets retained, anonymous audit follows canonical retention")


# Entrypoint không tự kết nối ngoài canonical hoặc bật listen LAN.
def main():
    """Parse tùy chọn không secret; Errors: chỉ in lỗi cố định của launcher, không traceback chứa config."""
    parser = argparse.ArgumentParser(description="Local IAM lab, no .env, no database reset")
    parser.add_argument("--verify", action="store_true")
    parser.add_argument("--port", type=int, default=3000)
    parser.add_argument("--cleanup-journal")
    args = parser.parse_args()
    if not 1024 <= args.port <= 65535:
        parser.error("port must be 1024–65535")
    try:
        if args.cleanup_journal:
            if args.verify:
                parser.error("cleanup-journal cannot be combined with verify")
            recover(args.cleanup_journal)
        else:
            run(args.verify, args.port)
    except (RuntimeError, ValueError, KeyError, TypeError, OSError, subprocess.SubprocessError) as error:
        if isinstance(error, RuntimeError) and str(error).startswith((
                "Provider check failed: ", "REALTIME_SQLX_TEST_")):
            print(str(error), file=sys.stderr)
        print("AUTH_LAB_FAILED: check toolchain/container/schema or retained ownership journal; no reset performed.", file=sys.stderr)
        raise SystemExit(1) from None


if __name__ == "__main__":
    main()
