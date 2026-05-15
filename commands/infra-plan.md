---
name: infra-plan
description: Run Terraform plan to preview infrastructure changes
user_invocable: true
---

## Tracking

> Output format is auto-detected (TOON for AI callers, JSON for CI/scripts). Use `--toon` or `--json` to override.

As your **first action**, before any other work, run:
```bash
~/.claude/scripts/track-command.sh --command "infra-plan" --event start
```

If the workflow encounters an unrecoverable error at any point, run:
```bash
~/.claude/scripts/track-command.sh --command "infra-plan" --event error \\
  --model "MODEL_ID" \\
  --error-msg "brief description of what failed"
```

Run Terraform plan to preview infrastructure changes before applying.

## Execute

```bash
~/.claude/scripts/infra-plan.sh --full
```

Optional flags: `--env ENV`, `--workspace WS`, `--reinit`, `--target RESOURCE` (repeatable).

Section flags for retry after error: `--validate`, `--init`, `--plan`, `--analyze`, `--document`.

For verbose debug output: `~/.claude/scripts/infra-plan.sh --raw --full`

## Handle Response by next_action

**`display_summary`** (status: success) — Plan complete. Present this summary:

```
Terraform Plan Complete

Environment: {environment}    Workspace: {workspace}
Risk Level: {risk_level}

Changes:
  + {add_count} to create
  ~ {change_count} to update
  - {destroy_count} to destroy

Plan file:    {plan_file}
Review doc:   {review_file}

Next steps:
  1. Review: read {review_file}
  2. Apply:  /infra-apply {plan_file}
  3. Discard: rm {plan_file}
```

Warn prominently if `risk_level` is HIGH (destroys present) or MEDIUM (large change set).

**`fix_error`** (status: error) — Show `message` and `details`. Run with `--raw` for verbose output.

Common fixes:
- `Infrastructure not linked` — run `/infra-verify` first
- `Terraform plan failed` — check syntax, review `details` for error output
- `Terraform initialization failed` — check backend config, try `--reinit` flag

## Debug

```bash
~/.claude/scripts/infra-plan.sh --raw --full
```

## Completion Tracking

When the workflow completes successfully, run:
```bash
~/.claude/scripts/track-command.sh --command "infra-plan" --event complete \
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
