"""Đối soát SEC002/003/009/014 có cận, chỉ giữ credential/canary và audit row trong RAM."""

import json
import hashlib
import hmac
import re
import secrets
import time
from urllib.parse import quote
from uuid import UUID

from verify_measurements import STAGES, begin_window, measurement_control, validate_snapshot
from verify_provider import expect, has_error_only_payload, header, read_persisted_session, request

# Cận tương đương response đo hiện hành, không đọc file log tùy ý hoặc thư mục dependency.
MAX_SINK_BYTES = 1_048_576
SINK_ROLES = ('backend_stdout', 'backend_stderr', 'structured_log', 'audit', 'metric',
              'evidence', 'browser_debug', 'app_debug')
SENSITIVE_FIELD = re.compile(
    r'''(?i)(?<![\w-])["']?(authorization|cookie|set-cookie|password|token|email)["']?\s*[:=]\s*''')
REDACTED_VALUE = re.compile(r'''(?i)^(?:["'](?:\[redacted\]|<redacted>|\*\*\*)["']|null)(?=\s*[,}\]\r\n]|$)''')
# Denial commit limiter rồi audit qua transaction khác, thêm đúng pool/begin/commit ngoài chín stage login.
DENIAL_STAGE_COUNTS = {stage: 2 if stage in ('pool_acquire', 'transaction_begin', 'commit_ack') else 1
                       for stage in STAGES}


def scan_sink(role, payload, canaries):
    """Scan bytes quan sát thật bằng tên field và canary, không trả payload hay fragment tìm được.

    Input
    Param: role — tên sink literal để report không chứa đường dẫn hoặc dữ liệu client.
    Param: payload — bytes chỉ trong RAM, None khi sink chưa được thu thập.
    Param: canaries — tuple giá trị auth/email thật của fixture cùng run, không lưu ra file.
    Output: enum/count, NOT_RUN khi thiếu/trống, FAIL khi có field raw hoặc canary.
    Errors: dữ liệu vượt1MiB, role sai hoặc canary ngoài cận làm lỗi generic.
    """
    if (role not in SINK_ROLES or payload is not None and type(payload) is not bytes
            or payload is not None and len(payload) > MAX_SINK_BYTES
            or type(canaries) is not tuple or len(canaries) > 64
            or any(type(value) is not str or not 8 <= len(value) <= 4096 for value in canaries)):
        raise RuntimeError('Invalid security sink input')
    if not payload:
        return {'sink': role, 'status': 'NOT_RUN', 'byteCount': 0,
                'canaryCount': len(canaries), 'canaryMatches': 0, 'namedFieldMatches': 0}
    text = payload.decode('utf-8', errors='replace')
    variants = set()
    for value in canaries:
        variants.update((value, quote(value, safe=''), json.dumps(value)[1:-1]))
    canary_matches = sum(text.count(value) for value in variants)
    # Debug output có thể serialize một JSON message hai lần, nên tên field escaped vẫn phải scan.
    normalized = text.replace('\\"', '"').replace("\\'", "'")
    named_matches = sum(not REDACTED_VALUE.match(normalized[match.end():])
                        for match in SENSITIVE_FIELD.finditer(normalized))
    return {'sink': role, 'status': 'FAIL' if canary_matches or named_matches else 'PASS',
            'byteCount': len(payload), 'canaryCount': len(canaries),
            'canaryMatches': canary_matches, 'namedFieldMatches': named_matches}


def denial_hash_work(snapshot, generation):
    """Đòi snapshot đủ login cùng transaction failure-audit rồi lấy một hash work để phát hiện skip verify.

    Input
    Param: snapshot — window riêng chỉ chứa một login denial, không có traffic đồng thời.
    Param: generation — window ID đã nhận từ begin, không lấy từ end.
    Output: microsecond hash work dương, chỉ số kỹ thuật không là SLO hoặc ngưỡng timing equality.
    """
    validate_snapshot(snapshot, generation, 1, DENIAL_STAGE_COUNTS)
    elapsed = next(sample['elapsedUs'] for sample in snapshot['samples'] if sample['stage'] == 'hash_work')
    if elapsed == 0:
        raise RuntimeError('Missing completed password verification work')
    return elapsed


def read_denial_audit(correlations):
    """Tra toàn bộ audit row theo correlation denial của run để scan nội dung, không chỉ count.

    Input
    Param: correlations — chín UUID HTTP của ba nhánh, parse typed trước SQL và không ghi raw row vào report.
    Output: bytes JSON bounded của đủ event vô danh cùng ANDROID/outcome/reason đúng.
    Errors: SQL/schema/count/identity sai làm lỗi generic, không phản chiếu stderr hoặc row.
    """
    import verify_database as lab
    values = tuple(str(UUID(str(value))) for value in correlations)
    if len(values) != 9 or len(set(values)) != 9:
        raise RuntimeError('Invalid security audit selectors')
    # UUID đã parse được nối thành literal typed, không chứa canary/credential và không mở thêm psql binding.
    selectors = ','.join("'" + value + "'::uuid" for value in values)
    # SELECT toàn row đúng UUID; LIMIT10 phát hiện duplicate và cap payload trước trả cho Python.
    statement = """SELECT CASE WHEN octet_length(payload::text)<=1048576 THEN payload::text ELSE 'AUDIT_SCAN_BUDGET_EXCEEDED' END
      FROM (SELECT coalesce(jsonb_agg(to_jsonb(owned)),'[]'::jsonb) payload FROM
      (SELECT * FROM audit_events WHERE correlation_id=ANY(ARRAY[""" + selectors + "]) LIMIT 10) owned) bounded;"
    result = lab.sql(statement, role=lab.ADMIN, database='iot_platform_lab', check=False)
    try:
        payload = result.stdout.strip().encode('utf-8')
        rows = json.loads(payload) if result.returncode == 0 and len(payload) <= MAX_SINK_BYTES else None
        valid = (type(rows) is list and len(rows) == 9
                 and {row['correlation_id'] for row in rows} == set(values)
                 and all(row['event_type'] == 'LOGIN_FAILED' and row['outcome'] == 'FAILURE'
                         and row['reason_code'] == 'INVALID_CREDENTIALS' and row['client_type'] == 'ANDROID'
                         and all(row[field] is None for field in ('workspace_id', 'actor_user_id', 'session_id'))
                         for row in rows))
        if valid:
            return payload
    except (ValueError, TypeError, KeyError, AttributeError):
        pass
    raise RuntimeError('Security audit lookup failed')


def verify_export_control_failure(port, key, email, password, user_id, checks):
    """Quan sát export control bị từ chối sau login đã commit, rồi đối soát lại cùng session.

    Input
    Param: port — child lab loopback đã READY, không có traffic khác trong window.
    Param: key — capability đo trong RAM của process.
    Param: email — account ACTIVE full thuộc fixture.
    Param: password — credential fixture nguyên bản, không ghi ra report.
    Param: user_id — UUID account dùng đối soát profile và row session durable.
    Param: checks — chỉ append ID invariant tĩnh.
    Output: report scope control failure và snapshot, không khẳng định remote exporter outage.
    """
    generation = begin_window(port, key)
    status, headers, body = request(port, 'POST', '/auth/login',
                                    {'email': email, 'password': password, 'clientType': 'ANDROID'})
    expect(status == 200 and type(body) is dict and type(body.get('token')) is str
           and bool(body['token']) and body.get('limited') is False and not header(headers, 'set-cookie'),
           'security-export-login-issued', checks)
    token = body['token']
    session_id = read_persisted_session(token, user_id, 'ANDROID', False, body['expiresAt'])
    bearer = {'Authorization': 'Bearer ' + token}
    # Đóng window chỉ chứa login trước GET profile, vì GET có transaction riêng và không thuộc chín stage login.
    snapshot = validate_snapshot(measurement_control(port, 'end', key), generation, 1)
    status, _, profile = request(port, 'GET', '/me', headers=bearer)
    expect(status == 200 and profile.get('id') == str(user_id), 'security-export-session-before', checks)
    # Window đã đóng nên end thứ hai phải bị control từ chối, sau khi response/session success đã quan sát.
    rejection = measurement_control(port, 'end', key, expected_status=409)
    expect(rejection == {'error': 'MEASUREMENT_CONTROL_REJECTED'}, 'security-export-control-rejected', checks)
    status, _, profile = request(port, 'GET', '/me', headers=bearer)
    after = read_persisted_session(token, user_id, 'ANDROID', False, body['expiresAt'])
    expect(status == 200 and profile.get('id') == str(user_id) and after == session_id,
           'security-export-rejection-preserves-committed-session', checks)
    report = {'scope': 'rejected measurement export control', 'snapshot': snapshot,
              'committedSessionUsableBefore': True, 'committedSessionUsableAfter': True}
    report['successAuditScan'] = scan_sink('audit', read_success_audit(session_id),
                                          (token, password, email))
    expect(report['successAuditScan']['status'] == 'PASS', 'security-success-audit-scan', checks)
    report['evidenceScan'] = scan_sink('evidence', json.dumps(report).encode('utf-8'),
                                       (token, password, email))
    expect(report['evidenceScan']['status'] == 'PASS', 'security-export-evidence-scan', checks)
    return report


def read_success_audit(session_id):
    """Đọc nguyên row success audit của session vừa cấp để kiểm token/password trên nhánh thành công.

    Input
    Param: session_id — UUID durable do read_persisted_session vừa đối soát, không nhận từ input mạng.
    Output: JSON row chỉ trong RAM; Errors: thiếu/duplicate/outcome sai hoặc vượt cận làm lỗi generic.
    """
    import verify_database as lab
    identity = str(UUID(str(session_id)))
    # Selector UUID bind từ session durable và LIMIT2 giúp phát hiện duplicate mà không quét audit global.
    statement = """SELECT CASE WHEN octet_length(payload::text)<=1048576 THEN payload::text ELSE 'AUDIT_SCAN_BUDGET_EXCEEDED' END
      FROM (SELECT coalesce(jsonb_agg(to_jsonb(owned)),'[]'::jsonb) payload FROM
      (SELECT * FROM audit_events WHERE session_id=:'auth_fault_user_id'::uuid AND event_type='LOGIN_SUCCEEDED' LIMIT 2) owned) bounded;"""
    result = lab.sql(statement, role=lab.ADMIN, database='iot_platform_lab', check=False,
                     variables=(('auth_fault_user_id', identity),))
    try:
        payload = result.stdout.strip().encode('utf-8')
        rows = json.loads(payload) if result.returncode == 0 and len(payload) <= MAX_SINK_BYTES else None
        if (type(rows) is list and len(rows) == 1 and rows[0]['session_id'] == identity
                and rows[0]['event_type'] == 'LOGIN_SUCCEEDED' and rows[0]['outcome'] == 'SUCCESS'
                and rows[0]['client_type'] == 'ANDROID'):
            return payload
    except (ValueError, TypeError, KeyError, AttributeError):
        pass
    raise RuntimeError('Security success audit lookup failed')


def begin_security_bucket_scope(emails, user_ids, digests, run_id, signing_key):
    """Chứng minh ownership/key live và chụp ba bucket trước denial để không reset limiter ngoài fixture.

    Input
    Param: emails — năm email đúng namespace seed của run, chỉ giữ RAM.
    Param: user_ids — năm UUID fixture, hai identity đầu phải có trạng thái ACTIVE/DISABLED đã seed.
    Param: digests — sáu HMAC đã giữ bởi launcher, phải trùng tính lại từ signing_key và email.
    Param: run_id — UUID marker dùng kiểm provenance ở DB trước khi traffic bắt đầu.
    Param: signing_key — key live32byte trong RAM, không nhận từ journal/file/env.
    Output: scope RAM chứa selector đã chứng minh và baseline hàng0 của account0 do seed_workspaces tạo.
    Errors: owner, PHC policy, key hoặc baseline khác mong đợi làm fail trước mutation.
    """
    import verify_database as lab
    import verify_repositories as repository
    marker = str(UUID(str(run_id)))
    identities = tuple(str(UUID(str(value))) for value in user_ids)
    expected_emails = [f'probe-{marker}-{index}@example.invalid' for index in range(5)]
    if (len(identities) != 5 or list(emails) != expected_emails or len(digests) != 6
            or type(signing_key) is not bytes or len(signing_key) != 32):
        raise RuntimeError('Invalid security bucket ownership')
    owned_emails = [*emails, f'probe-{marker}-unknown@example.invalid']
    calculated = tuple(hmac.new(signing_key, email.encode(), hashlib.sha256).hexdigest() for email in owned_emails)
    if any(type(actual) is not str or not re.fullmatch('[0-9a-f]{64}', actual) or not hmac.compare_digest(actual, expected)
           for actual, expected in zip(digests, calculated)):
        raise RuntimeError('Invalid security bucket ownership')
    if not repository.owns_probe(marker):
        raise RuntimeError('Security live role ownership rejected')
    selected = (calculated[0], calculated[1], calculated[5])
    # Hai UUID/marker đã parse và status/policy là literal, không lấy raw verifier/email ra khỏi DB.
    predicate = "activation_provenance='AUTH_HTTP_LAB:" + marker + "' AND split_part(password_hash,'$',2)='argon2id' AND split_part(password_hash,'$',3)='v=19' AND split_part(password_hash,'$',4)='m=19456,t=2,p=1' AND ("
    predicate += "(user_id='" + identities[0] + "'::uuid AND account_status='ACTIVE' AND email_normalized='probe-" + marker + "-0@example.invalid') OR "
    predicate += "(user_id='" + identities[1] + "'::uuid AND account_status='DISABLED' AND email_normalized='probe-" + marker + "-1@example.invalid'))"
    selectors = ','.join("decode('" + value + "','hex')" for value in selected)
    statement = "SELECT (SELECT count(*) FROM users WHERE " + predicate + "),coalesce(jsonb_agg(jsonb_build_object('key',encode(email_digest,'hex'),'failures',failure_count,'started',window_started_at)),'[]'::jsonb) FROM login_attempt_buckets WHERE email_digest IN (" + selectors + ");"
    result = lab.sql(statement, role=lab.ADMIN, database='iot_platform_lab', check=False)
    try:
        count, payload = result.stdout.strip().split('|', 1)
        rows = json.loads(payload)
        expected = [{'key': selected[0], 'failures': 0, 'started': None}]
        if result.returncode == 0 and count == '2' and rows == expected:
            return {'digests': selected, 'ownerPredicate': predicate, 'runId': marker}
    except (ValueError, TypeError, AttributeError):
        pass
    raise RuntimeError('Security bucket baseline or ownership rejected')


def restore_security_buckets(scope):
    """Khôi phục đúng baseline limiter của probe sau khi chín request đã terminal, giữ anonymous audit theo retention.

    Input
    Param: scope — dữ liệu RAM từ begin_security_bucket_scope của cùng launcher độc quyền DB.
    Side effects: khóa bucket→User, giữ account0 hàng0 đã seed và chỉ xóa hai hàng được probe tạo.
    Errors: mỗi bucket phải đúng3 failure còn window, ownership phải còn đúng; sai thì rollback toàn bộ.
    """
    import verify_database as lab
    import verify_repositories as repository
    if not repository.owns_probe(scope['runId']):
        raise RuntimeError('Security live role ownership rejected')
    selected = scope['digests']
    predicate = scope['ownerPredicate']
    selectors = ','.join("decode('" + value + "','hex')" for value in selected)
    created = ','.join("decode('" + value + "','hex')" for value in selected[1:])
    # Scope chỉ sinh trong RAM từ guard; khóa bucket→User như auth và kiểm count3 trước mọi reset/delete.
    statement = """BEGIN;
      DO $$ BEGIN
      PERFORM email_digest FROM login_attempt_buckets WHERE email_digest IN (""" + selectors + """) ORDER BY email_digest FOR UPDATE;
      PERFORM user_id FROM users WHERE """ + predicate + """ ORDER BY user_id FOR UPDATE;
      IF (SELECT count(*) FROM users WHERE """ + predicate + """ )<>2 THEN RAISE EXCEPTION 'Owned security users changed'; END IF;
      IF (SELECT count(*) FROM login_attempt_buckets WHERE email_digest IN (""" + selectors + """) AND failure_count=3 AND window_started_at IS NOT NULL)<>3
      THEN RAISE EXCEPTION 'Owned security buckets changed'; END IF;
      UPDATE login_attempt_buckets SET failure_count=0,window_started_at=NULL WHERE email_digest=decode('""" + selected[0] + """','hex');
      DELETE FROM login_attempt_buckets WHERE email_digest IN (""" + created + """);
      END $$;
      SELECT (SELECT count(*) FROM login_attempt_buckets WHERE email_digest IN (""" + selectors + """)),
        (SELECT count(*) FROM login_attempt_buckets WHERE email_digest=decode('""" + selected[0] + """','hex') AND failure_count=0 AND window_started_at IS NULL);
      COMMIT;"""
    result = lab.sql(statement, role=lab.ADMIN, database='iot_platform_lab', check=False)
    if result.returncode or result.stdout.strip() != '1|1':
        raise RuntimeError('Security bucket restore not confirmed')
    return {'restoredSeedBucketCount': 1, 'removedCreatedBucketCount': 2, 'anonymousAudit': 'RETAINED'}


def verify_security_evidence(port, emails, password, user_ids, digests, run_id, measurement_key, checks):
    """Chạy denial cùng input dưới threshold và scan audit/metric/evidence trong fixture độc quyền của launcher.

    Input
    Param: port — process có PasswordService và diagnostics thật, chỉ caller này phát traffic.
    Param: emails — năm email canonical của fixture mới, index0 ACTIVE và index1 DISABLED.
    Param: password — mật khẩu seed chỉ trong RAM, dùng tạo input sai cùng policy cho cả ba nhánh.
    Param: user_ids — UUID do launcher sở hữu, index0 cho success-control.
    Param: digests — HMAC live từ signing key cùng run cho năm email rồi unknown, dùng caller dọn bucket.
    Param: run_id — UUID namespace đã seed, chặn email trỏ account ngoài fixture.
    Param: measurement_key — capability recorder riêng, không serialize.
    Param: checks — danh sách invariant tĩnh không-secret.
    Output: evidence enum/numeric cùng UUID correlation lookup, không chứa canary/password/token/email.
    Side effects: mỗi key ba failure đã commit; caller phải restore bucket sở hữu trước provider tests cũ.
    """
    marker = str(UUID(str(run_id)))
    if (len(emails) != 5 or len(user_ids) != 5 or len(digests) != 6
            or list(emails) != [f'probe-{marker}-{index}@example.invalid' for index in range(5)]):
        raise RuntimeError('Invalid security fixture scope')
    wrong_password = 'Aa1' + secrets.token_hex(16)
    while wrong_password == password:
        wrong_password = 'Aa1' + secrets.token_hex(16)
    unknown = f'probe-{marker}-unknown@example.invalid'
    canaries = tuple([password, wrong_password, *emails, unknown])
    cases = (('wrong', emails[0]), ('unknown', unknown), ('disabled', emails[1]))
    observations = []
    correlations = []
    projection = None
    # Ba round xen kẽ thứ tự giảm lệch warmup, vẫn dưới threshold5 của từng key mới.
    for round_number in range(3):
        for label, email in cases[round_number:] + cases[:round_number]:
            generation = begin_window(port, measurement_key)
            started = time.monotonic_ns()
            status, headers, body = request(port, 'POST', '/auth/login',
                                            {'email': email, 'password': wrong_password, 'clientType': 'ANDROID'})
            elapsed_us = (time.monotonic_ns() - started) // 1000
            expect(status == 401 and has_error_only_payload(body, 'AUTH_INVALID')
                   and header(headers, 'cache-control') == 'no-store'
                   and all(header(headers, name) is None for name in ('set-cookie', 'x-auth-context-id', 'x-csrf-token')),
                   'security-' + label + '-exact-denial', checks)
            public = {name: value for name, value in body['error'].items() if name != 'correlationId'}
            if projection is None:
                projection = public
            expect(public == projection, 'security-denials-equivalent-projection', checks)
            correlations.append(body['error']['correlationId'])
            snapshot = measurement_control(port, 'end', measurement_key)
            work_us = denial_hash_work(snapshot, generation)
            observations.append({'branch': label, 'round': round_number + 1,
                                 'httpElapsedUs': elapsed_us, 'hashWorkUs': work_us, 'snapshot': snapshot})
    audit_bytes = read_denial_audit(correlations)
    metric_bytes = json.dumps(observations).encode('utf-8')
    report = {'kind': 'bounded actual password-verification observations',
              'sameInput': True, 'sameClient': 'ANDROID', 'samplesPerBranch': 3,
              'correlationIds': correlations, 'auditOutcomeLookups': 9, 'observations': observations}
    report['exportControlFailure'] = verify_export_control_failure(
        port, measurement_key, emails[0], password, user_ids[0], checks)
    report['missingSinks'] = ['structured_log', 'browser_debug', 'app_debug']
    scans = [scan_sink('audit', audit_bytes, canaries), scan_sink('metric', metric_bytes, canaries),
             scan_sink('evidence', json.dumps(report).encode('utf-8'), canaries)]
    expect(all(result['status'] == 'PASS' for result in scans), 'security-runtime-sink-scans', checks)
    report['sinkScans'] = scans
    return report
