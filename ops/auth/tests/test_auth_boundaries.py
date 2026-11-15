"""Kiểm oracle boundary bằng port giả, không thay evidence PostgreSQL thật."""

from pathlib import Path
import hashlib
import hmac
import json
import sys
import unittest
from unittest.mock import patch
from uuid import uuid4

AUTH_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(AUTH_ROOT))
sys.path.insert(0, str(AUTH_ROOT.parent / 'database'))
import verify_auth_boundaries as boundary


class AuthBoundaryTests(unittest.TestCase):
    """Bắt limiter gia hạn, selector ngoài ownership và credential trong denial."""

    def limited(self):
        """Tạo response tổng hợp đúng catalog để từng test chỉ thay một invariant."""
        return 429, {'Cache-Control': 'no-store', 'Retry-After': '900'}, {'error': {
            'code': 'RATE_LIMITED', 'message': 'Không thể hoàn tất yêu cầu. Vui lòng kiểm tra trạng thái và thử lại.',
            'details': {}, 'correlationId': str(uuid4())}}

    def test_limited_response_rejects_credential_or_invalid_retry(self):
        """429 chỉ được chấp nhận khi không capability và Retry-After nằm trong cửa sổ900giây."""
        for value in ('0', '901', '-1', '1.5'):
            response = self.limited()
            response[1]['Retry-After'] = value
            with self.assertRaisesRegex(RuntimeError, 'boundary-safe-limited'):
                boundary.assert_limited(response, [], 'boundary')
        response = self.limited()
        response[1]['Set-Cookie'] = 'private-fixture-value'
        with self.assertRaisesRegex(RuntimeError, 'boundary-safe-limited') as caught:
            boundary.assert_limited(response, [], 'boundary')
        self.assertNotIn('private-fixture-value', str(caught.exception))

    def test_bucket_identity_requires_ram_key_and_run_email(self):
        """Không được backdate khi digest/key/email không chứng minh cùng run trước SQL."""
        with patch.object(boundary.lab, 'sql') as sql:
            with self.assertRaisesRegex(ValueError, 'selector'):
                boundary.bucket_variables(uuid4(), uuid4(), 'foreign@example.invalid', bytes(32), '0' * 64)
        sql.assert_not_called()

    def test_reverse_race_requires_both_observed_waits(self):
        """Chain mutation→login→session holder thiếu bất kỳ cạnh nào đều không được PASS."""
        with patch.object(boundary, 'metadata_count', return_value=0), patch.object(boundary, 'OBSERVE_TIMEOUT', .001):
            with self.assertRaisesRegex(RuntimeError, 'mutation wait'):
                boundary.wait_for_mutation_blocked('iot_auth_fence_' + 'a' * 32, 123)

    def test_valid_bucket_selector_keeps_key_out_of_sql_variables(self):
        """Chỉ UUID/digest được đưa vào psql variables, key HMAC luôn ở RAM caller."""
        run, user = uuid4(), uuid4()
        key = bytes(range(32))
        email = f'probe-{run}-4@example.invalid'
        digest = hmac.new(key, email.encode(), hashlib.sha256).hexdigest()
        values = boundary.bucket_variables(run, user, email, key, digest)
        self.assertEqual(values, (('auth_fault_user_id', str(user)), ('auth_fault_bucket_digest', digest)))

    def test_expiry_refuses_foreign_owner_before_sql(self):
        """Marker owner sai chặn mutation trước bất kỳ statement nào."""
        run = uuid4()
        with patch.object(boundary.repository, 'owns_probe', return_value=False), patch.object(boundary.lab, 'sql') as sql:
            with self.assertRaisesRegex(RuntimeError, 'ownership'):
                boundary.position_owned_window(run, f'probe-{run}-4@example.invalid', (), 900)
        sql.assert_not_called()

    def test_snapshot_error_or_missing_bucket_is_not_zero(self):
        """Lỗi SQL và row thiếu không được biến thành counter0 để tạo PASS giả."""
        from types import SimpleNamespace
        for result in (SimpleNamespace(returncode=1, stdout='0|EMPTY'), SimpleNamespace(returncode=0, stdout='')):
            with patch.object(boundary.lab, 'sql', return_value=result):
                with self.assertRaisesRegex(RuntimeError, 'snapshot'):
                    boundary.read_window(())

    def test_limiter_nonextension_oracle_rejects_changed_timestamp(self):
        """429 đúng status nhưng timestamp bị kéo dài vẫn phải FAIL trước backdate."""
        run, user = uuid4(), uuid4()
        key = bytes(range(32))
        emails = [f'probe-{run}-{index}@example.invalid' for index in range(5)]
        digests = [hmac.new(key, email.encode(), hashlib.sha256).hexdigest() for email in emails]
        with patch.object(boundary, 'read_window', side_effect=[(5, 'old'), (5, 'extended')]), patch.object(
                boundary, 'read_snapshot', return_value=(1, 1, 5, 0)), patch.object(
                boundary, 'login_request', return_value=self.limited()), patch.object(boundary, 'position_owned_window') as expire:
            with self.assertRaisesRegex(RuntimeError, 'window-not-extended'):
                boundary.verify_limiter_boundary(3000, 3001, emails, 'synthetic-fixture-only', [user] * 5, digests, key, run, [])
        expire.assert_not_called()

    def test_reset_commit_requires_changed_and_committed_markers(self):
        """Reset protocol thiếu COMMITTED không được chứng nhận mutation thành công."""
        holder = boundary.ResetUserFence(uuid4(), uuid4(), uuid4())
        with patch.object(holder, 'send') as send, patch.object(holder, 'read_marker', side_effect=[None, RuntimeError('marker')]):
            with self.assertRaisesRegex(RuntimeError, 'marker'):
                holder.commit('reset')
        statement = send.call_args.args[0]
        self.assertIn('must_change_password=true', statement)
        self.assertIn('COMMIT;', statement)

    def test_last_second_and_expiry_paths_remain_distinct(self):
        """HTTP429 cuối giây và success sau expiry chỉ có evidence khi cả timestamp/counter đều đúng."""
        run, user = uuid4(), uuid4()
        key = bytes(range(32))
        emails = [f'probe-{run}-{index}@example.invalid' for index in range(5)]
        digests = [hmac.new(key, email.encode(), hashlib.sha256).hexdigest() for email in emails]
        final_second = self.limited()
        final_second[1]['Retry-After'] = '1'
        success = (200, {}, {'token': 'private-fixture-token', 'expiresAt': '2026-11-16T00:00:00Z'})
        for retry in ('1', '2'):
            final_second[1]['Retry-After'] = retry
            windows = [(5, 'original')] * 4 + [(5, 'last-second')] * 2 + [(0, 'EMPTY')]
            checks = []
            with self.subTest(retry=retry), patch.object(boundary, 'read_window', side_effect=windows), patch.object(
                    boundary, 'read_snapshot', return_value=(1, 1, 5, 0)), patch.object(
                    boundary, 'login_request', side_effect=[self.limited(), self.limited(), final_second, success]), patch.object(
                    boundary, 'alternate_source_login', return_value=self.limited()), patch.object(
                    boundary, 'position_owned_window') as position, patch.object(
                    boundary, 'has_login_projection', return_value=True), patch.object(boundary, 'read_persisted_session', return_value=user):
                if retry == '2':
                    with self.assertRaisesRegex(RuntimeError, 'last-second-retry-one'):
                        boundary.verify_limiter_boundary(3000, 3001, emails, 'private-fixture-password', [user] * 5, digests, key, run, checks)
                    self.assertEqual([call.args[-1] for call in position.call_args_list], [899])
                else:
                    report = boundary.verify_limiter_boundary(3000, 3001, emails, 'private-fixture-password', [user] * 5, digests, key, run, checks)
                    self.assertEqual([call.args[-1] for call in position.call_args_list], [899, 900])
                    self.assertTrue(report['lastSecondRetryOne'])
                    serialized = json.dumps(report) + json.dumps(checks)
                    for secret in ('private-fixture-password', 'private-fixture-token', emails[4], str(user)):
                        self.assertNotIn(secret, serialized)



class ResetProbeIsolationTests(unittest.TestCase):
    """Bắt regression khi reset probe làm hết budget và che status-fence assertions kế tiếp."""

    def test_exact_two_attempt_restore_preserves_window(self):
        """Chỉ hoàn trả count4 về baseline2 của owned HMAC, giữ nguyên timestamp và failure audit."""
        run, user = uuid4(), uuid4()
        key = bytes(range(32))
        email = f'probe-{run}-2@example.invalid'
        digest = hmac.new(key, email.encode(), hashlib.sha256).hexdigest()
        baseline = (2, '2026-11-15 00:00:00+00')
        with patch.object(boundary.repository, 'owns_probe', return_value=True), patch.object(
                boundary, 'read_window', side_effect=[(4, baseline[1]), baseline]), patch.object(
                boundary.lab, 'sql', return_value=type('Result', (), {'returncode': 0, 'stdout': '1'})()) as sql:
            boundary.restore_reset_probe_window(run, user, email, digest, key, baseline)
        statement = sql.call_args.args[0]
        self.assertIn('SET failure_count=2', statement)
        self.assertIn('failure_count=4', statement)
        self.assertNotIn('SET window_started_at', statement)
        self.assertNotIn('DELETE', statement)

    def test_unowned_or_unexpected_delta_never_updates(self):
        """Sai key hoặc có attempt ngoài probe phải dừng trước mutation, không reset brute-force state."""
        run, user = uuid4(), uuid4()
        key = bytes(range(32))
        email = f'probe-{run}-2@example.invalid'
        digest = hmac.new(key, email.encode(), hashlib.sha256).hexdigest()
        with patch.object(boundary.repository, 'owns_probe', return_value=True), patch.object(
                boundary, 'read_window', return_value=(5, 'original')), patch.object(boundary.lab, 'sql') as sql:
            for candidate in (key, bytes(reversed(key))):
                with self.assertRaises(RuntimeError):
                    boundary.restore_reset_probe_window(run, user, email, digest, candidate, (2, 'original'))
        sql.assert_not_called()

if __name__ == '__main__':
    unittest.main()
