"""Kiểm HTTP và PostgreSQL thật bằng fixture của launcher; không in credential/cookie/body."""

import http.client
import hashlib
import json
import re
import secrets
from datetime import datetime, timedelta
from uuid import UUID, uuid4


credential_observer = None


# Chỉ mở loopback của process do launcher sở hữu; không follow redirect hoặc ghi HTTP debug log.
def request(port, method, path, body=None, headers=None):
    """Gửi một request lab và cho security harness quan sát credential hai chiều trước khi parse response.

    Input
    Param: port — listener loopback của backend lab do launcher sở hữu.
    Param: method/path — thao tác HTTP và route nội bộ, không nhận URL tùy ý.
    Param: body/headers — dữ liệu fixture chỉ giữ trong RAM, không ghi log.
    Output: status, header projection và JSON bounded; observer chỉ nhận credential theo allowlist.
    Errors: body vượt cận hoặc JSON hỏng làm request thất bại, không phản chiếu payload.
    Side effects: observer đã đăng ký có thể bổ sung canary RAM trước khi caller tiếp tục.
    """
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=20)
    supplied_headers = dict(headers or {})
    if body is not None:
        supplied_headers["Content-Type"] = "application/json"
    try:
        connection.request(method, "/api/v1" + path, json.dumps(body) if body is not None else None, supplied_headers)
        response = connection.getresponse()
        response_headers = response.getheaders()
        payload = response.read(131073)
        if len(payload) > 131072:
            raise RuntimeError("Provider response exceeds test budget")
        if credential_observer is not None:
            credential_observer.observe(port, body or {}, supplied_headers, response_headers, payload)
        return response.status, dict(response_headers), json.loads(payload) if payload else None
    finally:
        connection.close()


# Không đưa giá trị expected/actual vào assertion vì chúng có thể là token hoặc hồ sơ.
def expect(condition, check_id, checks):
    """Input: condition boolean và check_id tĩnh. Output: append tên invariant hoặc lỗi an toàn, không body."""
    if not condition:
        raise RuntimeError("Provider check failed: " + check_id)
    checks.append(check_id)


# Header names HTTP không phân biệt hoa thường; giữ secret chỉ trong bộ nhớ người gọi.
def header(headers, name):
    """Input: headers response, name allowlist. Output: giá trị header hoặc None, không print."""
    return next((value for key, value in headers.items() if key.lower() == name.lower()), None)


def has_error_only_payload(body, expected_code):
    """Kiểm projection từ chối không lẫn dữ liệu resource, dùng chung cho ba guard provider thật.

    Input
    Param: body — JSON đã bounded parse từ HTTP, không được log khi sai.
    Param: expected_code — mã lỗi literal mà scenario đang kiểm.
    Output: True chỉ với envelope/error keys cố định, message catalog, UUID correlation và details rỗng theo adapter.
    """
    if not isinstance(body, dict) or set(body) != {'error'}:
        return False
    error = body['error']
    if not isinstance(error, dict) or set(error) != {'code', 'message', 'details', 'correlationId'}:
        return False
    try:
        correlation = UUID(error['correlationId'])
    except (ValueError, TypeError, AttributeError):
        return False
    messages = {'AUTH_INVALID': 'Thông tin đăng nhập không hợp lệ.',
                **dict.fromkeys(('PASSWORD_CHANGE_REQUIRED', 'RESOURCE_NOT_FOUND', 'AUTH_CONTEXT_MISMATCH',
                                 'CSRF_INVALID', 'SESSION_EXPIRED', 'RATE_LIMITED', 'CURSOR_INVALID', 'SERVICE_UNAVAILABLE'),
                                'Không thể hoàn tất yêu cầu. Vui lòng kiểm tra trạng thái và thử lại.')}
    return (expected_code in messages and error['code'] == expected_code
            and error['message'] == messages[expected_code]
            and str(correlation) == error['correlationId'] and error['details'] == {})


def has_login_projection(body, headers, client, email, user_id, limited):
    """Kiểm response login đúng schema và kênh để limited session không nhận role/workspace authority.

    Input
    Param: body — JSON HTTP chỉ giữ trong RAM, gồm summary và metadata public.
    Param: headers — header từ cùng response, không ghi ra evidence.
    Param: client — WEB/ANDROID/IOS đã chọn trong scenario nội bộ.
    Param: email — email fixture canonical cần khớp summary.
    Param: user_id — UUID fixture cần khớp identity đã xác thực.
    Param: limited — quyền hạn dự kiến theo trạng thái account fixture.
    Output: boolean, False khi schema/expiry/context/transport sai hoặc xuất thêm field authority.
    """
    expected_keys = {'me', 'expiresAt', 'limited'} | ({'token'} if client != 'WEB' else set())
    if client not in ('WEB', 'ANDROID', 'IOS') or not isinstance(body, dict) or set(body) != expected_keys:
        return False
    summary = body['me']
    if (not isinstance(summary, dict) or set(summary) != {'id', 'email', 'mustChangePassword'}
            or summary['id'] != str(user_id) or summary['email'] != email
            or summary['mustChangePassword'] is not limited or body['limited'] is not limited
            or header(headers, 'cache-control') != 'no-store'):
        return False
    try:
        if str(UUID(summary['id'])) != summary['id']:
            return False
        # Contract dùng UTC RFC3339; date-only, naive time và offset khác UTC không được nhận.
        if not isinstance(body['expiresAt'], str) or not re.fullmatch(r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|\+00:00)', body['expiresAt']):
            return False
        datetime.fromisoformat(body['expiresAt'].replace('Z', '+00:00'))
        if client == 'WEB':
            context = header(headers, 'x-auth-context-id')
            cookie = header(headers, 'set-cookie')
            return (str(UUID(context)) == context and bool(header(headers, 'x-csrf-token'))
                    and isinstance(cookie, str) and cookie.startswith('iot_session=')
                    and all(value in cookie for value in ('Secure', 'HttpOnly', 'SameSite=Lax', 'Path=/api/v1'))
                    and 'Domain=' not in cookie)
        return (isinstance(body['token'], str) and bool(body['token'])
                and all(header(headers, name) is None for name in ('set-cookie', 'x-auth-context-id', 'x-csrf-token')))
    except (ValueError, TypeError, AttributeError):
        return False


def read_persisted_session(token, user_id, client, limited, expires_at):
    """Đối soát capability vừa cấp với row durable, metadata và TTL24h mà không log secret/verifier.

    Input
    Param: token — capability trả bởi login thuộc fixture, chỉ dùng băm và scan row trong RAM.
    Param: user_id — UUID fixture dùng binding quote để giới hạn SELECT.
    Param: client — metadata transport phải khớp WEB/ANDROID/IOS.
    Param: limited — trạng thái quyền hạn cần lưu đúng theo login.
    Param: expires_at — UTC RFC3339 từ response phải bằng expiry đã commit.
    Output: UUID session đã xác nhận; caller dùng so sánh hai concurrent intents.
    Errors: RuntimeError cố định khi SQL/row/metadata sai, không phản chiếu dữ liệu auth.
    """
    import verify_database as lab
    identity = str(UUID(str(user_id)))
    digest = hashlib.sha256(token.encode('utf-8')).hexdigest()
    # Chỉ digest SHA256 nội bộ được nội suy; UUID quote riêng, raw capability không đi vào SQL/argv.
    statement = "SELECT coalesce(json_agg(s),'[]'::json) FROM sessions s WHERE s.user_id=:'auth_fault_user_id'::uuid AND s.token_digest=decode('" + digest + "','hex');"
    result = lab.sql(statement, role=lab.ADMIN, database='iot_platform_lab', check=False,
                     variables=(('auth_fault_user_id', identity),))
    try:
        rows = json.loads(result.stdout) if result.returncode == 0 else []
        if len(rows) != 1 or not isinstance(rows[0], dict) or token in json.dumps(rows[0]):
            raise ValueError('Invalid session row')
        row = rows[0]
        session_id = UUID(row['session_id'])
        context = UUID(row['auth_context_id'])
        issued = datetime.fromisoformat(row['issued_at'])
        expiry = datetime.fromisoformat(row['expires_at'])
        valid = (str(session_id) == row['session_id'] and str(context) == row['auth_context_id']
                 and row['user_id'] == identity and row['token_digest'] == '\\x' + digest
                 and row['client_type'] == client and row['limited'] is limited and row['revoked_at'] is None
                 and issued.utcoffset() == expiry.utcoffset() == timedelta(0)
                 and expiry - issued == timedelta(hours=24)
                 and expiry == datetime.fromisoformat(expires_at.replace('Z', '+00:00')))
        if valid:
            return session_id
    except (ValueError, KeyError, TypeError, AttributeError):
        pass
    raise RuntimeError('Provider session metadata mismatch')


def has_workspace_page(body):
    """Kiểm picker chỉ chứa summary ACTIVE theo contract, không rò dữ liệu resource hoặc authority khác.

    Input
    Param: body — JSON page từ HTTP chỉ giữ trong RAM để kiểm schema và uniqueness.
    Output: boolean đúng khi page/cursor và mọi UUID/role/revision phù hợp projection công khai.
    """
    if (not isinstance(body, dict) or set(body) != {'items', 'nextCursor'} or not isinstance(body['items'], list)
            or not (body['nextCursor'] is None or isinstance(body['nextCursor'], str) and bool(body['nextCursor']))):
        return False
    identities = []
    for item in body['items']:
        if (not isinstance(item, dict) or set(item) != {'id', 'name', 'status', 'role', 'revision'}
                or not isinstance(item['name'], str) or item['status'] != 'ACTIVE' or item['role'] not in ('ADMIN', 'USER')
                or type(item['revision']) is not int or item['revision'] < 1):
            return False
        try:
            if str(UUID(item['id'])) != item['id']:
                return False
        except (ValueError, TypeError, AttributeError):
            return False
        identities.append(item['id'])
    return len(identities) == len(set(identities))


def verify_login_origin_boundaries(port, login_body, user_id, checks):
    """Thử origin/Referer giả ở login và đối soát số session/audit để denial không tạo authority.

    Input
    Param: port — listener loopback đang thuộc launcher.
    Param: login_body — credential fixture ACTIVE trong RAM, clientType được thay bằng literal scenario.
    Param: user_id — UUID account fixture để readback count trước/sau mọi denied login.
    Param: checks — danh sách check ID tĩnh, không nhận payload hoặc credential.
    Errors: sai status/projection/header/count làm dừng suite bằng ID an toàn.
    """
    from verify_commit_ack import read_snapshot
    before = read_snapshot(user_id, 'WEB')
    cases = [(client, {'Origin': 'https://foreign.example.invalid'}, 'foreign-origin-' + client.lower())
             for client in ('WEB', 'ANDROID', 'IOS')]
    cases.extend((('WEB', {}, 'web-missing-origin-referer'),
                  ('WEB', {'Referer': 'http://localhost:5173/login'}, 'web-http-referer-fallback'),
                  ('WEB', {'Referer': 'https://foreign.example.invalid/login'}, 'web-foreign-referer')))
    for client, request_headers, label in cases:
        status, headers, body = request(port, 'POST', '/auth/login', {**login_body, 'clientType': client}, request_headers)
        expect(status == 403 and has_error_only_payload(body, 'CSRF_INVALID')
               and header(headers, 'cache-control') == 'no-store'
               and all(header(headers, name) is None for name in ('set-cookie', 'x-auth-context-id', 'x-csrf-token', 'retry-after', 'access-control-allow-origin')),
               'login-origin-' + label + '-denied-no-credential', checks)
    after = read_snapshot(user_id, 'WEB')
    expect(after.session_count == before.session_count and after.audit_count == before.audit_count,
           'login-origin-denials-no-session-or-success-audit', checks)


def set_owned_membership_status(run_id, user_id, owner_id, workspace_id, status):
    """Đổi USER membership synthetic theo hai bước ACTIVE→SUSPENDED→REMOVED để kiểm filter hiện hành.

    Input
    Param: run_id — marker launcher phải sở hữu probe role và cả hai account của workspace.
    Param: user_id — UUID fixture0 có USER membership cần kiểm, không là last Admin.
    Param: owner_id — UUID fixture4 đã tạo workspace và giữ ADMIN để bảo vệ invariant.
    Param: workspace_id — UUID đã được HTTP picker xác nhận thuộc fixture.
    Param: status — SUSPENDED hoặc REMOVED từ allowlist nội bộ, không nhận fragment SQL.
    Errors: ownership/transition/count không đúng làm fail closed bằng lỗi cố định.
    Side effects: đổi đúng một membership fixture, tăng revision/authz; REMOVED ghi removed_at và revoke current grant cùng transaction.
    """
    import verify_database as lab
    import verify_repositories as repository
    run_marker = str(UUID(str(run_id)))
    identity, owner, workspace = (str(UUID(str(value))) for value in (user_id, owner_id, workspace_id))
    if not repository.owns_probe(run_marker) or status not in ('SUSPENDED', 'REMOVED'):
        raise RuntimeError('Owned membership transition rejected')
    previous = {'SUSPENDED': 'ACTIVE', 'REMOVED': 'SUSPENDED'}[status]
    # UUID đã chuẩn hóa và status hữu hạn mới được nội suy, user binding quote riêng; provenance chặn row ngoại lai.
    statement = """WITH changed AS (
      UPDATE memberships m SET status='""" + status + """',revision=m.revision+1,
        authorization_version=m.authorization_version+1,
        removed_at=CASE WHEN '""" + status + """'='REMOVED' THEN transaction_timestamp() ELSE NULL END
      FROM users subject,users owner,workspaces w
      WHERE m.user_id=:'auth_fault_user_id'::uuid AND m.workspace_id='""" + workspace + """'::uuid
        AND m.role='USER' AND m.status='""" + previous + """'
        AND subject.user_id=m.user_id AND subject.activation_provenance='AUTH_HTTP_LAB:""" + run_marker + """'
        AND subject.email_normalized='probe-""" + run_marker + """-0@example.invalid'
        AND w.workspace_id=m.workspace_id AND w.created_by_user_id=owner.user_id
        AND owner.user_id='""" + owner + """'::uuid AND owner.activation_provenance='AUTH_HTTP_LAB:""" + run_marker + """'
        AND owner.email_normalized='probe-""" + run_marker + """-4@example.invalid'
      RETURNING m.workspace_id,m.user_id,m.current_grant_generation
    ), revoked_grant AS (
      UPDATE membership_grants g SET revoked_at=transaction_timestamp() FROM changed m
      WHERE '""" + status + """'='REMOVED' AND (g.workspace_id,g.user_id,g.grant_generation)=
        (m.workspace_id,m.user_id,m.current_grant_generation) AND g.revoked_at IS NULL
      RETURNING g.workspace_id
    ) SELECT (SELECT count(*) FROM changed),(SELECT count(*) FROM revoked_grant);"""
    # Deferred guard yêu cầu REMOVED có current grant revoked; cả hai CTE commit nguyên tử, không tắt constraint.
    result = lab.sql(statement, database='iot_platform_lab', check=False, variables=(('auth_fault_user_id', identity),))
    if result.returncode or result.stdout.strip() != ('1|1' if status == 'REMOVED' else '1|0'):
        raise RuntimeError('Owned membership transition rejected')


def verify_email_canonicalization(port, login_body, user_id, run_id, checks):
    """Đối soát login khác case/ASCII whitespace cùng account và unique key email thật trên fixture sở hữu.

    Input
    Param: port — listener loopback thuộc launcher, đã có account0 login thành công.
    Param: login_body — email canonical và password seed trong RAM, password được truyền nguyên chuỗi.
    Param: user_id — UUID account0 được dùng cho profile/session và predicate ownership SQL.
    Param: run_id — marker live của probe, phải khớp provenance và namespace email trước unique test.
    Param: checks — danh sách ID tĩnh, không ghi email/password/token hoặc lỗi SQL.
    Errors: khác account, session trùng, metadata sai hoặc unique key không từ chối làm fail closed.
    Side effects: hai session fixture mới; duplicate User intent nằm trong savepoint/rollback nên không thêm account bền vững.
    """
    import verify_database as lab
    import verify_repositories as repository
    run_marker = str(UUID(str(run_id)))
    identity = str(UUID(str(user_id)))
    canonical_email = 'probe-' + run_marker + '-0@example.invalid'
    if login_body['email'] != canonical_email or not repository.owns_probe(run_marker):
        raise RuntimeError('Canonical email fixture ownership mismatch')
    session_ids = []
    for variant, label in ((canonical_email.upper(), 'case'), ('\t ' + canonical_email.upper() + '\r\n', 'ascii-edges')):
        status, headers, body = request(port, 'POST', '/auth/login', {**login_body, 'email': variant, 'clientType': 'ANDROID'})
        expect(status == 200 and has_login_projection(body, headers, 'ANDROID', canonical_email, identity, False),
               'email-canonical-' + label + '-same-account', checks)
        session_ids.append(read_persisted_session(body['token'], identity, 'ANDROID', False, body['expiresAt']))
    expect(len(set(session_ids)) == 2, 'email-canonical-variants-distinct-durable-sessions', checks)
    duplicate_id = str(uuid4())
    # Tất cả literal được sinh/UUID-parse từ live fixture; password_hash chỉ copy nội bộ DB, không đọc vào Python.
    # Khối EXCEPTION tạo subtransaction rollback cho duplicate intent, outer SAVEPOINT/ROLLBACK bảo vệ cả nhánh bất ngờ.
    statement = """BEGIN; SAVEPOINT canonical_email_probe;
    DO $email_probe$ DECLARE violated text; rejected boolean:=false; BEGIN
      IF (SELECT count(*) FROM users WHERE user_id='""" + identity + """'::uuid
        AND activation_provenance='AUTH_HTTP_LAB:""" + run_marker + """'
        AND email_normalized='""" + canonical_email + """')<>1 THEN RAISE EXCEPTION 'Owned email fixture missing'; END IF;
      BEGIN
        INSERT INTO users(user_id,email_normalized,password_hash,account_status,must_change_password,activation_provenance)
        SELECT '""" + duplicate_id + """'::uuid,email_normalized,password_hash,account_status,must_change_password,activation_provenance
        FROM users WHERE user_id='""" + identity + """'::uuid;
      EXCEPTION WHEN unique_violation THEN
        GET STACKED DIAGNOSTICS violated=CONSTRAINT_NAME;
        rejected:=(violated='users_email_normalized_key');
      END;
      IF NOT rejected THEN RAISE EXCEPTION 'Canonical email unique key mismatch'; END IF;
    END $email_probe$;
    SELECT count(*) FROM users WHERE email_normalized='""" + canonical_email + """';
    ROLLBACK TO SAVEPOINT canonical_email_probe; ROLLBACK;"""
    result = lab.sql(statement, database='iot_platform_lab', check=False)
    expect(result.returncode == 0 and result.stdout.strip() == '1', 'email-canonical-unique-key-rejects-duplicate', checks)


def verify_password_flow(port, email, password, web_headers, csrf, user_id, checks):
    """Kiểm đổi credential tổng hợp qua HTTP thật và revoke hai client sau commit, không log dữ liệu auth.

    Input
    Param: port — listener loopback thuộc launcher của lượt kiểm hiện tại.
    Param: email — account limited synthetic trong đúng5fixture được phép.
    Param: password — credential seed giữ trong RAM để verify current và thử login cũ sau đổi.
    Param: web_headers — cookie/context của session limited, không là authority do test tự cấp.
    Param: csrf — token từ limited /me confirmation, chỉ dùng với chính cookie/context đó.
    Param: user_id — UUID fixture để kiểm profile mới không đổi identity.
    Param: checks — danh sách chỉ chứa check ID tĩnh dùng cho report không secret.
    Errors: RuntimeError chỉ mang check ID nếu provider lệch contract; không tự sửa expected hoặc retry mutation.
    Side effects: đổi password đúng account fixture, revoke session của account đó; launcher chịu cleanup.
    """
    login = {"email": email, "password": password, "clientType": "ANDROID"}
    status, _, app = request(port, "POST", "/auth/login", login)
    expect(status == 200 and app.get("token") and app["limited"] is True, "password-change-android-limited-session", checks)
    bearer = {"Authorization": "Bearer " + app["token"]}
    origin = {**web_headers, "Origin": "http://localhost:5173"}
    mutation_headers = {**origin, "X-CSRF-Token": csrf}
    for candidate, code, check_id in [
        ("Abcdefg1", "LENGTH", "password-new-length-8"),
        ("abcdefg12", "FORMAT", "password-new-missing-uppercase"),
        ("ABCDEFG12", "FORMAT", "password-new-missing-lowercase"),
        ("Abcdefghi", "FORMAT", "password-new-missing-digit"),
        (password, "SAME_AS_CURRENT", "password-new-same-as-current"),
    ]:
        status, headers, body = request(port, "POST", "/auth/password", {"currentPassword": password, "newPassword": candidate}, mutation_headers)
        expect(status == 422 and not header(headers, "set-cookie") and {"path": "/newPassword", "code": code} in body["error"]["details"]["fieldErrors"], check_id, checks)
        status, _, _ = request(port, "GET", "/me", headers=web_headers)
        expect(status == 403, check_id + "-session-retained", checks)
    # Chỉ credential TEST đúng9ký tự để kiểm boundary; không dùng generator này cho account sản phẩm.
    new_password = "Aa1" + secrets.token_hex(3)
    status, headers, body = request(port, "POST", "/auth/password", {"currentPassword": "synthetic-wrong-current", "newPassword": new_password}, mutation_headers)
    expect(status == 401 and body["error"]["code"] == "AUTH_INVALID" and not header(headers, "set-cookie"), "password-current-wrong-denied", checks)
    status, _, _ = request(port, "GET", "/me", headers=web_headers)
    expect(status == 403, "password-current-wrong-keeps-session", checks)
    status, _, _ = request(port, "POST", "/auth/password", {"currentPassword": password, "newPassword": new_password}, origin)
    expect(status == 403, "password-change-requires-csrf", checks)
    status, _, _ = request(port, "GET", "/me", headers=bearer)
    expect(status == 403, "password-denials-keep-android-session", checks)
    status, _, body = request(port, "POST", "/auth/password", {"currentPassword": password, "newPassword": new_password}, mutation_headers)
    expect(status == 204 and body is None, "password-change-nine-codepoints-committed", checks)
    status, _, _ = request(port, "GET", "/me", headers=web_headers)
    expect(status == 401, "password-change-revokes-web-session", checks)
    status, _, _ = request(port, "GET", "/me", headers=bearer)
    expect(status == 401, "password-change-revokes-android-session", checks)
    status, _, _ = request(port, "POST", "/auth/login", login)
    expect(status == 401, "password-change-rejects-old-password", checks)
    status, headers, app = request(port, "POST", "/auth/login", {**login, "password": new_password})
    expect(status == 200 and app.get("token") and app["limited"] is False and not header(headers, "set-cookie"), "password-change-new-android-login-full", checks)
    status, _, profile = request(port, "GET", "/me", headers={"Authorization": "Bearer " + app["token"]})
    expect(status == 200 and profile["id"] == str(user_id), "password-change-preserves-profile-identity", checks)
    status, headers, body = request(port, "POST", "/auth/login", {**login, "password": new_password, "clientType": "WEB"}, {"Origin": "http://localhost:5173"})
    expect(status == 200 and body["limited"] is False and "token" not in body and header(headers, "set-cookie"), "password-change-new-web-login-full", checks)


# Một luồng thật xuyên Router→application→SQLx→PostgreSQL, khác với unit test router/pool lazy.
def verify_provider(port, emails, password, run_id, user_ids):
    """Chạy baseline auth/bootstrap/password thật trên fixture sở hữu để phân biệt provider evidence với mock.

    Input
    Param: port — listener loopback của binary do launcher đang sở hữu.
    Param: emails —5email tổng hợp theo thứ tự full/disabled/limited/empty/owner thứ hai.
    Param: password — credential seed trong RAM, không log hoặc ghi evidence.
    Param: run_id — UUID của lượt chạy, giới hạn email unknown và mutation membership vào fixture đó.
    Param: user_ids —5UUID tương ứng để kiểm identity và scope mutation/cleanup.
    Output: danh sách check ID đã PASS, không chứa dữ liệu HTTP hoặc credential.
    Errors: RuntimeError an toàn ở invariant đầu tiên sai; không tự retry POST hoặc đổi expected.
    Side effects: tạo/revoke session fixture, thêm session đã hết hạn, kiểm B/C workspace tạm rồi dọn ngay, đổi password và chuyển USER membership fixture qua SUSPENDED/REMOVED; launcher dọn graph khi kết thúc.
    """
    checks = []
    origin = {"Origin": "http://localhost:5173"}
    login_body = {"email": emails[0], "password": password, "clientType": "WEB"}
    verify_login_origin_boundaries(port, login_body, user_ids[0], checks)
    status, headers, body = request(port, "POST", "/auth/login", login_body, origin)
    expect(status == 200 and "token" not in body and body["limited"] is False, "web-login-after-commit-no-bearer", checks)
    expect(has_login_projection(body, headers, 'WEB', emails[0], user_ids[0], False), 'web-full-login-exact-projection', checks)
    cookie = header(headers, "set-cookie")
    context = header(headers, "x-auth-context-id")
    csrf = header(headers, "x-csrf-token")
    read_persisted_session(cookie.split(';', 1)[0].split('=', 1)[1], user_ids[0], 'WEB', False, body['expiresAt'])
    checks.append('web-session-protected-digest-metadata-ttl')
    verify_email_canonicalization(port, login_body, user_ids[0], run_id, checks)
    expect(cookie is not None and all(value in cookie for value in ["Secure", "HttpOnly", "SameSite=Lax", "Path=/api/v1"]) and "Domain=" not in cookie, "cookie-protected-exact-path", checks)
    expect(header(headers, "cache-control") == "no-store" and context and csrf, "web-metadata-no-store", checks)
    cookie_header = {"Cookie": cookie.split(";", 1)[0]}
    confirmed = {**cookie_header, "X-Auth-Context-Id": context}
    status, headers, me = request(port, "GET", "/me", headers=cookie_header)
    expect(status == 200 and me["id"] == str(user_ids[0]) and me["displayTimezone"] == "UTC" and me["preferencesRevision"] == 1 and header(headers, "x-auth-context-id") == context, "full-me-discovery-safe-projection", checks)
    expected_profile = {'id': str(user_ids[0]), 'email': emails[0], 'mustChangePassword': False,
                        'displayTimezone': 'UTC', 'preferencesRevision': 1}
    expect(me == expected_profile, 'web-full-profile-exact-schema', checks)
    for protected_path in ('/me', '/workspaces', '/devices'):
        status, metadata, body = request(port, 'GET', protected_path,
                                         headers={**confirmed, 'Origin': 'https://foreign.example.invalid'})
        expect(status == 403 and has_error_only_payload(body, 'CSRF_INVALID')
               and all(header(metadata, name) is None for name in ('set-cookie', 'x-auth-context-id', 'x-csrf-token', 'access-control-allow-origin')),
               'bootstrap-foreign-origin-' + protected_path[1:] + '-denied-no-data', checks)
    status, _, body = request(port, "GET", "/me", headers=confirmed)
    expect(status == 200 and body["id"] == me["id"], "full-me-context-confirmation", checks)
    status, _, body = request(port, "GET", "/me", headers={**cookie_header, "X-Auth-Context-Id": str(uuid4())})
    expect(status == 409 and has_error_only_payload(body, 'AUTH_CONTEXT_MISMATCH'), "context-mismatch-before-profile", checks)
    status, _, body = request(port, "GET", "/workspaces", headers=cookie_header)
    expect(status == 409 and has_error_only_payload(body, 'AUTH_CONTEXT_MISMATCH'), "picker-rejects-missing-context", checks)
    status, _, page = request(port, "GET", "/workspaces", headers=confirmed)
    expect(status == 200 and has_workspace_page(page) and len(page["items"]) == 2
           and {item["role"] for item in page["items"]} == {"ADMIN", "USER"} and page['nextCursor'] is None,
           "picker-current-membership-roles", checks)
    # B/C tạm được dọn trước oracle hai workspace hiện hữu, không đổi membership seed A/D.
    from verify_workspace_matrix import verify_workspace_matrix
    verify_workspace_matrix(port, confirmed, page, run_id, user_ids[0], user_ids[4], checks)
    workspace_id = page["items"][0]["id"]
    # /me thiếu context là discovery hợp lệ; các route còn lại luôn cần context đã xác nhận.
    for protected_path in ('/workspaces', '/workspaces/' + workspace_id, '/devices'):
        for missing in (True, False):
            request_headers = cookie_header if missing else {**confirmed, 'X-Auth-Context-Id': str(uuid4())}
            status, metadata, body = request(port, 'GET', protected_path, headers=request_headers)
            expect(status == 409 and has_error_only_payload(body, 'AUTH_CONTEXT_MISMATCH')
                   and not header(metadata, 'set-cookie'),
                   'protected-get-' + protected_path.split('/')[1] + ('-missing-context' if missing else '-wrong-context'), checks)
    for query in ('?limit=100', '?status=ACTIVE&includeHistorical=false'):
        status, _, explicit_page = request(port, 'GET', '/workspaces' + query, headers=confirmed)
        expect(status == 200 and explicit_page == page, 'picker-explicit-active-or-max-limit-same-memberships', checks)
    status, _, detail = request(port, "GET", "/workspaces/" + workspace_id, headers=confirmed)
    expect(status == 200 and detail["id"] == workspace_id and detail["membershipStatus"] == "ACTIVE" and detail["membershipAuthzVersion"] >= 1, "selection-rechecks-detail-contract", checks)
    status, _, body = request(port, "GET", "/workspaces/" + str(uuid4()), headers=confirmed)
    expect(status == 404 and has_error_only_payload(body, 'RESOURCE_NOT_FOUND'),
           "foreign-workspace-not-found-no-data", checks)
    status, _, first_page = request(port, "GET", "/workspaces?limit=1", headers=confirmed)
    expect(status == 200 and has_workspace_page(first_page) and len(first_page["items"]) == 1 and first_page["nextCursor"], "signed-keyset-first-page", checks)
    cursor = first_page["nextCursor"]
    status, _, next_page = request(port, "GET", "/workspaces?limit=1&cursor=" + cursor, headers=confirmed)
    expect(status == 200 and has_workspace_page(next_page) and len(next_page['items']) == 1
           and next_page['nextCursor'] and next_page["items"][0]["id"] != first_page["items"][0]["id"], "signed-keyset-no-duplicate", checks)
    expect(first_page['items'] + next_page['items'] == page['items'], 'signed-keyset-exact-traversal-no-omissions', checks)
    # Khi trang đủ limit, server phát cursor tiếp dù đã hết rows; trang rỗng cuối xác nhận traversal terminal.
    status, _, terminal_page = request(port, 'GET', '/workspaces?limit=1&cursor=' + next_page['nextCursor'], headers=confirmed)
    expect(status == 200 and terminal_page == {'items': [], 'nextCursor': None}, 'signed-keyset-terminal-empty-page', checks)
    status, _, body = request(port, "GET", "/workspaces?limit=1&cursor=" + cursor + "0", headers=confirmed)
    expect(status == 400 and has_error_only_payload(body, 'CURSOR_INVALID'), "cursor-forgery-rejected", checks)
    status, _, body = request(port, 'GET', '/workspaces?limit=2&cursor=' + cursor, headers=confirmed)
    expect(status == 400 and has_error_only_payload(body, 'CURSOR_INVALID'), 'cursor-limit-binding-rejected', checks)
    # Account3 là principal full khác, 0membership; cursor của account0 không được cấp quyền cho account3.
    status, foreign_headers, foreign_login = request(port, 'POST', '/auth/login', {**login_body, 'email': emails[3]}, origin)
    expect(status == 200 and has_login_projection(foreign_login, foreign_headers, 'WEB', emails[3], user_ids[3], False), 'foreign-context-control-login', checks)
    foreign_confirmed = {'Cookie': header(foreign_headers, 'set-cookie').split(';', 1)[0],
                         'X-Auth-Context-Id': header(foreign_headers, 'x-auth-context-id')}
    status, _, body = request(port, 'GET', '/workspaces?limit=1&cursor=' + cursor, headers=foreign_confirmed)
    expect(status == 400 and has_error_only_payload(body, 'CURSOR_INVALID'), 'cursor-user-binding-rejected', checks)
    mismatched_headers = {**confirmed, **origin, 'X-Auth-Context-Id': foreign_confirmed['X-Auth-Context-Id'],
                          'X-CSRF-Token': header(foreign_headers, 'x-csrf-token')}
    for method, path, mutation in (('GET', '/me', None), ('POST', '/auth/logout', None),
                                   ('POST', '/auth/password', {'currentPassword': password, 'newPassword': 'Aa1' + secrets.token_hex(16)})):
        status, metadata, body = request(port, method, path, mutation, mismatched_headers)
        expect(status == 409 and has_error_only_payload(body, 'AUTH_CONTEXT_MISMATCH')
               and not header(metadata, 'set-cookie'), 'foreign-context-' + path.rsplit('/', 1)[-1] + '-denied', checks)
        for request_headers, expected_user, label in ((confirmed, user_ids[0], 'original'), (foreign_confirmed, user_ids[3], 'foreign')):
            status, _, profile = request(port, 'GET', '/me', headers=request_headers)
            expect(status == 200 and profile['id'] == str(expected_user), 'foreign-context-' + path.rsplit('/', 1)[-1] + '-' + label + '-session-retained', checks)
    # Đổi đúng membership USER thuộc fixture; owner Admin thứ hai giữ invariant last-admin.
    import verify_database as lab
    member_workspace = UUID(next(item["id"] for item in page["items"] if item["role"] == "USER"))
    set_owned_membership_status(run_id, user_ids[0], user_ids[4], member_workspace, 'SUSPENDED')
    status, _, body = request(port, "GET", "/workspaces?limit=1&cursor=" + cursor, headers=confirmed)
    expect(status == 400 and has_error_only_payload(body, 'CURSOR_INVALID'), "cursor-current-authority-change-rejected", checks)
    status, _, _ = request(port, "GET", "/workspaces/" + str(member_workspace), headers=confirmed)
    expect(status == 404, "suspended-membership-selection-denied", checks)
    active_page = {'items': [item for item in page['items'] if item['id'] != str(member_workspace)], 'nextCursor': None}
    for membership_status in ('SUSPENDED', 'REMOVED'):
        if membership_status == 'REMOVED':
            set_owned_membership_status(run_id, user_ids[0], user_ids[4], member_workspace, membership_status)
        status, _, filtered_page = request(port, 'GET', '/workspaces', headers=confirmed)
        expect(status == 200 and has_workspace_page(filtered_page) and filtered_page == active_page,
               'picker-excludes-' + membership_status.lower() + '-membership', checks)
        status, _, body = request(port, 'GET', '/workspaces/' + str(member_workspace), headers=confirmed)
        expect(status == 404 and has_error_only_payload(body, 'RESOURCE_NOT_FOUND'),
               membership_status.lower() + '-membership-detail-error-only', checks)
    status, _, _ = request(port, "POST", "/auth/logout", headers={**confirmed, **origin})
    expect(status == 403, "cookie-mutation-requires-csrf", checks)
    # Mọi denial logout phải giữ nguyên quyền S1 và không phát clear-cookie, kể cả context sai trước CSRF.
    for mutation_headers, expected_status, expected_code, label in (
        ({**confirmed, **origin, 'X-CSRF-Token': 'synthetic-invalid-csrf'}, 403, 'CSRF_INVALID', 'wrong-csrf'),
        ({**confirmed, 'Origin': 'https://foreign.example.invalid', 'X-CSRF-Token': csrf}, 403, 'CSRF_INVALID', 'wrong-origin'),
        ({**cookie_header, **origin, 'X-CSRF-Token': csrf}, 409, 'AUTH_CONTEXT_MISMATCH', 'missing-context'),
        ({**confirmed, **origin, 'X-Auth-Context-Id': str(uuid4()), 'X-CSRF-Token': csrf}, 409, 'AUTH_CONTEXT_MISMATCH', 'wrong-context'),
    ):
        status, metadata, body = request(port, 'POST', '/auth/logout', headers=mutation_headers)
        expect(status == expected_status and has_error_only_payload(body, expected_code)
               and not header(metadata, 'set-cookie'), 'logout-denied-' + label, checks)
        status, _, body = request(port, 'GET', '/me', headers=confirmed)
        expect(status == 200 and body['id'] == str(user_ids[0]), 'logout-denied-' + label + '-authority-retained', checks)
    status, app_headers, app = request(port, "POST", "/auth/login", {**login_body, "clientType": "ANDROID"})
    expect(status == 200 and app.get("token") and not header(app_headers, "set-cookie") and not header(app_headers, "x-auth-context-id"), "android-bearer-without-cookie", checks)
    expect(has_login_projection(app, app_headers, 'ANDROID', emails[0], user_ids[0], False), 'android-full-login-exact-projection', checks)
    read_persisted_session(app['token'], user_ids[0], 'ANDROID', False, app['expiresAt'])
    checks.append('android-session-protected-digest-metadata-ttl')
    bearer = {"Authorization": "Bearer " + app["token"]}
    status, ios_headers, ios = request(port, 'POST', '/auth/login', {**login_body, 'clientType': 'IOS'})
    expect(status == 200 and has_login_projection(ios, ios_headers, 'IOS', emails[0], user_ids[0], False), 'ios-full-login-exact-projection', checks)
    read_persisted_session(ios['token'], user_ids[0], 'IOS', False, ios['expiresAt'])
    checks.append('ios-session-protected-digest-metadata-ttl')
    ios_bearer = {'Authorization': 'Bearer ' + ios['token']}
    status, _, profile = request(port, 'GET', '/me', headers=ios_bearer)
    expect(status == 200 and profile == {'id': str(user_ids[0]), 'email': emails[0], 'mustChangePassword': False,
                                      'displayTimezone': 'UTC', 'preferencesRevision': 1}, 'ios-full-protected-profile-exact', checks)
    status, _, _ = request(port, 'GET', '/me', headers={'Cookie': 'iot_session=' + ios['token']})
    expect(status == 401, 'ios-token-not-accepted-as-cookie', checks)
    # Session immutable nên tạo row fixture hết hạn riêng từ identity IOS vừa xác minh, giữ nguyên session đang sống.
    # User UUID bind qua psql; run UUID chuẩn hóa và digest hex nội bộ mới được chèn literal, không nhận SQL từ ngoài.
    # Raw token chỉ được băm trong RAM, không truyền vào SQL hoặc report.
    expiry_digest = hashlib.sha256(ios['token'].encode('utf-8')).hexdigest()
    expiry_run_id = str(UUID(str(run_id)))
    expired_token = secrets.token_hex(32)
    expired_digest = hashlib.sha256(expired_token.encode('utf-8')).hexdigest()
    expired_session_id = str(uuid4())
    expired_context_id = str(uuid4())
    expiry_statement = """WITH expiry_clock AS (
        SELECT transaction_timestamp()-interval '1 hour' AS expiry
      ), changed AS (
        INSERT INTO sessions(session_id,user_id,token_digest,auth_context_id,limited,client_type,issued_at,expires_at)
        SELECT '""" + expired_session_id + """'::uuid,s.user_id,decode('""" + expired_digest + """','hex'),
               '""" + expired_context_id + """'::uuid,s.limited,s.client_type,c.expiry-interval '24 hours',c.expiry
        FROM sessions s,users u,expiry_clock c
        WHERE s.user_id=u.user_id AND u.user_id=:'auth_fault_user_id'::uuid
          AND u.activation_provenance='AUTH_HTTP_LAB:""" + expiry_run_id + """'
          AND u.email_normalized='probe-""" + expiry_run_id + """-0@example.invalid'
          AND s.client_type='IOS' AND s.revoked_at IS NULL
          AND s.token_digest=decode('""" + expiry_digest + """','hex') RETURNING session_id
      ) SELECT count(*) FROM changed;"""
    expiry_result = lab.sql(expiry_statement, database='iot_platform_lab', check=False,
                           variables=(('auth_fault_user_id', str(UUID(str(user_ids[0])))),))
    expect(expiry_result.returncode == 0 and expiry_result.stdout.strip() == '1',
           'owned-ios-expired-session-fixture-inserted', checks)
    status, _, expired_body = request(port, 'GET', '/me', headers={'Authorization': 'Bearer ' + expired_token})
    expect(status == 401 and has_error_only_payload(expired_body, 'SESSION_EXPIRED'),
           'expired-session-http-denied-error-only', checks)
    status, _, _ = request(port, "GET", "/me", headers={**confirmed, **bearer})
    expect(status == 400, "mixed-credential-rejected", checks)
    status, _, _ = request(port, "GET", "/me", headers={"Authorization": "Bearer " + cookie.split(";", 1)[0].split("=", 1)[1]})
    expect(status == 401, "web-token-not-accepted-as-bearer", checks)
    status, _, _ = request(port, "GET", "/me", headers={"Cookie": "iot_session=" + app["token"]})
    expect(status == 401, "android-token-not-accepted-as-cookie", checks)
    status, _, _ = request(port, "POST", "/auth/logout", headers={**confirmed, **origin, "X-CSRF-Token": csrf})
    expect(status == 204, "web-logout-committed", checks)
    status, _, _ = request(port, "POST", "/auth/logout", headers={**confirmed, **origin, "X-CSRF-Token": csrf})
    expect(status == 204, "web-logout-idempotent", checks)
    status, _, _ = request(port, "GET", "/me", headers=bearer)
    expect(status == 200, "web-logout-keeps-android-session", checks)
    for index, label in [(2, "limited"), (3, "empty")]:
        status, headers, body = request(port, "POST", "/auth/login", {**login_body, "email": emails[index]}, origin)
        expect(status == 200, label + "-login", checks)
        expect(has_login_projection(body, headers, 'WEB', emails[index], user_ids[index], index == 2), label + '-web-login-exact-projection', checks)
        session_headers = {"Cookie": header(headers, "set-cookie").split(";", 1)[0], "X-Auth-Context-Id": header(headers, "x-auth-context-id")}
        status, _, body = request(port, "GET", "/workspaces", headers=session_headers)
        expect((status == 403 and has_error_only_payload(body, 'PASSWORD_CHANGE_REQUIRED')) if index == 2 else (status == 200 and body == {"items": [], "nextCursor": None}), label + "-guard-or-empty", checks)
        if index == 2:
            status, app_headers, limited = request(port, 'POST', '/auth/login', {**login_body, 'email': emails[index], 'clientType': 'IOS'})
            expect(status == 200 and has_login_projection(limited, app_headers, 'IOS', emails[index], user_ids[index], True), 'ios-limited-login-no-authority-projection', checks)
            read_persisted_session(limited['token'], user_ids[index], 'IOS', True, limited['expiresAt'])
            checks.append('ios-limited-session-protected-digest-metadata-ttl')
            limited_bearer = {'Authorization': 'Bearer ' + limited['token']}
            for protected_path in ('/me', '/workspaces', '/devices'):
                status, _, body = request(port, 'GET', protected_path, headers=limited_bearer)
                expect(status == 403 and has_error_only_payload(body, 'PASSWORD_CHANGE_REQUIRED'), 'ios-limited-' + protected_path[1:] + '-no-authority', checks)
            status, _, body = request(port, 'POST', '/auth/logout', headers=limited_bearer)
            expect(status == 204 and body is None, 'limited-ios-logout-committed', checks)
            status, _, body = request(port, 'GET', '/me', headers=limited_bearer)
            expect(status == 401 and has_error_only_payload(body, 'SESSION_EXPIRED'), 'limited-ios-logout-revoked-only-session', checks)
            status, metadata, body = request(port, "GET", "/me", headers=session_headers)
            expect(status == 403 and has_error_only_payload(body, 'PASSWORD_CHANGE_REQUIRED') and header(metadata, "x-auth-context-id") == session_headers["X-Auth-Context-Id"] and header(metadata, "x-csrf-token"), "limited-confirmation-no-profile", checks)
            status, _, body = request(port, "GET", "/devices", headers=session_headers)
            # Chốt error-only payload để status403 không che việc vô tình serialize dữ liệu resource.
            expect(status == 403 and has_error_only_payload(body, 'PASSWORD_CHANGE_REQUIRED'),
                   "limited-resource-guard", checks)
            verify_password_flow(port, emails[index], password, session_headers, header(metadata, "x-csrf-token"), user_ids[index], checks)
            status, _, _ = request(port, "GET", "/me", headers=bearer)
            expect(status == 200, "password-change-keeps-other-account-session", checks)
        else:
            # Empty account có session full nhưng không có membership A đã biết tồn tại, không dùng UUID ngẫu nhiên.
            status, _, body = request(port, 'GET', '/workspaces/' + workspace_id, headers=session_headers)
            expect(status == 404 and has_error_only_payload(body, 'RESOURCE_NOT_FOUND'),
                   'empty-account-known-workspace-denied-no-data', checks)
    invalid_projections = []
    # Chỉ một disabled failure mới để giữ nguyên budget năm failure của user-fence chạy sau baseline.
    for index, candidate, label in ((0, 'wrong-synthetic-password', 'known-wrong'), (1, password, 'disabled')):
        status, headers, body = request(port, 'POST', '/auth/login', {**login_body, 'email': emails[index], 'password': candidate, 'clientType': 'ANDROID'})
        expect(status == 401 and has_error_only_payload(body, 'AUTH_INVALID')
               and all(header(headers, name) is None for name in ('set-cookie', 'x-auth-context-id', 'x-csrf-token')),
               label + '-exact-public-invalid-projection', checks)
        invalid_projections.append({key: value for key, value in body['error'].items() if key != 'correlationId'})
    for attempt in range(6):
        # Rate key hiện hành chỉ dùng canonical email; thay IP/proxy tự khai và client không mở key mới.
        client = ('WEB', 'ANDROID', 'IOS')[attempt % 3]
        forwarded = {**origin, 'X-Forwarded-For': '198.51.100.' + str(attempt + 1),
                     'Forwarded': 'for=198.51.100.' + str(attempt + 1) + ';proto=https'}
        status, headers, body = request(port, "POST", "/auth/login", {**login_body, "email": f"probe-{run_id}-unknown@example.invalid", "password": "wrong-synthetic-password", "clientType": client}, forwarded)
        expect(status == (401 if attempt < 5 else 429) and not header(headers, "set-cookie"), f"shared-limiter-attempt-{attempt + 1}", checks)
        expect(has_error_only_payload(body, 'AUTH_INVALID' if attempt < 5 else 'RATE_LIMITED'), f'shared-limiter-exact-envelope-{attempt + 1}', checks)
        if attempt == 0:
            invalid_projections.append({key: value for key, value in body['error'].items() if key != 'correlationId'})
    expect(header(headers, "retry-after") is not None, "rate-limit-retry-after", checks)
    expect(invalid_projections[0] == invalid_projections[1] == invalid_projections[2], 'public-auth-invalid-projection-equivalent', checks)
    checks.append('forged-forwarded-and-client-change-share-limiter-key')
    return checks
