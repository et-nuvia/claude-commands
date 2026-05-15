"""
Tests for generate-release-notes.py

Tests commit parsing, categorization, and template rendering.
Does NOT test git operations or AI polish (those require external deps).
"""

from __future__ import annotations

import importlib.util
from pathlib import Path

import pytest

SCRIPTS_DIR = Path(__file__).parent.parent
_MODULE_PATH = SCRIPTS_DIR / "generate-release-notes.py"
_spec = importlib.util.spec_from_file_location("generate_release_notes", _MODULE_PATH)
grn = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(grn)


def make_commit(subject: str, body: str = "") -> dict:
    return {
        "hash": "abc123",
        "subject": subject,
        "body": body,
        "author": "Test User",
        "date": "2026-03-10",
    }


# ── Tests: parse_commits ────────────────────────────────────────────────────

class TestParseCommits:
    def test_feature_commit(self):
        commits = [make_commit("feat(auth): add SSO login")]
        parsed = grn.parse_commits(commits)
        assert len(parsed["features"]) == 1
        assert len(parsed["fixes"]) == 0

    def test_fix_commit(self):
        commits = [make_commit("fix(api): handle null response")]
        parsed = grn.parse_commits(commits)
        assert len(parsed["fixes"]) == 1

    def test_other_commit_types(self):
        commits = [
            make_commit("docs: update README"),
            make_commit("chore: bump deps"),
            make_commit("refactor(ui): simplify layout"),
            make_commit("test: add auth tests"),
        ]
        parsed = grn.parse_commits(commits)
        assert len(parsed["other"]) == 4

    def test_breaking_change_bang(self):
        commits = [make_commit("feat(api)!: change response format")]
        parsed = grn.parse_commits(commits)
        assert len(parsed["breaking"]) == 1
        assert len(parsed["features"]) == 1

    def test_breaking_change_footer(self):
        commits = [make_commit("feat: new thing", "BREAKING CHANGE: old API removed")]
        parsed = grn.parse_commits(commits)
        assert len(parsed["breaking"]) == 1

    def test_empty_commits(self):
        parsed = grn.parse_commits([])
        assert parsed["features"] == []
        assert parsed["fixes"] == []
        assert parsed["breaking"] == []
        assert parsed["other"] == []

    def test_non_conventional_commit_ignored(self):
        commits = [make_commit("random message without type prefix")]
        parsed = grn.parse_commits(commits)
        assert len(parsed["features"]) == 0
        assert len(parsed["fixes"]) == 0
        assert len(parsed["other"]) == 0


# ── Tests: build_template_data ──────────────────────────────────────────────

class TestBuildTemplateData:
    def test_basic_structure(self):
        commits = [make_commit("feat: thing")]
        parsed = grn.parse_commits(commits)
        data = grn.build_template_data("1.2.3", commits, parsed)
        assert data["VERSION"] == "1.2.3"
        assert data["COMMIT_COUNT"] == 1
        assert data["FEATURE_COUNT"] == 1

    def test_aliases(self):
        commits = [make_commit("fix: bug")]
        parsed = grn.parse_commits(commits)
        data = grn.build_template_data("1.0.0", commits, parsed)
        assert data["BUG_FIXES"] == parsed["fixes"]
        assert data["NEW_FEATURES"] == parsed["features"]


# ── Tests: render_template ──────────────────────────────────────────────────

class TestRenderTemplate:
    @pytest.fixture
    def sample_data(self):
        commits = [
            make_commit("feat(auth): add SSO"),
            make_commit("fix(api): null check"),
        ]
        parsed = grn.parse_commits(commits)
        return grn.build_template_data("2.0.0", commits, parsed)

    def test_technical_render(self, sample_data):
        output = grn.render_template("technical", sample_data, Path("."))
        assert "2.0.0" in output
        assert "Technical" in output

    def test_operations_render(self, sample_data):
        output = grn.render_template("operations", sample_data, Path("."))
        assert "Operations" in output

    def test_business_render(self, sample_data):
        output = grn.render_template("business", sample_data, Path("."))
        assert "Business" in output

    def test_external_render(self, sample_data):
        output = grn.render_template("external", sample_data, Path("."))
        assert "2.0.0" in output

    def test_support_render(self, sample_data):
        output = grn.render_template("support", sample_data, Path("."))
        assert "Support" in output
