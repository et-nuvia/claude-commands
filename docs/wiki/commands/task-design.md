---
command: task-design
group: task-lifecycle
backing_script: ~/.claude/scripts/task-design.sh
mutates: [git, files]
runtime: ~10-60min (interactive)
destructive: false
requires_project_yaml: none
project_yaml_fields: []
requires_project_knowledge: optional
project_knowledge_sections:
  - Domain workflows
  - Entity relationships
  - Service maps
  - Integration flows
  - Business rules
---

# /task-design

Runs an interactive brainstorming session across 12 design topics (architecture, data model, API contract, error handling, security, observability, testing strategy, and more), then writes a DSN document recording every decision as Resolved, Not applicable, or Deferred-with-trigger. Run it before `/task-plan` when a feature has meaningful design choices.

> **Config:** PROJECT-KNOWLEDGE.md **optional** — reads domain workflows, entity relationships, service maps, integration flows, and business rules to inform architecturally sound design options.

---

## When to use it

- A feature has non-obvious design choices (data model, API shape, auth, observability)
- The task is investigation-driven and needs design decisions recorded as deferred with triggers
- A prior investigation phase completed and you need to resolve deferred decisions in an existing DSN

## Usage

```bash
/task-design [TASK_ID]
```

**Common invocations:**

```bash
/task-design                    # uses .current-task
/task-design A3F2B9             # design a specific task without making it active
```

## Arguments

| Argument / Flag | Required | Description |
|---|---|---|
| `TASK_ID` | No | Task to design. Defaults to `.current-task`. Allows designing a task without switching the active working task. |

## Dependencies

**External commands / packages:**

| Dependency | Why it's needed | Install |
|---|---|---|
| `git` | Commit the DSN document | preinstalled |
| `jq` | Parse script JSON responses | `brew install jq` / `apt install jq` |

**Project files consumed:**

- `PROJECT.yaml` (PY) — No
- `PROJECT-KNOWLEDGE.md` (PK) — Optional. Read at Step 0 for domain context.
- `.current-task` — read to identify the active task when no TASK_ID is provided
- TSK document — read to understand requirements during brainstorming
- DSN document (if exists) — read for `resume_design` flow; refined in place, never replaced

## Backing script

**Script**: `~/.claude/scripts/task-design.sh`

**Inputs:** `--full`, optional `--task-id <TASK_ID>`. Also accepts `--create-doc`, `--commit`, `--save-state`, `--load-state` for workflow checkpointing.

**Outputs (structured JSON):** `next_action` ∈ {`create_design`, `resume_design`, `fix_error`}, plus `task_doc` path, `existing_dsn` path (if present), `dsn_path` (write target).

For `--load-state`: `next_action` ∈ {`resume_brainstorm`, `create_design`}, plus `decisions[]` array with topic/choice/rationale per answered question.

**Invocation surface:**

```bash
~/.claude/scripts/task-design.sh --full                          # main
~/.claude/scripts/task-design.sh --full --task-id TASK_ID        # target specific task
~/.claude/scripts/task-design.sh --json --create-doc             # allocate DSN path + template
~/.claude/scripts/task-design.sh --json --commit                 # commit finished DSN
~/.claude/scripts/task-design.sh --save-state --task-id ID --decisions '[...]'  # checkpoint
~/.claude/scripts/task-design.sh --load-state --task-id ID       # restore checkpoint
~/.claude/scripts/task-design.sh --raw --full                    # debug: bypass formatting
```

## How it works

1. **Load context** — LLM reads PROJECT-KNOWLEDGE.md (if available) and detects whether a DSN already exists (`create_design` vs `resume_design`).
2. **Brainstorming session** — LLM works through 12 topics one at a time: Architecture, Implementation approach, Data model, Data flow, API/interface, Error handling, Security & auth, Observability, Testing strategy, Migration/rollout, Trade-offs, Risks. For each topic: ask one focused question, propose 2-3 options with trade-offs, wait for the user's choice. State is checkpointed after each answer so long sessions can resume after interruption.
3. **Classify outcomes** — every topic lands in exactly one of: **Resolved** (decision made), **Not applicable** (with a one-line reason), or **Deferred** (with an explicit trigger the user stated). No silent TBDs.
4. **Pre-commit completeness check** — LLM restates all decisions across three lists, asks the user to confirm completeness. Any new topic raised returns to the brainstorming loop.
5. **Write DSN** — script allocates filepath and template; LLM fills Resolved items into Design Decisions, Deferred items into Deferred Decisions with Trigger lines. Written in a single Write call.
6. **Commit** — DSN committed. State checkpoint file is deleted on success.

**Refinement flow** (`resume_design`): existing DSN is read, triggered deferrals are identified (those whose trigger condition is now met), brainstorming runs only on triggered items, and resolved items are moved from Deferred Decisions to Design Decisions in place via Edit tool. A second DSN is never created.

## Example workflows

### Scenario: New feature design

```
/task-capture "Add rate limiting to /search"
/task-design                    # interactive session, produces DSN
/task-plan                      # reads DSN decisions, builds PLN
/task-continue                  # implementation
```

### Scenario: Investigation-driven refinement

```
/task-continue         # Phase 1: investigation complete, findings in TSK
/task-design A3F2B9    # resume_design: resolve deferred decisions with real data
/task-plan             # Phase 3: implementation plan now fully resolved
```

### Scenario: Session checkpoint (abbreviated)

```
/task-design A3F2B9
```

```
Design session: A3F2B9 — Add rate limiting to /search

Topic 1: Architecture
  How should rate limiting be enforced?
  A) Middleware layer (simple, centralized, no business logic)
  B) Service layer (flexible, per-endpoint rules, more complex)
  C) API gateway (infrastructure-level, no app changes)

User choice? >
```

After each answer the session checkpoints, so a crash or disconnect loses at most one answer.

## Notes & gotchas

- **Never leave a topic as implicit TBD.** Deferred is valid; blank is not. If the user says "we'll decide later," record an explicit deferral with the trigger they stated.
- Long sessions (10+ topics) should use the checkpoint pattern automatically — state is saved after each answered topic and cleaned up on commit.
- Re-running on an existing DSN never creates a second DSN. It edits the existing one in place — Deferred items move to Design Decisions as they are resolved.
- **If it fails:** interrupted session → reload state with `--load-state --task-id ID`. Script errors → debug with `~/.claude/scripts/task-design.sh --raw --full`.
