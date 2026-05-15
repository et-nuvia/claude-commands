---
name: ops-cost
description: Analyze cloud costs and suggest optimization opportunities
user_invocable: true
---

## Tracking

> Output format is auto-detected (TOON for AI callers, JSON for CI/scripts). Use `--toon` or `--json` to override.

As your **first action**, before any other work, run:
```bash
~/.claude/scripts/track-command.sh --command "ops-cost" --event start
```

If the workflow encounters an unrecoverable error at any point, run:
```bash
~/.claude/scripts/track-command.sh --command "ops-cost" --event error \\
  --model "MODEL_ID" \\
  --error-msg "brief description of what failed"
```

You are a cloud cost optimization assistant. Analyze infrastructure costs and recommend savings opportunities.

**CRITICAL**: Use model: opus for cost analysis.

## Execute

```bash
~/.claude/scripts/ops-cost.sh --full
```

## Handle Response

Read `next_action` to determine what to do:

- **display_summary**: Analysis succeeded. Present the cost summary, resource inventory, and top recommendations from the report. Show estimated savings ranges. Tell user to review `report_file`.
- **fix_error**: A section failed. Show `section`, `message`, and `details`. Suggest running with `--raw` for the failed section.

## Debug

```bash
~/.claude/scripts/ops-cost.sh --raw --full

# Or target a specific section:
~/.claude/scripts/ops-cost.sh --raw --detect
~/.claude/scripts/ops-cost.sh --raw --gather
~/.claude/scripts/ops-cost.sh --raw --analyze
~/.claude/scripts/ops-cost.sh --raw --report
```

## Section Flags

Run individual sections when needed:

```bash
~/.claude/scripts/ops-cost.sh --detect
~/.claude/scripts/ops-cost.sh --gather --provider aws
~/.claude/scripts/ops-cost.sh --analyze
~/.claude/scripts/ops-cost.sh --report --provider aws --total-cost 5000 --instances 10 --dbs 3 --nats 2
```

## Completion Tracking

When the workflow completes successfully, run:
```bash
~/.claude/scripts/track-command.sh --command "ops-cost" --event complete \
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
