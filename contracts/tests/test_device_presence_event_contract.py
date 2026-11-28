"""Kiểm hợp đồng tĩnh lát cắt WS event tổng hợp của FEAT-TN-009 PRESENCE-1."""

from datetime import datetime
import unittest
from pathlib import Path
from uuid import UUID

try:
    from test_templates_devices_contract import load_json, matches_schema
except ModuleNotFoundError:
    from contracts.tests.test_templates_devices_contract import load_json, matches_schema


CONTRACTS_ROOT = Path(__file__).resolve().parents[1]
SCHEMA_PATH = CONTRACTS_ROOT / "schemas/device/device-presence-event.v1.json"
FIXTURE_PATH = CONTRACTS_ROOT / "fixtures/messaging/device-presence-changed.v1.json"


def parse_utc_timestamp(value):
    """
    Phân tích chuỗi thời gian UTC RFC3339 kết thúc bằng Z để bảo đảm ngày giờ hợp lệ.

    Input
    Param: value — chuỗi timestamp cần kiểm tra theo định dạng UTC RFC3339.

    Output
    Trả đối tượng datetime có múi giờ UTC để so sánh thứ tự thời gian.
    """
    if not isinstance(value, str) or not value.endswith("Z"):
        raise ValueError(f"Timestamp phải là chuỗi UTC kết thúc bằng Z: {value!r}")
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


class DevicePresenceEventContractTests(unittest.TestCase):
    """Khóa schema WS 067, ánh xạ 009→027, replay, thứ tự và từ chối payload phẳng."""

    @classmethod
    def setUpClass(cls):
        """
        Nạp schema và fixture tổng hợp của lát cắt device.presence.changed một lần cho toàn bộ suite.
        """
        cls.schema_doc = load_json(SCHEMA_PATH)
        cls.defs = cls.schema_doc["$defs"]
        cls.fixture = load_json(FIXTURE_PATH)
        cls.scenarios = {item["id"]: item for item in cls.fixture["scenarios"]}
        cls.rejected = {item["id"]: item for item in cls.fixture["rejectedWsFrames"]}

    def test_schema_and_fixture_versions_and_deferred_scope(self):
        """
        Giữ version đồng bộ giữa schema và fixture, đồng thời không gắn nhãn hoàn tất cho phần còn phụ thuộc.
        """
        self.assertEqual(self.schema_doc["x-contract-version"], self.fixture["contractVersion"])
        self.assertEqual(self.schema_doc["x-schema-version"], self.fixture["schemaVersion"])
        self.assertEqual(self.fixture["fixtureKind"], "synthetic-contract-example")
        self.assertEqual(self.schema_doc["$ref"], "#/$defs/WsDevicePresenceChangedEvent")
        self.assertEqual(self.fixture["scope"]["esp32HardwareStatus"], "DEFERRED / NOT RUN")
        self.assertEqual(len(self.scenarios), len(self.fixture["scenarios"]))
        self.assertEqual(len(self.rejected), len(self.fixture["rejectedWsFrames"]))

    def test_online_to_offline_mapping_across_009_067_and_027(self):
        """
        Kiểm tra ánh xạ 009→067 (resourceId=deviceId, revision=presenceVersion) và 009→027 (connectivityTransitionId, previous/current).
        """
        case = self.scenarios["CT-PRESENCE-001-ONLINE-TO-OFFLINE"]
        domain = case["internalDomainEvent"]
        ws_frame = case["wsFrame"]
        rule_input = case["ruleTriggerInput027"]

        self.assertTrue(matches_schema(domain, self.defs["InternalPresenceChangedDomainEvent"], SCHEMA_PATH))
        self.assertTrue(matches_schema(ws_frame, self.schema_doc, SCHEMA_PATH))
        self.assertTrue(matches_schema(rule_input, self.defs["ConnectivityRuleTriggerInput"], SCHEMA_PATH))

        # Xác nhận đúng chuyển trạng thái ONLINE -> OFFLINE và ngưỡng watchdog > 30 giây.
        self.assertEqual((domain["from"], domain["to"]), ("ONLINE", "OFFLINE"))
        occurred_at = parse_utc_timestamp(domain["occurredAt"])
        last_seen = parse_utc_timestamp(domain["lastSeen"])
        self.assertGreater((occurred_at - last_seen).total_seconds(), 30)

        # Kiểm tra ánh xạ 067 envelope: không dùng device config revision để thay presenceVersion.
        UUID(ws_frame["eventId"])
        self.assertEqual(ws_frame["type"], "device.presence.changed")
        self.assertEqual(ws_frame["workspaceId"], domain["workspaceId"])
        self.assertEqual(ws_frame["resourceId"], domain["deviceId"])
        self.assertEqual(ws_frame["revision"], domain["presenceVersion"])
        self.assertNotEqual(ws_frame["revision"], case["given"]["deviceConfigRevision"])
        self.assertEqual(ws_frame["occurredAt"], domain["occurredAt"])
        self.assertEqual(ws_frame["data"]["transitionId"], domain["transitionId"])
        self.assertEqual(ws_frame["data"]["from"], domain["from"])
        self.assertEqual(ws_frame["data"]["to"], domain["to"])
        self.assertEqual(ws_frame["data"]["reason"], domain["reason"])
        self.assertEqual(ws_frame["data"]["lastSeen"], domain["lastSeen"])
        self.assertEqual(ws_frame["data"]["maintenanceJobId"], domain["maintenanceJobId"])

        # Kiểm tra ánh xạ 027 rule trigger adapter giữ nguyên transitionId và timestamp gốc.
        self.assertEqual(rule_input["workspaceId"], domain["workspaceId"])
        self.assertEqual(rule_input["deviceId"], domain["deviceId"])
        self.assertEqual(rule_input["connectivityTransitionId"], domain["transitionId"])
        self.assertEqual(rule_input["presenceVersion"], domain["presenceVersion"])
        self.assertEqual(rule_input["previous"], domain["from"])
        self.assertEqual(rule_input["current"], domain["to"])
        self.assertEqual(rule_input["reason"], domain["reason"])
        self.assertEqual(rule_input["occurredAt"], domain["occurredAt"])
        self.assertEqual(rule_input["maintenanceJobId"], domain["maintenanceJobId"])

    def test_replay_preserves_ids_timestamps_and_ordering_versions(self):
        """
        Redelivery phải giữ nguyên toàn bộ ID và mốc thời gian gốc; client bỏ bản cũ khi revision đã cao hơn.
        """
        original = self.scenarios["CT-PRESENCE-001-ONLINE-TO-OFFLINE"]
        replay = self.scenarios["CT-PRESENCE-001-REPLAY"]

        self.assertTrue(matches_schema(replay["wsFrame"], self.schema_doc, SCHEMA_PATH))
        self.assertTrue(matches_schema(replay["ruleTriggerInput027"], self.defs["ConnectivityRuleTriggerInput"], SCHEMA_PATH))
        self.assertEqual(replay["internalDomainEvent"], original["internalDomainEvent"])
        self.assertEqual(replay["wsFrame"], original["wsFrame"])
        self.assertEqual(replay["ruleTriggerInput027"], original["ruleTriggerInput027"])

        # Thời điểm gửi lại muộn hơn không được làm thay đổi occurredAt hay lastSeen gốc.
        redelivered_at = parse_utc_timestamp(replay["given"]["redeliveryDispatchedAt"])
        occurred_at = parse_utc_timestamp(replay["wsFrame"]["occurredAt"])
        self.assertGreater(redelivered_at, occurred_at)

        ordering = self.scenarios["CT-PRESENCE-001-ORDERING-STALE-AND-GAP"]
        frames = ordering["given"]["committedSequence"]
        self.assertEqual(len(frames), 2)
        for frame in frames:
            self.assertTrue(matches_schema(frame, self.schema_doc, SCHEMA_PATH))
        self.assertGreater(frames[1]["revision"], frames[0]["revision"])
        self.assertGreater(
            parse_utc_timestamp(frames[1]["occurredAt"]),
            parse_utc_timestamp(frames[0]["occurredAt"]),
        )
        self.assertEqual(ordering["given"]["deliveryArrivalRevisions"], [3, 2])
        self.assertEqual(ordering["expected"]["finalAppliedRevision"], 3)

    def test_workspace_isolation_and_rejected_ws_frames(self):
        """
        Từ chối phát chéo workspace và từ chối payload domain phẳng hoặc frame sai hợp đồng ở ranh giới WebSocket.
        """
        isolation = self.scenarios["CT-PRESENCE-001-AUTHZ-WORKSPACE-ISOLATION"]
        self.assertTrue(matches_schema(isolation["wsFrame"], self.schema_doc, SCHEMA_PATH))
        self.assertNotEqual(
            isolation["given"]["eventWorkspaceId"],
            isolation["given"]["subscriberWorkspaceId"],
        )
        self.assertIs(isolation["expected"]["deliverToConnection"], False)

        # Payload phẳng từ domain 009 phải bị từ chối khi đưa vào validator của WS frame 067.
        flat_case = self.rejected["REJECT-FLAT-DOMAIN-PAYLOAD-AS-WS-FRAME"]
        self.assertEqual(
            flat_case["frame"],
            self.scenarios["CT-PRESENCE-001-ONLINE-TO-OFFLINE"]["internalDomainEvent"],
        )
        self.assertTrue(
            matches_schema(flat_case["frame"], self.defs["InternalPresenceChangedDomainEvent"], SCHEMA_PATH)
        )
        self.assertFalse(matches_schema(flat_case["frame"], self.schema_doc, SCHEMA_PATH))

        for case_id, item in self.rejected.items():
            with self.subTest(rejected_case=case_id):
                self.assertFalse(matches_schema(item["frame"], self.schema_doc, SCHEMA_PATH))


if __name__ == "__main__":
    unittest.main()
