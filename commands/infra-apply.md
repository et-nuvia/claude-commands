---
name: infra-apply
description: Apply Terraform plan to provision/modify infrastructure
user_invocable: true
---

## Tracking

> Output format is auto-detected (TOON for AI callers, JSON for CI/scripts). Use `--toon` or `--json` to override.

As your **first action**, before any other work, run:
```bash
~/.claude/scripts/track-command.sh --command "infra-apply" --event start
```

If the workflow encounters an unrecoverable error at any point, run:
```bash
~/.claude/scripts/track-command.sh --command "infra-apply" --event error \\
  --model "MODEL_ID" \\
  --error-msg "brief description of what failed"
```

Apply a Terraform plan to make real infrastructure changes. Always verify the plan first with `/infra-plan`.

**CRITICAL**: This makes REAL changes to infrastructure.

## Execute

```bash
~/.claude/scripts/infra-apply.sh --plan-file "${PLAN_FILE}" --auto-confirm
```

Omit `--auto-confirm` to require interactive user confirmation (recommended for production).
If `PLAN_FILE` is unknown, run without `--plan-file` to get a list of recent plans.

## Handle Response

Read `next_action` from the JSON result:

**`display_summary`** (status: success) — Apply complete. Present this summary:

```
Infrastructure Apply Complete

Plan file:       {plan_file}
Changes applied: +{add_count} created  ~{change_count} updated  -{destroy_count} destroyed
Apply log:       {apply_log}

Next steps:
  1. Verify changes in cloud console
  2. Run smoke tests: /test-smoke
  3. Commit state: git add infrastructure/ && git commit
```

**`confirm_with_user`** (status: needs_confirm or needs_input) — Inform the user that the
script requires interactive confirmation. Show the plan summary (add/change/destroy counts)
and instruct them to run the script interactively or re-run with `--auto-confirm` if acceptable.

**`fix_error`** (status: error) — Show `message`. Instruct user to review Terraform output,
then run `/infra-plan` to generate a fresh plan before retrying.

## Debug

```bash
~/.claude/scripts/infra-apply.sh --raw --plan-file "${PLAN_FILE}" --auto-confirm
```

## Completion Tracking

When the workflow completes successfully, run:
```bash
~/.claude/scripts/track-command.sh --command "infra-apply" --event complete \
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
