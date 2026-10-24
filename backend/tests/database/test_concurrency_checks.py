"""Kiểm giao tiếp với psql đã thoát do SQLSTATE, không nhầm pipe Windows với lỗi database."""

import importlib.util
import unittest
from pathlib import Path
from unittest.mock import Mock


SOURCE = Path(__file__).resolve().parents[3] / "ops/database/concurrency_checks.py"
SPECIFICATION = importlib.util.spec_from_file_location("concurrency_checks", SOURCE)
CHECKS = importlib.util.module_from_spec(SPECIFICATION)
SPECIFICATION.loader.exec_module(CHECKS)


class SqlSessionTests(unittest.TestCase):
    """Contender bị từ chối có thể đóng pipe trước khi caller gửi COMMIT."""

    # Vẫn thu exit code/log khi write COMMIT gặp EINVAL do client lỗi đã đóng pipe trên Windows.
    def test_closed_pipe_keeps_postgresql_failure_evidence(self):
        session = CHECKS.SqlSession.__new__(CHECKS.SqlSession)
        session.process = Mock(returncode=3)
        session.process.stdin.write.side_effect = OSError(22, "Invalid argument")
        session.reader = Mock()
        session.output = ["ERROR:  40001: could not serialize access\n"]
        code, output = session.finish()
        self.assertEqual(code, 3)
        self.assertIn("40001", output)
        session.process.stdin.close.assert_called_once()

    # Không được coi lỗi pipe là thành công nếu không có failure từ process PostgreSQL.
    def test_closed_pipe_without_failed_process_is_rejected(self):
        session = CHECKS.SqlSession.__new__(CHECKS.SqlSession)
        session.process = Mock(returncode=0)
        session.process.stdin.write.side_effect = OSError(22, "Invalid argument")
        session.reader = Mock()
        session.output = []
        with self.assertRaises(RuntimeError):
            session.finish()


if __name__ == "__main__":
    unittest.main()
