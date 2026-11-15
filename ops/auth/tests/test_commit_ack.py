"""Kiểm assertion của ACK verifier bằng response/count giả, không thay provider thật."""

from pathlib import Path
from dataclasses import replace
import sys
import unittest
from unittest.mock import MagicMock, patch
from uuid import uuid4

AUTH_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(AUTH_ROOT))
sys.path.insert(0, str(AUTH_ROOT.parent / 'database'))
import verify_commit_ack as verifier


def snapshots():
    """Cấp hai snapshot giả có đúng một session mới, mọi UUID chỉ giữ RAM của test.

    Output: baseline và after có count/link/TTL predicate giả phù hợp contract của adapter.
    """
    previous = frozenset(uuid4() for _ in range(3))
    created = frozenset([uuid4()])
    return (verifier.CommitSnapshot(3, 3, 0, previous, frozenset()),
            verifier.CommitSnapshot(4, 4, 1, previous | created, created))


class CommitAckVerifierTests(unittest.TestCase):
    """Không chỉ nhìn HTTP503: phải có ACK marker, đúng transaction count và cặp audit/session."""

    def test_missing_committed_pair_fails_without_retry(self):
        """Session tăng nhưng event/link/client/TTL không khớp phải fail ngay, không login lại."""
        proxy = MagicMock()
        proxy.gate.finish.return_value = {'confirmed': True, 'begins': 1, 'commits': 1}
        response = (503, {'Cache-Control': 'no-store'}, {'error': {'code': 'SERVICE_UNAVAILABLE', 'correlationId': str(uuid4())}})
        before, after = snapshots()
        with patch.object(verifier, 'read_snapshot', side_effect=[before, replace(after, matching_pairs=0)]), patch.object(verifier, 'request', return_value=response) as request:
            with self.assertRaisesRegex(RuntimeError, 'Provider check failed: commit-ack-web-exact-committed-pair'):
                verifier.verify_commit_ack(3001, 'fixture@example.invalid', 'Aa1synthetic', uuid4(), proxy, [])
        request.assert_called_once()
        proxy.gate.cancel.assert_called_once()

    def test_replayed_transaction_count_is_rejected(self):
        """Dù chỉ một session commit, hai BEGIN trong window không được ghi là no-replay PASS."""
        proxy = MagicMock()
        proxy.gate.finish.return_value = {'confirmed': True, 'begins': 2, 'commits': 1}
        response = (503, {'Cache-Control': 'no-store'}, {'error': {'code': 'SERVICE_UNAVAILABLE', 'correlationId': str(uuid4())}})
        with patch.object(verifier, 'read_snapshot', return_value=snapshots()[0]), patch.object(verifier, 'request', return_value=response) as request:
            with self.assertRaisesRegex(RuntimeError, 'Provider check failed: commit-ack-web-one-transaction'):
                verifier.verify_commit_ack(3001, 'fixture@example.invalid', 'Aa1synthetic', uuid4(), proxy, [])
        request.assert_called_once()

    def test_audit_linked_to_existing_session_is_rejected(self):
        """Count tăng đúng nhưng audit trỏ session Android cũ vẫn phải fail thay vì giả new orphan PASS."""
        proxy = MagicMock()
        proxy.gate.finish.return_value = {'confirmed': True, 'begins': 1, 'commits': 1}
        before, after = snapshots()
        wrong_link = replace(after, matched_session_ids=frozenset([next(iter(before.session_ids))]))
        android_created = frozenset([uuid4()])
        next_before = replace(after, matching_pairs=0, matched_session_ids=frozenset())
        next_after = verifier.CommitSnapshot(5, 5, 1, after.session_ids | android_created, android_created)
        response = (503, {'Cache-Control': 'no-store'}, {'error': {'code': 'SERVICE_UNAVAILABLE', 'correlationId': str(uuid4())}})
        with patch.object(verifier, 'read_snapshot', side_effect=[before, wrong_link, next_before, next_after]), patch.object(verifier, 'request', return_value=response):
            with self.assertRaisesRegex(RuntimeError, 'Provider check failed: commit-ack-web-exact-committed-pair'):
                verifier.verify_commit_ack(3001, 'fixture@example.invalid', 'Aa1synthetic', uuid4(), proxy, [])

    def test_nested_credential_is_rejected(self):
        """Credential trong error.details phải bị bắt và không được đưa vào thông báo assertion."""
        proxy = MagicMock()
        response = (503, {'Cache-Control': 'no-store'}, {'error': {'code': 'SERVICE_UNAVAILABLE', 'details': {'token': 'synthetic-private-token'}, 'correlationId': str(uuid4())}})
        with patch.object(verifier, 'read_snapshot', return_value=snapshots()[0]), patch.object(verifier, 'request', return_value=response):
            with self.assertRaisesRegex(RuntimeError, 'Provider check failed: commit-ack-web-no-credential') as caught:
                verifier.verify_commit_ack(3001, 'fixture@example.invalid', 'Aa1synthetic', uuid4(), proxy, [])
        self.assertNotIn('synthetic-private-token', str(caught.exception))


if __name__ == '__main__':
    unittest.main()
