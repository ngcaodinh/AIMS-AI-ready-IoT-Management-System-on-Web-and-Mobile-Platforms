"""Giữ dependency rule Clean Architecture bằng manifest thật, không đọc secret/build/dependency folders."""

import re
import tomllib
import unittest
from pathlib import Path

ROOT=Path(__file__).resolve().parents[3]


class ArchitectureTests(unittest.TestCase):
    """Domain/application chỉ phụ thuộc vào trong; PostgreSQL/crypto là adapter ngoài core."""

    def test_core_dependencies_point_inward(self):
        """Manifest core không thể vô tình thêm SQLx/Tokio/HTTP hoặc import implementation adapter."""
        allowed={"domain":{"chrono","uuid"},"application":{"iot-domain","chrono","uuid"}}
        for crate,dependencies in allowed.items():
            manifest=tomllib.loads((ROOT/f"backend/crates/{crate}/Cargo.toml").read_text(encoding="utf-8"))
            self.assertEqual(set(manifest.get("dependencies",{})),dependencies)
            for path in (ROOT/f"backend/crates/{crate}/src").glob("*.rs"):
                self.assertNotRegex(path.read_text(encoding="utf-8"),r"\b(?:sqlx|tokio|axum|argon2|iot_postgres)::")

    def test_prototype_does_not_survive_as_duplicate_implementation(self):
        """Chỉ còn use case/adapter canonical sau chuyển lớp, không giữ service cũ có SQL ở root."""
        for name in ("auth.rs","database.rs","input.rs","security.rs","workspace.rs"):
            self.assertFalse((ROOT/"backend/src"/name).exists(),name)
