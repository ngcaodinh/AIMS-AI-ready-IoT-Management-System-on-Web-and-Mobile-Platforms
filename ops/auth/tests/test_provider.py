"""Kiểm provider harness fail-closed; fake chỉ để thử assertion, không thay HTTP+PostgreSQL thật."""

from pathlib import Path
import json
import sys
import unittest
from types import SimpleNamespace
from unittest.mock import Mock, patch
from uuid import UUID

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import verify_provider as provider
import verify_security_evidence as security


class PasswordProviderHarnessTests(unittest.TestCase):
    """Bảo đảm harness phát hiện server nhận password8, không in credential/body để báo lỗi."""

    def test_weak_password_acceptance_stops_flow_without_leaking_input(self):
        """Server giả trả204 cho password8 phải làm check thất bại ngay, không tiếp tục mutation thành công."""
        replies = [
            (200, {}, {"token": "synthetic-nonfunctional-token", "limited": True}),
            (204, {}, None),
        ]
        with patch.object(provider, "request", side_effect=replies) as request:
            with self.assertRaisesRegex(RuntimeError, "Provider check failed: password-new-length-8") as caught:
                provider.verify_password_flow(
                    3001, "preview@example.invalid", "synthetic-old-password",
                    {"Cookie": "iot_session=synthetic-cookie", "X-Auth-Context-Id": "synthetic-context"},
                    "synthetic-csrf", UUID("5b1eaa6b-5369-4103-8469-e89bf90ea742"), [],
                )
            self.assertEqual(request.call_count, 2)
            self.assertNotIn("synthetic-old-password", str(caught.exception))
            self.assertNotIn("synthetic-cookie", str(caught.exception))


class SecurityProviderHarnessTests(unittest.TestCase):
    """Kiểm denial oracle cùng guard ownership bằng fake hữu hạn, không gọi HTTP/SQL thật."""

    def test_revoked_session_error_only_payload_is_supported(self):
        """Verifier nhận mã thu hồi đã biết với envelope an toàn, tách biệt với phiên hết hạn."""
        response = {'error': {'code': 'SESSION_REVOKED',
                              'message': 'Không thể hoàn tất yêu cầu. Vui lòng kiểm tra trạng thái và thử lại.',
                              'details': {},
                              'correlationId': '10000000-0000-4000-8000-000000000001'}}
        self.assertTrue(provider.has_error_only_payload(response, 'SESSION_REVOKED'))

    def test_origin_denials_require_no_credentials_and_unchanged_committed_state(self):
        """Đúng403 vẫn FAIL nếu cookie lọt hoặc session/audit tăng sau các login bị từ chối."""
        error = {'error': {'code': 'CSRF_INVALID',
                          'message': 'Không thể hoàn tất yêu cầu. Vui lòng kiểm tra trạng thái và thử lại.',
                          'details': {}, 'correlationId': '10000000-0000-4000-8000-000000000001'}}
        before = SimpleNamespace(session_count=2, audit_count=2)
        for mode in ('valid', 'cookie', 'accepted', 'session', 'audit'):
            headers = {'Cache-Control': 'no-store'}
            if mode == 'cookie':
                headers['Set-Cookie'] = 'iot_session=synthetic-cookie'
            after = SimpleNamespace(session_count=3 if mode == 'session' else 2,
                                    audit_count=3 if mode == 'audit' else 2)
            snapshots = SimpleNamespace(read_snapshot=None)
            with patch.dict(sys.modules, {'verify_commit_ack': snapshots}), patch.object(
                    snapshots, 'read_snapshot', side_effect=[before, after]), patch.object(
                    provider, 'request', return_value=(200 if mode == 'accepted' else 403, headers, error)) as request:
                checks = []
                if mode == 'valid':
                    provider.verify_login_origin_boundaries(3001, {'email': 'fixture@example.invalid', 'password': 'synthetic-password'},
                                                           UUID('10000000-0000-4000-8000-000000000002'), checks)
                    self.assertEqual(request.call_count, 6)
                    self.assertEqual({call.args[3]['clientType'] for call in request.call_args_list}, {'WEB', 'ANDROID', 'IOS'})
                    self.assertIn('login-origin-denials-no-session-or-success-audit', checks)
                else:
                    with self.assertRaisesRegex(RuntimeError, '^Provider check failed: login-origin-') as caught:
                        provider.verify_login_origin_boundaries(3001, {'email': 'fixture@example.invalid', 'password': 'synthetic-password'},
                                                               UUID('10000000-0000-4000-8000-000000000002'), checks)
                    self.assertNotIn('synthetic-password', str(caught.exception))
                    self.assertNotIn('synthetic-cookie', str(caught.exception))

    def test_membership_fixture_transition_requires_owned_provenance_and_exact_row(self):
        """Guard từ chối role ngoại lai/transition sai và row0/SQLfail, SQL chỉ nhắm USER thuộc run."""
        run_id = '10000000-0000-4000-8000-000000000001'
        user_id = '10000000-0000-4000-8000-000000000002'
        owner_id = '10000000-0000-4000-8000-000000000003'
        workspace_id = '10000000-0000-4000-8000-000000000004'
        for mode in ('suspended', 'removed', 'foreign-owner', 'invalid-status', 'missing-row', 'sql-failed'):
            database = SimpleNamespace(sql=None)
            repository = SimpleNamespace(owns_probe=None)
            with patch.dict(sys.modules, {'verify_database': database, 'verify_repositories': repository}), patch.object(
                    repository, 'owns_probe', return_value=mode != 'foreign-owner'), patch.object(
                    database, 'sql', return_value=SimpleNamespace(returncode=int(mode == 'sql-failed'),
                                                                 stdout='0|0' if mode == 'missing-row' else ('1|1' if mode == 'removed' else '1|0'))) as query:
                status = 'ACTIVE' if mode == 'invalid-status' else ('REMOVED' if mode == 'removed' else 'SUSPENDED')
                if mode in ('suspended', 'removed'):
                    provider.set_owned_membership_status(run_id, user_id, owner_id, workspace_id, status)
                    statement = query.call_args.args[0]
                    self.assertIn("m.role='USER'", statement)
                    self.assertIn("subject.activation_provenance='AUTH_HTTP_LAB:" + run_id + "'", statement)
                    self.assertIn("owner.activation_provenance='AUTH_HTTP_LAB:" + run_id + "'", statement)
                    self.assertIn("m.status='" + ('ACTIVE' if status == 'SUSPENDED' else 'SUSPENDED') + "'", statement)
                    self.assertIn('UPDATE membership_grants g SET revoked_at=transaction_timestamp() FROM changed m', statement)
                    self.assertEqual(query.call_args.kwargs['variables'], (('auth_fault_user_id', user_id),))
                else:
                    with self.assertRaisesRegex(RuntimeError, '^Owned membership transition rejected$'):
                        provider.set_owned_membership_status(run_id, user_id, owner_id, workspace_id, status)
                    if mode in ('foreign-owner', 'invalid-status'):
                        query.assert_not_called()


class LogoutAuditEvidenceTests(unittest.TestCase):
    """Kiểm audit logout chỉ đọc fixture đã chọn và canary scan không lộ payload."""

    def test_logout_audit_rows_use_bound_selectors_and_scan_fixture_canaries(self):
        """Hai row đúng user/session được trả bounded để scan RAM, selector không nối vào SQL."""
        user_id = '10000000-0000-4000-8000-000000000001'
        session_ids = (
            '10000000-0000-4000-8000-000000000002',
            '10000000-0000-4000-8000-000000000003',
        )
        rows = [
            {'session_id': session_id, 'actor_user_id': user_id,
             'event_type': 'LOGOUT', 'outcome': 'SUCCESS'}
            for session_id in session_ids
        ]
        database = SimpleNamespace(
            ADMIN='admin',
            sql=Mock(return_value=SimpleNamespace(returncode=0, stdout=json.dumps(rows)))
        )
        with patch.dict(sys.modules, {'verify_database': database}):
            payload = provider.read_logout_audit_rows(user_id, session_ids)

        result = security.scan_sink('audit', payload, ('synthetic-password-canary',))
        self.assertEqual(result['status'], 'PASS')
        query = database.sql.call_args
        statement = query.args[0]
        self.assertIn('BEGIN READ ONLY', statement)
        self.assertIn("statement_timeout='10s'", statement)
        self.assertIn("lock_timeout='3s'", statement)
        self.assertFalse(user_id in statement, 'user selector must use psql binding')
        self.assertTrue(all(session_id not in statement for session_id in session_ids),
                        'session selectors must use psql binding')
        self.assertEqual(
            query.kwargs['variables'],
            (('auth_fault_user_id', user_id),
             ('auth_fault_session_ids', ','.join(session_ids))),
        )

    def test_audit_canary_is_detected_without_returning_it_in_the_scan_result(self):
        """Canary trong payload fixture làm audit scan FAIL nhưng marker chỉ chứa trạng thái."""
        canary = 'synthetic-password-canary'
        payload = json.dumps({'event_type': 'LOGOUT', 'note': 'fixture ' + canary}).encode()

        result = security.scan_sink('audit', payload, (canary,))

        self.assertEqual(result['status'], 'FAIL')
        self.assertTrue(canary not in json.dumps(result), 'scan result must not echo canary')

    def test_logout_audit_lookup_rejects_missing_or_mismatched_rows(self):
        """Từng sai lệch session, actor, event hoặc outcome đều bị từ chối bằng lỗi cố định."""
        user_id = '10000000-0000-4000-8000-000000000011'
        session_ids = (
            '10000000-0000-4000-8000-000000000012',
            '10000000-0000-4000-8000-000000000013',
        )
        valid_row = {'session_id': session_ids[0], 'actor_user_id': user_id,
                     'event_type': 'LOGOUT', 'outcome': 'SUCCESS'}
        invalid_rows = (
            [valid_row],
            [valid_row, {**valid_row, 'session_id': session_ids[0]}],
            [valid_row, {**valid_row, 'session_id': session_ids[1],
                         'actor_user_id': '10000000-0000-4000-8000-000000000099'}],
            [valid_row, {**valid_row, 'session_id': session_ids[1], 'event_type': 'LOGIN'}],
            [valid_row, {**valid_row, 'session_id': session_ids[1], 'outcome': 'FAILURE'}],
        )
        for rows in invalid_rows:
            database = SimpleNamespace(
                ADMIN='admin',
                sql=Mock(return_value=SimpleNamespace(returncode=0, stdout=json.dumps(rows)))
            )
            with patch.dict(sys.modules, {'verify_database': database}):
                with self.assertRaisesRegex(RuntimeError, '^Logout audit lookup failed$'):
                    provider.read_logout_audit_rows(user_id, session_ids)

    def test_email_variants_preserve_password_and_bind_same_owned_account(self):
        """Case/ASCII edges phải giữ password nguyên chuỗi, trả cùng UUID và duplicate intent luôn rollback."""
        run_id = '10000000-0000-4000-8000-000000000001'
        user_id = '10000000-0000-4000-8000-000000000002'
        email = 'probe-' + run_id + '-0@example.invalid'
        password = ' SyntheticPassword1 '
        body = {'me': {'id': user_id, 'email': email, 'mustChangePassword': False},
                'limited': False, 'expiresAt': '2026-11-14T00:00:00Z', 'token': 'synthetic-token'}
        database = SimpleNamespace(sql=None)
        repository = SimpleNamespace(owns_probe=None)
        with patch.dict(sys.modules, {'verify_database': database, 'verify_repositories': repository}), patch.object(
                repository, 'owns_probe', return_value=True), patch.object(database, 'sql', return_value=SimpleNamespace(
                returncode=0, stdout='1')) as query, patch.object(provider, 'request', return_value=(200, {'Cache-Control': 'no-store'}, body)) as request, patch.object(
                provider, 'read_persisted_session', side_effect=[UUID('10000000-0000-4000-8000-000000000003'), UUID('10000000-0000-4000-8000-000000000004')]):
            checks = []
            provider.verify_email_canonicalization(3001, {'email': email, 'password': password}, user_id, run_id, checks)
            self.assertEqual([call.args[3]['password'] for call in request.call_args_list], [password, password])
            self.assertEqual([call.args[3]['email'] for call in request.call_args_list], [email.upper(), '\t ' + email.upper() + '\r\n'])
            statement = query.call_args.args[0]
            self.assertNotIn(password, statement)
            self.assertIn("violated='users_email_normalized_key'", statement)
            self.assertIn('SAVEPOINT canonical_email_probe', statement)
            self.assertTrue(statement.endswith('ROLLBACK TO SAVEPOINT canonical_email_probe; ROLLBACK;'))
            self.assertIn('email-canonical-unique-key-rejects-duplicate', checks)


class RealtimeProtocolTests(unittest.TestCase):
    """Kiểm helper dựng frame client tuân thủ masking bắt buộc của WebSocket."""

    def test_client_websocket_frame_is_masked_and_round_trips(self):
        """Frame text fixture phải có mask key, payload khôi phục đúng và không cho vượt cận protocol."""
        payload = b'synthetic-realtime-ticket'
        frame = provider.build_masked_websocket_frame(1, payload)

        self.assertEqual(frame[0], 0x81)
        self.assertEqual(frame[1] & 0x80, 0x80)
        self.assertEqual(frame[1] & 0x7F, len(payload))
        mask = frame[2:6]
        decoded = bytes(value ^ mask[index % 4] for index, value in enumerate(frame[6:]))
        self.assertEqual(decoded, payload)
        with self.assertRaisesRegex(ValueError, '^Invalid WebSocket test frame$'):
            provider.build_masked_websocket_frame(1, b'x' * 126)

    def test_server_close_frame_parser_preserves_only_protocol_bytes(self):
        """Parser đọc close frame unmasked thành opcode và payload đã được giới hạn."""
        connection = Mock()
        connection.recv.side_effect = [b'\x88\x02', b'\x03\xf0']

        self.assertEqual(provider.receive_websocket_frame(connection), (8, b'\x03\xf0'))

    def test_other_session_socket_is_open_only_when_peer_sends_no_frame(self):
        """Timeout không là close; EOF, frame hoặc reset đều không được báo socket còn hoạt động."""
        connection = Mock()
        connection.recv.side_effect = TimeoutError()
        self.assertTrue(provider.websocket_stays_open(connection, 0.01))

        connection.recv.side_effect = None
        connection.recv.return_value = b''
        self.assertFalse(provider.websocket_stays_open(connection, 0.01))

        connection.recv.side_effect = ConnectionResetError()
        self.assertFalse(provider.websocket_stays_open(connection, 0.01))


if __name__ == "__main__":
    unittest.main()
