"""Kiểm tĩnh tương thích snapshot lịch sử pre-0022 và ràng buộc publish mới trên schema template."""

import json
import unittest
from pathlib import Path


CONTRACT_ROOT = Path(__file__).resolve().parents[1]
SCHEMA_PATH = CONTRACT_ROOT / "schemas" / "templates.v1.schema.json"
FIXTURE_PATH = CONTRACT_ROOT / "fixtures" / "templates" / "scenarios.json"


class TemplateLegacyProvenanceTests(unittest.TestCase):
    """Giữ ranh giới đọc snapshot pre-0022 (`sourceRevision: null`) tách biệt với schema publish mới."""

    @classmethod
    def setUpClass(cls):
        """Nạp JSON Schema và bộ fixture template một lần để kiểm cấu trúc và dữ liệu mẫu."""
        cls.schema = json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))
        cls.defs = cls.schema["$defs"]
        cls.fixtures = json.loads(FIXTURE_PATH.read_text(encoding="utf-8"))
        cls.scenarios = {item["id"]: item for item in cls.fixtures["scenarios"]}

    # Chỉ schema NUMBER nghiêm ngặt mới bắt buộc cả min/max cho WRITE/READ_WRITE; legacy dùng chung NumberStreamBase.
    def test_number_stream_base_extracted_for_legacy_reads(self):
        base = self.defs["NumberStreamBase"]
        strict = self.defs["NumberStream"]
        legacy_union = [item["$ref"] for item in self.defs["LegacyTemplateStream"]["oneOf"]]
        strict_union = [item["$ref"] for item in self.defs["TemplateStream"]["oneOf"]]

        self.assertEqual(base["required"], ["key", "type", "channelKind", "direction"])
        self.assertFalse(base["additionalProperties"])
        self.assertNotIn("allOf", base)
        self.assertIn({"$ref": "#/$defs/NumberStreamBase"}, strict["allOf"])
        self.assertIn("#/$defs/NumberStreamBase", legacy_union)
        self.assertIn("#/$defs/LegacyEnumStream", legacy_union)
        self.assertIn("#/$defs/NumberStream", strict_union)
        self.assertIn("#/$defs/EnumStream", strict_union)

        version_snap = self.defs["TemplateVersionSnapshot"]
        publish_snap = self.defs["PublishedTemplateVersionSnapshot"]
        self.assertEqual(
            version_snap["properties"]["streams"]["items"]["$ref"],
            "#/$defs/LegacyTemplateStream",
        )
        self.assertEqual(
            version_snap["allOf"][0]["then"]["properties"]["streams"]["items"]["$ref"],
            "#/$defs/TemplateStream",
        )
        self.assertEqual(
            publish_snap["properties"]["streams"]["items"]["$ref"],
            "#/$defs/TemplateStream",
        )
        self.assertEqual(
            publish_snap["properties"]["sourceRevision"]["$ref"],
            "#/$defs/PublishedSourceRevision",
        )

    # Fixture đọc snapshot pre-0022 phải phủ ENUM số+chuỗi và NUMBER ghi được không đủ 2 biên, giữ sourceRevision null.
    def test_legacy_unbounded_number_and_mixed_enum_fixtures_preserve_provenance_split(self):
        unbounded = self.scenarios["CT-PUBLISH-READ-LEGACY-WRITABLE-NUMBER-UNBOUNDED"]["expected"][
            "body"
        ]
        self.assertIsNone(unbounded["sourceRevision"])
        no_bound, one_bound = unbounded["streams"]
        self.assertEqual(no_bound["direction"], "WRITE")
        self.assertNotIn("min", no_bound)
        self.assertNotIn("max", no_bound)
        self.assertEqual(one_bound["direction"], "READ_WRITE")
        self.assertIn("min", one_bound)
        self.assertNotIn("max", one_bound)

        mixed_enum = self.scenarios["CT-PUBLISH-READ-LEGACY-NUMERIC-ENUM"]["expected"]["body"]
        self.assertIsNone(mixed_enum["sourceRevision"])
        enum_values = mixed_enum["streams"][0]["enumValues"]
        self.assertEqual(enum_values, [1, "1"])
        self.assertIs(type(enum_values[0]), int)
        self.assertIs(type(enum_values[1]), str)

        for publish_id in ("CT-PUBLISH-001-PUBLISH-V1", "CT-PUBLISH-003-PUBLISH-V2"):
            with self.subTest(scenario=publish_id):
                published = self.scenarios[publish_id]["expected"]["body"]["version"]
                self.assertIs(type(published["sourceRevision"]), int)
                self.assertGreaterEqual(published["sourceRevision"], 1)
