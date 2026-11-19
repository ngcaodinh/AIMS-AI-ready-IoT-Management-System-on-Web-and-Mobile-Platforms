"""CT-MEMBER-001 trên Auth Lab đang chạy ở loopback, dùng hai account tổng hợp của cùng fixture."""

import argparse
from contextlib import ExitStack, contextmanager
from getpass import getpass
import http.client
import socket
import sys
from urllib.parse import quote
from uuid import UUID

from verify_provider import has_login_projection, has_workspace_page, header, request


class MemberCheckFailed(Exception):
    """Chỉ chứa mã assertion do test định nghĩa, an toàn để in trong report."""


# Giữ giá trị thực tế của DTO, pass và bearer ngoài thông báo lỗi.
def require(condition, check):
    """Kiểm điều kiện của bước hiện tại và báo mã check cố định khi sai."""
    if not condition:
        raise MemberCheckFailed(check)


# Giữ mỗi phiên test trong một context để logout cả khi assertion ở trang thứ hai thất bại.
@contextmanager
def fixture_actor(port, email, password):
    """Đăng nhập account seed trên listener đã chọn, cấp ID và bearer trong RAM đến khi logout."""
    status, metadata, login = request(port, 'POST', '/auth/login',
                                      {'clientType': 'ANDROID', 'email': email, 'password': password})
    require(status == 200 and isinstance(login, dict) and isinstance(login.get('token'), str)
            and login['token'], 'MEMBER_FIXTURE_LOGIN')
    credentials = {'Authorization': 'Bearer ' + login['token']}
    try:
        summary = login.get('me')
        require(isinstance(summary, dict)
                and has_login_projection(login, metadata, 'ANDROID', email, summary.get('id'), False),
                'MEMBER_FIXTURE_IDENTITY')
        yield summary['id'], credentials
    finally:
        status, _, _ = request(port, 'POST', '/auth/logout', headers=credentials)
        require(status == 204, 'MEMBER_FIXTURE_LOGOUT')


# Hai account seed có role ADMIN ở hai workspace khác nhau, do fixture cấp qua core.
def owned_workspace(port, credentials):
    """Đọc picker của actor và lấy UUID workspace duy nhất mà actor là ADMIN trong fixture."""
    status, _, page = request(port, 'GET', '/workspaces', headers=credentials)
    require(status == 200 and has_workspace_page(page) and page['nextCursor'] is None,
            'MEMBER_FIXTURE_WORKSPACES')
    owned = [row['id'] for row in page['items'] if row['role'] == 'ADMIN']
    require(len(owned) == 1, 'MEMBER_FIXTURE_ADMIN')
    return owned[0]


# So với tập ID/email/role độc lập từ seed để phát hiện row lặp, thiếu hoặc lọt tenant khác.
def check_pages(port, path, workspace, credentials, expected):
    """Đọc từng trang limit=1 rồi kiểm toàn bộ projection, cursor kết thúc và thành viên dự kiến."""
    rows = {}
    query = '?limit=1'
    for number in range(len(expected)):
        status, metadata, page = request(port, 'GET', path + query,
                                         headers={**credentials, 'X-Workspace-Id': workspace})
        require(status == 200 and header(metadata, 'cache-control') == 'no-store',
                'MEMBER_LIST_HTTP')
        require(isinstance(page, dict) and set(page) == {'items', 'nextCursor'}
                and isinstance(page['items'], list) and len(page['items']) == 1, 'MEMBER_LIST_PAGE')
        row = page['items'][0]
        require(isinstance(row, dict)
                and set(row) == {'workspaceId', 'userId', 'email', 'alias', 'role', 'status',
                                 'authzVersion', 'revision'}, 'MEMBER_LIST_DTO_FIELDS')
        user_id = row['userId']
        require(isinstance(user_id, str) and user_id in expected and user_id not in rows
                and row['workspaceId'] == workspace and row['status'] == 'ACTIVE'
                and (row['email'], row['role']) == expected[user_id], 'MEMBER_LIST_SCOPE')
        require((row['alias'] is None or isinstance(row['alias'], str) and 1 <= len(row['alias']) <= 100)
                and all(type(row[key]) is int and row[key] >= 1 for key in ('authzVersion', 'revision')),
                'MEMBER_LIST_DTO_VALUES')
        rows[user_id] = row
        cursor = page['nextCursor']
        if number + 1 == len(expected):
            require(cursor is None, 'MEMBER_LIST_FINAL_CURSOR')
        else:
            require(isinstance(cursor, str) and bool(cursor), 'MEMBER_LIST_NEXT_CURSOR')
            query = '?limit=1&cursor=' + quote(cursor, safe='')
    return list(rows.values())


# Chạy trong fixture chỉ có seed gốc để kết quả không phụ thuộc dữ liệu của bài test khác.
def verify_member_list(port, run_id, password):
    """Kiểm scoped route và alias trên hai workspace, đối chiếu cùng rows ở cùng thứ tự."""
    emails = [f'probe-{run_id}-{index}@example.invalid' for index in (0, 4)]
    with ExitStack() as sessions:
        first, second = [sessions.enter_context(fixture_actor(port, email, password)) for email in emails]
        first_id, first_credentials = first
        second_id, second_credentials = second
        first_workspace = owned_workspace(port, first_credentials)
        second_workspace = owned_workspace(port, second_credentials)
        require(first_id != second_id and first_workspace != second_workspace, 'MEMBER_FIXTURE_DISTINCT')
        contents = [(first_workspace, first_credentials, {first_id: (emails[0], 'ADMIN')}),
                    (second_workspace, second_credentials,
                     {second_id: (emails[1], 'ADMIN'), first_id: (emails[0], 'USER')})]
        for workspace, credentials, expected in contents:
            canonical = check_pages(port, f'/workspaces/{workspace}/members', workspace, credentials, expected)
            alias = check_pages(port, '/users', workspace, credentials, expected)
            require(alias == canonical, 'MEMBER_LIST_ALIAS')


# Credential test đến từ terminal ẩn hoặc một dòng trên private pipe của launcher, tuyệt đối không qua argv.
def main():
    """Kiểm listener trước khi nhận fixture. Trả 2 nếu thiếu fixture, 1 nếu case lỗi, 0 khi hoàn tất."""
    parser = argparse.ArgumentParser(description='Check CT-MEMBER-001 against a running local Auth Lab.')
    parser.add_argument('--port', type=int, default=3000)
    parser.add_argument('--run-id', type=UUID, help='Run UUID of the active synthetic Auth Lab')
    arguments = parser.parse_args()
    if not 1 <= arguments.port <= 65535:
        parser.error('invalid loopback port')
    try:
        with socket.create_connection(('127.0.0.1', arguments.port), timeout=2):
            pass
    except OSError:
        print('BLOCKED AUTH_LAB_LISTENER_UNAVAILABLE')
        return 2
    if arguments.run_id is None:
        print('BLOCKED AUTH_LAB_RUN_ID_REQUIRED')
        return 2
    try:
        password = getpass('Fixture TEST password: ') if sys.stdin.isatty() else sys.stdin.readline().rstrip('\r\n')
        if not password:
            print('BLOCKED AUTH_LAB_FIXTURE_INPUT_REQUIRED')
            return 2
        verify_member_list(arguments.port, arguments.run_id, password)
    except MemberCheckFailed as error:
        print('FAIL', error)
        return 1
    except (OSError, EOFError, ValueError, KeyError, TypeError, http.client.HTTPException, RuntimeError):
        print('FAIL MEMBER_LIST_TRANSPORT_OR_RESPONSE')
        return 1
    print('PASS CT-MEMBER-001')
    return 0


if __name__ == '__main__':
    sys.exit(main())
