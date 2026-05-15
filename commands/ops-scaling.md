---
name: ops-scaling
description: Recommend horizontal vs vertical scaling strategy based on metrics
user_invocable: true
---

## Tracking

> Output format is auto-detected (TOON for AI callers, JSON for CI/scripts). Use `--toon` or `--json` to override.

As your **first action**, before any other work, run:
```bash
~/.claude/scripts/track-command.sh --command "ops-scaling" --event start
```

If the workflow encounters an unrecoverable error at any point, run:
```bash
~/.claude/scripts/track-command.sh --command "ops-scaling" --event error \\
  --model "MODEL_ID" \\
  --error-msg "brief description of what failed"
```

You are a scaling strategy assistant. Analyze system metrics and recommend horizontal (add instances) or vertical (upgrade size) scaling.

## Execute

For interactive use, the script prompts for CPU%, memory%, request rate, response time, and instance count:

```bash
~/.claude/scripts/ops-scaling.sh --raw --full
```

For programmatic use with known metrics:

```bash
~/.claude/scripts/ops-scaling.sh --full --cpu 85 --mem 70 --req-rate 500 --response-time 300 --instances 3
```

## Handle Response

Read `next_action` to determine what to do:

- **display_summary**: Analysis succeeded. Present `analysis.recommendation` (Horizontal or Vertical Scaling), `analysis.bottleneck`, `analysis.recommended_instances`. Tell user to review `report_path`.
- **fix_error**: Script failed. Show `message` and `details`. Run debug command below.

## Debug

```bash
~/.claude/scripts/ops-scaling.sh --raw --gather
```

## Section Flags

Run individual sections with optional metric flags: `--gather`, `--analyze`, `--report`. Metric flags: `--cpu`, `--mem`, `--req-rate`, `--response-time`, `--instances`.

## Completion Tracking

When the workflow completes successfully, run:
```bash
~/.claude/scripts/track-command.sh --command "ops-scaling" --event complete \
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
