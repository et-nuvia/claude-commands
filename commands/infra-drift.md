---
name: infra-drift
description: Detect Terraform configuration drift between code and actual infrastructure
user_invocable: true
---

## Tracking

> Output format is auto-detected (TOON for AI callers, JSON for CI/scripts). Use `--toon` or `--json` to override.

As your **first action**, before any other work, run:
```bash
~/.claude/scripts/track-command.sh --command "infra-drift" --event start
```

If the workflow encounters an unrecoverable error at any point, run:
```bash
~/.claude/scripts/track-command.sh --command "infra-drift" --event error \\
  --model "MODEL_ID" \\
  --error-msg "brief description of what failed"
```

Detect when actual infrastructure differs from Terraform code. Safe to run anytime (read-only).

## Execute

```bash
~/.claude/scripts/infra-drift.sh --full
```

Check a specific environment: append `--env=staging` (repeatable for multiple envs).

Section flags: `--validate`, `--check`, `--analyze`. For debug: add `--raw` instead of `--json`.

## Handle Response by next_action

**`display_summary`** (status: success) — No drift detected. Confirm environments checked and infrastructure matches code.

**`remediate_drift`** (status: drift_detected) — Drift found. For each entry in `drift_summary` where `status == "drift"`, present:

```
Drift in {environment}: {total} resources affected
  + {add} to create   ~ {update} to update
  r {replace} to replace   - {destroy} to destroy
  Report: {report}
```

Read each drift report file to understand the specific changes. Then recommend:
1. Review changes in cloud console to determine cause (manual change vs automation)
2. To restore code state: run `/infra-plan --env {env}` then `/infra-apply`
3. To accept the drift: update Terraform code to match actual infrastructure state

**`fix_error`** (status: error) — Setup problem. Show `message` and `details`.

## Debug

```bash
~/.claude/scripts/infra-drift.sh --raw --full
```

## Completion Tracking

When the workflow completes successfully, run:
```bash
~/.claude/scripts/track-command.sh --command "infra-drift" --event complete \
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
