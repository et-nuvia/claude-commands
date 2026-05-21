---
command: task-close
group: task-lifecycle
backing_script: ~/.claude/scripts/task-close.sh
mutates: [git, files, asana, gitlab]
runtime: ~2-5min
destructive: false
requires_project_yaml: required
project_yaml_fields:
  - task_management.backend
  - task_management.asana.workspace_id
  - task_management.asana.default_project
  - task_management.gitlab.project_id
requires_project_knowledge: optional
project_knowledge_sections:
  - Service responsibility map
  - Entity relationships
  - Business rules
  - Integration flows
---

# /task-close

> Part of the [Task Lifecycle workflow](../08-workflows.md#task-lifecycle).

Closes a completed or deferred task: pre-verifies the merge, generates SUM and LRN documents, syncs the external tracker to "Done", squash-merges the feature branch into the target, moves all task docs to `completed/`, and deletes the branch. Handles worktrees, merge conflicts, and Asana hours logging. When a task must be deferred instead of shipped, the command preserves the branch and records the deferral reason.

> **Config:** PROJECT.yaml **required** — reads `task_management.backend`, plus either `task_management.asana.{workspace_id, default_project}` or `task_management.gitlab.project_id` depending on backend. PROJECT-KNOWLEDGE.md **optional** — reviewed for inaccuracies introduced by the task's changes.

---

## When to use it

- After `/task-audit` confirms the task meets acceptance criteria and is ready to ship
- When a task must be shelved indefinitely and you want the branch and docs cleaned up with a clear deferral record
- As the final step in the standard lifecycle: capture → plan → start → continue → audit → close

## Usage

```bash
/task-close
```

**Common invocations:**

```bash
/task-close                                      # default: completed, auto-detect merge target
/task-close --no-merge                           # close without squash merge (e.g., PR already merged)
/task-close --target-branch develop              # override detected merge target
/task-close --status deferred --deferral-reason "Waiting for API contract"
```

## Arguments

| Argument / Flag | Required | Description |
|---|---|---|
| `--status` | No | `completed` (default) or `deferred` |
| `--no-merge` | No | Skip the squash merge — use when the PR was merged separately |
| `--target-branch <branch>` | No | Override the auto-detected merge target branch |
| `--accomplished` | No | Summary of what was completed (used for SUM doc and Asana comment) |
| `--went-well` / `--challenges` / `--differently` / `--patterns` | No | Reflection fields for the SUM/LRN docs |
| `--deferral-reason` | No (required if `--status deferred`) | Why the task is being deferred |
| `--blocker` / `--expected-date` / `--contact` | No | Deferral detail fields |
| `--task-id` | No | Override `.current-task` lookup |

## Dependencies

**External commands / packages:**

| Dependency | Why it's needed | Install |
|---|---|---|
| `git` (≥ 2.30) | Squash merge, branch deletion, worktree removal | preinstalled |
| `jq` | Parse script JSON output | `brew install jq` / `apt install jq` |
| `make` | Pre-merge lint + test during `--pre-verify` | preinstalled |
| Asana MCP (work) | Sync status to "Done", add comment, log hours | `mcp__asana__*` tools registered |
| `~/.asana-token` or `~/.gitlab-token` | Auth for external tracker | manual setup |

**Project files consumed:**

- `PROJECT.yaml` (PY) — Yes. Required: `task_management.backend` and either `task_management.asana.*` or `task_management.gitlab.*`
- `PROJECT-KNOWLEDGE.md` (PK) — Optional. Reviewed and selectively updated if the task changes make existing entries inaccurate or incomplete.
- `.current-task` — read to identify the active task; deleted on successful close
- `.task-close-state` — checkpoint file written during `--cleanup`; auto-deleted on success
- `docs/active/<task_id>/` — SUM + LRN docs written here before being moved to `completed/`

## Backing script

**Script**: `~/.claude/scripts/task-close.sh`

**Inputs:** `--ai`, `--status`, `--task-id`, optional merge/deferral flags. Reads `.current-task`, task documents, and PROJECT.yaml.

**Outputs (structured JSON):** `next_action` ∈ {`sync_asana`, `generate_docs`, `cleanup`, `confirm_action`, `display_summary`, `parse_content`, `resolve_conflicts`, `fix_error`}, plus `sum_filepath`, `lrn_filepath`, `sum_template`, `lrn_template`, `lessons_count`, `related_docs`, `git_log`, `work_hours_logged`, `project_knowledge_path`, `project_knowledge_diff`.

**Invocation surface:**

```bash
~/.claude/scripts/task-close.sh --ai --status completed --task-id TASK_ID [...]   # main
~/.claude/scripts/task-close.sh --ai --status deferred --deferral-reason "..." --task-id TASK_ID
~/.claude/scripts/task-close.sh --json --ai --pre-verify --status completed --task-id TASK_ID   # verify merge before docs
~/.claude/scripts/task-close.sh --json --cleanup --task-id TASK_ID                              # resume cleanup
~/.claude/scripts/task-close.sh --json --create-summary --title "..." --overview "..." --task-id TASK_ID
~/.claude/scripts/task-close.sh --raw --full --task-id TASK_ID                                  # debug
```

## How it works

1. **Initial run** — the LLM calls the script with `--ai --status completed` and all reflection fields. The script reads `.current-task`, checks for uncommitted changes, and determines whether Asana sync is needed. Returns `next_action`.

2. **External tracker sync** (`sync_asana`) — the closeout calls `task_close` on the active task-api adapter (Asana / GitLab / GitHub / none), so any backend is handled uniformly through the `task_*` contract. The legacy code path made raw `gh issue close` / `curl PUT` calls against GitHub and GitLab directly; those have been removed in favor of the adapter. The LLM may additionally invoke Asana MCP for richer fields (status → "Done", completion comment, Invoice Ninja hours). All sync ops are best-effort; the flow continues even if they error.

3. **Pre-merge verification** (`generate_docs`) — before writing any docs, the LLM runs `--pre-verify` to confirm the branch can cleanly rebase, lint, and build. The verified SHA is recorded so the subsequent `--cleanup` call skips re-verification. If verification fails, the LLM fixes lint/test issues on the feature branch and re-runs `--pre-verify`.

4. **Document generation** — once verified, the LLM reads `related_docs` (TSK, PLN, DSN) for context, then writes the SUM document to `sum_filepath` and, if `lessons_count > 0`, the LRN document to `lrn_filepath`. If `project_knowledge_path` is non-empty, the LLM reviews `project_knowledge_diff` and updates PROJECT-KNOWLEDGE.md only where the task introduced inaccuracies or gaps. All doc changes are committed to the feature branch.

5. **Cleanup** — the LLM calls `--cleanup`, which checkpoints each step: remove worktree → squash merge → switch to target branch → move docs to `completed/` → delete feature branch → remove `.current-task`. If any step fails, re-running `--cleanup` picks up from the last checkpoint.

6. **Display summary** — final confirmation showing task ID, docs created, merge target, and next suggested command.

## Example workflows

### Scenario: Standard lifecycle close

```
/task-audit           # confirm 90+/100 before closing
/task-close           # generate SUM, merge, move docs, close tracker
```

### Scenario: Deferred task

```
/task-close --status deferred --deferral-reason "API contract not finalized by vendor" \
            --blocker "vendor" --expected-date "2026-06-01" --contact "vendor@example.com"
```

Branch is preserved; no squash merge. Asana status set to "On Hold".

### Scenario: Completion output

```
/task-close
```

```
✓ Task A3F2B9 closed: "Add /me endpoint"
  Status:    completed
  Branch:    feat/A3F2B9-me-endpoint → main (squash merged)
  Docs:      SUM + LRN created, moved to docs/completed/A3F2B9/
  Asana:     Done (hours logged: 4.5h)
  Worktree:  .worktrees/A3F2B9 removed

Next: /task-fetch (pick up next task)
```

## Notes & gotchas

- **Cleanup is checkpointed** via `.task-close-state`. If the process dies mid-cleanup, re-run `--cleanup` — it picks up exactly where it left off. No risk of double-merges.
- Pre-merge verification is skipped for doc-only changes and projects without a Makefile.
- Deferred tasks skip the squash merge and branch deletion automatically — the branch is preserved for future resumption.
- **NEVER run git merge, git checkout, or git branch -D directly.** All git operations are managed by the script; bypassing it corrupts the checkpoint state.
- **If it fails:** uncommitted changes → commit or stash, rerun. Merge conflicts → read `conflict_files`, resolve with Edit tool, `git add`, then `--cleanup`. Other errors: debug with `~/.claude/scripts/task-close.sh --raw --full --task-id TASK_ID`.
