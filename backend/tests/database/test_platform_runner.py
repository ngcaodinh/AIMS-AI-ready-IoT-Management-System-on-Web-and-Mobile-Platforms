"""Kiểm boundary runner DB chung, không truy cập engine hoặc cấu hình bí mật."""

import hashlib
import sys
import unittest
from pathlib import Path
from unittest.mock import patch


sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "ops/database"))
import verify_platform as platform


class PlatformRunnerTests(unittest.TestCase):
    """Không cho artifact một DB bị chuyển sang DB khác hoặc âm thầm thiếu migration."""

    # Guard phải chặn trước khi tới Docker, kể cả database có format hợp lệ của runner legacy.
    def test_rejects_every_noncanonical_database(self):
        """Output: không gọi adapter nếu caller chọn auth/restore/system DB hoặc SQL injection."""
        with patch.object(platform.lab, "sql") as adapter:
            for name in ("postgres", "iot_database_lab", "iot_database_restore_123456789abc", "other", "';DROP DATABASE postgres;--"):
                with self.subTest(database=name), self.assertRaises(ValueError):
                    platform.sql("SELECT 1;", database=name)
            adapter.assert_not_called()

    # Không glob theo file hiện có vì thiếu một slice phải fail trước migration đầu tiên.
    def test_missing_canonical_slice_is_fatal(self):
        """Output: FileNotFoundError thay vì báo schema hoàn chỉnh từ danh sách migration bị thiếu."""
        with patch.object(platform, "MIGRATIONS", platform.ROOT / "backend/migrations/nonexistent-platform-fixture"):
            with self.assertRaises(FileNotFoundError):
                platform.sources()

    # Artifact phân phối phải giữ target và checksum byte nguồn, không biến snapshot thành migration.
    def test_aggregate_contains_every_version_and_exact_checksum(self):
        """Output: bộ SQL tổng hợp có guard một DB và đủ numbered migration theo thứ tự."""
        bundle = platform.bundle_sql()
        self.assertIn("current_database()='iot_platform_lab'", bundle)
        self.assertEqual(bundle.count("\\set migration_version "), len(platform.SOURCE_NAMES))
        previous_position = -1
        for source in platform.sources():
            version, checksum = platform.migration_identity(source)
            self.assertEqual(checksum, hashlib.sha256(source.read_bytes()).hexdigest())
            position = bundle.index("\\set migration_version " + version)
            self.assertGreater(position, previous_position)
            self.assertIn("\\set migration_checksum " + checksum, bundle)
            previous_position = position

    # Fixture cleanup chỉ được sinh cho UUID đã biết, không nhận ID/path tùy ý.
    def test_concurrency_fixture_target_is_bounded(self):
        """Output: builder không thể phát SQL tạo/xóa tenant ngoài fixture103..107."""
        for number in (0, 1, 102, 108, -1):
            with self.subTest(identity=number), self.assertRaises(ValueError):
                platform.platform_concurrency.workspace_transaction(number)
