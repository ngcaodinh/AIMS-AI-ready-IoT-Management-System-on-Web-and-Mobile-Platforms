"""Buộc hai request HTTP thực cùng hiện diện trong cây lock wait của PostgreSQL disposable."""

from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
import subprocess
import time
from uuid import UUID

from test_member_list_live import require


# Chờ PostgreSQL xác nhận số backend đang đợi row lock trong cùng lượt kiểm thử.
# Input: database là adapter của container disposable, count là số request HTTP cần thấy trong cây chờ.
# Output: trả về khi có đúng holder và đủ số backend, kể cả backend chờ gián tiếp.
# Errors: báo lỗi DB hoặc assertion cố định nếu chưa thấy trạng thái cần thiết khi hết thời hạn.
# Side effects: đọc pg_stat_activity và pg_blocking_pids, không sửa dữ liệu.
def wait_for_blocked_requests(database, count):
    """Chờ holder hoặc số backend của role test đang đợi trực tiếp/gián tiếp sau holder trong DB riêng."""
    # Mỗi container chỉ có một holder. UNION dừng tại các PID đã gặp và không đọc text query/session credential.
    statement = """
        WITH RECURSIVE held(pid) AS (
          SELECT pid FROM pg_stat_activity WHERE datname=current_database()
            AND application_name='iot-member-patch-holder-ready' AND state='idle in transaction'
        ), waits(pid) AS (
          SELECT pid FROM held
          UNION
          SELECT a.pid FROM pg_stat_activity a JOIN waits w ON w.pid=ANY(pg_blocking_pids(a.pid))
           WHERE a.datname=current_database() AND a.usename='iot_repository_probe' AND a.wait_event_type='Lock'
        ) SELECT (SELECT count(*) FROM held), (SELECT count(*) FROM waits);
    """
    # Bridge giới hạn lock_timeout là 5 giây. Không đánh PASS nếu chưa thấy đủ backend trước thời hạn đó.
    deadline = time.monotonic() + 3.5
    while time.monotonic() < deadline:
        row = database.sql(statement, role=database.ADMIN, database='iot_platform_lab').stdout.strip()
        if row == f'1|{count + 1}':
            return
        time.sleep(0.025)
    require(False, 'MEMBER_PATCH_DB_WAIT_' + str(count))


# Mở một transaction giữ row workspace để điều khiển thứ tự của hai request thật.
# Input: database là adapter của container vừa tạo, workspace là UUID đã xác minh từ fixture.
# Output: context chỉ bàn giao quyền tiếp tục sau khi quan sát được holder sẵn sàng.
# Errors: UUID sai, lỗi psql, hết thời hạn chờ hoặc không đóng được tiến trình sẽ làm phép thử thất bại.
# Side effects: mở psql theo container ID, khóa một row tới khi thoát context rồi rollback và đóng psql.
@contextmanager
def hold_workspace(database, workspace):
    """Khóa row workspace fixture, báo ready sau khi lấy lock và xác minh psql đã đóng trước khi trả."""
    workspace = str(UUID(workspace))
    process = subprocess.Popen(database.docker_argv('exec', '-i', database.CONTAINER, 'psql', '-X', '-q',
                               '-w', '-v', 'ON_ERROR_STOP=1', '--set', 'workspace=' + workspace,
                               '-h', '/tmp', '-U', database.ADMIN, '-d', 'iot_platform_lab'),
                               stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                               text=True, encoding='utf-8')
    try:
        # UUID được bind bằng psql. Nếu fixture thiếu row thì dừng trước lúc đánh dấu ready.
        process.stdin.write("BEGIN;\nSELECT 1/count(*) FROM (SELECT 1 FROM workspaces "
                            "WHERE workspace_id=:'workspace'::uuid FOR UPDATE) owned;\n"
                            "SET LOCAL application_name='iot-member-patch-holder-ready';\n")
        process.stdin.flush()
        wait_for_blocked_requests(database, 0)
        yield
    finally:
        # Luôn kết thúc transaction, kể cả khi chờ lock thất bại. Nếu psql treo chỉ dừng tiến trình đã sở hữu.
        try:
            if process.poll() is None:
                process.communicate('ROLLBACK;\n', timeout=5)
            require(process.returncode == 0, 'MEMBER_PATCH_HOLDER_CLOSE')
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)
            require(False, 'MEMBER_PATCH_HOLDER_TIMEOUT')


# Buộc hai request HTTP đi vào cây chờ của cùng workspace theo thứ tự xác định.
# Input: database và workspace xác định fixture, first/second là hai thao tác HTTP không tham số.
# Output: cặp phản hồi theo thứ tự gửi, sau khi holder đã nhả workspace.
# Errors: truyền lỗi HTTP, thời hạn hoặc assertion nếu không chứng minh được sự chồng lấp.
# Side effects: gửi mỗi request đúng một lần ở hai thread và chờ thread kết thúc khi thoát context.
def overlapping_requests(database, workspace, first, second):
    """Thực hiện hai thao tác HTTP không retry và trả hai response theo thứ tự gửi, sau khi đã release."""
    with ThreadPoolExecutor(max_workers=2) as pool:
        with hold_workspace(database, workspace):
            first_result = pool.submit(first)
            wait_for_blocked_requests(database, 1)
            second_result = pool.submit(second)
            wait_for_blocked_requests(database, 2)
        return first_result.result(timeout=25), second_result.result(timeout=25)
