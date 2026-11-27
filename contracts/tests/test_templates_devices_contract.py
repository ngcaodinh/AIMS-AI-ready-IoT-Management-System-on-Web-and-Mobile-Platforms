"""Kiểm wire G1 của FEAT-TN-005–008 bằng các fixture tổng hợp."""

import copy
import json
import re
import unittest
from pathlib import Path


CONTRACTS = Path(__file__).resolve().parents[1]
SCHEMA_PATH = CONTRACTS / "schemas/device/template-device-provisioning.v1.json"
OPENAPI_PATH = CONTRACTS / "openapi/templates-devices.v1.json"
FIXTURE_PATH = CONTRACTS / "fixtures/api/templates-devices.v1.json"
JSON_TYPES = {
    "object": (dict,), "array": (list,), "string": (str,), "integer": (int,),
    "number": (int, float), "boolean": (bool,), "null": (type(None),),
}


def load_json(path):
    """Đọc tài liệu contract UTF-8 từ đường dẫn artifact cố định."""
    return json.loads(path.read_text(encoding="utf-8"))


def resolve_reference(document, reference):
    """Nối reference với đúng file và JSON Pointer, tránh suy kiểu từ tên field."""
    relative, pointer = reference.split("#", 1)
    if relative:
        document = document.parent / relative
    value = load_json(document)
    for key in pointer.split("/")[1:]:
        value = value[key.replace("~1", "/").replace("~0", "~")]
    return document, value


def matches_schema(value, schema, document):
    """Kiểm tập keyword cấu trúc dùng trong contract này để giữ runner stdlib."""
    if "$ref" in schema:
        target, resolved = resolve_reference(document, schema["$ref"])
        if not matches_schema(value, resolved, target):
            return False
    for keyword, expected in (("oneOf", 1), ("anyOf", None)):
        if keyword in schema:
            count = sum(matches_schema(value, option, document) for option in schema[keyword])
            if not count or (expected is not None and count != expected):
                return False
    if "not" in schema and matches_schema(value, schema["not"], document):
        return False
    if "const" in schema and (type(value) is not type(schema["const"]) or value != schema["const"]):
        return False
    if "enum" in schema and value not in schema["enum"]:
        return False
    value_types = schema.get("type")
    if isinstance(value_types, str):
        value_types = [value_types]
    if value_types is not None and not any(type(value) in JSON_TYPES[kind] for kind in value_types):
        return False
    if isinstance(value, dict):
        properties = schema.get("properties", {})
        return (
            len(value) >= schema.get("minProperties", 0)
            and set(schema.get("required", [])) <= value.keys()
            and (schema.get("additionalProperties") is not False or value.keys() <= properties.keys())
            and all(matches_schema(value[key], rule, document) for key, rule in properties.items() if key in value)
        )
    if isinstance(value, list):
        return (
            schema.get("minItems", 0) <= len(value) <= schema.get("maxItems", len(value))
            and (not schema.get("uniqueItems") or len({json.dumps(item, sort_keys=True) for item in value}) == len(value))
            and all(matches_schema(item, schema.get("items", {}), document) for item in value)
        )
    if isinstance(value, str):
        return (
            schema.get("minLength", 0) <= len(value) <= schema.get("maxLength", len(value))
            and ("pattern" not in schema or re.search(schema["pattern"], value) is not None)
        )
    if type(value) in (float, int):
        return schema.get("minimum", value) <= value <= schema.get("maximum", value)
    return True


class TemplatesDevicesContractTests(unittest.TestCase):
    """Khóa mapping hai trục, pin immutable và poll chỉ có metadata."""

    @classmethod
    def setUpClass(cls):
        """Nạp đúng version schema, OpenAPI và fixture của cùng một lát cắt."""
        cls.openapi = load_json(OPENAPI_PATH)
        cls.schema = load_json(SCHEMA_PATH)["$defs"]
        cls.fixture = load_json(FIXTURE_PATH)
        cls.cases = {case["id"]: case for case in cls.fixture["scenarios"]}
        cls.operations = {
            operation["operationId"]: operation
            for methods in cls.openapi["paths"].values()
            for operation in methods.values()
        }

    def test_golden_responses_match_operations_and_error_codes(self):
        """Mỗi HTTP status, lỗi và body trong fixture phải thuộc operation tương ứng."""
        self.assertEqual(self.fixture["contractVersion"], self.openapi["info"]["version"])
        self.assertEqual(self.fixture["fixtureKind"], "synthetic-contract-example")
        self.assertEqual(len(self.cases), len(self.fixture["scenarios"]))
        for case in self.cases.values():
            with self.subTest(case=case["id"]):
                operation = self.operations[case["operationId"]]
                response = case["response"]
                status = str(response["status"])
                declared = operation["responses"][status]
                self.assertEqual(declared["headers"]["Cache-Control"]["schema"]["const"], "no-store")
                self.assertEqual(response["headers"]["Cache-Control"], "no-store")
                self.assertTrue(matches_schema(response["body"], declared["content"]["application/json"]["schema"], OPENAPI_PATH))
                if response["status"] >= 400:
                    self.assertIn(response["body"]["error"]["code"], operation["x-error-codes"][status])

    def test_independent_axes_and_lossless_legacy_decoding(self):
        """Mode chỉ cung cấp một trục; mọi tổ hợp canonical có thể diễn tả độc lập."""
        source = self.cases["CT-TEMPLATE-001"]
        canonical = source["response"]["body"]["streams"]
        self.assertIn(("STATE", "READ"), [(stream["channelKind"], stream["direction"]) for stream in canonical])
        for channel_kind in ("TELEMETRY", "STATE"):
            for direction in ("READ", "WRITE", "READ_WRITE"):
                stream = {"key": "fan", "type": "BOOLEAN", "channelKind": channel_kind, "direction": direction}
                self.assertTrue(matches_schema(stream, self.schema["StreamInput"], SCHEMA_PATH))
                self.assertTrue(matches_schema(stream, self.schema["StreamOutput"], SCHEMA_PATH))
        for case_id, input_axis, output_axis in (
            ("CT-TEMPLATE-LEGACY-DIRECTION", "channelKind", "direction"),
            ("CT-TEMPLATE-LEGACY-KIND", "direction", "channelKind"),
        ):
            case = self.cases[case_id]
            request = case["request"]["body"]
            self.assertTrue(matches_schema(request, self.schema["TemplateCreate"], SCHEMA_PATH))
            index, legacy = next((index, stream) for index, stream in enumerate(request["streams"]) if "mode" in stream)
            self.assertNotIn(output_axis, legacy)
            self.assertEqual(canonical[index][input_axis], legacy[input_axis])
            self.assertEqual(canonical[index][output_axis], legacy["mode"])
            self.assertEqual(case["response"]["body"]["streams"], canonical)
            self.assertFalse(matches_schema(legacy, self.schema["StreamOutput"], SCHEMA_PATH))
        for case_id in (
            "MODE-ONLY-DIRECTION", "MODE-ONLY-KIND", "MODE-DUPLICATE-DIRECTION",
            "MODE-DUPLICATE-KIND", "MODE-MIXED-CANONICAL", "MODE-UNKNOWN", "CANONICAL-ONE-AXIS",
        ):
            case = self.cases[f"CT-TEMPLATE-{case_id}"]
            with self.subTest(case=case_id):
                self.assertFalse(matches_schema(case["request"]["body"], self.schema["TemplateCreate"], SCHEMA_PATH))
                self.assertEqual(case["response"]["status"], 422)
                self.assertIn("no-mutation", case["assertions"])

    def test_safe_value_is_command_only_and_distinct_from_default(self):
        """Provider giữ default riêng và serialize safeValue từ capability đã lưu."""
        body = self.cases["CT-TEMPLATE-001"]["response"]["body"]
        command = body["commands"][0]
        stream = next(stream for stream in body["streams"] if stream["key"] == command["stream"])
        self.assertIs(stream["default"], True)
        self.assertIs(command["safeValue"], False)
        self.assertNotIn("safeValue", stream)
        rejected = self.cases["CT-TEMPLATE-006"]["request"]["body"]
        self.assertFalse(matches_schema(rejected, self.schema["TemplateCreate"], SCHEMA_PATH))

    def test_exact_snapshot_uuid_survives_new_version_and_bundle(self):
        """Số thứ tự, CAS và version khác không thể thay UUID snapshot đã pin."""
        registered = self.cases["CT-DEVICE-REGISTERED"]
        pin = registered["request"]["body"]["templateVersionId"]
        first = self.cases["CT-PUBLISH-001"]["response"]["body"]
        self.assertEqual(first["version"]["id"], pin)
        self.assertEqual(first["revision"], first["version"]["sourceRevision"] + 1)
        self.assertNotIn("revision", first["version"])
        self.assertEqual(registered["response"]["body"]["templateVersionId"], pin)
        self.assertEqual(self.cases["CT-CRED-001"]["response"]["body"]["credential"]["templateVersion"], pin)
        for invalid in (1, "1", None, "latest", "f" * 36):
            altered = dict(registered["request"]["body"], templateVersionId=invalid)
            self.assertFalse(matches_schema(altered, self.schema["DeviceCreate"], SCHEMA_PATH))
        manifest = self.fixture["manifestCompatibility"]
        self.assertEqual(manifest["deviceTemplateVersionId"], pin)
        recovered = self.cases["CT-PUBLISH-RECOVERY"]["response"]["body"]["items"][0]
        self.assertEqual(recovered["id"], manifest["sameFamilyNewVersion"])
        self.assertNotEqual(recovered["id"], pin)
        for case in manifest["cases"]:
            versions = case["supportedTemplateVersions"]
            self.assertTrue(matches_schema(versions, self.schema["SupportedTemplateVersions"], SCHEMA_PATH))
            self.assertEqual(pin in versions, case["compatible"])

    def test_snapshot_provenance_unknown_is_read_only(self):
        """Cho phép đọc snapshot legacy theo UUID, giữ provenance bắt buộc khi publish mới."""
        legacy = self.cases["CT-PUBLISH-LEGACY-PROVENANCE"]["response"]["body"]
        self.assertIsNone(legacy["sourceRevision"])
        self.assertTrue(matches_schema(legacy, self.schema["TemplateVersion"], SCHEMA_PATH))
        self.assertTrue(matches_schema(
            {"items": [legacy], "nextCursor": None}, self.schema["TemplateVersionPage"], SCHEMA_PATH
        ))
        self.assertFalse(matches_schema(
            dict(legacy, sourceRevision=0), self.schema["TemplateVersion"], SCHEMA_PATH
        ))
        publish = copy.deepcopy(self.cases["CT-PUBLISH-001"]["response"]["body"])
        self.assertTrue(matches_schema(publish, self.schema["TemplatePublished"], SCHEMA_PATH))
        publish["version"]["sourceRevision"] = None
        self.assertFalse(matches_schema(publish, self.schema["TemplatePublished"], SCHEMA_PATH))

    def test_mqtt_acl_profile_uses_only_exact_device_topics(self):
        """Khóa sáu quyền topic theo UUID registry, QoS 1 và retain false trong fixture."""
        profile = self.fixture["mqttAclProfile"]
        device_id = profile["deviceId"]
        self.assertTrue(matches_schema(device_id, self.schema["Uuid"], SCHEMA_PATH))
        self.assertNotEqual(profile["otherDeviceId"], device_id)
        self.assertEqual(profile["clientId"], device_id)
        prefix = f"iot/v1/devices/{device_id}"
        self.assertEqual(profile["publish"], [
            f"{prefix}/{topic}" for topic in ("telemetry", "hello", "heartbeat", "results")
        ])
        self.assertEqual(profile["subscribeAndReceive"], [
            f"{prefix}/{topic}" for topic in ("commands", "receipts")
        ])
        self.assertEqual(profile["qos"], 1)
        self.assertIs(profile["retain"], False)

    def test_poll_is_explicit_and_contains_no_secret_fields(self):
        """GET chỉ nhận STATUS với đúng discriminator và từ chối field bí mật mọi variant."""
        poll = self.operations["getProvisioningOperation"]
        schema = poll["responses"]["200"]["content"]["application/json"]["schema"]
        discriminator = self.openapi["components"]["schemas"]["ProvisioningOperation"]["discriminator"]
        self.assertEqual(discriminator["propertyName"], "kind")
        kinds, modes = set(), set()
        for case in self.cases.values():
            if case["operationId"] != "getProvisioningOperation" or case["response"]["status"] != 200:
                continue
            body = case["response"]["body"]
            self.assertEqual(set(body), {"kind", "operation"})
            self.assertEqual(body["kind"], "STATUS")
            kinds.add(body["operation"]["kind"])
            if body["operation"]["kind"] == "CREDENTIAL":
                modes.add(body["operation"]["deliveryMode"])
            for secret_field in ("password", "credential", "escrowCiphertext", "fingerprint", "brokerAdmin"):
                altered = copy.deepcopy(body)
                altered["operation"][secret_field] = "invalid-synthetic-value"
                self.assertFalse(matches_schema(altered, schema, OPENAPI_PATH))
        self.assertEqual(kinds, {"CREDENTIAL", "DEVICE_LIFECYCLE", "ENROLLMENT_CLEANUP"})
        self.assertEqual(set(discriminator["mapping"]), kinds)
        self.assertEqual(modes, {"USB_ONE_TIME", "ENROLLMENT_BLE"})
        for case in self.fixture["rejectedResponses"]:
            with self.subTest(case=case["id"]):
                self.assertFalse(matches_schema(case["body"], schema, OPENAPI_PATH))


if __name__ == "__main__":
    unittest.main()
