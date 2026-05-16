---
command: task-resume
group: task-lifecycle
backing_script: ~/.claude/scripts/task-resume.sh
mutates: [git, files, asana, gitlab]
runtime: ~30-90s
destructive: false
requires_project_yaml: required
project_yaml_fields:
  - task_management.backend
  - task_management.asana.workspace_id
  - task_management.asana.default_project
  - task_management.gitlab.project_id
requires_project_knowledge: none
project_knowledge_sections: []
---

# /task-resume

Reopens a completed or on-hold task when new input arrives — an email, SMS, Asana comment, or direct description. Uses Opus to match the input against existing task documents, confirms the match with the user, syncs the external tracker back to "In Progress" before touching any files, moves docs from `completed/` to `active/`, creates a new document (UPD, FIX, etc.) capturing the new input, and restores the branch and worktree environment.

> **Config:** PROJECT.yaml **required** — reads `task_management.backend`, plus either `task_management.asana.{workspace_id, default_project}` or `task_management.gitlab.project_id` depending on backend.

---

## When to use it

- A vendor, customer, or stakeholder replies after a task was put on hold
- A "completed" task gets a bug report or follow-up change request
- A blocked task's dependency resolves and you have new information to incorporate

## Usage

```bash
/task-resume [INPUT_TEXT]
```

**Common invocations:**

```bash
/task-resume                                    # paste or describe the new input interactively
/task-resume "Vendor sent sandbox credentials"  # brief description
/task-resume [paste full email text]            # full message text for best matching accuracy
```

## Arguments

| Argument / Flag | Required | Description |
|---|---|---|
| `$ARGUMENTS` | No | Free-form text — the new input (email, SMS, description). Passed to the search and reopen steps. More detail improves match accuracy. |
| `--task-id <id>` | No | Skip search and go directly to reopening a known task ID |

## Dependencies

**External commands / packages:**

| Dependency | Why it's needed | Install |
|---|---|---|
| `git` (≥ 2.30) | Restore branch, recreate worktree if needed | preinstalled |
| `jq` | Parse script JSON output | `brew install jq` / `apt install jq` |
| Asana MCP (work) | Flip status to "In Progress", add resume comment | `mcp__asana__*` tools registered |
| `~/.asana-token` or `~/.gitlab-token` | Auth for external tracker | manual setup |

**Project files consumed:**

- `PROJECT.yaml` (PY) — Yes. Required: `task_management.backend` and either `task_management.asana.*` or `task_management.gitlab.*`
- `PROJECT-KNOWLEDGE.md` (PK) — No
- `docs/completed/<task_id>/` — source location for docs being moved back to active
- `docs/active/<task_id>/` — destination; new UPD/FIX/etc. document written here
- `.current-task` — written by `--setup` to identify the active task

## Backing script

**Script**: `~/.claude/scripts/task-resume.sh`

**Inputs:** `--search "$INPUT_TEXT"` for fuzzy matching, `--precheck "$TASK_ID"` for sync check, `--reopen "$TASK_ID" "$INPUT_TEXT"` for doc move, `--setup "$TASK_ID"` for environment restore.

**Outputs (structured JSON):**
- `--search`: `next_action` ∈ {`confirm_resume`, `fix_error`}; `matches[]` with task IDs, titles, and confidence scores.
- `--precheck`: `should_sync_asana` (bool), `asana_gid`.
- `--reopen`: `next_action` ∈ {`display_summary`, `parse_content`}; `doc_type`, `filepath`, `template`.
- `--setup`: `branch`, `worktree_path`, `worktree_restored`.

**Invocation surface:**

```bash
~/.claude/scripts/task-resume.sh --search "$INPUT_TEXT"                  # fuzzy match
~/.claude/scripts/task-resume.sh --precheck "$TASK_ID"                   # Asana sync check (read-only)
~/.claude/scripts/task-resume.sh --reopen "$TASK_ID" "$INPUT_TEXT"       # move docs
~/.claude/scripts/task-resume.sh --setup "$TASK_ID"                      # restore env
~/.claude/scripts/task-resume.sh --raw --search "$INPUT_TEXT"            # debug
```

## How it works

1. **Search** — the LLM (using Opus for matching accuracy) calls `--search` with the full input text. The script searches task document titles, descriptions, and hold context across `active/` and `completed/`. Returns ranked `matches[]` with confidence scores.

2. **Confirm** — if a single high-confidence match is found, the LLM asks the user to confirm before reopening. If multiple matches are returned, the LLM presents the top options for selection.

3. **Asana precheck** — `--precheck` is a read-only call that determines whether the tracker needs to be synced. Returns `should_sync_asana` and the task GID.

4. **Sync Asana first** — if `should_sync_asana == true`, the LLM updates Asana (status → "In Progress", `completed: false`, adds a resume comment) **before** touching any files. If Asana sync fails, the flow stops — moving docs while the tracker says "Completed" creates a divergence that must be reconciled by hand.

5. **Reopen** — `--reopen` moves all task documents from `completed/<task_id>/` to `active/<task_id>/`. Returns `next_action`:
   - `parse_content` — the LLM creates a new document (UPD, FIX, etc.) from the input text, writes it to `filepath`, and adds a reference in the TSK's Related Documents section.
   - `display_summary` — doc creation not needed (e.g., bare resume without new input).

6. **Restore environment** — `--setup` writes `.current-task` and restores the branch. In worktree mode: if `.worktrees/<task_id>` exists on disk, the LLM `cd`s into it; if the worktree was deleted but the branch exists, the script recreates it; if neither exists, the script errors.

7. **Route** — the LLM suggests the appropriate next command based on task state: `/task-plan` (no plan yet), `/task-continue` (plan exists), or `/task-start` (environment needs boot).

## Example workflows

### Scenario: Vendor replies to a held task

```
# task A3F2B9 is in docs/completed/ after /task-hold
/task-resume [paste vendor email with sandbox credentials]
# → Opus matches to A3F2B9, user confirms
# → Asana flipped to In Progress
# → docs moved to active/, UPD document created
# → worktree restored at .worktrees/A3F2B9
/task-continue        # pick up where the PLN left off
```

### Scenario: Bug report on completed feature

```
/task-resume "Customer reports /me endpoint returns 500 for SSO users"
# → matches A3F2B9 (completed)
# → FIX document created with bug details
# → branch recreated, Asana reopened
/task-plan            # add fix subtask to PLN
/task-continue        # implement fix
/task-close           # close again
```

### Scenario: Resume output

```
/task-resume "Vendor confirmed sandbox is live, credentials attached"
```

```
Match found (confidence: 94%)
  Task A3F2B9 — "Add /me endpoint"
  Status: completed (held: 2026-05-10)
  Hold reason: Waiting for vendor sandbox credentials

Confirm reopen? [y/n]: y

✓ Task A3F2B9 reopened
  Asana:    In Progress
  Docs:     moved to docs/active/A3F2B9/
  Created:  A3F2B9-20260516-UPD-vendor-credentials.md
  Worktree: .worktrees/A3F2B9 restored

Next: /task-continue
```

## Notes & gotchas

- **Opus is required for the search step** — the task-to-input matching is semantically complex and lower models produce poor confidence calibration. The command enforces Opus model selection for this step.
- **Asana sync blocks the file move intentionally.** If the tracker still shows "Completed" while docs are in `active/`, future `/task-fetch` calls return stale state. Fix the MCP issue before retrying.
- If the `--search` step finds no matches, use `/task-capture` to create a new task instead.
- **If it fails:** no matches → try `/task-resume` with more input detail, or use `--task-id` to bypass search. Asana sync failed → fix MCP token and retry from `--precheck`. Worktree missing and branch gone → error: contact user. Debug with `~/.claude/scripts/task-resume.sh --raw --search "$INPUT_TEXT"`.
