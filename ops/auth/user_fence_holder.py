"""Giữ User fence trên fixture sở hữu; chỉ marker/count được rời PostgreSQL, không PHC hoặc query text."""

import json
import queue
import subprocess
import threading
import time
from uuid import UUID, uuid4

import verify_database as lab
import verify_repositories as repository

DATABASE = 'iot_platform_lab'
# Budget của harness, không phải kết quả đo hash/pool/lock hoặc SLA sản phẩm.
STARTUP_TIMEOUT = 5.0
OBSERVE_TIMEOUT = 3.0
SHUTDOWN_TIMEOUT = 5.0


def remaining(deadline, phase):
    """Trả ngân sách còn lại, không cho bước tiếp theo nhận timeout mới sau deadline tuyệt đối.

    Input
    Param: deadline — mốc monotonic của toàn giai đoạn, không là thời gian wall clock.
    Param: phase — tên literal nội bộ giúp phân biệt failure mà không lộ dữ liệu request.
    Output: số giây dương; Errors: RuntimeError cố định nếu đã hết ngân sách.
    """
    budget = deadline - time.monotonic()
    if budget <= 0:
        raise RuntimeError('User fence ' + phase + ' deadline exceeded')
    return budget


def inspect_owned_lab(deadline):
    """Kiểm đúng image/container isolation bằng các field allowlist trong cùng startup deadline.

    Input
    Param: deadline — budget startup chung, mỗi subprocess nhận phần còn lại.
    Errors: metadata/container/client timeout sai đều FAIL, không đọc Config.Env.
    """
    template = '{{index .Config.Labels "com.iot.database-purpose"}}|{{.Image}}|{{.HostConfig.NetworkMode}}|{{json .HostConfig.PortBindings}}|{{.Config.User}}|{{range .Mounts}}{{.Type}}:{{.Destination}};{{end}}'
    outputs = []
    for arguments in (['image', 'inspect', lab.IMAGE, '--format', '{{.Id}}'], ['inspect', lab.CONTAINER, '--format', template]):
        try:
            result = subprocess.run(['docker', *arguments], capture_output=True, text=True, encoding='utf-8', timeout=remaining(deadline, 'startup'))
        except (OSError, TimeoutError, subprocess.SubprocessError):
            raise RuntimeError('User fence startup inspection unavailable') from None
        if result.returncode:
            raise RuntimeError('User fence startup inspection failed')
        remaining(deadline, 'startup')
        outputs.append(result.stdout.strip())
    fields = outputs[1].split('|')
    if len(fields) != 6:
        raise RuntimeError('User fence startup inspection invalid')
    metadata = dict(zip(('label', 'image', 'network', 'ports', 'user', 'mounts'), fields))
    try:
        metadata['ports'] = json.loads(metadata['ports'])
        lab.validate_container(metadata, outputs[0])
    except (ValueError, TypeError, RuntimeError):
        raise RuntimeError('User fence startup container mismatch') from None


def metadata_count(statement, timeout=2.0):
    """Đọc duy nhất số nguyên với query/client timeout hữu hạn, không log SQL/error thô.

    Input
    Param: statement — SELECT metadata nội bộ, chỉ nối UUID/PID đã kiểm kiểu.
    Param: timeout — ngân sách client còn lại theo deadline của caller, đơn vị giây.
    Output: một count nguyên không âm; lỗi hoặc output khác không được coi là0.
    Errors: RuntimeError cố định nếu psql/container/timeout/output sai.
    """
    try:
        result = subprocess.run(
            ['docker', 'exec', '-i', lab.CONTAINER, 'psql', '-X', '-qAtw', '-v', 'ON_ERROR_STOP=1',
             '-h', '/tmp', '-U', lab.ADMIN, '-d', DATABASE],
            input="SET statement_timeout='1s';\n" + statement,
            capture_output=True, text=True, encoding='utf-8', timeout=max(.001, timeout),
        )
    except (OSError, TimeoutError, subprocess.SubprocessError):
        raise RuntimeError('User fence metadata unavailable') from None
    output = result.stdout.strip()
    if result.returncode or not output.isdigit():
        raise RuntimeError('User fence metadata invalid')
    return int(output)


def owned_predicate(alias, run_id):
    """Giới hạn fixture bằng UUID lượt chạy và provenance, không dùng journal làm quyền tự khai.

    Input
    Param: alias — tên SQL literal nội bộ target/source, không lấy từ client.
    Param: run_id — UUID lượt chạy đã parse, tạo prefix email synthetic và marker DB.
    Output: predicate nội bộ; không chứa password/verifier hoặc giá trị tùy ý.
    """
    if alias not in ('target', 'source'):
        raise ValueError('Invalid fixture alias')
    run = str(UUID(str(run_id)))
    return f"{alias}.email_normalized LIKE 'probe-{run}-%@example.invalid' AND {alias}.activation_provenance IN ('AUTH_HTTP_LAB:{run}','SELF_PASSWORD_CHANGE')"


def set_fixture_state(run_id, target_id, seed_id, status):
    """Chuẩn bị/khôi phục target không membership bằng PHC seed chỉ copy bên trong DB.

    Input
    Param: run_id — marker owned role và prefix identity synthetic của lượt chạy.
    Param: target_id — UUID account1 hoặc2 do launcher cấp, không phải Admin workspace.
    Param: seed_id — UUID account4 còn PHC seed; không đọc PHC vào Python.
    Param: status — ACTIVE/DISABLED literal theo giai đoạn test, không reset limiter.
    Errors: sai ownership/row count/readback/SQL làm FAIL, không xuất SQL diagnostics.
    Side effects: thay đúng một fixture; caller chỉ dùng trong verify và launcher cleanup graph.
    """
    target = str(UUID(str(target_id)))
    source = str(UUID(str(seed_id)))
    if status not in ('ACTIVE', 'DISABLED') or target == source:
        raise ValueError('Invalid fixture transition')
    if not repository.owns_probe(run_id):
        raise RuntimeError('User fence ownership mismatch')
    predicate = owned_predicate('target', run_id) + ' AND ' + owned_predicate('source', run_id)
    # UUID parse trước khi dùng psql quote; PHC chỉ chuyển giữa hai row thuộc cùng lượt chạy.
    statement = f"""BEGIN;
SET LOCAL lock_timeout='2s'; SET LOCAL statement_timeout='2s';
UPDATE users target SET password_hash=source.password_hash,account_status='{status}'
FROM users source WHERE target.user_id=:'auth_fault_user_id'::uuid
AND source.user_id=:'auth_fault_correlations'::uuid AND {predicate}
AND NOT target.must_change_password
AND NOT EXISTS(SELECT 1 FROM memberships WHERE user_id=target.user_id) RETURNING 1;
COMMIT;
SELECT CASE WHEN target.account_status='{status}' AND target.password_hash=source.password_hash
THEN 1 ELSE 0 END FROM users target,users source
WHERE target.user_id=:'auth_fault_user_id'::uuid AND source.user_id=:'auth_fault_correlations'::uuid AND {predicate};"""
    result = lab.sql(statement, role=lab.ADMIN, database=DATABASE, check=False,
                     variables=(('auth_fault_user_id', target), ('auth_fault_correlations', source)))
    if result.returncode or result.stdout.split() != ['1', '1']:
        raise RuntimeError('User fence fixture transition unverified')


class UserFenceHolder:
    """Sở hữu đúng psql process/backend; launcher giữ object trước start để không mất quyền cleanup."""

    def __init__(self, run_id, target_id, changed_source_id):
        """Chỉ nhận UUID fixture, chuẩn bị identity backend riêng mà chưa mở process.

        Input
        Param: run_id — UUID owned probe, kiểm lại trước start.
        Param: target_id — UUID target không membership cần khóa User.
        Param: changed_source_id — UUID fixture có PHC khác seed cho password race.
        """
        self.run_id = UUID(str(run_id))
        self.target_id = UUID(str(target_id))
        self.changed_source_id = UUID(str(changed_source_id))
        self.application_name = 'iot_auth_fence_' + uuid4().hex
        self.process = None
        self.reader = None
        self.lines = queue.Queue(maxsize=16)
        self.pid = None

    def collect_lines(self):
        """Thu tối đa16marker/PID vào RAM; không log hoặc giữ output vô hạn khi protocol sai."""
        for line in self.process.stdout:
            try:
                self.lines.put_nowait(line.strip())
            except queue.Full:
                return

    def read_marker(self, expected, timeout):
        """Đọc một marker theo deadline tuyệt đối, không gia hạn vì stdout phát dữ liệu lạ.

        Input
        Param: expected — marker literal hoặc FENCE_READY với hậu tố PID dương.
        Param: timeout — số giây còn lại của startup/commit budget.
        Output: PID khi READY, None cho marker đúng; lỗi luôn cố định.
        """
        deadline = time.monotonic() + timeout
        try:
            line = self.lines.get(timeout=remaining(deadline, 'marker'))
        except queue.Empty:
            raise RuntimeError('User fence marker timeout') from None
        remaining(deadline, 'marker')
        if expected == 'FENCE_READY' and line.startswith('FENCE_READY|') and line.count('|') == 1:
            value = line.split('|')[1]
            if value.isdigit() and int(value) > 0:
                return int(value)
        elif line == expected:
            return None
        raise RuntimeError('User fence marker invalid')

    def send(self, statement):
        """Gửi SQL nguồn nội bộ qua stdin của đúng psql đang sở hữu, không dùng shell.

        Input
        Param: statement — SQL chỉ chứa UUID đã parse/literal của harness, không credential thô.
        Errors: process đóng hoặc pipe hỏng được lọc để không xuất câu SQL.
        """
        if self.process is None or self.process.poll() is not None:
            raise RuntimeError('User fence process unavailable')
        try:
            self.process.stdin.write(statement + '\n')
            self.process.stdin.flush()
        except (OSError, ValueError):
            raise RuntimeError('User fence process pipe unavailable') from None

    def start(self):
        """Mở holder canonical, xác nhận khóa đúng User bằng READY phát sau SELECT FOR UPDATE.

        Errors: role/container/fixture/marker sai thì FAIL; object vẫn thuộc registry launcher.
        Side effects: transaction chỉ khóa target; idle timeout10s tự chặn holder bị bỏ quên.
        """
        deadline = time.monotonic() + STARTUP_TIMEOUT
        # Kiểm marker role bằng SELECT bounded, không dùng adapter mặc định120s trong startup budget5s.
        statement = f"SELECT count(*) FROM pg_roles WHERE rolname='iot_repository_probe' AND shobj_description(oid,'pg_authid')='Temporary canonical repository verification:{self.run_id}';"
        if self.process is not None or metadata_count(statement, remaining(deadline, 'startup')) != 1:
            raise RuntimeError('User fence ownership mismatch')
        remaining(deadline, 'startup')
        inspect_owned_lab(deadline)
        # application_name từ UUID riêng được gắn ngay startup để tìm backend kể cả chưa nhận READY.
        connection = f'dbname={DATABASE} application_name={self.application_name} connect_timeout=3'
        self.process = subprocess.Popen(
            ['docker', 'exec', '-i', lab.CONTAINER, 'psql', '-X', '-qAtw', '-v', 'ON_ERROR_STOP=1',
             '-h', '/tmp', '-U', lab.ADMIN, '-d', connection],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            text=True, encoding='utf-8', creationflags=subprocess.CREATE_NO_WINDOW,
        )
        self.reader = threading.Thread(target=self.collect_lines, daemon=True)
        self.reader.start()
        predicate = owned_predicate('target', self.run_id)
        # Target không membership tránh trigger last-admin; marker chỉ tồn tại nếu chính row đã khóa.
        self.send(f"""SET statement_timeout='2s'; SET lock_timeout='2s';
SET idle_in_transaction_session_timeout='10s'; BEGIN;
SELECT 'FENCE_READY|'||pg_backend_pid() FROM users target
WHERE user_id='{self.target_id}'::uuid AND {predicate}
AND account_status='ACTIVE' AND NOT must_change_password
AND NOT EXISTS(SELECT 1 FROM memberships WHERE user_id=target.user_id) FOR UPDATE;""")
        self.pid = self.read_marker('FENCE_READY', remaining(deadline, 'startup'))

    def wait_for_blocked(self):
        """Xác nhận probe thực sự chờ Lock do chính holder PID; không đọc query text.

        Errors: không thấy đúng một waiter trong3s, holder chết hoặc metadata lỗi đều FAIL.
        Output: không trả PID/correlation ra report; thành công là quan sát blocker relation thật.
        """
        if self.pid is None:
            raise RuntimeError('User fence wait requires ready holder')
        deadline = time.monotonic() + OBSERVE_TIMEOUT
        while time.monotonic() < deadline:
            if self.process.poll() is not None:
                raise RuntimeError('User fence wait lost holder')
            # Role/DB literal; PID dương được parse từ READY của chính process, không chọn process để kill.
            statement = f"SELECT count(*) FROM pg_stat_activity WHERE datname='{DATABASE}' AND usename='iot_repository_probe' AND wait_event_type='Lock' AND {self.pid}=ANY(pg_blocking_pids(pid));"
            count = metadata_count(statement, min(2.0, max(.001, deadline - time.monotonic())))
            remaining(deadline, 'wait')
            if count == 1:
                return
            if count > 1:
                raise RuntimeError('User fence wait is not isolated')
            time.sleep(min(.05, max(0, deadline - time.monotonic())))
        raise RuntimeError('User fence wait not observed')

    def commit(self, kind):
        """Thay PHC hoặc status dưới User fence rồi nhận COMMITTED chỉ sau COMMIT thành công.

        Input
        Param: kind — password/status literal nội bộ; source PHC vẫn chỉ ở PostgreSQL.
        Errors: không đổi đúng một row hoặc commit lỗi thì không phát marker hợp lệ.
        """
        predicate = owned_predicate('target', self.run_id)
        if kind == 'password':
            source_predicate = owned_predicate('source', self.run_id)
            statement = f"UPDATE users target SET password_hash=source.password_hash FROM users source WHERE target.user_id='{self.target_id}'::uuid AND source.user_id='{self.changed_source_id}'::uuid AND {predicate} AND {source_predicate} AND target.password_hash<>source.password_hash RETURNING 'FENCE_CHANGED';"
        elif kind == 'status':
            statement = f"UPDATE users target SET account_status='DISABLED' WHERE target.user_id='{self.target_id}'::uuid AND {predicate} AND account_status='ACTIVE' RETURNING 'FENCE_CHANGED';"
        else:
            raise ValueError('Invalid user fence transition kind')
        self.send(statement + "\nCOMMIT;\n\\echo FENCE_COMMITTED")
        deadline = time.monotonic() + STARTUP_TIMEOUT
        self.read_marker('FENCE_CHANGED', max(.001, deadline - time.monotonic()))
        self.read_marker('FENCE_COMMITTED', max(.001, deadline - time.monotonic()))

    def stop(self):
        """Đóng/join đúng child và reader, rồi kiểm backend riêng đã biến mất trước fixture cleanup.

        Errors: chưa chứng minh process/reader/backend đã dừng thì giữ registry/journal và FAIL.
        Side effects: chỉ terminate/kill Popen sở hữu; không kill backend hoặc AVD/process ngoài scope.
        """
        if self.process is None:
            return
        deadline = time.monotonic() + SHUTDOWN_TIMEOUT
        if self.process.poll() is None:
            self.process.stdin.close()
            try:
                # Chừa ngân sách cho terminate/kill, reader join và backend-gone readback trong cùng5s.
                self.process.wait(timeout=min(1.0, remaining(deadline, 'shutdown')))
            except subprocess.TimeoutExpired:
                self.process.terminate()
                try:
                    self.process.wait(timeout=min(1.0, remaining(deadline, 'shutdown')))
                except subprocess.TimeoutExpired:
                    self.process.kill()
                    self.process.wait(timeout=min(1.0, remaining(deadline, 'shutdown')))
        if self.reader is not None:
            self.reader.join(timeout=min(1.0, remaining(deadline, 'shutdown')))
            if self.reader.is_alive():
                raise RuntimeError('User fence reader shutdown unverified')
        self.process.stdout.close()
        # Tên riêng sinh trước Popen chứng minh identity ngay cả nếu startup chưa trả PID.
        statement = f"SELECT count(*) FROM pg_stat_activity WHERE datname='{DATABASE}' AND usename='{lab.ADMIN}' AND application_name='{self.application_name}';"
        while time.monotonic() < deadline:
            count = metadata_count(statement, min(2.0, remaining(deadline, 'backend')))
            remaining(deadline, 'backend')
            if count == 0:
                return
            time.sleep(min(.05, max(0, deadline - time.monotonic())))
        raise RuntimeError('User fence backend shutdown unverified')
