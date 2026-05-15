#!/usr/bin/env python3
"""Docker audit consolidation with weekly/monthly rollups.

Follows the same consolidation pattern as coverage-report.py:
- Weekly rollups after week clears
- Monthly rollups after month clears
- Default branch guard
- Dedup via seen_ids
- Immutable rollups (append-only)
- Trend computation per category

Usage:
    docker-audit-consolidate.py                         # Human-readable report
    docker-audit-consolidate.py --format json           # JSON output
    docker-audit-consolidate.py --no-consolidate        # Skip consolidation
    docker-audit-consolidate.py --project-root /path    # Explicit project root
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

CATEGORIES = [
    "base_image", "compose", "security", "operations",
    "networking", "versions", "build_performance", "dhi_compliance",
    "vulnerability", "efficiency",
]


def get_project_root(explicit: str | None) -> Path:
    """Resolve project root from explicit arg, PROJECT_ROOT env, or cwd."""
    if explicit:
        return Path(explicit).resolve()
    return Path(os.environ.get("PROJECT_ROOT", os.getcwd())).resolve()


def detect_default_branch(project_root: Path) -> str:
    """Detect default branch from git or conventions."""
    try:
        result = subprocess.run(
            ["git", "-C", str(project_root), "symbolic-ref", "refs/remotes/origin/HEAD"],
            capture_output=True, text=True, timeout=5,
        )
        if result.returncode == 0:
            return result.stdout.strip().split("/")[-1]
    except Exception:
        pass

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
    now = datetime.now(timezone.utc)
    year, week, _ = now.isocalendar()
    return f"{year}-W{week:02d}"


def current_month() -> str:
    now = datetime.now(timezone.utc)
    return f"{now.year}-{now.month:02d}"


def load_snapshots(audit_dir: Path) -> list[dict[str, Any]]:
    """Load all snapshots from audit directory, deduplicating by id."""
    snapshots: list[dict[str, Any]] = []
    seen_ids: set[str] = set()

    if not audit_dir.is_dir():
        return snapshots

    for path in sorted(audit_dir.glob("*.json")):
        try:
            data = json.loads(path.read_text())
        except (json.JSONDecodeError, OSError):
            continue

        if "snapshots" in data:
            # Rollup file
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


def consolidate(audit_dir: Path, project_root: Path) -> None:
    """Consolidate completed weeks/months into rollup files."""
    if not is_default_branch(project_root):
        return

    if not audit_dir.is_dir():
        return

    cur_week = current_week()
    cur_month_str = current_month()

    # Collect individual snapshot files (not rollups)
    individual_files: list[tuple[Path, dict[str, Any]]] = []
    existing_rollup_ids: set[str] = set()

    for path in sorted(audit_dir.glob("*.json")):
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

        rollup_path = audit_dir / f"{week}.json"
        if rollup_path.exists():
            try:
                existing = json.loads(rollup_path.read_text())
                existing_ids = {s.get("id") for s in existing.get("snapshots", [])}
            except (json.JSONDecodeError, OSError):
                existing = {"version": 2, "period": week, "type": "weekly", "snapshots": []}
                existing_ids = set()
            for path, snap in entries:
                if snap["id"] not in existing_ids:
                    existing["snapshots"].append(snap)
            existing["snapshots"].sort(key=lambda s: s.get("id", ""))
            rollup_path.write_text(json.dumps(existing, indent=2) + "\n")
        else:
            rollup = {
                "version": 2,
                "period": week,
                "type": "weekly",
                "snapshots": sorted([s for _, s in entries], key=lambda s: s.get("id", "")),
            }
            rollup_path.write_text(json.dumps(rollup, indent=2) + "\n")

        for path, _ in entries:
            path.unlink(missing_ok=True)

    # Monthly consolidation
    weekly_files: list[tuple[Path, dict[str, Any]]] = []
    for path in sorted(audit_dir.glob("*-W*.json")):
        try:
            data = json.loads(path.read_text())
            if data.get("type") == "weekly":
                weekly_files.append((path, data))
        except (json.JSONDecodeError, OSError):
            continue

    by_month: dict[str, list[tuple[Path, dict[str, Any]]]] = {}
    for path, rollup in weekly_files:
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
            e[1].get("period", "") < cur_week for e in entries
        )
        if not all_complete:
            continue

        monthly_path = audit_dir / f"{month}.json"
        all_snapshots: list[dict[str, Any]] = []
        for _, rollup in entries:
            all_snapshots.extend(rollup.get("snapshots", []))
        all_snapshots.sort(key=lambda s: s.get("id", ""))

        monthly = {
            "version": 2,
            "period": month,
            "type": "monthly",
            "snapshots": all_snapshots,
        }
        monthly_path.write_text(json.dumps(monthly, indent=2) + "\n")

        for path, _ in entries:
            path.unlink(missing_ok=True)


def compute_trend(current: dict[str, Any], previous: dict[str, Any] | None) -> dict[str, Any]:
    """Compute trend deltas between snapshots."""
    trend: dict[str, Any] = {}
    cur_scores = current.get("scores", {})
    prev_scores = previous.get("scores", {}) if previous else {}

    # Overall
    cur_overall = cur_scores.get("overall", 0)
    prev_overall = prev_scores.get("overall", 0) if previous else 0
    trend["overall"] = {"score": cur_overall, "delta": cur_overall - prev_overall}

    # Per category
    for cat in CATEGORIES:
        cur_cat = cur_scores.get(cat, {})
        prev_cat = prev_scores.get(cat, {})
        cur_score = cur_cat.get("score", 0) if isinstance(cur_cat, dict) else 0
        prev_score = prev_cat.get("score", 0) if isinstance(prev_cat, dict) else 0
        trend[cat] = {"score": cur_score, "delta": cur_score - prev_score}

    return trend


def format_delta(delta: int) -> str:
    if delta > 0:
        return f"▲ +{delta}"
    elif delta < 0:
        return f"▼ {delta}"
    return "─ unchanged"


def print_human_report(snapshots: list[dict[str, Any]]) -> None:
    """Print human-readable audit trend report."""
    if not snapshots:
        print("No audit snapshots found.")
        print("Run 'python3 ~/.claude/scripts/docker-audit.py --stage all' to generate one.")
        return

    latest = snapshots[-1]
    previous = snapshots[-2] if len(snapshots) > 1 else None
    trend = compute_trend(latest, previous)

    print("Docker Audit Report")
    print("═" * 55)
    print(f"Latest: {latest.get('id', '?')} ({latest.get('branch', '?')})")
    print(f"Status: {latest.get('status', '?')}")
    print()

    print("Scores:")
    overall = trend["overall"]
    print(f"  {'Overall':<22s} {overall['score']:>3d}/100   {format_delta(overall['delta'])}")

    for cat in CATEGORIES:
        t = trend.get(cat, {})
        score = t.get("score", 0)
        delta = t.get("delta", 0)
        weight = latest.get("scores", {}).get(cat, {}).get("weight", 0) if isinstance(latest.get("scores", {}).get(cat), dict) else 0
        if score > 0 or weight > 0:
            print(f"  {cat:<22s} {score:>3d}/100   {format_delta(delta)}  (w: {weight}%)")

    print()

    # Service scores
    svc_scores = latest.get("service_scores", {})
    if svc_scores:
        print("Services:")
        for svc, data in svc_scores.items():
            print(f"  {svc:<16s} {data.get('score', 0):>3d}/100 ({data.get('grade', '?')})")

    print()
    summary = latest.get("summary", {})
    print(f"Checks: {summary.get('passed', 0)} passed, "
          f"{summary.get('failed', 0)} failed, "
          f"{summary.get('warnings', 0)} warnings")
    print(f"Total snapshots: {len(snapshots)}")


def generate_json_report(snapshots: list[dict[str, Any]]) -> dict[str, Any]:
    """Generate JSON report with trends."""
    if not snapshots:
        return {"snapshots": 0, "current": None, "trend": None}

    latest = snapshots[-1]
    previous = snapshots[-2] if len(snapshots) > 1 else None
    trend = compute_trend(latest, previous)

    return {
        "snapshots": len(snapshots),
        "current": latest,
        "trend": trend,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description="Docker audit consolidation and trends")
    parser.add_argument("--format", choices=["json"], help="Output format")
    parser.add_argument("--no-consolidate", action="store_true", help="Skip consolidation")
    parser.add_argument("--project-root", help="Project root directory")

    args = parser.parse_args()

    project_root = get_project_root(args.project_root)
    audit_dir = project_root / "docs" / "audits" / "docker"

    if not args.no_consolidate:
        consolidate(audit_dir, project_root)

    snapshots = load_snapshots(audit_dir)

    if args.format == "json":
        report = generate_json_report(snapshots)
        print(json.dumps(report, indent=2))
    else:
        print_human_report(snapshots)


if __name__ == "__main__":
    main()
