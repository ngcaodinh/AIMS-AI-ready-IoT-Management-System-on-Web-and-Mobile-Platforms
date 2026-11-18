"""Kiểm binding psql bằng process mock; không mở Docker/DB hoặc đọc cấu hình môi trường."""

import subprocess
import unittest
from unittest.mock import patch

import verify_database as database


# Chỉ là chuỗi công khai có hình dạng digest để kiểm boundary, không phải HMAC của fixture thật.
SYNTHETIC_DIGESTS = tuple(character * 64 for character in "abcdef")
SYNTHETIC_DIGEST_LIST = ",".join(SYNTHETIC_DIGESTS)


class PsqlVariableTests(unittest.TestCase):
    """Giữ allowlist tham số, đích và process boundary khi thêm danh sách bucket owned."""

    def test_six_unique_digests_are_bound_as_one_argument(self):
        """Danh sách đủ sáu giá trị đi qua một --set, SQL stdin giữ nguyên và không có shell/env override."""
        # SQL chỉ tới mock; ca này kiểm transport binding, không chạy hoặc đọc bucket thật.
        statement = "SELECT 1;"
        completed = subprocess.CompletedProcess([], 0, stdout="0\n", stderr="")
        with patch.object(database.subprocess, "run", return_value=completed) as run_process:
            result = database.sql(statement, role=database.ADMIN, database="iot_platform_lab",
                                  variables=(("auth_lab_bucket_digests", SYNTHETIC_DIGEST_LIST),))
        self.assertIs(result, completed)
        self.assertEqual(run_process.call_count, 1)
        arguments = run_process.call_args.args[0]
        self.assertEqual(arguments[0], "docker")
        self.assertEqual(arguments.count("--set"), 1)
        self.assertTrue(arguments[-2:] == ["--set", "auth_lab_bucket_digests=" + SYNTHETIC_DIGEST_LIST],
                        "DIGEST_LIST_MUST_BE_ONE_BOUND_VALUE")
        options = run_process.call_args.kwargs
        self.assertEqual(options["input"], statement)
        self.assertNotIn("shell", options)
        self.assertNotIn("env", options)

    def test_malformed_or_incomplete_digest_lists_do_not_spawn(self):
        """Thiếu/thừa scope, sai kiểu hoặc ký tự chèn lệnh phải bị chặn trước process, không log giá trị."""
        invalid_values = [
            "", ",".join(SYNTHETIC_DIGESTS[:5]), ",".join((*SYNTHETIC_DIGESTS, "0" * 64)),
            ",".join((SYNTHETIC_DIGESTS[0],) * 6),
            ",".join((SYNTHETIC_DIGESTS[0], *SYNTHETIC_DIGESTS[:5])),
            SYNTHETIC_DIGEST_LIST.upper(),
            SYNTHETIC_DIGEST_LIST.replace(",", ";"), SYNTHETIC_DIGEST_LIST + ",",
            " " + SYNTHETIC_DIGEST_LIST, SYNTHETIC_DIGEST_LIST + "\n",
            SYNTHETIC_DIGEST_LIST + "';SELECT 1;--", SYNTHETIC_DIGEST_LIST.encode(),
            None, 6, list(SYNTHETIC_DIGESTS),
        ]
        with patch.object(database.subprocess, "run") as run_process:
            for index, value in enumerate(invalid_values):
                with self.subTest(case=index):
                    with self.assertRaises(ValueError):
                        database.sql("SELECT 1;", database="iot_platform_lab",
                                     variables=(("auth_lab_bucket_digests", value),))
            run_process.assert_not_called()

    def test_duplicate_new_binding_does_not_spawn(self):
        """Không cho psql ghi đè scope bằng tên binding mới lặp lại dù cả hai value đều hợp lệ."""
        with patch.object(database.subprocess, "run") as run_process:
            with self.assertRaises(ValueError):
                database.sql("SELECT 1;", database="iot_platform_lab", variables=(
                    ("auth_lab_bucket_digests", SYNTHETIC_DIGEST_LIST),
                    ("auth_lab_bucket_digests", SYNTHETIC_DIGEST_LIST),
                ))
            run_process.assert_not_called()

    def test_existing_bindings_retain_their_behavior(self):
        """Giữ variable hiện hữu cùng UUID giới hạn của oracle logout và fixture offline expired."""
        user_id = "aaaaaaaa-1111-4111-8111-111111111111"
        session_id = "bbbbbbbb-2222-4222-8222-222222222222"
        context_id = "cccccccc-3333-4333-8333-333333333333"
        installation_id = "dddddddd-4444-4444-8444-444444444444"
        survivor_installation_id = "eeeeeeee-5555-4555-8555-555555555555"
        bindings = (("migration_checksum", "a" * 64), ("migration_version", "test-auth-version"),
                    ("auth_fault_user_id", user_id), ("auth_fault_bucket_digest", "b" * 64),
                    ("auth_fault_expired_session_id", session_id),
                    ("auth_fault_expired_context_id", context_id), ("auth_fault_token_digest", "d" * 64),
                    ("auth_fault_correlations", user_id), ("auth_fault_correlations", ""),
                    ("auth_fault_session_ids", session_id + "," + context_id + "," + installation_id),
                    ("auth_fault_installation_id", installation_id),
                    ("auth_fault_survivor_installation_id", survivor_installation_id))
        completed = subprocess.CompletedProcess([], 0, stdout="0\n", stderr="")
        with patch.object(database.subprocess, "run", return_value=completed) as run_process:
            database.sql("SELECT 1;", database="iot_platform_lab", variables=bindings)
            self.assertEqual(run_process.call_args.args[0].count("--set"), len(bindings))

    def test_logout_oracle_bindings_reject_invalid_scope_before_spawn(self):
        """Oracle logout chỉ nhận 1–3 UUID phiên và hai UUID installation, chặn SQL/option injection."""
        valid_session_id = "bbbbbbbb-2222-4222-8222-222222222222"
        invalid = (
            ("auth_fault_session_ids", ""),
            ("auth_fault_session_ids", valid_session_id + ",not-a-uuid"),
            ("auth_fault_session_ids", ",".join((valid_session_id,) * 4)),
            ("auth_fault_session_ids", valid_session_id + "' --"),
            ("auth_fault_installation_id", "not-a-uuid"),
            ("auth_fault_installation_id", valid_session_id + " --"),
            ("auth_fault_survivor_installation_id", "not-a-uuid"),
            ("auth_fault_survivor_installation_id", valid_session_id + " --"),
        )
        with patch.object(database.subprocess, "run") as run_process:
            for name, value in invalid:
                with self.subTest(name=name, value_length=len(value)):
                    with self.assertRaises(ValueError):
                        database.sql("SELECT 1;", database="iot_platform_lab", variables=((name, value),))
            run_process.assert_not_called()

    def test_expired_fixture_bindings_reject_malformed_values_before_spawn(self):
        """Expired fixture chỉ nhận UUID và SHA-256 hex chặt, không cho chèn psql option/SQL."""
        invalid = (
            ("auth_fault_expired_session_id", "not-a-uuid"),
            ("auth_fault_expired_context_id", "a" * 36 + "'"),
            ("auth_fault_token_digest", "e" * 63),
            ("auth_fault_token_digest", "f" * 63 + "g"),
        )
        with patch.object(database.subprocess, "run") as run_process:
            for name, value in invalid:
                with self.subTest(name=name, value_length=len(value)):
                    with self.assertRaises(ValueError):
                        database.sql("SELECT 1;", database="iot_platform_lab", variables=((name, value),))
            run_process.assert_not_called()

    def test_unknown_binding_does_not_spawn(self):
        """Tên gần giống không được mở rộng thành quyền truyền psql variable tùy ý."""
        with patch.object(database.subprocess, "run") as run_process:
            with self.assertRaises(ValueError):
                database.sql("SELECT 1;", database="iot_platform_lab",
                             variables=(("auth_lab_bucket_digest", SYNTHETIC_DIGEST_LIST),))
            run_process.assert_not_called()

    def test_database_and_role_allowlists_still_apply(self):
        """Binding mới không cho phép chuyển sang database hoặc principal ngoài allowlist đã có."""
        with patch.object(database.subprocess, "run") as run_process:
            for index, (role, database_name) in enumerate((
                ("unapproved_role", "iot_platform_lab"), (database.ADMIN, "unapproved_database"),
            )):
                with self.subTest(case=index):
                    with self.assertRaises(ValueError):
                        database.sql("SELECT 1;", role=role, database=database_name,
                                     variables=(("auth_lab_bucket_digests", SYNTHETIC_DIGEST_LIST),))
            run_process.assert_not_called()


if __name__ == "__main__":
    unittest.main()
