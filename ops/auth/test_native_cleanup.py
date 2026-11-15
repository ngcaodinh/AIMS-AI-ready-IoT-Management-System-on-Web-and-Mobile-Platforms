"""Tiêm lỗi teardown của launcher; mọi biên DB/process/file đều giả lập, không provision fixture."""

import sys
import threading
import time
import unittest
from contextlib import ExitStack
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import MagicMock, patch
from uuid import uuid4

sys.path.insert(0, str(Path(__file__).resolve().parent))
import run_local as launcher


class NativeCleanupTests(unittest.TestCase):
    """Giữ cleanup độc lập khi bridge hoặc role lỗi, đồng thời bảo vệ graph dưới child còn sống."""

    def test_role_sql_failure_still_removes_owned_hba(self):
        """SQL revoke thất bại vẫn phải thử đóng HBA thuộc run đã xác minh, rồi trả lỗi cố định."""
        with patch.object(launcher.repository, 'owns_probe', return_value=True), patch.object(launcher.lab, 'sql', return_value=SimpleNamespace(returncode=1)), patch.object(launcher.repository, 'scoped_hba') as hba:
            with self.assertRaises(RuntimeError):
                launcher.revoke(uuid4())
        hba.assert_called_once_with(False)

    def test_role_sql_exception_still_removes_owned_hba(self):
        """Timeout ở biên SQL không được bỏ qua HBA; exception gốc vẫn báo cleanup chưa xác nhận."""
        with patch.object(launcher.repository, 'owns_probe', return_value=True), patch.object(launcher.lab, 'sql', side_effect=TimeoutError('synthetic fault')), patch.object(launcher.repository, 'scoped_hba') as hba:
            with self.assertRaises(TimeoutError):
                launcher.revoke(uuid4())
        hba.assert_called_once_with(False)

    def test_unknown_owner_cannot_revoke_or_remove_hba(self):
        """Không có provenance đúng thì không tác động role hoặc HBA của lượt khác."""
        with patch.object(launcher.repository, 'owns_probe', return_value=False), patch.object(launcher.lab, 'sql') as sql, patch.object(launcher.repository, 'scoped_hba') as hba:
            launcher.revoke(uuid4())
        sql.assert_not_called()
        hba.assert_not_called()

    def test_bridge_exception_does_not_skip_socket_close(self):
        """Shutdown raise vẫn đóng listener và trả False, không biến việc thử cleanup thành PASS."""
        server = MagicMock()
        server.shutdown.side_effect = OSError('synthetic fault')
        self.assertFalse(launcher.close_bridge(server, timeout_seconds=.1))
        server.server_close.assert_called_once_with()

    def test_bridge_hang_is_bounded_and_close_is_attempted(self):
        """Bridge treo chỉ chiếm budget riêng; giải phóng worker giả sau assertion để test không sót thread."""
        released = threading.Event()
        finished = threading.Event()

        def blocked_shutdown():
            """Mô phỏng shutdown đang chờ tài nguyên; test sở hữu event để kết thúc worker sau timeout."""
            released.wait(2)
            finished.set()

        server = MagicMock()
        server.shutdown.side_effect = blocked_shutdown
        started = time.monotonic()
        try:
            self.assertFalse(launcher.close_bridge(server, timeout_seconds=.05))
            self.assertLess(time.monotonic() - started, 1)
            server.server_close.assert_called_once_with()
        finally:
            released.set()
            self.assertTrue(finished.wait(1))

    def test_bridge_success_is_confirmed(self):
        """Chỉ hai bước bridge kết thúc không lỗi mới cho phép trả True."""
        server = MagicMock()
        self.assertTrue(launcher.close_bridge(server, timeout_seconds=.1))
        server.shutdown.assert_called_once_with()
        server.server_close.assert_called_once_with()

    def run_faulted_launcher(self, bridge_error=False, graph_error=False, child_error=False):
        """Chạy finally thật với process/DB/file giả để quan sát mutation và dấu journal.

        Input
        Param: bridge_error — gây lỗi bridge sau khi owned child đã kết thúc.
        Param: graph_error — gây lỗi xóa graph để kiểm role cleanup độc lập.
        Param: child_error — làm stop child chưa xác nhận, buộc giữ graph/role/journal.
        Output: các spy cleanup/revoke/journal sau khi run đã trả lỗi cố định.
        """
        server = MagicMock()
        server.server_address = ('127.0.0.1', 4000)
        if bridge_error:
            server.shutdown.side_effect = OSError('synthetic bridge fault')
        with ExitStack() as stack:
            stack.enter_context(patch.object(launcher.lab, 'inspect_lab'))
            stack.enter_context(patch.object(launcher.lab, 'sql', return_value=SimpleNamespace(stdout=str(len(launcher.repository.platform.SOURCE_NAMES)))))
            stack.enter_context(patch.object(launcher.subprocess, 'run', return_value=SimpleNamespace(returncode=0)))
            stack.enter_context(patch.object(launcher.subprocess, 'Popen', side_effect=AssertionError('Unpatched process boundary')))
            stack.enter_context(patch.object(launcher.getpass, 'getpass', return_value='Aa1' + 'a' * 32))
            stack.enter_context(patch.object(Path, 'mkdir'))
            journal = stack.enter_context(patch.object(Path, 'write_text'))
            stack.enter_context(patch.object(launcher, 'provision'))
            stack.enter_context(patch.object(launcher.bridge, 'InspectionServer', return_value=server))
            stack.enter_context(patch.object(launcher, 'start_lab', return_value=MagicMock()))
            stack.enter_context(patch.object(launcher, 'stop_lab', side_effect=OSError('synthetic child fault') if child_error else None))
            cleanup = stack.enter_context(patch.object(launcher, 'cleanup', side_effect=RuntimeError('synthetic graph fault') if graph_error else None))
            revoke = stack.enter_context(patch.object(launcher, 'revoke'))
            stack.enter_context(patch.object(launcher.repository, 'owns_probe', return_value=True))
            stack.enter_context(patch('builtins.print'))
            with self.assertRaises((RuntimeError, OSError)):
                launcher.run()
        return cleanup, revoke, journal

    def test_bridge_failure_still_cleans_graph_and_role_without_success_journal(self):
        """Bridge lỗi không che graph/role cleanup nhưng journal không được đổi thành REMOVED tổng thể."""
        cleanup, revoke, journal = self.run_faulted_launcher(bridge_error=True)
        cleanup.assert_called_once()
        revoke.assert_called_once()
        self.assertEqual(journal.call_count, 1)

    def test_graph_failure_still_revokes_role_without_success_journal(self):
        """Graph lỗi vẫn chạy finally revoke và giữ journal ban đầu phục vụ recovery."""
        cleanup, revoke, journal = self.run_faulted_launcher(graph_error=True)
        cleanup.assert_called_once()
        revoke.assert_called_once()
        self.assertEqual(journal.call_count, 1)

    def test_unconfirmed_child_prevents_graph_and_role_mutation(self):
        """Child chưa terminal phải giữ graph/role để không xóa dưới server sống."""
        cleanup, revoke, journal = self.run_faulted_launcher(child_error=True)
        cleanup.assert_not_called()
        revoke.assert_not_called()
        self.assertEqual(journal.call_count, 1)


if __name__ == '__main__':
    unittest.main()
