"""Kiểm semantic coverage, quote SQL và snapshot chú thích mà không kết nối DB."""

import json
import sys
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch


ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "ops/database"))
import schema_documentation as documentation


class SchemaDocumentationTests(unittest.TestCase):
    """Không cho trường mới bị chú thích chung chung hoặc báo đủ khi comment thực tế sai."""

    # Phủ schema thật và ledger, giữ description cho cả view projection.
    def test_covers_every_canonical_table_and_attribute(self):
        """Output: đầy đủ91 bảng public, ledger và5 history view, không mô tả rỗng."""
        manifest = json.loads((ROOT / "backend/migrations/platform/manifest.json").read_text(encoding="utf-8"))
        relations = documentation.documented_relations(manifest)
        self.assertEqual(len(relations), len(manifest["tables"]) + 6)
        for relation in relations.values():
            self.assertGreater(len(relation["description"]), 40)
            self.assertTrue(relation["columns"])
            self.assertTrue(all(len(description) > 30 for description in relation["columns"].values()))

    # Field mới cần nghĩa nghiệp vụ, không được tự chuyển snake_case thành câu mô tả giả.
    def test_missing_column_purpose_is_rejected(self):
        """Output: ValueError khi có thuộc tính mới chưa được reviewer mô tả."""
        with self.assertRaisesRegex(ValueError, "users.unreviewed_field"):
            documentation.documented_relations({"tables": [{"name": "users", "columns": [{"name": "unreviewed_field"}]}]})

    # Quote apostrophe đúng nghĩa literal; không để nội dung mô tả chèn thêm SQL.
    def test_comment_literal_escapes_apostrophes(self):
        """Output: dấu nháy đơn trong text được nhân đôi khi sinh COMMENT ON."""
        with patch.dict(documentation.COLUMN_DESCRIPTIONS, {"email_normalized": "Email của O'Reilly; chỉ là mô tả metadata."}):
            statement = documentation.render_comments_migration({"tables": [{"name": "users", "columns": [{"name": "email_normalized"}]}]})
        self.assertIn("O''Reilly", statement)
        self.assertNotIn("O'Reilly", statement)

    # Thêm comment không được nuốt comma/constraint hoặc thay kiểu dữ liệu của snapshot.
    def test_annotated_snapshot_preserves_executable_definitions(self):
        """Output: purpose trước table và cột, trong khi mọi dòng DDL ban đầu được giữ nguyên."""
        snapshot = "CREATE TABLE public.users (\n    user_id uuid NOT NULL,\n    email_normalized text NOT NULL,\n    CONSTRAINT users_pkey PRIMARY KEY (user_id)\n);\n"
        manifest = {"tables": [{"name": "users", "columns": [{"name": "user_id"}, {"name": "email_normalized"}]}]}
        rendered = documentation.annotate_snapshot(snapshot, manifest)
        self.assertTrue(rendered.startswith("/* public.users\n"))
        for line in snapshot.splitlines():
            self.assertIn(line, rendered.splitlines())
        self.assertIn("    -- Identity tài khoản toàn cục", rendered)

    # pg_dump quote từ khóa như position; công dụng vẫn phải nằm cạnh column definition.
    def test_quoted_column_receives_inline_documentation(self):
        """Output: tên được pg_dump quote như position vẫn có công dụng trước định nghĩa, giữ nguyên DDL."""
        snapshot = 'CREATE TABLE public.dashboard_widgets (\n    "position" integer NOT NULL\n);\n'
        manifest = {"tables": [{"name": "dashboard_widgets", "columns": [{"name": "position"}]}]}
        rendered = documentation.annotate_snapshot(snapshot, manifest)
        self.assertIn('    -- Thứ tự widget trên mobile', rendered)
        self.assertIn('    "position" integer NOT NULL', rendered)

    # So đúng text thực tế, không chấp nhận một comment bất kỳ chỉ vì nó không NULL.
    def test_native_check_rejects_wrong_database_comment(self):
        """Output: kiểm engine fail nếu purpose bảng/cột khác dictionary đã review."""
        manifest = {"tables": []}
        actual = documentation.documented_relations(manifest)
        actual["migration_control.applied_migrations"]["columns"]["checksum"] = "Nội dung sai nhưng không rỗng"
        with self.assertRaisesRegex(RuntimeError, "migration_control.applied_migrations"):
            documentation.verify_native_comments(Mock(return_value=SimpleNamespace(stdout=json.dumps(actual))), manifest)
