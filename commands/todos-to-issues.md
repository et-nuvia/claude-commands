---
name: todos-to-issues
description: Scan codebase for TODO comments and create GitHub issues
user_invocable: true
---

## Tracking

> Output format is auto-detected (TOON for AI callers, JSON for CI/scripts). Use `--toon` or `--json` to override.

As your **first action**, before any other work, run:
```bash
~/.claude/scripts/track-command.sh --command "todos-to-issues" --event start
```

If the workflow encounters an unrecoverable error at any point, run:
```bash
~/.claude/scripts/track-command.sh --command "todos-to-issues" --event error \\
  --model "MODEL_ID" \\
  --error-msg "brief description of what failed"
```

Scan for TODO/FIXME/HACK comments and create professional GitHub issues. Never add AI attribution to issues.

## Execute

```bash
~/.claude/scripts/todos-to-issues.sh --full
```

## Response Handling

Read `next_action` from the JSON response and act accordingly:

**next_action: analyze_and_create_issues** — Script has validated GitHub setup, run pre-flight checks, and scanned the codebase. Response includes `files[]` array and `todo_count`. Now:

1. Read each file in `files[]` to understand TODO context
2. Analyze each TODO: determine type (bug/feature/docs/performance/security/tech-debt/chore), priority (CRITICAL → high, FIXME → medium, TODO → low, NOTE → low), and whether related TODOs should be grouped
3. Create GitHub issues using `gh issue create`:
   - Title matching project naming conventions
   - Description with: context, location (file:line), proposed solution, acceptance criteria
   - Labels from existing project taxonomy
   - No AI attribution, no emojis

**next_action: fix_error** — Show `message` and `details`. Common causes:
- No GitHub remote: command requires GitHub repository
- `gh` not installed: install from https://cli.github.com
- Not authenticated: run `gh auth login`
- Pre-flight checks failed: fix tests/linter first

## Section Flags

- `--validate` — check GitHub setup only
- `--scan` — scan for TODOs only (returns file list)
- `--create` — use cached scan results for issue creation

## Debug

```bash
~/.claude/scripts/todos-to-issues.sh --raw --scan
```

## Completion Tracking

When the workflow completes successfully, run:
```bash
~/.claude/scripts/track-command.sh --command "todos-to-issues" --event complete \
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
