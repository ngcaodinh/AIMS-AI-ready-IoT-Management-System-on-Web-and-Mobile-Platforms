"""Kiểm ownership/deadline của holder bằng adapter giả, không kết nối PostgreSQL."""

from pathlib import Path
import queue
import sys
import unittest
from unittest.mock import MagicMock, patch
from uuid import uuid4

AUTH_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(AUTH_ROOT))
sys.path.insert(0, str(AUTH_ROOT.parent / 'database'))
import user_fence_holder as holder_module


class UserFenceHolderTests(unittest.TestCase):
    """Thiếu marker/actual wait/owned backend shutdown không được chuyển thành PASS."""

    def test_foreign_role_refuses_start_before_process(self):
        """Không mở owner psql nếu probe marker không thuộc đúng run."""
        holder = holder_module.UserFenceHolder(uuid4(), uuid4(), uuid4())
        with patch.object(holder_module, 'metadata_count', return_value=0), patch.object(holder_module.subprocess, 'Popen') as process:
            with self.assertRaisesRegex(RuntimeError, 'ownership'):
                holder.start()
        process.assert_not_called()

    def test_preflight_consumes_the_same_startup_budget(self):
        """Role check đã hết budget phải dừng trước inspection/Popen, không bắt đầu lại5s mới."""
        holder = holder_module.UserFenceHolder(uuid4(), uuid4(), uuid4())
        with patch.object(holder_module, 'metadata_count', return_value=1), patch.object(holder_module.time, 'monotonic', side_effect=[0, 0, 6]), patch.object(holder_module, 'inspect_owned_lab') as inspect, patch.object(holder_module.subprocess, 'Popen') as process:
            with self.assertRaisesRegex(RuntimeError, 'startup'):
                holder.start()
        inspect.assert_not_called()
        process.assert_not_called()

    def test_missing_marker_has_bounded_wait(self):
        """Một pipe sống nhưng không phát marker phải timeout bằng deadline tuyệt đối."""
        holder = holder_module.UserFenceHolder(uuid4(), uuid4(), uuid4())
        holder.process = MagicMock()
        holder.process.poll.return_value = None
        holder.lines = queue.Queue()
        with self.assertRaisesRegex(RuntimeError, 'marker'):
            holder.read_marker('FENCE_READY', .01)

    def test_ready_marker_after_deadline_is_rejected(self):
        """Marker có sẵn nhưng được xử lý sau deadline không được chứng nhận startup đúng budget."""
        holder = holder_module.UserFenceHolder(uuid4(), uuid4(), uuid4())
        holder.lines.put('FENCE_READY|12345')
        with patch.object(holder_module.time, 'monotonic', side_effect=[0, 0, 1]):
            with self.assertRaisesRegex(RuntimeError, 'marker'):
                holder.read_marker('FENCE_READY', .01)

    def test_blocker_metadata_after_deadline_is_rejected(self):
        """Kết quả wait đến muộn không được biến observation timeout thành race PASS."""
        holder = holder_module.UserFenceHolder(uuid4(), uuid4(), uuid4())
        holder.pid = 12345
        holder.process = MagicMock()
        holder.process.poll.return_value = None
        with patch.object(holder_module, 'metadata_count', return_value=1), patch.object(holder_module.time, 'monotonic', side_effect=[0, 0, 0, 4]):
            with self.assertRaisesRegex(RuntimeError, 'wait'):
                holder.wait_for_blocked()

    def test_query_error_is_not_interpreted_as_zero_backends(self):
        """Metadata không đọc được không chứng minh holder backend đã biến mất."""
        with patch.object(holder_module.subprocess, 'run', side_effect=TimeoutError):
            with self.assertRaisesRegex(RuntimeError, 'metadata'):
                holder_module.metadata_count('SELECT 0;', .01)

    def test_missing_actual_lock_wait_fails(self):
        """Không có blocker relation thật phải FAIL, không chỉ chờ một khoảng thời gian."""
        holder = holder_module.UserFenceHolder(uuid4(), uuid4(), uuid4())
        holder.pid = 12345
        holder.process = MagicMock()
        holder.process.poll.return_value = None
        with patch.object(holder_module, 'metadata_count', return_value=0), patch.object(holder_module, 'OBSERVE_TIMEOUT', .01):
            with self.assertRaisesRegex(RuntimeError, 'wait'):
                holder.wait_for_blocked()

    def test_live_backend_prevents_shutdown_success(self):
        """Popen đã thoát nhưng backend còn giữ transaction vẫn phải chặn cleanup."""
        holder = holder_module.UserFenceHolder(uuid4(), uuid4(), uuid4())
        holder.process = MagicMock()
        holder.process.poll.return_value = 0
        with patch.object(holder_module, 'metadata_count', return_value=1), patch.object(holder_module, 'SHUTDOWN_TIMEOUT', .01):
            with self.assertRaisesRegex(RuntimeError, 'backend'):
                holder.stop()


if __name__ == '__main__':
    unittest.main()
