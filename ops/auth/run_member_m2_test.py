"""Runner HTTP/DB FEAT-TN-003 dùng container PostgreSQL riêng có lifetime bằng lượt kiểm thử."""

import argparse
from contextlib import ExitStack, contextmanager
import json
import re
import secrets
import socket
import subprocess
import sys
import threading
import time
from uuid import uuid4

import run_local as launcher
from test_member_creation_live import verify_member_creation
from test_member_list_live import MemberCheckFailed, require, verify_member_list
from verify_security_evidence import scan_sink


# Tạo mới bắt buộc và giữ nguyên ID do Docker trả về, không nhận target/container từ CLI.
@contextmanager
def disposable_database(run_id):
    """Chạy PostgreSQL canonical trong container đóng mạng, xóa đúng container mới khi rời fixture."""
    database = launcher.lab
    startup = (f"initdb -D {database.DATA_DIRECTORY} -U {database.ADMIN} --auth-local=trust "
               f"--auth-host=reject --locale=C --encoding=UTF8 && exec postgres -D {database.DATA_DIRECTORY} "
               "-c listen_addresses='' -c unix_socket_directories=/tmp")
    # Nhãn ownership và immutable ID không phụ thuộc tên container dùng chung của Auth Lab.
    identity = database.docker('create', '--pull=never', '--name', f'iot-member-m2-{run_id}',
                               '--network', 'none', '--user', 'postgres',
                               '--label', f'com.iot.database-purpose={database.PURPOSE}',
                               '--label', f'com.iot.member-run={run_id}', '--tmpfs', '/var/lib/postgresql/data',
                               '--entrypoint', '/bin/sh', database.IMAGE, '-c', startup).stdout.strip()
    if not re.fullmatch('[0-9a-f]{64}', identity):
        raise RuntimeError('MEMBER_FIXTURE_CONTAINER_ID')
    # Module database dùng chung bởi SQL, provision và bridge. Runner CLI riêng giữ ID này cả khi teardown lỗi.
    database.CONTAINER = identity
    try:
        database.inspect_lab()
        database.docker('start', identity)
        deadline = time.monotonic() + 45
        while database.docker('exec', identity, 'pg_isready', '-q', '-h', '/tmp', '-U', database.ADMIN,
                              check=False).returncode:
            if time.monotonic() >= deadline:
                raise RuntimeError('MEMBER_FIXTURE_DATABASE_START')
            time.sleep(0.5)
        database.bootstrap_database(launcher.DATABASE)
        launcher.repository.platform.apply()
        yield database
    finally:
        # Kiểm cả nhãn lượt chạy trước khi xóa theo ID, kể cả khi migration, test hoặc backend cleanup lỗi.
        owner = database.docker('inspect', identity, '--format',
                                '{{index .Config.Labels "com.iot.member-run"}}').stdout.strip()
        if owner != str(run_id):
            raise RuntimeError('MEMBER_FIXTURE_CONTAINER_OWNERSHIP')
        database.docker('rm', '--force', '--volumes', identity)


# Nếu bridge không đóng trong budget, lệnh phải trả FAIL trước khi xuất kết quả.
def close_bridge(server):
    """Đóng owner loopback đã khởi tạo và báo lỗi khi không xác minh được terminal."""
    if not launcher.close_bridge(server):
        raise RuntimeError('MEMBER_FIXTURE_BRIDGE_CLEANUP')


# Một process giữ DB, bridge và backend cho cả luồng tạo/sửa/mời và kiểm rollback, audit.
# Input: không nhận tham số; dùng PostgreSQL image đã ghim và Auth Lab của checkout hiện hành.
# Output: trả bằng chứng metric và số liệu của từng pipe sau khi kiểm redaction và dọn fixture.
# Errors: truyền lỗi build, fixture, HTTP hoặc PostgreSQL cho main xử lý.
# Side effects: build offline, mở listener loopback, cấp role trong container dùng một lần và quét hai pipe trong RAM.
def run():
    """Build offline rồi kiểm danh sách, tạo/mời, rollback, revision cũ và audit qua HTTP và PostgreSQL."""
    print('MEMBER_M2_STAGE_OFFLINE_BUILD', flush=True)
    built = subprocess.run(['cargo', 'build', '--bin', 'auth-lab', '--features', 'http-server',
                            '--locked', '--offline'], cwd=launcher.ROOT / 'backend',
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=300)
    if built.returncode:
        raise RuntimeError('MEMBER_FIXTURE_BACKEND_BUILD')
    run_id = uuid4()
    with ExitStack() as owners:
        print('MEMBER_M2_STAGE_DISPOSABLE_POSTGRES', flush=True)
        database = owners.enter_context(disposable_database(run_id))
        database_password = secrets.token_hex(32)
        launcher.provision(database_password, run_id)
        # Chỉ role tạm trong container riêng được thêm ba bảng cần cho receipt/invitation của POST.
        database.sql('GRANT SELECT,INSERT,UPDATE,DELETE ON workspace_idempotency_records TO iot_repository_probe; '
                     'GRANT SELECT,INSERT,UPDATE ON membership_admission_fences,workspace_invitations '
                     'TO iot_repository_probe;', database=launcher.DATABASE, role=database.ADMIN)
        server = launcher.bridge.InspectionServer(('127.0.0.1', 0), launcher.bridge.InspectionHandler)
        server.allowed_user = launcher.ROLE
        server.read_only = False
        threading.Thread(target=server.serve_forever, daemon=True).start()
        owners.callback(close_bridge, server)
        # Auth Lab nhận port qua stdin và chỉ trả READY khi đã bind. Khi mất race port, không gửi credential.
        with socket.socket() as allocation:
            allocation.bind(('127.0.0.1', 0))
            port = allocation.getsockname()[1]
        password = 'Aa1' + secrets.token_hex(16)
        # Capability measurement riêng với signing key, chỉ trao cho Auth Lab qua stdin của child và tester qua RAM.
        measurement_key = secrets.token_bytes(32)
        settings = {'databasePort': server.server_address[1], 'databasePassword': database_password,
                    'signingKey': list(secrets.token_bytes(32)), 'httpPort': port, 'runId': str(run_id),
                    'enableMeasurements': True, 'measurementKey': list(measurement_key),
                    'userIds': [str(uuid4()) for _ in range(5)],
                    'emails': [f'probe-{run_id}-{index}@example.invalid' for index in range(5)],
                    'fixturePassword': password}
        print('MEMBER_M2_STAGE_HTTP_START', flush=True)
        captures = []
        issued_secrets = []
        owners.callback(issued_secrets.clear)
        # Gắn reader ngay từ Popen để không mất output trước READY hoặc trong khi dừng process.
        backend = launcher.start_lab(settings, capture_sink='primary', output_captures=captures)
        try:
            print('MEMBER_M2_STAGE_MEMBER_LIST', flush=True)
            verify_member_list(port, run_id, password)
            print('MEMBER_M2_STAGE_MEMBER_CREATE', flush=True)
            evidence = verify_member_creation(port, database, run_id, password, measurement_key, issued_secrets)
        finally:
            # Dừng đúng child rồi đợi EOF của cả hai reader, kể cả khi một assertion HTTP/DB thất bại.
            launcher.stop_lab(backend)
            require(len(captures) == 1 and captures[0][0] is backend, 'MEMBER_CREATE_CAPTURE_OWNER')
            output = captures[0][1].finish(backend, tuple(issued_secrets))
            for stream in output['streams']:
                require(stream['status'] != 'FAIL', 'MEMBER_CREATE_SECRET_' + stream['sink'].upper())
        # Helper chỉ trả tên sink, trạng thái và số đếm. Pipe rỗng hoặc chưa có event JSON vẫn mang trạng thái NOT_RUN.
        summary = 'MEMBER_CREATE_BACKEND_OUTPUT ' + json.dumps(output, separators=(',', ':'))
        require(scan_sink('evidence', summary.encode('ascii'), tuple(issued_secrets))['status'] == 'PASS',
                'MEMBER_CREATE_OUTPUT_EVIDENCE_SECRET')
        return evidence, summary


# Xử lý yêu cầu chạy M2 và chuyển kết quả đã thu dọn thành exit code.
# Input: CLI phải có --run để bắt đầu fixture.
# Output: trả 0 khi mọi assertion và teardown thành công, trả 1 nếu test/fixture lỗi.
# Errors: argparse xử lý đối số sai, lỗi runtime chỉ xuất mã cố định.
# Side effects: gọi runner, in marker của các phép thử thực sự đã đi qua.
def main():
    """Trả exit 0 sau khi mọi oracle và cleanup đều hoàn tất, chỉ in check ID an toàn khi lỗi."""
    parser = argparse.ArgumentParser(description='Run M2 against a disposable local PostgreSQL container.')
    parser.add_argument('--run', action='store_true', required=True)
    parser.parse_args()
    try:
        evidence, output_summary = run()
    except MemberCheckFailed as error:
        print('FAIL', error)
        return 1
    except Exception:
        # Exception hạ tầng có thể chứa stderr hoặc cấu hình, nên chỉ ghi thông báo cố định.
        print('FAIL MEMBER_M2_FIXTURE_OR_TRANSPORT')
        return 1
    print(evidence)
    print(output_summary)
    print('PASS CT-MEMBER-001 CT-MEMBER-002 IT-MEMBER-001 IT-MEMBER-008 E2E-MEMBER-004 '
          'MEMBER_CREATE_AUDIT_REDACTION MEMBER_CREATE_METRIC_REDACTION MEMBER_CREATE_EVIDENCE_REDACTION')
    return 0


if __name__ == '__main__':
    sys.exit(main())
