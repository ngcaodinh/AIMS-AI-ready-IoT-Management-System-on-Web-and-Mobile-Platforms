"""PATCH qua HTTP và PostgreSQL disposable, dùng state đã commit làm oracle cho M3."""

from contextlib import ExitStack
from functools import partial
from hashlib import sha256
import json
from uuid import UUID

from member_patch_lock_fixture import overlapping_requests
from test_member_list_live import fixture_actor, owned_workspace, require
from verify_provider import header, request


# Gửi SQL do test định nghĩa vào đúng PostgreSQL của lượt chạy bằng tham số được bind.
# Input: database chứa container ID đã kiểm, statement là SQL nội bộ, values chứa UUID hoặc role ADMIN/USER.
# Output: stdout đã bỏ khoảng trắng ngoài, chỉ dùng cho projection mà từng câu SQL chọn.
# Errors: tên tham số, UUID, role không hợp lệ hoặc psql thất bại sẽ dừng phép thử.
# Side effects: thực hiện đúng thao tác đọc hoặc seed do caller chỉ định trong DB disposable.
def fixture_sql(database, statement, **values):
    """Chạy SQL trong container fixture của runner và trả projection bounded do statement chọn."""
    require(all(name in {'workspace', 'actor', 'target', 'correlation', 'session', 'role'} for name in values), 'M3_SQL_KEYS')
    bindings = []
    for name, value in values.items():
        if name == 'role':
            require(value in ('USER', 'ADMIN'), 'M3_SEED_ROLE')
        else:
            value = str(UUID(str(value)))
        bindings.extend(('--set', name + '=' + value))
    # SQL đi qua stdin, các biến được psql quote khi tham chiếu; kết nối bằng socket nội bộ của container.
    return database.docker('exec', '-i', database.CONTAINER, 'psql', '-X', '-qAt', '-w',
                           '-v', 'ON_ERROR_STOP=1', *bindings, '-h', '/tmp', '-U', database.MIGRATOR,
                           '-d', 'iot_platform_lab', input_text=statement).stdout.strip()


# Đọc membership đã commit làm căn cứ đối chiếu độc lập với phản hồi PATCH.
# Input: database là fixture disposable, workspace và target là UUID tenant và User cần kiểm.
# Output: MembershipDTO của đúng cặp workspace/User hoặc None khi chưa có membership.
# Errors: truyền lỗi SQL hoặc giải mã JSON khi projection không hợp lệ.
# Side effects: chỉ đọc các trường DTO và email tổng hợp, không đọc credential.
def snapshot(database, workspace, target):
    """Trả MembershipDTO của đúng target và workspace, hoặc None nếu tại đó không có membership."""
    # Join chỉ bổ sung email cho membership đã giới hạn bởi cả workspace lẫn user; DB tự trả revision và authzVersion.
    statement = """SELECT json_build_object('workspaceId',m.workspace_id,'userId',m.user_id,
       'role',m.role,'alias',m.alias,'email',u.email_normalized,'status',m.status,
       'revision',m.revision,'authzVersion',m.authorization_version)
       FROM memberships m JOIN users u USING(user_id)
       WHERE workspace_id=:'workspace'::uuid AND user_id=:'target'::uuid;"""
    row = fixture_sql(database, statement, workspace=workspace, target=target)
    return json.loads(row) if row else None


# Tạo thêm membership cho account sẵn có trong fixture của lượt kiểm thử.
# Input: database là fixture disposable, workspace/target là UUID, role chỉ được là USER hoặc ADMIN.
# Output: trả về khi transaction chốt cả membership và grant đầu tiên.
# Errors: role sai, membership trùng hoặc FK thất bại sẽ làm transaction không thể commit.
# Side effects: thêm đúng hai row phục vụ ca CAS hoặc tình huống workspace có hai Admin.
def seed_member(database, workspace, target, role):
    """Thêm một membership và grant generation một trong workspace cô lập, từ chối mọi role ngoài fixture."""
    # FK trỏ tới grant hiện hành được kiểm lúc commit, nên hai insert dùng chung transaction và UUID đã bind.
    fixture_sql(database, """BEGIN;
        INSERT INTO memberships(workspace_id,user_id,role,current_grant_generation)
        VALUES(:'workspace'::uuid,:'target'::uuid,:'role',1);
        INSERT INTO membership_grants(workspace_id,user_id,grant_generation)
        VALUES(:'workspace'::uuid,:'target'::uuid,1); COMMIT;""", workspace=workspace, target=target, role=role)


# Gọi điểm vào PATCH thật để kiểm cả dạng URL scoped lẫn alias.
# Input: port là cổng lab; credentials là header của phiên test; workspace/target là UUID trên route.
# Input: wire chọn route, body chứa các field cần thử, revision cấp If-Match, selected chọn workspace header tùy ý.
# Output: cặp status và JSON sau khi đã kiểm Cache-Control.
# Errors: route sai, lỗi HTTP hoặc thiếu no-store làm phép thử thất bại.
# Side effects: gửi một PATCH, có thể đổi dữ liệu và tạo audit nếu provider chấp nhận.
def patch(port, credentials, workspace, target, wire, body, revision=None, selected=None):
    """Gửi một PATCH tới route scoped hoặc alias, giữ header workspace độc lập để kiểm mismatch."""
    require(wire in ('scoped', 'alias'), 'M3_WIRE')
    path = f'/users/{target}' if wire == 'alias' else f'/workspaces/{workspace}/members/{target}'
    headers = {**credentials, 'X-Workspace-Id': selected or workspace}
    if revision is not None:
        headers['If-Match'] = f'"{revision}"'
    status, metadata, result = request(port, 'PATCH', path, body, headers)
    require(header(metadata, 'cache-control') == 'no-store', 'M3_NO_STORE')
    return status, result


# Đối chiếu lỗi HTTP và lấy correlation ID của chính request bị từ chối.
# Input: reply là cặp status/JSON, status/code là lỗi mong đợi, details là projection validation tùy chọn.
# Output: correlation ID sau khi kiểm envelope, message và details.
# Errors: sai status, field dư, details không khớp hoặc correlation ID không hợp lệ sẽ làm assertion thất bại.
# Side effects: chỉ kiểm dữ liệu trong bộ nhớ.
def denied(reply, status, code, details=None):
    """Xác minh status/code/correlation/envelope và trả correlation ID để đối chiếu sự kiện audit."""
    actual_status, body = reply
    require(actual_status == status and isinstance(body, dict) and set(body) == {'error'},
            f'M3_HTTP_{status}_{code}')
    error = body['error']
    require(isinstance(error, dict) and set(error) == {'code', 'message', 'details', 'correlationId'}
            and error['code'] == code and isinstance(error['message'], str) and error['message']
            and error['details'] == ({} if details is None else details)
            and isinstance(error['correlationId'], str)
            and str(UUID(error['correlationId'])) == error['correlationId'], 'M3_ERROR_' + code)
    return error['correlationId']


# Đối chiếu kết quả mutation ở HTTP và PostgreSQL với row đã đọc trước request.
# Input: database là fixture; before là DTO trước mutation; reply là kết quả PATCH; changes là field kỳ vọng đổi.
# Output: DTO kỳ vọng sau khi kiểm thành công, dùng làm baseline cho bước kế tiếp.
# Errors: sai HTTP status, projection, revision, authzVersion hoặc dữ liệu đã commit sẽ làm assertion thất bại.
# Side effects: đọc lại membership theo đúng tenant/User, không gửi lại PATCH.
def changed(database, before, reply, **changes):
    """So DTO HTTP và row PostgreSQL với cùng expected, bao gồm mọi field và chính xác một lần tăng revision."""
    expected = dict(before, **changes)
    expected['revision'] = before['revision'] + 1
    expected['authzVersion'] = before['authzVersion'] + int(any(
        before[field] != expected[field] for field in ('role', 'status')))
    require(reply == (200, expected), 'M3_PATCH_RESPONSE')
    require(snapshot(database, before['workspaceId'], before['userId']) == expected, 'M3_PATCH_PERSISTED')
    return expected


# Kiểm ranh giới hai workspace và trường hợp Admin duy nhất bị ngăn tự hạ quyền.
# Input: database/port là DB và HTTP của fixture; credentials thuộc actor có quyền Admin ở workspace A.
# Input: workspace/other là A/B; actor là User đang thao tác; outsider chỉ có membership tại B.
# Output: trả về khi cả hai route từ chối đúng mã, denial audit khớp và dữ liệu A/B được giữ nguyên.
# Errors: rò metadata tenant, thiếu audit theo correlation hoặc membership bị đổi sẽ làm phép thử thất bại.
# Side effects: gửi GET và PATCH dự kiến bị từ chối, đọc lại membership và audit tương ứng.
def check_scope_and_last_admin(database, port, credentials, workspace, other, actor, outsider):
    """Kiểm scope, membership ngoài A và last Admin trước khi seed Admin thứ hai."""
    me = snapshot(database, workspace, actor)
    visitor = snapshot(database, other, actor)
    outside = snapshot(database, other, outsider)
    require(me['role'] == 'ADMIN' and outside['role'] == 'ADMIN'
            and visitor is not None and visitor['role'] == 'USER' and visitor['status'] == 'ACTIVE'
            and snapshot(database, workspace, outsider) is None, 'M3_SCOPE_GIVEN')
    member_metadata = (other, outsider, outside['email'], actor, visitor['email'])
    # Lấy ID của chính phiên gửi PATCH từ digest SHA-256 qua stdin riêng của psql. Không đưa bearer/digest vào argv.
    authorization = credentials['Authorization']
    require(authorization.startswith('Bearer '), 'M3_FIXTURE_SESSION')
    digest = sha256(authorization.removeprefix('Bearer ').encode('utf-8')).hexdigest()
    session = fixture_sql(database, f"\\set digest {digest}\n" + """
        SELECT session_id FROM sessions WHERE user_id=:'actor'::uuid AND token_digest=decode(:'digest','hex')
          AND client_type='ANDROID' AND revoked_at IS NULL;""", actor=actor)
    require(str(UUID(session)) == session, 'M3_FIXTURE_SESSION')
    bad_field = {'fieldErrors': [{'path': '', 'code': 'UNKNOWN_FIELD'}]}
    denial_correlations = set()
    for wire, list_path in (('alias', '/users'), ('scoped', f'/workspaces/{other}/members')):
        hidden = patch(port, credentials, workspace, outsider, wire, {'alias': 'TEST'}, outside['revision'])
        denied(hidden, 404, 'RESOURCE_NOT_FOUND')
        require(not any(value in json.dumps(hidden[1], ensure_ascii=False)
                        for value in (outside['email'], outsider, other)), 'M3_HIDDEN_TARGET_DISCLOSURE')
        denied(patch(port, credentials, workspace, actor, wire, {'workspaceId': other, 'alias': 'TEST'},
                     me['revision']), 422, 'VALIDATION_ERROR', bad_field)
        # Admin A chỉ là USER tại B. Cả route có workspace trên URL và alias chọn B qua header đều phải từ chối đọc.
        status, metadata, body = request(port, 'GET', list_path, headers={**credentials, 'X-Workspace-Id': other})
        denied((status, body), 403, 'FORBIDDEN')
        response = json.dumps((metadata, body), ensure_ascii=False)
        require(header(metadata, 'cache-control') == 'no-store' and all(value not in response for value in member_metadata),
                'M3_OTHER_WORKSPACE_LIST_DISCLOSURE')
        require(snapshot(database, workspace, actor) == me and snapshot(database, other, actor) == visitor
                and snapshot(database, other, outsider) == outside, 'M3_OTHER_WORKSPACE_LIST_UNCHANGED')
        # Cùng phiên và cùng workspace B, PATCH dùng revision hiện hành phải từ chối trước mọi ghi.
        forbidden = patch(port, credentials, other, outsider, wire, {'alias': 'TEST'}, outside['revision'])
        denied(forbidden, 403, 'FORBIDDEN')
        response = json.dumps(forbidden[1], ensure_ascii=False)
        require(all(value not in response for value in member_metadata), 'M3_OTHER_WORKSPACE_PATCH_DISCLOSURE')
        correlation = denied(patch(port, credentials, workspace, actor, wire, {'role': 'USER'},
                                   me['revision']), 409, 'LAST_ADMIN_REQUIRED')
        # Mỗi request có đúng một denial audit theo correlation riêng, không được đếm lại event của route kia.
        require(correlation not in denial_correlations, 'M3_LAST_ADMIN_DISTINCT_CORRELATIONS')
        denial_correlations.add(correlation)
        # WHERE giữ mọi event cùng correlation; FILTER chỉ đếm denial hợp lệ để phát hiện cả event thừa khác loại.
        counts = fixture_sql(database, """SELECT count(*), count(*) FILTER (WHERE
              workspace_id=:'workspace'::uuid AND actor_user_id=:'actor'::uuid
              AND resource_type='MEMBERSHIP' AND resource_id=:'actor'
              AND session_id=:'session'::uuid AND occurred_at IS NOT NULL AND outcome='FAILURE'
              AND event_type='MEMBERSHIP_LAST_ADMIN_DENIED' AND reason_code='LAST_ADMIN_REQUIRED'
              AND redacted_diff->>'result'='DENIED')
            FROM audit_events WHERE correlation_id=:'correlation'::uuid;""",
                             workspace=workspace, actor=actor, session=session, correlation=correlation)
        require(counts == '1|1', 'M3_LAST_ADMIN_AUDIT')
    denied(patch(port, credentials, workspace, actor, 'scoped', {'alias': 'TEST'}, me['revision'],
                 selected=other), 403, 'WORKSPACE_MISMATCH')
    require(snapshot(database, workspace, actor) == me and snapshot(database, other, outsider) == outside
            and snapshot(database, other, actor) == visitor and snapshot(database, workspace, outsider) is None,
            'M3_DENIAL_UNCHANGED')


# Kiểm quyền của một USER đang ACTIVE trong workspace có đúng hai membership tại bước này của fixture.
# Input: database/port xác định fixture, workspace là tenant A, actor là cặp ID/header của phiên USER đầy đủ,
# admin_id là ID Admin cùng workspace mà USER thử sửa bằng revision hiện hành.
# Output: trả về sau khi cả hai route từ chối đọc và ghi, hai membership của A khớp dữ liệu ban đầu.
# Errors: trả dữ liệu thay vì FORBIDDEN, lộ metadata, thay đổi dữ liệu hoặc lỗi HTTP/SQL làm test thất bại.
# Side effects: gửi hai GET và hai PATCH qua HTTP thật, đọc lại hai membership sau từng request.
def check_user_admin_routes(database, port, workspace, actor, admin_id):
    """Kiểm SEC-MEMBER-001 trên phiên USER tổng hợp còn đầy đủ quyền đăng nhập."""
    user_id, credentials = actor
    member = snapshot(database, workspace, user_id)
    admin = snapshot(database, workspace, admin_id)
    require(member['status'] == admin['status'] == 'ACTIVE' and member['role'] == 'USER'
            and admin['role'] == 'ADMIN' and user_id != admin_id, 'M3_USER_PERMISSION_GIVEN')
    for wire, path in (('scoped', f'/workspaces/{workspace}/members'), ('alias', '/users')):
        status, metadata, body = request(port, 'GET', path, headers={**credentials, 'X-Workspace-Id': workspace})
        denied((status, body), 403, 'FORBIDDEN')
        require(header(metadata, 'cache-control') == 'no-store'
                and not any(value in json.dumps(body, ensure_ascii=False) for value in (admin['email'], admin_id)),
                'M3_USER_LIST_DISCLOSURE')
        require(snapshot(database, workspace, user_id) == member and snapshot(database, workspace, admin_id) == admin,
                'M3_USER_LIST_UNCHANGED')
        # Body hợp lệ và revision hiện hành loại trừ lỗi validation/CAS trước khi đối chiếu 403.
        denied(patch(port, credentials, workspace, admin_id, wire, {'alias': 'Tên chưa được phép'},
                     admin['revision']), 403, 'FORBIDDEN')
        require(snapshot(database, workspace, user_id) == member and snapshot(database, workspace, admin_id) == admin,
                'M3_USER_PATCH_UNCHANGED')


# Kiểm revision, alias và chuyển trạng thái của cùng thành viên qua hai route.
# Input: database/port là fixture, credentials thuộc Admin A, workspace/other là hai tenant của cùng target.
# Output: trả về khi phản hồi và dữ liệu A khớp, toàn bộ DTO của target tại B vẫn giữ nguyên sau mỗi chuyển trạng thái.
# Errors: sai precondition, stale revision, field validation, DTO hoặc audit no-op sẽ làm phép thử thất bại.
# Side effects: sửa alias, suspend, kích hoạt lại rồi remove User tại A; đọc audit và snapshot của A/B.
def check_cas_and_alias(database, port, credentials, workspace, other, target):
    """Kiểm revision, no-op, alias Unicode và hai tên status ở HTTP và PostgreSQL."""
    current = snapshot(database, workspace, target)
    outside = snapshot(database, other, target)
    require(outside is not None and outside['role'] == 'USER' and outside['status'] == 'ACTIVE',
            'M3_SHARED_USER_BASELINE')
    for wire in ('scoped', 'alias'):
        call = partial(patch, port, credentials, workspace, target, wire)
        correct, wrong = ('status', 'membershipStatus') if wire == 'scoped' else ('membershipStatus', 'status')
        # Revision hợp lệ bảo đảm mỗi request sai bị từ chối ở validation; kiểm từng snapshot gồm cả hai version.
        for body, path, code in (({}, '/', 'FORMAT'), ({'role': 'OWNER'}, '/role', 'ENUM'),
                                 ({correct: 'PENDING'}, '/' + correct, 'ENUM')):
            denied(call(body, current['revision']), 422, 'VALIDATION_ERROR',
                   {'fieldErrors': [{'path': path, 'code': code}]})
            require(snapshot(database, workspace, target) == current, 'M3_INVALID_PATCH_UNCHANGED')
        denied(call({'alias': 'TEST'}), 428, 'PRECONDITION_REQUIRED')
        require(snapshot(database, workspace, target) == current, 'M3_MISSING_REVISION_UNCHANGED')
        denied(call({'alias': '   '}, current['revision']), 422, 'VALIDATION_ERROR',
               {'fieldErrors': [{'path': '/alias', 'code': 'LENGTH'}]})
        old_revision = current['revision']
        current = changed(database, current, call({'alias': '  A\u0301nh  '}, old_revision), alias='Ánh')
        denied(call({'alias': 'Stale'}, old_revision), 412, 'VERSION_CONFLICT')
        require(snapshot(database, workspace, target) == current, 'M3_STALE_UNCHANGED')
        current = changed(database, current, call({'alias': None}, current['revision']), alias=None)
        denied(call({wrong: 'SUSPENDED'}, current['revision']), 422, 'VALIDATION_ERROR',
               {'fieldErrors': [{'path': '', 'code': 'UNKNOWN_FIELD'}]})
        for status in ('SUSPENDED', 'ACTIVE'):
            current = changed(database, current, call({correct: status}, current['revision']), status=status)
            # Hai tenant dùng chung user_id; so toàn bộ DTO tại B, kể cả revision và authzVersion, sau từng commit ở A.
            require(snapshot(database, other, target) == outside, 'M3_SHARED_USER_OTHER_WORKSPACE_UNCHANGED')
        # Snapshot ACTIVE cuối cùng giống input; no-op vẫn tăng revision và giữ nguyên authzVersion.
        current = changed(database, current, call({correct: 'ACTIVE'}, current['revision']), status='ACTIVE')
        # Đọc sự kiện mới nhất của đúng membership, chỉ chọn cờ no-op và danh sách tên field đã đổi.
        event = fixture_sql(database, """SELECT redacted_diff->'noOp',redacted_diff->'diff' FROM audit_events
            WHERE workspace_id=:'workspace'::uuid AND resource_id=:'target' AND event_type='MEMBERSHIP_CHANGED'
            ORDER BY occurred_at DESC LIMIT 1;""", workspace=workspace, target=target)
        require(event == 'true|[]', 'M3_NO_OP_AUDIT')

    # Hai route dùng cùng revision vừa commit sau khi xóa để kiểm lỗi chuyển trạng thái và phát hiện ghi ngoài ý muốn.
    scoped = partial(patch, port, credentials, workspace, target, 'scoped')
    removed = changed(database, current, scoped({'status': 'REMOVED'}, current['revision']), status='REMOVED')
    require(snapshot(database, other, target) == outside, 'M3_REMOVED_OTHER_WORKSPACE_UNCHANGED')
    denied(scoped({'status': 'ACTIVE'}, removed['revision']), 409, 'INVALID_TRANSITION')
    denied(patch(port, credentials, workspace, target, 'alias', {'membershipStatus': 'ACTIVE'},
                 removed['revision']), 409, 'INVALID_TRANSITION')
    require(snapshot(database, workspace, target) == removed, 'M3_REMOVED_MEMBERSHIP_UNCHANGED')


# Kiểm việc giữ lại Admin cuối và từ chối thao tác của actor vừa bị hạ quyền trong hai race.
# Input: database/port là fixture, workspace chứa hai Admin; first_actor/second_actor là cặp User ID và header.
# Output: trả về khi mỗi race có đúng một thay đổi, Admin còn lại vẫn đủ quyền và dữ liệu của loser không bị ghi.
# Errors: timeout lock, response sai hoặc dữ liệu DB không khớp đều làm phép thử thất bại.
# Side effects: hạ quyền Admin đầu, khôi phục bằng API giữa hai ca, rồi đọc lại trạng thái sau commit.
def check_races(database, port, workspace, first_actor, second_actor):
    """Buộc hai request thực tranh lock, so đúng một mutation cho từng race và giữ Admin còn hoạt động."""
    first_id, first_credentials = first_actor
    second_id, second_credentials = second_actor
    for case in ('mutual-demote', 'demote-vs-edit'):
        first = snapshot(database, workspace, first_id)
        second = snapshot(database, workspace, second_id)
        require(first['role'] == second['role'] == 'ADMIN' and first['status'] == second['status'] == 'ACTIVE',
                'M3_TWO_ACTIVE_ADMINS')
        demote = partial(patch, port, second_credentials, workspace, first_id, 'scoped',
                         {'role': 'USER'}, first['revision'])
        body = {'role': 'USER'} if case == 'mutual-demote' else {'alias': 'Forbidden write'}
        attempt = partial(patch, port, first_credentials, workspace, second_id, 'alias', body, second['revision'])
        winner, loser = overlapping_requests(database, workspace, demote, attempt)
        demoted = changed(database, first, winner, role='USER')
        denied(loser, 403, 'FORBIDDEN')
        require(snapshot(database, workspace, second_id) == second, 'M3_LOSER_NO_WRITE')
        # Đếm Admin còn đủ điều kiện cả ở membership và account, không đếm account disabled/đang buộc đổi mật khẩu.
        count = fixture_sql(database, """SELECT count(*) FROM memberships m JOIN users u USING(user_id)
          WHERE m.workspace_id=:'workspace'::uuid AND m.status='ACTIVE' AND m.role='ADMIN'
            AND u.account_status='ACTIVE' AND NOT u.must_change_password;""", workspace=workspace)
        require(count == '1', 'M3_ONE_CAPABLE_ADMIN')
        if case == 'mutual-demote':
            changed(database, demoted, patch(port, second_credentials, workspace, first_id, 'scoped',
                    {'role': 'ADMIN'}, demoted['revision']), role='ADMIN')


# Điều phối các ca M3 trên seed của Auth Lab và kiểm quyền ở workspace B trước/sau các mutation tại A.
# Input: database/port là DB và HTTP dùng một lần, settings chứa ID/email/mật khẩu fixture trong RAM.
# Output: trả về sau khi các ca scope, quyền USER, CAS và race hoàn tất và các phiên đã logout.
# Errors: truyền lỗi fixture, HTTP, SQL, assertion hoặc logout của bất kỳ bước nào.
# Side effects: mở phiên cho hai Admin và một USER, seed membership, thực hiện PATCH rồi logout.
def verify_member_patch(database, port, settings):
    """Đăng nhập hai Admin seed, chuẩn bị dữ liệu từng ca và đối chiếu các mutation M3."""
    with ExitStack() as owners:
        first, second = [owners.enter_context(fixture_actor(port, settings['emails'][index],
                          settings['fixturePassword'])) for index in (0, 4)]
        workspace = owned_workspace(port, first[1])
        other = owned_workspace(port, second[1])
        first_outside = snapshot(database, other, first[0])
        second_outside = snapshot(database, other, second[0])
        print('MEMBER_M3_STAGE_SCOPE_LAST_ADMIN', flush=True)
        check_scope_and_last_admin(database, port, first[1], workspace, other, first[0], second[0])
        target = settings['userIds'][3]
        seed_member(database, workspace, target, 'USER')
        # Tạo membership độc lập ở B cho cùng account để kiểm ranh giới workspace khi A đổi trạng thái.
        seed_member(database, other, target, 'USER')
        print('MEMBER_M3_STAGE_USER_PERMISSION', flush=True)
        with fixture_actor(port, settings['emails'][3], settings['fixturePassword']) as actor:
            require(actor[0] == target, 'M3_USER_SESSION_IDENTITY')
            check_user_admin_routes(database, port, workspace, actor, first[0])
        print('MEMBER_M3_STAGE_PATCH_CAS', flush=True)
        check_cas_and_alias(database, port, first[1], workspace, other, target)
        seed_member(database, workspace, second[0], 'ADMIN')
        print('MEMBER_M3_STAGE_ADMIN_RACES', flush=True)
        check_races(database, port, workspace, first, second)
        require(snapshot(database, other, first[0]) == first_outside
                and snapshot(database, other, second[0]) == second_outside, 'M3_OTHER_WORKSPACE_UNCHANGED')
