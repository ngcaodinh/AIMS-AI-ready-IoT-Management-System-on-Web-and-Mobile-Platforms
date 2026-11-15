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
        with patch.object(launcher.lab, 'inspect_lab'), patch.object(launcher.lab, 'sql', return_value=SimpleNamespace(stdout=str(len(launcher.repository.platform.SOURCE_NAMES)))), patch.object(launcher.subprocess, 'run', return_value=SimpleNamespace(returncode=0)), patch.object(launcher.subprocess, 'Popen', side_effect=AssertionError('Unpatched process boundary')), patch('http.client.HTTPConnection', side_effect=AssertionError('Unpatched HTTP boundary')), patch.object(Path, 'mkdir'), patch.object(Path, 'write_text'), patch.object(launcher, 'provision'), patch.object(launcher.bridge, 'InspectionServer', return_value=server), patch.object(launcher, 'CommitAckServer'), patch.object(launcher, 'start_lab', side_effect=[special, primary, RuntimeError('Auth lab failed to initialize')]) as start, patch('verify_pool_budget.PoolBudgetChild') as pool_child, patch('verify_pool_budget.verify_pool_budget') as verify_pool, patch('verify_provider.verify_provider') as provider, patch.object(launcher, 'stop_lab') as stop, patch.object(launcher, 'cleanup') as cleanup, patch.object(launcher, 'revoke') as revoke, patch.object(launcher.repository, 'owns_probe', return_value=True):
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
        provider.assert_not_called()


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


if __name__ == "__main__":
    unittest.main()
