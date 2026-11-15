"""Kiểm DB đã COMMIT nhưng SQLx mất ACK thật, không mô phỏng lỗi bằng core/application hook."""

import time
from dataclasses import dataclass
from uuid import UUID

import verify_database as lab
from verify_provider import expect, header, request


@dataclass(frozen=True)
class CommitSnapshot:
    """Count và UUID fixture chỉ giữ RAM để phân biệt session mới/cũ; không serialize vào evidence."""

    session_count: int
    audit_count: int
    matching_pairs: int
    session_ids: frozenset[UUID]
    matched_session_ids: frozenset[UUID]


def read_snapshot(user_id, client, correlation=None):
    """Đọc committed count và đúng cặp audit/session của request, không xuất row hoặc token digest.

    Input
    Param: user_id — UUID account0 fixture, parse rồi truyền psql variable đã quote.
    Param: client — WEB/ANDROID từ allowlist nội bộ, không là giá trị SQL từ HTTP.
    Param: correlation — UUID error response để ghép đúng event, None chỉ đọc baseline count.
    Output: count cùng UUID session chỉ trong RAM để cặp audit không thể trỏ nhầm session cũ.
    Errors: SQL/count/selector sai được lọc, không xem missing row như commit thành công.
    """
    identity = str(UUID(str(user_id)))
    correlation_value = str(UUID(str(correlation))) if correlation is not None else ''
    # Predicate chỉ lấy từ hai literal nội bộ; selector user/request quote riêng qua psql variables.
    client_predicate = {'WEB': "s.client_type='WEB' AND a.client_type='WEB'", 'ANDROID': "s.client_type='ANDROID' AND a.client_type='ANDROID'"}[client]
    statement = "WITH owned_sessions AS (SELECT session_id FROM sessions WHERE user_id=:'auth_fault_user_id'::uuid),matched AS (SELECT s.session_id FROM audit_events a JOIN sessions s ON s.session_id=a.session_id AND s.user_id=a.actor_user_id WHERE a.actor_user_id=:'auth_fault_user_id'::uuid AND a.correlation_id=ANY(string_to_array(:'auth_fault_correlations',',')::uuid[]) AND a.event_type='LOGIN_SUCCEEDED' AND a.outcome='SUCCESS' AND s.revoked_at IS NULL AND s.expires_at=s.issued_at+interval '24 hours' AND " + client_predicate + ") SELECT (SELECT count(*) FROM owned_sessions),(SELECT count(*) FROM audit_events WHERE actor_user_id=:'auth_fault_user_id'::uuid AND event_type='LOGIN_SUCCEEDED'),(SELECT count(*) FROM matched),coalesce((SELECT string_agg(session_id::text,',') FROM owned_sessions),''),coalesce((SELECT string_agg(session_id::text,',') FROM matched),'');"
    result = lab.sql(statement, role=lab.ADMIN, database='iot_platform_lab', check=False, variables=(('auth_fault_user_id', identity), ('auth_fault_correlations', correlation_value)))
    values = result.stdout.strip().split('|')
    if result.returncode or len(values) != 5 or not all(value.isdigit() for value in values[:3]):
        raise RuntimeError('Commit ACK snapshot read failed')
    session_ids = frozenset(UUID(value) for value in values[3].split(',') if value)
    matched_session_ids = frozenset(UUID(value) for value in values[4].split(',') if value)
    if len(session_ids) != int(values[0]):
        raise RuntimeError('Commit ACK session snapshot incomplete')
    return CommitSnapshot(*map(int, values[:3]), session_ids, matched_session_ids)


def verify_commit_ack(port, email, password, user_id, proxy, checks):
    """Cắt đúng ACK đã xác nhận rồi kiểm HTTP503 cùng orphan committed cho mỗi client.

    Input
    Param: port — listener loopback primary, mọi check trước đã hoàn tất và không có request song song.
    Param: email — account0 synthetic vẫn dùng credential seed.
    Param: password — password TEST trong RAM, không log/lưu hoặc tự retry.
    Param: user_id — UUID fixture cho SELECT count và JOIN correlation/client/session.
    Param: proxy — proxy thuộc launcher với gate nội bộ, không có control endpoint.
    Param: checks — danh sách invariant ID tĩnh dùng evidence không secret.
    Output: hai kết quả chỉ clientType/confirmed/transaction counts, không credential hoặc identity.
    Errors: no-fire/timeout/ACK lọt/duplicate/mismatch đều FAIL; không tự phát login lần hai.
    Side effects: đúng hai orphan session TTL24h, launcher dọn ngay theo ownership sau suite.
    """
    observations = []
    for client, label in [('WEB', 'web'), ('ANDROID', 'android')]:
        before = read_snapshot(user_id, client)
        generation = proxy.gate.arm(time.monotonic())
        try:
            status, headers, body = request(port, 'POST', '/auth/login', {'email': email, 'password': password, 'clientType': client}, {'Origin': 'http://localhost:5173'} if client == 'WEB' else None)
            expect(status == 503 and body['error']['code'] == 'SERVICE_UNAVAILABLE', 'commit-ack-' + label + '-unavailable', checks)
            error = body['error']
            # Envelope503 chỉ nhận catalog công khai/empty details; credential không được núp trong error con.
            safe_error = set(body) == {'error'} and set(error) <= {'code', 'message', 'details', 'correlationId'} and error.get('details', {}) == {} and error.get('message', 'Không thể hoàn tất yêu cầu. Vui lòng kiểm tra trạng thái và thử lại.') == 'Không thể hoàn tất yêu cầu. Vui lòng kiểm tra trạng thái và thử lại.'
            expect(safe_error and header(headers, 'cache-control') == 'no-store' and all(header(headers, name) is None for name in ('set-cookie', 'x-auth-context-id', 'x-csrf-token')), 'commit-ack-' + label + '-no-credential', checks)
            observation = proxy.gate.finish(generation)
            expect(observation['confirmed'] and observation['begins'] == observation['commits'] == 1, 'commit-ack-' + label + '-one-transaction', checks)
            after = read_snapshot(user_id, client, UUID(body['error']['correlationId']))
            # JOIN phải trỏ đúng UUID mới thêm, không chỉ một session cũ cùng account/client còn active.
            new_sessions = after.session_ids - before.session_ids
            expect(after.session_count == before.session_count + 1 and after.audit_count == before.audit_count + 1 and after.matching_pairs == 1 and len(new_sessions) == 1 and after.matched_session_ids == new_sessions, 'commit-ack-' + label + '-exact-committed-pair', checks)
            observations.append({'clientType': client, **observation})
        finally:
            proxy.gate.cancel()
    return observations
