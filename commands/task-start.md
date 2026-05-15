---
name: task-start
description: Start working on a task - create branch, setup environment, prepare for implementation
user_invocable: true
---

## Tracking

> Output format is auto-detected (TOON for AI callers, JSON for CI/scripts). Use `--toon` or `--json` to override.

As your **first action**, before any other work, run:
```bash
~/.claude/scripts/track-command.sh --command "task-start" --event start
```

If the workflow encounters an unrecoverable error at any point, run:
```bash
~/.claude/scripts/track-command.sh --command "task-start" --event error \\
  --model "MODEL_ID" \\
  --error-msg "brief description of what failed"
```

You are a task setup assistant. Prepare the development environment for starting work on a task.

## Execute

```bash
~/.claude/scripts/task-start.sh --full --task-id TASK_ID
```

**Worktree mode** (default): creates `.worktrees/<task_id>` with an isolated working tree. Pass `--no-worktree` to use a regular branch instead:
```bash
~/.claude/scripts/task-start.sh --full --no-worktree --task-id TASK_ID
```

Script automatically:
- Loads task context (task ID, title, Asana GID)
- Detects on-hold tasks with preserved branches
- Verifies prerequisites (clean git state)
- Pulls latest from default branch
- **Creates worktree** at `.worktrees/<task_id>` (default) or **creates branch** (`--no-worktree`)
- `cd`s into the worktree (if worktree mode) so all subsequent operations happen in the right directory
- Creates `.current-task` file (at worktree root in worktree mode, repo root in branch mode)
- Checks Asana integration config
- **If Asana sync is required**: pauses here and returns to the LLM. Asana is flipped to "In Progress" BEFORE Docker/migrations/deps — no wasted env boot on a task that can't be tracked
- **If Asana sync is NOT required**: continues inline with Docker services, migrations, dependencies, and returns a final summary

## Response Handling

Based on `next_action`:

**`sync_external`** — Branch is ready, `.current-task` is written, but Asana must be synced before env setup
- Update Asana status to "In progress" via `mcp__asana__update_custom_field` (use the `asana_gid` from the response)
- Once Asana sync succeeds, resume the flow with env setup:
  ```bash
  ~/.claude/scripts/task-start.sh --json --setup-env --task-id TASK_ID
  ```
- If Asana sync fails: fix the MCP issue and retry. The local branch is safe; nothing has been booted.

**`display_summary`** — Task fully started. Format per [Progress Format](docs/reference/ux/progress-update.md).
- Show branch name, environment status (Docker, DB, deps), worktree mode
- If `worktree_mode == true`: **the script's internal `cd` does NOT persist across Bash tool invocations** — your next Bash call will run from the parent repo unless you explicitly `cd` into the worktree. Verify and switch:
  1. Run `pwd` to check current directory
  2. If you're not at `.worktrees/<task_id>`, the very next Bash call must be `cd .worktrees/<task_id> && pwd` (or use absolute path `/Users/.../.worktrees/<task_id>`)
  3. **From this point forward in the session, every Bash invocation must either cd into the worktree first (`cd .worktrees/<task_id> && <cmd>`) or use absolute paths anchored at the worktree.** Failure to do this silently puts file edits, commits, and test runs on the wrong branch — a costly mistake that's hard to spot.
  4. Tell the user once: "Switched into worktree at `.worktrees/<task_id>`. All subsequent commands will run from here."
- If `worktree_mode == false`: standard branch mode, no worktree created — you're at the repo root
- If `task_reopened == true`: note that the task was reopened from completed status
- **Task Readiness Assessment** — after showing branch/environment status:
  - If `assessment.recommendation == "ready"`: "Task has an existing plan. Next: `/task-continue`"
  - If `assessment.recommendation == "needs_plan"`: "Task requirements are clear but no plan exists. Next: `/task-plan`"
  - If `assessment.recommendation == "needs_design"`: "Task needs design exploration before planning. Next: `/task-design`"

**`confirm_action`** — User decision needed
- On-hold task detected: ask if ready to resume, then `--resume-branch`
- Branch already exists: ask to switch, then `--setup-env`
- **Base branch choice** (`reason == "base_branch_choice"`): currently on a non-default branch. Ask user whether to branch from the current branch or the dev branch. Re-run with `--base-branch <chosen>` flag:
  `~/.claude/scripts/task-start.sh --json --full --base-branch <branch> --task-id TASK_ID`

**`fix_error`** — Start failed. Report per [Error Format](docs/reference/ux/error-blocker.md).
- `blocked` + uncommitted changes: stash (`git stash`) or commit the changes, then re-run `--full` (NOT `--verify` — `--full` re-runs the complete flow and is idempotent)
- Untracked files (e.g., a TSK doc you just created) do NOT block — only tracked file modifications block
- Other errors: debug with `--raw --<section>`

## Section Resumption

Resume from specific section after intervention:
- `--identify` — Load task context only
- `--verify` — After fixing uncommitted changes
- `--update-repo` — After fixing git conflicts
- `--create-branch` — After fixing branch issues
- `--resume-branch` — Resume on-hold preserved branch
- `--setup-env` — After fixing Docker/DB issues
- `--link-task` — Link task documents only

## Debugging

```bash
~/.claude/scripts/task-start.sh --raw --<section> --task-id TASK_ID
```

## Completion Tracking

When the workflow completes successfully, run:
```bash
~/.claude/scripts/track-command.sh --command "task-start" --event complete \
  --model "MODEL_ID" \
  --complexity COMPLEXITY \
  --tokens TOKENS_ESTIMATED \
  --cost COST_ESTIMATED
```

Replace values before calling:
- `MODEL_ID` — the model currently in use (from system context, e.g., `claude-sonnet-4-6`)
- `COMPLEXITY` — 1-5 based on: 1=read-only analysis, 2=single-file/simple git, 3=multi-file feature,
  4=cross-system/staging deploy, 5=production/infrastructure/security
- `TOKENS_ESTIMATED` — rough estimate of context used (input + output tokens combined)
- `COST_ESTIMATED` — approximate cost in USD based on model pricing
