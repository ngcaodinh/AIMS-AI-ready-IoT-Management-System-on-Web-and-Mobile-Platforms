"""Kiểm projection offline read-only bằng boundary giả, không mở DB hoặc SDK."""

import io
import json
import sys
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import MagicMock, patch
from uuid import uuid4

sys.path.insert(0, str(Path(__file__).resolve().parent))
import native_lab_fixture as fixture
from test_native_lab_fixture import synthetic_config


class OfflineFixtureTests(unittest.TestCase):
    """Giữ profile offline chỉ đọc, cùng snapshot và chặn lifecycle/schema sai."""

    def ready_control(self):
        """Output: control offline mới với config synthetic live callback và child fake đang sống."""
        child = MagicMock()
        child.poll.return_value = None
        control = fixture.NativeFixtureControl(MagicMock(), MagicMock(return_value=child), 'offline-login')
        control.start_lab(synthetic_config())
        return control, child

    def evidence(self):
        """Output: seed session/audit và hai workspace synthetic đúng role, không token hoặc profile."""
        session = str(uuid4())
        return {'sessions': [{'sessionId': session, 'revoked': False}],
                'audit': [{'sessionId': session, 'eventType': 'LOGIN_SUCCEEDED', 'outcome': 'SUCCESS', 'clientType': 'ANDROID'}],
                'workspaces': [{'workspaceId': str(uuid4()), 'name': 'Phòng vận hành A', 'role': 'ADMIN'},
                               {'workspaceId': str(uuid4()), 'name': 'Nhà kính B', 'role': 'USER'}]}

    def test_profile_deadline_packet_and_single_readonly_projection(self):
        """Profile offline neo1200s và đọc A/B cùng sessions/audit mà không cần resolve target hoặc mutation."""
        packet = {'version': 1, 'password': 'Aa1' + 'a' * 32, 'scenario': 'offline-login'}
        self.assertEqual(fixture.parse_packet(json.dumps(packet).encode()), packet['password'])
        control, _ = self.ready_control()
        self.assertEqual(control.work_seconds, 1200)
        self.assertIsNotNone(control.work_deadline)
        self.assertIsNone(control._membership_target)
        expected = self.evidence()
        with patch.object(fixture.launcher.lab, 'sql', return_value=SimpleNamespace(returncode=0, stdout=json.dumps(expected))) as sql:
            self.assertEqual(control.membership_session_evidence(), expected)
        sql.assert_called_once()
        statement = sql.call_args.args[0]
        for fragment in ['BEGIN READ ONLY', 'LIMIT 17', 'LIMIT 33', 'LIMIT 3', 'workspace_rows',
                         'membership_grants', 'AUTH_HTTP_LAB:', 'shobj_description', 'scope.ids[3]', "statement_timeout='20s'"]:
            self.assertIn(fragment, statement)
        for forbidden in ['UPDATE ', 'DELETE ', 'token_digest', 'password_hash', 'redacted_diff']:
            self.assertNotIn(forbidden, statement)
        self.assertEqual(sql.call_args.kwargs['variables'], (('auth_fault_correlations', ','.join(control._membership_scope)),))

    def test_workspace_shape_identity_role_and_overflow_are_rejected(self):
        """Projection sai workspace không được cấp matcher cho host, lỗi public giữ mã cố định."""
        for fault in ['extra', 'duplicate', 'wrong-role', 'missing', 'upper', 'foreign-audit', 'overflow']:
            with self.subTest(fault=fault):
                control, _ = self.ready_control()
                value = self.evidence()
                if fault == 'extra': value['workspaces'][0]['secret'] = 'SYNTHETIC'
                if fault == 'duplicate': value['workspaces'][1]['workspaceId'] = value['workspaces'][0]['workspaceId']
                if fault == 'wrong-role': value['workspaces'][0]['role'] = 'USER'
                if fault == 'missing': value['workspaces'].pop()
                if fault == 'upper': value['workspaces'][0]['workspaceId'] = 'ABCDEFAB-1234-4567-89AB-ABCDEFABCDEF'
                if fault == 'foreign-audit': value['audit'][0]['sessionId'] = str(uuid4())
                if fault == 'overflow': value['sessions'] *= 17
                with patch.object(fixture.launcher.lab, 'sql', return_value=SimpleNamespace(returncode=0, stdout=json.dumps(value))):
                    with self.assertRaisesRegex(RuntimeError, '^NATIVE_LAB_MEMBERSHIP_EVIDENCE_UNAVAILABLE$'):
                        control.membership_session_evidence()

    def test_stop_child_exit_expiry_and_wrong_live_scope_block_queries(self):
        """Lifecycle mất admission phải chặn trước SQL, cả sau query mới nhận STOP vẫn không public receipt."""
        for fault in ['stop', 'child', 'expired', 'scope']:
            control, child = self.ready_control()
            if fault == 'stop': control.stopping.set()
            if fault == 'child': child.poll.return_value = 0
            if fault == 'expired': control.work_deadline = 0
            if fault == 'scope': control._membership_scope = None
            with patch.object(fixture.launcher.lab, 'sql') as sql:
                with self.assertRaises(RuntimeError): control.membership_session_evidence()
            sql.assert_not_called()
        control, _ = self.ready_control()

        def stopped_query(*args, **kwargs):
            """Input: SQL/bindings nội bộ của control. Side effects: STOP tới trong query giả trước receipt."""
            control.stopping.set()
            return SimpleNamespace(returncode=0, stdout=json.dumps(self.evidence()))

        with patch.object(fixture.launcher.lab, 'sql', side_effect=stopped_query):
            with self.assertRaises(RuntimeError): control.membership_session_evidence()

    def test_offline_wire_rejects_membership_mutation_and_target_before_effect(self):
        """Chỉ evidence literal được offline dispatch, không cho membership target/suspend chạy qua cùng channel."""
        for command in [b'SUSPEND_B\n', b'MEMBERSHIP_TARGET\n', b'MEMBERSHIP_SESSION_EVIDENCE arbitrary\n']:
            control, _ = self.ready_control()
            with patch.object(control, 'membership_target') as target, patch.object(control, 'suspend_b') as suspend, \
                    patch.object(control, 'stop', side_effect=control.stopping.set) as stop:
                control.read_commands(io.BytesIO(command))
            target.assert_not_called()
            suspend.assert_not_called()
            stop.assert_called_once()


if __name__ == '__main__':
    unittest.main()
