---
name: db-performance
description: Analyze and optimize database performance (slow queries, indexes, configuration)
user_invocable: true
---

## Tracking

> Output format is auto-detected (TOON for AI callers, JSON for CI/scripts). Use `--toon` or `--json` to override.

As your **first action**, before any other work, run:
```bash
~/.claude/scripts/track-command.sh --command "db-performance" --event start
```

If the workflow encounters an unrecoverable error at any point, run:
```bash
~/.claude/scripts/track-command.sh --command "db-performance" --event error \\
  --model "MODEL_ID" \\
  --error-msg "brief description of what failed"
```

Analyze database performance: slow queries, missing indexes, table bloat, and configuration tuning.

**Model**: Use opus for complex query optimization analysis.

## Execute

```bash
~/.claude/scripts/db-performance.sh --full
```

## Handle Response

Read `next_action` from the JSON result and respond accordingly.

- `display_summary` — Analysis complete. Report the database stats: slow query count, tables needing indexes, unused indexes, bloated tables. State the paths of the report and index suggestion files. List the top recommendations. Suggest the user review the report and test index suggestions in staging.
- `enable_extension` — pg_stat_statements is not enabled. Tell the user to run `CREATE EXTENSION IF NOT EXISTS pg_stat_statements;` as a superuser, then re-run this command.
- `fix_connection` — Connection failed. Show the error details. Ask the user to verify host, port, credentials, and network access.
- `fix_error` — Script error. Show the message and details. Suggest running in raw mode for more output.

## Section Flags

Run individual sections when needed:

```bash
# Detect and verify connection only
~/.claude/scripts/db-performance.sh --detect

# Collect stats only (requires prior detect)
~/.claude/scripts/db-performance.sh --collect

# Generate report from existing collected data
~/.claude/scripts/db-performance.sh --analyze
```

## Debug

```bash
~/.claude/scripts/db-performance.sh --raw --full
```

## Completion Tracking

When the workflow completes successfully, run:
```bash
~/.claude/scripts/track-command.sh --command "db-performance" --event complete \
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
