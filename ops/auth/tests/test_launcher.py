"""Kiểm recovery guard bằng spy; không mở Docker, PostgreSQL hoặc thay dữ liệu lab."""

import importlib.util
import json
import sys
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import MagicMock, patch
from uuid import uuid4

AUTH_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(AUTH_ROOT))
SPEC = importlib.util.spec_from_file_location("auth_local_launcher", AUTH_ROOT / "run_local.py")
launcher = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(launcher)


class RecoveryOwnershipTests(unittest.TestCase):
    """Chứng minh recovery không chạm DB khi path hoặc quyền sở hữu vòng đời chưa an toàn."""

    def test_outside_journal_namespace_stops_before_database(self):
        """Path ngoài thư mục ownership phải bị từ chối trước mọi inspect/SQL."""
        with patch.object(launcher.lab, "inspect_lab") as inspect:
            with self.assertRaises(ValueError):
                launcher.recover(AUTH_ROOT / "outside.json")
            inspect.assert_not_called()

    def test_active_role_stops_before_fixture_cleanup(self):
        """Role còn tồn tại có thể thuộc server sống; recovery phải giữ nguyên fixture và journal."""
        run_id = str(uuid4())
        journal = AUTH_ROOT / "ownership" / (run_id + ".json")
        record = {"runId": run_id, "userIds": [str(uuid4()) for _ in range(5)], "limiterBucketDigests": ["a" * 64], "purpose": "AUTH_HTTP_LAB", "database": "iot_platform_lab"}
        with patch.object(Path, "read_text", return_value=json.dumps(record)), patch.object(Path, "write_text") as write, patch.object(launcher.lab, "inspect_lab"), patch.object(launcher.lab, "sql", return_value=SimpleNamespace(stdout="t")), patch.object(launcher, "cleanup") as cleanup:
            with self.assertRaises(RuntimeError):
                launcher.recover(journal)
            cleanup.assert_not_called()
            write.assert_not_called()

    def test_forged_journal_cannot_authorize_bucket_deletion(self):
        """Journal đúng shape nhưng UUID không tồn tại/digest tùy ý không được tạo DELETE limiter, kể cả role không còn."""
        run_id = str(uuid4())
        journal = AUTH_ROOT / "ownership" / (run_id + ".json")
        record = {"runId": run_id, "userIds": [str(uuid4()) for _ in range(5)], "limiterBucketDigests": ["a" * 64], "purpose": "AUTH_HTTP_LAB", "database": "iot_platform_lab"}
        with patch.object(Path, "read_text", return_value=json.dumps(record)), patch.object(Path, "write_text"), patch.object(launcher.lab, "inspect_lab"), patch.object(launcher.lab, "sql", return_value=SimpleNamespace(stdout="f", returncode=0)) as sql, patch("builtins.print"):
            launcher.recover(journal)
            statements = [call.args[0] for call in sql.call_args_list]
            self.assertFalse(any("DELETE FROM login_attempt_buckets" in statement for statement in statements))
            self.assertFalse(any("a" * 64 in statement for statement in statements))


class LabLifecycleTests(unittest.TestCase):
    """Peer startup lỗi phải dừng đúng child của launcher, không bỏ process sống trước fixture cleanup."""

    def test_failed_start_stops_only_the_spawned_child(self):
        """Marker không hợp lệ phải fail và terminate/wait chính child, không đưa config vào exception."""
        child = MagicMock()
        child.poll.return_value = None
        child.stdout.readline.return_value = 'AUTH_LAB_FAILED\n'
        with patch.object(launcher.subprocess, 'Popen', return_value=child):
            with self.assertRaisesRegex(RuntimeError, 'Auth lab failed to initialize') as caught:
                launcher.start_lab({'databasePassword': 'synthetic-private-value'})
        child.terminate.assert_called_once_with()
        child.wait.assert_called_once_with(timeout=15)
        self.assertNotIn('synthetic-private-value', str(caught.exception))

    def test_stop_escalates_only_owned_live_child_after_timeout(self):
        """Child không dừng sau terminate mới kill theo handle đã sở hữu, rồi chờ thoát trước cleanup."""
        child = MagicMock()
        child.poll.return_value = None
        child.wait.side_effect = [launcher.subprocess.TimeoutExpired('owned-child', 15), 0]
        launcher.stop_lab(child)
        child.terminate.assert_called_once_with()
        child.kill.assert_called_once_with()
        self.assertEqual(child.wait.call_count, 2)

    def test_invalid_peer_port_stops_before_database(self):
        """Verify cần hai cổng hợp lệ, không provision rồi mới phát hiện port65536."""
        with patch.object(launcher.lab, 'inspect_lab') as inspect, patch.object(launcher.lab, 'sql') as sql:
            with self.assertRaises(ValueError):
                launcher.run(True, 65535)
        inspect.assert_not_called()
        sql.assert_not_called()

    def test_peer_start_failure_stops_primary_before_cleanup(self):
        """Special được stop trước normal; peer lỗi vẫn dừng primary trước cleanup và không gọi provider."""
        server = MagicMock()
        server.server_address = ('127.0.0.1', 4000)
        special, primary = MagicMock(), MagicMock()
        ordered = MagicMock()
        # Server đã là fake không I/O; giữ thread thật để cleanup mới xác minh worker terminal thay vì mock toàn bộ threading.
        with patch.object(launcher.lab, 'inspect_lab'), patch.object(launcher.lab, 'sql', return_value=SimpleNamespace(stdout=str(len(launcher.repository.platform.SOURCE_NAMES)))), patch.object(launcher.subprocess, 'run', return_value=SimpleNamespace(returncode=0)), patch.object(launcher.subprocess, 'Popen', side_effect=AssertionError('Unpatched process boundary')), patch('http.client.HTTPConnection', side_effect=AssertionError('Unpatched HTTP boundary')), patch.object(Path, 'mkdir'), patch.object(Path, 'write_text'), patch.object(launcher, 'provision'), patch.object(launcher.bridge, 'InspectionServer', return_value=server), patch.object(launcher, 'CommitAckServer'), patch.object(launcher, 'start_lab', side_effect=[special, primary, RuntimeError('Auth lab failed to initialize')]) as start, patch.object(launcher, 'verify_realtime_sqlx_checkout') as realtime_sqlx, patch.object(launcher, 'set_fixture_session_read_access') as session_acl, patch('verify_pool_budget.PoolBudgetChild') as pool_child, patch('verify_pool_budget.verify_pool_budget') as verify_pool, patch('verify_provider.verify_provider') as provider, patch.object(launcher, 'stop_lab') as stop, patch.object(launcher, 'cleanup') as cleanup, patch.object(launcher, 'revoke') as revoke, patch.object(launcher.repository, 'owns_probe', return_value=True):
            def verify_special(*args):
                """Thu hồi special trước startup normal, mô phỏng verifier đã STOPPED và reap thành công.

                Input
                Param: args — đối số verifier; phần tử đầu phải là wrapper child do test sở hữu.
                Output: danh sách check rỗng vì test chỉ xác minh vòng đời process, không chạy provider.
                """
                self.assertEqual(start.call_count, 1)
                self.assertIs(args[0], pool_child.return_value)
                stop(special)
                return []

            verify_pool.side_effect = verify_special
            ordered.attach_mock(start, 'start')
            ordered.attach_mock(stop, 'stop')
            ordered.attach_mock(cleanup, 'cleanup')
            ordered.attach_mock(revoke, 'revoke')
            with self.assertRaisesRegex(RuntimeError, 'Auth lab failed to initialize'):
                launcher.run(True, 3001)
        self.assertEqual([call[0] for call in ordered.mock_calls], ['start', 'stop', 'start', 'start', 'stop', 'stop', 'cleanup', 'revoke'])
        self.assertIs(stop.call_args_list[0].args[0], special)
        self.assertIs(stop.call_args_list[1].args[0], primary)
        self.assertIs(stop.call_args_list[2].args[0], special)
        realtime_sqlx.assert_called_once()
        self.assertEqual([call.args[1] for call in session_acl.call_args_list], [False, True])
        provider.assert_not_called()


class RealtimeSqlxVerifierTests(unittest.TestCase):
    """Kiểm exact marker, lỗi cố định và ranh giới stdin của test PostgreSQL."""

    def test_exact_test_pass_uses_stdin_and_adds_both_evidence_markers(self):
        """Chỉ đánh dấu direct probe khi đúng ignored test PostgreSQL kết thúc thành công."""
        password = "a" * 64
        output = (
            b"running 1 test\n"
            b"test http::realtime::tests::sqlx_canceled_query_closes_checkout_before_permit_release ... ok\n"
        )
        checks = []
        with patch.object(
                launcher.subprocess, "run",
                return_value=SimpleNamespace(returncode=0, stdout=output, stderr=b"")) as run:
            launcher.verify_realtime_sqlx_checkout(4000, password, checks)

        self.assertEqual(checks, [
            "realtime-sqlx-canceled-checkout-before-permit-release",
            "realtime-adapter-session-denial-checkout-close-before-permit-release",
        ])
        command = run.call_args.args[0]
        self.assertNotIn(password, command)
        self.assertEqual(json.loads(run.call_args.kwargs["input"]), {
            "database_port": 4000,
            "database_password": password,
        })

    def test_missing_exact_test_uses_fixed_error_and_does_not_add_marker(self):
        """Cargo exit 0 không đủ nếu SQLx probe không chạy hoặc tên test đã đổi."""
        checks = []
        output = b"running 1 test\ntest http::realtime::tests::other_probe ... ok\n"
        with patch.object(
                launcher.subprocess, "run",
                return_value=SimpleNamespace(returncode=0, stdout=output, stderr=b"")):
            with self.assertRaisesRegex(
                    RuntimeError, "^REALTIME_SQLX_TEST_FAILED_BEFORE_CONFIG_VALIDATION$"):
                launcher.verify_realtime_sqlx_checkout(4000, "a" * 64, checks)
        self.assertEqual(checks, [])

    def test_raw_child_diagnostic_is_not_returned_to_caller(self):
        """Failure chỉ trả allowlisted stage code, không đưa raw child output vào exception."""
        sentinel = "synthetic-output-sentinel"
        output = b"running 1 test\nREALTIME_SQLX_STAGE_POOL_CONNECTED\n" + sentinel.encode()
        checks = []
        with patch.object(
                launcher.subprocess, "run",
                return_value=SimpleNamespace(returncode=1, stdout=output, stderr=output)):
            with self.assertRaisesRegex(RuntimeError, "^REALTIME_SQLX_TEST_CHECKOUT_FAILED$") as caught:
                launcher.verify_realtime_sqlx_checkout(4000, "a" * 64, checks)
        self.assertNotIn(sentinel, str(caught.exception))
        self.assertEqual(checks, [])

    def test_child_timeout_uses_fixed_error(self):
        """Timeout Cargo không trả stderr/process detail có thể chứa fixture data."""
        with patch.object(
                launcher.subprocess, "run",
                side_effect=launcher.subprocess.TimeoutExpired("cargo", 180)):
            with self.assertRaisesRegex(RuntimeError, "^REALTIME_SQLX_TEST_RUNNER_TIMEOUT$"):
                launcher.verify_realtime_sqlx_checkout(4000, "a" * 64, [])


class RealtimeTicketLabPrivilegeTests(unittest.TestCase):
    """Quyền consume realtime của role fixture phải có cặp cấp/thu hồi trước DROP ROLE."""

    def test_temporary_role_grants_and_revokes_ticket_consumer(self):
        """Auth Lab cấp đúng hàm consume ticket và thu hồi grant đó trước khi drop role test."""
        run_id = uuid4()
        sql_result = SimpleNamespace(returncode=0, stdout="")
        with patch.object(launcher.lab, "sql", return_value=sql_result) as sql, \
                patch.object(launcher.repository, "scoped_hba"), \
                patch.object(launcher.repository, "owns_probe", return_value=True):
            launcher.provision("a" * 64, run_id)
            launcher.revoke(run_id)

        statements = [call.args[0] for call in sql.call_args_list]
        self.assertEqual(len(statements), 2)
        self.assertIn(
            "GRANT EXECUTE ON FUNCTION public.consume_websocket_ticket(bytea) TO iot_repository_probe;",
            statements[0],
        )
        revoke_statement = (
            "REVOKE ALL ON FUNCTION public.consume_websocket_ticket(bytea) "
            "FROM iot_repository_probe;"
        )
        self.assertIn(revoke_statement, statements[1])
        self.assertLess(statements[1].index(revoke_statement), statements[1].index("DROP ROLE iot_repository_probe;"))


class RealtimeDatabaseFailureFixtureTests(unittest.TestCase):
    """Fault injection chỉ được đổi quyền đọc bảng session của role thuộc lượt Auth Lab."""

    def test_session_read_access_toggle_is_owned_and_restorable(self):
        """Verifier có thể tạo lỗi SELECT rồi khôi phục đúng ACL trước khi fixture cleanup."""
        run_id = uuid4()
        sql_results = [
            SimpleNamespace(returncode=0, stdout=''),
            SimpleNamespace(returncode=0, stdout='f'),
            SimpleNamespace(returncode=0, stdout=''),
            SimpleNamespace(returncode=0, stdout='t'),
        ]
        with patch.object(launcher.repository, 'owns_probe', return_value=True), patch.object(
                launcher.lab, 'sql', side_effect=sql_results) as sql:
            launcher.set_fixture_session_read_access(run_id, False)
            launcher.set_fixture_session_read_access(run_id, True)

        self.assertEqual(len(sql.call_args_list), 4)
        self.assertIn('REVOKE SELECT ON TABLE public.sessions FROM iot_repository_probe;',
                      sql.call_args_list[0].args[0])
        self.assertIn('GRANT SELECT ON TABLE public.sessions TO iot_repository_probe;',
                      sql.call_args_list[2].args[0])
        self.assertTrue(all(call.kwargs['role'] == launcher.lab.ADMIN for call in sql.call_args_list))

        with patch.object(launcher.repository, 'owns_probe', return_value=False), patch.object(
                launcher.lab, 'sql') as sql:
            with self.assertRaisesRegex(RuntimeError, '^Auth lab realtime ACL ownership check failed$'):
                launcher.set_fixture_session_read_access(run_id, False)
        sql.assert_not_called()


class AuthLabFixtureCleanupTests(unittest.TestCase):
    """Dọn đúng installation gắn phiên trước khi xóa session tham chiếu."""

    def test_push_installations_are_removed_before_owned_sessions(self):
        """Fixture phải dùng khóa active_user_id thật để không để FK hoặc push metadata mồ côi."""
        user_ids = [uuid4() for _ in range(5)]
        with patch.object(launcher.lab, "sql", return_value=SimpleNamespace(returncode=0)) as sql:
            launcher.cleanup(uuid4(), user_ids, [])

        statement = sql.call_args.args[0]
        delete_installations = "DELETE FROM push_installations WHERE active_user_id IN ("
        self.assertIn(delete_installations, statement)
        self.assertLess(statement.index(delete_installations), statement.index("DELETE FROM sessions"))


class FixturePasswordTests(unittest.TestCase):
    """Kiểm policy config tổng hợp mà không gọi launcher run, Docker hoặc SQL."""

    def test_fixture_passwords_match_shared_policy(self):
        """Mật khẩu seed lab mới phải cùng oracle với backend/Web/App, không dùng hex lowercase yếu."""
        fixture = json.loads((AUTH_ROOT.parents[1] / 'contracts/fixtures/auth/password-policy.json').read_text(encoding='utf-8'))
        for case in fixture['cases']:
            with self.subTest(case=case['id']):
                if case['newError'] is None:
                    launcher.validate_fixture_password(case['password'])
                else:
                    with self.assertRaises(ValueError):
                        launcher.validate_fixture_password(case['password'])


class DockerCliIsolationTests(unittest.TestCase):
    """Bảo đảm Auth Lab không dùng nhầm Docker credential config của người chạy."""

    def test_docker_argv_uses_workspace_isolated_config(self):
        """Giữ nguyên argv Docker sau config tường minh nằm trong namespace Auth Lab."""
        arguments = launcher.lab.docker_argv("exec", "iot-postgres17-database")

        self.assertEqual(arguments[:2], ["docker", "--config"])
        self.assertEqual(Path(arguments[2]), AUTH_ROOT / ".auth-lab-docker-config")
        self.assertEqual(arguments[3:], ["exec", "iot-postgres17-database"])


if __name__ == "__main__":
    unittest.main()
