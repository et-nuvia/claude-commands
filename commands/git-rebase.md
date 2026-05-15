---
name: git-rebase
description: Rebase a branch onto another branch with intelligent validation and conflict handling
user_invocable: true
---

## Tracking

> Output format is auto-detected (TOON for AI callers, JSON for CI/scripts). Use `--toon` or `--json` to override.

As your **first action**, before any other work, run:
```bash
~/.claude/scripts/track-command.sh --command "git-rebase" --event start
```

If the workflow encounters an unrecoverable error at any point, run:
```bash
~/.claude/scripts/track-command.sh --command "git-rebase" --event error \\
  --model "MODEL_ID" \\
  --error-msg "brief description of what failed"
```

You are a git rebase assistant that rebases branches to maintain clean, linear history.

## Step 1: Analyze

```bash
~/.claude/scripts/git-rebase.sh --full --branch feature-branch --onto target-branch
```

Flags: `--branch` defaults to current branch if omitted. `--onto` auto-detects from PROJECT.yaml or git remote HEAD if omitted.

## Handle Analysis Response

Read `next_action` from JSON to determine behavior:

**`confirm_action`** (status: ready_for_confirmation) — Rebase plan ready
- Show branch, onto, commit count, potential conflict files
- If `requires_force_push` is "yes", warn user
- **STOP and ask user for confirmation before proceeding**
- After confirmation, execute: `~/.claude/scripts/git-rebase.sh --json --execute --branch feature-branch --onto target-branch`

**`display_summary`** (status: not_needed) — No rebase required
- Show reason from analysis
- No further action needed

**`ask_uncommitted_strategy`** (status: needs_decision) — Uncommitted changes detected
- Tell the user: working directory has `changed_file_count` uncommitted file(s)
- Show the file list from `details`
- Ask the user to choose using AskUserQuestion with these options:
  - **Commit first** — run `/git-commit` to commit changes, then re-run this rebase
  - **Stash** — run `git stash` to stash changes, then re-run this rebase (remind user to `git stash pop` after)
  - **Cancel** — abort the rebase
- Based on user choice:
  - Commit first: run `/git-commit`, then re-run this rebase command
  - Stash: run `git stash`, then re-run this rebase command
  - Cancel: stop and report

**`fix_error`** (status: error) — Validation failed
- Show error message and details
- For more detail: `~/.claude/scripts/git-rebase.sh --raw --validate --branch feature-branch --onto target-branch`

## Handle Execution Response

After executing rebase, read `next_action` again:

**`display_summary`** (status: success) — Rebase completed
- Show branch, new base commit, docs_updated status
- Script auto-pushes with `--force-with-lease` if remote exists

**`resolve_conflicts`** (status: conflict) — Conflicts during rebase
- Read each file in `conflict_files` using Read tool
- Resolve conflicts using Edit tool (remove `<<<<<<< ======= >>>>>>>` markers)
- Stage resolved files: `git add <files>`
- Continue: `git rebase --continue`
- After completion, push: `~/.claude/scripts/git-rebase.sh --json --push --branch feature-branch`
- To abort instead: `git rebase --abort`

**`fix_error`** (status: error) — Execution failed
- Show error message
- For more detail: `~/.claude/scripts/git-rebase.sh --raw --execute --branch feature-branch --onto target-branch`

## Section Resumption

Resume from specific section after intervention:
```bash
~/.claude/scripts/git-rebase.sh --validate --branch feature-branch --onto target-branch
~/.claude/scripts/git-rebase.sh --analyze --branch feature-branch --onto target-branch
~/.claude/scripts/git-rebase.sh --execute --branch feature-branch --onto target-branch
~/.claude/scripts/git-rebase.sh --push --branch feature-branch
```

## Debugging

```bash
~/.claude/scripts/git-rebase.sh --raw --full --branch feature-branch --onto target-branch
```

## Critical Rules

- **NEVER** rebase protected branches (main, master, develop, production, staging)
- **NEVER** proceed without user confirmation when plan shows risks
- **ALWAYS** use `--force-with-lease` (never `--force`) for remote push
- **ALWAYS** validate working directory is clean before starting

## Completion Tracking

When the workflow completes successfully, run:
```bash
~/.claude/scripts/track-command.sh --command "git-rebase" --event complete \
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
