"""Kiểm contract ticket realtime và transport WebSocket đã chốt cho FEAT-TN-002."""

import json
import re
import unittest
from pathlib import Path


CONTRACT_ROOT = Path(__file__).resolve().parents[1]


class RealtimeTicketContractTests(unittest.TestCase):
    """Giữ wire ticket nhất quán và phân biệt fixture yêu cầu với runtime evidence."""

    @classmethod
    def setUpClass(cls):
        """Nạp OpenAPI và fixture tổng hợp dùng chung cho mọi kiểm tra contract."""
        cls.contract = json.loads(
            (CONTRACT_ROOT / "openapi/auth.v1.json").read_text(encoding="utf-8")
        )
        cls.fixture = json.loads(
            (CONTRACT_ROOT / "fixtures/auth/realtime-ticket-scenarios.json").read_text(
                encoding="utf-8"
            )
        )
        cls.scenarios = {item["id"]: item for item in cls.fixture["scenarios"]}
        cls.operation = cls.contract["paths"]["/api/v1/realtime/tickets"]["post"]
        cls.handshake = cls.contract["x-websocket-handshake"]

    def test_http_ticket_wire_is_session_and_workspace_scoped(self):
        """Ticket chỉ cấp qua POST bodyless hiện hành và response phải no-store."""
        self.assertEqual(self.fixture["contractVersion"], self.contract["info"]["version"])
        self.assertEqual(self.fixture["fixtureKind"], "synthetic-contract-example")
        self.assertEqual(self.operation["operationId"], "createRealtimeTicket")
        self.assertNotIn("requestBody", self.operation)
        self.assertIn(
            {"$ref": "#/components/parameters/WorkspaceId"},
            self.operation["parameters"],
        )
        response = self.operation["responses"]["201"]
        self.assertEqual(
            response["headers"]["Cache-Control"]["schema"]["const"], "no-store"
        )
        schema = response["content"]["application/json"]["schema"]
        self.assertEqual(schema["$ref"], "#/components/schemas/RealtimeTicketResponse")
        ticket_schema = self.contract["components"]["schemas"]["RealtimeTicketResponse"]
        self.assertEqual(ticket_schema["required"], ["ticket", "expiresAt"])
        self.assertFalse(ticket_schema["additionalProperties"])
        self.assertEqual(
            ticket_schema["properties"]["ticket"]["pattern"], "^[0-9a-f]{64}$"
        )

    def test_websocket_handshake_has_no_prevalidation_event_and_bounded_wait(self):
        """Ticket chỉ được nhận ở frame text đầu; timeout và close không lộ trạng thái."""
        self.assertEqual(self.handshake["path"], "/api/v1/realtime")
        self.assertEqual(self.handshake["ticketFrame"], {
            "direction": "client-to-server",
            "position": 0,
            "messageType": "text",
            "schema": {"type": "string", "pattern": "^[0-9a-f]{64}$"},
        })
        self.assertEqual(self.handshake["serverFramesBeforeValidation"], [])
        self.assertEqual(self.handshake["validationTimeoutSeconds"], 5)
        self.assertEqual(self.handshake["invalidTicketClose"], {
            "code": 1008,
            "reason": "Authentication required.",
        })
        self.assertEqual(self.handshake["validatedAck"], "AUTHENTICATED")
        self.assertFalse(self.handshake["ticketInUrl"])
        self.assertFalse(self.handshake["ticketInLogs"])

    def test_synthetic_cases_match_wire_and_preserve_security_assertions(self):
        """Kiểm fixture thành công, thiếu scope, timeout, replay và revoke theo wire contract."""
        self.assertEqual(len(self.scenarios), len(self.fixture["scenarios"]))
        expected_ids = {
            "RT-TICKET-WEB-201",
            "RT-TICKET-SCOPE-MISSING",
            "RT-WS-FIRST-FRAME-VALID",
            "RT-WS-FIRST-FRAME-TIMEOUT",
            "RT-WS-TICKET-REPLAY",
            "RT-WS-SESSION-REVOKED",
        }
        self.assertEqual(set(self.scenarios), expected_ids)
        for scenario in self.fixture["scenarios"]:
            with self.subTest(scenario=scenario["id"]):
                if scenario.get("operationId"):
                    response = scenario["response"]
                    self.assertIn(str(response["status"]), self.operation["responses"])
                    if response["status"] == 201:
                        ticket = response["body"]["ticket"]
                        self.assertRegex(ticket, re.compile(r"^[0-9a-f]{64}$"))
                        self.assertEqual(response["headers"]["Cache-Control"], "no-store")
                    else:
                        self.assertEqual(response["body"]["error"]["code"], "VALIDATION_ERROR")
                        self.assertEqual(scenario["expectedEffects"]["ticketRows"], 0)
                else:
                    self.assertEqual(scenario["boundary"], "websocket")
                    if scenario["id"] != "RT-WS-SESSION-REVOKED":
                        self.assertIn("no-event-before-validation", scenario["assertions"])
                        self.assertEqual(
                            scenario["expected"].get("serverFramesBeforeValidation", []), []
                        )
        self.assertIn("only-bound-session-closed", self.scenarios["RT-WS-SESSION-REVOKED"]["assertions"])


if __name__ == "__main__":
    unittest.main()
