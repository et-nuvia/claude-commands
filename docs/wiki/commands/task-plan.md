---
command: task-plan
group: task-lifecycle
backing_script: ~/.claude/scripts/task-plan.sh
mutates: [git, files]
runtime: ~60-180s
destructive: false
requires_project_yaml: optional
project_yaml_fields:
  - tech_stack
  - components
  - testing.command
  - testing.coverage_threshold
requires_project_knowledge: optional
project_knowledge_sections:
  - Domain workflows
  - Entity relationships
  - Service maps
  - Integration flows
  - Business rules
---

# /task-plan

Reads a TSK (and optional DSN) document, explores the codebase, and produces a PLN document that breaks the feature into phased subtasks with estimates, model assignments, TDD flags, and `[AC#]` acceptance-criterion tags. Runs an automated quality review and iterates until the plan passes before committing.

> **Config:** PROJECT.yaml **optional** — reads tech stack, component list, and testing config. PROJECT-KNOWLEDGE.md **optional** — reads domain workflows, entity relationships, service maps, integration flows, and business rules to improve requirement traceability and impact analysis.

---

## When to use it

- After capturing a task and before starting implementation — always plan before coding
- When a task has a DSN document with deferred decisions that need investigation phases
- After completing a `/task-design` session to translate design decisions into ordered subtasks

## Usage

```bash
/task-plan [--source <path-or-url>]
```

**Common invocations:**

```bash
/task-plan                                          # loads from .current-task
/task-plan --source docs/active/A3F2B9/A3F2B9-TSK-...md   # explicit source
/task-plan --source https://app.asana.com/...              # Asana URL as source
```

## Arguments

| Argument / Flag | Required | Description |
|---|---|---|
| `--source <path-or-url>` | No | Path to a TSK document or Asana URL. Defaults to `.current-task`. |
| `--skip-review` | No | Bypass the plan quality review. Discouraged — only for emergency unblocking. |

## Dependencies

**External commands / packages:**

| Dependency | Why it's needed | Install |
|---|---|---|
| `jq` | Parse script JSON output | `brew install jq` / `apt install jq` |
| `git` | Commit the PLN document | preinstalled |

**Project files consumed:**

- `PROJECT.yaml` (PY) — Optional. Reads tech stack, components, and testing config when present.
- `PROJECT-KNOWLEDGE.md` (PK) — Optional. Loaded at Step 0 for domain context.
- TSK document — required source (from `--source` or `.current-task`)
- DSN document — optional, loaded automatically when present for the same task
- `~/.claude/scripts/new-doc.sh` — allocates PLN filepath and template

## Backing script

**Script**: `~/.claude/scripts/task-plan.sh`

**Inputs:** `--full --source <path-or-url>`, optional `--skip-review`. Also accepts section flags for targeted re-runs.

**Outputs (structured JSON):** `next_action` ∈ {`use_opus_model`, `generate_plan`, `fix_plan`, `continue`, `display_summary`, `fix_error`}, plus `requirements` (parsed from TSK/DSN), `source_data`, `dsn_data`.

For `--review`: `next_action` ∈ {`fix_plan`, `continue`}, plus `issues[]` with `check`, `task`, `message`, `line` per failing check.

**Invocation surface:**

```bash
~/.claude/scripts/task-plan.sh --full --source "path-or-url"          # main
~/.claude/scripts/task-plan.sh --load --source "path-or-url"          # load requirements only
~/.claude/scripts/task-plan.sh --analyze --source "path-or-url"       # analyze only
~/.claude/scripts/task-plan.sh --breakdown --source "path-or-url"     # breakdown only
~/.claude/scripts/task-plan.sh --estimate --source "path-or-url"      # estimate only
~/.claude/scripts/task-plan.sh --generate --source "path-or-url"      # generate only
~/.claude/scripts/task-plan.sh --review --source "path-to-pln.md"     # review existing PLN
~/.claude/scripts/task-plan.sh --review --skip-review --source "..."  # bypass review
~/.claude/scripts/task-plan.sh --raw --full --source "path-or-url"    # debug: bypass formatting
```

## How it works

1. **Load requirements** — script loads the TSK (and DSN if present) and returns structured requirements. For investigation-driven tasks (Research Findings marked "Investigation pending" or DSN has Deferred Decisions), plan will include investigation and design-refinement phases.
2. **Context loading** — LLM reads PROJECT-KNOWLEDGE.md (if available), the TSK, and the DSN's Design/Deferred Decisions. Explores the codebase for related files and existing patterns.
3. **Coverage check** — before generating, LLM verifies every TSK requirement, every DSN Design Decision, and every DSN Deferred Decision maps to at least one subtask.
4. **Write PLN** — LLM generates the plan in a single pass with concrete metadata (no placeholders). Each subtask includes Description, Files, Dependencies, Complexity (XS/S/M/L/XL), Time Estimate, Work Model, Test Model, Risks, TDD Required, Auto Review, Review Type, Fresh Context, and `[AC#]` tags. Time-estimate caps enforced: XS ≤ 30m, S ≤ 2h, M ≤ 4h, L ≤ 8h, XL ≤ 16h.
5. **TDD resolution** — borderline TDD cases presented to user in a batch for `yes`/`no`/`review individually` decision. Final PLN must have only `yes` or `no`.
6. **Automated review** — `--review` flag runs quality checks. On `fix_plan`: LLM edits the PLN in place and re-runs review. Loops until `continue`.
7. **Commit** — PLN committed only after review passes.

## Example workflows

### Scenario: Full task lifecycle

```
/task-capture "Add /me endpoint"   # TSK document created
/task-start A3F2B9                 # branch + env
/task-plan                         # PLN document created and reviewed
/task-continue                     # implementation begins
```

### Scenario: Investigation-driven task

```
/task-capture "Figure out why /search is slow"   # TSK with Research Findings placeholder
/task-design A3F2B9                               # DSN with deferred decisions
/task-plan                                        # PLN with Phase 1 = investigation
```

The resulting PLN has Phase 1 (instrument and collect data), Phase 2 (re-run `/task-design` with findings), and Phase 3+ (implementation based on resolved decisions).

### Scenario: Plan generated

```
/task-plan --source docs/active/A3F2B9/A3F2B9-TSK-add-me-endpoint.md
```

```
Plan created: A3F2B9-20260516-PLN-add-me-endpoint.md

  Phase 1 — Implementation  (est. 6h)
    [AC1] 1.1 Add /me endpoint handler      M  2h  sonnet  TDD: yes
    [AC2] 1.2 Add unit tests                S  1h  haiku   TDD: yes
    [AC3] 1.3 Update API docs               XS 30m haiku   TDD: no

Review: passed (0 issues)
Committed. Next: /task-continue
```

## Notes & gotchas

- **Never commit an unreviewed plan.** The `--review` loop is not optional — skipping it with `--skip-review` is only for emergency unblocking.
- The review step enforces: no placeholder values (`[yes/no]`, `[XS/S/M/L/XL]`), time-estimate caps, and `[AC#]` tags on every subtask.
- Investigation-driven plans use a strict phase structure: Phase 1 = investigation, Phase 2 = design-refinement (re-run `/task-design`), Phase 3+ = implementation. Do not flatten this.
- **If it fails:** source not found or ambiguous → supply explicit `--source`. Review loops repeatedly → run `--skip-review` as last resort and file a note. Other errors: debug with `~/.claude/scripts/task-plan.sh --raw --full --source "path"`.
