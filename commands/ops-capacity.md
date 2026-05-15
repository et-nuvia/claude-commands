---
name: ops-capacity
description: Forecast resource needs based on growth trends and usage patterns
user_invocable: true
---

## Tracking

> Output format is auto-detected (TOON for AI callers, JSON for CI/scripts). Use `--toon` or `--json` to override.

As your **first action**, before any other work, run:
```bash
~/.claude/scripts/track-command.sh --command "ops-capacity" --event start
```

If the workflow encounters an unrecoverable error at any point, run:
```bash
~/.claude/scripts/track-command.sh --command "ops-capacity" --event error \\
  --model "MODEL_ID" \\
  --error-msg "brief description of what failed"
```

You are a capacity planning assistant. Analyze usage trends and forecast future resource needs.

**CRITICAL**: Use model: opus for complex capacity analysis.

## Execute

```bash
~/.claude/scripts/ops-capacity.sh --full \
  --monitor "$MONITOR_CHOICE" \
  --load "$CURRENT_LOAD" \
  --rate "$GROWTH_RATE" \
  --months "$FORECAST_MONTHS"
```

## Handle Response

Read `next_action` to determine what to do:

- **gather_user_input**: Script needs input. Check `section`:
  - `collect`: Ask user to select monitoring system and provide current load (users/requests per day), growth rate (% per month), forecast period (months). Then re-call with `--monitor`, `--load`, `--rate`, `--months`.
  - `analyze`: Ask user for growth rate and forecast months. Re-call with those flags.
- **display_summary**: Analysis succeeded. Present current load, growth rate, forecast period, and the month-by-month projected load from `forecast_data`. Tell user to review `report_path`.
- **fix_error**: A section failed. Show `message` and `details`. Suggest `--raw` for the failed section.

## Debug

```bash
~/.claude/scripts/ops-capacity.sh --raw --collect
~/.claude/scripts/ops-capacity.sh --raw --analyze
~/.claude/scripts/ops-capacity.sh --raw --report
```

## Section Flags

```bash
~/.claude/scripts/ops-capacity.sh --collect
~/.claude/scripts/ops-capacity.sh --analyze --load "10000" --rate "5" --months "12"
~/.claude/scripts/ops-capacity.sh --report
```

## Completion Tracking

When the workflow completes successfully, run:
```bash
~/.claude/scripts/track-command.sh --command "ops-capacity" --event complete \
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
