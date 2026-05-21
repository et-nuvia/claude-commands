---
command: task-hold
group: task-lifecycle
backing_script: ~/.claude/scripts/task-hold.sh
mutates: [git, files, asana, gitlab]
runtime: ~30-60s
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

# /task-hold

> Part of the [Task Lifecycle workflow](../08-workflows.md#task-lifecycle).

Pauses work on a task while preserving the branch and all in-progress documents. Records who is being waited on, why, and by when, then commits the hold details locally, syncs the external tracker to "Hold", and pushes the feature branch to the remote so it survives if the local worktree is later removed. **The default branch is never touched** — in-progress work is held on the feature branch only. The worktree (if in worktree mode) stays on disk for seamless resumption via `/task-resume`.

> **Config:** PROJECT.yaml **required** — reads `task_management.backend`, plus either `task_management.asana.{workspace_id, default_project}` or `task_management.gitlab.project_id` depending on backend.

---

## When to use it

- A customer response, vendor delivery, or external API is blocking progress
- Another team's work must land on `main` before you can continue
- The task needs a design decision that requires stakeholder input

## Usage

```bash
/task-hold --hold-reason "<reason>" --waiting-on "<who>" --expected-date "<YYYY-MM-DD>"
```

**Common invocations:**

```bash
/task-hold \
  --hold-reason "Waiting for vendor to finalize webhook schema" \
  --waiting-on "vendor-team" \
  --expected-date "2026-06-01" \
  --needed-info "Finalized webhook payload spec" \
  --resume-context "Resume with task-resume once spec is confirmed"
```

## Arguments

| Argument / Flag | Required | Description |
|---|---|---|
| `--hold-reason` | Yes | Why the task is blocked (≥ 20 chars) |
| `--waiting-on` | Yes | Named person, team, or vendor being waited on (must be concrete) |
| `--expected-date` | Yes | Date when the blocker is expected to resolve (`YYYY-MM-DD` or `unknown`) |
| `--needed-info` | No | Exactly what information or deliverable is needed to resume |
| `--resume-context` | No | Context note to surface when the task is later resumed |
| `--task-id <id>` | No | Override `.current-task` lookup |

## Dependencies

**External commands / packages:**

| Dependency | Why it's needed | Install |
|---|---|---|
| `git` (≥ 2.30) | Commit hold details locally, push feature branch to remote | preinstalled |
| `jq` | Parse script JSON output | `brew install jq` / `apt install jq` |
| Asana MCP (work) | Sync status to "Hold" + add comment | `mcp__asana__*` tools registered |
| `~/.asana-token` or `~/.gitlab-token` | Auth for external tracker | manual setup |

**Project files consumed:**

- `PROJECT.yaml` (PY) — Yes. Required: `task_management.backend` and either `task_management.asana.*` or `task_management.gitlab.*`
- `PROJECT-KNOWLEDGE.md` (PK) — No
- `.current-task` — read to identify the active task; left in place so `/task-resume` can pick the same context back up
- `docs/active/<task_id>/` — task document updated with hold details in place

## Backing script

**Script**: `~/.claude/scripts/task-hold.sh`

**Inputs:** `--full` plus hold detail flags. Reads `.current-task` and PROJECT.yaml. Accepts `--merge` for the post-Asana-sync branch-preservation step (despite the flag name, no actual merge into the default branch happens — see "How it works" step 5).

**Outputs (structured JSON):** `next_action` ∈ {`sync_external`, `display_summary`, `resolve_conflicts`, `fix_error`}, plus `hold_reason`, `waiting_on`, `expected_date`, `needed_info`, `branch`, `asana_gid`.

**Invocation surface:**

```bash
~/.claude/scripts/task-hold.sh --full --hold-reason "..." --waiting-on "..." \
  --expected-date "..." [--needed-info "..."] [--resume-context "..."]   # main
~/.claude/scripts/task-hold.sh --json --merge                            # preserve branch on remote (after Asana sync)
~/.claude/scripts/task-hold.sh --json --identify --task-id TASK_ID       # identify only
~/.claude/scripts/task-hold.sh --json --validate                         # validate inputs
~/.claude/scripts/task-hold.sh --json --update                           # update task doc
~/.claude/scripts/task-hold.sh --json --commit                           # local commit only
~/.claude/scripts/task-hold.sh --json --sync                             # detect external sync need
~/.claude/scripts/task-hold.sh --raw --full                              # debug
```

## How it works

1. **Validate inputs** — the script enforces that `hold_reason` is ≥ 20 chars, `waiting_on` names a concrete entity (not "someone"), and `expected_date` is today or future (or `unknown`). Returns `fix_error` with an `issues` array if validation fails.

2. **Update task document** — the TSK doc is updated with the hold details (reason, waiting on, expected date, needed info, resume context). A stakeholder summary document is created.

3. **Local commit** — the hold details are committed to the feature branch. `main` is untouched. A trap is installed: if any later step fails or the user interrupts, the staging area is unwound so a retry sees a clean index.

4. **External sync gate** (`sync_external`) — if the tracker is configured, the script returns `sync_external` before preserving the branch. The LLM updates Asana (status → "Hold", adds a comment with hold details). **Only after Asana sync succeeds** does the LLM call `--merge`. If Asana sync fails, the preservation step is blocked so external and local state don't diverge.

5. **Preserve branch** — `--merge` pushes the feature branch to the remote so it survives if the local worktree is later removed. **The default branch is NOT merged into and NOT touched.** The flag is named `--merge` for historical reasons; the actual operation is `git push -u origin <feature-branch>`. In worktree mode, the worktree at `.worktrees/<task_id>` is preserved on disk — it is NOT removed.

6. **Display summary** — shows task ID, hold reason, waiting on, expected date, and the preserved branch or worktree path.

## Example workflows

### Scenario: Waiting on vendor

```
/task-continue        # implement what's possible
/task-hold \
  --hold-reason "Cannot test until vendor delivers sandbox credentials" \
  --waiting-on "vendor-team" \
  --expected-date "2026-06-15" \
  --needed-info "Sandbox API key and webhook signing secret"
# later, when credentials arrive:
/task-resume [paste vendor email]
```

### Scenario: Hold output

```
/task-hold --hold-reason "Waiting for design sign-off on new nav" \
           --waiting-on "design-team" --expected-date "unknown"
```

```
✓ Task A3F2B9 on hold: "Redesign navigation"
  Waiting on:  design-team
  Expected:    unknown
  Branch:      feat/A3F2B9-redesign-nav (preserved on local + remote)
  Asana:       Hold (comment added)
  Default:     untouched (in-progress work stays on the feature branch)

To resume: /task-resume [paste new input]
```

## Notes & gotchas

- **In-progress work is never integrated into the default branch.** Putting a task on hold preserves the *feature branch* only; the default branch stays exactly as it was. This is intentional — partial WIP shouldn't land on `main` just because work paused.
- **Asana sync runs before the branch is pushed** — intentionally. If Asana is misconfigured, the remote is never touched. The local feature branch commit is safe to abandon or retry.
- In worktree mode, the worktree stays on disk after hold. On resume, `cd` back to `.worktrees/<task_id>` or use `/task-resume` (which detects the existing worktree automatically).
- `--needed-info` and `--resume-context` are optional but dramatically improve the quality of `/task-resume` matching when the blocker resolves.
- **If it fails:** validation error → fix the flagged `issues` from the `fix_error` response and rerun. Asana sync failed → fix MCP config and rerun `--merge`. Push rejected (permissions/network) → fix auth and rerun `--merge`. Commit hook failure → the cleanup trap unstages so the retry sees a clean index. Debug with `~/.claude/scripts/task-hold.sh --raw --full`.
