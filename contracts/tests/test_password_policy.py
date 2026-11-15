"""Khóa policy user yêu cầu9–128/hoa/thường/số; chỉ dùng ví dụ tổng hợp, không provider hoặc credential thật."""

import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


class PasswordPolicyTests(unittest.TestCase):
    """Giữ contract và bộ ví dụ dùng chung thống nhất cho Rust/Web/Dart."""

    def test_schema_distinguishes_login_current_and_new_password(self):
        """Login nhận9–128, current1–128; new có composition nhưng không khóa account legacy ở login."""
        schemas = json.loads((ROOT / 'openapi/auth.v1.json').read_text(encoding='utf-8'))['components']['schemas']
        login = schemas['LoginRequest']['properties']['password']
        change = schemas['ChangePasswordRequest']['properties']
        self.assertEqual((login['minLength'], login['maxLength']), (9, 128))
        self.assertEqual((change['currentPassword']['minLength'], change['currentPassword']['maxLength']), (1, 128))
        self.assertEqual((change['newPassword']['minLength'], change['newPassword']['maxLength']), (9, 128))
        self.assertEqual(change['newPassword']['x-password-policy'], 'new-password-v1')

    def test_shared_examples_cover_boundaries_composition_and_preservation(self):
        """Fixture oracle độc lập phải có đúng8/9/128/129 và các thành phần thiếu, không suy expected từ client."""
        fixture = json.loads((ROOT / 'fixtures/auth/password-policy.json').read_text(encoding='utf-8'))
        self.assertEqual(fixture['policyVersion'], 1)
        self.assertEqual(fixture['minimumLength'], 9)
        self.assertEqual(fixture['maximumLength'], 128)
        lengths = set()
        for case in fixture['cases']:
            with self.subTest(case=case['id']):
                value = case['password']
                lengths.add(len(value))
                login_error = None if 9 <= len(value) <= 128 else 'LENGTH'
                current_error = None if 1 <= len(value) <= 128 else 'LENGTH'
                composition = any(c.isupper() for c in value) and any(c.islower() for c in value) and any(c in '0123456789' for c in value)
                new_error = login_error or (None if composition else 'FORMAT')
                self.assertEqual(case['loginError'], login_error)
                self.assertEqual(case['currentError'], current_error)
                self.assertEqual(case['newError'], new_error)
        self.assertTrue({8, 9, 128, 129}.issubset(lengths))
        self.assertTrue(any(c['password'] != c['password'].strip() and c['newError'] is None for c in fixture['cases']))

    def test_existing_password_change_scenarios_pass_new_password_policy(self):
        """CSRF/same/success fixture phải qua composition trước khi kiểm nhánh nghiệp vụ phía sau."""
        fixture = json.loads((ROOT / 'fixtures/auth/scenarios.json').read_text(encoding='utf-8'))
        for case in fixture['scenarios']:
            if case['operationId'] != 'changeOwnPassword':
                continue
            value = case['request']['body']['newPassword']
            with self.subTest(case=case['id']):
                self.assertTrue(9 <= len(value) <= 128)
                self.assertTrue(any(c.isupper() for c in value))
                self.assertTrue(any(c.islower() for c in value))
                self.assertTrue(any(c in '0123456789' for c in value))
