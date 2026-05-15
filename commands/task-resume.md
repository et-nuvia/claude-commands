---
name: task-resume
description: Resume a completed or on-hold task with new input (email, SMS, Cliq, Asana, direct)
user_invocable: true
---

## Tracking

> Output format is auto-detected (TOON for AI callers, JSON for CI/scripts). Use `--toon` or `--json` to override.

As your **first action**, before any other work, run:
```bash
~/.claude/scripts/track-command.sh --command "task-resume" --event start
```

If the workflow encounters an unrecoverable error at any point, run:
```bash
~/.claude/scripts/track-command.sh --command "task-resume" --event error \\
  --model "MODEL_ID" \\
  --error-msg "brief description of what failed"
```

You are a task resume assistant. Analyze new input to identify which existing task it relates to, then reopen and incorporate the new input.

**CRITICAL**: Use model: opus for analyzing input and matching to existing tasks.

## Step 1: Search for Matching Task

```bash
~/.claude/scripts/task-resume.sh --search "$INPUT_TEXT"
```

## Step 2: Handle Response by next_action

**`confirm_resume`** — Match(es) found, user must confirm
- If single high-confidence match: ask user to confirm before reopening
- If multiple matches: use AskUserQuestion to present top matches for selection
- After confirmation, proceed to reopen with the selected task ID

**`fix_error`** — Search failed or no matches
- If `not_found`: suggest `/task-capture` to create new task
- If `error`: check details, retry with `--raw --search` for debugging

## Step 3: Precheck — detect Asana sync need BEFORE moving files

```bash
~/.claude/scripts/task-resume.sh --precheck "$TASK_ID"
```

This is a **read-only** check. It does NOT move documents. It returns whether Asana sync is required and with what GID.

## Step 4: Sync Asana FIRST (if configured)

If `should_sync_asana == true` from Step 3:
- Update Asana status to "In Progress" via `mcp__asana__update_custom_field`
- Mark the task incomplete via `mcp__asana__update_task` (`completed: false`)
- Add a comment noting the resume reason via `mcp__asana__add_comment`
- **If Asana sync fails, stop here.** Do NOT proceed to Step 5. Fix the MCP issue (token, network, permissions) and retry. Moving the docs locally while Asana still says "Completed" creates a divergence that has to be reconciled by hand.

If `should_sync_asana == false`: skip to Step 5.

## Step 5: Reopen Task (move docs)

```bash
~/.claude/scripts/task-resume.sh --reopen "$TASK_ID" "$INPUT_TEXT"
```

Script moves documents from `completed/` to `active/`, detects input source, and prepares the document template.

## Step 6: Handle Reopen + Document Creation

**`display_summary`** — Task reopened successfully
- Update task status field to "Reopened" via Edit tool
- Add progress log entry noting reopen reason

**`parse_content`** — LLM must create the new document
- Get template + filepath: `~/.claude/scripts/new-doc.sh --type "$DOC_TYPE" --description "$DESCRIPTION" --id "$TASK_ID" --json`
- Response contains `template` and `filepath`. Fill the template with parsed input data and write the completed document to `filepath` using the Write tool.
- Add reference to task's Related Documents section

## Step 7: Setup Environment

```bash
~/.claude/scripts/task-resume.sh --setup "$TASK_ID"
```

Creates `.current-task`, restores preserved branch or creates new one.

**Worktree mode**: if the task was originally started in a worktree:
1. If `.worktrees/<task_id>` still exists on disk → `cd` into it automatically
2. If worktree was deleted but branch exists → recreates the worktree from the preserved branch
3. If neither exists → error

## Section Resumption

Skip completed sections after manual intervention:
- `--precheck "$TASK_ID"` — Re-check Asana sync need only (no side effects)
- `--reopen "$TASK_ID" "$INPUT_TEXT"` — Skip search/precheck
- `--document "$TASK_ID" "$INPUT_TEXT"` — Skip search + reopen
- `--setup "$TASK_ID"` — Skip to environment setup

## Debugging

```bash
~/.claude/scripts/task-resume.sh --raw --search "$INPUT_TEXT"
```

## Completion Tracking

When the workflow completes successfully, run:
```bash
~/.claude/scripts/track-command.sh --command "task-resume" --event complete \
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
