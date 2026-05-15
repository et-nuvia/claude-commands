"""
Tests for coverage-report.py

Tests snapshot loading, deduplication, trend computation, and consolidation helpers.
"""

from __future__ import annotations

import importlib.util
import json
from pathlib import Path
from unittest.mock import patch

import pytest

SCRIPTS_DIR = Path(__file__).parent.parent
_MODULE_PATH = SCRIPTS_DIR / "coverage-report.py"
_spec = importlib.util.spec_from_file_location("coverage_report", _MODULE_PATH)
cr = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(cr)


# ── Fixtures ──────────────────────────────────────────────────────────────────

@pytest.fixture
def coverage_dir(tmp_path: Path) -> Path:
    d = tmp_path / "coverage"
    (d / "development").mkdir(parents=True)
    (d / "pipeline").mkdir(parents=True)
    return d


def make_snapshot(snap_id: str, lines_pct: float = 85.0) -> dict:
    return {
        "id": snap_id,
        "timestamp": "2026-03-10T12:00:00Z",
        "source": "development",
        "branch": "dev",
        "overall": {
            "lines": {"pct": lines_pct, "total": 100, "covered": int(lines_pct)},
            "branches": {"pct": 70.0, "total": 50, "covered": 35},
            "functions": {"pct": 90.0, "total": 20, "covered": 18},
            "statements": {"pct": 80.0, "total": 200, "covered": 160},
        },
    }


# ── Tests: get_project_root ─────────────────────────────────────────────────

class TestGetProjectRoot:
    def test_explicit_path(self, tmp_path):
        result = cr.get_project_root(str(tmp_path))
        assert result == tmp_path.resolve()

    def test_env_var(self, tmp_path):
        with patch.dict("os.environ", {"PROJECT_ROOT": str(tmp_path)}):
            result = cr.get_project_root(None)
        assert result == tmp_path.resolve()

    def test_falls_back_to_cwd(self):
        result = cr.get_project_root(None)
        assert result.is_absolute()


# ── Tests: iso_week / iso_month ──────────────────────────────────────────────

class TestTimeHelpers:
    def test_iso_week(self):
        result = cr.iso_week("2026-03-10T12:00:00Z")
        assert result.startswith("2026-W")

    def test_iso_month(self):
        assert cr.iso_month("2026-03-10T12:00:00Z") == "2026-03"

    def test_iso_month_single_digit(self):
        assert cr.iso_month("2026-01-05T00:00:00Z") == "2026-01"


# ── Tests: load_snapshots ───────────────────────────────────────────────────

class TestLoadSnapshots:
    def test_loads_individual_files(self, coverage_dir):
        snap = make_snapshot("snap-001")
        (coverage_dir / "development" / "snap-001.json").write_text(json.dumps(snap))
        result = cr.load_snapshots(coverage_dir)
        assert len(result) == 1
        assert result[0]["id"] == "snap-001"

    def test_deduplicates_by_id(self, coverage_dir):
        snap = make_snapshot("snap-001")
        (coverage_dir / "development" / "snap-001.json").write_text(json.dumps(snap))
        (coverage_dir / "pipeline" / "snap-001.json").write_text(json.dumps(snap))
        result = cr.load_snapshots(coverage_dir)
        assert len(result) == 1

    def test_loads_from_rollups(self, coverage_dir):
        rollup = {
            "version": 1,
            "period": "2026-W10",
            "type": "weekly",
            "snapshots": [make_snapshot("snap-001"), make_snapshot("snap-002")],
        }
        (coverage_dir / "development" / "2026-W10.json").write_text(json.dumps(rollup))
        result = cr.load_snapshots(coverage_dir)
        assert len(result) == 2

    def test_sorts_by_id(self, coverage_dir):
        (coverage_dir / "development" / "b.json").write_text(json.dumps(make_snapshot("snap-002")))
        (coverage_dir / "development" / "a.json").write_text(json.dumps(make_snapshot("snap-001")))
        result = cr.load_snapshots(coverage_dir)
        assert result[0]["id"] == "snap-001"
        assert result[1]["id"] == "snap-002"

    def test_empty_dir(self, coverage_dir):
        result = cr.load_snapshots(coverage_dir)
        assert result == []

    def test_invalid_json_skipped(self, coverage_dir):
        (coverage_dir / "development" / "bad.json").write_text("not json")
        (coverage_dir / "development" / "good.json").write_text(json.dumps(make_snapshot("snap-001")))
        result = cr.load_snapshots(coverage_dir)
        assert len(result) == 1


# ── Tests: compute_trend ────────────────────────────────────────────────────

class TestComputeTrend:
    def test_no_previous(self):
        current = make_snapshot("s1", lines_pct=85.0)
        trend = cr.compute_trend(current, None)
        assert trend["lines"]["pct"] == 85.0
        assert trend["lines"]["delta"] == 0

    def test_with_previous(self):
        current = make_snapshot("s2", lines_pct=90.0)
        previous = make_snapshot("s1", lines_pct=85.0)
        trend = cr.compute_trend(current, previous)
        assert trend["lines"]["delta"] == 5.0

    def test_negative_delta(self):
        current = make_snapshot("s2", lines_pct=80.0)
        previous = make_snapshot("s1", lines_pct=85.0)
        trend = cr.compute_trend(current, previous)
        assert trend["lines"]["delta"] == -5.0


# ── Tests: format_delta ─────────────────────────────────────────────────────

class TestFormatDelta:
    def test_positive(self):
        assert "+" in cr.format_delta(5.0)

    def test_negative(self):
        result = cr.format_delta(-3.0)
        assert "-3.0" in result

    def test_zero(self):
        assert "unchanged" in cr.format_delta(0)


# ── Tests: detect_services ──────────────────────────────────────────────────

class TestDetectServices:
    def test_from_services_key(self):
        snaps = [{"services": {"backend": {}, "frontend": {}}}]
        result = cr.detect_services(snaps)
        assert "backend" in result
        assert "frontend" in result

    def test_from_services_tested(self):
        snaps = [{"services_tested": ["api", "web"]}]
        result = cr.detect_services(snaps)
        assert "api" in result

    def test_empty(self):
        assert cr.detect_services([]) == []


# ── Tests: read_min_coverage ────────────────────────────────────────────────

class TestReadMinCoverage:
    def test_reads_from_yaml(self, tmp_path):
        (tmp_path / "PROJECT.yaml").write_text("name: test\nmin_coverage: 90\n")
        assert cr.read_min_coverage(tmp_path) == 90

    def test_defaults_to_80(self, tmp_path):
        assert cr.read_min_coverage(tmp_path) == 80


# ── Tests: generate_json_report ─────────────────────────────────────────────

class TestGenerateJsonReport:
    def test_empty_snapshots(self):
        report = cr.generate_json_report([], None)
        assert report["snapshots"] == 0
        assert report["current"] is None

    def test_with_snapshots(self):
        snaps = [make_snapshot("s1"), make_snapshot("s2", 90.0)]
        report = cr.generate_json_report(snaps, None)
        assert report["snapshots"] == 2
        assert report["current"]["id"] == "s2"
        assert report["trend"] is not None

    def test_service_filter(self):
        snap = make_snapshot("s1")
        snap["services"] = {"backend": {"lines": {"pct": 95.0}}}
        report = cr.generate_json_report([snap], "backend")
        assert report["service_filter"] == "backend"
        assert report["service"]["lines"]["pct"] == 95.0
