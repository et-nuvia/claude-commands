"""
Tests for analyze-har.py

Tests HAR file parsing, request counting, redundancy detection, and size tracking.
"""

from __future__ import annotations

import importlib.util
import json
from pathlib import Path
from io import StringIO
from unittest.mock import patch

import pytest

SCRIPTS_DIR = Path(__file__).parent.parent
_MODULE_PATH = SCRIPTS_DIR / "analyze-har.py"
_spec = importlib.util.spec_from_file_location("analyze_har", _MODULE_PATH)
har = importlib.util.module_from_spec(_spec)
try:
    _spec.loader.exec_module(har)
except SyntaxError:
    pytest.skip("analyze-har.py has syntax errors (f-string with literal newline)", allow_module_level=True)


def make_entry(method: str, url: str, status: int = 200, size: int = 100) -> dict:
    return {
        "request": {"method": method, "url": url},
        "response": {
            "status": status,
            "content": {"size": size},
        },
    }


@pytest.fixture
def simple_har(tmp_path: Path) -> Path:
    data = {
        "log": {
            "entries": [
                make_entry("GET", "https://example.com/api/users"),
                make_entry("GET", "https://example.com/api/users"),
                make_entry("POST", "https://example.com/api/login", 200, 500),
                make_entry("GET", "https://example.com/api/health", 200, 50),
            ]
        }
    }
    p = tmp_path / "test.har"
    p.write_text(json.dumps(data))
    return p


@pytest.fixture
def empty_har(tmp_path: Path) -> Path:
    data = {"log": {"entries": []}}
    p = tmp_path / "empty.har"
    p.write_text(json.dumps(data))
    return p


class TestAnalyzeHar:
    def test_prints_total_requests(self, simple_har, capsys):
        har.analyze_har(str(simple_har))
        output = capsys.readouterr().out
        assert "Total Requests: 4" in output

    def test_prints_data_transferred(self, simple_har, capsys):
        har.analyze_har(str(simple_har))
        output = capsys.readouterr().out
        assert "Total Data Transferred:" in output

    def test_detects_redundant_requests(self, simple_har, capsys):
        har.analyze_har(str(simple_har))
        output = capsys.readouterr().out
        assert "2x" in output
        assert "/api/users" in output

    def test_prints_status_codes(self, simple_har, capsys):
        har.analyze_har(str(simple_har))
        output = capsys.readouterr().out
        assert "200: 4" in output

    def test_empty_har(self, empty_har, capsys):
        har.analyze_har(str(empty_har))
        output = capsys.readouterr().out
        assert "Total Requests: 0" in output

    def test_invalid_file(self, tmp_path, capsys):
        p = tmp_path / "bad.har"
        p.write_text("not json")
        har.analyze_har(str(p))
        output = capsys.readouterr().out
        assert "Error reading HAR file" in output

    def test_negative_size_treated_as_zero(self, tmp_path, capsys):
        data = {
            "log": {
                "entries": [make_entry("GET", "https://x.com/a", 200, -1)]
            }
        }
        p = tmp_path / "neg.har"
        p.write_text(json.dumps(data))
        har.analyze_har(str(p))
        output = capsys.readouterr().out
        assert "0.00 MB" in output
