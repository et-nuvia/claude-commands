---
command: task-continue
group: task-lifecycle
backing_script: ~/.claude/scripts/task-continue.sh
mutates: [git, files]
runtime: ~5-30min
destructive: false
requires_project_yaml: optional
project_yaml_fields:
  - task_management.backend
  - task_management.asana.workspace_id
  - task_management.gitlab.project_id
requires_project_knowledge: optional
project_knowledge_sections:
  - Service responsibility map
  - Entity relationships
  - Business rules
  - Integration flows
---

# /task-continue

> Part of the [Task Lifecycle workflow](../08-workflows.md#task-lifecycle).

The main implementation loop for a task: reads the PLN to find the next unchecked subtask, does the work (directly or via subagent), runs focused tests, optionally auto-reviews, and commits progress with the PLN marked complete — atomically, in one script call. Repeat until all subtasks are done.

> **Config:** PROJECT.yaml **optional** — read for tech stack and test command configuration. PROJECT-KNOWLEDGE.md **optional** — read for domain context when implementing complex features.

---

## When to use it

- After `/task-plan` created the PLN and you're ready to implement the first (or next) subtask
- Each time you return to a task mid-implementation and need to pick up where the plan left off
- After fixing failures flagged by `/task-audit`, to commit the corrected work

## Usage

```bash
/task-continue
```

**Common invocations:**

```bash
/task-continue                        # load context, implement next subtask, commit
/task-continue --task-id A3F2B9       # override .current-task lookup
```

## Arguments

| Argument / Flag | Required | Description |
|---|---|---|
| `--task-id <id>` | No | Override `.current-task` lookup |

The commit step accepts additional reflection fields passed at runtime — see "How it works" Step 5.

## Dependencies

**External commands / packages:**

| Dependency | Why it's needed | Install |
|---|---|---|
| `git` | Stage and commit changes | preinstalled |
| `make` | Run tests via `make test` hierarchy | preinstalled |
| `jq` | Parse script JSON output | `brew install jq` / `apt install jq` |

**Project files consumed:**

- `PROJECT.yaml` (PY) — Optional. Determines tech stack, test command, TDD enforcement level.
- `PROJECT-KNOWLEDGE.md` (PK) — Optional. Enriches implementation decisions with domain knowledge.
- `.current-task` — read to identify the active task
- `docs/active/<task_id>/` — PLN read for `next_items`; updated atomically in `--commit`

## Backing script

**Script**: `~/.claude/scripts/task-continue.sh`

**Inputs:** `--full` / `--commit` / `--run-tests`, optional `--task-id`. The `--commit` stage also accepts `--progress-note`, `--completed-tasks`, `--lessons`, `--went-well`, `--challenges`, `--differently`, `--patterns`, `--actual-time`, `--task-label`.

**Outputs (structured JSON):** `next_action` via `--full`: `plan_context` with `next_items[]`, `work_agent`, `test_agent`, `auto_review`, `tdd_required`, `fresh_context`, `testing` (scope + has_tests). Via `--run-tests`: `passed`, `failed`, `failures[]`, `services`, `available_targets`.

**Invocation surface:**

```bash
~/.claude/scripts/task-continue.sh --full --task-id TASK_ID               # load context
~/.claude/scripts/task-continue.sh --run-tests --task-id TASK_ID           # run focused tests
~/.claude/scripts/task-continue.sh --commit --task-id TASK_ID \            # commit progress
  --progress-note "..." --completed-tasks "1.1,1.2" --lessons "..."
~/.claude/scripts/task-continue.sh --raw --full --task-id TASK_ID          # debug
```

## How it works

1. **Load context** — `--full` returns the PLN's `next_items`, the `work_agent` model, TDD enforcement level, test scope, and whether subagent isolation (`fresh_context`) is required.

2. **Determine next work** — the LLM reads `next_items` to find unchecked subtasks. If `plan_context` shows no remaining items, the task is done and the LLM routes to `/task-audit`.

3. **Do the work** — for XS/S subtasks the LLM acts directly; for M+ complexity subtasks it dispatches a subagent to protect the parent context from file-read noise. If `fresh_context == "yes"` or `work_agent` is a lighter model than the current model, a subagent is always used. Independent next items are dispatched in parallel via multiple Agent calls in one message. TDD enforcement: when `tdd_required == "yes"`, a failing test must be written and run red before any production code.

4. **Run focused tests** — `--run-tests` calls `make test` and returns structured JSON with `failures[]` and `available_targets`. The LLM drills into the narrowest failing target rather than re-running the full suite. Tests run based on scope: after the subtask (`task`), after the last subtask in a phase (`phase`), or after all phases (`full`).

5. **Auto review** (when `auto_review == "yes"`) — a review subagent analyzes the diff against the subtask spec. It must end with `APPROVED` or one or more `BLOCKING: file:line — description` lines. Real blockers go back to Step 4; non-blocking notes go into `--lessons`.

6. **Commit progress** — `--commit` atomically marks the subtask complete in the PLN (the `plan_updated` field in the output reflects whether `plan-progress.sh` actually succeeded — a failure logs a warning and the commit still proceeds with `plan_updated:false`, instead of silently lying), appends a progress entry with reflection fields, stages files via `git add -u` + NUL-delimited untracked path handling (so renames and filenames-with-spaces survive — the previous `xargs git add` pipeline corrupted them), and commits. TDD compliance is enforced here — the script blocks commits that lack test files for production changes when `tdd_required == "yes"`. Never bypass this with a direct `git commit`.

## Example workflows

### Scenario: Full implementation loop

```
/task-plan            # create PLN with subtasks
/task-continue        # implement subtask 1.1 → tests → commit
/task-continue        # implement subtask 1.2 → tests → commit
/task-audit           # quality gate
/task-close           # ship
```

### Scenario: Parallel subtasks

When `plan_context.next_items` contains two independent subtasks, the LLM dispatches both Agent calls simultaneously and commits after both return.

### Scenario: Context load output

```
/task-continue
```

```
Task A3F2B9 — "Add /me endpoint"  (subtask 2 of 5)
Next: Task 1.2 — Implement GET /me handler
  Files: src/api/me.py, tests/test_me.py
  TDD: required — write failing test first
  Model: sonnet (subagent)
  Fresh context: yes

Dispatching subagent for Task 1.2…
```

## Notes & gotchas

- **Never bypass `--commit` with direct `git add` + `git commit`.** The script enforces TDD, updates the PLN, and maintains document indexes. If it blocks, the correct fix is to write the missing tests.
- A subtask is only recorded as complete **after** tests and review pass. Do not call `plan-progress.sh --mark-complete` separately before validation.
- Subagent prompts must be fully self-contained — the subagent has zero context from the parent conversation. Always include subtask description, file list, acceptance criteria, and TDD requirement.
- **If it fails:** no PLN found → run `/task-plan` first. Tests fail after 3 retries → stop and ask the user. TDD block → write the test. Other errors: debug with `~/.claude/scripts/task-continue.sh --raw --full --task-id TASK_ID`.
