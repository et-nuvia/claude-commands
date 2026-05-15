---
name: db-upgrade
description: Plan and execute database major version upgrades safely
user_invocable: true
---

## Tracking

> Output format is auto-detected (TOON for AI callers, JSON for CI/scripts). Use `--toon` or `--json` to override.

As your **first action**, before any other work, run:
```bash
~/.claude/scripts/track-command.sh --command "db-upgrade" --event start
```

If the workflow encounters an unrecoverable error at any point, run:
```bash
~/.claude/scripts/track-command.sh --command "db-upgrade" --event error \\
  --model "MODEL_ID" \\
  --error-msg "brief description of what failed"
```

Generate a comprehensive upgrade plan for a database major version change.

**Model**: Use opus for complex upgrade planning and risk assessment.

## Execute

```bash
~/.claude/scripts/db-upgrade.sh --full
```

## Handle Response

Read `next_action` from the JSON result and respond accordingly.

- `display_summary` — Plan generated. Report: database type, current/target versions, strategy, estimated downtime. List generated files (plan doc, upgrade scripts). Remind the user to test in staging first.
- `provide_target_version` — Script needs a target version. Show the current major version and available target versions from the result. Ask the user which version to upgrade to, then re-run: `~/.claude/scripts/db-upgrade.sh --json --full --target-version 16`
- `provide_strategy` — Script needs an upgrade strategy. Present the available strategies from the result: `pg_upgrade` (fast, in-place, brief downtime), `dump_restore` (flexible, longer downtime), `logical_replication` (zero downtime, complex), `blue_green` (zero downtime, needs duplicate infra). Ask the user which to use, then re-run: `~/.claude/scripts/db-upgrade.sh --json --full --target-version 16 --strategy pg_upgrade`
- `configure_database` — No database config found. Ask the user to add `database.type`, `database.connection.host/database/user` to PROJECT.yaml.
- `fix_connection` — Connection failed. Show the error. Ask user to verify credentials and network access.
- `fix_error` — Script error. Show message and details. Suggest running in raw mode.

## Section Flags

Run individual sections when needed:

```bash
# Detect current version only
~/.claude/scripts/db-upgrade.sh --detect

# Check breaking changes for a target version
~/.claude/scripts/db-upgrade.sh --breaking-changes --target-version 16

# Estimate size and downtime only
~/.claude/scripts/db-upgrade.sh --estimate
```

## Debug

```bash
~/.claude/scripts/db-upgrade.sh --raw --full
```

## Completion Tracking

When the workflow completes successfully, run:
```bash
~/.claude/scripts/track-command.sh --command "db-upgrade" --event complete \
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
