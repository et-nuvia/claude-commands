---
name: db-restore
description: Restore database from backup with safety checks and verification
user_invocable: true
---

## Tracking

> Output format is auto-detected (TOON for AI callers, JSON for CI/scripts). Use `--toon` or `--json` to override.

As your **first action**, before any other work, run:
```bash
~/.claude/scripts/track-command.sh --command "db-restore" --event start
```

If the workflow encounters an unrecoverable error at any point, run:
```bash
~/.claude/scripts/track-command.sh --command "db-restore" --event error \\
  --model "MODEL_ID" \\
  --error-msg "brief description of what failed"
```

Safely restore a database from backup with integrity verification and post-restore checks.

**Warning**: Database restore is destructive. The script requires safety confirmations.

## Execute

```bash
~/.claude/scripts/db-restore.sh --full
```

## Handle Response

Read `next_action` from the JSON result and respond accordingly.

- `display_summary` — Restore complete. Report: target database, tables restored, duration, invalid indexes. Show the report file path. List next steps (run ANALYZE, smoke tests, monitor performance).
- `provide_input` — Script needs user input. Check `section` in the result:
  - `detect`: Database config missing. Ask user to add `database.type`, `database.connection.*`, and `database.backup.directory` to PROJECT.yaml. Or run in raw mode for interactive prompts.
  - `restore`: Target database not specified. Ask the user: restore to a new test database (recommended and safest), create a new named database, or overwrite an existing database (destructive). Then re-run with `--target-db <name>` and optionally `--create-db`.
- `select_backup` — Multiple backups found. Show the list of recent backups from the result. Ask the user which backup to restore. Re-run with `--backup-file <path>`.
- `fix_backup_path` — No backups found. Verify the backup directory is configured correctly in PROJECT.yaml at `database.backup.directory`.
- `fix_connection` — Database connection failed. Show error details. Ask user to verify credentials.
- `fix_error` — Restore failed. Show message and details. Suggest running in raw mode for verbose output.

## Section Flags

Run individual sections when needed:

```bash
# Detect database config only
~/.claude/scripts/db-restore.sh --detect

# Verify a specific backup file
~/.claude/scripts/db-restore.sh --verify --backup-file /path/to/backup.dump

# Post-restore verification only
~/.claude/scripts/db-restore.sh --check
```

## Debug

```bash
~/.claude/scripts/db-restore.sh --raw --full
```

## Completion Tracking

When the workflow completes successfully, run:
```bash
~/.claude/scripts/track-command.sh --command "db-restore" --event complete \
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
