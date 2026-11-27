"""Kiểm boundary runner DB chung, không truy cập engine hoặc cấu hình bí mật."""

import hashlib
import json
import sys
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory
from types import SimpleNamespace
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

    def test_schema_manifest_uses_tracked_grains_and_checks_ddl(self):
        """Dựng manifest thiếu docs và vẫn từ chối bảng engine không khai báo trong DDL."""
        with TemporaryDirectory() as directory:
            root = Path(directory)
            catalog = root / "ops/database/schema-catalog-grains.json"
            catalog.parent.mkdir(parents=True)
            source = {"path": "docs/plan/database/schema-catalog.md", "sha256": "a" * 64}
            grains = {"users": "một account", "password_change_attempt_buckets": "một bucket theo user"}
            catalog_data = json.dumps({"source": source, "grains": grains}).encode("utf-8")
            catalog.write_bytes(catalog_data)

            migration = root / "fixture.sql"
            migration.write_text(
                "CREATE TABLE users (user_id uuid PRIMARY KEY);\n"
                "CREATE TABLE public.password_change_attempt_buckets (user_id uuid PRIMARY KEY);\n"
                "CREATE TABLE rule_draft_references (user_id uuid PRIMARY KEY);\n",
                encoding="utf-8",
            )
            table_names = (*grains, "rule_draft_references")
            tables = [
                {
                    "name": table_name,
                    "columns": [{"name": "user_id", "nullable": "NO"}],
                    "constraints": [{"definition": "PRIMARY KEY (user_id)"}],
                }
                for table_name in table_names
            ]
            internal = SimpleNamespace(stdout="[]")
            matching = SimpleNamespace(stdout=json.dumps({"tables": tables}))
            mismatching = SimpleNamespace(stdout=json.dumps({"tables": tables + [{"name": "unexpected_table"}]}))
            with patch.object(platform, "ROOT", root), patch.object(platform, "sources", return_value=(migration,)):
                with patch.object(platform, "sql", side_effect=(matching, internal)):
                    manifest = platform.schema_manifest()
                with patch.object(platform, "sql", side_effect=(mismatching, internal)):
                    with self.assertRaisesRegex(RuntimeError, "DDL drift=.*unexpected_table"):
                        platform.schema_manifest()

            self.assertEqual(manifest["table_count"], 3)
            self.assertEqual(manifest["catalog_table_count"], 3)
            self.assertEqual(manifest["tables"][1]["grain"], grains["password_change_attempt_buckets"])
            self.assertEqual(manifest["catalog_input"], {
                "path": "ops/database/schema-catalog-grains.json",
                "sha256": hashlib.sha256(catalog_data).hexdigest(),
                "source": source,
            })

    def test_catalog_projection_requires_pinned_source_hash(self):
        """Từ chối bản chiếu thiếu SHA nguồn hợp lệ thay vì sinh evidence không truy vết được."""
        with TemporaryDirectory() as directory:
            root = Path(directory)
            catalog = root / "ops/database/schema-catalog-grains.json"
            catalog.parent.mkdir(parents=True)
            catalog.write_text(json.dumps({
                "source": {"path": "docs/plan/database/schema-catalog.md", "sha256": "unverified"},
                "grains": {"users": "một account"},
            }), encoding="utf-8")
            with patch.object(platform, "ROOT", root), self.assertRaisesRegex(ValueError, "Invalid catalog source"):
                platform.read_catalog_grains()

    # Fixture cleanup chỉ được sinh cho UUID đã biết, không nhận ID/path tùy ý.
    def test_concurrency_fixture_target_is_bounded(self):
        """Output: builder không thể phát SQL tạo/xóa tenant ngoài fixture103..107."""
        for number in (0, 1, 102, 108, -1):
            with self.subTest(identity=number), self.assertRaises(ValueError):
                platform.platform_concurrency.workspace_transaction(number)
