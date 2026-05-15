"""Tests for json2toon.py TOON encoder."""

import json
import sys
import os

# Add lib to path
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "lib"))
from json2toon import encode, _needs_quoting, _encode_value, _is_tabular


class TestPrimitives:
    def test_null(self):
        assert encode(None) == "null"

    def test_true(self):
        assert encode(True) == "true"

    def test_false(self):
        assert encode(False) == "false"

    def test_integer(self):
        assert encode(42) == "42"

    def test_float(self):
        assert encode(3.14) == "3.14"

    def test_float_whole(self):
        assert encode(1.0) == "1"

    def test_string(self):
        assert encode("hello") == "hello"

    def test_nan(self):
        assert encode(float("nan")) == "null"

    def test_inf(self):
        assert encode(float("inf")) == "null"


class TestQuoting:
    def test_empty_string_quoted(self):
        assert _needs_quoting("")

    def test_bool_string_quoted(self):
        assert _needs_quoting("true")
        assert _needs_quoting("false")

    def test_null_string_quoted(self):
        assert _needs_quoting("null")

    def test_numeric_string_quoted(self):
        assert _needs_quoting("42")
        assert _needs_quoting("-3.14")

    def test_colon_quoted(self):
        assert _needs_quoting("key: value")

    def test_normal_string_unquoted(self):
        assert not _needs_quoting("hello world")

    def test_delimiter_in_value(self):
        assert _needs_quoting("a,b", delimiter=",")


class TestSimpleObject:
    def test_flat_object(self):
        result = encode({"name": "Alice", "age": 30})
        assert "name: Alice" in result
        assert "age: 30" in result

    def test_nested_object(self):
        result = encode({"outer": {"inner": 1}})
        lines = result.split("\n")
        assert lines[0] == "outer:"
        assert lines[1] == "  inner: 1"

    def test_empty_object(self):
        assert encode({}) == ""

    def test_empty_nested_object(self):
        result = encode({"a": {}})
        assert "a: {}" in result


class TestArrays:
    def test_primitive_array(self):
        result = encode({"items": [1, 2, 3]})
        assert "items[3]: 1,2,3" in result

    def test_empty_array(self):
        result = encode({"items": []})
        assert "items[0]:" in result

    def test_tabular_array(self):
        data = {"rows": [
            {"id": 1, "name": "Alice"},
            {"id": 2, "name": "Bob"},
        ]}
        result = encode(data)
        assert "rows[2]{id,name}:" in result
        assert "  1,Alice" in result
        assert "  2,Bob" in result

    def test_non_uniform_objects_not_tabular(self):
        data = [{"a": 1}, {"b": 2}]
        assert not _is_tabular(data)

    def test_nested_values_not_tabular(self):
        data = [{"a": {"nested": 1}}, {"a": {"nested": 2}}]
        assert not _is_tabular(data)


class TestRootArray:
    def test_root_tabular(self):
        data = [{"x": 1, "y": 2}, {"x": 3, "y": 4}]
        result = encode(data)
        assert result.startswith("[2]{x,y}:")
        assert "  1,2" in result
        assert "  3,4" in result

    def test_root_primitive(self):
        result = encode([1, 2, 3])
        assert result == "[3]: 1,2,3"

    def test_root_empty(self):
        assert encode([]) == "[0]:"


class TestEscaping:
    def test_newline_escaped(self):
        result = _encode_value("line1\nline2")
        assert result == '"line1\\nline2"'

    def test_quote_escaped(self):
        result = _encode_value('say "hi"')
        assert result == '"say \\"hi\\""'

    def test_backslash_escaped(self):
        result = _encode_value("path\\to")
        assert result == '"path\\\\to"'


class TestRealWorldPatterns:
    """Test with patterns matching actual Claude Code script output."""

    def test_pipeline_audit_findings(self):
        findings = [
            {"category": "branch", "check": "Lint stage", "result": "pass", "detail": "Found"},
            {"category": "build", "check": "Security", "result": "warn", "detail": "Missing"},
        ]
        result = encode({"findings": findings})
        assert "{category,check,result,detail}" in result
        assert "branch,Lint stage,pass,Found" in result

    def test_git_commit_file_list(self):
        data = {"files": ["scripts/a.sh", "scripts/b.sh", "docs/c.md"]}
        result = encode(data)
        assert "files[3]:" in result

    def test_plan_progress(self):
        data = {
            "status": "success",
            "progress": {"done": 3, "pending": 5, "total": 8, "percent": 37},
            "next_items": ["Task A", "Task B"],
        }
        result = encode(data)
        assert "status: success" in result
        assert "done: 3" in result
        assert "next_items[2]:" in result
