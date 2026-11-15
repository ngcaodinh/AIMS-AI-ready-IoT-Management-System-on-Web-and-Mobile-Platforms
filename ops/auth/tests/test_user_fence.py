"""Kiểm oracle của User fence; dữ liệu giả không thay bằng chứng provider thật."""

from pathlib import Path
import sys
import unittest
from uuid import uuid4

AUTH_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(AUTH_ROOT))
sys.path.insert(0, str(AUTH_ROOT.parent / 'database'))
import verify_user_fence as verifier


class UserFenceOracleTests(unittest.TestCase):
    """Bắt response lộ secret, denial giả và commit sai dù status HTTP trông hợp lệ."""

    def denial(self):
        """Trả response401 tổng hợp đúng catalog, không chứa credential sử dụng được."""
        return (401, {'Cache-Control': 'no-store'}, {'error': {
            'code': 'AUTH_INVALID', 'message': 'Thông tin đăng nhập không hợp lệ.',
            'correlationId': str(uuid4()),
        }})

    def test_nested_secret_is_rejected_without_logging_value(self):
        """Không chấp nhận token trong error.details hoặc phản chiếu nó qua assertion."""
        response = self.denial()
        response[2]['error']['details'] = {'token': 'synthetic-private-token'}
        with self.assertRaisesRegex(RuntimeError, 'fixture-no-credential') as caught:
            verifier.validate_denial(response, [], 'fixture')
        self.assertNotIn('synthetic-private-token', str(caught.exception))

    def test_wrong_public_message_is_rejected(self):
        """Disabled không được phân biệt account tồn tại bằng catalog riêng."""
        response = self.denial()
        response[2]['error']['message'] = 'Account disabled'
        with self.assertRaisesRegex(RuntimeError, 'fixture-no-credential'):
            verifier.validate_denial(response, [], 'fixture')

    def test_cookie_or_context_is_rejected(self):
        """401 kèm capability metadata vẫn là failure dù body đúng."""
        for name in ('Set-Cookie', 'X-Auth-Context-Id', 'X-CSRF-Token'):
            response = self.denial()
            response[1][name] = 'synthetic-private-header'
            with self.assertRaisesRegex(RuntimeError, 'fixture-no-credential'):
                verifier.validate_denial(response, [], 'fixture')

    def test_rate_limiter_cannot_substitute_for_user_fence(self):
        """429 phải FAIL, không được dùng limiter che thiếu kiểm password/status."""
        response = (429, {'Cache-Control': 'no-store'}, {'error': {'code': 'RATE_LIMITED'}})
        with self.assertRaisesRegex(RuntimeError, 'fixture-invalid'):
            verifier.validate_denial(response, [], 'fixture')

    def test_denial_that_committed_session_is_rejected(self):
        """HTTP401 không đủ nếu DB vẫn thêm session hoặc success audit."""
        for after in ((4, 3, 2, 1), (3, 4, 2, 1)):
            with self.assertRaisesRegex(RuntimeError, 'fixture-no-issued-session'):
                verifier.assert_denial_state((3, 3, 1, 0), after, [], 'fixture')

    def test_missing_counter_or_exact_failure_audit_is_rejected(self):
        """Counter bền vững và failure event đúng correlation/client phải cùng được kiểm."""
        for after in ((3, 3, 1, 1), (3, 3, 2, 0), (3, 3, 2, 2)):
            with self.assertRaisesRegex(RuntimeError, 'fixture-counter-and-audit'):
                verifier.assert_denial_state((3, 3, 1, 0), after, [], 'fixture')

    def test_expected_denial_retains_only_static_check_ids(self):
        """Oracle đúng trả correlation trong RAM và report chỉ tên invariant cố định."""
        checks = []
        verifier.validate_denial(self.denial(), checks, 'fixture')
        verifier.assert_denial_state((3, 3, 1, 0), (3, 3, 2, 1), checks, 'fixture')
        self.assertEqual(len(checks), 4)


if __name__ == '__main__':
    unittest.main()
