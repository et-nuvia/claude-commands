---
command: deploy-risk
group: deploy
backing_script: ~/.claude/scripts/deploy-risk.sh
mutates: [files]
runtime: ~2-5min
destructive: false
requires_project_yaml: optional
project_yaml_fields: []
requires_project_knowledge: none
project_knowledge_sections: []
---

# /deploy-risk

> Part of the [Deployment workflow](../08-workflows.md#deployment).

Runs a 10-category weighted risk analysis against the current diff and
produces a scored RSK document with per-risk mitigations, a deployment
readiness verdict, and a pre-deployment checklist. Makes no changes to git or
infrastructure; safe to run at any time.

---

## When to use it

- Before `/deploy-to-stage` or `/deploy-to-prod` when you want a standalone
  risk document separate from the automated inline scoring
- A deployment has blocking concerns and you need a formal risk assessment to
  share with stakeholders
- Post-incident review: retroactively score a change to understand what signals
  were present

## Usage

```bash
/deploy-risk [--environment ENV] [--task-id ID | --new]
```

**Common invocations:**

```bash
/deploy-risk                                     # prompts for environment
/deploy-risk --environment staging               # skip the prompt
/deploy-risk --environment production            # production thresholds
/deploy-risk --environment staging --task-id A3F2B9   # append RSK doc to existing task
/deploy-risk --environment staging --new         # assign a new V4 task ID
```

## Arguments

| Argument / Flag | Required | Description |
|---|---|---|
| `--environment ENV` | No | `staging` or `production`. Prompted interactively if omitted. |
| `--task-id ID` | No | Append the RSK document to an existing V4 task sequence (e.g. `A3F2B9`). |
| `--new` | No | Create a new V4 task ID and RSK document sequence. |

`--task-id` and `--new` are mutually exclusive. Omitting both writes to
`docs/deployment-risks/YYYY-MM-DD-<env>-<version>.md` — this is the path used
by `/deploy-to-stage` and `/deploy-to-prod` internally.

## Dependencies

**External commands:**

| Dependency | Why it's needed | Install |
|---|---|---|
| `git` | Generate diff (`git diff main...HEAD`) | preinstalled |
| `jq` | Parse script JSON output | `brew install jq` / `apt install jq` |

**Project files consumed:**

- `PROJECT.yaml` (PY) — Optional. Script proceeds without it; branch names
  default to conventional names (`main`, `staging`) when absent.
- `PROJECT-KNOWLEDGE.md` (PK) — No
- Output: `docs/deployment-risks/YYYY-MM-DD-<env>-<version>.md` (standalone)
  or `docs/active/<TASK_ID>-<DATETIME>-RSK-<desc>.md` (V4 task mode)

## Backing script

**Script**: `~/.claude/scripts/deploy-risk.sh`

**Inputs:** `--full --environment <ENV>`, optional `--task-id <ID>` or
`--new`. Section flags for targeted phases. Reads `PROJECT.yaml` if present
for branch references.

**Outputs (structured JSON):** `next_action` ∈ {`proceed_to_analysis`,
`llm_analyze`, `llm_score`, `llm_generate_document`, `write_document`,
`fix_error`}, plus `document_path`, gathered git diff context, and in V4 mode
a pre-populated document template.

**Invocation surface:**

```bash
~/.claude/scripts/deploy-risk.sh --full --environment staging
~/.claude/scripts/deploy-risk.sh --full --environment production
~/.claude/scripts/deploy-risk.sh --full --environment staging --task-id A3F2B9
~/.claude/scripts/deploy-risk.sh --full --environment staging --new
~/.claude/scripts/deploy-risk.sh --gather --environment staging
~/.claude/scripts/deploy-risk.sh --analyze --environment staging
~/.claude/scripts/deploy-risk.sh --document --environment staging
~/.claude/scripts/deploy-risk.sh --raw --analyze --environment staging   # debug
```

## How it works

1. **Gather** — script runs `git diff` for the target environment, collects
   branch metadata, and returns `proceed_to_analysis` with the diff in context.
2. **Analyze** — LLM scores each of 10 categories on a 0–10 scale:
   Code Changes, Database Migrations, Dependencies, Configuration, Breaking
   Changes, Rollback Capability, Testing Coverage, Security, Performance, Data
   Integrity. Anchors: `DROP`=9–10, hardcoded secret=10, no tests=7–9.
3. **Score** — LLM computes the weighted overall:
   `MAX(highest_individual_critical, weighted_score)`. Weights: Security 30%,
   Data Integrity 25%, Breaking Changes 15%, DB Migrations 10%, Rollback 10%,
   Code 5%, Dependencies 2.5%, Config 2.5%. Time-of-day/day-of-week
   adjustments: Friday +1, weekend +2, night +2, no on-call +2.
   Decision bands: 9–10 BLOCK · 7–8 CAUTION · 4–6 READY · 0–3 SAFE.
4. **Document** — LLM writes the RSK document to `document_path` with:
   executive summary, risk breakdown table, per-category analysis, 2+
   mitigation options each (effort, effectiveness, steps), deployment readiness
   verdict, pre-deployment checklist, and rollback plan. In V4 mode (`--task-id`
   or `--new`), `next_action` is `write_document`; standalone uses
   `llm_generate_document`.

## Example workflows

### Scenario: Standalone pre-deployment assessment

```
/deploy-risk --environment staging
/deploy-to-stage
```

Run before a staging deploy when you want the RSK doc as a separate artifact
(e.g., for a change-management ticket).

### Scenario: Attach risk doc to a task

```
/task-start 58
# implement the feature
/deploy-risk --environment production --task-id A3F2B9
/deploy-to-prod
```

V4 task mode: the RSK doc lands in `docs/active/` alongside the TSK and PLN
docs for the same task.

### Scenario: Risk summary output

```
/deploy-risk --environment staging
```

```
Deployment Risk Analysis — staging
─────────────────────────────────────────
Overall Score:  4/10 — READY (monitor closely)

  Security         2   Dependencies    1
  Data Integrity   0   Configuration   3
  Breaking Changes 0   Code Changes    4
  DB Migrations    2   Rollback        2
  Testing Coverage 5   Performance     1

Time adjustment: +0 (Tuesday afternoon, on-call confirmed)

Verdict: READY — proceed with standard monitoring.
Rollback: down migration exists; estimated recovery < 5 min.

RSK document written to:
  docs/deployment-risks/2026-05-16-staging-1.4.2.md
```

## Notes & gotchas

- `/deploy-to-stage` and `/deploy-to-prod` run risk analysis internally. Use
  `/deploy-risk` when you want a *standalone* RSK document separate from the
  deployment workflow, or when you need a formal artifact before a CAB review.
- The scoring formula uses `MAX(highest_individual, weighted)` — a single
  critical finding (e.g., a SQL injection) can override an otherwise low score.
  Do not average the category scores manually.
- `--task-id` and `--new` change both the file path and the `next_action`
  returned. Do not mix these flags with the paths expected by `/deploy-to-stage`.
- **If it fails (gather):** likely a git issue — confirm you're in a git repo
  with a clean diff context. Debug with
  `~/.claude/scripts/deploy-risk.sh --raw --gather --environment staging`.
- **If it fails (document write):** check that `docs/deployment-risks/` exists
  or the V4 docs path is writable.
