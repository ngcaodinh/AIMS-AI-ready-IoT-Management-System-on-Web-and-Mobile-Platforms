"""Kiểm tra artifact auth P1 bằng thư viện chuẩn; không thay provider/client test G1."""

import json
import unittest
from datetime import datetime
from pathlib import Path
from uuid import UUID


CONTRACT_ROOT = Path(__file__).resolve().parents[1]
OPENAPI_PATH = CONTRACT_ROOT / "openapi" / "auth.v1.json"
FIXTURE_PATH = CONTRACT_ROOT / "fixtures" / "auth" / "scenarios.json"
WORKSPACE_FIXTURE_PATH = CONTRACT_ROOT / "fixtures" / "auth" / "workspace-scenarios.json"


class AuthContractTests(unittest.TestCase):
    """Giữ những bất biến wire quan trọng giữa schema và fixture tổng hợp."""

    @classmethod
    # Đọc một bản contract và fixture dùng chung để các ca không lệch phiên bản.
    def setUpClass(cls):
        cls.contract = json.loads(OPENAPI_PATH.read_text(encoding="utf-8"))
        cls.fixtures = json.loads(FIXTURE_PATH.read_text(encoding="utf-8"))
        cls.workspace_fixtures = json.loads(
            WORKSPACE_FIXTURE_PATH.read_text(encoding="utf-8")
        )
        cls.operations = {
            operation["operationId"]: operation
            for path in cls.contract["paths"].values()
            for operation in path.values()
        }

    # Bắt tham chiếu schema hỏng và fixture lệch version trước khi tích hợp.
    def test_references_and_version(self):
        self.assertEqual(self.contract["openapi"], "3.1.0")
        self.assertEqual(self.contract["info"]["version"], self.fixtures["contractVersion"])
        self.assertEqual(
            self.contract["info"]["version"],
            self.workspace_fixtures["contractVersion"],
        )

        # Duyệt cả response lồng nhau để mọi $ref nội bộ trỏ về cùng artifact.
        def visit(node):
            if isinstance(node, dict):
                for key, value in node.items():
                    if key == "$ref":
                        self.assertTrue(value.startswith("#/components/"))
                        target = self.contract
                        for segment in value[2:].split("/"):
                            self.assertIn(segment, target)
                            target = target[segment]
                    else:
                        visit(value)
            elif isinstance(node, list):
                for item in node:
                    visit(item)

        visit(self.contract)

    # Khóa field input và cấm Web schema chứa bearer token.
    def test_sensitive_request_and_response_boundaries(self):
        schemas = self.contract["components"]["schemas"]
        login = schemas["LoginRequest"]
        self.assertEqual(login["required"], ["email", "password", "clientType"])
        self.assertFalse(login["additionalProperties"])
        self.assertEqual(login["properties"]["clientType"]["enum"], ["WEB", "ANDROID", "IOS"])
        self.assertEqual(login["properties"]["password"]["minLength"], 12)
        self.assertEqual(login["properties"]["password"]["maxLength"], 128)
        self.assertEqual(schemas["WebLoginSuccess"]["not"]["required"], ["token"])
        self.assertIn("token", schemas["AppLoginSuccess"]["required"])
        self.assertFalse(schemas["ChangePasswordRequest"]["additionalProperties"])
        self.assertNotIn("role", schemas["MeProfile"]["properties"])
        self.assertEqual(
            schemas["WorkspaceSummary"]["required"],
            ["id", "name", "status", "role", "revision"],
        )
        self.assertFalse(schemas["CreateWorkspaceRequest"]["additionalProperties"])
        self.assertNotIn("workspaceId", schemas["CreateWorkspaceRequest"]["properties"])
        self.assertNotIn("role", schemas["CreateWorkspaceRequest"]["properties"])
        self.assertIn("membershipAuthzVersion", schemas["WorkspaceDetail"]["required"])
        self.assertIn("authzVersion", schemas["WorkspaceDetail"]["required"])

    # Mỗi fixture phải khớp route/status và giữ lỗi ở envelope chung.
    def test_scenarios_match_documented_operations_and_statuses(self):
        scenario_ids = set()
        field_codes = set(
            self.contract["components"]["schemas"]["FieldError"]["properties"]["code"]["enum"]
        )
        public_error_codes = set(
            self.contract["components"]["schemas"]["ErrorEnvelope"]["properties"]["error"]
            ["properties"]["code"]["enum"]
        )
        for scenario in (
            self.fixtures["scenarios"] + self.workspace_fixtures["scenarios"]
        ):
            with self.subTest(scenario=scenario["id"]):
                self.assertNotIn(scenario["id"], scenario_ids)
                scenario_ids.add(scenario["id"])
                operation = self.operations[scenario["operationId"]]
                response = scenario["response"]
                self.assertIn(str(response["status"]), operation["responses"])
                self.assertEqual(response["headers"]["Cache-Control"], "no-store")

                if response["status"] == 204:
                    self.assertIsNone(response["body"])
                    continue

                if response["status"] >= 400:
                    error = response["body"]["error"]
                    self.assertEqual(
                        set(error), {"code", "message", "details", "correlationId"}
                    )
                    self.assertIn(error["code"], public_error_codes)
                    self.assertTrue(
                        set(error["details"]).issubset({"fieldErrors"})
                    )
                    self.assertNotIn("Set-Cookie", response["headers"])
                    self.assertNotIn("token", response["body"])
                    for field_error in error["details"].get("fieldErrors", []):
                        self.assertIn(field_error["code"], field_codes)
                        self.assertTrue(
                            field_error["path"] == ""
                            or field_error["path"].startswith("/")
                        )
                    continue

                if scenario["operationId"] == "login":
                    body = response["body"]
                    client_type = scenario["request"]["body"]["clientType"]
                    self.assertEqual(body["limited"], body["me"]["mustChangePassword"])
                    UUID(body["me"]["id"])
                    self.assertTrue(body["expiresAt"].endswith("Z"))
                    datetime.fromisoformat(body["expiresAt"].replace("Z", "+00:00"))
                    if client_type == "WEB":
                        self.assertNotIn("token", body)
                        self.assertIn("iot_session=", response["headers"]["Set-Cookie"])
                        self.assertIn("X-CSRF-Token", response["headers"])
                    else:
                        self.assertTrue(body["token"].startswith("<nonfunctional-"))
                        self.assertNotIn("Set-Cookie", response["headers"])
                elif scenario["operationId"] == "getMe":
                    self.assertEqual(response["body"]["displayTimezone"], "UTC")
                    self.assertGreaterEqual(response["body"]["preferencesRevision"], 1)
                    self.assertNotIn("role", response["body"])
                elif scenario["operationId"] == "listAvailableWorkspaces":
                    page = response["body"]
                    self.assertEqual(set(page), {"items", "nextCursor"})
                    for item in page["items"]:
                        self.assertEqual(
                            set(item), {"id", "name", "status", "role", "revision"}
                        )
                        self.assertEqual(item["status"], "ACTIVE")
                        UUID(item["id"])
                elif scenario["operationId"] == "createWorkspace":
                    detail = response["body"]
                    self.assertEqual(detail["status"], "ACTIVE")
                    self.assertEqual(detail["membershipStatus"], "ACTIVE")
                    self.assertEqual(detail["role"], "ADMIN")
                    self.assertEqual(detail["revision"], 1)
                    self.assertEqual(detail["membershipAuthzVersion"], 1)
                elif scenario["operationId"] == "getWorkspaceDetail":
                    detail = response["body"]
                    self.assertEqual(
                        detail["id"], scenario["request"]["path"]["id"]
                    )
                    self.assertEqual(detail["status"], "ACTIVE")
                    self.assertEqual(detail["membershipStatus"], "ACTIVE")
                    self.assertNotIn("devices", detail)

        self.assertGreaterEqual(len(scenario_ids), 20)

    # Giữ cùng hình dạng lỗi công khai cho account lạ, sai mật khẩu và account bị vô hiệu.
    def test_credential_failure_has_one_public_shape(self):
        scenarios = {
            item["id"]: item
            for item in self.fixtures["scenarios"]
            if item["id"]
            in {"CT-AUTH-INVALID", "CT-AUTH-WRONG-PASSWORD", "CT-AUTH-DISABLED"}
        }
        self.assertEqual(len(scenarios), 3)
        public_shapes = {
            (
                item["response"]["status"],
                item["response"]["body"]["error"]["code"],
                item["response"]["body"]["error"]["message"],
                json.dumps(item["response"]["body"]["error"]["details"], sort_keys=True),
            )
            for item in scenarios.values()
        }
        self.assertEqual(len(public_shapes), 1)
        for item in scenarios.values():
            self.assertNotIn("Set-Cookie", item["response"]["headers"])

    # Bắt mọi response khai báo no-store để trung gian không cache thông tin xác thực.
    def test_all_documented_responses_disable_cache(self):
        response_definitions = list(self.contract["components"]["responses"].values())
        for operation in self.operations.values():
            response_definitions.extend(
                response
                for response in operation["responses"].values()
                if "$ref" not in response
            )
        for response in response_definitions:
            with self.subTest(description=response["description"]):
                cache_header = response["headers"]["Cache-Control"]
                self.assertEqual(cache_header["schema"]["const"], "no-store")

    # Giữ default picker chỉ cho quyền vận hành ACTIVE.
    def test_default_workspace_filter_is_explicit(self):
        operation = self.operations["listAvailableWorkspaces"]
        parameters = {item["name"]: item for item in operation["parameters"]}
        self.assertFalse(parameters["includeHistorical"]["schema"]["default"])
        self.assertEqual(parameters["status"]["schema"]["default"], "ACTIVE")
        self.assertEqual(parameters["limit"]["schema"]["default"], 20)
        self.assertEqual(parameters["limit"]["schema"]["maximum"], 100)

    # Bảo đảm fixture duplicate key còn tái hiện được lỗi 400 sau mỗi lần sửa dữ liệu.
    def test_duplicate_key_fixture_is_actually_duplicated(self):
        scenario = next(
            item
            for item in self.fixtures["scenarios"]
            if item["id"] == "CT-AUTH-DUPLICATE-KEY"
        )
        pairs = json.loads(scenario["request"]["rawBody"], object_pairs_hook=list)
        keys = [key for key, _ in pairs]
        self.assertGreater(keys.count("email"), 1)


if __name__ == "__main__":
    unittest.main()
