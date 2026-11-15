"""Kiểm độc lập các invariant logout theo plan002 mục 8, 13, 14 và 22; chỉ là artifact tĩnh."""

import json
import unittest
from pathlib import Path


CONTRACT_ROOT = Path(__file__).resolve().parents[1]


class LogoutQaCoverageTests(unittest.TestCase):
    """Bắt sai lệch fixture và guard mà kiểm tra status hoặc enum chung chưa phát hiện."""

    # Đọc contract và fixture synthetic cho từng ca để không chia sẻ dữ liệu có thể bị đổi.
    def setUp(self):
        self.contract = json.loads(
            (CONTRACT_ROOT / "openapi/auth.v1.json").read_text(encoding="utf-8")
        )
        fixture = json.loads(
            (CONTRACT_ROOT / "fixtures/auth/logout-scenarios.json").read_text(encoding="utf-8")
        )
        self.scenarios = {item["id"]: item for item in fixture["scenarios"]}

    # Giữ mapping lỗi logout đã chốt; một code có trong enum chung chưa đủ đúng HTTP status.
    def test_error_codes_match_http_status(self):
        expected_codes = {
            400: "VALIDATION_ERROR", 401: "SESSION_EXPIRED", 403: "CSRF_INVALID",
            409: "AUTH_CONTEXT_MISMATCH", 413: "VALIDATION_ERROR",
            415: "VALIDATION_ERROR", 422: "VALIDATION_ERROR", 429: "RATE_LIMITED",
            503: "SERVICE_UNAVAILABLE",
        }
        for scenario in self.scenarios.values():
            response = scenario["response"]
            if scenario["operationId"] == "logout" and response["status"] >= 400:
                with self.subTest(scenario=scenario["id"]):
                    self.assertEqual(response["body"]["error"]["code"],
                                     expected_codes[response["status"]])

    # Lỗi phải có message/correlationId dùng được và không lẫn dữ liệu thành công ở body.
    def test_error_envelopes_have_usable_correlation_and_no_success_data(self):
        for scenario in self.scenarios.values():
            response = scenario["response"]
            if response["status"] >= 400:
                with self.subTest(scenario=scenario["id"]):
                    self.assertEqual(set(response["body"]), {"error"})
                    error = response["body"]["error"]
                    self.assertIsInstance(error["details"], dict)
                    for field in ("message", "correlationId"):
                        self.assertIsInstance(error[field], str)
                        self.assertTrue(error[field].strip())

    # Đối chiếu assertion với effects để fixture từ chối không đồng thời khai đã revoke/audit.
    def test_no_side_effect_examples_do_not_declare_committed_mutations(self):
        for scenario in self.scenarios.values():
            if "no-side-effect" in scenario.get("assertions", []):
                with self.subTest(scenario=scenario["id"]):
                    effects = scenario.get("expectedEffects", {})
                    self.assertEqual(effects.get("newAuditTransitions", 0), 0)
                    for field in ("revokedSession", "invalidateTicketsFor",
                                  "clearPushBindingIfSession", "revokedAt", "activeSessionId"):
                        self.assertNotIn(field, effects)
                    self.assertNotEqual(effects.get("commitOutcome"), "COMMITTED")

    # Repeat Web/App giữ timestamp đầu và phiên độc lập, không tạo audit transition mới.
    def test_repeated_logout_preserves_both_transports_timestamp_and_other_session(self):
        for scenario_id, other_session in (
            ("CT-LOGOUT-003", "S2"), ("CT-LOGOUT-APP-REPEAT", "S1"),
        ):
            scenario = self.scenarios[scenario_id]
            with self.subTest(scenario=scenario_id):
                self.assertEqual(scenario["response"]["status"], 204)
                self.assertEqual(scenario["expectedEffects"]["revokedAt"],
                                 scenario["given"]["revokedAt"])
                self.assertEqual(scenario["expectedEffects"]["preservedSessions"], [other_session])
                self.assertEqual(scenario["expectedEffects"]["newAuditTransitions"], 0)

    # Race A logout sau B rebind phải revoke S1 từ credential cũ và giữ binding/session S2.
    def test_late_revoke_targets_old_session_and_preserves_rebound_session(self):
        scenario = self.scenarios["CT-LOGOUT-REBIND-B"]
        self.assertEqual(scenario["request"]["credentialSession"], "S1")
        self.assertEqual(scenario["expectedEffects"]["revokedSession"], "S1")
        self.assertEqual(scenario["given"]["activeSessionId"], "S2")
        self.assertEqual(scenario["expectedEffects"]["activeSessionId"], "S2")
        self.assertEqual(scenario["expectedEffects"]["preservedSessions"], ["S2"])

    # Mất ACK không chứng minh commit/rollback; fixture không được khẳng định timestamp hay audit.
    def test_commit_unknown_does_not_claim_a_specific_committed_transition(self):
        scenario = self.scenarios["CT-LOGOUT-COMMIT-UNKNOWN"]
        self.assertEqual(scenario["expectedEffects"], {"commitOutcome": "UNKNOWN"})
        self.assertNotIn("no-side-effect", scenario["assertions"])
        self.assertIn("local-ui-stays-locked", scenario["assertions"])

    # Tạo đúng raw UTF-8 65537 byte và parse JSON để không test nhầm malformed trước oversize.
    def test_oversize_generator_materializes_valid_json_one_byte_above_limit(self):
        generator = self.scenarios["CT-LOGOUT-BODY-TOO-LARGE"]["request"]["rawBodyGenerator"]
        self.assertEqual(generator["kind"], "jsonWithTrailingAsciiWhitespace")
        prefix = generator["prefix"].encode("utf-8")
        total_bytes = generator["totalBytes"]
        self.assertLessEqual(len(prefix), total_bytes)
        raw_body = prefix + b" " * (total_bytes - len(prefix))
        self.assertEqual(len(raw_body), 65537)
        try:
            parsed_body = json.loads(raw_body)
        except json.JSONDecodeError as error:
            # Payload sai cú pháp sẽ kiểm nhầm nhánh 400; báo FAIL fixture thay vì lỗi runner.
            self.fail(f"Fixture oversize phải là JSON hợp lệ: {error}")
        self.assertEqual(parsed_body, {})

    # Giữ hai header Web ở operation để client sinh từ contract biết phải truyền guard tương ứng.
    def test_logout_declares_both_web_context_and_csrf_parameter_references(self):
        operation = self.contract["paths"]["/api/v1/auth/logout"]["post"]
        parameters = operation["parameters"]
        for reference, header in (("AuthContext", "X-Auth-Context-Id"),
                                  ("CsrfToken", "X-CSRF-Token")):
            with self.subTest(header=header):
                self.assertIn({"$ref": "#/components/parameters/" + reference}, parameters)
                definition = self.contract["components"]["parameters"][reference]
                self.assertEqual(definition["name"], header)
                self.assertEqual(definition["in"], "header")

    # Ngoại lệ absent204 chỉ thuộc logout; mọi operation protected khác vẫn đòi credential.
    def test_anonymous_logout_does_not_make_other_protected_operations_anonymous(self):
        for path, methods in self.contract["paths"].items():
            for operation in methods.values():
                if operation["operationId"] not in ("login", "logout"):
                    with self.subTest(path=path):
                        self.assertEqual(operation["security"],
                                         [{"WebSession": []}, {"AppBearer": []}])


if __name__ == "__main__":
    unittest.main()
