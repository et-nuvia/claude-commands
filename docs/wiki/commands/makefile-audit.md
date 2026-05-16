---
command: makefile-audit
group: audit
backing_script: ~/.claude/scripts/makefile-audit.sh
mutates: []
runtime: ~10-30s (--fix: modifies files)
destructive: false
requires_project_yaml: required
project_yaml_fields:
  - components
  - testing.min_coverage
requires_project_knowledge: none
project_knowledge_sections: []
---

# /makefile-audit

Audits a project's Makefiles against the established project standards
(hierarchical targets, JSON output contract, help system, delegation patterns),
producing a weighted 0-100 score plus a prioritized fix plan. Can optionally
auto-fix a subset of mechanical issues in-place. Read-only by default; safe to
run repeatedly.

> **Config:** PROJECT.yaml **required** — reads `components` (verifies each component has a corresponding Makefile) and `testing.min_coverage` (validates Coverage Config)

---

## When to use it

- After setting up a new project or adding a component, to verify Makefile compliance
- When `make test` output is malformed or missing JSON fields
- Periodic review before a release to ensure the build system is sound

## Usage

```bash
/makefile-audit [--fix] [--full] [--quick]
```

**Common invocations:**

```bash
/makefile-audit               # audit only, no changes
/makefile-audit --fix         # audit then auto-fix mechanical issues
/makefile-audit --full        # audit + auto-fix in one pass
/makefile-audit --quick       # skip database seeding checks
```

## Arguments

| Argument / Flag | Required | Description |
|---|---|---|
| `--fix` | No | Apply auto-fixes for mechanical issues (idempotent) |
| `--full` | No | Audit + auto-fix in a single pass |
| `--quick` | No | Skip database seeding checks for faster results |

**Auto-fixable issues** (applied by `--fix` / `--full`): missing
`FORMAT ?= human`, missing `MAKEFLAGS += --no-print-directory`, missing
`JSON_WRAPPER` variable, missing `targets` meta-target.

**Manual-fix issues** (reported but not auto-applied): `ifeq ($(FORMAT),json)`
branches on existing targets, missing standard targets (`test`, `lint`,
`format`), missing `@` prefix on recipe lines.

## Dependencies

**External commands / packages** (must be on `PATH`):

| Dependency | Why it's needed | Install |
|---|---|---|
| `make` | Validate Makefile syntax and target discovery | preinstalled |
| `jq` | Build / consume result JSON | `brew install jq` |

**Project files consumed:**

- `PROJECT.yaml` (PY) — Yes. Required: `components`. Optional: `testing.min_coverage`.
- `PROJECT-KNOWLEDGE.md` (PK) — No
- `Makefile` (root) + `<component>/Makefile` for each component — artifacts audited
- `~/.claude/docs/reference/makefile.md` — source-of-truth for project standards
- `~/.claude/docs/reference/testing.md` — test abstraction standards
- `/tmp/makefile-audit-result.json` — written for the LLM phase

## Backing script

**Script**: `~/.claude/scripts/makefile-audit.sh`

Heavy script / light LLM: the script runs all deterministic checks and
computes weighted scores. The LLM explains failures, provides exact Makefile
code snippets to fix each issue, and routes follow-up actions.

**Inputs:** CLI flags above. Reads `PROJECT.yaml` for component list and
`testing.min_coverage`. Reads all discovered Makefiles.

**Outputs (structured JSON, to stdout and `/tmp/makefile-audit-result.json`):**

- `overall_score` (0-100), `status` (EXCELLENT / GOOD / FAIR / NEEDS WORK)
- `next_action` (`display_summary` | `generate_report_with_fixes` | `generate_report_with_recommendations`)
- `categories[]` — per-category score, weight, passed/failed/warning counts
- `findings[]` — per-check `id`, `status`, `evidence`, `file`, `fixable`
- `components[]` — per-component Makefile discovery results

**Invocation surface:**

```bash
~/.claude/scripts/makefile-audit.sh --stage all
~/.claude/scripts/makefile-audit.sh --fix
~/.claude/scripts/makefile-audit.sh --full
~/.claude/scripts/makefile-audit.sh --stage score      # score only, no report
~/.claude/scripts/makefile-audit.sh --quick
```

**Scoring:**

| Category | Weight | What It Checks |
|---|---|---|
| JSON Output | 20% | `FORMAT` branching in targets, `_PASS` and `_SCRIPT_FLAGS` variables, runner script calls in FORMAT mode |
| Structure | 15% | Root + per-component Makefiles present, `.PHONY`, `.DEFAULT_GOAL` |
| Naming Convention | 15% | `<action>-<service>-<subtype>` pattern, drill-down targets exist |
| Delegation | 15% | Root delegates via `$(MAKE) --no-print-directory -C <service>`, args forwarded via `$(_PASS)` |
| Test Abstraction | 15% | Runner scripts present, aggregation via `test-aggregate.sh`, framework not named in Makefile |
| Help System | 10% | Awk-based help, `##` annotations on targets, `##   ARG=` annotations on parameterized targets |
| Database Seeding | 10% | `_TEST_DB_SEEDED` env-var guard, leaf-only prerequisite, no file-based sentinels |

Bands: 90+ Excellent · 70-89 Good · 50-69 Fair · <50 Needs Work.

## How it works

1. **Deterministic scan** — script discovers the root Makefile and all
   component Makefiles, cross-references against `components` in `PROJECT.yaml`,
   runs every pattern matcher, computes weighted scores, writes
   `/tmp/makefile-audit-result.json`.
2. **Read results** — LLM reads the JSON; `next_action` directs the analysis
   path.
3. **Contextual analysis** — for each failed check: explains why it matters
   (referencing `makefile.md` or `testing.md`), provides the exact Makefile
   code to add or change, names the file to edit.
4. **Auto-fix offer** — if `--fix` was not passed and fixable issues exist,
   LLM offers to run `makefile-audit.sh --fix` to apply mechanical corrections.
5. **Follow-up routing** — < 50 → suggest `/makefile-init` for fresh
   generation; 50-89 → offer fixes; ≥ 90 → suggest `/testing-audit`.

## Example workflows

### Scenario: New project setup verification

```
/makefile-init           # generate Makefiles
/makefile-audit          # verify compliance
/testing-audit           # verify test abstraction
```

### Scenario: Fix and re-verify

```
/makefile-audit --fix    # auto-fix mechanical issues
/makefile-audit          # confirm score improved
/git-commit
```

### Scenario: Scorecard output

```
/makefile-audit
```

```
Makefile Implementation Audit
─────────────────────────────────────────
Project: nuvia-api      Date: 2026-05-16
Overall: 71/100 (GOOD)

Category Breakdown:
  JSON Output          55/100  (20%)
  Structure            90/100  (15%)
  Naming Convention    80/100  (15%)
  Delegation           85/100  (15%)
  Test Abstraction     70/100  (15%)
  Help System          75/100  (10%)
  Database Seeding     60/100  (10%)

Checks: 18 passed, 4 failed, 3 warnings

Top issues:
  • backend/Makefile: test target missing ifeq ($(FORMAT),json) branch (JSON Output)
  • root Makefile: _PASS variable not defined (JSON Output)
  • backend/Makefile: _TEST_DB_SEEDED guard missing on test-e2e (Database Seeding)

Run /makefile-audit --fix to apply auto-fixable corrections.
```

## Notes & gotchas

- Audit-only (`--stage all`) is non-destructive. `--fix` and `--full` modify
  Makefile(s) in-place — review changes with `git diff` after.
- Auto-fixes are idempotent; running `--fix` twice produces the same result.
- The `--quick` flag skips seeding checks — use it in CI where seeding
  infrastructure is not available.
- Scores are not comparable across projects with different component counts;
  the weights remain fixed but the number of checks scales with components.
- **If it fails:** rerun with
  `~/.claude/scripts/makefile-audit.sh --stage score` to get a bare score JSON
  and isolate which category is erroring. If `PROJECT.yaml` is missing, run
  `/project-config init` first.
