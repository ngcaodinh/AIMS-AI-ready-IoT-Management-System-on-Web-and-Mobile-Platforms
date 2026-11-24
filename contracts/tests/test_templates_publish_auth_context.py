"""Kiểm tĩnh tham số AuthContext trên OpenAPI publish và fixture Web thành công."""

import json
import unittest
from pathlib import Path
from uuid import UUID


CONTRACT_ROOT = Path(__file__).resolve().parents[1]
AUTH_CONTRACT_PATH = CONTRACT_ROOT / "openapi" / "auth.v1.json"
TEMPLATES_CONTRACT_PATH = CONTRACT_ROOT / "openapi" / "templates.v1.json"
TEMPLATES_FIXTURE_PATH = CONTRACT_ROOT / "fixtures" / "templates" / "scenarios.json"


class TemplatePublishAuthContextTests(unittest.TestCase):
    """Bảo đảm route publish khai báo X-Auth-Context-Id dùng chung và fixture Web gửi đúng context."""

    @classmethod
    def setUpClass(cls):
        """Nạp OpenAPI auth, templates và golden fixtures templates một lần cho bộ kiểm tĩnh."""
        cls.auth_contract = json.loads(AUTH_CONTRACT_PATH.read_text(encoding="utf-8"))
        cls.templates_contract = json.loads(TEMPLATES_CONTRACT_PATH.read_text(encoding="utf-8"))
        cls.fixtures = json.loads(TEMPLATES_FIXTURE_PATH.read_text(encoding="utf-8"))
        cls.scenarios = {item["id"]: item for item in cls.fixtures["scenarios"]}

    # Tham số AuthContext phải trỏ đúng tới parameter dùng chung trong auth.v1.json như members.v1.json.
    def test_publish_openapi_references_shared_auth_context_parameter(self):
        publish_op = self.templates_contract["paths"]["/api/v1/templates/{templateId}/publish"]["post"]
        refs = [param.get("$ref") for param in publish_op["parameters"]]
        self.assertIn("./auth.v1.json#/components/parameters/AuthContext", refs)
        shared = self.auth_contract["components"]["parameters"]["AuthContext"]
        self.assertEqual(shared["name"], "X-Auth-Context-Id")
        self.assertEqual(shared["in"], "header")
        self.assertEqual(shared["schema"]["format"], "uuid")

    # Mọi fixture publish Web thành công phải gửi UUID X-Auth-Context-Id khớp phiên và tách biệt với ca 409 mismatch.
    def test_successful_web_publish_fixtures_include_matching_auth_context(self):
        mismatch_ctx = self.scenarios["CT-PUBLISH-AUTH-CONTEXT-MISMATCH-409"]["request"]["headers"][
            "X-Auth-Context-Id"
        ]
        limited_ctx = self.scenarios["CT-PUBLISH-AUTH-LIMITED-SESSION-403"]["request"]["headers"][
            "X-Auth-Context-Id"
        ]
        for scenario_id in ("CT-PUBLISH-001-PUBLISH-V1", "CT-PUBLISH-003-PUBLISH-V2"):
            with self.subTest(scenario=scenario_id):
                scenario = self.scenarios[scenario_id]
                self.assertEqual(scenario["contextRef"], "CTX-WEB-ADMIN")
                self.assertEqual(scenario["expected"]["status"], 200)
                headers = scenario["request"]["headers"]
                self.assertIn("X-Auth-Context-Id", headers)
                ctx_value = headers["X-Auth-Context-Id"]
                UUID(ctx_value)
                self.assertNotEqual(ctx_value, mismatch_ctx)
                self.assertNotEqual(ctx_value, limited_ctx)
