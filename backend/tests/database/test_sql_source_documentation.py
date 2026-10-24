"""Kiểm chú thích từng cột và lexer giữ nguyên SQL khi source có literal/comment/dollar-body."""

import sys
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory

sys.path.insert(0,str(Path(__file__).resolve().parents[3]/"ops/database"))
import sql_source_documentation as source_documentation


class SqlSourceDocumentationTests(unittest.TestCase):
    """Chỉ cho thay comment/format, không cho vô tình hợp thức hóa executable drift."""

    # Comment marker trong literal hoặc function body không được coi là comment ngoài SQL.
    def test_tokens_preserve_literals_and_function_bodies(self):
        """Output: bỏ comment thật nhưng giữ nguyên chuỗi và dollar-body."""
        statement="SELECT '--text', '/*literal*/', $$BEGIN -- body\n END$$; /* outer /* nested */ done */"
        tokens=[token[0] for token in source_documentation.sql_tokens(statement)]
        self.assertIn("'--text'",tokens)
        self.assertIn("'/*literal*/'",tokens)
        self.assertIn('$$BEGIN -- body\n END$$',tokens)
        self.assertNotIn('outer',tokens)

    # Comma trong CHECK/literal không được biến thành thuộc tính mới hoặc thay executable tokens.
    def test_each_column_is_documented_without_sql_change(self):
        """Output: một thuộc tính mỗi dòng, có purpose/type/NULL/check và mọi token giữ nguyên."""
        statement="CREATE TABLE users (user_id uuid PRIMARY KEY, email_normalized text NOT NULL CHECK(length(email_normalized) BETWEEN 3 AND 254));"
        manifest={"tables":[{"name":"users","columns":[
            {"name":"user_id","type":"uuid","nullable":"NO","default":None},
            {"name":"email_normalized","type":"text","nullable":"NO","default":None}],"constraints":[]}]}
        rendered=source_documentation.annotate_tables(statement,manifest)
        self.assertIn('-- UUID: định danh 128 bit',rendered)
        self.assertIn('không xác minh email RFC',rendered)
        self.assertIn('\n    user_id uuid PRIMARY KEY,',rendered)
        self.assertEqual([token[0] for token in source_documentation.sql_tokens(statement)],
                         [token[0] for token in source_documentation.sql_tokens(rendered)])

    # Ledger dùng schema riêng trong dictionary, không được lookup như bảng public không qualifier.
    def test_internal_ledger_uses_qualified_documentation_name(self):
        """Output: ledger migration_control có purpose/type/NULL cạnh từng cột như bảng public."""
        statement='CREATE TABLE migration_control.applied_migrations (version text NOT NULL);'
        manifest={'tables':[],'internal_tables':[{'name':'applied_migrations','columns':[
            {'name':'version','type':'text','nullable':'NO','default':None}],'constraints':[]}]}
        rendered=source_documentation.annotate_tables(statement,manifest)
        self.assertIn('Lịch sử phiên bản migration',rendered)
        self.assertIn('Identity phiên bản migration',rendered)
        self.assertIn('    version text NOT NULL',rendered)

    # Archive không phải cách bỏ qua kiểm drift; thay constraint phải dừng trước engine.
    def test_archive_rejects_executable_change(self):
        """Output: chỉ source cùng token mới được trỏ về byte archive đã áp."""
        with TemporaryDirectory() as directory:
            root=Path(directory)
            (root/'applied_sql').mkdir()
            archived=root/'applied_sql/0001_identity.sql'
            archived.write_text('CREATE TABLE users (user_id uuid);',encoding='utf-8')
            visible=root/'0001_identity.sql'
            visible.write_text('-- mô tả\nCREATE TABLE users (user_id uuid);',encoding='utf-8')
            self.assertEqual(source_documentation.executable_source(visible),archived)
            visible.write_text('CREATE TABLE users (user_id text);',encoding='utf-8')
            with self.assertRaisesRegex(RuntimeError,'executable SQL'):
                source_documentation.executable_source(visible)

    # Source không kết thúc phải fail thay vì làm mất phần còn lại khi so token.
    def test_unterminated_sql_is_rejected(self):
        """Output: lỗi rõ cho literal, dollar body và block comment chưa đóng."""
        for statement in ("SELECT 'broken",'DO $$broken','/* missing end'):
            with self.subTest(statement=statement),self.assertRaises(ValueError):
                source_documentation.sql_tokens(statement)
