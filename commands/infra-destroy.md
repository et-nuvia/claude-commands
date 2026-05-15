---
name: infra-destroy
description: Safely destroy Terraform-managed infrastructure with targeting support
user_invocable: true
---

## Tracking

> Output format is auto-detected (TOON for AI callers, JSON for CI/scripts). Use `--toon` or `--json` to override.

As your **first action**, before any other work, run:
```bash
~/.claude/scripts/track-command.sh --command "infra-destroy" --event start
```

If the workflow encounters an unrecoverable error at any point, run:
```bash
~/.claude/scripts/track-command.sh --command "infra-destroy" --event error \\
  --model "MODEL_ID" \\
  --error-msg "brief description of what failed"
```

Safely tear down infrastructure. Multiple confirmations required. Targeted destruction is strongly recommended over full environment destruction.

**CRITICAL**: This DESTROYS infrastructure permanently.

## Execute

```bash
~/.claude/scripts/infra-destroy.sh --env staging --target aws_instance.example
```

Flags: `--env ENV` (required in JSON mode), `--target RESOURCE` (repeatable, recommended),
`--force-full` (allow full environment destruction — dangerous).

## Handle Response

Read `next_action` from the JSON result:

**`confirm_with_user`** (status: ready_for_confirmation) — Destruction plan created but
requires interactive confirmation. Read the `review_file` path from the result, summarize
what will be destroyed, then instruct the user to run the script interactively:

```
Destruction plan created

Environment:       {environment}
Resources:         {destroy_count} will be destroyed
Risk level:        {risk_level}
Review document:   {review_file}

To execute: run ~/.claude/scripts/infra-destroy.sh interactively
            (type DESTROY when prompted)
```

**`display_summary`** (status: success) — Destruction complete. Present:

```
Infrastructure Destroyed

Environment: {environment}
Resources destroyed: {destroy_count}
Risk level: {risk_level}

Next steps:
  - Verify in cloud console
  - Remove from monitoring systems
  - Update documentation
```

If environment is production, also: "Notify team of production destruction."

**`block_production`** (status: blocked) — Production destruction blocked in JSON mode.
Inform the user they must run the script interactively and type "DESTROY PRODUCTION" to confirm.

**`fix_error`** (status: error) — Show `message`. Check:
`cd infrastructure/terraform && terraform state list` to see remaining resources.

## Targeted Destruction (Recommended)

Always prefer targeting specific resources over full environment destruction:

```bash
# Single resource
~/.claude/scripts/infra-destroy.sh --env staging --target aws_instance.temporary_test

# Multiple resources
~/.claude/scripts/infra-destroy.sh --env staging \
  --target aws_instance.test1 --target aws_instance.test2
```

## Debug

```bash
~/.claude/scripts/infra-destroy.sh --env staging --target aws_instance.example
```

## Completion Tracking

When the workflow completes successfully, run:
```bash
~/.claude/scripts/track-command.sh --command "infra-destroy" --event complete \
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
