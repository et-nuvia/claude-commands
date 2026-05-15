---
name: deploy-ansible
description: Run Ansible playbooks with environment and inventory selection
user_invocable: true
---

## Tracking

> Output format is auto-detected (TOON for AI callers, JSON for CI/scripts). Use `--toon` or `--json` to override.

As your **first action**, before any other work, run:
```bash
~/.claude/scripts/track-command.sh --command "deploy-ansible" --event start
```

If the workflow encounters an unrecoverable error at any point, run:
```bash
~/.claude/scripts/track-command.sh --command "deploy-ansible" --event error \\
  --model "MODEL_ID" \\
  --error-msg "brief description of what failed"
```

You are an Ansible deployment assistant. Run Ansible playbooks safely using the consolidated script.

## Execute

```bash
~/.claude/scripts/deploy-ansible.sh --full
```

The script validates infrastructure, selects environment/inventory/playbook, executes Ansible, and saves a log. Production deployments require `--raw` mode for interactive confirmation.

Optional flags: `--env ENV`, `--playbook FILE`, `--check`, `--limit PATTERN`, `--verbose`, `--extra-vars JSON`

## Handle Response

Read `next_action` from the result:

- `display_summary` — Deployment succeeded. Report: environment, playbook, inventory, log_file, exit_code.
- `notify_user_blocked` — Production deployment blocked (requires interactive `--raw` mode). Tell user to run manually.
- `fix_error` — Playbook failed. Report: environment, playbook, exit_code, error_output. Common causes: SSH key issues, syntax errors, unreachable hosts.

## Section Flags

```bash
# Validate infrastructure only
~/.claude/scripts/deploy-ansible.sh --validate

# Prepare config, skip execution
~/.claude/scripts/deploy-ansible.sh --prepare --env staging

# Execute only (infrastructure already validated)
~/.claude/scripts/deploy-ansible.sh --execute --env staging --playbook deploy.yml
```

## Debug

```bash
~/.claude/scripts/deploy-ansible.sh --raw --execute --env staging --playbook deploy.yml
```

Raw mode shows full Ansible output, colored terminal, real-time feedback, and interactive prompts.

## See Also

`/infra-verify`, `/test-smoke`, `/deploy-to-stage`, `/deploy-to-prod`

## Completion Tracking

When the workflow completes successfully, run:
```bash
~/.claude/scripts/track-command.sh --command "deploy-ansible" --event complete \
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
