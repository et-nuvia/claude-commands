# Coverage Tracking Standard

Cross-project standard for persistent test coverage tracking with trend analysis.

---

## Overview

Coverage data is stored as individual JSON snapshot files in a `coverage/` directory, tracked in git. Snapshots are automatically consolidated into weekly/monthly rollups to keep the directory clean. The ops-dashboard collects coverage data from all projects via git tree API.

---

## Directory Structure

```
coverage/
├── development/     # Snapshots from local `make test-coverage` runs
│   └── .gitkeep
└── pipeline/        # Snapshots from CI pipeline runs
    └── .gitkeep
```

Both directories use the same naming convention and schema.

---

## Snapshot Schema (v1)

File naming: `{YYYYMMDD}T{HHMMSS}-{short-commit-hash}.json` (sortable by time)

```json
{
  "version": 1,
  "id": "20260314T103000-abc1234",
  "timestamp": "2026-03-14T10:30:00Z",
  "commit": "abc1234",
  "branch": "dev",
  "source": "development",
  "test_type": "unit",
  "services_tested": ["backend", "frontend"],
  "overall": {
    "lines": { "total": 480, "covered": 400, "pct": 83.33 },
    "branches": { "total": 200, "covered": 150, "pct": 75.00 },
    "functions": { "total": 100, "covered": 85, "pct": 85.00 },
    "statements": { "total": 500, "covered": 420, "pct": 84.00 }
  },
  "services": {
    "backend": {
      "suites": 10, "passed": 128, "failed": 0, "skipped": 2,
      "lines": { "total": 300, "covered": 250, "pct": 83.33 },
      "branches": { "total": 120, "covered": 90, "pct": 75.00 },
      "functions": { "total": 60, "covered": 51, "pct": 85.00 },
      "statements": { "total": 320, "covered": 270, "pct": 84.38 }
    }
  }
}
```

### Required Fields

| Field | Type | Description |
|-------|------|-------------|
| `version` | int | Schema version (currently `1`) |
| `id` | string | Unique ID: `{timestamp}-{commit}` |
| `timestamp` | string | ISO 8601 UTC timestamp |
| `commit` | string | Short git commit hash |
| `branch` | string | Git branch name |
| `source` | string | `"development"` or `"pipeline"` |
| `test_type` | string | `"unit"` (future: `"e2e"`, `"api"`) |
| `services_tested` | string[] | List of service names included in this run |
| `overall` | object | Aggregated coverage metrics across all services |
| `services` | object | Per-service coverage breakdown |

### Coverage Metrics Object

Each of `lines`, `branches`, `functions`, `statements`:

```json
{ "total": 480, "covered": 400, "pct": 83.33 }
```

### Per-Service Object

Test result counts + coverage metrics:

```json
{
  "suites": 10, "passed": 128, "failed": 0, "skipped": 2,
  "lines": { "total": 300, "covered": 250, "pct": 83.33 },
  "branches": { ... },
  "functions": { ... },
  "statements": { ... }
}
```

---

## Rollup Schema

Weekly and monthly rollups wrap individual snapshots:

```json
{
  "version": 1,
  "period": "2026-W11",
  "type": "weekly",
  "snapshots": [
    { "version": 1, "id": "20260310T...", ... },
    { "version": 1, "id": "20260311T...", ... }
  ]
}
```

Monthly: `"type": "monthly"`, `"period": "2026-03"`.

---

## Schema Versioning

- Every file includes `"version": 1`
- Individual snapshots inside rollups preserve their original version
- When the schema changes: bump version in the writer, add migration path in `coverage-report.py` for older versions
- Old files are never rewritten — the report script handles mixed versions

---

## Implementation Guide

### Step 1: Create directory structure

```bash
mkdir -p coverage/development coverage/pipeline
touch coverage/development/.gitkeep coverage/pipeline/.gitkeep
```

### Step 2: Update .gitignore

The project-level `coverage/` directory must be tracked in git. If your `.gitignore` has a blanket `coverage/` entry (common for Jest/Istanbul output), change it to only ignore per-service coverage:

```gitignore
# Before (blocks project-level tracking):
coverage/

# After (only ignores test runner output):
backend/coverage/
frontend/coverage/
# Or for single-service projects:
src/coverage/
```

### Step 3: Add snapshot writing to test runner

After test execution produces coverage data, write a snapshot file. The writer must:

1. Check if coverage data exists in the test output (no-op if no coverage)
2. Determine `source` from `CI` env var (`"pipeline"` if set, `"development"` otherwise)
3. Generate unique ID from UTC timestamp + short commit hash
4. Build snapshot object matching the schema above
5. Write to `coverage/{source}/{id}.json`
6. Wrap in try/except — **never break test execution** for snapshot failures

**Python example** (adapt for your test runner):

```python
import json
import os
import subprocess
from datetime import datetime, timezone
from pathlib import Path

def write_coverage_snapshot(test_output: dict) -> None:
    """Write coverage snapshot after test run. No-op if no coverage data."""
    if "coverage" not in test_output:
        return

    try:
        now = datetime.now(timezone.utc)
        commit = subprocess.run(
            ["git", "rev-parse", "--short", "HEAD"],
            capture_output=True, text=True, timeout=5,
        ).stdout.strip() or "unknown"
        branch = subprocess.run(
            ["git", "rev-parse", "--abbrev-ref", "HEAD"],
            capture_output=True, text=True, timeout=5,
        ).stdout.strip() or "unknown"

        source = "pipeline" if os.environ.get("CI") else "development"
        snapshot_id = now.strftime("%Y%m%dT%H%M%S") + "-" + commit

        snapshot = {
            "version": 1,
            "id": snapshot_id,
            "timestamp": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "commit": commit,
            "branch": branch,
            "source": source,
            "test_type": "unit",
            "services_tested": list(test_output.get("services", {}).keys()),
            "overall": test_output["coverage"],
            "services": {},
        }

        for svc_name, svc_data in test_output.get("services", {}).items():
            svc_snapshot = {
                "suites": svc_data.get("suites", 0),
                "passed": svc_data.get("passed", 0),
                "failed": svc_data.get("failed", 0),
                "skipped": svc_data.get("skipped", 0),
            }
            if "coverage" in svc_data:
                svc_snapshot.update(svc_data["coverage"])
            snapshot["services"][svc_name] = svc_snapshot

        project_root = Path(__file__).resolve().parent.parent
        out_dir = project_root / "coverage" / source
        out_dir.mkdir(parents=True, exist_ok=True)
        (out_dir / f"{snapshot_id}.json").write_text(
            json.dumps(snapshot, indent=2) + "\n"
        )
    except Exception:
        pass  # Never break test execution
```

### Step 4: Add Makefile target

```makefile
coverage-report: ## Show coverage report
	@python3 scripts/coverage-report.py $(if $(FORMAT),--format $(FORMAT),) $(if $(SERVICE),--service $(SERVICE),)
```

Or delegate to the global script directly:

```makefile
coverage-report: ## Show coverage report
	@python3 ~/.claude/scripts/coverage-report.py $(if $(FORMAT),--format $(FORMAT),) $(if $(SERVICE),--service $(SERVICE),)
```

### Step 5: Add project-local wrapper (optional)

If the project has its own `scripts/coverage-report.py`, it can delegate to the global version:

```python
#!/usr/bin/env python3
"""Coverage report — delegates to global ~/.claude/scripts/coverage-report.py."""
from pathlib import Path
import runpy, sys

GLOBAL_SCRIPT = Path.home() / ".claude" / "scripts" / "coverage-report.py"
if GLOBAL_SCRIPT.exists():
    if "--project-root" not in sys.argv:
        sys.argv.insert(1, "--project-root")
        sys.argv.insert(2, str(Path(__file__).resolve().parent.parent))
    runpy.run_path(str(GLOBAL_SCRIPT), run_name="__main__")
else:
    print(f"Global script not found: {GLOBAL_SCRIPT}", file=sys.stderr)
    sys.exit(1)
```

---

## Consolidation Rules

The global `coverage-report.py` handles consolidation automatically:

1. **Only runs on the default branch** — feature branches never consolidate
2. **Only completed periods** — current week/month is never touched
3. **Write-once rollups** — created once, never modified (no merge conflicts)
4. **Individual → weekly** — individual files rolled up after the week ends
5. **Weekly → monthly** — weekly files rolled up after the month ends
6. **Idempotent** — duplicate IDs are detected and skipped

### CI Detection

The snapshot writer checks `os.environ.get("CI")`:
- Set by both GitLab CI and GitHub Actions automatically
- CI detected → writes to `coverage/pipeline/`
- No CI → writes to `coverage/development/`

---

## Report Usage

```bash
# Human-readable report with trends
make coverage-report

# JSON output for dashboard/LLM consumption
make coverage-report FORMAT=json

# Single service detail
make coverage-report SERVICE=backend

# Global script directly (any project)
~/.claude/scripts/coverage-report.py --project-root /path/to/project
~/.claude/scripts/coverage-report.py --format json
~/.claude/scripts/coverage-report.py --no-consolidate
```

### Human-Readable Output

```
Coverage Report
═══════════════════════════════════════════════════════
Latest: 20260314T103000-abc1234 (pipeline, dev)

Overall:
  Lines:      83.33%  (400/480)   ▲ +1.2%
  Branches:   75.00%  (150/200)   ▼ -0.5%
  Functions:  85.00%  (85/100)    ─ unchanged
  Statements: 84.00%  (420/500)   ▲ +0.8%
  Min target: 80%                 ✓ PASSING

Services:                                         Source
  backend     83.33%                              pipeline/20260314T103000-abc1234
  frontend    75.00%                              development/20260311T142000-def5678
```

---

## Dashboard Collection

The ops-dashboard `CoverageCollector`:

1. Fetches git tree for `coverage/pipeline/` via GitLab/GitHub API
2. Sorts files by name (lexicographic = chronological)
3. Reads latest file(s) for current state
4. Reads rollup files for trend data
5. For partial runs: takes latest per service across recent files

---

## Adoption Checklist

- [ ] `coverage/development/.gitkeep` exists and is tracked
- [ ] `coverage/pipeline/.gitkeep` exists and is tracked
- [ ] `.gitignore` does NOT block `coverage/` directory (only per-service test output)
- [ ] Test runner writes snapshots matching the v1 schema
- [ ] Snapshot writer detects CI via `$CI` env var
- [ ] Snapshot writer is wrapped in try/except (never breaks tests)
- [ ] `coverage-report` Makefile target exists
- [ ] `min_coverage` is set in `PROJECT.yaml` under `testing:`
- [ ] Coverage files sort chronologically by filename
