"""Kiểm shim fixture RAM qua fake boundary, không mở DB/SDK hoặc ghi credential."""

import json
from contextlib import ExitStack
import io
import hashlib
import hmac
import secrets
import subprocess
import sys
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import MagicMock, patch
from uuid import uuid4

sys.path.insert(0, str(Path(__file__).resolve().parent))
import native_lab_fixture as fixture


def synthetic_config():
    """Tạo config synthetic đúng namespace để test validation không che mất các nhánh handoff hiện hữu.

    Output: config RAM mới với UUID riêng và key test công khai32byte, không credential từ môi trường.
    """
    run_id = str(uuid4())
    return {'runId': run_id, 'userIds': [str(uuid4()) for _ in range(5)],
            'emails': [f'probe-{run_id}-{index}@example.invalid' for index in range(5)],
            'signingKey': list(range(32))}


class NativeFixtureTests(unittest.TestCase):
    """Kiểm schema, pending STOP và snapshot không đọc bearer/token verifier."""

    def test_startup_failure_exits_with_open_control_pipe_without_buffered_reader_abort(self):
        """Lỗi trước READY không được làm CPython abort vì daemon giữ buffered stdin lock; process/DB đều fake."""
        code = """import sys,time
from unittest.mock import MagicMock
sys.path.insert(0,'ops/auth')
import native_lab_fixture as fixture
fixture.launcher.run=MagicMock(side_effect=RuntimeError('synthetic startup fault'))
try: fixture.main()
except RuntimeError: pass
time.sleep(.1)
"""
        child = subprocess.Popen([sys.executable, '-X', 'utf8', '-B', '-c', code], cwd=Path(__file__).resolve().parents[2], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            child.stdin.write(json.dumps({'version': 1, 'password': 'Aa1' + secrets.token_hex(16)}).encode() + b'\n')
            child.stdin.flush()
            # Giữ pipe mở như host đang chờ FAILED; communicate() sẽ đóng stdin và che lỗi shutdown này.
            exit_code = child.wait(timeout=5)
            output = child.stdout.read(8193)
            errors = child.stderr.read(8193)
            self.assertEqual(exit_code, 0)
            self.assertEqual(output, b'')
            self.assertFalse(b'_enter_buffered_busy' in errors)
        finally:
            if child.poll() is None:
                child.kill()
            child.wait(timeout=5)
            child.stdin.close()
            child.stdout.close()
            child.stderr.close()

    def test_packet_schema_rejects_extra_fields_and_weak_password(self):
        """Chỉ nhận credential synthetic theo scenario, không nhận cấu hình DB hoặc token ngoài profile offline."""
        packet = {'version': 1, 'password': 'Aa1' + 'a' * 32}
        self.assertEqual(fixture.parse_packet(json.dumps(packet).encode()), packet['password'])
        self.assertEqual(fixture.parse_packet(json.dumps({**packet, 'scenario': 'password'}).encode()), packet['password'])
        self.assertEqual(fixture.parse_packet(json.dumps({**packet, 'scenario': 'rate-limit'}).encode()), packet['password'])
        self.assertEqual(fixture.parse_packet(json.dumps({**packet, 'scenario': 'offline-expired',
                                                         'expiredSessionToken': 'a' * 64}).encode()), packet['password'])
        for scenario in ['full', 35, None, 'password-relogin']:
            with self.assertRaises(ValueError):
                fixture.parse_packet(json.dumps({**packet, 'scenario': scenario}).encode())
        for invalid in [
            {**packet, 'scenario': 'password', 'expiredSessionToken': 'a' * 64},
            {**packet, 'scenario': 'offline-login', 'expiredSessionToken': 'a' * 64},
            {**packet, 'scenario': 'offline-expired'},
            {**packet, 'scenario': 'offline-expired', 'expiredSessionToken': 'b' * 63},
            {**packet, 'scenario': 'offline-expired', 'expiredSessionToken': 'g' * 64},
        ]:
            with self.assertRaises(ValueError):
                fixture.parse_packet(json.dumps(invalid).encode())
        for invalid in [b'{}', b'x' * 4097, json.dumps({**packet, 'port': 9999}).encode(), json.dumps({**packet, 'password': 'weak'}).encode()]:
            with self.assertRaises(ValueError):
                fixture.parse_packet(invalid)

    def test_expired_session_token_is_limited_to_the_expired_profile(self):
        """Chỉ profile expired được giữ bearer synthetic để seed; offline thường không nhận token thừa.

        Input
        Param: không có — profile và token đều synthetic.
        Output: offline-expired cần token đủ dạng; offline-login không thể kích hoạt nhánh INSERT.
        Errors: ValueError cố định nếu cấu hình profile/token vượt hợp đồng fixture.
        """
        token = 'd' * 64
        with self.assertRaises(ValueError):
            fixture.NativeFixtureControl(MagicMock(), MagicMock(), scenario='offline-login',
                                          expired_session_token=token)
        with self.assertRaises(ValueError):
            fixture.NativeFixtureControl(MagicMock(), MagicMock(), scenario='offline-expired')
        control = fixture.NativeFixtureControl(MagicMock(), MagicMock(), scenario='offline-expired',
                                                expired_session_token=token)
        self.assertEqual(control.expired_session_token, token)

    def test_coalesced_packet_and_stop_are_consumed_with_pipe_still_open(self):
        """JSON và STOP cùng một write không bị buffered prefetch nuốt; fake launcher phải thấy STOP trước EOF."""
        code = '''import sys
from unittest.mock import MagicMock
sys.path.insert(0,'ops/auth')
import native_lab_fixture as fixture
from test_native_lab_fixture import synthetic_config
fixture.launcher.start_lab=MagicMock(return_value=MagicMock())
fixture.launcher.stop_lab=MagicMock()
fixture.launcher.lab.sql=MagicMock(side_effect=AssertionError('Unexpected SQL'))
fixture.NativeFixtureControl.verify_cleanup=MagicMock(return_value={})
def fake_run(verify,port):
    """Đợi STOP qua raw pipe trong launcher giả, không gọi DB.
    Input
    Param: verify — cờ normal run từ adapter, không chạy provider.
    Param: port — cổng normal run, không bind trong test này.
    """
    control=fixture.launcher.start_lab.__self__
    fixture.launcher.start_lab(synthetic_config())
    assert control.stopping.wait(2), 'Coalesced STOP not consumed'
fixture.launcher.run=fake_run
fixture.main()
'''
        child = subprocess.Popen([sys.executable, '-X', 'utf8', '-B', '-c', code], cwd=Path(__file__).resolve().parents[2], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            child.stdin.write(json.dumps({'version': 1, 'password': 'Aa1' + secrets.token_hex(16)}).encode() + b'\nSTOP\n')
            child.stdin.flush()
            self.assertEqual(child.wait(timeout=5), 0)
            frames = [json.loads(line) for line in child.stdout.read(8193).splitlines()]
            self.assertTrue(any(frame['kind'] == 'STOPPED' for frame in frames))
        finally:
            if child.poll() is None:
                child.kill()
            child.wait(timeout=5)
            child.stdin.close()
            child.stdout.close()
            child.stderr.close()

    def test_stop_before_ready_stops_child_without_publishing_ready(self):
        """STOP trong build/startup được giữ đến khi shim sở hữu child; không bỏ child sống khi caller timeout."""
        emit = MagicMock()
        child = MagicMock()
        control = fixture.NativeFixtureControl(emit, MagicMock(return_value=child))
        control.stop()
        with patch.object(fixture.launcher, 'stop_lab') as stop:
            self.assertIs(control.start_lab(synthetic_config()), child)
        stop.assert_called_once_with(child)
        emit.assert_not_called()

    def test_snapshot_before_ready_never_reads_database(self):
        """Không có owned config và READY thì snapshot bị từ chối trước SQL."""
        control = fixture.NativeFixtureControl(MagicMock(), MagicMock())
        with patch.object(fixture.launcher.lab, 'sql') as sql:
            with self.assertRaises(RuntimeError):
                control.snapshot()
        sql.assert_not_called()

    def test_pending_stop_failure_still_hands_child_to_launcher_finally(self):
        """Stop chưa xác nhận không được raise trước khi run gốc append child, tránh xóa graph dưới child sống."""
        emit = MagicMock()
        child = MagicMock()
        control = fixture.NativeFixtureControl(emit, MagicMock(return_value=child))
        control.stop()
        with patch.object(fixture.launcher, 'stop_lab', side_effect=OSError('synthetic stop fault')):
            self.assertIs(control.start_lab(synthetic_config()), child)
        self.assertIs(control.process, child)
        self.assertFalse(control.ready.is_set())
        emit.assert_called_once_with({'kind': 'STOP_UNCONFIRMED'})

    def test_stop_after_ready_blocks_new_snapshot(self):
        """Khi STOP đã phát intent, control không cho SQL đọc thêm dù child vẫn còn trong khoảng chờ dừng."""
        control = fixture.NativeFixtureControl(MagicMock(), MagicMock())
        control.ready.set()
        control.stopping.set()
        with patch.object(fixture.launcher.lab, 'sql') as sql:
            with self.assertRaises(RuntimeError):
                control.snapshot()
        sql.assert_not_called()

    def test_ready_output_failure_still_hands_child_back_and_requests_stop(self):
        """Host mất stdout sau spawn không được làm mất handle trước launcher finally."""
        child = MagicMock()
        control = fixture.NativeFixtureControl(MagicMock(side_effect=BrokenPipeError()), MagicMock(return_value=child))
        with patch.object(fixture.launcher, 'stop_lab') as stop:
            self.assertIs(control.start_lab(synthetic_config()), child)
        stop.assert_called_once_with(child)
        self.assertTrue(control.stopping.is_set())
        self.assertFalse(control.ready.is_set())

    def test_stop_marker_output_failure_cannot_discard_child(self):
        """Cả stop và marker đều lỗi vẫn phải trả child để finally gốc chặn cleanup dưới server sống."""
        child = MagicMock()
        control = fixture.NativeFixtureControl(MagicMock(side_effect=BrokenPipeError()), MagicMock(return_value=child))
        control.stop()
        with patch.object(fixture.launcher, 'stop_lab', side_effect=OSError('synthetic stop fault')):
            self.assertIs(control.start_lab(synthetic_config()), child)
        self.assertIs(control.process, child)

    def test_failed_control_marker_still_stops_without_thread_traceback(self):
        """Snapshot và stdout cùng lỗi vẫn dừng child; daemon không được in traceback hoặc mất STOP."""
        control = fixture.NativeFixtureControl(MagicMock(side_effect=BrokenPipeError()), MagicMock())
        with patch.object(control, 'snapshot', side_effect=RuntimeError('synthetic snapshot fault')), patch.object(control, 'stop') as stop:
            control.read_commands(io.BytesIO(b'SNAPSHOT\n'))
        stop.assert_called_once_with()

    def test_malformed_snapshot_uuid_stops_control_without_traceback(self):
        """SQL boundary bất thường không được làm thread chết khi child vẫn sống; sessionId sai phải fail-closed."""
        control = fixture.NativeFixtureControl(MagicMock(), MagicMock())
        control.process = MagicMock()
        control.process.poll.return_value = None
        control.config = {'userIds': [str(uuid4())]}
        control.ready.set()
        with patch.object(fixture.launcher.lab, 'sql', return_value=SimpleNamespace(stdout=json.dumps([{'sessionId': None, 'revoked': False}]))), patch.object(fixture.launcher, 'stop_lab') as stop:
            control.read_commands(io.BytesIO(b'SNAPSHOT\n'))
        stop.assert_called_once_with(control.process)
        self.assertTrue(control.stopping.is_set())
        control.emit.assert_called_once_with({'kind': 'CONTROL_FAILED'})

    def test_ready_metadata_and_snapshot_exclude_secrets(self):
        """Metadata chỉ có UUID/email synthetic; snapshot chỉ UUID/revoked và dùng psql quoted UUID."""
        config = {**synthetic_config(), 'fixturePassword': 'not-for-output', 'databasePassword': 'not-for-output'}
        run_id, user_ids = config['runId'], config['userIds']
        emit = MagicMock()
        child = MagicMock()
        child.poll.return_value = None
        control = fixture.NativeFixtureControl(emit, MagicMock(return_value=child))
        control.start_lab(config)
        self.assertEqual(emit.call_args.args[0], {'kind': 'READY', 'runId': run_id, 'userIds': user_ids, 'emails': config['emails']})
        session_id = str(uuid4())
        with patch.object(fixture.launcher.lab, 'sql', return_value=SimpleNamespace(stdout=json.dumps([{'sessionId': session_id, 'revoked': False}]) + '\n')) as sql:
            self.assertEqual(control.snapshot(), [{'sessionId': session_id, 'revoked': False}])
        statement = sql.call_args.args[0]
        self.assertNotIn('token', statement)
        self.assertIn(":'auth_fault_user_id'", statement)
        self.assertIn("client_type IN ('ANDROID','WEB')", statement)
        self.assertEqual(sql.call_args.kwargs['variables'], (('auth_fault_user_id', user_ids[0]),))

    def test_expired_session_seed_binds_only_digest_and_preserves_24_hour_ttl(self):
        """Fixture chỉ INSERT verifier digest, giữ TTL24h và không phát raw bearer trong READY.

        Input
        Param: không có — token/ID/expiry đều synthetic trong RAM.
        Output: READY chỉ chứa session ID và expiry; SQL chỉ nhận digest đã bind.
        Errors: assertion sai nếu token thô rời RAM hoặc có UPDATE session.
        """
        config = synthetic_config()
        token = 'c' * 64
        expires_at = (datetime.now(timezone.utc) - timedelta(hours=1)).replace(microsecond=0)
        expires_at_text = expires_at.isoformat(timespec='milliseconds').replace('+00:00', 'Z')
        child = MagicMock()
        child.poll.return_value = None
        emit = MagicMock()
        control = fixture.NativeFixtureControl(emit, MagicMock(return_value=child),
                                               scenario='offline-expired', expired_session_token=token)
        # SQL fake chỉ chiếu lại session UUID đã bind, không tạo selector hoặc thay query bằng cấu hình ngoài.
        def insert(statement, **kwargs):
            """Param: statement/kwargs — SQL binding fake, trả đúng UUID owner đã bind."""
            variables = dict(kwargs['variables'])
            output = json.dumps({'sessionId': variables['auth_fault_expired_session_id'],
                                 'expiresAt': expires_at_text}) + '\n'
            return SimpleNamespace(returncode=0, stdout=output)
        with patch.object(fixture.launcher.lab, 'sql', side_effect=insert) as sql:
            self.assertIs(control.start_lab(config), child)
        ready = emit.call_args.args[0]
        variables = dict(sql.call_args.kwargs['variables'])
        session_id = variables['auth_fault_expired_session_id']
        self.assertEqual(ready['expiredSessionId'], session_id)
        self.assertEqual(ready['expiredSessionExpiresAt'], expires_at_text)
        self.assertNotIn(token, json.dumps(ready))
        statement = sql.call_args.args[0]
        self.assertNotIn(token, statement)
        self.assertNotIn(token, str(variables))
        self.assertEqual(variables['auth_fault_token_digest'], hashlib.sha256(token.encode('ascii')).hexdigest())
        self.assertIn("decode(:'auth_fault_token_digest','hex')", statement)
        self.assertIn("date_trunc('milliseconds', transaction_timestamp())", statement)
        self.assertIn("interval '24 hours'", statement)
        self.assertNotIn('UPDATE sessions', statement)

    def test_snapshot_scope_uses_only_owned_fixed_accounts(self):
        """Full/disabled/empty chỉ bind UUID từ config owned, không nhận index hoặc UUID ngoài run."""
        control = fixture.NativeFixtureControl(MagicMock(), MagicMock())
        control.process = MagicMock()
        control.process.poll.return_value = None
        user_ids = [str(uuid4()) for _ in range(5)]
        control.config = {'userIds': user_ids}
        control.ready.set()
        for scope, index in [('full', 0), ('disabled', 1), ('empty', 3), ('limited', 2)]:
            with self.subTest(scope=scope), patch.object(fixture.launcher.lab, 'sql', return_value=SimpleNamespace(stdout='[]')) as sql:
                self.assertEqual(control.snapshot(scope), [])
                self.assertEqual(sql.call_args.kwargs['variables'], (('auth_fault_user_id', user_ids[index]),))
        for invalid in ['arbitrary', user_ids[0], 0, None]:
            with self.subTest(invalid=invalid), patch.object(fixture.launcher.lab, 'sql') as sql:
                with self.assertRaises(ValueError):
                    control.snapshot(invalid)
                sql.assert_not_called()

    def test_snapshot_commands_emit_matching_scope_without_arbitrary_selector(self):
        """Literal commands ánh xạ scope cố định; response scope giúp host không nhận nhầm account."""
        for command, scope in [(b'SNAPSHOT\n', 'full'), (b'SNAPSHOT_DISABLED\n', 'disabled'), (b'SNAPSHOT_EMPTY\n', 'empty'), (b'SNAPSHOT_LIMITED\n', 'limited')]:
            emit = MagicMock()
            control = fixture.NativeFixtureControl(emit, MagicMock())
            with patch.object(control, 'snapshot', return_value=[]) as snapshot, patch.object(control, 'stop', side_effect=control.stopping.set):
                control.read_commands(io.BytesIO(command))
            snapshot.assert_called_once_with(scope)
            emit.assert_called_once_with({'kind': 'SNAPSHOT', 'scope': scope, 'sessions': []})
        control = fixture.NativeFixtureControl(MagicMock(), MagicMock())
        with patch.object(control, 'snapshot') as snapshot, patch.object(control, 'stop', side_effect=control.stopping.set) as stop:
            control.read_commands(io.BytesIO(b'SNAPSHOT arbitrary-uuid\n'))
        snapshot.assert_not_called()
        stop.assert_called_once()

    def test_watchdog_profiles_are_closed_and_expiry_requests_stop(self):
        """Password riêng35phút, default20phút; deadline chỉ yêu cầu STOP, không giả terminal hoặc cleanup."""
        for scenario, seconds in [('default', 1200), ('password', 2100)]:
            control = fixture.NativeFixtureControl(MagicMock(), MagicMock(), scenario=scenario)
            with patch.object(control.ready, 'wait', return_value=True) as ready, patch.object(control.stopping, 'wait', return_value=False) as work, patch.object(control, 'stop') as stop:
                control.watchdog()
            ready.assert_called_once_with(900)
            work.assert_called_once_with(seconds)
            stop.assert_called_once()
            control.process = None
            with self.assertRaises(RuntimeError):
                control.verify_cleanup()
        for invalid in ['full', 2100, None]:
            with self.assertRaises(ValueError):
                fixture.NativeFixtureControl(MagicMock(), MagicMock(), scenario=invalid)

    def test_cleanup_requires_zero_readback_and_uses_owned_uuid_list(self):
        """STOPPED cần13integer0 từ một query bound, scope chốt lúc spawn không đổi theo config mutable."""
        config = synthetic_config()
        user_ids = tuple(config['userIds'])
        expected_digests = tuple(hmac.new(bytes(config['signingKey']), email.encode(), hashlib.sha256).hexdigest()
                                 for email in [*config['emails'], f"probe-{config['runId']}-unknown@example.invalid"])
        child = MagicMock()
        child.poll.return_value = 0
        control = fixture.NativeFixtureControl(MagicMock(), MagicMock(return_value=child))
        control.start_lab(config)
        config['userIds'][0] = str(uuid4())
        config['emails'][0] = 'foreign@example.invalid'
        config['signingKey'][0] = 255
        counts = dict.fromkeys(['role', 'hba', 'users', 'sessions', 'workspaces', 'memberships', 'auditActor',
                                'limiterBuckets', 'pushInstallations', 'websocketTickets', 'outboxEvents',
                                'outboxConsumptions', 'globalIdempotencyRecords'], 0)
        with patch.object(fixture.launcher.lab, 'sql', return_value=SimpleNamespace(returncode=0, stdout=json.dumps(counts))) as sql:
            self.assertEqual(control.verify_cleanup(), counts)
        self.assertEqual(sql.call_count, 1)
        self.assertEqual(sql.call_args.kwargs['database'], 'iot_platform_lab')
        self.assertEqual(sql.call_args.kwargs['role'], fixture.launcher.lab.ADMIN)
        self.assertFalse(sql.call_args.kwargs['check'])
        self.assertEqual(sql.call_args.kwargs['variables'], (
            ('auth_fault_correlations', ','.join(user_ids)), ('auth_lab_bucket_digests', ','.join(expected_digests))))
        self.assertEqual(sql.call_args.args[0], fixture.CLEANUP_READBACK_SQL)
        self.assertIn("decode(digest, 'hex')", fixture.CLEANUP_READBACK_SQL)
        self.assertIn("WHERE email_digest IN (SELECT email_digest FROM owned_buckets)", fixture.CLEANUP_READBACK_SQL)
        self.assertIn("payload->>'userId' IN (SELECT user_id::text FROM owned)", fixture.CLEANUP_READBACK_SQL)
        self.assertIn("active_user_id IN (SELECT user_id FROM owned)", fixture.CLEANUP_READBACK_SQL)
        self.assertNotIn("push_installations WHERE user_id", fixture.CLEANUP_READBACK_SQL)
        for table in ('push_installations', 'websocket_tickets', 'outbox_events', 'outbox_consumptions', 'global_idempotency_records'):
            self.assertIn(table, fixture.CLEANUP_READBACK_SQL)
        for invalid in [None, [], {}, {**counts, 'unexpected': 0},
                        *({key: value for key, value in counts.items() if key != missing} for missing in counts),
                        *({**counts, key: 1} for key in ['pushInstallations', 'websocketTickets', 'outboxEvents',
                                                        'outboxConsumptions', 'globalIdempotencyRecords']),
                        *({**counts, 'limiterBuckets': value} for value in [1, -1, False, None, '0', 0.1]),
                        {**counts, 'sessions': 1}, {**counts, 'users': False}]:
            with patch.object(fixture.launcher.lab, 'sql', return_value=SimpleNamespace(returncode=0, stdout=json.dumps(invalid))):
                with self.assertRaises(RuntimeError):
                    control.verify_cleanup()

    def test_cleanup_scope_rejects_invalid_source_before_spawn_or_sql(self):
        """Shape đúng UUID chưa đủ: account/key/email phải trọn namespace live trước capability spawn."""
        config = synthetic_config()
        invalid_configs = [None, {}, {**config, 'runId': 'invalid'},
                           {**config, 'runId': '{' + config['runId'] + '}'},
                           {**config, 'userIds': config['userIds'][:4]},
                           {**config, 'userIds': [config['userIds'][0], *config['userIds'][:4]]},
                           {**config, 'userIds': [None, *config['userIds'][1:]]},
                           {**config, 'emails': config['emails'][:4]},
                           {**config, 'emails': list(reversed(config['emails']))},
                           {**config, 'emails': ['foreign@example.invalid', *config['emails'][1:]]},
                           *({**config, 'signingKey': value} for value in [None, 'key', [1], [False] * 32, [-1] * 32, [256] * 32])]
        for index, invalid in enumerate(invalid_configs):
            with self.subTest(case=index), patch.object(fixture.launcher.lab, 'sql') as sql:
                start = MagicMock()
                control = fixture.NativeFixtureControl(MagicMock(), start)
                with self.assertRaisesRegex(ValueError, '^INVALID_NATIVE_LAB_CLEANUP_SCOPE$'):
                    control.start_lab(invalid)
                start.assert_not_called()
                sql.assert_not_called()

    def test_cleanup_requires_captured_scope_and_owned_terminal_child(self):
        """Config tự gán hoặc child còn sống không đủ provenance để xuất cleanup ACK."""
        control = fixture.NativeFixtureControl(MagicMock(), MagicMock())
        control.config = synthetic_config()
        with patch.object(fixture.launcher.lab, 'sql') as sql:
            with self.assertRaisesRegex(RuntimeError, '^NATIVE_LAB_CLEANUP_UNCONFIRMED$'):
                control.verify_cleanup()
            sql.assert_not_called()
        child = MagicMock()
        child.poll.return_value = None
        control = fixture.NativeFixtureControl(MagicMock(), MagicMock(return_value=child))
        control.start_lab(synthetic_config())
        with patch.object(fixture.launcher.lab, 'sql') as sql:
            with self.assertRaisesRegex(RuntimeError, '^NATIVE_LAB_CLEANUP_UNCONFIRMED$'):
                control.verify_cleanup()
            sql.assert_not_called()

    def test_failed_spawn_does_not_capture_cleanup_authority(self):
        """Valid config chỉ được chốt khi capability thực trả owned child; startup lỗi không giả ownership."""
        control = fixture.NativeFixtureControl(MagicMock(), MagicMock(side_effect=RuntimeError('synthetic startup fault')))
        with self.assertRaises(RuntimeError):
            control.start_lab(synthetic_config())
        with patch.object(fixture.launcher.lab, 'sql') as sql:
            with self.assertRaisesRegex(RuntimeError, '^NATIVE_LAB_CLEANUP_UNCONFIRMED$'):
                control.verify_cleanup()
            sql.assert_not_called()

    def test_cleanup_sql_errors_are_fixed_and_do_not_reflect_values(self):
        """Returncode/JSON/exception lỗi không được đưa digest, SQL hoặc stderr vào public error."""
        child = MagicMock()
        child.poll.return_value = 0
        control = fixture.NativeFixtureControl(MagicMock(), MagicMock(return_value=child))
        control.start_lab(synthetic_config())
        raw_error = 'synthetic-sensitive-diagnostic'
        invalid_results = [SimpleNamespace(returncode=1, stdout='{}', stderr=raw_error),
                           SimpleNamespace(returncode=False, stdout='{}'),
                           SimpleNamespace(returncode=0, stdout=raw_error)]
        for result in invalid_results:
            with patch.object(fixture.launcher.lab, 'sql', return_value=result):
                with self.assertRaisesRegex(RuntimeError, '^NATIVE_LAB_CLEANUP_UNCONFIRMED$'):
                    control.verify_cleanup()
        for error in [RuntimeError(raw_error), OSError(raw_error), subprocess.TimeoutExpired(raw_error, 120)]:
            with patch.object(fixture.launcher.lab, 'sql', side_effect=error):
                with self.assertRaisesRegex(RuntimeError, '^NATIVE_LAB_CLEANUP_UNCONFIRMED$'):
                    control.verify_cleanup()

    def test_rate_arm_anchors_absolute_work_before_delayed_watchdog(self):
        """READY không mở work window; watchdog thức muộn vẫn dùng mốc ARM đã chốt, không cấp thêm40phút."""
        child = MagicMock()
        child.poll.return_value = None
        emit = MagicMock()
        with patch.object(fixture.time, 'monotonic', return_value=100) as clock:
            control = fixture.NativeFixtureControl(emit, MagicMock(return_value=child), scenario='rate-limit')
            control.start_lab(synthetic_config())
            self.assertIsNone(control.work_deadline)
            clock.return_value = 200
            control.arm()
            self.assertEqual(control.work_deadline, 2600)
            self.assertEqual(emit.call_args.args[0], {'kind': 'ARMED'})
            clock.return_value = 2500

            def expire_work(seconds):
                """Mô phỏng hết phần100giây còn lại, không thay clock của App hoặc DB.

                Input
                Param: seconds — timeout watchdog cấp từ deadline tuyệt đối.
                Output: False như event chưa nhận STOP trước timeout.
                """
                self.assertEqual(seconds, 100)
                clock.return_value = 2600
                return False

            with patch.object(control.state_changed, 'wait', side_effect=expire_work) as wait, patch.object(fixture.launcher, 'stop_lab') as stop:
                control.watchdog()
            wait.assert_called_once_with(100)
            stop.assert_called_once_with(child)
            self.assertTrue(control.stopping.is_set())

    def test_rate_startup_deadline_includes_ready_waiting_for_arm(self):
        """Đã READY nhưng chưa ARM vẫn hết startup15phút tính từ constructor, không mở cửa sổ mới."""
        with patch.object(fixture.time, 'monotonic', return_value=100) as clock:
            control = fixture.NativeFixtureControl(MagicMock(), MagicMock(), scenario='rate-limit')
            control.ready.set()
            clock.return_value = 999

            def expire_startup(seconds):
                """Đẩy host clock tới startup deadline để chứng minh READY không kéo dài chờ ARM.

                Input
                Param: seconds — phần thời gian còn lại trước deadline.
                """
                self.assertEqual(seconds, 1)
                clock.return_value = 1000
                return False

            with patch.object(control.state_changed, 'wait', side_effect=expire_startup), patch.object(control, 'stop', wraps=control.stop) as stop:
                control.watchdog()
            stop.assert_called_once()
            self.assertTrue(control.stopping.is_set())
            self.assertIsNone(control.work_deadline)

    def test_rate_arm_rejects_early_late_stopped_and_duplicate_without_sql(self):
        """ARM chỉ thắng đúng một lần trong READY/startup còn hạn; invalid intent không mở work hoặc đọc SQL."""
        for case in ['early', 'late', 'stopped', 'duplicate']:
            with self.subTest(case=case), patch.object(fixture.time, 'monotonic', return_value=100) as clock, patch.object(fixture.launcher.lab, 'sql') as sql, patch.object(fixture.launcher, 'stop_lab'):
                child = MagicMock()
                child.poll.return_value = None
                emit = MagicMock()
                control = fixture.NativeFixtureControl(emit, MagicMock(return_value=child), scenario='rate-limit')
                if case != 'early':
                    control.start_lab(synthetic_config())
                if case == 'late':
                    clock.return_value = 1000
                elif case == 'stopped':
                    control.stop()
                elif case == 'duplicate':
                    control.arm()
                previous_deadline = control.work_deadline
                with self.assertRaisesRegex(RuntimeError, '^NATIVE_LAB_ARM_UNAVAILABLE$'):
                    control.arm()
                self.assertEqual(control.work_deadline, previous_deadline)
                sql.assert_not_called()

    def test_rate_snapshot_requires_arm_and_emit_failure_keeps_owned_stop(self):
        """Không snapshot trước ARM; output ARMED hỏng vẫn STOP đúng child, không mất handle hoặc in traceback."""
        child = MagicMock()
        child.poll.return_value = None
        emit = MagicMock()
        control = fixture.NativeFixtureControl(emit, MagicMock(return_value=child), scenario='rate-limit')
        control.start_lab(synthetic_config())
        with patch.object(fixture.launcher.lab, 'sql') as sql:
            with self.assertRaisesRegex(RuntimeError, '^NATIVE_LAB_SNAPSHOT_UNAVAILABLE$'):
                control.snapshot()
            sql.assert_not_called()
        emit.side_effect = BrokenPipeError()
        with patch.object(fixture.launcher, 'stop_lab') as stop:
            control.read_commands(io.BytesIO(b'ARM\n'))
        stop.assert_called_once_with(child)
        self.assertIs(control.process, child)
        self.assertTrue(control.stopping.is_set())

    def test_old_profiles_do_not_accept_arm_or_change_work_budget(self):
        """ARM chỉ thuộc rate-limit; default/password giữ budget và unknown-command STOP như trước."""
        for scenario, seconds in [('default', 1200), ('password', 2100)]:
            control = fixture.NativeFixtureControl(MagicMock(), MagicMock(), scenario=scenario)
            self.assertEqual(control.work_seconds, seconds)
            control.read_commands(io.BytesIO(b'ARM\n'))
            self.assertTrue(control.stopping.is_set())
            control.emit.assert_not_called()

    def test_rate_arm_wins_before_startup_timeout_without_restarting_work(self):
        """Wake timeout không được ghi đè ARM đã commit trước boundary; deadline work vẫn từ ARM thắng lock."""
        child = MagicMock()
        child.poll.return_value = None
        emit = MagicMock()
        with patch.object(fixture.time, 'monotonic', return_value=100) as clock:
            control = fixture.NativeFixtureControl(emit, MagicMock(return_value=child), scenario='rate-limit')
            control.start_lab(synthetic_config())
            clock.return_value = 999

            def race_arm_and_timeout(seconds):
                """Cho ARM thắng ngay trước timeout rồi mô phỏng watchdog thức sau startup đã hết.

                Input
                Param: seconds — remaining hiện tại, một giây startup rồi2399giây work.
                Output: False để buộc watchdog đọc lại state đã được serialize.
                """
                if seconds == 1:
                    clock.return_value = 999.5
                    control.arm()
                    clock.return_value = 1000.5
                else:
                    self.assertEqual(seconds, 2399)
                    clock.return_value = 3399.5
                return False

            with patch.object(control.state_changed, 'wait', side_effect=race_arm_and_timeout) as wait, patch.object(fixture.launcher, 'stop_lab') as stop:
                control.watchdog()
            self.assertEqual(control.work_deadline, 3399.5)
            self.assertEqual(wait.call_count, 2)
            self.assertEqual(sum(call.args == ({'kind': 'ARMED'},) for call in emit.call_args_list), 1)
            stop.assert_called_once_with(child)




class NativeMembershipTargetTests(unittest.TestCase):
    """Kiểm projection B của run owned bằng fake SQL, không truy cập canonical DB."""

    def make_ready(self, scenario='default'):
        """Dựng control qua handoff thật để test không tự gán ownership bằng state private.

        Input
        Param: scenario — profile fixed cần kiểm, default hoặc rate-limit.
        Output: control, config synthetic và owned child giả còn sống.
        """
        child = MagicMock()
        child.poll.return_value = None
        config = synthetic_config()
        control = fixture.NativeFixtureControl(MagicMock(), MagicMock(return_value=child), scenario=scenario)
        control.start_lab(config)
        return control, config, child

    def projection(self):
        """Output: metadata B synthetic đúng shape, không chứa credentials hoặc user profile."""
        return {'workspaceId': str(uuid4()), 'revision': 1, 'authorizationVersion': 1, 'grantGeneration': 1}

    def test_owned_projection_is_pinned_and_returns_a_copy(self):
        """Một SQL đầu chốt target B của live run; caller sửa copy không được đổi authority bên trong."""
        control, config, child = self.make_ready()
        expected = self.projection()
        with patch.object(fixture.launcher.lab, 'sql', return_value=SimpleNamespace(returncode=0, stdout=json.dumps([expected]))) as sql:
            result = control.membership_target()
            self.assertEqual(result, expected)
            result['workspaceId'] = str(uuid4())
            self.assertEqual(control.membership_target(), expected)
        sql.assert_called_once()
        call = sql.call_args
        self.assertFalse(call.kwargs['check'])
        self.assertEqual(call.kwargs['database'], fixture.launcher.DATABASE)
        self.assertEqual(call.kwargs['variables'], (('auth_fault_correlations', ','.join([config['runId'], config['userIds'][0], config['userIds'][4]])),))
        statement = call.args[0]
        for fragment in ["BEGIN READ ONLY", "statement_timeout='20s'", "lock_timeout='5s'",
                         "idle_in_transaction_session_timeout='25s'", "shobj_description",
                         "AUTH_HTTP_LAB:", "created_by_user_id", "creator.role='ADMIN'",
                         "member.role='USER'", "grant_row.revoked_at IS NULL", "COMMIT;"]:
            self.assertIn(fragment, statement)
        self.assertNotIn('UPDATE ', statement)
        self.assertNotIn('password', statement)
        self.assertNotIn('token', statement)

    def test_admission_requires_ready_live_owned_child_and_no_stop(self):
        """Control chưa ready, child chết hoặc STOP phải từ chối trước SQL kể cả đã có cached target."""
        for state in ['early', 'dead', 'stopped', 'cached-stopped']:
            with self.subTest(state=state):
                control, config, child = self.make_ready()
                if state == 'cached-stopped':
                    with patch.object(fixture.launcher.lab, 'sql', return_value=SimpleNamespace(returncode=0, stdout=json.dumps([self.projection()]))):
                        control.membership_target()
                if state == 'early':
                    control.ready.clear()
                elif state == 'dead':
                    child.poll.return_value = 0
                else:
                    control.stopping.set()
                with patch.object(fixture.launcher.lab, 'sql') as sql:
                    with self.assertRaisesRegex(RuntimeError, '^NATIVE_LAB_MEMBERSHIP_UNAVAILABLE$'):
                        control.membership_target()
                sql.assert_not_called()

    def test_rate_requires_arm_and_unexpired_work(self):
        """Projection không mở thêm work window rate, trước ARM hoặc sau deadline không có SQL."""
        with patch.object(fixture.time, 'monotonic', return_value=100) as clock:
            control, config, child = self.make_ready('rate-limit')
            with patch.object(fixture.launcher.lab, 'sql') as sql:
                with self.assertRaisesRegex(RuntimeError, '^NATIVE_LAB_MEMBERSHIP_UNAVAILABLE$'):
                    control.membership_target()
                control.arm()
                clock.return_value = control.work_deadline
                with self.assertRaisesRegex(RuntimeError, '^NATIVE_LAB_MEMBERSHIP_UNAVAILABLE$'):
                    control.membership_target()
            sql.assert_not_called()

    def test_schema_failure_is_sticky_and_never_echoes_sql_output(self):
        """Ambiguous row, invalid UUID/version/schema hoặc SQL exit lỗi không cấp target và không retry."""
        valid = self.projection()
        invalid = [[], [valid, valid], {}, [None], [{**valid, 'extra': 'SYNTHETIC_SECRET'}],
                   [{**valid, 'workspaceId': None}], [{**valid, 'workspaceId': 'ABCDEFAB-1234-4567-89AB-ABCDEFABCDEF'}],
                   [{**valid, 'revision': True}], [{**valid, 'revision': 0}],
                   [{**valid, 'authorizationVersion': 2**63}],
                   [{**valid, 'grantGeneration': '1'}]]
        for value in invalid:
            with self.subTest(value_type=type(value).__name__):
                control, config, child = self.make_ready()
                with patch.object(fixture.launcher.lab, 'sql', return_value=SimpleNamespace(returncode=0, stdout=json.dumps(value))) as sql:
                    for attempt in range(2):
                        with self.assertRaisesRegex(RuntimeError, '^NATIVE_LAB_MEMBERSHIP_UNAVAILABLE$'):
                            control.membership_target()
                sql.assert_called_once()
        for result in [SimpleNamespace(returncode=1, stdout='SYNTHETIC_SECRET'),
                       SimpleNamespace(returncode=True, stdout=json.dumps([valid])),
                       SimpleNamespace(returncode=0, stdout='SYNTHETIC_SECRET'),
                       SimpleNamespace(returncode=0, stdout='x' * 4097)]:
            control, config, child = self.make_ready()
            with patch.object(fixture.launcher.lab, 'sql', return_value=result) as sql:
                with self.assertRaisesRegex(RuntimeError, '^NATIVE_LAB_MEMBERSHIP_UNAVAILABLE$'):
                    control.membership_target()
                with self.assertRaisesRegex(RuntimeError, '^NATIVE_LAB_MEMBERSHIP_UNAVAILABLE$'):
                    control.membership_target()
            sql.assert_called_once()

    def test_sql_exception_is_fixed_and_sticky(self):
        """Docker timeout hoặc lỗi SQL không được phản chiếu selector/credential, retry cần fixture mới."""
        control, config, child = self.make_ready()
        with patch.object(fixture.launcher.lab, 'sql', side_effect=subprocess.TimeoutExpired('SYNTHETIC_SECRET', 120)) as sql:
            for attempt in range(2):
                with self.assertRaisesRegex(RuntimeError, '^NATIVE_LAB_MEMBERSHIP_UNAVAILABLE$'):
                    control.membership_target()
        sql.assert_called_once()

    def test_stop_or_child_exit_during_sql_prevents_publication(self):
        """Operation đã trở về nhưng STOP hoặc child terminal làm target không còn hợp lệ để handoff."""
        for state in ['stop', 'exit']:
            control, config, child = self.make_ready()
            def query(*args, **kwargs):
                """Đặt thay đổi lifecycle ngay trong SQL giả để thử guard sau operation.

                Input
                Param: args — SQL nội bộ, không execute.
                Param: kwargs — binding nội bộ, không truy cập DB.
                Output: row hợp lệ nhưng lifecycle đã mất admission.
                """
                if state == 'stop':
                    control.stopping.set()
                else:
                    child.poll.return_value = 0
                return SimpleNamespace(returncode=0, stdout=json.dumps([self.projection()]))
            with patch.object(fixture.launcher.lab, 'sql', side_effect=query) as sql:
                with self.assertRaisesRegex(RuntimeError, '^NATIVE_LAB_MEMBERSHIP_UNAVAILABLE$'):
                    control.membership_target()
                with self.assertRaisesRegex(RuntimeError, '^NATIVE_LAB_MEMBERSHIP_UNAVAILABLE$'):
                    control.membership_target()
            sql.assert_called_once()

    def test_literal_command_has_no_selector_and_output_failure_stops(self):
        """Chỉ literal target command có projection metadata, lỗi emit vẫn STOP owned child."""
        control, config, child = self.make_ready()
        target = self.projection()
        with patch.object(control, 'membership_target', return_value=target) as target_read, patch.object(control, 'stop', side_effect=control.stopping.set):
            control.read_commands(io.BytesIO(b'MEMBERSHIP_TARGET\n'))
        target_read.assert_called_once_with()
        self.assertEqual(control.emit.call_args.args[0], {'kind': 'MEMBERSHIP_TARGET', 'target': target})
        for command in [b'MEMBERSHIP_TARGET arbitrary-id\n', b'MEMBERSHIP_TARGET\r\n']:
            control, config, child = self.make_ready()
            with patch.object(control, 'membership_target') as target_read, patch.object(fixture.launcher, 'stop_lab') as stop:
                control.read_commands(io.BytesIO(command))
            target_read.assert_not_called()
            stop.assert_called_once_with(child)
        control, config, child = self.make_ready()
        control.emit.side_effect = BrokenPipeError()
        with patch.object(control, 'membership_target', return_value=target), patch.object(fixture.launcher, 'stop_lab') as stop:
            control.read_commands(io.BytesIO(b'MEMBERSHIP_TARGET\n'))
        self.assertTrue(control.stopping.is_set())
        stop.assert_called_once_with(child)



    def test_live_config_mutation_cannot_retarget_the_pinned_scope(self):
        """Selector phải lấy tuple chốt trước READY, không theo object config RAM bị caller sửa về sau."""
        control, config, child = self.make_ready()
        expected = ','.join([config['runId'], config['userIds'][0], config['userIds'][4]])
        config['runId'] = str(uuid4())
        config['userIds'][0] = str(uuid4())
        config['userIds'][4] = str(uuid4())
        with patch.object(fixture.launcher.lab, 'sql', return_value=SimpleNamespace(returncode=0, stdout=json.dumps([self.projection()]))) as sql:
            control.membership_target()
        self.assertEqual(sql.call_args.kwargs['variables'], (('auth_fault_correlations', expected),))

    def test_stop_waits_for_owned_read_and_blocks_late_publication(self):
        """STOP giữ intent ngay nhưng phải đợi SQL thuộc control nhả lock trước stop child, không ACK target muộn."""
        control, config, child = self.make_ready()
        entered = fixture.threading.Event()
        release = fixture.threading.Event()
        completed = fixture.threading.Event()
        outcomes = []

        def query(*args, **kwargs):
            """Giữ fake SQL đúng một operation để kiểm serialization mà không cần sleep.

            Input
            Param: args — statement của method, không execute.
            Param: kwargs — bindings của method, không execute.
            Output: row synthetic hợp lệ sau khi case cho operation kết thúc.
            """
            entered.set()
            if not release.wait(5):
                raise RuntimeError('SYNTHETIC_QUERY_RELEASE_TIMEOUT')
            return SimpleNamespace(returncode=0, stdout=json.dumps([self.projection()]))

        def read_target():
            """Ghi outcome cố định của worker để main thread xác nhận không có ACK muộn."""
            try:
                control.membership_target()
                outcomes.append('unexpected-target')
            except RuntimeError as error:
                outcomes.append(str(error))
            finally:
                completed.set()

        worker = fixture.threading.Thread(target=read_target)
        stopper = fixture.threading.Thread(target=control.stop)
        with patch.object(fixture.launcher.lab, 'sql', side_effect=query), patch.object(fixture.launcher, 'stop_lab') as stop:
            try:
                worker.start()
                self.assertTrue(entered.wait(5))
                stopper.start()
                self.assertTrue(control.stopping.wait(5))
                stop.assert_not_called()
                self.assertFalse(completed.is_set())
                release.set()
                worker.join(5)
                stopper.join(5)
                self.assertFalse(worker.is_alive())
                self.assertFalse(stopper.is_alive())
                self.assertEqual(outcomes, ['NATIVE_LAB_MEMBERSHIP_UNAVAILABLE'])
                stop.assert_called_once_with(child)
            finally:
                release.set()
                if worker.ident is not None:
                    worker.join(5)
                if stopper.ident is not None:
                    stopper.join(5)




class NativeMembershipSuspendTests(unittest.TestCase):
    """Kiểm membership profile và owner registry, không chạy mutation thật."""

    def ready_control(self):
        """Output: membership control qua live handoff giả và projection B đã decode đúng schema."""
        child = MagicMock()
        child.poll.return_value = None
        control = fixture.NativeFixtureControl(MagicMock(), MagicMock(return_value=child), scenario='membership-stale')
        control.start_lab(synthetic_config())
        target = {'workspaceId':str(uuid4()),'revision':1,'authorizationVersion':1,'grantGeneration':1}
        with patch.object(fixture.launcher.lab,'sql',return_value=SimpleNamespace(returncode=0,stdout=json.dumps([target]))):
            control.membership_target()
        return control, child, target

    def test_profile_packet_is_fixed_and_deadline_anchored_before_ready(self):
        """Membership20phút không được cộng lại sau READY; packet chỉ thêm enum fixed không numeric budget."""
        packet = {'version':1,'password':'Aa1'+'a'*32,'scenario':'membership-stale'}
        self.assertEqual(fixture.parse_packet(json.dumps(packet).encode()), packet['password'])
        with patch.object(fixture.time,'monotonic',return_value=100) as clock:
            control = fixture.NativeFixtureControl(MagicMock(), MagicMock(), scenario='membership-stale')
            self.assertEqual(control.work_deadline, 1300)
            clock.return_value = 900
            with patch.object(control.ready,'wait',return_value=True), patch.object(control.stopping,'wait',return_value=False) as work, patch.object(control,'stop') as stop:
                control.watchdog()
            work.assert_called_once_with(400)
            stop.assert_called_once()

    def test_suspend_requires_membership_profile_target_and_available_lifecycle(self):
        """Không mutation ở profile cũ, trước projection, sau STOP, hết work hoặc child terminal."""
        for state in ['old-profile','no-target','stopped','expired','dead']:
            with self.subTest(state=state):
                control, child, target = self.ready_control()
                if state == 'old-profile':
                    control.scenario = 'default'
                elif state == 'no-target':
                    control._membership_target = None
                elif state == 'stopped':
                    control.stopping.set()
                elif state == 'expired':
                    control.work_deadline = 0
                else:
                    child.poll.return_value = 0
                with patch.object(fixture,'NativeMembershipOperation') as factory:
                    with self.assertRaisesRegex(RuntimeError,'^NATIVE_LAB_MEMBERSHIP_SUSPEND_UNAVAILABLE$'):
                        control.suspend_b()
                factory.assert_not_called()

    def test_operation_is_registered_before_execute_and_only_one_attempt(self):
        """Control registry nhìn thấy object trước execute, kết quả copy và replay không tạo operation mới."""
        control, child, target = self.ready_control()
        result = {**target,'status':'SUSPENDED','revision':2,'authorizationVersion':2}
        owned = MagicMock()
        def execute():
            """Kiểm object đã nằm trong owner registry ngay lúc operation được admission."""
            self.assertIs(control._membership_operation, owned)
            return result
        owned.execute.side_effect = execute
        with patch.object(fixture,'NativeMembershipOperation',return_value=owned) as factory:
            actual = control.suspend_b()
            self.assertEqual(actual,result)
            actual['revision']=500
            self.assertEqual(result['revision'],2)
            with self.assertRaisesRegex(RuntimeError,'^NATIVE_LAB_MEMBERSHIP_SUSPEND_UNAVAILABLE$'):
                control.suspend_b()
        factory.assert_called_once_with(*control._membership_scope,target,
                                       assert_active=control._require_membership_available)
        owned.execute.assert_called_once()

    def test_lifecycle_lost_during_start_prevents_update_admission(self):
        """STOP, deadline hoặc backend chết trong startup phải chặn UPDATE trước khi gửi SQL."""
        operation_type = fixture.NativeMembershipOperation
        for state in ['stop', 'expired', 'death']:
            with self.subTest(state=state):
                control, child, target = self.ready_control()

                def lose_lifecycle():
                    """Đổi lifecycle sau startup admission, trước boundary gửi mutation giả."""
                    if state == 'stop':
                        control.stopping.set()
                    elif state == 'expired':
                        control.work_deadline = 0
                    else:
                        child.poll.return_value = 0

                with patch.object(operation_type, 'start', side_effect=lose_lifecycle), \
                     patch.object(operation_type, '_suspend') as suspend, \
                     patch.object(operation_type, '_drain') as drain:
                    with self.assertRaisesRegex(RuntimeError, '^NATIVE_LAB_MEMBERSHIP_SUSPEND_UNAVAILABLE$'):
                        control.suspend_b()
                suspend.assert_not_called()
                drain.assert_called_once()

    def test_failed_or_late_operation_cannot_retry_or_publish(self):
        """Lỗi/STOP/child death trong execute giữ attempt latch, không trả receipt hoặc tạo operation mới."""
        for state in ['failure','stop','death']:
            control, child, target = self.ready_control()
            owned = MagicMock()
            def execute():
                """Giả operation kết thúc với lifecycle đã mất hoặc lỗi commit unknown."""
                if state == 'failure':
                    raise RuntimeError('SYNTHETIC_SECRET')
                if state == 'stop':
                    control.stopping.set()
                else:
                    child.poll.return_value=0
                return {**target,'status':'SUSPENDED','revision':2,'authorizationVersion':2}
            owned.execute.side_effect=execute
            with patch.object(fixture,'NativeMembershipOperation',return_value=owned) as factory:
                for attempt in range(2):
                    with self.assertRaisesRegex(RuntimeError,'^NATIVE_LAB_MEMBERSHIP_SUSPEND_UNAVAILABLE$'):
                        control.suspend_b()
            factory.assert_called_once()
            owned.execute.assert_called_once()

    def test_registry_stop_drains_operation_and_failure_is_not_swallowed(self):
        """Launcher holder.stop phải đi qua owned operation, drain lỗi phải ngăn graph cleanup."""
        control, child, target = self.ready_control()
        owned = MagicMock()
        with patch.object(fixture,'NativeMembershipOperation',return_value=owned):
            control.suspend_b()
        with patch.object(fixture.launcher,'stop_lab') as stop:
            control.stop()
        stop.assert_called_once_with(child)
        owned.stop.assert_called_once()
        owned.stop.side_effect=RuntimeError('NATIVE_MEMBERSHIP_DRAIN_UNCONFIRMED')
        with patch.object(fixture.launcher,'stop_lab'):
            with self.assertRaisesRegex(RuntimeError,'^NATIVE_MEMBERSHIP_DRAIN_UNCONFIRMED$'):
                control.stop()

    def test_literal_suspend_command_is_profile_gated_and_has_no_selector(self):
        """Chỉ membership-stale nhận đúng literal, payload thêm hoặc profile cũ luôn STOP."""
        control, child, target = self.ready_control()
        result = {**target,'status':'SUSPENDED','revision':2,'authorizationVersion':2}
        with patch.object(control,'suspend_b',return_value=result) as suspend, patch.object(control,'stop',side_effect=control.stopping.set):
            control.read_commands(io.BytesIO(b'SUSPEND_B\n'))
        suspend.assert_called_once_with()
        self.assertEqual(control.emit.call_args.args[0],{'kind':'MEMBERSHIP_SUSPENDED','target':result})
        for profile, command in [('default',b'SUSPEND_B\n'),('password',b'SUSPEND_B\n'),
                                 ('rate-limit',b'SUSPEND_B\n'),('membership-stale',b'SUSPEND_B arbitrary\n')]:
            control, child, target = self.ready_control()
            control.scenario=profile
            with patch.object(control,'suspend_b') as suspend, patch.object(control,'stop',side_effect=control.stopping.set) as stop:
                control.read_commands(io.BytesIO(command))
            suspend.assert_not_called()
            stop.assert_called_once()

    def test_membership_main_registers_control_before_launcher_and_finally_drains(self):
        """Registry chứa control cố định từ trước launcher.run, không bỏ sót append race khi backend chết."""
        packet=json.dumps({'version':1,'password':'Aa1'+'b'*32,'scenario':'membership-stale'}).encode()+b'\n'
        raw_input=SimpleNamespace(buffer=SimpleNamespace(raw=io.BytesIO(packet)))
        control=MagicMock()
        control.verify_cleanup.return_value={}
        original_start=fixture.launcher.start_lab
        original_getpass=fixture.launcher.getpass.getpass
        def run(verify,port,operation_holders=None):
            """Kiểm launcher đã nhận holder trước bất kỳ spawn nào của run.

            Input
            Param: verify — false, đây là lab tương tác.
            Param: port — fixed3000.
            Param: operation_holders — registry fixed phải chứa đúng control live.
            """
            self.assertEqual(operation_holders,[control])
            operation_holders[0].stop()
        with patch.object(fixture.sys,'argv',['native_lab_fixture.py']), patch.object(fixture.sys,'stdin',raw_input), patch.object(fixture.sys,'stdout',io.StringIO()), patch.object(fixture,'NativeFixtureControl',return_value=control), patch.object(fixture.threading,'Thread'), patch.object(fixture.launcher,'run',side_effect=run):
            fixture.main()
        self.assertGreaterEqual(control.stop.call_count,2)
        self.assertIs(fixture.launcher.start_lab,original_start)
        self.assertIs(fixture.launcher.getpass.getpass,original_getpass)



    def test_launcher_drains_fixed_registry_before_graph_and_preserves_graph_on_failure(self):
        """Finally thật của launcher phải drain owner cả khi backend tự exit, drain lỗi giữ graph/role/journal."""
        for failing in [False,True]:
            owner=MagicMock()
            ordered=MagicMock()
            if failing:
                owner.stop.side_effect=RuntimeError('NATIVE_MEMBERSHIP_DRAIN_UNCONFIRMED')
            server=MagicMock()
            server.server_address=('127.0.0.1',4000)
            child=MagicMock()
            child.wait.return_value=0
            with ExitStack() as stack:
                stack.enter_context(patch.object(fixture.launcher.lab,'inspect_lab'))
                stack.enter_context(patch.object(fixture.launcher.lab,'sql',return_value=SimpleNamespace(stdout=str(len(fixture.launcher.repository.platform.SOURCE_NAMES)))))
                stack.enter_context(patch.object(fixture.launcher.subprocess,'run',return_value=SimpleNamespace(returncode=0)))
                stack.enter_context(patch.object(fixture.launcher.subprocess,'Popen',side_effect=AssertionError('Unpatched process')))
                stack.enter_context(patch.object(fixture.launcher.getpass,'getpass',return_value='Aa1'+'a'*32))
                stack.enter_context(patch.object(Path,'mkdir'))
                journal=stack.enter_context(patch.object(Path,'write_text'))
                stack.enter_context(patch.object(fixture.launcher,'provision'))
                stack.enter_context(patch.object(fixture.launcher.bridge,'InspectionServer',return_value=server))
                stack.enter_context(patch.object(fixture.launcher.threading,'Thread'))
                stack.enter_context(patch.object(fixture.launcher,'start_lab',return_value=child))
                stop=stack.enter_context(patch.object(fixture.launcher,'stop_lab'))
                stack.enter_context(patch.object(fixture.launcher,'close_bridge',return_value=True))
                cleanup=stack.enter_context(patch.object(fixture.launcher,'cleanup'))
                revoke=stack.enter_context(patch.object(fixture.launcher,'revoke'))
                stack.enter_context(patch.object(fixture.launcher.repository,'owns_probe',return_value=True))
                stack.enter_context(patch('builtins.print'))
                ordered.attach_mock(stop,'backend_stop')
                ordered.attach_mock(owner.stop,'owner_drain')
                ordered.attach_mock(cleanup,'graph_cleanup')
                ordered.attach_mock(revoke,'role_revoke')
                if failing:
                    with self.assertRaisesRegex(RuntimeError,'^NATIVE_MEMBERSHIP_DRAIN_UNCONFIRMED$'):
                        fixture.launcher.run(False,3000,operation_holders=[owner])
                    cleanup.assert_not_called()
                    revoke.assert_not_called()
                    self.assertEqual(journal.call_count,1)
                else:
                    fixture.launcher.run(False,3000,operation_holders=[owner])
                    self.assertEqual([call[0] for call in ordered.mock_calls],
                                     ['backend_stop','owner_drain','graph_cleanup','role_revoke'])
                owner.stop.assert_called_once()




class NativeMembershipEvidenceTests(unittest.TestCase):
    """Kiểm read-only sessions/audit projection của account0 owned, không truy cập DB."""

    def ready_control(self):
        """Output: membership profile có target B đã xác minh qua boundary giả."""
        return NativeMembershipSuspendTests.ready_control(self)

    def evidence(self):
        """Output: metadata seed session và login audit synthetic, không token/payload/profile."""
        session_id=str(uuid4())
        return {'sessions':[{'sessionId':session_id,'revoked':False}],
                'audit':[{'sessionId':session_id,'eventType':'LOGIN_SUCCEEDED','outcome':'SUCCESS','clientType':'ANDROID'}]}

    def test_owned_projection_uses_single_read_only_query_and_returns_copies(self):
        """Một query giữ cùng snapshot SQL cho sessions/audit, user selector lấy immutable owned scope."""
        control, child, target=self.ready_control()
        expected=self.evidence()
        with patch.object(fixture.launcher.lab,'sql',return_value=SimpleNamespace(returncode=0,stdout=json.dumps(expected))) as sql:
            result=control.membership_session_evidence()
        self.assertEqual(result,expected)
        result['sessions'][0]['revoked']=True
        self.assertFalse(expected['sessions'][0]['revoked'])
        sql.assert_called_once()
        call=sql.call_args
        self.assertEqual(call.kwargs['variables'],(('auth_fault_correlations',','.join(control._membership_scope[:2])),))
        self.assertFalse(call.kwargs['check'])
        for fragment in ['BEGIN READ ONLY',"statement_timeout='20s'","lock_timeout='5s'",
                         'shobj_description','AUTH_HTTP_LAB:','LOGIN_SUCCEEDED',"'LOGOUT'",
                         'LIMIT 17','LIMIT 33','a.actor_user_id=s.user_id',"a.client_type='ANDROID'"]:
            self.assertIn(fragment,call.args[0])
        for forbidden in ['token','password_hash','redacted_diff','UPDATE ','DELETE ']:
            self.assertNotIn(forbidden,call.args[0])

    def test_unavailable_profile_target_stop_expiry_or_child_blocks_sql(self):
        """Không dùng read-only oracle ngoài profile hoặc sau khi lifecycle mất admission."""
        for state in ['profile','target','stop','expiry','child']:
            control, child, target=self.ready_control()
            if state=='profile':
                control.scenario='default'
            elif state=='target':
                control._membership_target=None
            elif state=='stop':
                control.stopping.set()
            elif state=='expiry':
                control.work_deadline=0
            else:
                child.poll.return_value=0
            with patch.object(fixture.launcher.lab,'sql') as sql:
                with self.assertRaisesRegex(RuntimeError,'^NATIVE_LAB_MEMBERSHIP_EVIDENCE_UNAVAILABLE$'):
                    control.membership_session_evidence()
            sql.assert_not_called()

    def test_invalid_shape_bounds_and_foreign_session_fail_closed(self):
        """Không ép kiểu, truncate rows, bỏ duplicatesessions hoặc nhận audit gắn session ngoài projection."""
        valid=self.evidence()
        row=valid['sessions'][0]
        event=valid['audit'][0]
        invalid=[None,{}, {**valid,'extra':'SYNTHETIC_SECRET'},
                 {**valid,'sessions':[row]*17}, {**valid,'audit':[event]*33},
                 {**valid,'sessions':[row,row]},
                 {**valid,'sessions':[{**row,'revoked':0}]},
                 {**valid,'sessions':[{**row,'sessionId':'ABCDEFAB-1234-4567-89AB-ABCDEFABCDEF'}]},
                 {**valid,'audit':[{**event,'sessionId':str(uuid4())}]},
                 {**valid,'audit':[{**event,'eventType':'PASSWORD_CHANGED'}]},
                 {**valid,'audit':[{**event,'outcome':'SYNTHETIC_UNTRUSTED'}]},
                 {**valid,'audit':[{**event,'clientType':'WEB'}]},
                 {**valid,'audit':[{**event,'extra':'SYNTHETIC_SECRET'}]}]
        for value in invalid:
            control, child, target=self.ready_control()
            with patch.object(fixture.launcher.lab,'sql',return_value=SimpleNamespace(returncode=0,stdout=json.dumps(value))):
                with self.assertRaisesRegex(RuntimeError,'^NATIVE_LAB_MEMBERSHIP_EVIDENCE_UNAVAILABLE$'):
                    control.membership_session_evidence()

    def test_duplicate_audit_events_are_preserved_for_business_oracle(self):
        """Hai login audit cùng session phải còn cả hai để final oracle bắt count sai, không deduplicate che lỗi."""
        control, child, target=self.ready_control()
        evidence=self.evidence()
        evidence['audit']*=2
        with patch.object(fixture.launcher.lab,'sql',return_value=SimpleNamespace(returncode=0,stdout=json.dumps(evidence))):
            self.assertEqual(len(control.membership_session_evidence()['audit']),2)

    def test_read_errors_do_not_echo_raw_output_and_stop_during_query_blocks_receipt(self):
        """Lỗi SQL/JSON/overflow hoặc STOP sau read phải trả fixed error, chưa cấp business receipt."""
        control, child, target=self.ready_control()
        with patch.object(fixture.launcher.lab,'sql',side_effect=subprocess.TimeoutExpired('SYNTHETIC_SECRET',120)):
            with self.assertRaisesRegex(RuntimeError,'^NATIVE_LAB_MEMBERSHIP_EVIDENCE_UNAVAILABLE$'):
                control.membership_session_evidence()
        for result in [SimpleNamespace(returncode=1,stdout='SYNTHETIC_SECRET'),
                       SimpleNamespace(returncode=True,stdout=json.dumps(self.evidence())),
                       SimpleNamespace(returncode=0,stdout='SYNTHETIC_SECRET'),
                       SimpleNamespace(returncode=0,stdout='x'*8193)]:
            control, child, target=self.ready_control()
            with patch.object(fixture.launcher.lab,'sql',return_value=result):
                with self.assertRaisesRegex(RuntimeError,'^NATIVE_LAB_MEMBERSHIP_EVIDENCE_UNAVAILABLE$'):
                    control.membership_session_evidence()
        control, child, target=self.ready_control()
        def query(*args,**kwargs):
            """Đặt STOP ngay khi read xong để kiểm post-operation fence.

            Input
            Param: args — SQL của method, không execute.
            Param: kwargs — bindings owned, không execute.
            Output: metadata hợp lệ nhưng lifecycle đã đóng.
            """
            control.stopping.set()
            return SimpleNamespace(returncode=0,stdout=json.dumps(self.evidence()))
        with patch.object(fixture.launcher.lab,'sql',side_effect=query):
            with self.assertRaisesRegex(RuntimeError,'^NATIVE_LAB_MEMBERSHIP_EVIDENCE_UNAVAILABLE$'):
                control.membership_session_evidence()

    def test_literal_evidence_command_has_no_selector_and_is_profile_gated(self):
        """Chỉ literal new profile gửi read-only evidence, command gắn UUID hoặc profile cũ phải STOP."""
        control, child, target=self.ready_control()
        evidence=self.evidence()
        with patch.object(control,'membership_session_evidence',return_value=evidence) as read, patch.object(control,'stop',side_effect=control.stopping.set):
            control.read_commands(io.BytesIO(b'MEMBERSHIP_SESSION_EVIDENCE\n'))
        read.assert_called_once_with()
        self.assertEqual(control.emit.call_args.args[0],{'kind':'MEMBERSHIP_SESSION_EVIDENCE',**evidence})
        for profile,command in [('default',b'MEMBERSHIP_SESSION_EVIDENCE\n'),
                                ('membership-stale',b'MEMBERSHIP_SESSION_EVIDENCE arbitrary\n')]:
            control, child, target=self.ready_control()
            control.scenario=profile
            with patch.object(control,'membership_session_evidence') as read, patch.object(control,'stop',side_effect=control.stopping.set) as stop:
                control.read_commands(io.BytesIO(command))
            read.assert_not_called()
            stop.assert_called_once()


if __name__ == '__main__':
    unittest.main()
