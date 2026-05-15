---
name: git-merge
description: Merge a source branch into a target branch (regular or squash merge)
user_invocable: true
---

## Tracking

> Output format is auto-detected (TOON for AI callers, JSON for CI/scripts). Use `--toon` or `--json` to override.

As your **first action**, before any other work, run:
```bash
~/.claude/scripts/track-command.sh --command "git-merge" --event start
```

If the workflow encounters an unrecoverable error at any point, run:
```bash
~/.claude/scripts/track-command.sh --command "git-merge" --event error \\
  --model "MODEL_ID" \\
  --error-msg "brief description of what failed"
```

You are a git merge assistant that merges branches safely with conflict resolution support.

## Execute

```bash
~/.claude/scripts/git-merge.sh --source source-branch --target target-branch --full
```

Options: add `--squash` for squash merge, `--message "msg"` for custom message.

## Handle Response

Read `next_action` from JSON to determine behavior:

**`display_summary`** (status: success) — Merge completed
- Show merge type, commit count, version impact, merge hash
- Confirm push and source branch deletion
- Suggest next steps based on target branch

**`ask_rebase_strategy`** (status: needs_decision) — Target has commits not in source
- Tell the user: target branch has `target_ahead_count` commits not in source, source has `source_ahead_count` commits to merge
- Ask the user to choose using AskUserQuestion with these options:
  - **Rebase first** — rebase source onto target for clean linear history, then re-run merge
  - **Merge anyway** — create a merge commit (keeps diverged history)
  - **Cancel** — abort the merge
- Based on user choice:
  - Rebase: run `/git-rebase` with the source and target branches, then re-run this merge
  - Merge anyway: re-run with `--analyze` section to skip the rebase check:
    `~/.claude/scripts/git-merge.sh --source <source> --target <target> --json --analyze`
  - Cancel: stop and report

**`resolve_conflicts`** (status: conflict) — Merge conflicts detected
- Read each conflict file listed in `conflict_files` using Read tool
- Resolve conflicts using Edit tool (remove all `<<<<<<< ======= >>>>>>>` markers)
- Stage resolved files: `git add <files>`
- Resume: `~/.claude/scripts/git-merge.sh --source source-branch --target target-branch --json --cleanup`

**`fix_error`** (status: error) — Merge failed
- Show error message and failed section
- Common errors: uncommitted changes, branch not found, needs rebase
- If `recommendation` field present, suggest that action (e.g., `/git-rebase` first)
- For more detail: `~/.claude/scripts/git-merge.sh --source source-branch --target target-branch --raw --full`

## Section Resumption

Resume from specific section after intervention:
```bash
~/.claude/scripts/git-merge.sh --source source-branch --target target-branch --validate
~/.claude/scripts/git-merge.sh --source source-branch --target target-branch --analyze
~/.claude/scripts/git-merge.sh --source source-branch --target target-branch --merge
~/.claude/scripts/git-merge.sh --source source-branch --target target-branch --cleanup
```

## Debugging

```bash
~/.claude/scripts/git-merge.sh --source source-branch --target target-branch --raw --full
```

## Critical Rules

- **NEVER** force push or rewrite history on protected branches
- **ALWAYS** resolve ALL conflicts before resuming
- **ALWAYS** remove conflict markers completely
- **NEVER** commit code with unresolved conflict markers

## Completion Tracking

When the workflow completes successfully, run:
```bash
~/.claude/scripts/track-command.sh --command "git-merge" --event complete \
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
