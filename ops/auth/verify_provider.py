"""Kiểm HTTP và PostgreSQL thật bằng fixture của launcher; không in credential/cookie/body."""

import base64
import http.client
import hashlib
import json
import re
import secrets
import socket
import struct
import time
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


def build_masked_websocket_frame(opcode, payload):
    """Dựng frame client có mask chuẩn RFC6455 cho probe realtime loopback.

    Input
    Param: opcode — loại frame literal của verifier, chỉ text hoặc close.
    Param: payload — byte fixture trong RAM, không được ghi log hay report.
    Output: frame đã mask bằng nonce mới cho từng lần gửi.
    Errors: ValueError cố định nếu opcode/payload vượt giới hạn probe.
    """
    if opcode not in (1, 8) or not isinstance(payload, bytes) or len(payload) > 125:
        raise ValueError('Invalid WebSocket test frame')
    masking_key = secrets.token_bytes(4)
    # RFC6455 yêu cầu client mask từng byte bằng key ngẫu nhiên mới; ticket không được gửi nguyên dạng.
    masked_payload = bytes(value ^ masking_key[index % 4] for index, value in enumerate(payload))
    return bytes((0x80 | opcode, 0x80 | len(payload))) + masking_key + masked_payload


def receive_websocket_bytes(connection, size):
    """Đọc đúng kích thước cố định từ WebSocket mà không phản chiếu dữ liệu thô khi lỗi.

    Input
    Param: connection — socket loopback đã upgrade thuộc probe đang chạy.
    Param: size — số byte header/payload đã được parser giới hạn trước.
    Output: bytes đủ kích thước.
    Errors: RuntimeError tĩnh nếu peer đóng sớm hoặc timeout.
    """
    result = bytearray()
    try:
        while len(result) < size:
            chunk = connection.recv(size - len(result))
            if not chunk:
                raise RuntimeError('Realtime WebSocket ended early')
            result.extend(chunk)
    except (OSError, TimeoutError):
        raise RuntimeError('Realtime WebSocket read failed') from None
    return bytes(result)


def receive_websocket_frame(connection):
    """Đọc một frame server với payload bị giới hạn để kiểm ACK/close mà không log nội dung tùy ý.

    Input
    Param: connection — socket loopback đã upgrade thuộc probe đang chạy.
    Output: opcode và payload server-to-client chưa mask.
    Errors: RuntimeError tĩnh nếu frame sai định dạng, vượt cận hoặc peer lỗi.
    """
    header_bytes = receive_websocket_bytes(connection, 2)
    first_byte, second_byte = header_bytes
    if first_byte & 0x70 or not first_byte & 0x80 or second_byte & 0x80:
        raise RuntimeError('Realtime WebSocket frame invalid')
    # Chỉ server trả unmasked frame; cận payload trước khi đọc ngăn test helper cấp phát từ length bất thường.
    payload_size = second_byte & 0x7F
    if payload_size == 126:
        payload_size = struct.unpack('!H', receive_websocket_bytes(connection, 2))[0]
    elif payload_size == 127:
        payload_size = struct.unpack('!Q', receive_websocket_bytes(connection, 8))[0]
    if payload_size > 1024:
        raise RuntimeError('Realtime WebSocket frame exceeds test budget')
    return first_byte & 0x0F, receive_websocket_bytes(connection, payload_size)


def open_authenticated_websocket(port, ticket):
    """Upgrade socket peer rồi xác thực bằng frame ticket đầu tiên trước khi trả connection.

    Input
    Param: port — listener loopback của backend peer do Auth Lab launcher sở hữu.
    Param: ticket — ticket một lần vừa cấp từ fixture, chỉ tồn tại trong RAM probe.
    Output: socket đã nhận đúng ACK AUTHENTICATED sau khi peer consume ticket.
    Errors: RuntimeError cố định nếu handshake, accept key, ticket ACK hoặc transport sai.
    Side effects: gửi ticket duy nhất trong masked text frame; không đặt ticket vào URL/header.
    """
    if not isinstance(ticket, str) or not re.fullmatch(r'[0-9a-f]{64}', ticket):
        raise RuntimeError('Realtime ticket unavailable')
    connection = None
    try:
        connection = socket.create_connection(('127.0.0.1', port), timeout=5)
        connection.settimeout(5)
        websocket_key = base64.b64encode(secrets.token_bytes(16)).decode('ascii')
        request_bytes = (
            f'GET /api/v1/realtime HTTP/1.1\r\n'
            f'Host: 127.0.0.1:{port}\r\n'
            'Upgrade: websocket\r\n'
            'Connection: Upgrade\r\n'
            f'Sec-WebSocket-Key: {websocket_key}\r\n'
            'Sec-WebSocket-Version: 13\r\n'
            'Origin: http://localhost:5173\r\n\r\n'
        ).encode('ascii')
        connection.sendall(request_bytes)
        response = bytearray()
        while not response.endswith(b'\r\n\r\n'):
            if len(response) >= 16384:
                raise RuntimeError('Realtime WebSocket upgrade headers exceed test budget')
            response.extend(receive_websocket_bytes(connection, 1))
        status_line, *header_lines = response.decode('latin-1').split('\r\n')
        response_headers = {}
        for line in header_lines:
            if ':' in line:
                name, value = line.split(':', 1)
                response_headers[name.strip().lower()] = value.strip()
        expected_accept = base64.b64encode(
            hashlib.sha1((websocket_key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode('ascii')).digest()
        ).decode('ascii')
        # Chấp nhận đúng handshake RFC6455 của listener fixture trước khi gửi capability ticket.
        if (status_line != 'HTTP/1.1 101 Switching Protocols'
                or response_headers.get('sec-websocket-accept') != expected_accept):
            raise RuntimeError('Realtime WebSocket upgrade rejected')
        connection.sendall(build_masked_websocket_frame(1, ticket.encode('ascii')))
        opcode, payload = receive_websocket_frame(connection)
        if opcode != 1 or payload != b'AUTHENTICATED':
            raise RuntimeError('Realtime WebSocket authentication rejected')
        connection.settimeout(None)
        return connection
    except (OSError, UnicodeError, ValueError, RuntimeError):
        if connection is not None:
            connection.close()
        raise RuntimeError('Realtime WebSocket probe failed') from None


def websocket_closed_within(connection, timeout_seconds):
    """Kiểm peer đã gửi terminal close/EOF trong ngân sách mà không làm lộ frame hoặc socket error.

    Input
    Param: connection — socket S1 đã xác thực trên backend peer.
    Param: timeout_seconds — ngân sách hữu hạn do verifier quyết định.
    Output: opcode, close code/reason an toàn và thời lượng; None khi không close kịp.
    """
    started = time.monotonic()
    connection.settimeout(timeout_seconds)
    try:
        opcode, payload = receive_websocket_frame(connection)
    except RuntimeError:
        return None
    elapsed = time.monotonic() - started
    if opcode != 8 or len(payload) < 2:
        return None
    try:
        reason = payload[2:].decode('utf-8')
    except UnicodeError:
        return None
    return struct.unpack('!H', payload[:2])[0], reason, elapsed


def websocket_stays_open(connection, timeout_seconds):
    """Xác nhận socket S2 không nhận close/EOF trong thời gian đối chiếu S1 trên peer.

    Input
    Param: connection — socket Android S2 đã xác thực trên cùng backend peer.
    Param: timeout_seconds — khoảng quan sát hữu hạn cho chu kỳ reconciler.
    Output: true nếu không có frame hoặc EOF trong cửa sổ quan sát.
    Side effects: tạm đặt timeout đọc cho socket do verifier sở hữu.
    """
    connection.settimeout(timeout_seconds)
    try:
        connection.recv(1)
        return False
    except TimeoutError:
        return True
    except OSError:
        return False


def close_websocket_probe(connection):
    """Gửi close frame chuẩn cho socket verifier còn mở để dọn registry không thuộc acceptance.

    Input
    Param: connection — socket local do verifier tạo, có thể đã nhận close từ server.
    Side effects: gửi mã close 1000 khi transport còn mở rồi luôn đóng handle cục bộ.
    """
    try:
        connection.settimeout(0.5)
        connection.sendall(build_masked_websocket_frame(8, struct.pack('!H', 1000)))
    except (OSError, RuntimeError, ValueError):
        pass
    finally:
        connection.close()


def verify_realtime_cross_instance(primary_port, peer_port, web_session_headers,
                                   web_context, web_csrf, workspace_id, android_bearer,
                                   set_session_read_access, checks):
    """Chứng minh peer backend đóng socket Web S1 đã revoke nhưng giữ socket Android S2 cùng account.

    Input
    Param: primary_port — backend xử lý cấp ticket và commit logout.
    Param: peer_port — backend độc lập consume ticket và sở hữu hai socket.
    Param: web_session_headers — cookie Web fixture S1, chỉ dùng trong request có context/CSRF.
    Param: web_context — context ID của đúng S1 đang được thử revoke.
    Param: web_csrf — token CSRF của mutation Web logout.
    Param: workspace_id — workspace Admin fixture còn active trên hai session.
    Param: android_bearer — credential Android S2 cùng account nhưng khác session.
    Param: set_session_read_access — callback fixture chỉ thu hồi/khôi phục SELECT sau ownership check.
    Param: checks — danh sách check ID nội bộ, không chứa credential.
    Output: check IDs chỉ được thêm sau khi socket S1 đóng và S2 còn active trên peer.
    Errors: RuntimeError an toàn nếu API, handshake, close policy hoặc isolation sai.
    Side effects: cấp/consume hai ticket, logout S1 qua primary và đóng probe socket sau kiểm tra.
    """
    web_headers = {
        **web_session_headers,
        'Origin': 'http://localhost:5173',
        'X-Auth-Context-Id': web_context,
        'X-CSRF-Token': web_csrf,
        'X-Workspace-Id': workspace_id,
    }
    status, web_ticket_headers, web_ticket_body = request(
        primary_port, 'POST', '/realtime/tickets', headers=web_headers)
    expect(status == 201 and isinstance(web_ticket_body, dict)
           and set(web_ticket_body) == {'ticket', 'expiresAt'}
           and header(web_ticket_headers, 'cache-control') == 'no-store'
           and isinstance(web_ticket_body.get('ticket'), str)
           and re.fullmatch(r'[0-9a-f]{64}', web_ticket_body['ticket']) is not None,
           'realtime-cross-instance-web-ticket-issued', checks)
    android_headers = {**android_bearer, 'X-Workspace-Id': workspace_id}
    status, android_ticket_headers, android_ticket_body = request(
        primary_port, 'POST', '/realtime/tickets', headers=android_headers)
    expect(status == 201 and isinstance(android_ticket_body, dict)
           and set(android_ticket_body) == {'ticket', 'expiresAt'}
           and header(android_ticket_headers, 'cache-control') == 'no-store'
           and isinstance(android_ticket_body.get('ticket'), str)
           and re.fullmatch(r'[0-9a-f]{64}', android_ticket_body['ticket']) is not None,
           'realtime-cross-instance-android-ticket-issued', checks)

    web_socket = None
    android_socket = None
    try:
        web_socket = open_authenticated_websocket(peer_port, web_ticket_body['ticket'])
        android_socket = open_authenticated_websocket(peer_port, android_ticket_body['ticket'])
        checks.append('realtime-tickets-consumed-by-independent-peer')
        status, _, body = request(primary_port, 'POST', '/auth/logout', headers=web_headers)
        expect(status == 204 and body is None, 'realtime-cross-instance-web-logout-committed', checks)
        # Peer chỉ tự đối soát DB, không nhận close signal từ primary; cửa sổ5giây bao hai chu kỳ poll.
        close_result = websocket_closed_within(web_socket, 5)
        expect(close_result is not None and close_result[0] == 1008
               and close_result[1] == 'Authentication required.'
               and close_result[2] <= 5,
               'realtime-peer-reconciles-revoked-session-within-policy', checks)
        # Chờ hơn một chu kỳ reconciler để chắc phiên Android active không bị đóng nhầm cùng account.
        expect(websocket_stays_open(android_socket, 1.25),
               'realtime-peer-retains-other-active-session', checks)
        try:
            set_session_read_access(False)
            # Session S2 vẫn active; chỉ worker query bị từ chối vì ACL fixture vừa thu hồi.
            database_failure_close = websocket_closed_within(android_socket, 5)
            expect(database_failure_close is not None and database_failure_close[0] == 1008
                   and database_failure_close[1] == 'Authentication required.'
                   and database_failure_close[2] <= 5,
                   'realtime-peer-database-failure-closes-local-socket-fail-closed', checks)
        finally:
            set_session_read_access(True)
        status, _, profile = request(primary_port, 'GET', '/me', headers=android_bearer)
        expect(status == 200 and profile.get('id'),
               'realtime-peer-db-recovery-preserves-android-session-authority', checks)
    finally:
        if web_socket is not None:
            close_websocket_probe(web_socket)
        if android_socket is not None:
            close_websocket_probe(android_socket)


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
                                 'CSRF_INVALID', 'SESSION_EXPIRED', 'SESSION_REVOKED', 'RATE_LIMITED',
                                 'CURSOR_INVALID', 'SERVICE_UNAVAILABLE'),
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


def read_logout_audit_rows(user_id, session_ids):
    """Đọc payload audit logout của đúng các session fixture để scanner kiểm credential trong RAM.

    Input
    Param: user_id — UUID account fixture, giới hạn quyền sở hữu của các audit row.
    Param: session_ids — đúng hai UUID session vừa logout, không nhận selector tùy ý từ CLI.
    Output: bytes JSON bounded đã xác thực event, outcome, actor và tập session.
    Errors: lỗi SQL, budget, schema hoặc selector trả một mã lỗi cố định, không phản chiếu row.
    """
    import verify_database as lab
    from verify_security_evidence import MAX_SINK_BYTES

    identity = str(UUID(str(user_id)))
    sessions = tuple(str(UUID(str(value))) for value in session_ids)
    if len(sessions) != 2 or len(set(sessions)) != 2:
        raise RuntimeError('Logout audit selector rejected')
    # Chỉ đọc event của account/session fixture; UUID truyền qua psql variables để tránh nối dữ liệu vào SQL.
    statement = """BEGIN READ ONLY;
SET LOCAL statement_timeout='10s';
SET LOCAL lock_timeout='3s';
WITH target AS (
    SELECT string_to_array(:'auth_fault_session_ids', ',')::uuid[] AS ids
), bounded_rows AS (
    SELECT coalesce(jsonb_agg(to_jsonb(owned) ORDER BY owned.session_id), '[]'::jsonb) AS payload
    FROM (
        SELECT audit.* FROM audit_events audit, target
        WHERE audit.actor_user_id=:'auth_fault_user_id'::uuid
          AND audit.session_id=ANY(target.ids)
          AND audit.event_type='LOGOUT' AND audit.outcome='SUCCESS'
        ORDER BY audit.session_id LIMIT 3
    ) owned
)
SELECT CASE WHEN octet_length(payload::text) <= """ + str(MAX_SINK_BYTES) + """ THEN payload::text
       ELSE 'AUDIT_SCAN_BUDGET_EXCEEDED' END
FROM bounded_rows;
COMMIT;"""
    result = lab.sql(
        statement,
        role=lab.ADMIN,
        database='iot_platform_lab',
        check=False,
        variables=(('auth_fault_user_id', identity),
                   ('auth_fault_session_ids', ','.join(sessions))),
    )
    try:
        if result.returncode != 0 or type(result.stdout) is not str:
            raise ValueError()
        payload = result.stdout.strip().encode('utf-8')
        rows = json.loads(payload) if 0 < len(payload) <= MAX_SINK_BYTES else None
        valid = (
            type(rows) is list and len(rows) == 2
            and {row['session_id'] for row in rows} == set(sessions)
            and all(row['actor_user_id'] == identity and row['event_type'] == 'LOGOUT'
                    and row['outcome'] == 'SUCCESS' for row in rows)
        )
        if valid:
            return payload
    except (ValueError, TypeError, KeyError, AttributeError, UnicodeDecodeError):
        pass
    raise RuntimeError('Logout audit lookup failed')


def read_logout_session_snapshot(user_id, web_session_id, android_survivor_session_id,
                                 android_logout_session_id, survivor_installation_id, installation_id):
    """Đọc trạng thái ba session, audit, outbox và push binding trong một snapshot chỉ đọc.

    Input
    Param: user_id — UUID account tổng hợp sở hữu ba session.
    Param: web_session_id — UUID session Web bị revoke đầu tiên.
    Param: android_survivor_session_id — UUID Android S2 phải còn active sau logout Web.
    Param: android_logout_session_id — UUID Android S3 dùng kiểm retry logout.
    Param: survivor_installation_id — UUID installation giả được ràng buộc với Android S2.
    Param: installation_id — UUID installation giả được ràng buộc với Android S3.
    Output: các cờ/count hữu hạn; không trả identity, credential, digest hoặc row thô.
    Errors: RuntimeError cố định nếu SQL, schema hoặc projection không đúng.
    """
    import verify_database as lab

    identity = str(UUID(str(user_id)))
    web_session = str(UUID(str(web_session_id)))
    android_survivor = str(UUID(str(android_survivor_session_id)))
    android_logout = str(UUID(str(android_logout_session_id)))
    survivor_installation = str(UUID(str(survivor_installation_id)))
    installation = str(UUID(str(installation_id)))
    # Đọc một MVCC snapshot chỉ gồm cờ/count; mọi UUID đi qua psql variable đã kiểm kiểu, không nối vào SQL.
    statement = """BEGIN READ ONLY;
SET LOCAL statement_timeout='10s';
SET LOCAL lock_timeout='3s';
WITH target AS (
    SELECT string_to_array(:'auth_fault_session_ids', ',')::uuid[] AS ids
)
SELECT json_build_object(
    'webRevoked', coalesce((SELECT s.revoked_at IS NOT NULL FROM sessions s, target
        WHERE s.session_id=target.ids[1] AND s.user_id=:'auth_fault_user_id'::uuid AND s.client_type='WEB'), false),
    'androidSurvivorRevoked', coalesce((SELECT s.revoked_at IS NOT NULL FROM sessions s, target
        WHERE s.session_id=target.ids[2] AND s.user_id=:'auth_fault_user_id'::uuid AND s.client_type='ANDROID'), false),
    'androidLogoutRevoked', coalesce((SELECT s.revoked_at IS NOT NULL FROM sessions s, target
        WHERE s.session_id=target.ids[3] AND s.user_id=:'auth_fault_user_id'::uuid AND s.client_type='ANDROID'), false),
    'webAuditCount', (SELECT count(*) FROM audit_events a, target WHERE a.actor_user_id=:'auth_fault_user_id'::uuid
        AND a.session_id=target.ids[1] AND a.event_type='LOGOUT' AND a.outcome='SUCCESS'),
    'androidSurvivorAuditCount', (SELECT count(*) FROM audit_events a, target WHERE a.actor_user_id=:'auth_fault_user_id'::uuid
        AND a.session_id=target.ids[2] AND a.event_type='LOGOUT' AND a.outcome='SUCCESS'),
    'androidLogoutAuditCount', (SELECT count(*) FROM audit_events a, target WHERE a.actor_user_id=:'auth_fault_user_id'::uuid
        AND a.session_id=target.ids[3] AND a.event_type='LOGOUT' AND a.outcome='SUCCESS'),
    'webOutboxCount', (SELECT count(*) FROM outbox_events e, target WHERE e.event_type='SESSION_REVOKED'
        AND e.payload->>'sessionId'=target.ids[1]::text AND e.payload->>'userId'=:'auth_fault_user_id'),
    'androidSurvivorOutboxCount', (SELECT count(*) FROM outbox_events e, target WHERE e.event_type='SESSION_REVOKED'
        AND e.payload->>'sessionId'=target.ids[2]::text AND e.payload->>'userId'=:'auth_fault_user_id'),
    'androidLogoutOutboxCount', (SELECT count(*) FROM outbox_events e, target WHERE e.event_type='SESSION_REVOKED'
        AND e.payload->>'sessionId'=target.ids[3]::text AND e.payload->>'userId'=:'auth_fault_user_id'),
    'pushBoundToSurvivorAndroid', (SELECT count(*)=1 FROM push_installations p, target
        WHERE p.installation_id=:'auth_fault_survivor_installation_id'::uuid AND p.active_user_id=:'auth_fault_user_id'::uuid
        AND p.active_session_id=target.ids[2] AND p.binding_generation=1 AND p.enabled=false),
    'pushBoundToLogoutAndroid', (SELECT count(*)=1 FROM push_installations p, target
        WHERE p.installation_id=:'auth_fault_installation_id'::uuid AND p.active_user_id=:'auth_fault_user_id'::uuid
        AND p.active_session_id=target.ids[3] AND p.binding_generation=1 AND p.enabled=false),
    'pushUnbound', (SELECT count(*)=1 FROM push_installations p
        WHERE p.installation_id=:'auth_fault_installation_id'::uuid AND p.active_user_id IS NULL
        AND p.active_session_id IS NULL AND p.binding_generation=2 AND p.enabled=false)
) FROM target;
COMMIT;"""
    result = lab.sql(
        statement,
        role=lab.ADMIN,
        database='iot_platform_lab',
        check=False,
        variables=(
            ('auth_fault_user_id', identity),
            ('auth_fault_session_ids', ','.join((web_session, android_survivor, android_logout))),
            ('auth_fault_survivor_installation_id', survivor_installation),
            ('auth_fault_installation_id', installation),
        ),
    )
    try:
        snapshot = json.loads(result.stdout.strip()) if result.returncode == 0 and len(result.stdout) <= 2048 else None
        expected_keys = {
            'webRevoked', 'androidSurvivorRevoked', 'androidLogoutRevoked',
            'webAuditCount', 'androidSurvivorAuditCount', 'androidLogoutAuditCount',
            'webOutboxCount', 'androidSurvivorOutboxCount', 'androidLogoutOutboxCount',
            'pushBoundToSurvivorAndroid', 'pushBoundToLogoutAndroid', 'pushUnbound',
        }
        boolean_keys = ('webRevoked', 'androidSurvivorRevoked', 'androidLogoutRevoked',
                        'pushBoundToSurvivorAndroid', 'pushBoundToLogoutAndroid', 'pushUnbound')
        count_keys = ('webAuditCount', 'androidSurvivorAuditCount', 'androidLogoutAuditCount',
                      'webOutboxCount', 'androidSurvivorOutboxCount', 'androidLogoutOutboxCount')
        if (not isinstance(snapshot, dict) or set(snapshot) != expected_keys
                or any(type(snapshot[key]) is not bool for key in boolean_keys)
                or any(type(snapshot[key]) is not int for key in count_keys)):
            raise ValueError()
        return snapshot
    except (ValueError, TypeError, AttributeError):
        raise RuntimeError('Logout PostgreSQL readback failed') from None


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


def verify_logout_session_scope(port, peer_port, cookie_header, context, csrf, workspace_id,
                                android_headers, user_id, email, password, web_session_id,
                                android_session_id, set_session_read_access, checks):
    """Chứng minh revoke Web chỉ đổi S1, retry Android riêng idempotent và DB giữ binding chính xác.

    Input
    Param: port — backend primary trong Auth Lab fixture do launcher sở hữu.
    Param: peer_port — backend độc lập dùng để xác nhận socket S1 đóng qua DB reconcile.
    Param: cookie_header — cookie Web S1 giữ trong RAM để kiểm logout và mutation stale.
    Param: context — metadata context Web S1 bắt buộc cho mutation.
    Param: csrf — token CSRF Web S1 dùng cùng origin đã xác minh.
    Param: workspace_id — workspace A đã xác minh, chỉ cấp scope cho realtime ticket.
    Param: android_headers — bearer Android S2 phải tiếp tục sống sau khi Web S1 bị revoke.
    Param: user_id — UUID fixture sở hữu ba session và installation giả.
    Param: email — email tổng hợp account0 để mở Android S3 độc lập.
    Param: password — password tổng hợp chỉ dùng cho login/mutation, không ghi log.
    Param: web_session_id — UUID Web S1 đã xác minh với row durable.
    Param: android_session_id — UUID Android S2 giữ lại cho các kiểm tra provider phía sau.
    Param: set_session_read_access — fault control thuộc fixture để kiểm fail-closed của peer.
    Param: checks — marker tĩnh được đưa vào provider evidence, không có identity hoặc credential.
    Output: hoàn tất oracle logout Web/Android hoặc ném lỗi cố định tại invariant sai.
    Side effects: tạo rồi xóa hai push installation disabled; revoke Web S1 và Android S3 tổng hợp; scan audit logout trong RAM.
    """
    import verify_database as lab

    identity = str(UUID(str(user_id)))
    web_session = str(UUID(str(web_session_id)))
    android_survivor = str(UUID(str(android_session_id)))
    survivor_installation_id = str(uuid4())
    installation_id = str(uuid4())
    inserted = False
    try:
        # Tạo Android S3 riêng để retry logout không làm mất S2 mà các provider check sau còn dùng.
        status, sibling_headers, sibling = request(
            port, 'POST', '/auth/login',
            {'email': email, 'password': password, 'clientType': 'ANDROID'},
        )
        expect(status == 200 and has_login_projection(sibling, sibling_headers, 'ANDROID', email, user_id, False),
               'logout-android-retry-session-created', checks)
        android_logout_session = str(read_persisted_session(
            sibling['token'], user_id, 'ANDROID', False, sibling['expiresAt'],
        ))
        android_logout_headers = {'Authorization': 'Bearer ' + sibling['token']}
        session_ids = ','.join((web_session, android_survivor, android_logout_session))
        variables = (
            ('auth_fault_user_id', identity),
            ('auth_fault_session_ids', session_ids),
            ('auth_fault_survivor_installation_id', survivor_installation_id),
            ('auth_fault_installation_id', installation_id),
        )
        # Hai installation giả không có provider token và bị disable; mỗi binding theo session kiểm tra đúng đường revoke.
        insert_statement = """WITH target AS (
    SELECT string_to_array(:'auth_fault_session_ids', ',')::uuid[] AS ids
), candidates AS (
    SELECT :'auth_fault_survivor_installation_id'::uuid AS installation_id, ids[2] AS session_id FROM target
    UNION ALL
    SELECT :'auth_fault_installation_id'::uuid, ids[3] FROM target
), inserted AS (
    INSERT INTO push_installations(
    installation_id,installation_proof_digest,platform,binding_generation,client_sequence,
    permission_state,enabled,active_user_id,active_session_id)
    SELECT candidate.installation_id,decode(repeat('00',32),'hex'),'ANDROID',1,1,
           'NOT_DETERMINED',false,:'auth_fault_user_id'::uuid,candidate.session_id
    FROM candidates candidate
    WHERE EXISTS(SELECT 1 FROM sessions s WHERE s.session_id=candidate.session_id
        AND s.user_id=:'auth_fault_user_id'::uuid AND s.client_type='ANDROID' AND s.revoked_at IS NULL)
    RETURNING installation_id::text
)
SELECT string_agg(installation_id, ',' ORDER BY installation_id) FROM inserted;"""
        result = lab.sql(insert_statement, role=lab.ADMIN, database='iot_platform_lab', check=False,
                         variables=variables)
        inserted_ids = ','.join(sorted((survivor_installation_id, installation_id)))
        inserted = result.returncode == 0
        expect(inserted and result.stdout.strip() == inserted_ids,
               'logout-push-binding-fixture-created', checks)

        baseline = read_logout_session_snapshot(
            identity, web_session, android_survivor, android_logout_session,
            survivor_installation_id, installation_id,
        )
        expect(not baseline['webRevoked'] and not baseline['androidSurvivorRevoked']
               and not baseline['androidLogoutRevoked']
               and baseline['webAuditCount'] == baseline['androidSurvivorAuditCount'] == baseline['androidLogoutAuditCount'] == 0
               and baseline['webOutboxCount'] == baseline['androidSurvivorOutboxCount'] == baseline['androidLogoutOutboxCount'] == 0
               and baseline['pushBoundToSurvivorAndroid'] and baseline['pushBoundToLogoutAndroid']
               and not baseline['pushUnbound'],
               'logout-session-and-push-baseline-exact', checks)

        verify_realtime_cross_instance(port, peer_port, cookie_header, context, csrf,
                                       workspace_id, android_headers,
                                       set_session_read_access, checks)
        origin = {'Origin': 'http://localhost:5173'}
        confirmed = {**cookie_header, 'X-Auth-Context-Id': context}
        web_mutation_headers = {**confirmed, **origin, 'X-CSRF-Token': csrf}
        for check_id in ('web-logout-idempotent', 'web-logout-retry-idempotent'):
            status, _, body = request(port, 'POST', '/auth/logout', headers=web_mutation_headers)
            expect(status == 204 and body is None, check_id, checks)
        status, _, body = request(
            port,
            'POST',
            '/auth/password',
            {'currentPassword': password, 'newPassword': 'Aa2' + secrets.token_hex(16)},
            web_mutation_headers,
        )
        expect(status == 401 and has_error_only_payload(body, 'SESSION_REVOKED'),
               'web-revoked-protected-mutation-denied', checks)
        status, _, profile = request(port, 'GET', '/me', headers=android_headers)
        expect(status == 200 and profile.get('id') == identity,
               'web-logout-keeps-android-session', checks)

        web_only = read_logout_session_snapshot(
            identity, web_session, android_survivor, android_logout_session,
            survivor_installation_id, installation_id,
        )
        expect(web_only['webRevoked'] and not web_only['androidSurvivorRevoked']
               and not web_only['androidLogoutRevoked'],
               'logout-db-only-web-session-revoked', checks)
        expect(web_only['webAuditCount'] == 1 and web_only['androidSurvivorAuditCount'] == 0
               and web_only['androidLogoutAuditCount'] == 0
               and web_only['webOutboxCount'] == 1 and web_only['androidSurvivorOutboxCount'] == 0
               and web_only['androidLogoutOutboxCount'] == 0,
               'logout-db-web-audit-outbox-exact', checks)
        expect(web_only['pushBoundToSurvivorAndroid'] and web_only['pushBoundToLogoutAndroid']
               and not web_only['pushUnbound'],
               'logout-db-web-keeps-both-android-push-bindings', checks)

        status, _, body = request(port, 'POST', '/auth/logout', headers=android_logout_headers)
        expect(status == 204 and body is None, 'android-sibling-logout-committed', checks)
        status, _, body = request(port, 'POST', '/auth/logout', headers=android_logout_headers)
        expect(status == 204 and body is None, 'android-sibling-logout-idempotent', checks)
        status, _, body = request(port, 'GET', '/me', headers=android_logout_headers)
        expect(status == 401 and has_error_only_payload(body, 'SESSION_REVOKED'),
               'android-sibling-revoked-after-logout', checks)
        status, _, body = request(port, 'GET', '/me', headers=confirmed)
        expect(status == 401 and has_error_only_payload(body, 'SESSION_REVOKED'),
               'web-session-remains-revoked-after-android-logout', checks)
        status, _, profile = request(port, 'GET', '/me', headers=android_headers)
        expect(status == 200 and profile.get('id') == identity,
               'android-survivor-remains-active-after-sibling-logout', checks)

        both_revoked = read_logout_session_snapshot(
            identity, web_session, android_survivor, android_logout_session,
            survivor_installation_id, installation_id,
        )
        expect(both_revoked['webRevoked'] and not both_revoked['androidSurvivorRevoked']
               and both_revoked['androidLogoutRevoked'],
               'logout-db-only-target-sessions-revoked', checks)
        expect(both_revoked['webAuditCount'] == both_revoked['androidLogoutAuditCount'] == 1
               and both_revoked['androidSurvivorAuditCount'] == 0
               and both_revoked['webOutboxCount'] == both_revoked['androidLogoutOutboxCount'] == 1
               and both_revoked['androidSurvivorOutboxCount'] == 0,
               'logout-db-one-audit-and-outbox-per-revoked-session', checks)
        expect(both_revoked['pushBoundToSurvivorAndroid'] and not both_revoked['pushBoundToLogoutAndroid']
               and both_revoked['pushUnbound'],
               'logout-db-only-target-android-push-binding-cleared', checks)

        # Gom credential ngay từ fixture đang chạy để audit scan bao gồm cả cookie Web và hai bearer Android thật.
        if credential_observer is None:
            raise RuntimeError('Logout audit canary unavailable')
        observed_canaries = set(credential_observer.values())
        canaries = {email, password, context, csrf}
        required_observed = {email, password, csrf}
        for headers in (cookie_header, android_headers, android_logout_headers):
            for name in ('Cookie', 'Authorization', 'X-CSRF-Token', 'X-Auth-Context-Id'):
                value = header(headers, name)
                if not value:
                    continue
                canaries.add(value)
                if name.lower() == 'authorization' and value.lower().startswith('bearer '):
                    bearer = value[7:]
                    canaries.add(bearer)
                    required_observed.update((value, bearer))
                elif name.lower() == 'cookie':
                    required_observed.add(value)
                    for item in value.split(';'):
                        _, separator, cookie_value = item.partition('=')
                        if separator and cookie_value.strip():
                            canaries.add(cookie_value.strip())
                            required_observed.add(cookie_value.strip())
                elif name.lower() == 'x-csrf-token':
                    required_observed.add(value)
        if not required_observed.issubset(observed_canaries):
            raise RuntimeError('Logout audit canary unavailable')
        from verify_security_evidence import scan_sink
        audit_payload = read_logout_audit_rows(identity, (web_session, android_logout_session))
        audit_scan = scan_sink('audit', audit_payload, tuple(sorted(canaries)))
        expect(audit_scan['status'] == 'PASS', 'logout-audit-secret-canary-scan', checks)
    finally:
        if inserted:
            # Chỉ xóa đúng hai row có UUID ngẫu nhiên do lượt test này tạo, dù revoke đã bỏ binding account.
            cleanup = lab.sql(
                "WITH deleted AS (DELETE FROM push_installations WHERE installation_id IN (:'auth_fault_survivor_installation_id'::uuid,:'auth_fault_installation_id'::uuid) RETURNING installation_id::text) SELECT string_agg(installation_id, ',' ORDER BY installation_id) FROM deleted;",
                role=lab.ADMIN,
                database='iot_platform_lab',
                check=False,
                variables=(('auth_fault_survivor_installation_id', survivor_installation_id),
                           ('auth_fault_installation_id', installation_id)),
            )
            cleaned_ids = set(cleanup.stdout.strip().split(',')) if cleanup.stdout.strip() else set()
            if (cleanup.returncode != 0
                    or not cleaned_ids.issubset({survivor_installation_id, installation_id})):
                raise RuntimeError('Logout push-binding fixture cleanup failed')


# Một luồng thật xuyên Router→application→SQLx→PostgreSQL, khác với unit test router/pool lazy.
def verify_provider(port, peer_port, emails, password, run_id, user_ids, set_session_read_access):
    """Chạy baseline auth/bootstrap/password thật trên fixture sở hữu để phân biệt provider evidence với mock.

    Input
    Param: port — listener primary loopback của binary do launcher đang sở hữu.
    Param: peer_port — listener backend peer độc lập dùng kiểm ticket và socket reconciliation.
    Param: emails —5email tổng hợp theo thứ tự full/disabled/limited/empty/owner thứ hai.
    Param: password — credential seed trong RAM, không log hoặc ghi evidence.
    Param: run_id — UUID của lượt chạy, giới hạn email unknown và mutation membership vào fixture đó.
    Param: user_ids —5UUID tương ứng để kiểm identity và scope mutation/cleanup.
    Param: set_session_read_access — callback chỉ fault/restore ACL fixture trong probe cross-instance.
    Output: danh sách check ID đã PASS, không chứa dữ liệu HTTP hoặc credential.
    Errors: RuntimeError an toàn ở invariant đầu tiên sai; không tự retry POST hoặc đổi expected.
    Side effects: tạo/revoke session fixture, kiểm push/session/audit readback và provider realtime, thêm session đã hết hạn, kiểm workspace tạm rồi dọn ngay; launcher dọn graph khi kết thúc.
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
    web_session_id = read_persisted_session(cookie.split(';', 1)[0].split('=', 1)[1], user_ids[0], 'WEB', False, body['expiresAt'])
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
    admin_workspace_id = next(item['id'] for item in page['items'] if item['role'] == 'ADMIN')
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
    android_session_id = read_persisted_session(app['token'], user_ids[0], 'ANDROID', False, app['expiresAt'])
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
    verify_logout_session_scope(
        port, peer_port, cookie_header, context, csrf, admin_workspace_id, bearer,
        user_ids[0], emails[0], password, web_session_id, android_session_id,
        set_session_read_access, checks,
    )
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
            # Session vừa logout đã biết là bị thu hồi; không gộp trạng thái này với phiên hết hạn.
            expect(status == 401 and has_error_only_payload(body, 'SESSION_REVOKED'), 'limited-ios-logout-revoked-only-session', checks)
            status, metadata, body = request(port, "GET", "/me", headers=session_headers)
            expect(status == 403 and has_error_only_payload(body, 'PASSWORD_CHANGE_REQUIRED') and header(metadata, "x-auth-context-id") == session_headers["X-Auth-Context-Id"] and header(metadata, "x-csrf-token"), "limited-confirmation-no-profile", checks)
            status, _, body = request(port, "GET", "/devices", headers=session_headers)
            # Chốt error-only payload để status403 không che việc vô tình serialize dữ liệu resource.
            expect(status == 403 and has_error_only_payload(body, 'PASSWORD_CHANGE_REQUIRED'),
                   "limited-resource-guard", checks)
            verify_password_flow(port, emails[index], password, session_headers, header(metadata, "x-csrf-token"), user_ids[index], checks)
            status, _, body = request(port, "GET", "/me", headers=bearer)
            if status != 200:
                # Chỉ phân loại status và error code allowlist để khoanh vùng lỗi mà không lộ body/profile.
                error = body.get('error') if isinstance(body, dict) else None
                error_code = error.get('code') if isinstance(error, dict) else None
                if error_code not in {
                    'AUTH_INVALID', 'SESSION_EXPIRED', 'SESSION_REVOKED', 'SERVICE_UNAVAILABLE',
                }:
                    error_code = 'UNCLASSIFIED'
                raise RuntimeError(
                    'Provider check failed: password-change-keeps-other-account-session-'
                    + str(status) + '-' + error_code
                )
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
