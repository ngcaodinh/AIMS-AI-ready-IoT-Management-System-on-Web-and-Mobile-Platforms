"""Khóa ma trận input login001; fixture tĩnh không chứng minh provider đã xử lý đúng."""

import json
import unittest
from datetime import datetime, timedelta
from pathlib import Path


CONTRACT_ROOT = Path(__file__).resolve().parents[1]


class LoginContractTests(unittest.TestCase):
    """Giữ nhánh validation và dữ liệu biên đủ cụ thể cho runner provider sau CP-01."""

    # Đọc đúng artifact tổng hợp, không truy cập credential hay cấu hình môi trường.
    def setUp(self):
        self.fixtures = json.loads(
            (CONTRACT_ROOT / "fixtures/auth/login-validation-scenarios.json").read_text(
                encoding="utf-8"
            )
        )
        self.scenarios = {item["id"]: item for item in self.fixtures["scenarios"]}

    # Mỗi field phải có ví dụ thiếu/null/sai kiểu, tránh chỉ kiểm đủ các HTTP status.
    def test_required_fields_cover_missing_null_and_type_without_coercion(self):
        for field in ("email", "password", "clientType"):
            for case, code in (("MISSING", "REQUIRED"), ("NULL", "TYPE"), ("TYPE", "TYPE")):
                scenario_id = f"CT-LOGIN-{field.upper()}-{case}"
                with self.subTest(scenario=scenario_id):
                    self.assertIn(scenario_id, self.scenarios)
                    scenario = self.scenarios[scenario_id]
                    body = scenario["request"]["body"]
                    if case == "MISSING":
                        self.assertNotIn(field, body)
                    elif case == "NULL":
                        self.assertIsNone(body[field])
                    else:
                        self.assertNotIsInstance(body[field], str)
                        self.assertIsNotNone(body[field])
                    self.assertEqual(scenario["response"]["status"], 422)
                    self.assertEqual(
                        scenario["response"]["body"]["error"]["details"]["fieldErrors"],
                        [{"path": f"/{field}", "code": code}],
                    )

    # Giữ biên9–128 Unicode scalar mới và khoảng trắng thật để phát hiện trim/đếm byte sai.
    def test_password_boundary_inputs_preserve_unicode_and_whitespace(self):
        for length, status in ((8, 422), (9, 200), (128, 200), (129, 422)):
            scenario_id = f"CT-LOGIN-PASSWORD-LENGTH-{length}"
            with self.subTest(scenario=scenario_id):
                self.assertIn(scenario_id, self.scenarios)
                scenario = self.scenarios[scenario_id]
                self.assertEqual(len(scenario["request"]["body"]["password"]), length)
                self.assertEqual(scenario["response"]["status"], status)
                if status == 422:
                    self.assertEqual(
                        scenario["response"]["body"]["error"]["details"]["fieldErrors"],
                        [{"path": "/password", "code": "LENGTH"}],
                    )
        self.assertIn("CT-LOGIN-PASSWORD-UNICODE-12", self.scenarios)
        unicode_case = self.scenarios["CT-LOGIN-PASSWORD-UNICODE-12"]
        unicode_password = unicode_case["request"]["body"]["password"]
        self.assertEqual(len(unicode_password), 12)
        self.assertGreater(len(unicode_password.encode("utf-16-le")) // 2, 12)
        self.assertEqual(unicode_case["response"]["status"], 200)
        self.assertIn("CT-LOGIN-PASSWORD-WHITESPACE-12", self.scenarios)
        whitespace_case = self.scenarios["CT-LOGIN-PASSWORD-WHITESPACE-12"]
        whitespace_password = whitespace_case["request"]["body"]["password"]
        self.assertEqual(len(whitespace_password), 12)
        self.assertLess(len(whitespace_password.strip()), 12)
        self.assertEqual(whitespace_case["response"]["status"], 200)
        for scenario in (unicode_case, whitespace_case):
            self.assertTrue(scenario["given"]["storedPasswordEqualsRequest"])
            self.assertIn("password-preserved-exactly", scenario["assertions"])

    # Khóa giới hạn canonical email và mẫu không ASCII mà không tự dựng email validator mới.
    def test_email_canonicalization_and_length_examples_are_concrete(self):
        for boundary, length, status in (
            ("TOTAL", 254, 200), ("TOTAL", 255, 422),
            ("LOCAL", 64, 200), ("LOCAL", 65, 422),
        ):
            scenario_id = f"CT-LOGIN-EMAIL-{boundary}-{length}"
            with self.subTest(scenario=scenario_id):
                self.assertIn(scenario_id, self.scenarios)
                scenario = self.scenarios[scenario_id]
                email = scenario["request"]["body"]["email"]
                measured_part = email if boundary == "TOTAL" else email.split("@")[0]
                self.assertEqual(len(measured_part), length)
                self.assertTrue(email.isascii())
                self.assertEqual(scenario["response"]["status"], status)
                if status == 422:
                    self.assertEqual(
                        scenario["response"]["body"]["error"]["details"]["fieldErrors"],
                        [{"path": "/email", "code": "LENGTH"}],
                    )
        for case in ("FORMAT", "UNICODE"):
            scenario_id = f"CT-LOGIN-EMAIL-{case}"
            self.assertIn(scenario_id, self.scenarios)
            scenario = self.scenarios[scenario_id]
            self.assertEqual(scenario["response"]["status"], 422)
            self.assertEqual(
                scenario["response"]["body"]["error"]["details"]["fieldErrors"],
                [{"path": "/email", "code": "FORMAT"}],
            )
        unicode_email = self.scenarios["CT-LOGIN-EMAIL-UNICODE"]["request"]["body"]["email"]
        self.assertFalse(unicode_email.isascii())
        self.assertIn("CT-LOGIN-EMAIL-CANONICAL", self.scenarios)
        canonical_case = self.scenarios["CT-LOGIN-EMAIL-CANONICAL"]
        self.assertEqual(
            canonical_case["request"]["body"]["email"], "\t Member+tag@Example.Test \r\n"
        )
        self.assertEqual(
            canonical_case["response"]["body"]["me"]["email"], "member+tag@example.test"
        )
        self.assertEqual(canonical_case["response"]["status"], 200)

    # Từ chối mọi authority do client khai, không lặp lại tên field tùy ý trong lỗi.
    def test_client_authority_fields_have_root_unknown_field_errors(self):
        for field in ("role", "workspaceId", "userId", "permissions"):
            scenario_id = f"CT-LOGIN-UNKNOWN-{field.upper()}"
            with self.subTest(scenario=scenario_id):
                self.assertIn(scenario_id, self.scenarios)
                scenario = self.scenarios[scenario_id]
                self.assertIn(field, scenario["request"]["body"])
                self.assertEqual(scenario["response"]["status"], 422)
                self.assertEqual(
                    scenario["response"]["body"]["error"]["details"]["fieldErrors"],
                    [{"path": "", "code": "UNKNOWN_FIELD"}],
                )

    # Phân biệt JSON hỏng với JSON đúng cú pháp nhưng sai kiểu/body/enum/rỗng.
    def test_json_shape_empty_fields_and_client_enum_are_rejected(self):
        cases = {
            "MALFORMED": (400, "", "MALFORMED_JSON"),
            "ROOT-NULL": (422, "", "TYPE"),
            "ROOT-ARRAY": (422, "", "TYPE"),
            "EMAIL-EMPTY": (422, "/email", "FORMAT"),
            "PASSWORD-EMPTY": (422, "/password", "LENGTH"),
            "CLIENTTYPE-EMPTY": (422, "/clientType", "ENUM"),
            "CLIENTTYPE-ENUM": (422, "/clientType", "ENUM"),
        }
        for case, (status, path, code) in cases.items():
            scenario_id = f"CT-LOGIN-{case}"
            with self.subTest(scenario=scenario_id):
                self.assertIn(scenario_id, self.scenarios)
                scenario = self.scenarios[scenario_id]
                self.assertEqual(scenario["response"]["status"], status)
                self.assertEqual(
                    scenario["response"]["body"]["error"]["details"]["fieldErrors"],
                    [{"path": path, "code": code}],
                )
                if case == "MALFORMED":
                    with self.assertRaises(json.JSONDecodeError):
                        json.loads(scenario["request"]["rawBody"])
                elif case == "ROOT-NULL":
                    self.assertIsNone(scenario["request"]["body"])
                elif case == "ROOT-ARRAY":
                    self.assertIsInstance(scenario["request"]["body"], list)
                elif case.endswith("EMPTY"):
                    self.assertEqual(scenario["request"]["body"][path[1:]], "")
                else:
                    self.assertNotIn(
                        scenario["request"]["body"]["clientType"], ("WEB", "ANDROID", "IOS")
                    )

    # Lỗi validation không được cấp credential hay chứa input; thành công cần account fixture riêng.
    def test_fixture_errors_are_safe_and_successes_define_synthetic_setup(self):
        self.assertTrue(self.scenarios)
        self.assertEqual(len(self.scenarios), len(self.fixtures["scenarios"]))
        self.assertEqual(self.fixtures["fixtureKind"], "synthetic-contract-example")
        for scenario in self.scenarios.values():
            with self.subTest(scenario=scenario["id"]):
                self.assertEqual(scenario["operationId"], "login")
                response = scenario["response"]
                self.assertEqual(response["headers"]["Cache-Control"], "no-store")
                if response["status"] == 200:
                    self.assertTrue(scenario["given"]["storedPasswordEqualsRequest"])
                    self.assertEqual(scenario["given"]["accountStatus"], "ACTIVE")
                    self.assertEqual(
                        scenario["given"]["emailNormalized"], response["body"]["me"]["email"]
                    )
                    self.assertFalse(response["body"]["limited"])
                    self.assertFalse(response["body"]["me"]["mustChangePassword"])
                    issued_at = datetime.fromisoformat(scenario["given"]["issuedAt"])
                    expires_at = datetime.fromisoformat(response["body"]["expiresAt"])
                    self.assertEqual(expires_at - issued_at, timedelta(hours=24))
                    continue
                self.assertIn(response["status"], (400, 422))
                self.assertNotIn("Set-Cookie", response["headers"])
                self.assertEqual(set(response["body"]), {"error"})
                error = response["body"]["error"]
                self.assertEqual(set(error), {"code", "message", "details", "correlationId"})
                self.assertEqual(error["code"], "VALIDATION_ERROR")
                self.assertTrue(error["correlationId"])
                self.assertEqual(set(error["details"]), {"fieldErrors"})
                for field_error in error["details"]["fieldErrors"]:
                    self.assertEqual(set(field_error), {"path", "code"})
                self.assertTrue(
                    {"no-session", "no-cookie", "no-credential-emitted"}.issubset(
                        scenario["assertions"]
                    )
                )
                serialized = json.dumps(response, ensure_ascii=False)
                for canary in (
                    "synthetic-password", "member@example.test", "Bearer ",
                    "tokenDigest", "passwordHash",
                ):
                    self.assertNotIn(canary, serialized)


if __name__ == "__main__":
    unittest.main()
