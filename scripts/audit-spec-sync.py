#!/usr/bin/env python3
"""Generate and verify the audit scoring tables published in the wiki and docs.

The audit scripts own their scoring weights. Each exposes them via `--emit-spec`;
this tool renders those specs into markdown tables and writes them between
BEGIN/END GENERATED markers in the wiki pattern pages and ~/.claude/docs/reference.

    audit-spec-sync.py --check    # exit 1 if any published table has drifted
    audit-spec-sync.py --write    # regenerate every marked block in place
    audit-spec-sync.py --check --json

Because /docker-audit and /pipeline-audit run against every project, a weight
change in a script must never leave the documentation behind — LLMs building new
projects read the wiki, not the script. --check is wired into ci-lint-local.sh.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path
from typing import Any

HOME = Path.home()
SCRIPTS = HOME / ".claude" / "scripts"
WIKI = HOME / "projects" / "wiki"
DOCS = HOME / ".claude" / "docs" / "reference"

# Each audit: how to get its spec, and which files publish which blocks.
AUDITS: dict[str, dict[str, Any]] = {
    "docker": {
        "command": [sys.executable, str(SCRIPTS / "docker-audit.py"), "--emit-spec"],
        "targets": [
            WIKI / "patterns" / "docker-hardening-checklist.md",
            DOCS / "docker.md",
        ],
    },
    "pipeline": {
        "command": ["bash", str(SCRIPTS / "pipeline-audit.sh"), "--emit-spec"],
        "targets": [
            WIKI / "patterns" / "pipeline-audit-checklist.md",
            DOCS / "pipelines.md",
        ],
    },
}

MARKER_RE = re.compile(
    r"(?P<begin><!-- BEGIN GENERATED: (?P<audit>[a-z-]+)-audit (?P<block>[a-z-]+)[^>]*-->)"
    r"(?P<body>.*?)"
    r"(?P<end><!-- END GENERATED: (?P=audit)-audit (?P=block) -->)",
    re.DOTALL,
)


def fetch_spec(audit: str) -> dict[str, Any]:
    """Run the audit script's --emit-spec and parse it."""
    cfg = AUDITS[audit]
    proc = subprocess.run(cfg["command"], capture_output=True, text=True, cwd="/")
    if proc.returncode != 0:
        raise RuntimeError(f"{audit}: --emit-spec failed: {proc.stderr.strip()}")
    try:
        return json.loads(proc.stdout)
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"{audit}: --emit-spec did not emit valid JSON: {exc}") from exc


def pct(value: int) -> str:
    return f"{value}%" if value else "—"


def render_scoring(spec: dict[str, Any]) -> str:
    """Weighted scoring category table, one column per variant."""
    variants = spec["variants"]
    groups = {g["id"]: g for g in spec.get("groups", [])}

    def table(cats: list[dict[str, Any]]) -> list[str]:
        # Optional columns are included only when this group of categories
        # actually populates them, so project-standards tables don't carry an
        # empty Framework column just because the industry ones need it.
        headers = ["Category"] + [v["label"] for v in variants]
        show_framework = any(c.get("framework") for c in cats)
        show_items = any(c.get("items") for c in cats)
        if show_framework:
            headers.append("Framework")
        if show_items:
            headers.append("Checklist Items")
        headers.append("What It Checks")

        def row(cat: dict[str, Any]) -> str:
            cells = [cat["label"]] + [pct(cat["weights"].get(v["id"], 0)) for v in variants]
            if show_framework:
                cells.append(cat.get("framework") or "—")
            if show_items:
                cells.append(cat.get("items") or "—")
            cells.append(cat["checks"])
            return "| " + " | ".join(cells) + " |"

        return [
            "| " + " | ".join(headers) + " |",
            "|" + "|".join("---" for _ in headers) + "|",
            *[row(c) for c in cats],
        ]

    lines: list[str] = []
    for variant in variants:
        lines.append(f"- **{variant['label']}** applies when {variant['condition']}.")
    lines.append("")

    if groups:
        for gid, group in groups.items():
            cats = [c for c in spec["categories"] if c.get("group") == gid]
            if not cats:
                continue
            lines.append(f"**{group['label']} ({group['total']}%)**")
            lines.append("")
            lines.extend(table(cats))
            lines.append("")
    else:
        lines.extend(table(spec["categories"]))
        lines.append("")

    for variant in variants:
        total = sum(c["weights"].get(variant["id"], 0) for c in spec["categories"])
        lines.append(f"*{variant['label']} weights total {total}%.*")
    if spec.get("blocking_rule"):
        lines.append("")
        lines.append(spec["blocking_rule"])
    return "\n".join(lines)


def render_rating(spec: dict[str, Any]) -> str:
    """Rating scale table, ranges derived from the score thresholds."""
    scale = sorted(spec["rating_scale"], key=lambda r: r["min"], reverse=True)
    lines = ["| Score | Rating | Action |", "|---|---|---|"]
    upper = 100
    for entry in scale:
        lines.append(f"| {entry['min']}-{upper} | {entry['rating']} | {entry['action']} |")
        upper = entry["min"] - 1
    return "\n".join(lines)


def render_maturity(spec: dict[str, Any]) -> str:
    levels = spec.get("maturity_levels")
    if not levels:
        return "*This audit defines no maturity levels.*"
    lines = ["| Level | Score | Characteristics |", "|---|---|---|"]
    ordered = sorted(levels, key=lambda l: l["min"], reverse=True)
    upper = 100
    for entry in ordered:
        lines.append(
            f"| {entry['level']} - {entry['name']} | {entry['min']}-{upper} "
            f"| {entry['characteristics']} |"
        )
        upper = entry["min"] - 1
    if spec.get("maturity_basis"):
        lines.append("")
        lines.append(f"*Basis: {spec['maturity_basis']}.*")
    return "\n".join(lines)


RENDERERS = {
    "scoring": render_scoring,
    "rating": render_rating,
    "maturity": render_maturity,
}

# Blocks every target file for an audit must carry. Absence is treated as drift.
REQUIRED_BLOCKS = {
    "docker": ["scoring", "rating"],
    "pipeline": ["scoring", "rating", "maturity"],
}


def process(path: Path, spec: dict[str, Any], audit: str,
            write: bool) -> tuple[list[str], list[str], list[str]]:
    """Return (drifted, unknown, found) block ids for one file."""
    original = path.read_text()
    drifted: list[str] = []
    unknown: list[str] = []
    found: list[str] = []

    def replace(match: re.Match[str]) -> str:
        block = match.group("block")
        if match.group("audit") != audit:
            return match.group(0)
        found.append(block)
        renderer = RENDERERS.get(block)
        if renderer is None:
            unknown.append(block)
            return match.group(0)
        rendered = f"\n{renderer(spec)}\n"
        if match.group("body") != rendered:
            drifted.append(block)
        return match.group("begin") + rendered + match.group("end")

    updated = MARKER_RE.sub(replace, original)
    if write and updated != original:
        path.write_text(updated)
    return drifted, unknown, found


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--check", action="store_true",
                      help="Report drift without editing (default)")
    mode.add_argument("--write", action="store_true",
                      help="Regenerate every marked block in place")
    parser.add_argument("--audit", choices=sorted(AUDITS), action="append",
                        help="Limit to one audit (repeatable; default: all)")
    parser.add_argument("--json", action="store_true", help="Emit JSON result")
    args = parser.parse_args()

    audits = args.audit or sorted(AUDITS)
    results: list[dict[str, Any]] = []
    problems = 0

    for audit in audits:
        try:
            spec = fetch_spec(audit)
        except RuntimeError as exc:
            results.append({"audit": audit, "status": "error", "message": str(exc)})
            problems += 1
            continue

        for target in AUDITS[audit]["targets"]:
            if not target.exists():
                results.append({"audit": audit, "file": str(target),
                                "status": "missing"})
                problems += 1
                continue
            drifted, unknown, found = process(target, spec, audit, args.write)
            # A published file with no markers is drift too — someone deleted the
            # generated block, and the tables it held are now unmaintained.
            missing_blocks = [b for b in REQUIRED_BLOCKS[audit] if b not in found]
            if missing_blocks:
                results.append({"audit": audit, "file": str(target),
                                "status": "no_markers", "blocks": missing_blocks})
                problems += 1
                continue
            if unknown:
                results.append({"audit": audit, "file": str(target),
                                "status": "unknown_block", "blocks": unknown})
                problems += 1
            if drifted:
                results.append({
                    "audit": audit, "file": str(target),
                    "status": "regenerated" if args.write else "drifted",
                    "blocks": drifted,
                })
                if not args.write:
                    problems += 1
            elif not unknown:
                results.append({"audit": audit, "file": str(target),
                                "status": "in_sync"})

    if args.json:
        print(json.dumps({"mode": "write" if args.write else "check",
                          "problems": problems, "results": results}, indent=2))
    else:
        for r in results:
            label = r.get("file", "")
            if label:
                label = str(Path(label)).replace(str(HOME), "~")
            blocks = ",".join(r.get("blocks", []))
            suffix = f" [{blocks}]" if blocks else ""
            detail = r.get("message", "")
            print(f"{r['status']:>14}  {r['audit']:<9} {label}{suffix} {detail}".rstrip())
        if problems and not args.write:
            print(f"\n{problems} problem(s). Run: audit-spec-sync.py --write", file=sys.stderr)

    return 1 if (problems and not args.write) else 0


if __name__ == "__main__":
    sys.exit(main())
