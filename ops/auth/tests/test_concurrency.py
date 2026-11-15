"""Thử harness bằng provider giả; không coi unit test này là concurrency PostgreSQL evidence."""

import json
from pathlib import Path
import sys
import threading
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import verify_concurrency as concurrency


class ConcurrentProviderHarnessTests(unittest.TestCase):
    """Bắt limiter cục bộ từng instance và bảo đảm report không chứa credential tổng hợp."""

    def exercise(self, shared, duplicate_sessions=False):
        """Cấp response và readback giả theo failure count, kiểm cả hai listener và session độc lập.

        Input
        Param: shared — True mô phỏng shared limiter, False mô phỏng cả6request bị nhận.
        Param: duplicate_sessions — True mô phỏng hai intent trỏ cùng một row durable để thử oracle.
        Output: metrics chỉ metadata và danh sách check, hoặc lỗi invariant cố định.
        """
        ports = []
        lock = threading.Lock()

        def respond(port, method, path, body=None, headers=None):
            """Mô phỏng outcome công khai, không ghi body/header vào assertion.

            Input
            Param: port — listener giả để kiểm phân bố request qua hai instance.
            Param: method — HTTP method cần phân biệt login và discovery.
            Param: path — endpoint mà harness chọn.
            Param: body — fixture giả chỉ dùng phân biệt credential đúng/sai.
            Param: headers — transport bearer giả, không đưa vào report.
            Output: response HTTP giả, không có dịch vụ hoặc DB thật.
            """
            if method == 'GET':
                return 200, {}, {'id': 'synthetic-user-id'}
            if body['password'] == 'Aa1synthetic':
                return 200, {}, {'token': 'synthetic-token', 'limited': False, 'expiresAt': '2026-11-14T00:00:00Z'}
            with lock:
                ports.append(port)
                limited = shared and len(ports) == 6
            return (429, {'Retry-After': '900'}, {'error': {'code': 'RATE_LIMITED'}}) if limited else (401, {}, {'error': {'code': 'AUTH_INVALID'}})

        checks = []
        session_ids = [0] * 6 if duplicate_sessions else list(range(6))
        with patch.object(concurrency, 'request', side_effect=respond), patch.object(
                concurrency, 'read_persisted_session', side_effect=session_ids):
            metrics = concurrency.verify_concurrency(3001, 3002, ['fixture@example.invalid'] * 5, 'Aa1synthetic', ['synthetic-user-id'] * 5, checks)
        self.assertEqual(sorted(ports), [3001] * 3 + [3002] * 3)
        serialized = json.dumps(metrics)
        for secret in ('Aa1synthetic', 'synthetic-token', 'fixture@example.invalid', 'synthetic-user-id'):
            self.assertNotIn(secret, serialized)
        return metrics, checks

    def test_per_instance_limiter_is_rejected(self):
        """Mỗi instance chấp nhận3attempt khiến cả6trả401 phải thất bại thay vì giả PASS."""
        with self.assertRaisesRegex(RuntimeError, 'Provider check failed: concurrent-shared-limiter-counts'):
            self.exercise(False)

    def test_shared_limiter_records_six_samples_without_secrets(self):
        """Nhận đúng5×401+1×429 mới ghi nhận sáu latency sample không secret."""
        metrics, checks = self.exercise(True)
        self.assertEqual(metrics['sameKey']['samples'], 6)
        self.assertEqual(metrics['multiKey']['samples'], 6)
        self.assertIn('concurrent-shared-limiter-counts', checks)

    def test_concurrent_intents_cannot_share_one_persisted_session(self):
        """Hai intent bị ghi đè cùng row phải fail trước khi chuyển sang limiter batch."""
        with self.assertRaisesRegex(RuntimeError, 'Provider check failed: concurrent-same-account-distinct-durable-sessions'):
            self.exercise(True, duplicate_sessions=True)


if __name__ == '__main__':
    unittest.main()
