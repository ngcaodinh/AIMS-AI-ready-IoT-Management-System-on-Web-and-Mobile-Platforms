"""Kiểm User fence và fixed-window qua provider thật, chỉ xuất check ID/boolean."""

from concurrent.futures import ThreadPoolExecutor
import hashlib
import hmac
import http.client
import json
import re
import subprocess
import threading
import time
from uuid import UUID

import verify_database as lab
import verify_repositories as repository
from user_fence_holder import (DATABASE, OBSERVE_TIMEOUT, STARTUP_TIMEOUT, UserFenceHolder,
                               inspect_owned_lab, metadata_count, owned_predicate, remaining)
from verify_provider import expect, has_error_only_payload, has_login_projection, header, read_persisted_session, request
from verify_user_fence import assert_denial_state, login_request, read_snapshot, validate_denial


def bucket_variables(run_id, user_id, email, signing_key, digest):
    """Chứng minh key RAM, email synthetic và UUID thuộc cùng launcher trước mọi bucket mutation.

    Input
    Param: run_id — UUID marker owner đang chạy.
    Param: user_id — UUID fixture do launcher giữ.
    Param: email — canonical email account4 trong lượt chạy.
    Param: signing_key — HMAC key chỉ trong RAM, không ghi SQL/log/file.
    Param: digest — HMAC bucket cần thao tác, không nhận từ journal.
    Output: tuple biến psql đã kiểm identity và digest; Errors: ValueError nếu selector sai.
    """
    run = str(UUID(str(run_id)))
    identity = str(UUID(str(user_id)))
    if (not isinstance(signing_key, bytes) or len(signing_key) != 32
            or email != f'probe-{run}-4@example.invalid'
            or not isinstance(digest, str) or not re.fullmatch('[0-9a-f]{64}', digest)
            or not hmac.compare_digest(hmac.new(signing_key, email.encode(), hashlib.sha256).hexdigest(), digest)):
        raise ValueError('Invalid boundary bucket selector')
    return (('auth_fault_user_id', identity), ('auth_fault_bucket_digest', digest))


def read_window(variables):
    """Đọc counter và thời điểm nguyên vẹn trong RAM để phát hiện429 gia hạn dù HTTP đúng.

    Input
    Param: variables — UUID/digest đã chứng minh bằng key RAM trước khi gọi.
    Output: counter và timestamp text nội bộ, không đưa vào report.
    Errors: query/output sai không được chuyển thành bucket rỗng.
    """
    # Chỉ đọc đúng HMAC bucket, dữ liệu psql quote riêng không đi vào SQL text.
    result = lab.sql("SELECT failure_count,coalesce(window_started_at::text,'EMPTY') FROM login_attempt_buckets WHERE email_digest=decode(:'auth_fault_bucket_digest','hex');",
                     role=lab.ADMIN, database=DATABASE, check=False, variables=variables)
    values = result.stdout.strip().split('|')
    if result.returncode or len(values) != 2 or not values[0].isdigit() or not values[1]:
        raise RuntimeError('Boundary bucket snapshot unavailable')
    return int(values[0]), values[1]


def position_owned_window(run_id, email, variables, age_seconds):
    """Backdate duy nhất bucket owned đủ5failure tới cuối cửa sổ hoặc mốc expiry.

    Input
    Param: run_id — marker role và email run cần khớp trước mutation.
    Param: email — canonical account4 đã chứng minh với HMAC key RAM.
    Param: variables — UUID/digest đã validate, psql quote trước cast.
    Param: age_seconds — chỉ899giây để kiểm Retry-After1 hoặc900giây để kiểm expiry.
    Errors: thiếu ownership, sai target/provenance/counter hoặc SQL lỗi đều FAIL.
    Side effects: chỉ thay window_started_at của đúng một bucket synthetic, không đổi clock toàn cục.
    """
    if (type(age_seconds) is not int or age_seconds not in (899, 900)
            or not repository.owns_probe(run_id) or email != f'probe-{UUID(str(run_id))}-4@example.invalid'):
        raise RuntimeError('Boundary bucket ownership mismatch')
    predicate = owned_predicate('target', run_id)
    # UPDATE khóa cùng bucket như provider; chỉ row có User/provenance đúng và5failure được backdate.
    statement = f"""BEGIN;
SET LOCAL lock_timeout='2s'; SET LOCAL statement_timeout='2s';
UPDATE login_attempt_buckets SET window_started_at=clock_timestamp()-interval '{age_seconds} seconds'
WHERE email_digest=decode(:'auth_fault_bucket_digest','hex') AND failure_count=5
AND EXISTS(SELECT 1 FROM users target WHERE target.user_id=:'auth_fault_user_id'::uuid
AND {predicate} AND target.email_normalized='probe-{UUID(str(run_id))}-4@example.invalid'
AND target.account_status='ACTIVE' AND NOT target.must_change_password)
RETURNING CASE WHEN failure_count=5 AND window_started_at IS NOT NULL THEN 1 ELSE 0 END;
COMMIT;"""
    result = lab.sql(statement, role=lab.ADMIN, database=DATABASE, check=False, variables=variables)
    if result.returncode or result.stdout.split() != ['1']:
        raise RuntimeError('Boundary bucket position unverified')


def assert_limited(response, checks, prefix):
    """Đòi429 generic, no-store, Retry-After hữu hạn và không credential trước khi kiểm DB.

    Input
    Param: response — response bounded chỉ trong RAM.
    Param: checks — danh sách check ID tĩnh.
    Param: prefix — nhãn scenario literal, không lấy từ payload.
    Output: Retry-After nguyên để so thứ tự request; Errors: RuntimeError không chứa body/header.
    """
    status, headers, body = response
    retry = header(headers, 'retry-after')
    expect(status == 429 and has_error_only_payload(body, 'RATE_LIMITED')
           and header(headers, 'cache-control') == 'no-store'
           and all(header(headers, name) is None for name in ('set-cookie', 'x-auth-context-id', 'x-csrf-token'))
           and isinstance(retry, str) and retry.isdigit() and 1 <= int(retry) <= 900,
           prefix + '-safe-limited', checks)
    return int(retry)


def alternate_source_login(port, email, password):
    """Đổi địa chỉ socket loopback thật để kiểm key email không phụ thuộc IP client tự khai.

    Input
    Param: port — listener loopback owned primary.
    Param: email — email synthetic account4 đã đủ ngưỡng.
    Param: password — seed đúng chỉ trong RAM.
    Output: response bounded từ source127.0.0.2, không follow redirect hoặc log auth.
    Errors: bind/HTTP/JSON lỗi phải FAIL, không thay bằng X-Forwarded-For.
    """
    connection = http.client.HTTPConnection('127.0.0.1', port, timeout=20, source_address=('127.0.0.2', 0))
    try:
        connection.request('POST', '/api/v1/auth/login', json.dumps({'email': email, 'password': password, 'clientType': 'IOS'}), {'Content-Type': 'application/json'})
        response = connection.getresponse()
        payload = response.read(131073)
        if len(payload) > 131072:
            raise RuntimeError('Boundary response exceeds budget')
        return response.status, dict(response.getheaders()), json.loads(payload)
    finally:
        connection.close()


def verify_limiter_boundary(port, peer_port, emails, password, user_ids, digests, signing_key, run_id, checks):
    """Kiểm password đúng/IP/client/instance và nonextension trên bucket5failure do concurrency tạo.

    Input
    Param: port — primary loopback owned.
    Param: peer_port — process peer dùng cùng DB/key.
    Param: emails —5email synthetic của launcher.
    Param: password — seed đúng của account4, chỉ ở RAM.
    Param: user_ids —5UUID fixture của launcher.
    Param: digests — HMAC fixture tương ứng, không xuất report.
    Param: signing_key — key HMAC RAM để chứng minh bucket mutation.
    Param: run_id — UUID ownership được xác minh trước backdate.
    Param: checks — ID invariant tĩnh nối report provider.
    Output: metadata scope cố định; exact900s do domain unit test, HTTP expiry ở sau mốc DB.
    Side effects: backdate riêng owned bucket4 rồi cấp một phiên bằng password đúng sau expiry.
    """
    variables = bucket_variables(run_id, user_ids[4], emails[4], signing_key, digests[4])
    before = read_window(variables)
    state = read_snapshot(user_ids[4], digests[4], 'ANDROID')
    expect(before[0] == 5 and before[1] != 'EMPTY', 'limiter-boundary-five-committed', checks)
    previous_retry = 900
    for target, client in ((port, 'WEB'), (peer_port, 'ANDROID')):
        retry = assert_limited(login_request(target, emails[4], password, client), checks, 'limiter-correct-' + client.lower())
        expect(retry <= previous_retry and read_window(variables) == before, 'limiter-correct-' + client.lower() + '-window-not-extended', checks)
        previous_retry = retry
    retry = assert_limited(alternate_source_login(port, emails[4], password), checks, 'limiter-correct-alternate-ip-ios')
    expect(retry <= previous_retry and read_window(variables) == before, 'limiter-alternate-ip-window-not-extended', checks)
    expect(read_snapshot(user_ids[4], digests[4], 'ANDROID')[:3] == state[:3], 'limiter-correct-denials-no-session-audit-counter-change', checks)
    position_owned_window(run_id, emails[4], variables, 899)
    near_end = read_window(variables)
    last_retry = assert_limited(login_request(port, emails[4], password, 'ANDROID'), checks, 'limiter-last-second-correct-password')
    expect(last_retry == 1 and read_window(variables) == near_end, 'limiter-last-second-retry-one-window-not-extended', checks)
    position_owned_window(run_id, emails[4], variables, 900)
    checks.append('limiter-owned-bucket-expired-by-db-clock')
    status, headers, body = login_request(peer_port, emails[4], password, 'ANDROID')
    expect(status == 200 and has_login_projection(body, headers, 'ANDROID', emails[4], user_ids[4], False), 'limiter-expired-correct-password-verified', checks)
    read_persisted_session(body['token'], user_ids[4], 'ANDROID', False, body['expiresAt'])
    expect(read_window(variables) == (0, 'EMPTY'), 'limiter-expired-success-clears-only-expired-window', checks)
    return {'correctPasswordAtThreshold': True, 'alternateLoopbackSource': True,
            'blockedRequestsPreserveWindow': True, 'lastSecondRetryOne': True, 'expiredOwnedBucketSuccess': True,
            'exactExpiryBoundary': 'DOMAIN_UNIT_TEST_REQUIRED', 'clockScope': 'owned bucket DB timestamp only'}


class SessionInsertFence(UserFenceHolder):
    """Giữ SHARE sessions chỉ trong canonical verifier độc quyền để dừng INSERT sau verify."""

    def start(self):
        """Lấy table fence trước login, READY chỉ sau lock thật và không giữ User fence.

        Errors: ownership/container/timeout/marker sai giữ object trong registry để cleanup.
        Side effects: sessions INSERT chờ tối đa harness window, không có production fault hook.
        """
        deadline = time.monotonic() + STARTUP_TIMEOUT
        statement = f"SELECT count(*) FROM pg_roles WHERE rolname='iot_repository_probe' AND shobj_description(oid,'pg_authid')='Temporary canonical repository verification:{self.run_id}';"
        if self.process is not None or metadata_count(statement, remaining(deadline, 'startup')) != 1:
            raise RuntimeError('Session fence ownership mismatch')
        inspect_owned_lab(deadline)
        connection = f'dbname={DATABASE} application_name={self.application_name} connect_timeout=3'
        self.process = subprocess.Popen(
            ['docker', 'exec', '-i', lab.CONTAINER, 'psql', '-X', '-qAtw', '-v', 'ON_ERROR_STOP=1', '-h', '/tmp', '-U', lab.ADMIN, '-d', connection],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            text=True, encoding='utf-8', creationflags=subprocess.CREATE_NO_WINDOW)
        self.reader = threading.Thread(target=self.collect_lines, daemon=True)
        self.reader.start()
        # SHARE không tương thích ROW EXCLUSIVE của INSERT; User lock của login vẫn giữ xuyên crypto.
        self.send("SET statement_timeout='2s'; SET lock_timeout='2s'; SET idle_in_transaction_session_timeout='10s'; BEGIN; LOCK TABLE sessions IN SHARE MODE; SELECT 'FENCE_READY|'||pg_backend_pid();")
        self.pid = self.read_marker('FENCE_READY', remaining(deadline, 'startup'))


def wait_for_mutation_blocked(application_name, session_holder_pid):
    """Đòi chain mutation→login→sessions holder thật trước khi nhả INSERT, không dùng sleep làm proof.

    Input
    Param: application_name — tên UUID riêng của mutation holder đã đăng ký ownership.
    Param: session_holder_pid — PID đọc từ READY của đúng sessions holder.
    Errors: không thấy một chain cô lập trong3giây thì FAIL.
    """
    if not re.fullmatch(r'iot_auth_fence_[0-9a-f]{32}', application_name) or type(session_holder_pid) is not int or session_holder_pid <= 0:
        raise ValueError('Invalid mutation wait selector')
    deadline = time.monotonic() + OBSERVE_TIMEOUT
    # Chỉ metadata PID/role/application_name, không đọc query text có thể chứa credential.
    statement = f"SELECT count(*) FROM pg_stat_activity mutation JOIN pg_stat_activity login ON login.pid=ANY(pg_blocking_pids(mutation.pid)) WHERE mutation.application_name='{application_name}' AND mutation.usename='{lab.ADMIN}' AND login.usename='iot_repository_probe' AND login.datname='{DATABASE}' AND {session_holder_pid}=ANY(pg_blocking_pids(login.pid));"
    while time.monotonic() < deadline:
        count = metadata_count(statement, min(2.0, remaining(deadline, 'mutation wait')))
        remaining(deadline, 'mutation wait')
        if count == 1:
            return
        if count > 1:
            raise RuntimeError('Boundary mutation wait is not isolated')
        time.sleep(min(.025, max(0, deadline - time.monotonic())))
    raise RuntimeError('Boundary mutation wait not observed')


class ResetUserFence(UserFenceHolder):
    """Dùng cùng User fence để kiểm transition PHC/mustChangePassword của reset protocol."""

    def commit(self, kind):
        """Commit reset atomic dưới User lock hoặc dùng transition password/status hiện hữu.

        Input
        Param: kind — password/status/reset literal của harness.
        Errors: reset không đổi đúng target/source hoặc marker commit sai thì FAIL.
        Side effects: trigger canonical revoke các phiên trong cùng transaction reset.
        """
        if kind != 'reset':
            return super().commit(kind)
        target = owned_predicate('target', self.run_id)
        source = owned_predicate('source', self.run_id)
        # PHC không rời PostgreSQL; transition giống repository reset, không giả đã chạy FEAT004 authorization/quota.
        self.send(f"UPDATE users target SET password_hash=source.password_hash,must_change_password=true FROM users source WHERE target.user_id='{self.target_id}'::uuid AND source.user_id='{self.changed_source_id}'::uuid AND {target} AND {source} AND target.password_hash<>source.password_hash AND NOT target.must_change_password RETURNING 'FENCE_CHANGED';\nCOMMIT;\n\\echo FENCE_COMMITTED")
        deadline = time.monotonic() + STARTUP_TIMEOUT
        self.read_marker('FENCE_CHANGED', remaining(deadline, 'commit'))
        self.read_marker('FENCE_COMMITTED', remaining(deadline, 'commit'))


def restore_fixture(run_id, target_id, source_id, status='ACTIVE'):
    """Khôi phục PHC/status/mustChangePassword đúng fixture không membership, không sửa limiter.

    Input
    Param: run_id — UUID owner dùng provenance DB.
    Param: target_id — UUID account1/2/3 cần phục hồi trong run.
    Param: source_id — UUID fixture còn PHC mong muốn, chỉ copy trong PostgreSQL.
    Param: status — ACTIVE hoặc DISABLED literal của fixture.
    Errors: sai owner/row count/query phải FAIL và giữ cleanup registry.
    """
    target, source = str(UUID(str(target_id))), str(UUID(str(source_id)))
    if status not in ('ACTIVE', 'DISABLED') or target == source or not repository.owns_probe(run_id):
        raise RuntimeError('Boundary fixture ownership mismatch')
    # Không có membership nên không can thiệp last-Admin invariant; provenance/UUID giới hạn đúng graph.
    statement = f"UPDATE users target SET password_hash=source.password_hash,account_status='{status}',must_change_password=false FROM users source WHERE target.user_id=:'auth_fault_user_id'::uuid AND source.user_id=:'auth_fault_correlations'::uuid AND {owned_predicate('target', run_id)} AND {owned_predicate('source', run_id)} AND NOT EXISTS(SELECT 1 FROM memberships WHERE user_id=target.user_id) RETURNING 1;"
    result = lab.sql(statement, role=lab.ADMIN, database=DATABASE, check=False,
                     variables=(('auth_fault_user_id', target), ('auth_fault_correlations', source)))
    if result.returncode or result.stdout.split() != ['1']:
        raise RuntimeError('Boundary fixture restore unverified')


def verify_login_first(port, emails, password, user_ids, run_id, checks, holders, kind, client):
    """Dừng login tại sessions INSERT sau crypto rồi cho mutation chờ User và revoke sau login commit.

    Input
    Param: port — primary loopback độc quyền trong table fence window.
    Param: emails — fixture email, target account3 không membership/counter0.
    Param: password — seed password chỉ ở RAM.
    Param: user_ids — target3/source2 PHC khác seed/seed4.
    Param: run_id — UUID owner của graph.
    Param: checks — invariant ID tĩnh.
    Param: holders — registry parent giữ trước mọi start để cleanup cả startup lỗi.
    Param: kind — password/status/reset literal.
    Param: client — WEB hoặc ANDROID.
    Output: boolean observation, không session ID/token/PHC.
    """
    prefix = 'user-fence-login-first-' + kind + '-' + client.lower()
    restore_fixture(run_id, user_ids[3], user_ids[4])
    insert_fence = SessionInsertFence(run_id, user_ids[3], user_ids[2])
    mutation = ResetUserFence(run_id, user_ids[3], user_ids[2])
    holders.extend((insert_fence, mutation))
    try:
        insert_fence.start()
        with ThreadPoolExecutor(max_workers=2) as workers:
            login = workers.submit(login_request, port, emails[3], password, client)
            try:
                insert_fence.wait_for_blocked()
                waiting_mutation = workers.submit(mutation.start)
                try:
                    wait_for_mutation_blocked(mutation.application_name, insert_fence.pid)
                    expect(not login.done() and not waiting_mutation.done(), prefix + '-after-verify-actual-lock-chain', checks)
                finally:
                    insert_fence.stop()
                response = login.result(timeout=21)
                waiting_mutation.result(timeout=6)
                status, headers, body = response
                expect(status == 200 and has_login_projection(body, headers, client, emails[3], user_ids[3], False), prefix + '-login-committed', checks)
                token = header(headers, 'set-cookie').split(';', 1)[0].split('=', 1)[1] if client == 'WEB' else body['token']
                session_id = read_persisted_session(token, user_ids[3], client, False, body['expiresAt'])
                mutation.commit(kind)
                # Exact issued session row chỉ được đọc trạng thái, không token/digest/PHC.
                statement = f"SELECT count(*) FROM sessions WHERE session_id='{UUID(str(session_id))}'::uuid AND user_id='{UUID(str(user_ids[3]))}'::uuid AND revoked_at IS NOT NULL;"
                expect(metadata_count(statement) == 1, prefix + '-issued-session-revoked-after-mutation', checks)
                proof = {'Cookie': header(headers, 'set-cookie').split(';', 1)[0], 'X-Auth-Context-Id': header(headers, 'x-auth-context-id')} if client == 'WEB' else {'Authorization': 'Bearer ' + token}
                denied, denied_headers, denied_body = request(port, 'GET', '/me', headers=proof)
                # Password/reset để tài khoản active nên known revoke có mã riêng; disabled vẫn giữ denial tổng quát.
                expected_error = 'SESSION_EXPIRED' if kind == 'status' else 'SESSION_REVOKED'
                expect(denied == 401 and has_error_only_payload(denied_body, expected_error)
                       and header(denied_headers, 'cache-control') == 'no-store', prefix + '-old-session-unusable', checks)
            finally:
                insert_fence.stop()
                mutation.stop()
        return {'kind': kind, 'clientType': client, 'afterVerifyInsertWait': True, 'mutationWaitsForUser': True, 'oldSessionRevoked': True}
    finally:
        insert_fence.stop()
        mutation.stop()
        restore_fixture(run_id, user_ids[3], user_ids[4])


def restore_reset_probe_window(run_id, user_id, email, digest, signing_key, baseline):
    """Hoàn trả riêng hai attempt reset probe để không làm saturation che status-fence verifier kế tiếp.

    Input
    Param: run_id/user_id/email/digest/signing_key — selector UUID và HMAC được chứng minh từ key live của cùng fixture.
    Param: baseline — count/timestamp đã đọc trước probe, không nhận dữ liệu journal hoặc client.
    Errors: ownership/HMAC/timestamp/count delta khác2 thì dừng trước UPDATE, không reset brute-force state ngoài test.
    Side effects: chỉ failure_count của đúng bucket account2 được trả baseline, timestamp và anonymous audit giữ nguyên.
    """
    run = str(UUID(str(run_id)))
    identity = str(UUID(str(user_id)))
    if (email != f'probe-{run}-2@example.invalid' or type(signing_key) is not bytes or len(signing_key) != 32
            or not re.fullmatch('[0-9a-f]{64}', digest)
            or not hmac.compare_digest(hmac.new(signing_key, email.encode(), hashlib.sha256).hexdigest(), digest)
            or not repository.owns_probe(run) or type(baseline) is not tuple
            or type(baseline[0]) is not int or not 0 <= baseline[0] <= 2 or baseline[1] == 'EMPTY'):
        raise RuntimeError('Reset probe bucket ownership rejected')
    variables = (('auth_fault_user_id', identity), ('auth_fault_bucket_digest', digest))
    if read_window(variables) != (baseline[0] + 2, baseline[1]):
        raise RuntimeError('Reset probe bucket delta rejected')
    # Timestamp không đổi và chỉ UPDATE count đúng baseline+2 trong graph owned. Role và User provenance được kiểm lại trong transaction.
    predicate = owned_predicate('target', run)
    statement = f"""BEGIN;
    UPDATE login_attempt_buckets SET failure_count={baseline[0]}
    WHERE email_digest=decode(:'auth_fault_bucket_digest','hex') AND failure_count={baseline[0] + 2}
      AND window_started_at IS NOT NULL AND EXISTS(SELECT 1 FROM users target
      WHERE target.user_id=:'auth_fault_user_id'::uuid AND {predicate}
      AND target.email_normalized='probe-{run}-2@example.invalid') RETURNING 1;
    COMMIT;"""
    result = lab.sql(statement, role=lab.ADMIN, database=DATABASE, check=False, variables=variables)
    if result.returncode or result.stdout.strip() != '1' or read_window(variables) != baseline:
        raise RuntimeError('Reset probe bucket restore unconfirmed')


def verify_fence_boundaries(port, emails, password, user_ids, digests, run_id, checks, holders, signing_key):
    """Kiểm reverse order cả ba mutation và reset-first trước verifier User fence hiện hữu.

    Input
    Param: port — primary do launcher sở hữu, không có traffic khác trong SHARE table fence.
    Param: emails —5email fixture theo thứ tự launcher.
    Param: password — seed credential RAM, không argv/file/log.
    Param: user_ids —5UUID, account2 vẫn giữ PHC khác seed sau baseline provider.
    Param: digests — HMAC fixture chỉ phục vụ snapshot counter, không sửa counter.
    Param: run_id — marker ownership role/graph.
    Param: checks — danh sách check ID tĩnh cho evidence.
    Param: holders — registry parent được drain trước cleanup graph.
    Param: signing_key — key RAM để chứng minh bucket account2 khi hoàn trả hai attempt riêng của reset probe.
    Output: actual lock observations, reset protocol scope được ghi rõ.
    Side effects: account2 thêm2failure, giữ PHC khác seed cho password race kế tiếp; account3 giữ counter0.
    """
    variables = (('auth_fault_user_id', str(UUID(str(user_ids[2])))), ('auth_fault_bucket_digest', digests[2]))
    baseline_window = read_window(variables)
    observations = []
    for kind in ('password', 'status', 'reset'):
        for client in ('WEB', 'ANDROID'):
            observations.append(verify_login_first(port, emails, password, user_ids, run_id, checks, holders, kind, client))
    # Giữ PHC khác seed trong account1 khi dùng account2 cho reset-first; PHC luôn ở DB.
    restore_fixture(run_id, user_ids[1], user_ids[2])
    try:
        for client in ('WEB', 'ANDROID'):
            prefix = 'user-fence-reset-first-' + client.lower()
            restore_fixture(run_id, user_ids[2], user_ids[4])
            before = read_snapshot(user_ids[2], digests[2], client)
            expect(before[2] < 5, prefix + '-below-limiter', checks)
            holder = ResetUserFence(run_id, user_ids[2], user_ids[1])
            holders.append(holder)
            try:
                holder.start()
                with ThreadPoolExecutor(max_workers=1) as workers:
                    pending = workers.submit(login_request, port, emails[2], password, client)
                    try:
                        holder.wait_for_blocked()
                        expect(not pending.done(), prefix + '-actual-user-wait', checks)
                        holder.commit('reset')
                    finally:
                        holder.stop()
                    correlation = validate_denial(pending.result(timeout=21), checks, prefix)
                assert_denial_state(before, read_snapshot(user_ids[2], digests[2], client, correlation), checks, prefix)
                observations.append({'kind': 'reset', 'clientType': client, 'mutationFirst': True, 'waitBeforeUserRead': True})
            finally:
                holder.stop()
    finally:
        # Account2 PHC đổi từ baseline phải còn cho password race hiện hữu chạy sau lát cắt này.
        restore_fixture(run_id, user_ids[2], user_ids[1])
        restore_fixture(run_id, user_ids[1], user_ids[4], 'DISABLED')
    restore_reset_probe_window(run_id, user_ids[2], emails[2], digests[2], signing_key, baseline_window)
    checks.append('user-fence-reset-probe-restores-exact-owned-bucket-baseline')
    return {'observations': observations, 'resetScope': 'atomic PHC/mustChangePassword/User-fence protocol, FEAT004 authorization/quota not exercised',
            'mutationFirstPause': 'before User read and crypto, User lock spans verification through commit',
            'loginFirstPause': 'session INSERT after successful crypto, mutation blocked on same User'}
