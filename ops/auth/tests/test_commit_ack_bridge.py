"""Kiểm framing/controller ACK bằng byte tổng hợp; không PostgreSQL hoặc credential thật."""

from pathlib import Path
import socket
import struct
import sys
import threading
import time
import unittest
from unittest.mock import MagicMock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'database'))
import commit_ack_bridge as bridge


def packet(kind, payload):
    """Đóng gói message tổng hợp đúng độ dài PG để kiểm phân mảnh, không mang query/bind thật.

    Input
    Param: kind — một byte type PG do test chọn.
    Param: payload — byte dữ liệu tổng hợp của case.
    Output: frame gồm type, độ dài4byte và payload.
    """
    return kind + struct.pack('!I', len(payload) + 4) + payload


class FrameReaderTests(unittest.TestCase):
    """Không suy message từ chunk TCP; frame có bound và completion deadline riêng."""

    def test_every_byte_fragment_and_coalesced_frames(self):
        """Header/body chia từng byte vẫn cho đúng hai frame, không mất byte hoặc gộp sai packet."""
        reader = bridge.FrameReader()
        expected = [packet(b'C', b'COMMIT\0'), packet(b'Z', b'I')]
        actual = []
        for value in b''.join(expected):
            actual.extend(reader.feed(bytes([value]), 1))
        self.assertEqual(actual, expected)
        self.assertEqual(bridge.FrameReader().feed(b''.join(expected), 1), expected)

    def test_size_and_partial_completion_deadline(self):
        """Length không hợp lệ và peer nhỏ giọt byte không được né cận bộ nhớ/thời gian."""
        for size in (3, bridge.MAX_FRAME_BYTES + 1):
            with self.assertRaises(ValueError):
                bridge.FrameReader().feed(b'D' + struct.pack('!I', size), 1)
        for partial in (b'C\0', packet(b'C', b'COMMIT\0')[:-1]):
            reader = bridge.FrameReader()
            reader.feed(partial, 1)
            with self.assertRaises(TimeoutError):
                reader.feed(b'X', 1 + bridge.FRAME_TIMEOUT + .1)

    def test_startup_send_cannot_outlive_completion_deadline(self):
        """Startup đã hết hạn không được gửi thêm byte hoặc kéo dài budget qua send timeout mới."""
        connection = MagicMock()
        with patch.object(bridge.time, 'monotonic', return_value=10):
            with self.assertRaises(TimeoutError):
                bridge.send_before_deadline(connection, b'synthetic', 9)
        connection.sendall.assert_not_called()


class CommitGateTests(unittest.TestCase):
    """Cùng một controller cô lập window và connection trước khi ACK có thể tới downstream."""

    def test_gate_before_forward_and_confirm_only_after_idle(self):
        """Claim COMMIT dưới transaction lập gate trước send; C chưa đủ, phải có Z idle."""
        gate = bridge.CommitGate()
        generation = gate.arm(1)
        gate.frontend(10, packet(b'Q', b'BEGIN\0'), b'I', 1)
        self.assertTrue(gate.frontend(10, packet(b'Q', b'COMMIT\0'), b'T', 1))
        self.assertTrue(gate.suppresses(10))
        self.assertFalse(gate.backend(10, packet(b'C', b'COMMIT\0'), 1))
        self.assertTrue(gate.backend(10, packet(b'Z', b'I'), 1))
        result = gate.finish(generation)
        self.assertEqual(result, {'confirmed': True, 'begins': 1, 'commits': 1})

    def test_bare_commit_error_and_old_generation_cannot_confirm(self):
        """COMMIT ngoài transaction, server error và callback connection cũ không thể giả injection PASS."""
        gate = bridge.CommitGate()
        generation = gate.arm(1)
        self.assertFalse(gate.frontend(1, packet(b'Q', b'COMMIT\0'), b'I', 1))
        with self.assertRaises(RuntimeError):
            gate.finish(generation)

        generation = gate.arm(2)
        gate.frontend(2, packet(b'Q', b'BEGIN\0'), b'I', 2)
        gate.frontend(2, packet(b'Q', b'COMMIT\0'), b'T', 2)
        gate.backend(2, packet(b'E', b'SERROR\0\0'), 2)
        gate.backend(2, packet(b'Z', b'I'), 2)
        with self.assertRaises(RuntimeError):
            gate.finish(generation)
        generation = gate.arm(3)
        self.assertFalse(gate.backend(2, packet(b'C', b'COMMIT\0'), 3))
        self.assertFalse(gate.backend(2, packet(b'Z', b'I'), 3))
        with self.assertRaises(RuntimeError):
            gate.finish(generation)

    def test_timeout_missing_idle_and_cancellation_are_failure(self):
        """Không có Z hoặc hủy window phải là FAIL, không biến timeout thành confirmed."""
        gate = bridge.CommitGate()
        generation = gate.arm(1)
        gate.frontend(1, packet(b'Q', b'BEGIN\0'), b'I', 1)
        gate.frontend(1, packet(b'Q', b'COMMIT\0'), b'T', 1)
        gate.backend(1, packet(b'C', b'COMMIT\0'), 1)
        self.assertTrue(gate.expire(1 + bridge.ARM_TIMEOUT + .1))
        self.assertTrue(gate.expire(1 + bridge.ARM_TIMEOUT + .2))
        with self.assertRaises(RuntimeError):
            gate.finish(generation)

    def test_late_ack_cannot_confirm_after_deadline_without_poll(self):
        """ACK được xử lý sau deadline phải FAIL dù worker chưa kịp gọi expire trong vòng poll."""
        gate = bridge.CommitGate()
        generation = gate.arm(1)
        gate.frontend(1, packet(b'Q', b'BEGIN\0'), b'I', 1)
        gate.frontend(1, packet(b'Q', b'COMMIT\0'), b'T', 1)
        gate.backend(1, packet(b'C', b'COMMIT\0'), 1 + bridge.ARM_TIMEOUT + .1)
        gate.backend(1, packet(b'Z', b'I'), 1 + bridge.ARM_TIMEOUT + .2)
        with self.assertRaises(RuntimeError):
            gate.finish(generation)
        generation = gate.arm(30)
        gate.cancel()
        with self.assertRaises(RuntimeError):
            gate.finish(generation)


class ProxySocketTests(unittest.TestCase):
    """Peer PG giả dùng socket thật để bắt race forwarding/shutdown, không gọi PostgreSQL hoặc Docker."""

    def exercise_socket(self, mode):
        """Chạy peer tổng hợp trên socket thật để kiểm ACK nhanh, frame dở và hủy khi đang capture.

        Input
        Param: mode — complete/missingIdle/partialFrame/cancel, chỉ điều khiển bytes tổng hợp của peer giả.
        """
        listener = socket.socket()
        listener.bind(('127.0.0.1', 0))
        listener.listen(1)
        outcomes = []
        sent = threading.Event()

        def upstream():
            """Peer tổng hợp trả Z theo BEGIN/COMMIT; chỉ giữ boolean outcome để không log packet."""
            try:
                connection, _ = listener.accept()
                with connection:
                    deadline = time.monotonic() + 3
                    size = struct.unpack('!I', bridge.receive_exact(connection, 4, deadline))[0]
                    bridge.receive_exact(connection, size - 4, deadline)
                    connection.sendall(packet(b'Z', b'I'))
                    for expected in (b'BEGIN\0', b'COMMIT\0'):
                        header = bridge.receive_exact(connection, 5, deadline)
                        length = struct.unpack('!I', header[1:])[0]
                        payload = bridge.receive_exact(connection, length - 4, deadline)
                        if header[:1] != b'Q' or payload != expected:
                            raise ValueError('Unexpected synthetic command')
                        response = packet(b'C', expected) + packet(b'Z', b'T' if expected == b'BEGIN\0' else b'I')
                        if expected == b'COMMIT\0' and mode != 'complete':
                            response = packet(b'C', expected)[:-1] if mode == 'partialFrame' else packet(b'C', expected)
                        connection.sendall(response)
                    sent.set()
                    if mode != 'complete' and connection.recv(1) != b'':
                        raise ValueError('Synthetic peer expected proxy EOF')
                    outcomes.append(True)
            except (OSError, ValueError, ConnectionError):
                outcomes.append(False)

        worker = threading.Thread(target=upstream, daemon=True)
        worker.start()
        proxy = bridge.CommitAckServer(listener.getsockname()[1])
        proxy.start()
        try:
            with socket.create_connection(proxy.server_address, timeout=3) as client:
                startup = struct.pack('!I', 196608) + b'user\0iot_repository_probe\0database\0iot_platform_lab\0\0'
                client.sendall(struct.pack('!I', len(startup) + 4) + startup)
                self.assertEqual(bridge.receive_exact(client, 6, time.monotonic() + 3), packet(b'Z', b'I'))
                generation = proxy.gate.arm(time.monotonic())
                client.sendall(packet(b'Q', b'BEGIN\0'))
                expected = packet(b'C', b'BEGIN\0') + packet(b'Z', b'T')
                self.assertEqual(bridge.receive_exact(client, len(expected), time.monotonic() + 3), expected)
                started = time.monotonic()
                client.sendall(packet(b'Q', b'COMMIT\0'))
                if mode == 'cancel':
                    self.assertTrue(sent.wait(2))
                    proxy.stop()
                self.assertEqual(client.recv(1), b'')
                if mode == 'complete':
                    self.assertLess(time.monotonic() - started, bridge.ARM_TIMEOUT)
                    self.assertTrue(proxy.gate.finish(generation)['confirmed'])
                else:
                    with self.assertRaises(RuntimeError):
                        proxy.gate.finish(generation)
        finally:
            proxy.stop()
            listener.close()
            worker.join(3)
        self.assertEqual(outcomes, [True])
        self.assertFalse(worker.is_alive())
        self.assertFalse(any(item.is_alive() for item in proxy.workers))

    def test_immediate_ack_is_suppressed_and_workers_are_joined(self):
        """Server trả ACK ngay khi nhận COMMIT vẫn chỉ cho client EOF, không chờ timeout mới đóng."""
        self.exercise_socket('complete')

    def test_missing_idle_and_partial_body_close_by_deadline(self):
        """Peer im lặng sau C hoặc thiếu byte cuối đều bị đóng theo deadline, không được PASS confirmed."""
        with patch.object(bridge, 'FRAME_TIMEOUT', .2), patch.object(bridge, 'ARM_TIMEOUT', .4):
            for mode in ('missingIdle', 'partialFrame'):
                with self.subTest(mode=mode):
                    self.exercise_socket(mode)

    def test_shutdown_cancels_capture_and_joins_active_workers(self):
        """Stop khi đã suppress C nhưng chưa có Z phải đóng cả2socket và join worker, không đợi arm timeout."""
        self.exercise_socket('cancel')


if __name__ == '__main__':
    unittest.main()
