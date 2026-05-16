---
command: testing-audit
group: audit
backing_script: ~/.claude/scripts/testing-audit.sh
mutates: []
runtime: ~15-45s
destructive: false
requires_project_yaml: required
project_yaml_fields:
  - components
  - databases
  - testing.min_coverage
requires_project_knowledge: none
project_knowledge_sections: []
---

# /testing-audit

Audits a project's test infrastructure — target hierarchy, JSON output
contract, framework abstraction, database seeding patterns, data isolation,
coverage configuration, and test quality — against project standards, producing
a weighted 0-100 score plus a prioritized fix plan. Makes no changes; safe to
run repeatedly.

> **Config:** PROJECT.yaml **required** — reads `components` (discovers test directories and runner scripts), `databases` (validates seeding patterns), and `testing.min_coverage` (validates coverage thresholds)

---

## When to use it

- After adding a new test suite or component, to verify it follows the standard contract
- When `make test` JSON output is missing required fields or aggregation is broken
- Periodic review before a release to confirm no skipped tests or `.only` leaks

## Usage

```bash
/testing-audit [--quick]
```

**Common invocations:**

```bash
/testing-audit           # full audit
/testing-audit --quick   # skip database seeding and data isolation checks
```

## Arguments

| Argument / Flag | Required | Description |
|---|---|---|
| `--quick` | No | Skip database seeding and data isolation checks for faster CI-mode results |

## Dependencies

**External commands / packages** (must be on `PATH`):

| Dependency | Why it's needed | Install |
|---|---|---|
| `jq` | Build / consume result JSON | `brew install jq` |
| `grep` / `find` | Pattern matching across test files | preinstalled |

**Project files consumed:**

- `PROJECT.yaml` (PY) — Yes. Required: `components`, `databases`, `testing.min_coverage`.
- `PROJECT-KNOWLEDGE.md` (PK) — No
- `Makefile`, `<component>/Makefile` — test target discovery
- `scripts/test-*.sh` — runner script contract validation
- `scripts/test-aggregate.sh` — aggregation contract validation
- Test source files (`**/*.test.ts`, `**/*.spec.ts`, `tests/**/*.py`, etc.) — quality checks
- Fixture / seed files — data isolation checks
- `jest.config.*`, `pytest.ini`, `pyproject.toml` — coverage threshold config
- `~/.claude/docs/reference/testing.md` — source-of-truth for project standards
- `/tmp/testing-audit-result.json` — written for the LLM phase

## Backing script

**Script**: `~/.claude/scripts/testing-audit.sh`

Heavy script / light LLM: the script runs all deterministic checks and
computes weighted scores. The LLM provides category-specific analysis,
explains failures with specific code-snippet fixes, and routes follow-up
actions.

**Inputs:** `--stage all`, optional `--quick`. Reads `PROJECT.yaml` for
component list, database config, and coverage threshold.

**Outputs (structured JSON, to stdout and `/tmp/testing-audit-result.json`):**

- `overall_score` (0-100), `status` (EXCELLENT / GOOD / FAIR / NEEDS WORK)
- `next_action` (`display_summary` | `generate_report_with_fixes` | `generate_report_with_recommendations`)
- `categories[]` — per-category score, weight, passed/failed/warning counts
- `findings[]` — per-check `id`, `status`, `evidence`, `file`
- `discovery{}` — component list, test dir count, runner script count, `min_coverage`

**Invocation surface:**

```bash
~/.claude/scripts/testing-audit.sh --stage all
~/.claude/scripts/testing-audit.sh --stage all --quick
```

**Scoring:**

| Category | Weight | What It Checks |
|---|---|---|
| JSON Contract | 20% | Runner scripts produce standard fields (`target`, `suites`, `tests`, `passed`, `failed`, `failed_tests`); `test-aggregate.sh` wraps children in `targets[]`; error fallback emits JSON even on framework crash |
| Target Hierarchy | 15% | `test` → `test-<service>` → `test-<service>-<type>` cascade; root delegates to service Makefiles; service Makefiles have leaf targets |
| Framework Abstraction | 15% | `ifdef FORMAT` mode calls runner scripts, not Jest/Playwright directly; non-FORMAT mode calls tools for human output; Makefile is the only thing that names the framework |
| Database Seeding | 15% | `_TEST_DB_SEEDED` env-var guard; only leaf targets have `_seed-test-db` prereq (aggregators never seed); `_PASS` forwards seed state; no file-based sentinels |
| Data Isolation | 15% | Suite-scoped seed/fixture naming; `beforeEach`/`afterEach` patterns; mutating tests do not share global state |
| Coverage Config | 10% | `testing.min_coverage` in `PROJECT.yaml`; coverage targets in Makefiles; Jest/pytest threshold configuration |
| Test Quality | 10% | No `.skip`/`xit`/`xdescribe`; no `.only`/`fdescribe`/`fit`; no `console.log`/`print()` in test files |

Bands: 90+ Excellent · 70-89 Good · 50-69 Fair · <50 Needs Work.

## How it works

1. **Deterministic scan** — script discovers components, Makefiles, runner
   scripts, and test source files; runs every pattern matcher across all
   categories; computes weighted scores; writes
   `/tmp/testing-audit-result.json`.
2. **Read results** — LLM reads the JSON; `next_action` directs the analysis
   path.
3. **Category-specific analysis** — LLM validates the JSON contract by reading
   runner scripts, checks `test-aggregate.sh` wraps children correctly, and
   scans test files for `.skip` / `.only` leaks.
4. **Contextual analysis** — for each failed check: explains why it matters
   (referencing `testing.md`), provides the exact code to add, names the file
   to edit.
5. **Follow-up routing** — < 50 → suggest `/makefile-init`; 50-69 → start with
   JSON contract and hierarchy (highest weight); 70-89 → offer targeted fixes;
   ≥ 90 → suggest `/makefile-audit` if not done.

## Example workflows

### Scenario: New component onboarding

```
/makefile-audit          # verify Makefile structure first
/testing-audit           # verify test infrastructure
/git-commit
```

### Scenario: CI JSON contract broken

```
/testing-audit           # identify which runner script is non-compliant
# fix the runner script
/testing-audit           # confirm JSON Contract score recovered
```

### Scenario: Scorecard output

```
/testing-audit
```

```
Testing Implementation Audit
─────────────────────────────────────────
Project: nuvia-api      Date: 2026-05-16
Overall: 76/100 (GOOD)

Category Breakdown:
  JSON Contract          80/100  (20%)
  Target Hierarchy       90/100  (15%)
  Framework Abstraction  85/100  (15%)
  Database Seeding       65/100  (15%)
  Data Isolation         70/100  (15%)
  Coverage Config        75/100  (10%)
  Test Quality           60/100  (10%)

Discovery:
  Components:      backend, worker, frontend
  Test dirs:       6
  Runner scripts:  4
  Min coverage:    80%

Checks: 22 passed, 3 failed, 4 warnings

Top issues:
  • worker/Makefile: test-unit has _seed-test-db prereq (aggregator should not seed)
  • frontend: 2 .skip blocks in auth.test.ts (Test Quality)
  • PROJECT.yaml: testing.min_coverage not set (Coverage Config)

Run /testing-audit again after fixes to verify.
```

## Notes & gotchas

- Non-destructive — only reads files, makes no changes.
- `--quick` skips seeding and data isolation checks; use it in environments
  without a database available.
- Skipped tests (`.skip`) are treated as failures: "skipped tests = useless tests."
- The `_TEST_DB_SEEDED` guard is critical — without it, every parent target
  re-seeds the database, causing slow and flaky CI.
- **If it fails:** rerun with
  `~/.claude/scripts/testing-audit.sh --stage all --quick` to isolate seeding
  check failures from structural failures. If `PROJECT.yaml` is missing, run
  `/project-config init` first.
