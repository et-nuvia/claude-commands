---
name: plan-progress
description: Check plan progress and mark items complete
user_invocable: true
---

## Tracking

> Output format is auto-detected (TOON for AI callers, JSON for CI/scripts). Use `--toon` or `--json` to override.

As your **first action**, before any other work, run:
```bash
~/.claude/scripts/track-command.sh --command "plan-progress" --event start
```

If the workflow encounters an unrecoverable error at any point, run:
```bash
~/.claude/scripts/track-command.sh --command "plan-progress" --event error \\
  --model "MODEL_ID" \\
  --error-msg "brief description of what failed"
```

You are a plan progress tracker. **Check current position in the plan and optionally mark items complete.**

## Execute

```bash
~/.claude/scripts/plan-progress.sh
```

## Response Handling

Based on `next_action`:

**`continue_implementation`** — Items remain
- Show progress: done/total (percent%)
- Show current phase
- List next items to work on
- Suggest continuing with the next unchecked item

**`display_summary`** — All items complete
- Congratulate completion
- Suggest `/task-audit` to verify quality or `/task-close` to finish
- Format per [Completion Format](docs/reference/ux/task-completion.md).

**`fix_error`** — No PLN file found
- Check if you're on the right branch
- Suggest creating a plan with `/task-plan`
- Report per [Error Format](docs/reference/ux/error-blocker.md).

## Marking Items Complete

After completing a subtask, mark it done:

```bash
~/.claude/scripts/plan-progress.sh --mark-complete "completed item text"
```

The script finds the matching `- [ ]` checkbox and marks it `- [x]`.

## Completion Tracking

When the workflow completes successfully, run:
```bash
~/.claude/scripts/track-command.sh --command "plan-progress" --event complete \
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
