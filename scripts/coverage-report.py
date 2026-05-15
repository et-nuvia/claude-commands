#!/usr/bin/env python3
"""Coverage report with automatic consolidation of snapshot files.

Reads coverage snapshots from coverage/{development,pipeline}/ directories,
computes current state and trends, and optionally consolidates completed
weeks/months into rollup files.

Works with any project that follows the coverage/ directory contract:
  coverage/development/  — snapshots from local test runs
  coverage/pipeline/     — snapshots from CI pipeline runs

Usage:
    coverage-report.py                         # Human-readable report
    coverage-report.py --format json           # JSON output
    coverage-report.py --service backend       # Single service detail
    coverage-report.py --no-consolidate        # Skip consolidation
    coverage-report.py --project-root /path    # Explicit project root
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

SOURCES = ["development", "pipeline"]
METRICS = ["lines", "branches", "functions", "statements"]


def get_project_root(explicit: str | None) -> Path:
    """Resolve project root from explicit arg, PROJECT_ROOT env, or cwd."""
    if explicit:
        return Path(explicit).resolve()
    return Path(os.environ.get("PROJECT_ROOT", os.getcwd())).resolve()


def load_snapshots(coverage_dir: Path) -> list[dict[str, Any]]:
    """Load all individual snapshot files and extract snapshots from rollups."""
    snapshots: list[dict[str, Any]] = []
    seen_ids: set[str] = set()

    for source in SOURCES:
        source_dir = coverage_dir / source
        if not source_dir.is_dir():
            continue

        for path in sorted(source_dir.glob("*.json")):
            try:
                data = json.loads(path.read_text())
            except (json.JSONDecodeError, OSError):
                continue

            if "snapshots" in data:
                for snap in data["snapshots"]:
                    snap_id = snap.get("id", "")
                    if snap_id and snap_id not in seen_ids:
                        seen_ids.add(snap_id)
                        snapshots.append(snap)
            elif "id" in data:
                snap_id = data["id"]
                if snap_id not in seen_ids:
                    seen_ids.add(snap_id)
                    snapshots.append(data)

    snapshots.sort(key=lambda s: s.get("id", ""))
    return snapshots


def detect_default_branch(project_root: Path) -> str:
    """Detect default branch from PROJECT.yaml or common conventions."""
    yaml_path = project_root / "PROJECT.yaml"
    if yaml_path.exists():
        try:
            in_ci = False
            for line in yaml_path.read_text().splitlines():
                stripped = line.strip()
                if stripped.startswith("ci:"):
                    in_ci = True
                    continue
                if in_ci and not stripped.startswith("-") and ":" in stripped and not stripped.startswith(" "):
                    in_ci = False
                if in_ci and "production:" in stripped:
                    # The non-production branch is typically the default
                    pass
        except OSError:
            pass

    # Try git symbolic-ref
    try:
        result = subprocess.run(
            ["git", "-C", str(project_root), "symbolic-ref", "refs/remotes/origin/HEAD"],
            capture_output=True, text=True, timeout=5,
        )
        if result.returncode == 0:
            return result.stdout.strip().split("/")[-1]
    except Exception:
        pass

    # Common defaults
    for branch in ["dev", "main", "master"]:
        try:
            result = subprocess.run(
                ["git", "-C", str(project_root), "rev-parse", "--verify", f"refs/heads/{branch}"],
                capture_output=True, text=True, timeout=5,
            )
            if result.returncode == 0:
                return branch
        except Exception:
            continue

    return "dev"


def is_default_branch(project_root: Path) -> bool:
    """Check if we're on the default branch (consolidation guard)."""
    try:
        current = subprocess.run(
            ["git", "-C", str(project_root), "rev-parse", "--abbrev-ref", "HEAD"],
            capture_output=True, text=True, timeout=5,
        ).stdout.strip()
        default = detect_default_branch(project_root)
        return current == default
    except Exception:
        return False


def iso_week(ts: str) -> str:
    """Convert timestamp to ISO week string like '2026-W11'."""
    dt = datetime.fromisoformat(ts.replace("Z", "+00:00"))
    year, week, _ = dt.isocalendar()
    return f"{year}-W{week:02d}"


def iso_month(ts: str) -> str:
    """Convert timestamp to month string like '2026-03'."""
    dt = datetime.fromisoformat(ts.replace("Z", "+00:00"))
    return f"{dt.year}-{dt.month:02d}"


def current_week() -> str:
    """Get current ISO week string."""
    now = datetime.now(timezone.utc)
    year, week, _ = now.isocalendar()
    return f"{year}-W{week:02d}"


def current_month() -> str:
    """Get current month string."""
    now = datetime.now(timezone.utc)
    return f"{now.year}-{now.month:02d}"


def consolidate(coverage_dir: Path, project_root: Path) -> None:
    """Consolidate completed weeks/months into rollup files."""
    if not is_default_branch(project_root):
        return

    cur_week = current_week()
    cur_month_str = current_month()

    for source in SOURCES:
        source_dir = coverage_dir / source
        if not source_dir.is_dir():
            continue

        # Collect individual snapshot files (not rollups)
        individual_files: list[tuple[Path, dict[str, Any]]] = []
        existing_rollup_ids: set[str] = set()

        for path in sorted(source_dir.glob("*.json")):
            try:
                data = json.loads(path.read_text())
            except (json.JSONDecodeError, OSError):
                continue

            if "snapshots" in data:
                for snap in data["snapshots"]:
                    existing_rollup_ids.add(snap.get("id", ""))
            elif "id" in data:
                individual_files.append((path, data))

        # Group individuals by week
        by_week: dict[str, list[tuple[Path, dict[str, Any]]]] = {}
        for path, snap in individual_files:
            if snap.get("id", "") in existing_rollup_ids:
                path.unlink(missing_ok=True)
                continue
            ts = snap.get("timestamp", "")
            if not ts:
                continue
            week = iso_week(ts)
            by_week.setdefault(week, []).append((path, snap))

        # Create weekly rollups for completed weeks
        for week, entries in by_week.items():
            if week >= cur_week:
                continue
            rollup_path = source_dir / f"{week}.json"
            if rollup_path.exists():
                try:
                    existing = json.loads(rollup_path.read_text())
                    existing_ids = {s.get("id") for s in existing.get("snapshots", [])}
                except (json.JSONDecodeError, OSError):
                    existing = {"version": 1, "period": week, "type": "weekly", "snapshots": []}
                    existing_ids = set()
                for path, snap in entries:
                    if snap["id"] not in existing_ids:
                        existing["snapshots"].append(snap)
                existing["snapshots"].sort(key=lambda s: s.get("id", ""))
                rollup_path.write_text(json.dumps(existing, indent=2) + "\n")
            else:
                rollup = {
                    "version": 1,
                    "period": week,
                    "type": "weekly",
                    "snapshots": sorted([s for _, s in entries], key=lambda s: s.get("id", "")),
                }
                rollup_path.write_text(json.dumps(rollup, indent=2) + "\n")

            for path, _ in entries:
                path.unlink(missing_ok=True)

        # Monthly consolidation: roll completed weekly files into monthly
        weekly_files: list[tuple[Path, dict[str, Any]]] = []
        for path in sorted(source_dir.glob("*-W*.json")):
            try:
                data = json.loads(path.read_text())
                if data.get("type") == "weekly":
                    weekly_files.append((path, data))
            except (json.JSONDecodeError, OSError):
                continue

        by_month: dict[str, list[tuple[Path, dict[str, Any]]]] = {}
        for path, rollup in weekly_files:
            period = rollup.get("period", "")
            if not period:
                continue
            snaps = rollup.get("snapshots", [])
            if not snaps:
                continue
            month = iso_month(snaps[0].get("timestamp", ""))
            if month:
                by_month.setdefault(month, []).append((path, rollup))

        for month, entries in by_month.items():
            if month >= cur_month_str:
                continue
            all_complete = all(
                e[1].get("period", "") < cur_week for _, e in enumerate(entries)
                for e in [entries[_]]
            )
            if not all_complete:
                continue

            monthly_path = source_dir / f"{month}.json"
            all_snapshots: list[dict[str, Any]] = []
            for _, rollup in entries:
                all_snapshots.extend(rollup.get("snapshots", []))
            all_snapshots.sort(key=lambda s: s.get("id", ""))

            monthly = {
                "version": 1,
                "period": month,
                "type": "monthly",
                "snapshots": all_snapshots,
            }
            monthly_path.write_text(json.dumps(monthly, indent=2) + "\n")

            for path, _ in entries:
                path.unlink(missing_ok=True)


def compute_trend(current: dict[str, Any], previous: dict[str, Any] | None) -> dict[str, Any]:
    """Compute trend deltas between current and previous snapshots."""
    trend: dict[str, Any] = {}
    for metric in METRICS:
        cur_pct = current.get("overall", {}).get(metric, {}).get("pct", 0)
        if previous:
            prev_pct = previous.get("overall", {}).get(metric, {}).get("pct", 0)
            delta = round(cur_pct - prev_pct, 2)
        else:
            delta = 0
        trend[metric] = {"pct": cur_pct, "delta": delta}
    return trend


def format_delta(delta: float) -> str:
    """Format a delta value with arrow indicator."""
    if delta > 0:
        return f"\u25b2 +{delta}%"
    elif delta < 0:
        return f"\u25bc {delta}%"
    return "\u2500 unchanged"


def detect_services(snapshots: list[dict[str, Any]]) -> list[str]:
    """Detect available service names from snapshot data."""
    services: set[str] = set()
    for snap in snapshots:
        services.update(snap.get("services", {}).keys())
        services.update(snap.get("services_tested", []))
    return sorted(services)


def read_min_coverage(project_root: Path) -> int:
    """Read min_coverage from PROJECT.yaml, defaulting to 80."""
    yaml_path = project_root / "PROJECT.yaml"
    if yaml_path.exists():
        try:
            for line in yaml_path.read_text().splitlines():
                stripped = line.strip()
                if stripped.startswith("min_coverage:"):
                    return int(stripped.split(":")[1].strip())
        except (OSError, ValueError, IndexError):
            pass
    return 80


def print_human_report(
    snapshots: list[dict[str, Any]],
    service_filter: str | None,
    min_target: int,
) -> None:
    """Print human-readable coverage report."""
    if not snapshots:
        print("No coverage data found.")
        print("Run 'make test-coverage' to generate coverage snapshots.")
        return

    latest = snapshots[-1]
    previous = snapshots[-2] if len(snapshots) > 1 else None
    trend = compute_trend(latest, previous)

    print("Coverage Report")
    print("\u2550" * 55)
    print(f"Latest: {latest['id']} ({latest.get('source', '?')}, {latest.get('branch', '?')})")
    print()

    if service_filter:
        svc_data = latest.get("services", {}).get(service_filter)
        if not svc_data:
            print(f"No data for service '{service_filter}'")
            return
        print(f"Service: {service_filter}")
        for metric in METRICS:
            m = svc_data.get(metric, {})
            pct = m.get("pct", 0)
            total = m.get("total", 0)
            covered = m.get("covered", 0)
            print(f"  {metric:<12s} {pct:6.2f}%  ({covered}/{total})")
        return

    print("Overall:")
    overall_pass = True
    for metric in METRICS:
        t = trend[metric]
        m = latest.get("overall", {}).get(metric, {})
        total = m.get("total", 0)
        covered = m.get("covered", 0)
        delta_str = format_delta(t["delta"])
        print(f"  {metric:<12s} {t['pct']:6.2f}%  ({covered}/{total})   {delta_str}")
        if t["pct"] < min_target:
            overall_pass = False

    status = "\u2713 PASSING" if overall_pass else "\u2717 FAILING"
    print(f"  Min target:  {min_target}%{' ' * 17}{status}")
    print()

    services = latest.get("services", {})
    if services:
        print(f"{'Services:':<50s} Source")
        for svc_name, svc_data in services.items():
            lines_pct = svc_data.get("lines", {}).get("pct", 0)
            source_id = f"{latest.get('source', '')}/{latest['id']}"
            print(f"  {svc_name:<12s} {lines_pct:6.2f}%{' ' * 26}{source_id}")

    print()
    print(f"Total snapshots: {len(snapshots)}")


def generate_json_report(snapshots: list[dict[str, Any]], service_filter: str | None) -> dict[str, Any]:
    """Generate JSON report with current state and trends."""
    if not snapshots:
        return {"snapshots": 0, "current": None, "trend": None}

    latest = snapshots[-1]
    previous = snapshots[-2] if len(snapshots) > 1 else None
    trend = compute_trend(latest, previous)

    report: dict[str, Any] = {
        "snapshots": len(snapshots),
        "current": latest,
        "trend": trend,
    }

    if service_filter:
        report["service_filter"] = service_filter
        report["service"] = latest.get("services", {}).get(service_filter)

    return report


def main() -> None:
    parser = argparse.ArgumentParser(description="Coverage report with consolidation")
    parser.add_argument("--format", choices=["json"], help="Output format")
    parser.add_argument("--service", help="Show single service detail")
    parser.add_argument("--no-consolidate", action="store_true", help="Skip consolidation")
    parser.add_argument("--project-root", help="Project root directory (default: $PROJECT_ROOT or cwd)")
    args = parser.parse_args()

    project_root = get_project_root(args.project_root)
    coverage_dir = project_root / "coverage"
    min_target = read_min_coverage(project_root)

    if not args.no_consolidate:
        consolidate(coverage_dir, project_root)

    snapshots = load_snapshots(coverage_dir)

    if args.format == "json":
        report = generate_json_report(snapshots, args.service)
        print(json.dumps(report, indent=2))
    else:
        print_human_report(snapshots, args.service, min_target)


if __name__ == "__main__":
    main()
