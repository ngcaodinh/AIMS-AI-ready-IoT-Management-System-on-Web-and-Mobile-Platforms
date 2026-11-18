"""Điều phối các transaction PostgreSQL thật bằng marker và lock evidence, không đoán race bằng sleep."""

import queue
import re
import subprocess
import threading
import time
from uuid import uuid4

import verify_database as lab


class SqlSession:
    """Giữ một psql connection để kiểm snapshot và thời điểm commit giữa hai transaction."""

    # Mỗi session chỉ vào container/DB lab do caller đã xác minh, với timeout test hữu hạn.
    def __init__(self, container, role, database, isolation):
        """Input
        Param: container — container PostgreSQL lab đã định danh.
        Param: role — migrator lab, không phải credential.
        Param: database — DB test mới của lần chạy.
        Param: isolation — READ COMMITTED hoặc REPEATABLE READ được test.
        Side effects: mở psql và transaction riêng qua config Docker cô lập; không đọc environment hoặc app data thật.
        """
        if isolation not in ("READ COMMITTED", "REPEATABLE READ"):
            raise ValueError("Unexpected test isolation")
        self.process = subprocess.Popen(
            lab.docker_argv("exec", "-i", container, "psql", "-X", "-q", "-A", "-t", "-w", "-v", "ON_ERROR_STOP=1", "-h", "/tmp", "-U", role, "-d", database),
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            text=True, encoding="utf-8", bufsize=1,
        )
        self.events = queue.Queue()
        self.output = []
        self.reader = threading.Thread(target=self.read_output, daemon=True)
        self.reader.start()
        self.send(
            "\\set VERBOSITY verbose\n"
            f"BEGIN ISOLATION LEVEL {isolation};\n"
            "SET LOCAL lock_timeout='10s'; SET LOCAL statement_timeout='20s'; "
            "SET LOCAL idle_in_transaction_session_timeout='30s';\n"
            "SELECT pg_backend_pid() AS test_backend_pid \\gset\n"
            "\\echo BACKEND :test_backend_pid\n"
        )
        self.backend_pid = int(self.wait_for("BACKEND ").split()[1])

    # Đọc stdout qua hàng đợi để marker có deadline, không block vô hạn trên pipe Windows.
    def read_output(self):
        """Side effects: thu output tổng hợp của session; EOF là một event riêng cho waiter."""
        for line in self.process.stdout:
            self.output.append(line)
            self.events.put(line.strip())
        self.events.put(None)

    # Stdin chỉ nhận câu SQL test cố định hoặc UUID/pid sinh nội bộ đã chuẩn hóa.
    def send(self, statement):
        """Input
        Param: statement — SQL/marker của harness, không nhận input API.
        Errors: pipe đóng hoặc psql đã thoát; Side effects: gửi vào connection này.
        """
        self.process.stdin.write(statement + "\n")
        self.process.stdin.flush()

    # Chờ tín hiệu thật từ psql, phân biệt EOF/timeout với việc transaction đã đến barrier.
    def wait_for(self, prefix):
        """Input
        Param: prefix — tiền tố marker duy nhất cần thấy.
        Output: dòng marker; Errors: thiếu marker hoặc deadline20s.
        """
        deadline = time.monotonic() + 20
        while True:
            line = self.events.get(timeout=max(0.01, deadline - time.monotonic()))
            if line is None:
                raise RuntimeError("Session exited before marker: " + "".join(self.output))
            if line.startswith(prefix):
                return line

    # Commit/rollback có deadline; sau wait mới đọc log đầy đủ để không mất SQLSTATE.
    def finish(self, statement="COMMIT;"):
        """Input
        Param: statement — kết thúc transaction, mặc định COMMIT.
        Output: exit code và log synthetic; Errors: process vượt deadline.
        """
        pipe_failed = False
        try:
            self.send(statement)
        except OSError:
            # Windows có thể trả EINVAL thay BrokenPipe khi contender đã lỗi; vẫn phải lấy SQLSTATE.
            pipe_failed = True
        try:
            self.process.stdin.close()
        except OSError:
            # close cũng flush buffer; chỉ chấp nhận lỗi này nếu process thật sự thất bại bên dưới.
            pipe_failed = True
        self.process.wait(timeout=25)
        self.reader.join(timeout=2)
        if pipe_failed and self.process.returncode == 0:
            raise RuntimeError("Pipe failed without a PostgreSQL process failure")
        return self.process.returncode, "".join(self.output)

    # Chỉ kết thúc process do harness tạo; idle/statement timeout phía server là guard bổ sung.
    def close(self):
        """Side effects: rollback session đang sống hoặc kill client riêng khi không thoát đúng hạn."""
        if self.process.poll() is None:
            try:
                self.finish("ROLLBACK;")
            except (OSError, subprocess.TimeoutExpired):
                self.process.kill()
                self.process.wait(timeout=5)
        self.reader.join(timeout=2)
        self.process.stdout.close()


# Fixture mỗi race có UUID/email riêng, hai User full và workspace có ít nhất một capable Admin.
def create_fixture(sql, database, two_admins=True):
    """Input
    Param: sql — adapter lab đã kiểm target.
    Param: database — DB concurrency riêng.
    Param: two_admins — có cấp cả hai membership ADMIN ngay lúc tạo hay không.
    Output: UUID workspace/User thứ nhất/User thứ hai; Side effects: commit fixture tổng hợp.
    """
    workspace, first_user, second_user = (str(uuid4()) for _ in range(3))
    second_membership = f"INSERT INTO memberships(workspace_id,user_id,role) VALUES('{workspace}','{second_user}','ADMIN');" if two_admins else ""
    # Các UUID do uuid4 sinh và email .invalid, không lấy input người dùng để ghép SQL.
    sql(
        "BEGIN;"
        f"INSERT INTO users(id,email_normalized,password_hash,status) VALUES('{first_user}','{first_user}@example.invalid','synthetic-non-authenticating-verifier','ACTIVE'),('{second_user}','{second_user}@example.invalid','synthetic-non-authenticating-verifier','ACTIVE');"
        f"INSERT INTO workspaces(id,name,created_by) VALUES('{workspace}','Synthetic concurrency workspace','{first_user}');"
        f"INSERT INTO memberships(workspace_id,user_id,role) VALUES('{workspace}','{first_user}','ADMIN');"
        + second_membership + "COMMIT;", database=database,
    )
    return workspace, first_user, second_user


# Chứng minh contender bị chặn bởi đúng transaction đầu trước khi cho transaction đầu commit.
def wait_for_block(sql, database, blocker_pid, waiter_pid):
    """Input
    Param: sql — adapter lab; database — DB test; blocker_pid/waiter_pid — pid PostgreSQL đã parse int.
    Errors: thiếu quan hệ blocking trong5s; không dùng sleep làm bằng chứng race.
    """
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        if sql(f"SELECT {int(blocker_pid)}=ANY(pg_blocking_pids({int(waiter_pid)}));", database=database).stdout.strip() == "t":
            return
        time.sleep(0.05)
    raise RuntimeError("Contender never reached the expected PostgreSQL lock barrier")


# Kiểm một winner và một loser đúng SQLSTATE, rồi đối chiếu capable Admin còn lại trên DB thật.
def verify_concurrency(sql, container, role, database):
    """Input
    Param: sql — adapter target-validated của runner.
    Param: container — container đã xác minh; role — migrator lab; database — DB test mới.
    Output: sáu kết quả RC/RR với SQLSTATE/barrier; Errors: race không giữ invariant hoặc lỗi khác.
    """
    results = []
    for isolation in ("READ COMMITTED", "REPEATABLE READ"):
        for operation in ("demote", "disable"):
            workspace, first_user, second_user = create_fixture(sql, database)
            first = second = None
            try:
                first = SqlSession(container, role, database, isolation)
                first.send(f"UPDATE memberships SET role='USER' WHERE workspace_id='{workspace}' AND user_id='{first_user}';\n\\echo FIRST_UPDATED")
                first.wait_for("FIRST_UPDATED")
                second = SqlSession(container, role, database, isolation)
                statement = (
                    f"UPDATE memberships SET role='USER' WHERE workspace_id='{workspace}' AND user_id='{second_user}';"
                    if operation == "demote" else f"UPDATE users SET status='DISABLED' WHERE id='{second_user}';"
                )
                second.send(statement)
                wait_for_block(sql, database, first.backend_pid, second.backend_pid)
                first_code, first_output = first.finish()
                if first_code:
                    raise RuntimeError("First contender unexpectedly failed: " + first_output)
                second_code, second_output = second.finish()
                state = re.search(r"ERROR:\s+(23514|40001|40P01):", second_output)
                if second_code == 0 or state is None:
                    raise RuntimeError("Losing contender did not reject safely: " + second_output)
                count = sql(f"SELECT count(*) FROM memberships AS member JOIN users AS account ON account.id=member.user_id WHERE member.workspace_id='{workspace}' AND member.role='ADMIN' AND member.status='ACTIVE' AND account.status='ACTIVE' AND NOT account.must_change_password;", database=database).stdout.strip()
                if count != "1":
                    raise RuntimeError("Concurrent mutation lost the last capable administrator")
                results.append({"case": operation, "isolation": isolation, "lock_barrier": "OBSERVED", "winner": "COMMITTED", "loser_sqlstate": state.group(1), "capable_admins": 1})
            finally:
                if first is not None:
                    first.close()
                if second is not None:
                    second.close()

        workspace, first_user, second_user = create_fixture(sql, database, two_admins=False)
        stale = None
        try:
            stale = SqlSession(container, role, database, isolation)
            stale.send(f"SELECT count(*) FROM memberships WHERE user_id='{second_user}';\n\\echo SNAPSHOT_CAPTURED")
            stale.wait_for("SNAPSHOT_CAPTURED")
            sql(f"BEGIN; INSERT INTO memberships(workspace_id,user_id,role) VALUES('{workspace}','{second_user}','ADMIN'); UPDATE memberships SET role='USER' WHERE workspace_id='{workspace}' AND user_id='{first_user}'; COMMIT;", database=database)
            code, output = stale.finish(f"UPDATE users SET status='DISABLED' WHERE id='{second_user}'; COMMIT;")
            expected_state = "40001" if isolation == "REPEATABLE READ" else "23514"
            if code == 0 or re.search(r"ERROR:\s+" + expected_state + ":", output) is None:
                raise RuntimeError("Stale snapshot missed a newly granted administrator: " + output)
            count = sql(f"SELECT count(*) FROM memberships AS member JOIN users AS account ON account.id=member.user_id WHERE member.workspace_id='{workspace}' AND member.role='ADMIN' AND member.status='ACTIVE' AND account.status='ACTIVE' AND NOT account.must_change_password;", database=database).stdout.strip()
            if count != "1":
                raise RuntimeError("Stale snapshot damaged the capable administrator invariant")
            results.append({"case": "new_grant_after_snapshot", "isolation": isolation, "barrier": "SNAPSHOT_THEN_GRANT_COMMIT", "loser_sqlstate": expected_state})
        finally:
            if stale is not None:
                stale.close()
    return results
