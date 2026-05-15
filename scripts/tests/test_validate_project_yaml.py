"""
Tests for validate-project-yaml.py

Tests the simple schema-only validator.
"""

from __future__ import annotations

import importlib.util
import json
from pathlib import Path

import pytest

SCRIPTS_DIR = Path(__file__).parent.parent
_MODULE_PATH = SCRIPTS_DIR / "validate-project-yaml.py"
_spec = importlib.util.spec_from_file_location("validate_project_yaml", _MODULE_PATH)
vpy = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(vpy)


@pytest.fixture
def schema_path() -> Path:
    return Path.home() / ".claude" / "schemas" / "project.schema.json"


@pytest.fixture
def valid_yaml(tmp_path: Path) -> Path:
    p = tmp_path / "PROJECT.yaml"
    p.write_text("name: test\ntesting:\n  command: make test\n  min_coverage: 80\nsecrets:\n  backend: aws\n")
    return p


@pytest.fixture
def invalid_yaml(tmp_path: Path) -> Path:
    p = tmp_path / "PROJECT.yaml"
    p.write_text("name: test\n")
    return p


class TestValidateProjectYaml:
    def test_valid_returns_true(self, valid_yaml, schema_path):
        if not schema_path.exists():
            pytest.skip("Schema not found")
        is_valid, paths = vpy.validate_project_yaml(str(valid_yaml), str(schema_path))
        assert is_valid is True
        assert paths == []

    def test_invalid_returns_false(self, invalid_yaml, schema_path):
        if not schema_path.exists():
            pytest.skip("Schema not found")
        is_valid, paths = vpy.validate_project_yaml(str(invalid_yaml), str(schema_path))
        assert is_valid is False

    def test_invalid_paths_are_sorted(self, invalid_yaml, schema_path):
        if not schema_path.exists():
            pytest.skip("Schema not found")
        _, paths = vpy.validate_project_yaml(str(invalid_yaml), str(schema_path))
        assert paths == sorted(paths)

    def test_paths_start_with_dot(self, invalid_yaml, schema_path):
        if not schema_path.exists():
            pytest.skip("Schema not found")
        _, paths = vpy.validate_project_yaml(str(invalid_yaml), str(schema_path))
        for p in paths:
            assert p.startswith("."), f"Path should start with dot: {p}"
