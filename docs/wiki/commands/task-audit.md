---
command: task-audit
group: task-lifecycle
backing_script: ~/.claude/scripts/task-audit.sh
mutates: [git, files]
runtime: ~30-60s
destructive: false
requires_project_yaml: optional
project_yaml_fields:
  - task_management.backend
requires_project_knowledge: optional
project_knowledge_sections:
  - Service responsibility map
  - Entity relationships
  - Business rules
  - Integration flows
---

# /task-audit

Runs a comprehensive quality audit of a task's implementation — checking commits, test coverage, acceptance criteria completion, and open TODOs — then writes an AUD document with a scored report and prioritized recommendations. Run it before closing to confirm the task is genuinely done.

> **Config:** PROJECT.yaml **optional** — reads test command config when present. PROJECT-KNOWLEDGE.md **optional** — reads service maps, entity relationships, and business rules to improve impact analysis accuracy.

---

## When to use it

- Before `/task-close`, to confirm acceptance criteria, coverage, and TODOs are addressed
- After fixing issues flagged by a prior audit, using `--re-verify` to see the delta
- As a mid-task checkpoint on long features (L/XL complexity) to catch drift early

## Usage

```bash
/task-audit [--verify] [--re-verify]
```

**Common invocations:**

```bash
/task-audit                    # full audit → AUD document
/task-audit --verify           # 100-point verification → VRF document
/task-audit --re-verify        # incremental re-audit after fixes; shows delta from prior AUD
```

## Arguments

| Argument / Flag | Required | Description |
|---|---|---|
| `--verify` | No | Runs the 100-point implementation verification rubric and writes a VRF document instead of AUD |
| `--re-verify` | No | Re-runs audit after fixes; includes `prior_aud_path` and `prior_overall_score` in response so the LLM can report the improvement delta |

## Dependencies

**External commands / packages:**

| Dependency | Why it's needed | Install |
|---|---|---|
| `git` | Inspect commits, diffs, branch state | preinstalled |
| `jq` | Parse script JSON output | `brew install jq` / `apt install jq` |
| `make` | Run tests via `make test` | preinstalled |

**Project files consumed:**

- `PROJECT.yaml` (PY) — Optional. Used to locate test command config.
- `PROJECT-KNOWLEDGE.md` (PK) — Optional. Enriches impact analysis with domain knowledge.
- `.current-task` — read to identify the active task
- `docs/active/<task_id>/` — TSK + PLN documents used for acceptance criteria and progress log comparison

## Backing script

**Script**: `~/.claude/scripts/task-audit.sh`

**Inputs:** `--full`, optional `--task-id <TASK_ID>`, `--verify`, `--re-verify`. Reads `.current-task` and task documents. Runs `make test` internally.

**Outputs (structured JSON, to stdout):** `next_action` ∈ {`generate_document`, `verify_implementation`, `fix_error`}, plus `audit_status` (`excellent`/`good`/`fair`/`needs_work`), `scores.overall` (0-100), per-category scores, `recommendations[]`, `aud_filepath`, `aud_template`. For `--re-verify`: adds `prior_aud_path`, `prior_audit_status`, `prior_overall_score`.

**Invocation surface:**

```bash
~/.claude/scripts/task-audit.sh --full                          # main
~/.claude/scripts/task-audit.sh --full --task-id TASK_ID        # target specific task
~/.claude/scripts/task-audit.sh --test                          # test execution only
~/.claude/scripts/task-audit.sh --remaining                     # remaining work only
~/.claude/scripts/task-audit.sh --impact                        # impact analysis only
~/.claude/scripts/task-audit.sh --verify                        # 100-point verification
~/.claude/scripts/task-audit.sh --re-verify                     # incremental re-audit
~/.claude/scripts/task-audit.sh --raw --full                    # debug: bypass formatting
```

## How it works

1. **Load context** — if `PROJECT-KNOWLEDGE.md` exists, LLM reads it before running the script to enrich impact analysis.
2. **Automated scan** — script analyzes commits, diffs, test results, acceptance criteria in the TSK, and open TODOs. Coverage counts exclude false-negative files (migrations, ORM models, Pydantic schemas, route registrations, type declarations — these are tested indirectly).
3. **Score and classify** — returns `audit_status` and a 0-100 overall score. Bands: excellent (90+) → ready for `/task-close`; good (70-89) → address minor items; fair (50-69) → prioritize failing tests then coverage; needs_work (<50) → return to `/task-continue`.
4. **LLM writes AUD document** — fills `aud_template` with scores, findings, and recommendations, writes to `aud_filepath`.
5. **Route** — based on status, suggests next command: `/task-close` (excellent), `/task-continue` (needs_work), or manual item fixes (fair/good).

## Example workflows

### Scenario: Pre-close quality gate

```
/task-continue        # finish implementation
/task-audit           # confirm quality before closing
/task-close           # ship
```

Standard workflow — don't skip the audit; it catches missing acceptance criteria that slip past manual review.

### Scenario: Re-audit after fixes

```
/task-audit           # returns fair: 58/100
# fix failing tests and TODOs
/task-audit --re-verify   # returns good: 82/100, shows delta
```

### Scenario: Audit scorecard output

```
/task-audit
```

```
Task Audit: A3F2B9 — Add /me endpoint
──────────────────────────────────────
Status: good (78/100)

  Acceptance Criteria    90/100   4/4 complete
  Test Coverage          70/100   2 files uncovered
  Commit Quality         85/100   3 focused commits
  Open TODOs              80/100   1 TODO remaining

Recommendations:
  • Add test coverage for src/api/users.py (line 42-61)
  • Resolve TODO on src/api/me.py:18

AUD document: docs/active/A3F2B9/A3F2B9-20260516-AUD-add-me-endpoint.md
Next: address recommendations, then /task-close
```

## Notes & gotchas

- Coverage counting intentionally excludes migration files, ORM models, and schema definitions — these are tested indirectly via API/CRUD tests.
- The `--verify` flag generates a VRF document (implementation vs. plan comparison) rather than an AUD — use when you need a formal verification artifact.
- **If it fails:** no `.current-task` → supply `--task-id`. Missing test command → check PROJECT.yaml. Other errors: debug with `~/.claude/scripts/task-audit.sh --raw --full`.
