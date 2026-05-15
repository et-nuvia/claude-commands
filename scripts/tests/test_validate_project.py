"""
Tests for validate-project.py

Tests the two-layer validation: schema validation and runtime checks.
Uses temporary files and directories — no real PROJECT.yaml or schema needed.
"""

from __future__ import annotations

import importlib.util
import json
import sys
from pathlib import Path
from unittest.mock import patch

import pytest

# Load module from hyphenated filename
SCRIPTS_DIR = Path(__file__).parent.parent
_MODULE_PATH = SCRIPTS_DIR / "validate-project.py"
_spec = importlib.util.spec_from_file_location("validate_project", _MODULE_PATH)
vp = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(vp)


# ── Fixtures ──────────────────────────────────────────────────────────────────

@pytest.fixture
def schema_path() -> Path:
    """Return path to the real project schema."""
    return Path.home() / ".claude" / "schemas" / "project.schema.json"


@pytest.fixture
def minimal_valid_yaml(tmp_path: Path) -> Path:
    """Create a minimal valid PROJECT.yaml."""
    content = """\
name: test-project
testing:
  command: make test
  min_coverage: 80
secrets:
  backend: aws
"""
    p = tmp_path / "PROJECT.yaml"
    p.write_text(content)
    return p


@pytest.fixture
def invalid_yaml(tmp_path: Path) -> Path:
    """Create an invalid PROJECT.yaml (missing required fields)."""
    content = "name: test-project\n"
    p = tmp_path / "PROJECT.yaml"
    p.write_text(content)
    return p


@pytest.fixture
def bad_syntax_yaml(tmp_path: Path) -> Path:
    """Create a YAML file with syntax errors."""
    p = tmp_path / "PROJECT.yaml"
    p.write_text("name: [\ninvalid yaml {{\n")
    return p


# ── Tests: make_issue ────────────────────────────────────────────────────────

class TestMakeIssue:
    def test_basic_issue(self):
        issue = vp.make_issue("error", "TEST_CODE", "some.path", "test message")
        assert issue["severity"] == "error"
        assert issue["code"] == "TEST_CODE"
        assert issue["path"] == "some.path"
        assert issue["message"] == "test message"
        assert "context" not in issue
        assert "fix" not in issue

    def test_issue_with_context_and_fix(self):
        issue = vp.make_issue(
            "warning", "WARN", "p", "msg",
            context={"key": "val"}, fix="do this",
        )
        assert issue["context"] == {"key": "val"}
        assert issue["fix"] == "do this"


# ── Tests: path_str ──────────────────────────────────────────────────────────

class TestPathStr:
    def test_empty_path(self):
        assert vp.path_str([]) == "(root)"

    def test_simple_path(self):
        assert vp.path_str(["testing", "command"]) == "testing.command"

    def test_path_with_index(self):
        assert vp.path_str(["databases", 0, "name"]) == "databases[0].name"

    def test_index_at_start(self):
        assert vp.path_str([0, "name"]) == "[0].name"


# ── Tests: get_nested ────────────────────────────────────────────────────────

class TestGetNested:
    def test_simple_key(self):
        assert vp.get_nested({"a": 1}, "a") == 1

    def test_nested_key(self):
        assert vp.get_nested({"a": {"b": {"c": 3}}}, "a.b.c") == 3

    def test_missing_key(self):
        assert vp.get_nested({"a": 1}, "b") is None

    def test_missing_key_with_default(self):
        assert vp.get_nested({"a": 1}, "b", "default") == "default"

    def test_deep_missing(self):
        assert vp.get_nested({"a": {"b": 1}}, "a.c.d") is None


# ── Tests: find_empty_strings ────────────────────────────────────────────────

class TestFindEmptyStrings:
    def test_no_empty_strings(self):
        assert vp.find_empty_strings({"a": "hello", "b": 1}) == []

    def test_top_level_empty(self):
        assert vp.find_empty_strings({"a": "", "b": "ok"}) == ["a"]

    def test_nested_empty(self):
        result = vp.find_empty_strings({"a": {"b": ""}})
        assert "a.b" in result

    def test_list_empty(self):
        result = vp.find_empty_strings({"items": ["", "ok"]})
        assert "items[0]" in result

    def test_deeply_nested(self):
        result = vp.find_empty_strings({"a": {"b": {"c": ""}}})
        assert "a.b.c" in result


# ── Tests: validate (schema layer) ──────────────────────────────────────────

class TestValidateSchema:
    def test_valid_minimal(self, minimal_valid_yaml, schema_path):
        if not schema_path.exists():
            pytest.skip("Schema file not found")
        result = vp.validate(str(minimal_valid_yaml), schema_only=True)
        assert result["valid"] is True
        assert result["summary"]["errors"] == 0

    def test_invalid_missing_required(self, invalid_yaml, schema_path):
        if not schema_path.exists():
            pytest.skip("Schema file not found")
        result = vp.validate(str(invalid_yaml), schema_only=True)
        assert result["valid"] is False
        assert result["summary"]["errors"] > 0

    def test_file_not_found(self, tmp_path):
        result = vp.validate(str(tmp_path / "nonexistent.yaml"))
        assert result["valid"] is False
        assert any(i["code"] == "YAML_PARSE_ERROR" for i in result["issues"])

    def test_bad_syntax(self, bad_syntax_yaml):
        result = vp.validate(str(bad_syntax_yaml))
        assert result["valid"] is False
        assert any(i["code"] == "YAML_PARSE_ERROR" for i in result["issues"])

    def test_non_dict_yaml(self, tmp_path):
        p = tmp_path / "PROJECT.yaml"
        p.write_text("- just\n- a\n- list\n")
        result = vp.validate(str(p))
        assert result["valid"] is False
        assert any("mapping" in i["message"] for i in result["issues"])

    def test_schema_not_found(self, minimal_valid_yaml):
        with patch.object(vp, "SCHEMA_PATH", Path("/nonexistent/schema.json")):
            result = vp.validate(str(minimal_valid_yaml))
        assert result["valid"] is False
        assert any(i["code"] == "SCHEMA_NOT_FOUND" for i in result["issues"])

    def test_result_structure(self, minimal_valid_yaml, schema_path):
        if not schema_path.exists():
            pytest.skip("Schema file not found")
        result = vp.validate(str(minimal_valid_yaml), schema_only=True)
        assert "valid" in result
        assert "file" in result
        assert "schema_version" in result
        assert "summary" in result
        assert "issues" in result
        assert "errors" in result["summary"]
        assert "warnings" in result["summary"]
        assert "info" in result["summary"]


# ── Tests: runtime_checks ───────────────────────────────────────────────────

class TestRuntimeChecks:
    def test_empty_string_detection(self):
        config = {"name": "test", "description": ""}
        issues = vp.runtime_checks(config)
        paths = [i["path"] for i in issues]
        assert "description" in paths

    def test_compose_file_missing(self, tmp_path):
        config = {"docker": {"compose_file": str(tmp_path / "nonexistent.yml")}}
        issues = vp.runtime_checks(config)
        codes = [i["code"] for i in issues]
        assert "FILE_NOT_FOUND" in codes

    def test_version_file_missing(self, tmp_path):
        config = {"version_file": str(tmp_path / "nonexistent")}
        issues = vp.runtime_checks(config)
        assert any(i["path"] == "version_file" for i in issues)

    def test_asana_token_missing(self):
        config = {"task_management": {"backend": "asana"}}
        with patch("pathlib.Path.exists", return_value=False):
            issues = vp.runtime_checks(config)
        assert any(i["code"] == "TOKEN_NOT_FOUND" for i in issues)

    def test_same_db_users_error(self):
        config = {
            "databases": [{
                "name": "app",
                "type": "postgresql",
                "users": {
                    "migration": {"secret_keys": {"username": "DB_USER"}},
                    "app": {"secret_keys": {"username": "DB_USER"}},
                },
            }]
        }
        issues = vp.runtime_checks(config)
        assert any(i["code"] == "SAME_DB_USERS" for i in issues)

    def test_different_db_users_ok(self):
        config = {
            "databases": [{
                "name": "app",
                "type": "postgresql",
                "users": {
                    "migration": {"secret_keys": {"username": "DB_MIG_USER"}},
                    "app": {"secret_keys": {"username": "DB_APP_USER"}},
                },
            }]
        }
        issues = vp.runtime_checks(config)
        assert not any(i["code"] == "SAME_DB_USERS" for i in issues)

    def test_sqlite_skips_user_check(self):
        config = {
            "databases": [{
                "name": "local",
                "type": "sqlite",
            }]
        }
        issues = vp.runtime_checks(config)
        assert not any("SINGLE_DB_USER" in i.get("code", "") for i in issues)


# ── Tests: format_human ─────────────────────────────────────────────────────

class TestFormatHuman:
    def test_valid_result(self):
        result = {
            "valid": True,
            "file": "PROJECT.yaml",
            "schema_version": "1.0.0",
            "summary": {"errors": 0, "warnings": 0, "info": 0},
            "issues": [],
        }
        output = vp.format_human(result)
        assert "Valid" in output

    def test_invalid_result(self):
        result = {
            "valid": False,
            "file": "PROJECT.yaml",
            "schema_version": "1.0.0",
            "summary": {"errors": 1, "warnings": 0, "info": 0},
            "issues": [
                {"severity": "error", "code": "X", "path": "name", "message": "missing"},
            ],
        }
        output = vp.format_human(result)
        assert "Invalid" in output
        assert "1 error" in output

    def test_quiet_hides_info(self):
        result = {
            "valid": True,
            "file": "PROJECT.yaml",
            "schema_version": "1.0.0",
            "summary": {"errors": 0, "warnings": 0, "info": 1},
            "issues": [
                {"severity": "info", "code": "I", "path": "x", "message": "note"},
            ],
        }
        output = vp.format_human(result, quiet=True)
        assert "note" not in output
