"""
Tests for docker-audit-consolidate.py

Tests snapshot loading, dedup, trend computation, and format helpers.
"""

from __future__ import annotations

import importlib.util
import json
from pathlib import Path
from unittest.mock import patch

import pytest

SCRIPTS_DIR = Path(__file__).parent.parent
_MODULE_PATH = SCRIPTS_DIR / "docker-audit-consolidate.py"
_spec = importlib.util.spec_from_file_location("docker_audit_consolidate", _MODULE_PATH)
dac = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(dac)


def make_snapshot(snap_id: str, overall_score: int = 75) -> dict:
    return {
        "id": snap_id,
        "timestamp": "2026-03-10T12:00:00Z",
        "branch": "dev",
        "status": "pass",
        "scores": {
            "overall": overall_score,
            "base_image": {"score": 80, "weight": 15},
            "compose": {"score": 70, "weight": 15},
            "security": {"score": 85, "weight": 20},
        },
        "summary": {"passed": 10, "failed": 2, "warnings": 1},
    }


@pytest.fixture
def audit_dir(tmp_path: Path) -> Path:
    d = tmp_path / "docs" / "audits" / "docker"
    d.mkdir(parents=True)
    return d


# ── Tests: load_snapshots ───────────────────────────────────────────────────

class TestLoadSnapshots:
    def test_loads_individual(self, audit_dir):
        (audit_dir / "snap-001.json").write_text(json.dumps(make_snapshot("snap-001")))
        result = dac.load_snapshots(audit_dir)
        assert len(result) == 1

    def test_deduplicates(self, audit_dir):
        snap = make_snapshot("snap-001")
        (audit_dir / "a.json").write_text(json.dumps(snap))
        (audit_dir / "b.json").write_text(json.dumps(snap))
        result = dac.load_snapshots(audit_dir)
        assert len(result) == 1

    def test_loads_from_rollups(self, audit_dir):
        rollup = {
            "version": 2,
            "period": "2026-W10",
            "type": "weekly",
            "snapshots": [make_snapshot("s1"), make_snapshot("s2")],
        }
        (audit_dir / "2026-W10.json").write_text(json.dumps(rollup))
        result = dac.load_snapshots(audit_dir)
        assert len(result) == 2

    def test_empty_dir(self, audit_dir):
        assert dac.load_snapshots(audit_dir) == []

    def test_nonexistent_dir(self, tmp_path):
        assert dac.load_snapshots(tmp_path / "nope") == []

    def test_invalid_json_skipped(self, audit_dir):
        (audit_dir / "bad.json").write_text("nope")
        (audit_dir / "good.json").write_text(json.dumps(make_snapshot("s1")))
        assert len(dac.load_snapshots(audit_dir)) == 1


# ── Tests: compute_trend ────────────────────────────────────────────────────

class TestComputeTrend:
    def test_no_previous(self):
        trend = dac.compute_trend(make_snapshot("s1", 80), None)
        assert trend["overall"]["score"] == 80
        # With no previous, prev_overall defaults to 0, so delta = score - 0
        assert trend["overall"]["delta"] == 80

    def test_with_previous(self):
        trend = dac.compute_trend(make_snapshot("s2", 85), make_snapshot("s1", 75))
        assert trend["overall"]["delta"] == 10

    def test_negative_delta(self):
        trend = dac.compute_trend(make_snapshot("s2", 70), make_snapshot("s1", 80))
        assert trend["overall"]["delta"] == -10

    def test_per_category_trend(self):
        trend = dac.compute_trend(make_snapshot("s1"), None)
        assert "base_image" in trend
        assert "security" in trend
        assert trend["base_image"]["score"] == 80


# ── Tests: format_delta ─────────────────────────────────────────────────────

class TestFormatDelta:
    def test_positive(self):
        assert "+" in dac.format_delta(5)

    def test_negative(self):
        result = dac.format_delta(-3)
        assert "-3" in result

    def test_zero(self):
        assert "unchanged" in dac.format_delta(0)


# ── Tests: time helpers ─────────────────────────────────────────────────────

class TestTimeHelpers:
    def test_iso_week(self):
        assert dac.iso_week("2026-03-10T12:00:00Z").startswith("2026-W")

    def test_iso_month(self):
        assert dac.iso_month("2026-03-10T12:00:00Z") == "2026-03"


# ── Tests: generate_json_report ─────────────────────────────────────────────

class TestGenerateJsonReport:
    def test_empty(self):
        report = dac.generate_json_report([])
        assert report["snapshots"] == 0
        assert report["current"] is None

    def test_with_data(self):
        snaps = [make_snapshot("s1", 70), make_snapshot("s2", 85)]
        report = dac.generate_json_report(snaps)
        assert report["snapshots"] == 2
        assert report["current"]["id"] == "s2"
        assert report["trend"]["overall"]["delta"] == 15
