"""Kiểm audit fault harness cách ly DB/HTTP; chỉ provider thật mới là evidence CP-02."""

from pathlib import Path
import sys
from types import SimpleNamespace
import unittest
from unittest.mock import patch
from uuid import uuid4

AUTH_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(AUTH_ROOT))
sys.path.insert(0, str(AUTH_ROOT.parent / 'database'))
import verify_audit_faults as faults


class AuditFaultHarnessTests(unittest.TestCase):
    """Bắt sai public credential/counter và restore quyền khi assertion thất bại."""

    def exercise(self, *, leaked=False, persisted=True):
        """Giả lập quyền audit và snapshot committed để thử fail-closed mà không chạm DB.

        Input
        Param: leaked — True mô phỏng response503 lộ token.
        Param: persisted — False mô phỏng failed-login counter bị rollback cùng audit.
        Output: danh sách check nếu đúng invariant; RuntimeError khi harness phát hiện defect.
        """
        enabled = True
        commands = []
        snapshots = 0

        def sql(statement, **kwargs):
            """Cấp snapshot tổng hợp và ghi nhận duy nhất các permission command nội bộ.

            Input
            Param: statement — SQL của harness, không thực thi hoặc log ra ngoài test.
            Param: kwargs — role/database/check của adapter giả, không chứa credential.
            Output: CompletedProcess giả với count/boolean, không DB row thật.
            """
            nonlocal enabled, snapshots
            if statement.startswith('REVOKE') or statement.startswith('GRANT'):
                commands.append(statement)
                enabled = statement.startswith('GRANT')
                return SimpleNamespace(returncode=0, stdout='')
            if statement.startswith('SELECT has_table_privilege'):
                return SimpleNamespace(returncode=0, stdout='t' if enabled else 'f')
            snapshots += 1
            failures = 5 if snapshots >= 3 and persisted else 0
            return SimpleNamespace(returncode=0, stdout=f'3|3|{failures}|0')

        responses = []
        for _ in range(2):
            body = {'error': {'code': 'SERVICE_UNAVAILABLE', 'correlationId': str(uuid4())}}
            if leaked:
                body['token'] = 'synthetic-private-token'
            responses.append((503, {'Cache-Control': 'no-store'}, body))
        for _ in range(5):
            responses.append((401, {'Cache-Control': 'no-store'}, {'error': {'code': 'AUTH_INVALID', 'correlationId': str(uuid4())}}))
        responses.append((429, {'Cache-Control': 'no-store', 'Retry-After': '900'}, {'error': {'code': 'RATE_LIMITED', 'correlationId': str(uuid4())}}))
        checks = []
        with patch.object(faults, 'verify_transaction_faults'), patch.object(faults.repository, 'owns_probe', return_value=True), patch.object(faults.lab, 'sql', side_effect=sql), patch.object(faults, 'request', side_effect=responses):
            try:
                faults.verify_audit_faults(3001, 'fixture@example.invalid', 'Aa1synthetic', uuid4(), 'a' * 64, uuid4(), checks)
            finally:
                self.assertTrue(enabled)
                self.assertEqual(commands, ['REVOKE INSERT ON audit_events FROM iot_repository_probe;', 'GRANT INSERT ON audit_events TO iot_repository_probe;'])
        return checks

    def test_unowned_role_stops_before_sql(self):
        """Không được giảm hoặc khôi phục quyền role khi marker không thuộc lượt chạy hiện tại."""
        with patch.object(faults.repository, 'owns_probe', return_value=False), patch.object(faults.lab, 'sql') as sql:
            with self.assertRaises(RuntimeError):
                faults.set_audit_permission(uuid4(), False)
        sql.assert_not_called()

    def test_untrusted_snapshot_variables_stop_before_docker(self):
        """Không nhận chuỗi chèn SQL hoặc correlation list vô hạn vào interface psql variable mới."""
        invalid = [('auth_fault_user_id', "'; SELECT 1; --"), ('auth_fault_bucket_digest', 'a' * 63 + "'"), ('auth_fault_correlations', ','.join([str(uuid4())] * 9))]
        with patch.object(faults.lab, 'docker') as docker:
            for variable in invalid:
                with self.assertRaises(ValueError):
                    faults.lab.sql('SELECT 1;', database='iot_platform_lab', variables=[variable])
        docker.assert_not_called()

    def test_token_leak_is_rejected_and_permission_restored(self):
        """Response503 kèm token phải fail, nhưng INSERT ban đầu vẫn được khôi phục."""
        with self.assertRaisesRegex(RuntimeError, 'Provider check failed: audit-fault-web-no-credential') as caught:
            self.exercise(leaked=True)
        self.assertNotIn('synthetic-private-token', str(caught.exception))

    def test_counter_rollback_is_rejected_and_permission_restored(self):
        """Counter vẫn0 sau5wrong phải fail dù HTTP giả trả401 và role đã restore."""
        with self.assertRaisesRegex(RuntimeError, 'Provider check failed: audit-fault-counter-committed'):
            self.exercise(persisted=False)

    def test_expected_outcomes_keep_counter_and_restore_permission(self):
        """Chỉ đủ negative-path invariant và khôi phục INSERT mới cho harness GREEN."""
        checks = self.exercise()
        self.assertIn('audit-fault-counter-committed', checks)
        self.assertIn('audit-fault-rate-limit-retained', checks)


class TransactionPermissionFaultTests(unittest.TestCase):
    """Kiểm session/limiter fault oracle và restore quyền bằng SQL/HTTP giả, không mở fixture thật."""

    def exercise(self, mode='valid'):
        """Cấp response503/snapshot tổng hợp để bắt credential leak, commit ngoài ý muốn và restore bị bỏ sót.

        Input
        Param: mode — loại defect synthetic trong response hoặc committed-state readback.
        Output: danh sách check khi mọi oracle đúng, lỗi cố định khi harness phát hiện defect.
        """
        before = (3, 3, 0, 0)
        after = {'session': (4, 3, 0, 0), 'audit': (3, 4, 0, 0),
                 'counter': (3, 3, 1, 0), 'failure-audit': (3, 3, 0, 1)}.get(mode, before)
        headers = {'Cache-Control': 'no-store'}
        body = {'error': {'code': 'SERVICE_UNAVAILABLE',
                          'message': 'Không thể hoàn tất yêu cầu. Vui lòng kiểm tra trạng thái và thử lại.',
                          'details': {}, 'correlationId': str(uuid4())}}
        if mode == 'token': body['token'] = 'synthetic-private-token'
        if mode == 'cookie': headers['Set-Cookie'] = 'synthetic-private-cookie'
        checks = []
        with patch.object(faults, 'read_snapshot', side_effect=[before, after, before, after]), patch.object(
                faults, 'set_transaction_permission') as permissions, patch.object(
                faults, 'request', return_value=(401 if mode == 'wrong-status' else 503, headers, body)) as request:
            try:
                faults.verify_transaction_faults(3001, 'fixture@example.invalid', 'Aa1synthetic', uuid4(), 'a' * 64, uuid4(), checks)
            finally:
                self.assertTrue(permissions.call_args.args[-1])
                self.assertEqual(permissions.call_args_list[0].args[1:], ('session-insert', False))
            if mode == 'valid':
                self.assertEqual(request.call_count, 6)
                self.assertEqual({call.args[3]['clientType'] for call in request.call_args_list}, {'WEB', 'ANDROID', 'IOS'})
                self.assertEqual([call.args[1:] for call in permissions.call_args_list],
                                 [('session-insert', False), ('session-insert', True), ('limiter-update', False), ('limiter-update', True)])
        return checks

    def test_exact_safe_unavailable_and_unchanged_state_pass(self):
        """Đủ sáu503 đúng schema, hai committed snapshot giữ nguyên và quyền restore mới cho PASS."""
        checks = self.exercise()
        self.assertIn('session-insert-fault-session-audit-counter-unchanged', checks)
        self.assertIn('limiter-update-fault-session-audit-counter-unchanged', checks)

    def test_leaked_credential_or_public_401_is_rejected_and_permission_restored(self):
        """Fault DB phải503 không credential, lỗi chỉ chứa check ID và vẫn chạy finally restore."""
        for mode in ('token', 'cookie', 'wrong-status'):
            with self.assertRaisesRegex(RuntimeError, '^Provider check failed: session-insert-fault-') as caught:
                self.exercise(mode)
            self.assertNotIn('synthetic-private', str(caught.exception))

    def test_any_committed_session_audit_or_counter_delta_is_rejected(self):
        """Status503 không che session/audit/counter đã commit ngoài transaction rollback."""
        for mode in ('session', 'audit', 'counter', 'failure-audit'):
            with self.assertRaisesRegex(RuntimeError, 'session-insert-fault-session-audit-counter-unchanged'):
                self.exercise(mode)

    def test_permission_mutation_requires_ownership_and_exact_readback(self):
        """Chỉ hai privilege đã duyệt được đổi, role ngoại lai hoặc readback sai đều fail closed."""
        with patch.object(faults.repository, 'owns_probe', return_value=False), patch.object(faults.lab, 'sql') as sql:
            with self.assertRaisesRegex(RuntimeError, 'Transaction fault requires owned probe role'):
                faults.set_transaction_permission(uuid4(), 'session-insert', False)
            sql.assert_not_called()
        for fault, table, privilege in (('session-insert', 'sessions', 'INSERT'), ('limiter-update', 'login_attempt_buckets', 'UPDATE')):
            for enabled in (False, True):
                expected_readback = ('t|t|t|t' if enabled else 'f|t|f|f') if fault == 'limiter-update' else ('t' if enabled else 'f')
                with patch.object(faults.repository, 'owns_probe', return_value=True), patch.object(
                        faults.lab, 'sql', side_effect=[SimpleNamespace(returncode=0), SimpleNamespace(returncode=0, stdout=expected_readback)]) as sql:
                    faults.set_transaction_permission(uuid4(), fault, enabled)
                    command = sql.call_args_list[0].args[0]
                    if fault == 'limiter-update':
                        self.assertTrue(command.startswith('BEGIN; ') and command.endswith(' COMMIT;'))
                        self.assertIn('REVOKE UPDATE (email_digest)' if enabled else 'GRANT UPDATE (email_digest)', command)
                        for column in ('failure_count', 'window_started_at'):
                            self.assertIn("'" + column + "','UPDATE'", sql.call_args_list[1].args[0])
                    else:
                        self.assertEqual(command, ('GRANT ' + privilege + ' ON ' + table + ' TO iot_repository_probe;' if enabled else
                                                   'REVOKE ' + privilege + ' ON ' + table + ' FROM iot_repository_probe;'))
                    self.assertIn("'public." + table + "','" + privilege + "'", sql.call_args_list[1].args[0])
                with patch.object(faults.repository, 'owns_probe', return_value=True), patch.object(
                        faults.lab, 'sql', side_effect=[SimpleNamespace(returncode=0), SimpleNamespace(returncode=0, stdout='f' if enabled else 't')]):
                    with self.assertRaisesRegex(RuntimeError, 'Transaction fault permission readback failed'):
                        faults.set_transaction_permission(uuid4(), fault, enabled)


if __name__ == '__main__':
    unittest.main()
