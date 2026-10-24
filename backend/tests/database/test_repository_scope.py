"""Failure injection cho lifecycle role probe; không mở Docker hoặc đọc environment thật."""

import sys
import unittest
from pathlib import Path
from unittest.mock import Mock, patch
from uuid import uuid4

sys.path.insert(0,str(Path(__file__).resolve().parents[3]/"ops/database"))
import verify_repositories as runner


class RepositoryScopeTests(unittest.TestCase):
    """Role chỉ được dọn khi marker đúng lượt chạy, và cleanup phải bao cả provision đã commit một phần."""

    def test_provision_failure_after_commit_revokes_owned_role(self):
        """HBA/setup lỗi sau SQL commit vẫn phải revoke role thuộc lượt chạy và dọn fixture an toàn."""
        with patch.object(runner,"provision_probe",side_effect=RuntimeError("HBA failure")),patch.object(runner,"owns_probe",return_value=True),patch.object(runner,"cleanup_probe") as cleanup,patch.object(runner,"revoke_probe") as revoke:
            with self.assertRaisesRegex(RuntimeError,"HBA failure"):
                with runner.probe_scope("0"*64,uuid4(),[],[]):
                    self.fail("scope must not yield after failed provision")
            cleanup.assert_called_once()
            revoke.assert_called_once()

    def test_unowned_role_is_never_revoked(self):
        """Role đã tồn tại từ lượt khác không được launcher mới tự chiếm hoặc xóa."""
        with patch.object(runner,"provision_probe",side_effect=RuntimeError("existing role")),patch.object(runner,"owns_probe",return_value=False),patch.object(runner,"cleanup_probe") as cleanup,patch.object(runner,"revoke_probe") as revoke:
            with self.assertRaises(RuntimeError):
                with runner.probe_scope("0"*64,uuid4(),[],[]):
                    self.fail("scope must not yield")
            cleanup.assert_not_called()
            revoke.assert_not_called()

    def test_fixture_cleanup_error_still_revokes_role(self):
        """Lỗi cleanup dữ liệu không được làm role LOGIN tiếp tục sống sau probe."""
        journal=Mock()
        with patch.object(runner,"provision_probe"),patch.object(runner,"owns_probe",return_value=True),patch.object(runner,"cleanup_probe",side_effect=RuntimeError("fixture failure")),patch.object(runner,"revoke_probe") as revoke:
            with self.assertRaisesRegex(RuntimeError,"fixture failure"):
                with runner.probe_scope("0"*64,uuid4(),[],[],journal=journal):
                    pass
            revoke.assert_called_once()
            journal.unlink.assert_not_called()

    def test_verification_failure_removes_journal_after_successful_cleanup(self):
        """Lượt test lỗi nhưng cleanup thành công không để journal báo nhầm fixture còn sót.
        Side effects: chỉ mock journal và role lifecycle, không chạm DB hoặc file thật.
        """
        journal=Mock()
        with patch.object(runner,"provision_probe"),patch.object(runner,"owns_probe",return_value=True),patch.object(runner,"cleanup_probe") as cleanup,patch.object(runner,"revoke_probe") as revoke:
            with self.assertRaisesRegex(RuntimeError,"verification failure"):
                with runner.probe_scope("0"*64,uuid4(),[],[],journal=journal):
                    raise RuntimeError("verification failure")
            cleanup.assert_called_once()
            revoke.assert_called_once()
            journal.unlink.assert_called_once_with(missing_ok=True)
