"""Kiểm độ phủ fixture auth bắt buộc của FEAT-TN-001 tại checkpoint contract."""

import json
import unittest
from pathlib import Path


FIXTURE_PATH = Path(__file__).resolve().parents[1] / "fixtures" / "auth" / "scenarios.json"


class AuthQaCoverageTests(unittest.TestCase):
    # Đọc fixture synthetic hiện hành để đối chiếu ma trận client và loại phiên đã chốt.
    def setUp(self):
        self.scenarios = json.loads(FIXTURE_PATH.read_text(encoding="utf-8"))["scenarios"]

    # Mỗi client thuộc scope phải có fixture thành công cho cả phiên full và limited.
    def test_web_and_android_have_full_and_limited_login_fixtures(self):
        login_scenarios = [
            scenario
            for scenario in self.scenarios
            if scenario["operationId"] == "login"
            and scenario["response"]["status"] == 200
        ]
        observed = {
            (
                scenario["request"]["body"]["clientType"],
                scenario["response"]["body"]["limited"],
            )
            for scenario in login_scenarios
        }
        required = {("WEB", False), ("WEB", True), ("ANDROID", False), ("ANDROID", True)}
        self.assertTrue(
            required.issubset(observed), f"Missing login fixtures: {required - observed}"
        )

        for client_type, limited in required:
            with self.subTest(clientType=client_type, limited=limited):
                matching = [
                    scenario
                    for scenario in login_scenarios
                    if scenario["request"]["body"]["clientType"] == client_type
                    and scenario["response"]["body"]["limited"] == limited
                ]
                self.assertEqual(len(matching), 1)
                response = matching[0]["response"]
                self.assertEqual(
                    response["body"]["me"]["mustChangePassword"], limited
                )
                self.assertEqual(response["headers"]["Cache-Control"], "no-store")
                if client_type == "WEB":
                    self.assertNotIn("token", response["body"])
                    self.assertIn("HttpOnly", response["headers"]["Set-Cookie"])
                    self.assertIn("Secure", response["headers"]["Set-Cookie"])
                    self.assertIn("X-CSRF-Token", response["headers"])
                else:
                    self.assertTrue(
                        response["body"]["token"].startswith("<nonfunctional-")
                    )
                    self.assertNotIn("Set-Cookie", response["headers"])

    # Fixture login phải thể hiện đủ status validation đã khóa tại OQ-AUTH-008.
    def test_login_validation_fixtures_cover_http_boundaries(self):
        validation_scenarios = [
            scenario
            for scenario in self.scenarios
            if scenario["operationId"] == "login"
            and scenario["response"]["status"] >= 400
            and scenario["response"]["body"]["error"]["code"] == "VALIDATION_ERROR"
        ]
        observed = {scenario["response"]["status"] for scenario in validation_scenarios}
        required = {400, 413, 415, 422}
        self.assertTrue(
            required.issubset(observed),
            f"Missing validation statuses: {required - observed}",
        )

        expected_field_codes = {413: "BODY_TOO_LARGE", 415: "CONTENT_TYPE"}
        for status, field_code in expected_field_codes.items():
            with self.subTest(status=status):
                matches = [
                    scenario
                    for scenario in validation_scenarios
                    if scenario["response"]["status"] == status
                ]
                self.assertEqual(len(matches), 1)
                scenario = matches[0]
                response = scenario["response"]
                self.assertEqual(response["headers"]["Cache-Control"], "no-store")
                self.assertNotIn("Set-Cookie", response["headers"])
                self.assertNotIn("token", response["body"])
                self.assertEqual(
                    response["body"]["error"]["details"]["fieldErrors"],
                    [{"path": "", "code": field_code}],
                )
                self.assertNotIn(
                    "synthetic-password", json.dumps(response["body"], ensure_ascii=False)
                )
                self.assertIn("no-session", scenario["assertions"])

                if status == 413:
                    generator = scenario["request"]["rawBodyGenerator"]
                    self.assertEqual(generator["kind"], "jsonWithTrailingAsciiWhitespace")
                    self.assertEqual(
                        scenario["request"]["headers"]["Content-Type"],
                        "application/json",
                    )
                    prefix_bytes = generator["prefix"].encode("utf-8")
                    self.assertLess(len(prefix_bytes), generator["totalBytes"])
                    # Đệm ASCII whitespace sau JSON hợp lệ để vượt đúng giới hạn wire 64 KiB.
                    raw_body = prefix_bytes + b" " * (
                        generator["totalBytes"] - len(prefix_bytes)
                    )
                    self.assertEqual(len(raw_body), 64 * 1024 + 1)
                    json.loads(raw_body.decode("utf-8"))
                else:
                    self.assertEqual(
                        scenario["request"]["headers"]["Content-Type"], "text/plain"
                    )
                    json.loads(scenario["request"]["rawBody"])


if __name__ == "__main__":
    unittest.main()
