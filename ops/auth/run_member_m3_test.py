"""Runner cô lập cho các ca PATCH FEAT-TN-003, dùng bộ cấp container/bridge đã có của M2."""

import argparse
from contextlib import ExitStack
import secrets
import socket
import subprocess
import sys
import threading
from uuid import uuid4

import run_local as launcher
from run_member_m2_test import close_bridge, disposable_database
from test_member_list_live import MemberCheckFailed
from test_member_patch_live import verify_member_patch


# Dựng Auth Lab và điều phối các ca M3 trên dữ liệu tổng hợp của lượt chạy.
# Input: không nhận tham số. Lệnh chạy dùng checkout hiện tại và image PostgreSQL đã ghim.
# Output: trả về sau khi mọi phép kiểm, tiến trình con, bridge và container đều đã kết thúc.
# Errors: lỗi build, khởi động, assertion hoặc thu dọn được truyền về main.
# Side effects: build offline, tạo container, cấp role/ACL và mở HTTP trên loopback trong thời gian test.
def run():
    """Build Auth Lab offline, seed hai tenant, chạy HTTP/DB rồi đóng các owner theo thứ tự ngược."""
    print('MEMBER_M3_STAGE_OFFLINE_BUILD', flush=True)
    built = subprocess.run(['cargo', 'build', '--bin', 'auth-lab', '--features', 'http-server',
                            '--locked', '--offline'], cwd=launcher.ROOT / 'backend',
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=300)
    if built.returncode:
        raise RuntimeError('MEMBER_M3_BUILD')
    run_id = uuid4()
    with ExitStack() as owners:
        print('MEMBER_M3_STAGE_DISPOSABLE_POSTGRES', flush=True)
        database = owners.enter_context(disposable_database(run_id))
        database_password = secrets.token_hex(32)
        launcher.provision(database_password, run_id)
        # PATCH đổi quyền gọi các hook hiện hữu kể cả với tenant mới chưa có job/key/delivery nào.
        database.sql('GRANT SELECT,INSERT,UPDATE ON membership_admission_fences TO iot_repository_probe; '
                     'GRANT SELECT,UPDATE ON workspace_invitations,webhook_deliveries,webhook_subscriptions,'
                     'push_deliveries,api_keys,commands,rule_executions,action_executions,action_jobs '
                     'TO iot_repository_probe;', database=launcher.DATABASE, role=database.ADMIN)
        # Bridge chỉ chấp nhận role của fixture và được đăng ký dọn trước khi dựng backend sử dụng nó.
        bridge = launcher.bridge.InspectionServer(('127.0.0.1', 0), launcher.bridge.InspectionHandler)
        bridge.allowed_user, bridge.read_only = launcher.ROLE, False
        threading.Thread(target=bridge.serve_forever, daemon=True).start()
        owners.callback(close_bridge, bridge)
        # Để hệ điều hành chọn cổng loopback. Nếu cổng bị lấy sau khi nhả socket, bước READY của backend sẽ thất bại.
        with socket.socket() as allocation:
            allocation.bind(('127.0.0.1', 0))
            port = allocation.getsockname()[1]
        password = 'Aa1' + secrets.token_hex(16)
        settings = {'databasePort': bridge.server_address[1], 'databasePassword': database_password,
                    'signingKey': list(secrets.token_bytes(32)), 'httpPort': port, 'runId': str(run_id),
                    'userIds': [str(uuid4()) for _ in range(5)],
                    'emails': [f'probe-{run_id}-{index}@example.invalid' for index in range(5)],
                    'fixturePassword': password}
        print('MEMBER_M3_STAGE_HTTP_START', flush=True)
        backend = launcher.start_lab(settings)
        # ExitStack gọi ngược thứ tự đăng ký: dừng backend trước, sau đó đóng bridge và xóa container theo ID.
        owners.callback(launcher.stop_lab, backend)
        verify_member_patch(database, port, settings)


# Phân tích lệnh yêu cầu chạy M3 và chuyển kết quả thành exit code cho caller.
# Input: đối số CLI phải có --run để thực thi.
# Output: 0 khi mọi assertion và teardown đều thành công, 1 khi gặp lỗi test hoặc hạ tầng.
# Errors: argparse xử lý đối số không hợp lệ. Lỗi từ fixture được chuyển thành mã cố định để giữ kín dữ liệu.
# Side effects: gọi run() sau khi kiểm đối số, in kết quả ra terminal.
def main():
    """Báo kết quả của HTTP/DB sau teardown, chỉ xuất mã lỗi cố định nếu fixture/transport thất bại."""
    parser = argparse.ArgumentParser(description='Check membership PATCH on a disposable local PostgreSQL.')
    parser.add_argument('--run', action='store_true', required=True)
    parser.parse_args()
    try:
        run()
    except MemberCheckFailed as error:
        print('FAIL', error)
        return 1
    except Exception:
        print('FAIL MEMBER_M3_FIXTURE_OR_TRANSPORT')
        return 1
    # Ca mutual-demote gửi hai PATCH đồng thời và kiểm DB còn đúng một Admin, theo E2E-MEMBER-002/AT-WF-003-02.
    print('PASS CT-MEMBER-003 CT-MEMBER-004-LAST-ADMIN CT-MEMBER-005 CT-MEMBER-006 '
          'IT-MEMBER-002 IT-MEMBER-006 SEC-MEMBER-001 SEC-MEMBER-002 E2E-MEMBER-002 AT-WF-003-02')
    return 0


if __name__ == '__main__':
    sys.exit(main())
