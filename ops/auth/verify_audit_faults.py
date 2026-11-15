"""Fault transaction PostgreSQL thật trên đúng role lab sở hữu, kiểm rollback và luôn khôi phục quyền."""

import secrets
from uuid import UUID

import verify_database as lab
import verify_repositories as repository
from verify_provider import expect, has_error_only_payload, header, request

DATABASE = 'iot_platform_lab'


def set_audit_permission(run_id, enabled):
    """Giảm/khôi phục duy nhất INSERT audit của owned probe, rồi đọc lại privilege.

    Input
    Param: run_id — marker quyền sở hữu launcher, không nhận role name từ client.
    Param: enabled — True khôi phục quyền ban đầu, False gây permission denial thật.
    Errors: không sở hữu role hoặc thay/đọc privilege lỗi thì fail closed, không log SQL/error thô.
    Side effects: thay đúng quyền đã được duyệt; không thay reader/runtime/retention hoặc schema.
    """
    if not repository.owns_probe(run_id):
        raise RuntimeError('Audit fault requires owned probe role')
    # Role/table/lệnh đều literal nội bộ; chỉ khôi phục INSERT đã có, không cấp quyền rộng hơn.
    statement = 'GRANT INSERT ON audit_events TO iot_repository_probe;' if enabled else 'REVOKE INSERT ON audit_events FROM iot_repository_probe;'
    if lab.sql(statement, role=lab.ADMIN, database=DATABASE, check=False).returncode:
        raise RuntimeError('Audit fault permission change failed')
    observed = lab.sql("SELECT has_table_privilege('iot_repository_probe','public.audit_events','INSERT');", role=lab.ADMIN, database=DATABASE, check=False)
    if observed.returncode or observed.stdout.strip() != ('t' if enabled else 'f'):
        raise RuntimeError('Audit fault permission readback failed')


def read_snapshot(user_id, bucket_digest, correlations=()):
    """Đọc count đã commit để không lấy HTTP error làm chứng cứ rollback/counter bền vững.

    Input
    Param: user_id — UUID fixture tổng hợp, được parse lại và truyền psql variable đã quote.
    Param: bucket_digest — đúng HMAC64hex của email fixture, không xuất vào evidence.
    Param: correlations — UUID request lỗi do HTTP trả, chỉ đọc audit của những request đó.
    Output: số session, success audit, failure_count và audit của request lỗi; không trả row/secret.
    Errors: selector/count sai hoặc SQL lỗi được lọc, không diễn giải thành count0.
    """
    identity = str(UUID(str(user_id)))
    if len(bucket_digest) != 64 or any(character not in '0123456789abcdef' for character in bucket_digest):
        raise ValueError('Invalid audit fault fixture digest')
    correlation_ids = ','.join(str(UUID(str(value))) for value in correlations)
    # Value truyền riêng và được psql quote; PostgreSQL cast uuid/bytea/uuid[] trước khi lọc đúng fixture.
    statement = "SELECT (SELECT count(*) FROM sessions WHERE user_id=:'auth_fault_user_id'::uuid),(SELECT count(*) FROM audit_events WHERE actor_user_id=:'auth_fault_user_id'::uuid),coalesce((SELECT failure_count FROM login_attempt_buckets WHERE email_digest=decode(:'auth_fault_bucket_digest','hex')),0),(SELECT count(*) FROM audit_events WHERE correlation_id=ANY(string_to_array(:'auth_fault_correlations',',')::uuid[]));"
    result = lab.sql(statement, role=lab.ADMIN, database=DATABASE, check=False, variables=(('auth_fault_user_id', identity), ('auth_fault_bucket_digest', bucket_digest), ('auth_fault_correlations', correlation_ids)))
    values = result.stdout.strip().split('|')
    if result.returncode or len(values) != 4 or not all(value.isdigit() for value in values):
        raise RuntimeError('Audit fault snapshot read failed')
    return tuple(map(int, values))


def set_transaction_permission(run_id, fault, enabled):
    """Giảm rồi khôi phục đúng privilege đã cấp cho probe thuộc run để gây lỗi DB thực tại auth boundary.

    Input
    Param: run_id — UUID provenance do launcher giữ để đối chiếu owner trước mọi thay quyền.
    Param: fault — session-insert hoặc limiter-update từ allowlist nội bộ cố định.
    Param: enabled — True trả về quyền ban đầu, False thu hồi riêng privilege cần gây fault.
    Errors: ownership, lệnh SQL hoặc privilege readback sai được trả bằng lỗi cố định.
    Side effects: chỉ INSERT sessions hoặc UPDATE login_attempt_buckets của iot_repository_probe thay đổi; limiter giữ subset email_digest để khóa row.
    """
    if not repository.owns_probe(run_id):
        raise RuntimeError('Transaction fault requires owned probe role')
    table, privilege = {'session-insert': ('sessions', 'INSERT'),
                        'limiter-update': ('login_attempt_buckets', 'UPDATE')}[fault]
    # Table/privilege đều literal allowlist, không nhận identifier từ HTTP hoặc thêm grant ngoài provision gốc.
    statement = ('GRANT ' + privilege + ' ON ' + table + ' TO iot_repository_probe;' if enabled else
                 'REVOKE ' + privilege + ' ON ' + table + ' FROM iot_repository_probe;')
    readback = "SELECT has_table_privilege('iot_repository_probe','public." + table + "','" + privilege + "');"
    expected = 't' if enabled else 'f'
    if fault == 'limiter-update':
        # SELECT FOR UPDATE cần UPDATE ít nhất một column. Giữ email_digest để fault xảy ra ở save_login_window,
        # còn hai column thực ghi counter/window đều bị cấm. Subset tạm được revoke trước khi trả table grant gốc.
        statement = ('BEGIN; REVOKE UPDATE (email_digest) ON login_attempt_buckets FROM iot_repository_probe; '
                     'GRANT UPDATE ON login_attempt_buckets TO iot_repository_probe; COMMIT;' if enabled else
                     'BEGIN; REVOKE UPDATE ON login_attempt_buckets FROM iot_repository_probe; '
                     'GRANT UPDATE (email_digest) ON login_attempt_buckets TO iot_repository_probe; COMMIT;')
        readback = "SELECT has_table_privilege('iot_repository_probe','public.login_attempt_buckets','UPDATE'),has_column_privilege('iot_repository_probe','public.login_attempt_buckets','email_digest','UPDATE'),has_column_privilege('iot_repository_probe','public.login_attempt_buckets','failure_count','UPDATE'),has_column_privilege('iot_repository_probe','public.login_attempt_buckets','window_started_at','UPDATE');"
        expected = 't|t|t|t' if enabled else 'f|t|f|f'
    if lab.sql(statement, role=lab.ADMIN, database=DATABASE, check=False).returncode:
        raise RuntimeError('Transaction fault permission change failed')
    observed = lab.sql(readback, role=lab.ADMIN, database=DATABASE, check=False)
    if observed.returncode or observed.stdout.strip() != expected:
        raise RuntimeError('Transaction fault permission readback failed')


def verify_transaction_faults(port, email, password, user_id, bucket_digest, run_id, checks):
    """Kiểm session insert và limiter permission fail503 trước commit, rồi đối soát state và restore từng fault.

    Input
    Param: port — primary loopback đang do launcher sở hữu, không có request concurrent trong fault window.
    Param: email — account3 fixture ACTIVE còn password seed hợp lệ và counter0.
    Param: password — credential synthetic chỉ giữ trong RAM cho session-insert control intent.
    Param: user_id — UUID account fixture dùng snapshot SQL đã quote.
    Param: bucket_digest — HMAC limiter fixture dùng binding64hex có allowlist sẵn.
    Param: run_id — marker probe phải khớp trước revoke và restore.
    Param: checks — chỉ chứa check ID tĩnh để evidence không lẫn dữ liệu auth.
    Errors: status/envelope/header hoặc committed state sai làm fail closed, finally luôn trả privilege về ban đầu.
    Side effects: thu hồi tạm từng privilege probe rồi restore ngay; request lỗi không được commit session/audit/counter.
    """
    for fault in ('session-insert', 'limiter-update'):
        before = read_snapshot(user_id, bucket_digest)
        correlations = []
        try:
            set_transaction_permission(run_id, fault, False)
            checks.append(fault + '-fault-permission-denial-confirmed')
            candidate = password if fault == 'session-insert' else 'Aa1' + secrets.token_hex(32)
            for client in ('WEB', 'ANDROID', 'IOS'):
                status, headers, body = request(port, 'POST', '/auth/login',
                                                {'email': email, 'password': candidate, 'clientType': client},
                                                {'Origin': 'http://localhost:5173'} if client == 'WEB' else None)
                expect(status == 503 and has_error_only_payload(body, 'SERVICE_UNAVAILABLE'),
                       fault + '-fault-' + client.lower() + '-safe-unavailable', checks)
                expect(header(headers, 'cache-control') == 'no-store'
                       and all(header(headers, name) is None for name in ('set-cookie', 'x-auth-context-id', 'x-csrf-token', 'retry-after')),
                       fault + '-fault-' + client.lower() + '-no-credential', checks)
                correlations.append(UUID(body['error']['correlationId']))
            after = read_snapshot(user_id, bucket_digest, correlations)
            expect(after[:3] == before[:3] and after[3] == 0,
                   fault + '-fault-session-audit-counter-unchanged', checks)
        finally:
            set_transaction_permission(run_id, fault, True)
        checks.append(fault + '-fault-permission-restored')


def verify_audit_faults(port, email, password, user_id, bucket_digest, run_id, checks):
    """Kiểm required audit rollback và failed-auth exception xuyên HTTP→core→PostgreSQL thật.

    Input
    Param: port — loopback listener primary do launcher sở hữu.
    Param: email — account3 synthetic chưa có failed attempt trong baseline.
    Param: password — credential seed TEST giữ trong RAM, không log hoặc lưu file.
    Param: user_id — identity fixture để đọc committed session/audit count.
    Param: bucket_digest — HMAC của email fixture từ cùng signing key trong RAM launcher.
    Param: run_id — ownership marker cần đúng trước mỗi lần đổi quyền.
    Param: checks — chỉ nhận invariant ID tĩnh, không chứa body hoặc selector SQL.
    Errors: bất kỳ invariant sai đều fail; finally khôi phục quyền ngay cả check thất bại.
    Side effects: sáu intent lỗi session/limiter, năm failed attempts audit và giảm/restore từng privilege probe.
    """
    verify_transaction_faults(port, email, password, user_id, bucket_digest, run_id, checks)
    before = read_snapshot(user_id, bucket_digest)
    expect(before[2] == 0, 'audit-fault-fresh-fixture-bucket', checks)
    correlations = []
    try:
        set_audit_permission(run_id, False)
        for client, label in [('WEB', 'web'), ('ANDROID', 'android')]:
            status, headers, body = request(port, 'POST', '/auth/login', {'email': email, 'password': password, 'clientType': client}, {'Origin': 'http://localhost:5173'} if client == 'WEB' else None)
            expect(status == 503 and body['error']['code'] == 'SERVICE_UNAVAILABLE', 'audit-fault-' + label + '-unavailable', checks)
            expect(set(body) == {'error'} and all(header(headers, name) is None for name in ('set-cookie', 'x-auth-context-id', 'x-csrf-token')) and header(headers, 'cache-control') == 'no-store', 'audit-fault-' + label + '-no-credential', checks)
            correlations.append(UUID(body['error']['correlationId']))
        after_success = read_snapshot(user_id, bucket_digest, correlations)
        expect(after_success[:3] == before[:3] and after_success[3] == 0, 'audit-fault-required-session-audit-rollback', checks)
        wrong_password = 'Aa1' + secrets.token_hex(32)
        for attempt in range(5):
            status, headers, body = request(port, 'POST', '/auth/login', {'email': email, 'password': wrong_password, 'clientType': 'ANDROID'})
            expect(status == 401 and body['error']['code'] == 'AUTH_INVALID' and not header(headers, 'set-cookie'), 'audit-fault-denied-attempt-' + str(attempt + 1), checks)
            correlations.append(UUID(body['error']['correlationId']))
        after_failure = read_snapshot(user_id, bucket_digest, correlations)
        expect(after_failure[2] == 5, 'audit-fault-counter-committed', checks)
        expect(after_failure[:2] == before[:2] and after_failure[3] == 0, 'audit-fault-denials-no-session-or-audit', checks)
        status, headers, body = request(port, 'POST', '/auth/login', {'email': email, 'password': wrong_password, 'clientType': 'ANDROID'})
        retry_after = header(headers, 'retry-after')
        expect(status == 429 and body['error']['code'] == 'RATE_LIMITED' and retry_after is not None and retry_after.isdigit() and int(retry_after) > 0 and not header(headers, 'set-cookie'), 'audit-fault-rate-limit-retained', checks)
    finally:
        set_audit_permission(run_id, True)
    checks.append('audit-fault-permission-restored')
