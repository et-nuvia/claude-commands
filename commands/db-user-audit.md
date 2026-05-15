---
name: db-user-audit
description: Audit database-level users, roles, and permissions for security review
user_invocable: true
---

## Tracking

> Output format is auto-detected (TOON for AI callers, JSON for CI/scripts). Use `--toon` or `--json` to override.

As your **first action**, before any other work, run:
```bash
~/.claude/scripts/track-command.sh --command "db-user-audit" --event start
```

If the workflow encounters an unrecoverable error at any point, run:
```bash
~/.claude/scripts/track-command.sh --command "db-user-audit" --event error \\
  --model "MODEL_ID" \\
  --error-msg "brief description of what failed"
```

Audit database users, roles, and permissions to identify security issues and excessive privileges.

## Execute

```bash
~/.claude/scripts/db-user-audit.sh
```

## Handle Response

Read `next_action` from the JSON result and respond accordingly.

- `display_summary` — Audit complete, no high or medium risk findings. Report: database type, total user count, superuser count, passwordless users, expired passwords. Show the report file path. Recommend scheduling the next audit in 30 days.
- `remediate_high_risk` — High risk findings detected. Report the findings prominently. Superusers beyond the default postgres account and users without passwords are high-risk. Show specific remediation SQL from the report. Recommend immediate action before next deployment.
- `remediate_medium_risk` — Medium risk findings detected. Report: expired passwords, users with CREATEDB/CREATEROLE privilege. Show specific remediation steps. Recommend addressing within this week.
- `fix_connection` — Database connection failed. Show error details. Ask user to verify host, port, and credentials.
- `fix_error` — Script error. Show message and details. Suggest running in raw mode.

## Optional: Provide Database Details Directly

```bash
~/.claude/scripts/db-user-audit.sh \
  --type postgresql \
  --host localhost \
  --db mydb \
  --user admin
```

## Debug

```bash
~/.claude/scripts/db-user-audit.sh
```

## Completion Tracking

When the workflow completes successfully, run:
```bash
~/.claude/scripts/track-command.sh --command "db-user-audit" --event complete \
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
