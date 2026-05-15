---
name: db-backup-verify
description: Verify database backup integrity and test restoration procedures
user_invocable: true
---

## Tracking

> Output format is auto-detected (TOON for AI callers, JSON for CI/scripts). Use `--toon` or `--json` to override.

As your **first action**, before any other work, run:
```bash
~/.claude/scripts/track-command.sh --command "db-backup-verify" --event start
```

If the workflow encounters an unrecoverable error at any point, run:
```bash
~/.claude/scripts/track-command.sh --command "db-backup-verify" --event error \\
  --model "MODEL_ID" \\
  --error-msg "brief description of what failed"
```

Verify backup file integrity, check retention policy compliance, and optionally test restore procedures.

## Execute

```bash
~/.claude/scripts/db-backup-verify.sh --full
```

## Handle Response

Read `next_action` from the JSON result and respond accordingly.

- `display_summary` — Verification complete. Report: backup count, latest backup file, checks passed/failed (readable, size, compression, SQL syntax, age). Report retention compliance (old backup count vs retention days). If any checks failed, highlight them and suggest corrective action.
- `fix_error` — Verification failed. Show the section and error details. Common causes: backup directory not configured in PROJECT.yaml, directory does not exist, or backup file is corrupted. For corrupted backups, advise running a fresh backup immediately.

## Section Flags

Run individual sections when needed:

```bash
# Load and validate config only
~/.claude/scripts/db-backup-verify.sh --config

# List available backups
~/.claude/scripts/db-backup-verify.sh --list

# Verify latest backup integrity
~/.claude/scripts/db-backup-verify.sh --verify

# Test actual restore to a temporary database
~/.claude/scripts/db-backup-verify.sh --test-restore

# Check retention policy compliance
~/.claude/scripts/db-backup-verify.sh --retention
```

## Debug

```bash
~/.claude/scripts/db-backup-verify.sh --raw --full
```

## Completion Tracking

When the workflow completes successfully, run:
```bash
~/.claude/scripts/track-command.sh --command "db-backup-verify" --event complete \
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
