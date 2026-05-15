---
name: task-hold
description: Put task on hold while waiting for customer response or external dependency
user_invocable: true
---

## Tracking

> Output format is auto-detected (TOON for AI callers, JSON for CI/scripts). Use `--toon` or `--json` to override.

As your **first action**, before any other work, run:
```bash
~/.claude/scripts/track-command.sh --command "task-hold" --event start
```

If the workflow encounters an unrecoverable error at any point, run:
```bash
~/.claude/scripts/track-command.sh --command "task-hold" --event error \\
  --model "MODEL_ID" \\
  --error-msg "brief description of what failed"
```

You are a task hold assistant. Put a task on hold while preserving all work for later resumption.

## Execute

```bash
~/.claude/scripts/task-hold.sh --full \
  --hold-reason "Specific reason (>= 20 chars)" \
  --waiting-on "Named person/team/vendor" \
  --expected-date "YYYY-MM-DD or unknown" \
  --needed-info "What exactly we need" \
  --resume-context "Context to remember on resume"
```

Script automatically:
- Identifies task from `.current-task` or task ID
- Gathers and **validates** hold information (reason ≥ 20 chars, waiting_on is concrete, expected_date is today/future or 'unknown')
- Updates task document with hold details
- Creates summary document for stakeholders
- Commits task document edit **locally** (no merge yet)
- Detects whether external sync (Asana/GitHub/GitLab) is needed
- Pauses BEFORE the merge so Asana can be synced first (avoids main-merged-but-Asana-unsynced divergence)

## Response Handling

Based on `next_action`:

**`sync_external`** — Local commit done, but Asana sync is required before the merge
- Local task document is committed on the feature branch. Nothing has been merged or pushed yet.
- Update Asana status to "Hold" via `mcp__asana__update_custom_field`
- Add hold comment via `mcp__asana__add_comment` using the `hold_reason`, `waiting_on`, `expected_date`, `needed_info` from the response
- **Only after Asana sync succeeds**, finalize: `~/.claude/scripts/task-hold.sh --json --merge`
- If Asana sync fails: do NOT merge. Fix the MCP issue first, then re-sync and re-run `--merge`. Local state is recoverable (just a commit on the feature branch) — main is untouched.

**`display_summary`** — Task successfully put on hold (full flow complete OR Asana not configured)
- Show: task ID, title, hold reason, waiting on, expected date, branch preserved
- **Worktree mode**: the worktree at `.worktrees/<task_id>` is preserved on disk (not removed). The branch is merged to main as usual. On resume, `cd` back to the worktree or run `/task-resume` which detects it automatically.
- Format per [Completion Format](docs/reference/ux/task-completion.md).

**`resolve_conflicts`** — Merge conflicts when merging to main
- Read conflict files, resolve using Edit tool
- Stage resolved files: `git add <files>`
- Resume: `~/.claude/scripts/task-hold.sh --json --merge`

**`fix_error`** — Hold operation failed
- If `reason == "invalid_hold_input"`: read the `issues` array and retry with better `--hold-reason`, `--waiting-on`, `--expected-date`, or `--needed-info` values.
- Other errors: debug via `~/.claude/scripts/task-hold.sh --raw --<failed-section>`.
- Report per [Error Format](docs/reference/ux/error-blocker.md).

## Section Resumption

Resume from specific section after manual intervention:
- `--identify --task-id TASK_ID` — Identify task only
- `--validate` — Validate hold inputs without side effects
- `--update` — Update task document and create summary
- `--commit` — Commit local changes only (no merge)
- `--sync` — Detect external sync requirements (does not perform Asana sync)
- `--merge` — Merge feature branch into default and push (call AFTER external sync completes)

## Debugging

```bash
~/.claude/scripts/task-hold.sh --raw --full
```

## Resume Later

- With new input: `/task-resume [paste email/SMS/response]`
- Without new input: `/task-start {task_id}`
- Manual: `git checkout {branch}`

## Completion Tracking

When the workflow completes successfully, run:
```bash
~/.claude/scripts/track-command.sh --command "task-hold" --event complete \
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
