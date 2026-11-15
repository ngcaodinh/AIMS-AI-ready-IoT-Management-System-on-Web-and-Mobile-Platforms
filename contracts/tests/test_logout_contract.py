"""Kiểm tĩnh wire/fixture logout002; không mô phỏng provider hoặc chứng nhận revoke thật."""

import json
import unittest
from pathlib import Path


CONTRACT_ROOT = Path(__file__).resolve().parents[1]


class LogoutContractTests(unittest.TestCase):
    """Giữ fixture logout cùng phiên bản và không làm yếu boundary đã chốt."""

    # Đọc artifact dùng chung; file fixture thiếu phải FAIL thay vì bỏ qua ca kiểm tra.
    @classmethod
    def setUpClass(cls):
        """Nạp contract và fixture một lần để mọi kiểm tra dùng cùng một bộ dữ liệu."""
        cls.contract = json.loads(
            (CONTRACT_ROOT / "openapi/auth.v1.json").read_text(encoding="utf-8")
        )
        cls.fixture = json.loads(
            (CONTRACT_ROOT / "fixtures/auth/logout-scenarios.json").read_text(encoding="utf-8")
        )
        cls.scenarios = {item["id"]: item for item in cls.fixture["scenarios"]}
        cls.operations = {
            operation["operationId"]: operation
            for path in cls.contract["paths"].values()
            for operation in path.values()
        }

    # Phiên bản, ID và status phải khớp OpenAPI; 204 không được dựng JSON giả.
    def test_fixture_version_unique_ids_and_wire_responses(self):
        self.assertEqual(self.fixture["contractVersion"], self.contract["info"]["version"])
        self.assertEqual(self.fixture["fixtureKind"], "synthetic-contract-example")
        self.assertEqual(len(self.scenarios), len(self.fixture["scenarios"]))
        codes = self.contract["components"]["schemas"]["ErrorEnvelope"]["properties"]
        codes = codes["error"]["properties"]["code"]["enum"]
        for scenario in self.scenarios.values():
            with self.subTest(scenario=scenario["id"]):
                response = scenario["response"]
                self.assertIn(str(response["status"]), self.operations[scenario["operationId"]]["responses"])
                self.assertEqual(response["headers"]["Cache-Control"], "no-store")
                if response["status"] == 204:
                    self.assertIsNone(response["body"])
                else:
                    error = response["body"]["error"]
                    self.assertEqual(set(error), {"code", "message", "details", "correlationId"})
                    self.assertIn(error["code"], codes)
                    self.assertNotIn("Set-Cookie", response["headers"])

    # Một phiên logout không được thu hồi toàn account hoặc bỏ qua limited/expiry/repeat.
    def test_resolver_matrix_and_session_isolation_expectations(self):
        matrix = {
            "CT-LOGOUT-001": ("active", 204),
            "CT-LOGOUT-002": ("active", 204),
            "CT-LOGOUT-003": ("revoked", 204),
            "CT-LOGOUT-LIMITED": ("limited", 204),
            "CT-LOGOUT-006-EXPIRED": ("expired", 204),
            "CT-LOGOUT-006-ABSENT": ("absent", 204),
            "CT-LOGOUT-006-UNKNOWN": ("unknown", 401),
            "CT-LOGOUT-006-MALFORMED": ("malformed", 401),
            "CT-LOGOUT-006-DB-DOWN": ("storeUnavailable", 503),
        }
        policy = self.operations["logout"]["x-logout-policy"]["credentialOutcomes"]
        for scenario_id, (state, status) in matrix.items():
            scenario = self.scenarios[scenario_id]
            with self.subTest(scenario=scenario_id):
                self.assertEqual(scenario["request"]["credentialState"], state)
                self.assertEqual(scenario["response"]["status"], status)
                self.assertEqual(policy[state], status)
                if status in (401, 503):
                    self.assertEqual(
                        scenario["response"]["body"]["error"]["code"],
                        "SESSION_EXPIRED" if status == 401 else "SERVICE_UNAVAILABLE",
                    )
        for scenario_id, target, other in (
            ("CT-LOGOUT-001", "S1", "S2"), ("CT-LOGOUT-002", "S2", "S1"),
        ):
            effects = self.scenarios[scenario_id]["expectedEffects"]
            self.assertEqual(effects["revokedSession"], target)
            self.assertEqual(effects["preservedSessions"], [other])
            self.assertEqual(effects["invalidateTicketsFor"], target)
            self.assertEqual(effects["clearPushBindingIfSession"], target)
            self.assertEqual(effects["newAuditTransitions"], 1)
        repeat = self.scenarios["CT-LOGOUT-003"]
        self.assertEqual(repeat["given"]["revokedAt"], repeat["expectedEffects"]["revokedAt"])
        self.assertEqual(repeat["expectedEffects"]["newAuditTransitions"], 0)
        rebind = self.scenarios["CT-LOGOUT-REBIND-B"]
        self.assertEqual(rebind["given"]["activeSessionId"], "S2")
        self.assertEqual(rebind["expectedEffects"]["activeSessionId"], "S2")

    # Mỗi transport phải có fixture active/limited/revoked/expired để không bỏ sót Web inactive.
    def test_both_transports_cover_recognized_session_states(self):
        observed = {
            (item["request"].get("clientType"), item["request"]["credentialState"])
            for item in self.scenarios.values()
            if item["operationId"] == "logout" and item["response"]["status"] == 204
        }
        expected = {
            (client_type, state)
            for client_type in ("WEB", "ANDROID")
            for state in ("active", "limited", "revoked", "expired")
        }
        self.assertTrue(expected.issubset(observed), f"Thiếu fixture: {expected - observed}")

    # Guard đúng trước revoke, cookie clear chỉ khi Web thành công và có phiên nhận diện.
    def test_web_cookie_csrf_and_context_recovery_boundaries(self):
        expected_cookie = self.operations["logout"]["responses"]["204"]["headers"]
        expected_cookie = expected_cookie["Set-Cookie"]["schema"]["const"]
        for scenario in self.scenarios.values():
            request, response = scenario["request"], scenario["response"]
            with self.subTest(scenario=scenario["id"]):
                if response["status"] == 204 and request.get("clientType") == "WEB":
                    self.assertEqual(response["headers"]["Set-Cookie"], expected_cookie)
                    self.assertIn("X-Auth-Context-Id", request["headers"])
                    self.assertIn("X-CSRF-Token", request["headers"])
                    self.assertEqual(request["headers"]["Origin"], "https://nexa.example.test")
                else:
                    self.assertNotIn("Set-Cookie", response["headers"])
        for scenario_id, status, code in (
            ("CT-LOGOUT-CSRF-MISSING", 403, "CSRF_INVALID"),
            ("CT-LOGOUT-CSRF-REVOKED", 403, "CSRF_INVALID"),
            ("CT-LOGOUT-ORIGIN-INVALID", 403, "CSRF_INVALID"),
            ("CT-LOGOUT-CONTEXT-MISMATCH", 409, "AUTH_CONTEXT_MISMATCH"),
            ("CT-LOGOUT-CONTEXT-MISSING", 409, "AUTH_CONTEXT_MISMATCH"),
        ):
            scenario = self.scenarios[scenario_id]
            self.assertEqual(scenario["response"]["status"], status)
            self.assertEqual(scenario["response"]["body"]["error"]["code"], code)
            self.assertEqual(scenario["expectedEffects"]["newAuditTransitions"], 0)
            self.assertIn("no-side-effect", scenario["assertions"])

    # JSON có nội dung không tương đương body vắng; authority từ body luôn bị từ chối.
    def test_body_validation_mixed_credentials_and_retry_after(self):
        for scenario_id, value in (
            ("CT-LOGOUT-BODY-OBJECT", {}), ("CT-LOGOUT-BODY-NULL", None),
            ("CT-LOGOUT-BODY-ARRAY", []),
        ):
            scenario = self.scenarios[scenario_id]
            self.assertEqual(json.loads(scenario["request"]["rawBody"]), value)
            self.assertEqual(scenario["response"]["status"], 422)
        authority = self.scenarios["CT-LOGOUT-BODY-AUTHORITY"]
        self.assertEqual(authority["request"]["credentialSession"], "S1")
        self.assertEqual(json.loads(authority["request"]["rawBody"])["sessionId"], "S2")
        self.assertEqual(authority["response"]["status"], 422)
        self.assertEqual(authority["expectedEffects"]["preservedSessions"], ["S1", "S2"])
        duplicate = self.scenarios["CT-LOGOUT-BODY-DUPLICATE"]
        pairs = json.loads(duplicate["request"]["rawBody"], object_pairs_hook=list)
        self.assertGreater([key for key, _ in pairs].count("sessionId"), 1)
        self.assertEqual(duplicate["response"]["status"], 400)
        malformed = self.scenarios["CT-LOGOUT-BODY-MALFORMED"]
        with self.assertRaises(json.JSONDecodeError):
            json.loads(malformed["request"]["rawBody"])
        self.assertEqual(malformed["response"]["status"], 400)
        self.assertEqual(self.scenarios["CT-LOGOUT-MIXED"]["response"]["status"], 400)
        self.assertEqual(self.scenarios["CT-LOGOUT-MEDIA-TYPE"]["response"]["status"], 415)
        oversized = self.scenarios["CT-LOGOUT-BODY-TOO-LARGE"]
        generator = oversized["request"]["rawBodyGenerator"]
        self.assertEqual(generator["kind"], "jsonWithTrailingAsciiWhitespace")
        self.assertEqual(generator["totalBytes"], 65537)
        self.assertEqual(oversized["response"]["status"], 413)
        limited = self.scenarios["CT-LOGOUT-RATE-LIMITED"]["response"]
        self.assertEqual(limited["status"], 429)
        self.assertGreaterEqual(limited["headers"]["Retry-After"], 1)

    # HTTP lỗi sau mất ACK là UNKNOWN; không được biến thành bằng chứng chưa/đã commit.
    def test_commit_unknown_and_protected_reuse_remain_distinct(self):
        scenario = self.scenarios["CT-LOGOUT-COMMIT-UNKNOWN"]
        self.assertEqual(scenario["response"]["status"], 503)
        self.assertEqual(scenario["expectedEffects"]["commitOutcome"], "UNKNOWN")
        self.assertNotIn("no-side-effect", scenario["assertions"])
        self.assertIn("local-ui-stays-locked", scenario["assertions"])
        self.assertIn("retry-only-same-session-context", scenario["assertions"])
        reuse = self.scenarios["CT-LOGOUT-004"]
        self.assertEqual(reuse["operationId"], "getMe")
        self.assertEqual(reuse["response"]["status"], 401)
        self.assertEqual(reuse["response"]["body"]["error"]["code"], "SESSION_REVOKED")
        self.assertIn("no-protected-data", reuse["assertions"])


if __name__ == "__main__":
    unittest.main()
