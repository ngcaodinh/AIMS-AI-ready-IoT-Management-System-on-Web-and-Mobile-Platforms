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
LOGIN_VALIDATION_FIXTURE_PATH = (
    CONTRACT_ROOT / "fixtures" / "auth" / "login-validation-scenarios.json"
)


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
        cls.login_validation_fixtures = json.loads(
            LOGIN_VALIDATION_FIXTURE_PATH.read_text(encoding="utf-8")
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
        self.assertEqual(
            self.contract["info"]["version"],
            self.login_validation_fixtures["contractVersion"],
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
        self.assertEqual(login["properties"]["password"]["minLength"], 9)
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
            + self.login_validation_fixtures["scenarios"]
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
                        UUID(response["headers"]["X-Auth-Context-Id"])
                    else:
                        self.assertTrue(body["token"].startswith("<nonfunctional-"))
                        self.assertNotIn("Set-Cookie", response["headers"])
                        self.assertNotIn("X-Auth-Context-Id", response["headers"])
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
        # Header tham chiếu được kiểm riêng; test này chỉ đọc query khai trực tiếp.
        parameters = {
            item["name"]: item for item in operation["parameters"] if "name" in item
        }
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

    # Phân biệt discovery limited với đối soát context bắt buộc sau login Web.
    def test_web_limited_confirmation_has_matching_and_mismatch_fixtures(self):
        scenarios = {item["id"]: item for item in self.fixtures["scenarios"]}
        login = scenarios["CT-AUTH-WEB-LIMITED"]["response"]
        context_id = login["headers"]["X-Auth-Context-Id"]
        discovery = scenarios["CT-AUTH-ME-LIMITED"]
        self.assertNotIn("X-Auth-Context-Id", discovery["request"].get("headers", {}))
        confirmation = scenarios["CT-AUTH-ME-LIMITED-CONFIRMATION"]
        self.assertEqual(confirmation["operationId"], "getMe")
        self.assertEqual(confirmation["request"]["headers"]["X-Auth-Context-Id"], context_id)
        self.assertEqual(confirmation["response"]["status"], 403)
        self.assertEqual(
            confirmation["response"]["body"]["error"]["code"],
            "PASSWORD_CHANGE_REQUIRED",
        )
        self.assertEqual(confirmation["response"]["headers"]["X-Auth-Context-Id"], context_id)
        self.assertNotIn("me", confirmation["response"]["body"])
        self.assertNotIn("memberships", confirmation["response"]["body"])
        self.assertIn("no-profile", confirmation["assertions"])
        self.assertIn("no-membership-data", confirmation["assertions"])
        self.assertIn("no-workspace-request", confirmation["assertions"])
        mismatch = scenarios["CT-AUTH-ME-LIMITED-CONTEXT-MISMATCH"]
        self.assertEqual(mismatch["operationId"], "getMe")
        self.assertNotEqual(mismatch["request"]["headers"]["X-Auth-Context-Id"], context_id)
        self.assertEqual(mismatch["response"]["status"], 409)
        self.assertEqual(mismatch["response"]["body"]["error"]["code"], "AUTH_CONTEXT_MISMATCH")
        self.assertIn("lock-protected-ui", mismatch["assertions"])

    # Khóa header đối soát phiên Web trên mọi route bảo vệ trước khi có provider.
    def test_web_auth_context_fence_is_declared_for_protected_routes(self):
        self.assertEqual(self.contract["info"]["version"], "0.2.1")
        parameters = self.contract["components"]["parameters"]
        self.assertEqual(parameters["AuthContext"]["name"], "X-Auth-Context-Id")
        self.assertIn(
            "AUTH_CONTEXT_MISMATCH",
            self.contract["components"]["schemas"]["ErrorEnvelope"]["properties"]
            ["error"]["properties"]["code"]["enum"],
        )
        self.assertIn(
            "X-Auth-Context-Id", self.operations["login"]["responses"]["200"]["headers"]
        )
        self.assertIn(
            "X-Auth-Context-Id", self.operations["getMe"]["responses"]["200"]["headers"]
        )
        self.assertIn(
            "X-Auth-Context-Id",
            self.contract["components"]["responses"]["PasswordChangeRequired"]["headers"],
        )
        for operation_id in (
            "getMe", "listAvailableWorkspaces", "getWorkspaceDetail",
            "createWorkspace", "logout", "changeOwnPassword",
        ):
            with self.subTest(operation=operation_id):
                operation = self.operations[operation_id]
                self.assertIn(
                    {"$ref": "#/components/parameters/AuthContext"},
                    operation["parameters"],
                )
                self.assertIn("409", operation["responses"])

    # Resolver logout nhận cả phiên đã thu hồi/hết hạn, không nới guard của route bảo vệ.
    def test_logout_resolver_and_anonymous_security_match_the_policy(self):
        operation = self.operations["logout"]
        self.assertIn({}, operation["security"])
        policy = operation["x-logout-policy"]
        self.assertEqual(policy["resolver"], "session-digest-including-inactive")
        self.assertEqual(policy["scope"], "current-session-only")
        self.assertEqual(policy["credentialOutcomes"], {
            "active": 204, "limited": 204, "revoked": 204, "expired": 204,
            "absent": 204, "unknown": 401, "malformed": 401,
            "storeUnavailable": 503,
        })
        self.assertNotIn({}, self.operations["getMe"]["security"])
        self.assertNotIn("requestBody", operation)
        for status in (204, 400, 401, 403, 409, 413, 415, 422, 429, 503):
            self.assertIn(str(status), operation["responses"])

    # Cookie clear chỉ áp dụng thành công Web đã nhận diện, không chạm cookie B khi lỗi.
    def test_logout_cookie_clear_has_exact_scope_and_no_success_body(self):
        operation = self.operations["logout"]
        response = operation["responses"]["204"]
        self.assertNotIn("content", response)
        self.assertEqual(response["headers"]["Set-Cookie"]["schema"]["const"],
                         "iot_session=; Path=/api/v1; Secure; HttpOnly; SameSite=Lax; Max-Age=0")
        cookie = operation["x-logout-policy"]["cookie"]
        self.assertEqual(cookie["clearOn"], "recognized-web-session-success")
        self.assertFalse(cookie["clearOnError"])
        self.assertFalse(cookie["clearWhenAbsent"])

    # Khóa CSRF/context cho cả cookie inactive và phân biệt body rỗng với JSON null/{}.
    def test_logout_guards_and_body_boundaries_are_explicit(self):
        policy = self.operations["logout"]["x-logout-policy"]
        self.assertEqual(policy["webGuards"], {
            "recognizedCookie": ["authContext", "sameOrigin", "csrfBoundToSession"],
            "includesInactive": True, "contextMismatch": 409, "csrfInvalid": 403,
        })
        self.assertEqual(policy["body"], {
            "maxBytes": 65536, "emptyAllowed": True, "jsonValue": 422,
            "malformedJson": 400, "unsupportedMediaType": 415, "oversize": 413,
        })
        self.assertEqual(policy["idempotency"], {
            "repeatStatus": 204, "preserveRevokedAt": True,
            "audit": "first-transition-only",
        })

    # Fixture phải chứng minh cookie khác context không trả dữ liệu hoặc revoke sai phiên.
    def test_web_auth_context_mismatch_fixtures_are_denials(self):
        scenarios = {
            item["id"]: item
            for item in self.fixtures["scenarios"] + self.workspace_fixtures["scenarios"]
        }
        # Discovery chỉ được đọc khi UI khóa; một response 200 không tự xác nhận intent.
        discovery = scenarios["CT-AUTH-ME-DISCOVERY"]
        self.assertNotIn("X-Auth-Context-Id", discovery["request"].get("headers", {}))
        self.assertIn("explicit-resume-confirmation", discovery["assertions"])
        self.assertIn("no-workspace-before-confirmation", discovery["assertions"])
        # Các fixture Web đã có context phải gửi header trước guard nghiệp vụ.
        for scenario in scenarios.values():
            auth_state = scenario["request"].get("authState", "")
            if auth_state.startswith("valid-web") and scenario["id"] not in (
                "CT-AUTH-ME-LIMITED", "CT-BOOTSTRAP-CONTEXT-MISSING"
            ):
                with self.subTest(web_context=scenario["id"]):
                    self.assertIn(
                        "X-Auth-Context-Id", scenario["request"].get("headers", {})
                    )
        expected = {
            "CT-AUTH-ME-CONTEXT-MISMATCH": "getMe",
            "CT-AUTH-ME-LIMITED-CONTEXT-MISMATCH": "getMe",
            "CT-BOOTSTRAP-CONTEXT-MISMATCH": "listAvailableWorkspaces",
            "CT-BOOTSTRAP-CONTEXT-MISSING": "listAvailableWorkspaces",
            "CT-AUTH-LOGOUT-CONTEXT-MISMATCH": "logout",
        }
        for scenario_id, operation_id in expected.items():
            with self.subTest(scenario=scenario_id):
                scenario = scenarios[scenario_id]
                self.assertEqual(scenario["operationId"], operation_id)
                self.assertIn("authState", scenario["request"])
                if scenario_id == "CT-BOOTSTRAP-CONTEXT-MISSING":
                    self.assertNotIn(
                        "X-Auth-Context-Id", scenario["request"].get("headers", {})
                    )
                else:
                    self.assertIn(
                        "X-Auth-Context-Id", scenario["request"]["headers"]
                    )
                response = scenario["response"]
                self.assertEqual(response["status"], 409)
                self.assertEqual(response["body"]["error"]["code"], "AUTH_CONTEXT_MISMATCH")
                self.assertEqual(response["headers"]["Cache-Control"], "no-store")
                self.assertNotIn("Set-Cookie", response["headers"])
                self.assertNotIn("items", response["body"])
                self.assertNotIn("me", response["body"])
                self.assertIn("no-side-effect", scenario["assertions"])


if __name__ == "__main__":
    unittest.main()
