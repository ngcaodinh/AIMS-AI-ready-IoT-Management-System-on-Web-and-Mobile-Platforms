"""Kiểm scanner và oracle security bằng dữ liệu RAM tổng hợp, không xác nhận sink runtime thật."""

from copy import deepcopy
import json
from pathlib import Path
import secrets
import hashlib
import hmac
import sys
import unittest
from unittest.mock import Mock, patch
from uuid import uuid4

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import verify_security_evidence as security
import verify_measurements as measurements
from verify_measurements import STAGES


class SecurityEvidenceTests(unittest.TestCase):
    """Chặn PASS từ sink trống, canary bị escape, field bí mật hoặc thiếu verify work."""

    def test_empty_or_missing_sink_has_no_pass(self):
        """Phân biệt thiếu sink với scan âm tính có nội dung để report không suy không-secret từ silence."""
        for payload in (None, b''):
            self.assertEqual(security.scan_sink('app_debug', payload, ())['status'], 'NOT_RUN')

    def test_each_required_named_field_is_detected(self):
        """Mọi tên field trong SEC009 đều bị phát hiện với JSON, header và metric label."""
        for name in ('Authorization', 'Cookie', 'Set-Cookie', 'password', 'token', 'email'):
            for payload in (json.dumps({name: secrets.token_hex(16)}).encode(),
                            (name + '=opaque').encode(), (name + ': opaque').encode()):
                with self.subTest(field=name):
                    result = security.scan_sink('audit', payload, ())
                    self.assertEqual(result['status'], 'FAIL')
                    self.assertGreater(result['namedFieldMatches'], 0)

    def test_actual_canary_and_encodings_are_detected_without_echo(self):
        """Canary sinh RAM phải bị tìm cả dạng JSON/URL escaped và kết quả không mang lại giá trị gốc."""
        canary = 'Aa1+@É' + secrets.token_hex(16)
        from urllib.parse import quote
        for encoded in (canary, quote(canary, safe=''), json.dumps(canary)[1:-1]):
            result = security.scan_sink('app_debug', ('event ' + encoded).encode(), (canary,))
            self.assertEqual(result['status'], 'FAIL')
            self.assertGreater(result['canaryMatches'], 0)
            self.assertTrue(canary not in json.dumps(result))

    def test_scanner_detects_double_serialized_fields(self):
        """Output bị JSON serialize hai lần vẫn phải kiểm tên field nhạy cảm nằm trong chuỗi escaped."""
        payload = json.dumps({'message': json.dumps({'token': secrets.token_hex(16)})}).encode()
        self.assertEqual(security.scan_sink('app_debug', payload, ())['status'], 'FAIL')

    def test_clean_nonempty_sink_and_redacted_fields(self):
        """Event tương quan chỉ gồm metadata hoặc field đã redact được scan có nội dung hữu hạn."""
        payload = b'{"event":"LOGIN_FAILED","outcome":"FAILURE","token":"[REDACTED]"}'
        result = security.scan_sink('audit', payload, (secrets.token_hex(16),))
        self.assertEqual(result['status'], 'PASS')
        self.assertEqual(result['byteCount'], len(payload))

    def test_budget_and_unknown_role_fail_safely(self):
        """Sink vượt cận và role tùy ý bị từ chối trước scan mà lỗi không chứa payload."""
        for role, payload in (('untrusted', b'{}'), ('audit', b'x' * (security.MAX_SINK_BYTES + 1))):
            with self.assertRaisesRegex(RuntimeError, '^Invalid security sink input$'):
                security.scan_sink(role, payload, ())

    def snapshot(self):
        """Cấp snapshot tổng hợp đúng stage để mutation test bắt early-return hoặc duration không hợp lệ."""
        return {'windowId': 1, 'valid': True, 'droppedSamples': 0, 'staleSamples': 0,
                'poisoned': False, 'samples': [
                    {'stage': stage, 'outcome': 'completed', 'elapsedUs': 100}
                    for stage in STAGES]}

    def test_denial_requires_actual_completed_hash_work(self):
        """Oracle denial phải từ chối thiếu/abandoned/zero hash work thay vì chỉ nhìn HTTP401."""
        snapshot = self.snapshot()
        snapshot['samples'].extend({'stage': stage, 'outcome': 'completed', 'elapsedUs': 100}
                                  for stage in ('pool_acquire', 'transaction_begin', 'commit_ack'))
        self.assertEqual(security.denial_hash_work(snapshot, 1), 100)
        variants = []
        missing = deepcopy(snapshot)
        missing['samples'] = [sample for sample in missing['samples'] if sample['stage'] != 'hash_work']
        variants.append(missing)
        for field, value in (('outcome', 'abandoned'), ('elapsedUs', 0), ('elapsedUs', True)):
            changed = deepcopy(snapshot)
            next(sample for sample in changed['samples'] if sample['stage'] == 'hash_work')[field] = value
            variants.append(changed)
        for changed in variants:
            with self.assertRaises(RuntimeError):
                security.denial_hash_work(changed, 1)
        # Chỉ chín stage success chưa chứa failure-audit committed không được coi là denial window đầy đủ.
        with self.assertRaises(RuntimeError):
            security.denial_hash_work(self.snapshot(), 1)

    def test_export_rejection_must_be_observed_and_session_survives(self):
        """Thành công trước/sau rejected export được đối soát bằng cùng bearer và commit metadata reader."""
        secret = secrets.token_hex(32)
        body = {'token': secret, 'limited': False, 'expiresAt': '2030-01-01T00:00:00Z'}
        profile = {'id': 'subject'}
        with patch.object(security, 'begin_window', return_value=1), \
                patch.object(security, 'measurement_control', side_effect=[self.snapshot(), {'error': 'MEASUREMENT_CONTROL_REJECTED'}]) as control, \
                patch.object(security, 'request', side_effect=[(200, {}, body), (200, {}, profile), (200, {}, profile)]) as http, \
                patch.object(security, 'read_success_audit', return_value=b'[{"event_type":"LOGIN_SUCCEEDED","outcome":"SUCCESS"}]'), \
                patch.object(security, 'read_persisted_session', return_value='durable-session') as durable:
            result = security.verify_export_control_failure(3100, b'x' * 32, 'fixture@example.invalid', 'password', 'subject', [])
        self.assertEqual(result['scope'], 'rejected measurement export control')
        self.assertTrue(http.call_args_list[1].kwargs['headers'] == http.call_args_list[2].kwargs['headers'])
        self.assertEqual(durable.call_count, 2)
        self.assertEqual(control.call_args.kwargs, {'expected_status': 409})
        self.assertTrue(secret not in json.dumps(result))

    def test_export_control_requires_exact_rejected_http_and_schema(self):
        """Client control chỉ chấp nhận409 schema chuẩn, không dùng timeout/503 như proof exporter bị từ chối."""
        for status, value, accepted in ((409, {'error': 'MEASUREMENT_CONTROL_REJECTED'}, True),
                                         (503, {'error': 'MEASUREMENT_CONTROL_REJECTED'}, False),
                                         (200, {'error': 'MEASUREMENT_CONTROL_REJECTED'}, False),
                                         (409, {'error': 'arbitrary'}, False)):
            connection = Mock()
            response = connection.getresponse.return_value
            response.status = status
            response.getheaders.return_value = [('cache-control', 'no-store')]
            response.read.return_value = json.dumps(value).encode()
            with patch.object(measurements.http.client, 'HTTPConnection', return_value=connection):
                if accepted:
                    self.assertEqual(measurements.measurement_control(3100, 'end', b'x' * 32, 409), value)
                else:
                    with self.assertRaisesRegex(RuntimeError, '^Measurement control failed$'):
                        measurements.measurement_control(3100, 'end', b'x' * 32, 409)

    def owned_fixture(self):
        """Sinh key/email/UUID chỉ trong RAM để kiểm bằng chứng HMAC mà không dùng fixture DB thật."""
        marker = uuid4()
        emails = [f'probe-{marker}-{index}@example.invalid' for index in range(5)]
        identities = [uuid4() for _ in range(5)]
        key = secrets.token_bytes(32)
        digests = [hmac.new(key, value.encode(), hashlib.sha256).hexdigest()
                   for value in [*emails, f'probe-{marker}-unknown@example.invalid']]
        return emails, identities, digests, marker, key

    def test_scope_requires_live_hmac_and_does_not_read_db_on_mismatch(self):
        """Sai key/digest/namespace bị chặn trước SQL, không cho journal tự nhận ownership limiter."""
        fixture = self.owned_fixture()
        for index, value in ((2, ['0' * 64] * 6), (4, secrets.token_bytes(32)),
                             (0, ['foreign@example.invalid'] * 5)):
            changed = list(fixture)
            changed[index] = value
            lab = Mock()
            with patch.dict(sys.modules, {'verify_database': lab, 'verify_repositories': Mock()}), self.assertRaises(RuntimeError):
                security.begin_security_bucket_scope(*changed)
            lab.sql.assert_not_called()

    def test_scope_requires_exact_owner_policy_and_seed_only_empty_bucket(self):
        """Ownership sai, bucket cũ nonzero hoặc thêm bucket0 ngoài seed đều không được reset."""
        fixture = self.owned_fixture()
        seed = {'key': fixture[2][0], 'failures': 0, 'started': None}
        variants = [('1', [seed]), ('2', [{**seed, 'failures': 1}]),
                    ('2', [seed, {'key': fixture[2][1], 'failures': 0, 'started': None}]), ('2', [])]
        for owners, rows in variants:
            lab = Mock()
            lab.sql.return_value = Mock(returncode=0, stdout=owners + '|' + json.dumps(rows))
            with patch.dict(sys.modules, {'verify_database': lab, 'verify_repositories': Mock()}), self.assertRaises(RuntimeError):
                security.begin_security_bucket_scope(*fixture)

    def test_restore_preserves_seed_row_and_requires_fresh_readback(self):
        """Restore giữ hàng0 của seed, xóa đúng hai row mới và fail khi SQL/readback không khớp."""
        fixture = self.owned_fixture()
        lab = Mock()
        seed = [{'key': fixture[2][0], 'failures': 0, 'started': None}]
        lab.sql.return_value = Mock(returncode=0, stdout='2|' + json.dumps(seed))
        with patch.dict(sys.modules, {'verify_database': lab, 'verify_repositories': Mock()}):
            scope = security.begin_security_bucket_scope(*fixture)
            lab.sql.return_value = Mock(returncode=0, stdout='1|1')
            result = security.restore_security_buckets(scope)
            self.assertEqual(result['removedCreatedBucketCount'], 2)
            sql = lab.sql.call_args.args[0]
            self.assertTrue('failure_count=3' in sql)
            self.assertTrue('FOR UPDATE' in sql)
            self.assertTrue('DELETE FROM audit_events' not in sql)
            for returncode, stdout in ((1, ''), (0, '0|0'), (0, '2|1')):
                lab.sql.return_value = Mock(returncode=returncode, stdout=stdout)
                with self.assertRaisesRegex(RuntimeError, '^Security bucket restore not confirmed$'):
                    security.restore_security_buckets(scope)

    def test_guard_and_restore_reject_wrong_live_role_owner(self):
        """User provenance/HMAC không thay live role marker của lượt chạy nên sai marker chặn trước SQL dữ liệu."""
        fixture = self.owned_fixture()
        lab = Mock()
        repository = Mock()
        repository.owns_probe.return_value = False
        with patch.dict(sys.modules, {'verify_database': lab, 'verify_repositories': repository}):
            with self.assertRaisesRegex(RuntimeError, 'live role ownership'):
                security.begin_security_bucket_scope(*fixture)
            with self.assertRaisesRegex(RuntimeError, 'live role ownership'):
                security.restore_security_buckets({'runId': str(fixture[3])})
        lab.sql.assert_not_called()


if __name__ == '__main__':
    unittest.main()
