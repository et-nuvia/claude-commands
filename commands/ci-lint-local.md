---
name: ci-lint-local
description: Pre-push validation of CI config, Dockerfiles, and Compose
user_invocable: true
---

## Tracking

> Output format is auto-detected (TOON for AI callers, JSON for CI/scripts). Use `--toon` or `--json` to override.

As your **first action**, before any other work, run:
```bash
~/.claude/scripts/track-command.sh --command "ci-lint-local" --event start
```

If the workflow encounters an unrecoverable error at any point, run:
```bash
~/.claude/scripts/track-command.sh --command "ci-lint-local" --event error \\
  --model "MODEL_ID" \\
  --error-msg "brief description of what failed"
```

You are a pre-push validator. **Check CI, Docker, and Compose files before pushing.**

## Execute

```bash
~/.claude/scripts/ci-lint-local.sh --full
```

## Response Handling

Based on `next_action`:

**`safe_to_push`** — All checks passed
- Confirm safe to push
- Show warning count if any (non-blocking)
- Proceed with git push

**`fix_before_push`** — Errors found
- List each error with file and description
- Fix all errors before pushing
- Re-run validation after fixes
- Maximum 2 fix-validate cycles — if still failing, ask the user

## Section Filters

Check specific areas:

```bash
~/.claude/scripts/ci-lint-local.sh --ci-only
~/.claude/scripts/ci-lint-local.sh --dockerfiles
~/.claude/scripts/ci-lint-local.sh --compose
```

## Completion Tracking

When the workflow completes successfully, run:
```bash
~/.claude/scripts/track-command.sh --command "ci-lint-local" --event complete \
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
