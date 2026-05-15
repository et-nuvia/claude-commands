---
name: git-commit
description: Analyze and commit changes following conventional commits with single-purpose commits
user_invocable: true
---

## Tracking

> Output format is auto-detected (TOON for AI callers, JSON for CI/scripts). Use `--toon` or `--json` to override.

As your **first action**, before any other work, run:
```bash
~/.claude/scripts/track-command.sh --command "git-commit" --event start
```

If the workflow encounters an unrecoverable error at any point, run:
```bash
~/.claude/scripts/track-command.sh --command "git-commit" --event error \\
  --model "MODEL_ID" \\
  --error-msg "brief description of what failed"
```

Analyze git state, categorize changes by purpose, group into logical commits, get user approval, and execute. Every commit needs a title and body. Never include "Co-Authored-By: Claude" or AI attribution.

User instructions: `$ARGUMENTS`

## Step 1: Analyze Summary

```bash
~/.claude/scripts/git-commit.sh --analyze
```

Returns file lists, diff stats, recent commits, and `diff_pages` count.

## Step 2: Fetch Diffs

Call `--analyze-diffs` for each page (1 through `diff_pages`). Run pages in parallel when possible:

```bash
~/.claude/scripts/git-commit.sh --analyze-diffs --page 1
~/.claude/scripts/git-commit.sh --analyze-diffs --page 2
```

Each page returns `file_diffs` array with full diffs per file (no truncation).

## Step 3: Plan Commits

Using the diffs from all pages:

1. Group changes into single-purpose commits — split files serving different purposes
2. Match recent commit style from `recent_commits`
3. Draft a commit plan — each commit needs `title` + `body` + `files` array
4. Present the plan as a **table + bodies** and ask for approval using AskUserQuestion

### Presentation Format

Show a table with columns `#`, `Title`, `Files`, `+/-`, then bodies below with `▎` prefix:

```
Commit Plan

  ┌─────┬──────────────────────────────────────────────┬──────────────────────────────────┬─────────┐
  │  #  │                    Title                     │              Files               │   +/-   │
  ├─────┼──────────────────────────────────────────────┼──────────────────────────────────┼─────────┤
  │ 1   │ fix(scope): short description                │ path/to/file.sh                  │ +3/-10  │
  │ 2   │ feat(scope): another change                  │ file-a.sh, file-b.sh             │ +45/-0  │
  └─────┴──────────────────────────────────────────────┴──────────────────────────────────┴─────────┘

  1 ▎ Why this fix is needed. Wrap at 72 chars.
    ▎ Second line of body.

  2 ▎ Why this feature was added.
```

See [Commit Confirmation](docs/reference/ux/commit-confirmation.md) for full rules.

### Title format: `type(scope): description`

**Type** — pick by what the change DOES, not where it lives:
- `feat` — new capability that didn't exist before
- `fix` — corrects wrong behavior
- `refactor` — restructures code without changing behavior
- `test` — adds or updates tests only
- `docs` — documentation only
- `chore` — maintenance (deps, CI, config, tooling)
- `perf` — performance improvement

**Scope** — the component or area affected (e.g., `api`, `auth`, `commands`, `scripts`, `ui`)

**Description** — imperative mood, lowercase, no period, max 50 chars total title. Describe WHAT changed, not HOW.

### Body — explain WHY (wrap at 72 chars)

## Step 4: Execute

After user approves, save the plan and execute. Each commit object must have `title`, `body`, and `files`:

```bash
echo '{"commits":[{"title":"...","body":"...","files":["a.sh","b.sh"]}]}' > /tmp/git-commit-plan.json
~/.claude/scripts/git-commit.sh --execute --plan-file /tmp/git-commit-plan.json
```

## Handle Responses

**display_summary** (execute complete) — Report total commits created with hashes and titles. Note any remaining uncommitted changes.

**fix_failed_commits** — Some commits failed. Report per [Error Format](docs/reference/ux/error-blocker.md). If a pre-commit hook failed, fix the issue and create a NEW commit (never amend).

**fix_error** — Script error. Report per [Error Format](docs/reference/ux/error-blocker.md). Try the debug block.

## Debug

```bash
~/.claude/scripts/git-commit.sh --raw --analyze
~/.claude/scripts/git-commit.sh --raw --analyze-diffs --page 1
~/.claude/scripts/git-commit.sh --raw --execute --plan-file /tmp/git-commit-plan.json
```

## Completion Tracking

When the workflow completes successfully, run:
```bash
~/.claude/scripts/track-command.sh --command "git-commit" --event complete \
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
