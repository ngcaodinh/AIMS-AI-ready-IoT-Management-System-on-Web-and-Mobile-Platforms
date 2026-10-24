"""Kiểm tra guard của runner trước khi cho phép ghi PostgreSQL thật."""

import importlib.util
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch


RUNNER_PATH = Path(__file__).resolve().parents[3] / "ops/database/verify_database.py"
SPECIFICATION = importlib.util.spec_from_file_location("database_lab", RUNNER_PATH)
RUNNER = importlib.util.module_from_spec(SPECIFICATION)
SPECIFICATION.loader.exec_module(RUNNER)


class LabGuardTests(unittest.TestCase):
    """Ngăn dùng nhầm container hoặc thay image/cổng trong lần chạy lại."""

    # Chỉ nhận identity, image, user và network đúng manifest để bảo vệ đích ghi.
    def test_accepts_only_exact_isolated_container(self):
        expected = {
            "label": RUNNER.PURPOSE,
            "image": "sha256:synthetic-image-identity",
            "network": "none",
            "ports": {},
            "user": "postgres",
            "mounts": "tmpfs:/var/lib/postgresql/data;",
        }
        RUNNER.validate_container(expected, expected["image"])
        for field, value in (
            ("label", "unrelated-container"),
            ("image", "sha256:different-image"),
            ("network", "bridge"),
            ("ports", {"5432/tcp": [{"HostPort": "5432"}]}),
            ("user", "root"),
            ("mounts", "bind:/tmp;"),
        ):
            with self.subTest(field=field), self.assertRaises(RuntimeError):
                RUNNER.validate_container({**expected, field: value}, expected["image"])

    # Digest chỉ nhận SHA-256 hex; không nhận SQL do caller chèn vào metadata.
    def test_migration_checksum_boundary(self):
        script = RUNNER.migration_script("SELECT 1;", "a" * 64)
        self.assertIn("pg_advisory_xact_lock", script)
        self.assertIn("migration checksum drift", script)
        self.assertIn("BEGIN;", script)
        self.assertIn("COMMIT;", script)
        for invalid in ("", "a" * 63, "A" * 64, "'; DROP SCHEMA public; --"):
            with self.subTest(checksum=invalid), self.assertRaises(ValueError):
                RUNNER.migration_script("SELECT 1;", invalid)

    # Mọi version phải có tên ổn định để replay không đổi khóa ledger0001 đã áp.
    def test_canonical_migration_versions(self):
        sources = RUNNER.migration_sources()
        self.assertEqual([version for version, _ in sources], ["draft-0001-auth", "0002-auth-integrity"])
        for version, source in sources:
            self.assertEqual(source.parent, RUNNER.ROOT / "backend/migrations")
            script = RUNNER.migration_script(source.read_text(encoding="utf-8"), "a" * 64, version)
            self.assertIn(":'migration_version'", script)
        for invalid in ("", "'; DROP TABLE users; --", "a" * 129):
            with self.subTest(version=invalid), self.assertRaises(ValueError):
                RUNNER.migration_script("SELECT 1;", "a" * 64, invalid)

    # Không được xuất evidence thành công nếu suite còn GAP, thiếu kết quả hoặc trùng tên ca.
    def test_sql_evidence_requires_real_pass_results(self):
        RUNNER.validate_sql_results(["PASS:example"])
        for invalid in ([], ["GAP:example"], ["PASS:example", "PASS:example"], ["unexpected text"]):
            with self.subTest(results=invalid), self.assertRaises(RuntimeError):
                RUNNER.validate_sql_results(invalid)

    # Tên database chỉ thuộc namespace lab; không thể nhắm postgres hoặc DB tùy ý.
    def test_database_target_allowlist(self):
        RUNNER.validate_database_name(RUNNER.DATABASE)
        RUNNER.validate_database_name("iot_database_restore_0123456789ab")
        for invalid in ("postgres", "production", "iot_database_restore_", "x;DROP DATABASE y"):
            with self.subTest(database=invalid), self.assertRaises(ValueError):
                RUNNER.validate_database_name(invalid)

    # pg_dump tạo public nhưng DB mới đã có schema này; chỉ đổi đúng lệnh tạo schema rỗng.
    def test_restore_preserves_schema_and_constraints(self):
        original = "CREATE SCHEMA public;\nCREATE TABLE public.example(id integer PRIMARY KEY);\n"
        self.assertEqual(
            RUNNER.prepare_restore_dump(original),
            "CREATE SCHEMA IF NOT EXISTS public;\nCREATE TABLE public.example(id integer PRIMARY KEY);\n",
        )
        self.assertEqual(RUNNER.prepare_restore_dump("CREATE SCHEMA another;\n"), "CREATE SCHEMA another;\n")
        with self.assertRaises(ValueError):
            RUNNER.prepare_restore_dump("CREATE SCHEMA public;\nCREATE SCHEMA public;\n")

    # Dừng trước fixture/dump nếu lab đã có dữ liệu ứng dụng ngoài bộ kiểm thử tổng hợp.
    def test_refuses_application_data_before_test_or_dump(self):
        with patch.object(RUNNER, "sql", return_value=SimpleNamespace(stdout="0\n")):
            RUNNER.ensure_empty_application_tables()
        for count in ("1\n", "100\n", ""):
            with self.subTest(count=count), patch.object(
                RUNNER, "sql", return_value=SimpleNamespace(stdout=count)
            ), self.assertRaises(RuntimeError):
                RUNNER.ensure_empty_application_tables()


if __name__ == "__main__":
    unittest.main()
