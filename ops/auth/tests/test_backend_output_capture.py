"""Kiểm capture output/canary bằng pipe tổng hợp, không khởi chạy backend hoặc mở fixture DB."""

import io
import json
from pathlib import Path
import secrets
import subprocess
import sys
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from backend_output_capture import BackendOutputCapture, CredentialCanaries
import verify_provider


class BackendOutputTests(unittest.TestCase):
    """Capture chỉ tin process handle do launcher bàn giao và chỉ report số đếm sau EOF terminal."""

    def process(self, stdout='AUTH_LAB_READY\n', stderr=''):
        """Cấp hai pipe RAM và trạng thái process terminal để test owner/EOF có cận."""
        return SimpleNamespace(stdout=io.StringIO(stdout), stderr=io.StringIO(stderr), poll=Mock(return_value=0))

    def test_ready_does_not_discard_trailing_output_or_echo_secrets(self):
        """Leak sau READY vẫn bị scan cả hai stream, report chỉ giữ tên sink và số đếm."""
        token = secrets.token_hex(32)
        child = self.process('AUTH_LAB_READY\nlate ' + token + '\n', 'token: raw-value\n')
        capture = BackendOutputCapture(child, 'primary')
        capture.start()
        self.assertTrue(capture.ready.wait(1))
        result = capture.finish(child, (token,))
        self.assertEqual([entry['status'] for entry in result['streams']], ['FAIL', 'FAIL'])
        self.assertTrue(token not in json.dumps(result))

    def test_pipe_reader_observes_ready_before_child_exit(self):
        """Reader pipe nhận marker ngắn ngay cả khi backend còn sống và chưa flush đủ một chunk.

        Output: process hoàn tất rồi cả hai stream được scan sau EOF; test không để child sót lại.
        """
        child = subprocess.Popen(
            [sys.executable, '-c', "import time; print('AUTH_LAB_READY', flush=True); time.sleep(1)"],
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        capture = BackendOutputCapture(child, 'primary')
        try:
            capture.start()
            self.assertTrue(capture.ready.wait(.5))
            self.assertIsNone(child.poll())
            child.wait(timeout=3)
            result = capture.finish(child, ())
            self.assertEqual(result['streams'][0]['status'], 'PASS')
        finally:
            if child.poll() is None:
                child.terminate()
                child.wait(timeout=3)

    def test_missing_and_empty_stream_never_claim_coverage(self):
        """Output trống có NOT_RUN riêng, thiếu handle hoặc sai provenance bị từ chối."""
        child = self.process()
        capture = BackendOutputCapture(child, 'peer')
        capture.start()
        result = capture.finish(child, ())
        self.assertEqual(result['streams'][1]['status'], 'NOT_RUN')
        self.assertEqual(result['structuredLog']['status'], 'NOT_RUN')
        with self.assertRaisesRegex(RuntimeError, '^Backend output owner mismatch$'):
            capture.finish(self.process(), ())
        with self.assertRaises(RuntimeError):
            BackendOutputCapture(SimpleNamespace(stdout=None, stderr=None), 'peer')

    def test_capture_requires_terminal_process_and_complete_eof(self):
        """Process còn sống không được chốt scan vì log có thể tới sau thời điểm snapshot."""
        child = self.process()
        child.poll.return_value = None
        capture = BackendOutputCapture(child, 'primary')
        capture.start()
        with self.assertRaisesRegex(RuntimeError, '^Backend output process still active$'):
            capture.finish(child, ())
        child.poll.return_value = 0
        capture.finish(child, ())

    def test_overflow_is_detected_and_pipe_still_drains(self):
        """Vượt cap không được cắt log rồi báo sạch, reader vẫn drain tới EOF để child không kẹt pipe."""
        child = self.process('AUTH_LAB_READY\n' + 'x' * 80)
        with patch('backend_output_capture.MAX_OUTPUT_BYTES', 32):
            capture = BackendOutputCapture(child, 'primary')
            capture.start()
            with self.assertRaisesRegex(RuntimeError, '^Backend output capture incomplete$'):
                capture.finish(child, ())
        self.assertEqual(capture._sizes['backend_stdout'], 80 + len('AUTH_LAB_READY\n'))
        self.assertTrue(child.stdout.closed)

    def test_structured_log_requires_actual_structured_event(self):
        """Marker lifecycle không thay event JSON có correlation/outcome trên sink thật."""
        event = '{"event":"LOGIN_FAILED","outcome":"FAILURE","correlationId":"request"}\n'
        child = self.process('AUTH_LAB_READY\n' + event)
        capture = BackendOutputCapture(child, 'primary')
        capture.start()
        result = capture.finish(child, ())
        self.assertEqual(result['structuredLog']['status'], 'PASS')
        self.assertEqual(result['structuredLog']['eventCount'], 1)

    def test_structured_log_cannot_pass_when_its_stream_has_a_secret(self):
        """Sự kiện JSON có secret phải làm sink thất bại dù shape sự kiện hợp lệ.

        Output: verdict chỉ chứa số đếm và không trả lại token tổng hợp.
        """
        token = secrets.token_hex(32)
        event = json.dumps({'event': 'LOGIN_FAILED', 'outcome': 'FAILURE',
                            'correlationId': 'request', 'password': token}) + '\n'
        child = self.process(event)
        capture = BackendOutputCapture(child, 'primary')
        capture.start()
        result = capture.finish(child, (token,))
        self.assertEqual(result['streams'][0]['status'], 'FAIL')
        self.assertEqual(result['structuredLog']['status'], 'FAIL')
        self.assertNotIn(token, json.dumps(result))

    def test_actual_http_observer_keeps_outbound_and_issued_credentials_in_ram(self):
        """Hook request hiện hữu đăng ký password/email và token/cookie thực từ exchange trước report scan."""
        token = secrets.token_hex(32)
        password = 'Aa1' + secrets.token_hex(16)
        email = secrets.token_hex(16) + '@example.invalid'
        registry = CredentialCanaries((3100, 3101), (password, email))
        response = Mock(status=200)
        response.read.return_value = json.dumps({'token': token}).encode()
        response.getheaders.return_value = [('Set-Cookie', 'iot_session=' + token + '; Path=/api/v1; SameSite=Lax')]
        connection = Mock()
        connection.getresponse.return_value = response
        with registry.observe_requests(), patch.object(verify_provider.http.client, 'HTTPConnection', return_value=connection):
            verify_provider.request(3100, 'POST', '/auth/login', {'email': email, 'password': password})
        self.assertTrue(token in registry.values())
        self.assertTrue(password in registry.values())
        self.assertIsNone(verify_provider.credential_observer)

    def test_registry_rejects_foreign_port_and_bounded_capacity(self):
        """Port ngoài hai child hoặc số canary quá cận phải fail, không âm thầm bỏ token để tạo PASS."""
        registry = CredentialCanaries((3100, 3101), ())
        with self.assertRaisesRegex(RuntimeError, '^Credential observer port mismatch$'):
            registry.observe(3199, {}, {}, None, None)
        with patch('backend_output_capture.MAX_CANARIES', 1):
            with self.assertRaisesRegex(RuntimeError, '^Credential canary budget exceeded$'):
                CredentialCanaries((3100, 3101), (secrets.token_hex(16), secrets.token_hex(16)))


if __name__ == '__main__':
    unittest.main()
