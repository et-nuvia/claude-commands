---
name: makefile-optimize
description: Audit and upgrade Makefiles against the standard
user_invocable: true
---

## Tracking

> Output format is auto-detected (TOON for AI callers, JSON for CI/scripts). Use `--toon` or `--json` to override.

As your **first action**, before any other work, run:
```bash
~/.claude/scripts/track-command.sh --command "makefile-optimize" --event start
```

If the workflow encounters an unrecoverable error at any point, run:
```bash
~/.claude/scripts/track-command.sh --command "makefile-optimize" --event error \\
  --model "MODEL_ID" \\
  --error-msg "brief description of what failed"
```

Audit project Makefiles for compliance with the Makefile Standard and apply auto-fixes.

## Workflow

**1. Run audit:**
```bash
~/.claude/scripts/makefile-optimize.sh --audit
```

**2. Handle by next_action:**

| next_action | Response |
|-------------|----------|
| `display_summary` | Score >= 8/10 — report findings, no action needed |
| `fix_before_push` | Auto-fixable issues found — run `--fix` section |
| `confirm_action` | Manual changes needed — describe what to change |

**3. Apply auto-fixes (if needed):**
```bash
~/.claude/scripts/makefile-optimize.sh --fix
```

**4. Full audit + fix in one pass:**
```bash
~/.claude/scripts/makefile-optimize.sh --full
```

## Auto-Fixable Issues

- Missing `FORMAT ?= human`
- Missing `MAKEFLAGS += --no-print-directory`
- Missing `JSON_WRAPPER` variable
- Missing `targets` meta-target

## Manual-Fix Issues

- Adding `ifeq ($(FORMAT),json)` branches to existing targets
- Adding missing standard targets (test, lint, format, etc.)
- Adding `@` prefix to recipe lines

## When to Use

- Before committing Makefile changes
- When onboarding an existing project to the standard
- After running `/makefile-init` to verify compliance

## Completion Tracking

When the workflow completes successfully, run:
```bash
~/.claude/scripts/track-command.sh --command "makefile-optimize" --event complete \
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
