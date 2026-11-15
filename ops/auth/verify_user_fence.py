"""Kiểm disabled và password/status race qua HTTP thật, không dùng production fault hook."""

from concurrent.futures import ThreadPoolExecutor
from uuid import UUID

import verify_database as lab
from user_fence_holder import UserFenceHolder, metadata_count, set_fixture_state
from verify_provider import expect, header, request


def read_snapshot(user_id, bucket_digest, client, correlation=None):
    """Đọc count committed và failure event đúng request mà không xuất identity/credential.

    Input
    Param: user_id — UUID target fixture từ launcher, quote qua psql variable.
    Param: bucket_digest — HMAC64hex của đúng email target, chỉ giữ RAM.
    Param: client — WEB/ANDROID literal, không nhận SQL từ response.
    Param: correlation — UUID response để kiểm anonymous LOGIN_FAILED, None khi baseline.
    Output: session count, success audit count, failure_count, exact failure audit count.
    Errors: selector/output/SQL sai không được chuyển thành count0.
    """
    identity = str(UUID(str(user_id)))
    if len(bucket_digest) != 64 or any(character not in '0123456789abcdef' for character in bucket_digest):
        raise ValueError('Invalid User fence bucket selector')
    predicate = {'WEB': "client_type='WEB'", 'ANDROID': "client_type='ANDROID'"}[client]
    correlation_value = str(UUID(str(correlation))) if correlation is not None else ''
    # Failure audit vô danh; chỉ exact correlation/client/outcome mới là bằng chứng request bị từ chối.
    statement = "SELECT (SELECT count(*) FROM sessions WHERE user_id=:'auth_fault_user_id'::uuid),(SELECT count(*) FROM audit_events WHERE actor_user_id=:'auth_fault_user_id'::uuid AND event_type='LOGIN_SUCCEEDED'),coalesce((SELECT failure_count FROM login_attempt_buckets WHERE email_digest=decode(:'auth_fault_bucket_digest','hex')),0),(SELECT count(*) FROM audit_events WHERE correlation_id=ANY(string_to_array(:'auth_fault_correlations',',')::uuid[]) AND event_type='LOGIN_FAILED' AND outcome='FAILURE' AND reason_code='INVALID_CREDENTIALS' AND actor_user_id IS NULL AND session_id IS NULL AND workspace_id IS NULL AND " + predicate + ');'
    result = lab.sql(statement, role=lab.ADMIN, database='iot_platform_lab', check=False,
                     variables=(('auth_fault_user_id', identity), ('auth_fault_bucket_digest', bucket_digest), ('auth_fault_correlations', correlation_value)))
    values = result.stdout.strip().split('|')
    if result.returncode or len(values) != 4 or not all(value.isdigit() for value in values):
        raise RuntimeError('User fence snapshot unavailable')
    return tuple(map(int, values))


def validate_denial(response, checks, prefix):
    """Đòi401 generic an toàn trước khi dùng correlation để đối soát DB.

    Input
    Param: response — status/headers/body trong RAM, không log giá trị auth.
    Param: checks — nơi ghi check ID tĩnh cho report.
    Param: prefix — nhãn ca literal do harness chọn, không nhận từ người dùng.
    Output: UUID correlation đã kiểm kiểu; 429/503 không được thay denial dưới User fence.
    """
    status, headers, body = response
    error = body.get('error') if isinstance(body, dict) else None
    expect(status == 401 and isinstance(error, dict) and error.get('code') == 'AUTH_INVALID', prefix + '-invalid', checks)
    safe_error = set(body) == {'error'} and set(error) <= {'code', 'message', 'details', 'correlationId'} and error.get('details', {}) == {} and error.get('message') == 'Thông tin đăng nhập không hợp lệ.'
    expect(safe_error and header(headers, 'cache-control') == 'no-store' and all(header(headers, name) is None for name in ('set-cookie', 'x-auth-context-id', 'x-csrf-token')), prefix + '-no-credential', checks)
    try:
        return UUID(error['correlationId'])
    except (KeyError, ValueError, TypeError, AttributeError):
        raise RuntimeError('Provider check failed: ' + prefix + '-correlation') from None


def assert_denial_state(before, after, checks, prefix):
    """Đòi counter+1/exact anonymous audit và không phát session dưới denial.

    Input
    Param: before — count committed ngay trước request, sau control login/mutation setup.
    Param: after — snapshot đúng target/request/client sau response.
    Param: checks — danh sách invariant tĩnh, không ghi count hoặc identity nhạy cảm.
    Param: prefix — nhãn ca nội bộ dùng truy dấu failure.
    """
    expect(after[:2] == before[:2], prefix + '-no-issued-session', checks)
    expect(after[2] == before[2] + 1 and after[3] == 1, prefix + '-counter-and-audit', checks)


def login_request(port, email, password, client):
    """Gửi một login tổng hợp đúng client, không retry dù kết quả UNKNOWN.

    Input
    Param: port — listener loopback của launcher.
    Param: email — identity fixture, không log.
    Param: password — credential TEST trong RAM.
    Param: client — WEB/ANDROID literal quyết định Origin và credential channel.
    Output: response trong RAM cho control/denial oracle.
    """
    return request(port, 'POST', '/auth/login', {'email': email, 'password': password, 'clientType': client},
                   {'Origin': 'http://localhost:5173'} if client == 'WEB' else None)


def verify_race(port, emails, password, user_ids, digests, run_id, checks, holders, kind, client):
    """Giữ User lock, quan sát waiter thật rồi commit mutation trước khi login đọc trạng thái mới.

    Input
    Param: port — listener primary của launcher, không có HTTP khác trong window này.
    Param: emails — năm email synthetic theo thứ tự fixture.
    Param: password — seed password TEST, chỉ dùng RAM.
    Param: user_ids — UUID fixture để giữ target1/password hoặc target2/status.
    Param: digests — HMAC bucket của đúng target từ key còn trong RAM launcher.
    Param: run_id — marker sở hữu role/fixture.
    Param: checks — danh sách ID invariant an toàn cho evidence.
    Param: holders — registry launcher, append trước start để không mất child khi startup lỗi.
    Param: kind — password/status literal; password chạy trước khi target2 PHC được phục hồi seed.
    Param: client — WEB/ANDROID literal, một request race duy nhất mỗi case.
    Output: metadata loại ca/client/actual wait; không credential/PID/identity.
    Side effects: mutate target fixture, tạo control session rồi revoke bởi trigger khi PHC/status đổi.
    """
    index = {'password': 1, 'status': 2}[kind]
    prefix = 'user-fence-' + kind + '-' + client.lower()
    set_fixture_state(run_id, user_ids[index], user_ids[4], 'ACTIVE')
    status, headers, body = login_request(port, emails[index], password, client)
    credential = header(headers, 'set-cookie') if client == 'WEB' else body.get('token')
    expect(status == 200 and body.get('me', {}).get('id') == str(user_ids[index]) and body.get('limited') is False and bool(credential), prefix + '-control', checks)
    before = read_snapshot(user_ids[index], digests[index], client)
    expect(before[2] < 5, prefix + '-below-limiter', checks)
    holder = UserFenceHolder(run_id, user_ids[index], user_ids[2])
    holders.append(holder)
    try:
        holder.start()
        with ThreadPoolExecutor(max_workers=1) as workers:
            pending = workers.submit(login_request, port, emails[index], password, client)
            try:
                holder.wait_for_blocked()
                expect(not pending.done(), prefix + '-actual-wait', checks)
                holder.commit(kind)
            finally:
                # Nhả/đóng holder trước khi join HTTP; lỗi wait không được treo request dưới khóa cũ.
                holder.stop()
            response = pending.result(timeout=21)
        # Chỉ boolean hash/status được đọc; verifier không rời PostgreSQL hoặc xuất evidence.
        target = str(UUID(str(user_ids[index])))
        source = str(UUID(str(user_ids[2] if kind == 'password' else user_ids[4])))
        condition = "target.account_status='ACTIVE'" if kind == 'password' else "target.account_status='DISABLED'"
        statement = f"SELECT count(*) FROM users target,users source WHERE target.user_id='{target}'::uuid AND source.user_id='{source}'::uuid AND target.password_hash=source.password_hash AND {condition};"
        expect(metadata_count(statement) == 1, prefix + '-mutation-committed', checks)
        correlation = validate_denial(response, checks, prefix)
        after = read_snapshot(user_ids[index], digests[index], client, correlation)
        assert_denial_state(before, after, checks, prefix)
        return {'kind': kind, 'clientType': client, 'waitObserved': True, 'mutationCommitted': True}
    finally:
        holder.stop()


def verify_user_fence(port, emails, password, user_ids, digests, run_id, checks, holders):
    """Kiểm bốn race và hai disabled request trên cùng5fixture, không reset limiter.

    Input
    Param: port — listener primary của launcher.
    Param: emails —5email fixture theo thứ tự full/disabled/limited/empty/owner.
    Param: password — credential seed tổng hợp trong RAM, không file/env/log.
    Param: user_ids — UUID5accounts được launcher sinh và giữ ownership.
    Param: digests — HMAC bucket tương ứng, chỉ giữ RAM.
    Param: run_id — marker role/fixture đang sở hữu.
    Param: checks — danh sách check ID tĩnh nối baseline provider.
    Param: holders — registry do launcher giữ qua toàn bộ finally cleanup.
    Output: bốn quan sát race và hai nhãn disabled; không phải browser/App E2E.
    Errors: không bỏ qua limiter, wait/SQL/HTTP/cleanup failure; launcher giữ journal khi không dọn được.
    """
    observations = []
    try:
        for client in ('WEB', 'ANDROID'):
            observations.append(verify_race(port, emails, password, user_ids, digests, run_id, checks, holders, 'password', client))
        # Điều kiện401 phải do DISABLED với password đúng, không do PHC còn từ password race.
        set_fixture_state(run_id, user_ids[1], user_ids[4], 'DISABLED')
        for client in ('WEB', 'ANDROID'):
            prefix = 'disabled-' + client.lower()
            before = read_snapshot(user_ids[1], digests[1], client)
            correlation = validate_denial(login_request(port, emails[1], password, client), checks, prefix)
            assert_denial_state(before, read_snapshot(user_ids[1], digests[1], client, correlation), checks, prefix)
            observations.append({'kind': 'disabled', 'clientType': client})
        for client in ('WEB', 'ANDROID'):
            observations.append(verify_race(port, emails, password, user_ids, digests, run_id, checks, holders, 'status', client))
    finally:
        # Tất cả holder phải chứng minh backend gone trước mọi fixture restore, kể cả khi assertion lỗi.
        for holder in reversed(holders):
            holder.stop()
        set_fixture_state(run_id, user_ids[1], user_ids[4], 'DISABLED')
        set_fixture_state(run_id, user_ids[2], user_ids[4], 'ACTIVE')
    return observations
