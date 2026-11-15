"""Kiểm evidence parser/control bằng dữ liệu tổng hợp, không coi unit test là phép đo PostgreSQL."""

from copy import deepcopy
from pathlib import Path
import sys
import json
import socket
import threading
import time
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import verify_measurements as measurements


class SyntheticControlServer:
    """TCP fixture chỉ dùng dữ liệu tổng hợp để kiểm cap/deadline; không mô phỏng PostgreSQL hoặc auth."""

    def __init__(self, mode):
        """Giữ mode fault và socket loopback sở hữu, không đọc/copy cấu hình môi trường.

        Input
        Param: mode — ok/oversized/header-trickle/body-trickle quyết định response kiểm cận client.
        """
        self.mode = mode
        self.stop = threading.Event()
        self.listener = socket.socket()
        self.listener.bind(('127.0.0.1', 0))
        self.listener.listen(1)
        self.listener.settimeout(1)
        self.port = self.listener.getsockname()[1]
        self.connection = None
        self.paths = []
        self.worker = threading.Thread(target=self.serve, daemon=True)

    def __enter__(self):
        """Khởi động đúng một worker đã sở hữu, trả fixture để caller lấy port ngẫu nhiên."""
        self.worker.start()
        return self

    def __exit__(self, _kind, _value, _traceback):
        """Dừng sockets/thread kể cả assertion thất bại để test không để port hoặc worker sống.

        Input
        Param: _kind — loại exception context, không được suppress.
        Param: _value — dữ liệu lỗi chỉ đi qua context manager, không log.
        Param: _traceback — traceback không dùng thay đổi verdict.
        """
        self.stop.set()
        if self.connection is not None:
            try:
                self.connection.shutdown(socket.SHUT_RDWR)
            except OSError:
                # Client/watchdog có thể đã shutdown; fixture vẫn phải close và join worker sở hữu.
                pass
            self.connection.close()
        self.listener.close()
        self.worker.join(1)
        if self.worker.is_alive():
            raise RuntimeError('Synthetic control fixture did not stop')

    def serve(self):
        """Phục vụ một request có cận hoặc gửi từng byte để chứng minh socket timeout đơn thuần không đủ.

        Side effects: chỉ lưu path request, không giữ header proof trong fixture/report.
        """
        try:
            self.connection, _ = self.listener.accept()
            self.connection.settimeout(1)
            incoming = b''
            while b'\r\n\r\n' not in incoming and len(incoming) < 8192:
                part = self.connection.recv(1024)
                if not part:
                    return
                incoming += part
            self.paths.append(incoming.split(b'\r\n', 1)[0].split()[1].decode('ascii'))
            incoming = b''
            payload = json.dumps({'windowId': 1, 'padding': 'x' * 64}).encode()
            if self.mode == 'oversized':
                payload = b' ' * (measurements.MAX_RESPONSE_BYTES + 1)
            if self.mode == 'ok':
                payload = b'{"windowId":1}'
            headers = f'HTTP/1.1 200 OK\r\nCache-Control: no-store\r\nContent-Length: {len(payload)}\r\nConnection: close\r\n\r\n'.encode()
            if self.mode == 'header-trickle':
                stream = headers + payload
            elif self.mode == 'body-trickle':
                self.connection.sendall(headers)
                stream = payload
            else:
                self.connection.sendall(headers + payload)
                return
            for byte in stream:
                if self.stop.wait(.2):
                    return
                self.connection.sendall(bytes([byte]))
        except OSError:
            # Watchdog/client timeout hoặc context cleanup đóng socket là kết thúc được mong đợi của fault fixture.
            pass
        finally:
            if self.connection is not None:
                self.connection.close()


class MeasurementSnapshotTests(unittest.TestCase):
    """Snapshot thiếu sample hoặc có error/stale phải FAIL thay vì tạo percentile đẹp từ evidence không đủ."""

    def snapshot(self):
        """Tạo chín stage thành công trong một window tổng hợp, chỉ gồm enum/numeric cho negative mutation."""
        return {'windowId': 2, 'valid': True, 'droppedSamples': 0, 'staleSamples': 0,
                'poisoned': False, 'samples': [
                    {'stage': stage, 'outcome': 'completed', 'elapsedUs': 100}
                    for stage in measurements.STAGES]}

    def test_exact_stage_counts_are_required(self):
        """Đủ chín stage mới PASS; thiếu, trùng hoặc error không được giảm mẫu để tiếp tục."""
        snapshot = self.snapshot()
        self.assertEqual(measurements.validate_snapshot(snapshot, 2, 1), snapshot)
        variants = []
        missing = deepcopy(snapshot)
        missing['samples'].pop()
        variants.append(missing)
        duplicate = deepcopy(snapshot)
        duplicate['samples'].append(deepcopy(duplicate['samples'][0]))
        variants.append(duplicate)
        # Tổng vẫn9 nhưng thiếu một stage và trùng stage khác; chỉ kiểm len không đủ chứng minh completeness.
        wrong_distribution = deepcopy(snapshot)
        wrong_distribution['samples'][1]['stage'] = wrong_distribution['samples'][0]['stage']
        variants.append(wrong_distribution)
        for outcome in ('error', 'abandoned', 'unknown'):
            changed = deepcopy(snapshot)
            changed['samples'][0]['outcome'] = outcome
            variants.append(changed)
        for changed in variants:
            with self.subTest(kind='count-or-outcome'), self.assertRaises(RuntimeError):
                measurements.validate_snapshot(changed, 2, 1)

    def test_window_and_completeness_cannot_be_forged(self):
        """Bool không thay số, generation sai hoặc incomplete flags đều khiến evidence bị từ chối."""
        for field, value in [('windowId', 1), ('windowId', True), ('valid', False),
                             ('valid', 1), ('droppedSamples', 1), ('droppedSamples', False),
                             ('staleSamples', 1), ('poisoned', True), ('poisoned', 0)]:
            changed = self.snapshot()
            changed[field] = value
            with self.subTest(field=field), self.assertRaises(RuntimeError):
                measurements.validate_snapshot(changed, 2, 1)

    def test_sample_schema_is_finite_and_numeric(self):
        """Không nhận nhãn theo request, field bí mật, duration âm/bool/float hoặc số ngoài uint64."""
        for field, value in [('stage', 'arbitrary-input'), ('elapsedUs', True),
                             ('elapsedUs', -1), ('elapsedUs', 0.5), ('elapsedUs', 2**64),
                             ('unexpected', 'synthetic-private-value')]:
            changed = self.snapshot()
            changed['samples'][0][field] = value
            with self.subTest(field=field), self.assertRaises(RuntimeError):
                measurements.validate_snapshot(changed, 2, 1)
        changed = self.snapshot()
        changed['unexpected'] = 'synthetic-private-value'
        with self.assertRaises(RuntimeError):
            measurements.validate_snapshot(changed, 2, 1)

    def test_empty_startup_window_has_no_samples(self):
        """Window mở sau startup phải rỗng, không được trộn dummy hash/seed trước READY."""
        snapshot = self.snapshot()
        snapshot['samples'] = []
        self.assertEqual(measurements.validate_snapshot(snapshot, 2, 0), snapshot)
        with self.assertRaises(RuntimeError):
            measurements.validate_snapshot(self.snapshot(), 2, 0)

    def test_duplicate_json_fields_are_rejected(self):
        """Hai giá trị cho cùng field không được để parser mặc định chọn bản cuối rồi coi hợp lệ."""
        with self.assertRaises(RuntimeError):
            measurements.unique_object([('windowId', 1), ('windowId', 2)])


class MeasurementControlTests(unittest.TestCase):
    """Kiểm client TCP thật cho cap/deadline và negative schema, không mở DB hoặc dùng secret thực."""

    def test_control_uses_absolute_lab_path(self):
        """Control không được đi qua helper tự prefix/api/v1 hoặc follow redirect sang destination khác."""
        with SyntheticControlServer('ok') as server:
            self.assertEqual(measurements.measurement_control(server.port, 'begin', b'x' * 32), {'windowId': 1})
            self.assertEqual(server.paths, ['/__auth_lab/measurements/begin'])

    def test_control_rejects_oversized_response(self):
        """Đọc cap+1 để phát hiện vượt1MiB, không parse/truncate một phần JSON rồi coi hợp lệ."""
        with SyntheticControlServer('oversized') as server, self.assertRaises(RuntimeError):
            measurements.measurement_control(server.port, 'end', b'x' * 32)

    def test_trickled_headers_and_body_have_total_deadline(self):
        """Peer vẫn gửi byte đều không được kéo exchange quá3s bằng cách reset timeout mỗi recv."""
        for mode in ('header-trickle', 'body-trickle'):
            with self.subTest(mode=mode), SyntheticControlServer(mode) as server:
                started = time.monotonic()
                with self.assertRaises(RuntimeError):
                    measurements.measurement_control(server.port, 'begin', b'x' * 32)
                elapsed = time.monotonic() - started
                self.assertGreaterEqual(elapsed, 2.5)
                self.assertLess(elapsed, 4.5)
        self.assertFalse(any(worker.name == 'auth-measurement-control' for worker in threading.enumerate()))

    def test_late_success_cannot_bypass_fresh_deadline(self):
        """Kết quả200 về muộn phải FAIL ngay cả khi watchdog chưa chạy do scheduling."""
        connection = Mock()
        response = Mock(status=200)
        connection.getresponse.return_value = response
        response.getheaders.return_value = [('Cache-Control', 'no-store')]
        with patch.object(measurements.http.client, 'HTTPConnection', return_value=connection), patch.object(measurements.time, 'monotonic', return_value=100) as clock:
            def finish_late(_limit):
                """Đẩy clock qua deadline trước khi trả body hợp lệ, không cần chờ wall clock trong test.

                Input
                Param: _limit — cap mà client cấp cho read, fixture không dùng để tăng payload.
                Output: JSON begin hợp lệ; Side effects: mô phỏng response hoàn tất sau deadline tuyệt đối.
                """
                clock.return_value = 104
                return b'{"windowId":1}'
            response.read.side_effect = finish_late
            with self.assertRaises(RuntimeError):
                measurements.measurement_control(3001, 'begin', b'x' * 32)
        self.assertTrue(connection.close.called)
        self.assertTrue(response.close.called)

    def test_begin_generation_is_exact_and_increasing(self):
        """Bool,0,stale hoặc field ngoài schema không tạo generation tin cậy cho window end."""
        for value in ({'windowId': True}, {'windowId': 0}, {'windowId': 1}, {'windowId': 2, 'extra': 1}):
            with patch.object(measurements, 'measurement_control', return_value=value), self.assertRaises(RuntimeError):
                measurements.begin_window(3001, b'x' * 32, previous=1)


class MeasurementSmokeTests(unittest.TestCase):
    """Kiểm thứ tự window/login/end và redaction của orchestrator trước khi chạy provider thật."""

    def exercise(self, login_status=200):
        """Cấp hai recorder giả có generation riêng, không được lẫn startup với sample login.

        Input
        Param: login_status — HTTP outcome dùng để kiểm success hoặc fail closed trước end/export.
        Output: snapshot/checks/sequence hoặc RuntimeError; không có DB/session thật trong fixture này.
        """
        generations = {3001: 0, 3002: 0}
        calls = []

        def control(port, action, _key):
            """Mô phỏng begin/end theo từng process, chỉ lưu listener/action vào sequence.

            Input
            Param: port — process primary/peer tổng hợp để giữ generation riêng.
            Param: action — begin/end do orchestrator yêu cầu.
            Param: _key — capability TEST không đưa vào assertion/report.
            Output: window rỗng đầu tiên hoặc đủ9sample cho window login thứ hai.
            """
            calls.append((port, action))
            if action == 'begin':
                generations[port] += 1
                return {'windowId': generations[port]}
            samples = [] if generations[port] == 1 else [
                {'stage': stage, 'outcome': 'completed', 'elapsedUs': 100} for stage in measurements.STAGES]
            return {'windowId': generations[port], 'valid': True, 'poisoned': False,
                    'droppedSamples': 0, 'staleSamples': 0, 'samples': samples}

        def login(port, method, path, _body):
            """Trả credential tổng hợp trong RAM để test chứng minh exporter không làm rò response.

            Input
            Param: port — listener mà login đi tới, không đổi process key.
            Param: method — chỉ POST trong smoke, không discovery ngoài ý muốn.
            Param: path — route auth thật cần giữ prefix qua helper provider.
            Param: _body — input TEST không đưa vào report hoặc sequence.
            Output: status/header/body tổng hợp; Side effects: ghi metadata lời gọi phi bí mật.
            """
            calls.append((port, method + ' ' + path))
            return login_status, {}, {'token': 'synthetic-private-token', 'limited': False}

        checks = []
        with patch.object(measurements, 'measurement_control', side_effect=control), patch.object(measurements, 'request', side_effect=login):
            report = measurements.verify_measurements(3001, 3002, 'synthetic-private-email', 'synthetic-private-password', b'x' * 32, checks)
        return report, checks, calls

    def test_windows_bracket_only_two_logins(self):
        """Mở cả2window trước2login, kết thúc sau responses; raw credential không vào report."""
        report, checks, calls = self.exercise()
        self.assertEqual(calls, [(3001, 'begin'), (3001, 'end'), (3002, 'begin'), (3002, 'end'),
                                 (3001, 'begin'), (3002, 'begin'),
                                 (3001, 'POST /auth/login'), (3002, 'POST /auth/login'),
                                 (3001, 'end'), (3002, 'end')])
        self.assertEqual(len(checks), 3)
        self.assertEqual([window['process'] for window in report['windows']], ['primary', 'peer'])
        self.assertEqual([len(window['samples']) for window in report['windows']], [9, 9])
        serialized = json.dumps(report)
        for value in ('synthetic-private-email', 'synthetic-private-password', 'synthetic-private-token'):
            self.assertNotIn(value, serialized)

    def test_http_failure_does_not_export_partial_evidence(self):
        """Status khác200 không được xuất metrics như thể login thành công, launcher phải cleanup process."""
        with self.assertRaises(RuntimeError):
            self.exercise(login_status=503)


if __name__ == '__main__':
    unittest.main()
