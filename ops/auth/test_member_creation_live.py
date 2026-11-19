"""Kiểm tạo thành viên, rollback, bảo mật audit, lời mời và sửa với revision cũ qua HTTP và PostgreSQL."""

from concurrent.futures import ThreadPoolExecutor
from contextlib import ExitStack
from datetime import datetime, timezone
import json
from operator import itemgetter
import re
from threading import Barrier
from uuid import UUID

from test_member_list_live import check_pages, fixture_actor, owned_workspace, require
from test_member_patch_live import changed, denied, fixture_sql, patch, snapshot
from verify_measurements import begin_window, measurement_control
from verify_provider import has_error_only_payload, header, request
from verify_security_evidence import scan_sink


# Chỉ trả mã lỗi assertion cố định vì response thành công chứa bí mật dùng một lần.
def create(port, actor, email, gate=None):
    """Gửi một POST từ actor trong workspace tương ứng, đồng bộ trước gửi khi kiểm race."""
    workspace, credentials = actor
    if gate is not None:
        gate.wait(timeout=10)
    status, metadata, body = request(port, 'POST', '/users',
                                     {'email': email, 'displayName': '  A\u0301nh  ', 'role': 'USER'},
                                     {**credentials, 'X-Workspace-Id': workspace})
    require(header(metadata, 'cache-control') == 'no-store' and isinstance(body, dict),
            'MEMBER_CREATE_RESPONSE')
    return status, body


# So hai kết quả như tập có số lần xuất hiện để không phụ thuộc thread nào thắng.
def race(port, actors, email):
    """Cho hai client gửi POST cùng email qua hai kết nối riêng, giữ association với actor ban đầu."""
    gate = Barrier(2)
    with ThreadPoolExecutor(max_workers=2) as pool:
        attempts = [pool.submit(create, port, actor, email, gate) for actor in actors]
        return [attempt.result(timeout=30) for attempt in attempts]


# So toàn bộ payload gồm metadata để phát hiện lặp lại giá trị secret dưới tên field khác.
def check_conflict(reply, code, secrets):
    """Kiểm đúng 409/envelope/code của lần gửi lại và bảo đảm response không chứa secret đã cấp."""
    status, body = reply
    require(status == 409 and set(body) == {'error'} and isinstance(body['error'], dict)
            and set(body['error']) == {'code', 'message', 'details', 'correlationId'}
            and body['error']['code'] == code, 'MEMBER_CREATE_CONFLICT_' + code)
    contents = json.dumps(body, ensure_ascii=False)
    require('"temporaryPassword"' not in contents and '"invitationToken"' not in contents
            and all(secret not in contents for secret in secrets), 'MEMBER_CREATE_SECRET_REPLAY')


# Chỉ fixture dùng chuỗi secret làm canary trong RAM đến khi kết thúc, không đưa vào report.
def check_created(reply, workspace, email, secrets):
    """Kiểm DTO/alias NFC và mật khẩu mới của 201, trả UUID account cho oracle DB độc lập."""
    status, body = reply
    require(status == 201 and set(body) == {'membership', 'temporaryPassword'}, 'MEMBER_CREATE_201')
    row = body['membership']
    require(isinstance(row, dict) and set(row) == {'workspaceId', 'userId', 'email', 'alias',
            'role', 'status', 'authzVersion', 'revision'} and row['workspaceId'] == workspace
            and row['email'] == email and row['alias'] == 'Ánh' and row['role'] == 'USER'
            and row['status'] == 'ACTIVE' and type(row['revision']) is int and row['revision'] >= 1
            and type(row['authzVersion']) is int and row['authzVersion'] >= 1
            and str(UUID(row['userId'])) == row['userId'], 'MEMBER_CREATE_PROJECTION')
    secret = body['temporaryPassword']
    require(isinstance(secret, str) and 9 <= len(secret) <= 128 and any(c.isupper() for c in secret)
            and any(c.islower() for c in secret) and any(c in '0123456789' for c in secret)
            and secret not in secrets, 'MEMBER_CREATE_TEMPORARY_PASSWORD')
    secrets.append(secret)
    return row['userId']


# TTL đủ 24 giờ được kiểm từ issued_at và expires_at dưới DB, tránh dựa đồng hồ client.
def check_invited(reply, workspace, secrets):
    """Kiểm DTO và token base64url của 202, trả ID và thời hạn để đối chiếu bản ghi invitation."""
    status, body = reply
    require(status == 202 and set(body) == {'invitation', 'invitationToken'}, 'MEMBER_CREATE_202')
    row = body['invitation']
    require(isinstance(row, dict) and set(row) == {'workspaceId', 'id', 'role', 'expiresAt'}
            and row['workspaceId'] == workspace and row['role'] == 'USER'
            and str(UUID(row['id'])) == row['id'], 'MEMBER_CREATE_INVITATION_PROJECTION')
    expiry = datetime.fromisoformat(row['expiresAt'])
    require(expiry.utcoffset() is not None and expiry > datetime.now(timezone.utc),
            'MEMBER_CREATE_INVITATION_EXPIRY')
    secret = body['invitationToken']
    require(isinstance(secret, str) and re.fullmatch(r'[A-Za-z0-9_-]{43}', secret)
            and secret not in secrets, 'MEMBER_CREATE_INVITATION_TOKEN')
    secrets.append(secret)
    return row['id'], expiry


# Chỉ đọc projection của đúng email do fixture sinh, không lấy password hash, token hoặc digest.
def check_persistence(database, run_id, case, account, joined, invited=None, invitation=None):
    """Đếm account, membership và invitation thực sau commit, đối chiếu workspace và resource ID."""
    require(case in ('sequence', 'same', 'cross'), 'MEMBER_CREATE_TEST_CASE')
    # Giá trị UUID bind bằng psql, suffix chỉ lấy từ enum ba ca trên.
    sql = f"""
    WITH target AS (SELECT 'probe-' || :'auth_fault_user_id' || '-{case}@example.invalid' AS email),
    accounts AS (SELECT user_id FROM users JOIN target ON email_normalized=target.email)
    SELECT json_build_object(
      'accounts', ARRAY(SELECT user_id FROM accounts),
      'memberships', ARRAY(SELECT workspace_id FROM memberships JOIN accounts USING(user_id)),
      'invitations', COALESCE((SELECT json_agg(json_build_array(workspace_id, invitation_id, expires_at,
        (expires_at-issued_at=interval '24 hours' AND used_at IS NULL AND revoked_at IS NULL AND expired_at IS NULL)))
        FROM workspace_invitations JOIN target ON email_normalized=target.email), '[]'::json));
    """
    actual = json.loads(database.sql(sql, database='iot_platform_lab',
                                    variables=(('auth_fault_user_id', str(run_id)),)).stdout)
    require(actual['accounts'] == [account] and actual['memberships'] == [joined],
            'MEMBER_CREATE_SINGLE_ACCOUNT_NO_AUTOJOIN')
    rows = actual['invitations']
    if invitation is None:
        require(rows == [], 'MEMBER_CREATE_UNEXPECTED_INVITATION')
    else:
        require(len(rows) == 1 and rows[0][:2] == [invited, invitation[0]]
                and datetime.fromisoformat(rows[0][2]) == invitation[1] and rows[0][3] is True,
                'MEMBER_CREATE_PENDING_INVITATION')


# Đối chiếu phép tạo User bị gián đoạn sau bước ghi account với dữ liệu trước request.
# Input: database/port là DB và HTTP dùng một lần, actor là Admin của workspace, run_id nhận diện fixture.
# Output: trả về khi HTTP báo 503 chung và cả account lẫn tập membership khớp trạng thái ban đầu.
# Errors: sai owner, quyền ban đầu, HTTP, rollback hoặc khôi phục quyền sẽ làm test thất bại.
# Side effects: tạm thu hồi INSERT của role test trong một container và cấp lại quyền trong finally.
def check_creation_rollback(database, port, actor, run_id):
    """Kiểm IT-MEMBER-001 khi PostgreSQL từ chối INSERT tại bước thêm membership."""
    owner = database.docker('inspect', database.CONTAINER, '--format',
                            '{{index .Config.Labels "com.iot.member-run"}}').stdout.strip()
    require(owner == str(run_id), 'MEMBER_CREATE_FAULT_OWNER')
    # Tra account bằng email fixture và lấy tập membership độc lập với join account để thấy cả row dư.
    state_sql = """SELECT json_build_object('accounts', (SELECT count(*) FROM users
        WHERE email_normalized='probe-' || :'target' || '-rollback@example.invalid'),
        'members', ARRAY(SELECT user_id FROM memberships WHERE workspace_id=:'workspace'::uuid ORDER BY user_id));"""
    keys = {'workspace': actor[0], 'target': run_id}
    before = json.loads(fixture_sql(database, state_sql, **keys))
    require(before['accounts'] == 0 and before['members'], 'MEMBER_CREATE_FAULT_BASELINE')
    # Kiểm quyền hiệu lực để một 503 do cấu hình sẵn không tạo kết quả dương tính giả.
    privilege = "SELECT has_table_privilege('iot_repository_probe','public.memberships','INSERT');"
    require(fixture_sql(database, privilege) == 't', 'MEMBER_CREATE_FAULT_GRANT_GIVEN')
    try:
        database.sql('REVOKE INSERT ON public.memberships FROM iot_repository_probe;',
                     database='iot_platform_lab', role=database.ADMIN)
        require(fixture_sql(database, privilege) == 'f', 'MEMBER_CREATE_FAULT_DENIED')
        status, body = create(port, actor, f'probe-{run_id}-rollback@example.invalid')
        require(status == 503 and has_error_only_payload(body, 'SERVICE_UNAVAILABLE'),
                'MEMBER_CREATE_FAULT_HTTP')
    finally:
        # Chỉ trả lại đúng quyền đã kiểm trước khi fault, cả khi HTTP/transport/assertion thất bại.
        database.sql('GRANT INSERT ON public.memberships TO iot_repository_probe;',
                     database='iot_platform_lab', role=database.ADMIN)
    require(fixture_sql(database, privilege) == 't', 'MEMBER_CREATE_FAULT_GRANT_RESTORED')
    require(json.loads(fixture_sql(database, state_sql, **keys)) == before, 'MEMBER_CREATE_FAULT_ROLLBACK')


# Tìm bí mật vừa cấp trong audit toàn cục và audit tại workspace phát hành của từng Admin.
# Input
# Param: database — PostgreSQL dùng một lần của fixture.
# Param: scopes — các cặp workspace/actor và số lần cấp bí mật trong workspace tương ứng.
# Param: secrets — mật khẩu và token tổng hợp chỉ giữ trong RAM để đối chiếu với audit diff.
# Output: trả về khi đủ sự kiện phát hành tại workspace và các diff đã quét đều giữ kín bí mật.
# Errors: thiếu sự kiện hoặc tìm thấy bí mật sẽ báo mã assertion cố định, không in diff hay giá trị tìm được.
# Side effects: chỉ đọc audit theo actor và phạm vi đã chọn; bí mật để đối chiếu ở lại trong RAM.
def check_audit_redaction(database, scopes, secrets):
    """Kiểm phần audit của SEC-MEMBER-003 cho cả ba mật khẩu và hai token vừa cấp."""
    require(len(secrets) == sum(count for _, _, count in scopes), 'MEMBER_CREATE_AUDIT_CANARIES')
    # So cùng cách escape JSON để password chứa dấu nháy hoặc dấu gạch chéo cũng được phát hiện trong diff.
    needles = [json.dumps(secret, ensure_ascii=False)[1:-1] for secret in secrets]
    for workspace, actor, issued in scopes:
        # Bind actor/workspace để đọc cả TEMPORARY_ACCOUNT_CREATED toàn cục của đúng Admin đã tạo tài khoản.
        # Bộ đếm chỉ tính sự kiện phát hành ở workspace, còn diff được quét ở cả hai phạm vi.
        statement = """SELECT json_build_object('issued', count(*) FILTER (WHERE workspace_id=:'workspace'::uuid
            AND event_type IN
            ('MEMBERSHIP_CREATED','INVITATION_CREATED')), 'diffs', json_agg(redacted_diff))
            FROM audit_events WHERE actor_user_id=:'actor'::uuid
            AND (workspace_id=:'workspace'::uuid OR workspace_id IS NULL);"""
        audit = json.loads(fixture_sql(database, statement, workspace=workspace, actor=actor))
        require(audit['issued'] >= issued and isinstance(audit['diffs'], list), 'MEMBER_CREATE_AUDIT_MISSING')
        contents = json.dumps(audit['diffs'], ensure_ascii=False)
        require(all(needle not in contents for needle in needles), 'MEMBER_CREATE_AUDIT_SECRET')


# Quét snapshot metric xuất từ Auth Lab và chính dòng bằng chứng sẽ được runner công bố.
# Input
# Param: port — cổng loopback của Auth Lab đã phục vụ các request tạo thành viên.
# Param: key — khóa điều khiển measurement riêng cho lượt này, chỉ giữ trong RAM.
# Param: window — số thế hệ nhận trước khi gửi các request tạo tài khoản và lời mời.
# Param: secrets — toàn bộ mật khẩu và token một lần đã nhận qua HTTP trong cùng cửa sổ.
# Output: dòng bằng chứng ASCII chứa số mẫu và kết quả quét, sẵn sàng in sau teardown.
# Errors: xuất sai cửa sổ, thiếu mẫu, mất mẫu hoặc phát hiện canary sẽ dừng runner trước khi công bố.
# Side effects: đóng cửa sổ measurement qua HTTP và quét dữ liệu trong RAM.
def checked_measurement_evidence(port, key, window, secrets):
    """Kiểm các stage hash và DB thật để một cửa sổ trống không thể được dùng làm bằng chứng redaction."""
    metrics = measurement_control(port, 'end', key)
    require(metrics.get('windowId') == window and metrics.get('valid') is True
            and metrics.get('poisoned') is False and metrics.get('droppedSamples') == metrics.get('staleSamples') == 0,
            'MEMBER_CREATE_METRIC_WINDOW')
    samples = metrics.get('samples')
    require(isinstance(samples, list) and all(isinstance(sample, dict) for sample in samples),
            'MEMBER_CREATE_METRIC_SAMPLES')
    completed = {sample.get('stage') for sample in samples if sample.get('outcome') == 'completed'}
    require({'hash_work', 'pool_acquire', 'transaction_begin', 'commit_ack'} <= completed,
            'MEMBER_CREATE_METRIC_ACTIVITY')
    # Quét toàn bộ export trước khi chọn số liệu công bố để bắt cả giá trị bí mật trong tên nhãn hoặc trường dư.
    canaries = tuple(secrets)
    scan = scan_sink('metric', json.dumps(metrics).encode('utf-8'), canaries)
    require(scan['status'] == 'PASS', 'MEMBER_CREATE_METRIC_SECRET')
    evidence = (f"MEMBER_CREATE_REDACTION_EVIDENCE metricSamples={len(samples)} "
                f"issuedSecrets={scan['canaryCount']} metricCanaryMatches={scan['canaryMatches']}")
    require(scan_sink('evidence', evidence.encode('ascii'), canaries)['status'] == 'PASS',
            'MEMBER_CREATE_EVIDENCE_SECRET')
    return evidence


# Kiểm rollback, luồng tạo/sửa/mời, audit và metric của hai Admin kể cả khi hai request tạo đồng thời.
# Input: port và database thuộc cùng fixture, run_id và password chỉ dùng cho các account tổng hợp của lượt này.
# Input: measurement_key điều khiển cửa sổ đo trên đúng tiến trình Auth Lab này.
# Input: secrets là danh sách do runner sở hữu, nhận từng mật khẩu/token vừa cấp để quét hai pipe sau khi child dừng.
# Output: dòng bằng chứng đã quét sau khi phản hồi, dữ liệu đã commit và các lần logout đều hợp lệ.
# Errors: lỗi phiên, HTTP, SQL, rollback, rò bí mật, revision hoặc kết quả race làm test thất bại.
# Side effects: tạo session, đổi rồi khôi phục quyền INSERT, tạo membership/invitation và sửa alias trong fixture.
def verify_member_creation(port, database, run_id, password, measurement_key, secrets):
    """Kiểm rollback trước các bước tạo, sửa, mời, tranh chấp và đối chiếu audit theo từng scope."""
    with ExitStack() as sessions:
        actors = []
        baseline = {}
        for index in (0, 4):
            email = f'probe-{run_id}-{index}@example.invalid'
            user_id, credentials = sessions.enter_context(fixture_actor(port, email, password))
            baseline[index] = (user_id, email)
            actors.append((owned_workspace(port, credentials), credentials))
        first, second = actors
        require(first[0] != second[0], 'MEMBER_CREATE_DISTINCT_WORKSPACES')
        # Mở sau hai lần login để mẫu hash/DB quan sát được thuộc luồng thành viên đang kiểm.
        window = begin_window(port, measurement_key)
        check_creation_rollback(database, port, first, run_id)
        sequential = f'probe-{run_id}-sequence@example.invalid'
        created = create(port, first, sequential)
        account = check_created(created, first[0], sequential, secrets)
        original = created[1]['membership']
        # Gửi If-Match lấy từ response 201. Lần sửa thứ hai mang alias khác để phát hiện mọi ghi đè bằng revision cũ.
        updated = changed(database, original, patch(port, first[1], first[0], account, 'scoped',
                          {'alias': 'Tên đã lưu'}, original['revision']), alias='Tên đã lưu')
        denied(patch(port, first[1], first[0], account, 'scoped', {'alias': 'Bản sửa cũ'},
                     original['revision']), 412, 'VERSION_CONFLICT')
        require(snapshot(database, first[0], account) == updated, 'MEMBER_CREATE_STALE_PATCH_UNCHANGED')
        check_conflict(create(port, first, sequential), 'MEMBER_EXISTS', secrets)
        invitation = check_invited(create(port, second, sequential), second[0], secrets)
        check_conflict(create(port, second, sequential), 'INVITATION_EXISTS', secrets)
        check_persistence(database, run_id, 'sequence', account, first[0], second[0], invitation)
        # Cả hai Admin tải lại metadata sau POST. B chưa nhận membership của email đang chờ accept.
        first_id, first_email = baseline[0]
        second_id, second_email = baseline[4]
        expected_rows = ({first_id: (first_email, 'ADMIN'), account: (sequential, 'USER')},
                         {first_id: (first_email, 'USER'), second_id: (second_email, 'ADMIN')})
        for (workspace, credentials), expected in zip(actors, expected_rows):
            rows = check_pages(port, '/users', workspace, credentials, expected)
            contents = json.dumps(rows, ensure_ascii=False)
            require(all(secret not in contents for secret in secrets), 'MEMBER_CREATE_LIST_SECRET_REPLAY')

        same = f'probe-{run_id}-same@example.invalid'
        responses = sorted(race(port, [first, first], same), key=itemgetter(0))
        account = check_created(responses[0], first[0], same, secrets)
        check_conflict(responses[1], 'MEMBER_EXISTS', secrets)
        check_persistence(database, run_id, 'same', account, first[0])

        cross = f'probe-{run_id}-cross@example.invalid'
        responses = race(port, actors, cross)
        require(sorted(status for status, _ in responses) == [201, 202], 'MEMBER_CREATE_CROSS_RACE')
        winner = 0 if responses[0][0] == 201 else 1
        joined, invited = actors[winner][0], actors[1 - winner][0]
        account = check_created(responses[winner], joined, cross, secrets)
        invitation = check_invited(responses[1 - winner], invited, secrets)
        check_conflict(create(port, actors[winner], cross), 'MEMBER_EXISTS', secrets)
        check_conflict(create(port, actors[1 - winner], cross), 'INVITATION_EXISTS', secrets)
        check_persistence(database, run_id, 'cross', account, joined, invited, invitation)
        # Admin A nhận bí mật ở bước sequence, same và cross; Admin B nhận ở sequence và cross.
        check_audit_redaction(database, ((first[0], first_id, 3), (second[0], second_id, 2)), secrets)
        return checked_measurement_evidence(port, measurement_key, window, secrets)
