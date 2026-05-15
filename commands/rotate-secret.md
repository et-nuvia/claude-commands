---
name: rotate-secret
description: Manage secret rotation with automated reminders and guided workflows
user_invocable: true
---

## Tracking

> Output format is auto-detected (TOON for AI callers, JSON for CI/scripts). Use `--toon` or `--json` to override.

As your **first action**, before any other work, run:
```bash
~/.claude/scripts/track-command.sh --command "rotate-secret" --event start
```

If the workflow encounters an unrecoverable error at any point, run:
```bash
~/.claude/scripts/track-command.sh --command "rotate-secret" --event error \\
  --model "MODEL_ID" \\
  --error-msg "brief description of what failed"
```

Check rotation status, view schedules, and guide through secret rotation workflows.

## Execute

```bash
# Parse user intent from $ARGUMENTS:
# "status" → --status
# "schedule" → --schedule
# "rotate <bucket>" → --rotate <bucket>
# "setup-reminders" → --setup-reminders
~/.claude/scripts/rotate-secret.sh --status
```

## Response Handling

Read `next_action` from the JSON response and act accordingly:

**next_action: display_summary** — Status or schedule retrieved. For `--status`: show `due[]` (overdue, need immediate action), `approaching[]` (due within warning period), `up_to_date[]`. For `--schedule`: show each bucket's frequency, strategy, last rotated, and next due date.

**next_action: guide_rotation** — Script returns `intervention` status for rotate/setup actions. Use `bucket` and the strategy from PROJECT.yaml to guide the rotation:
- **database** (two-step): generate password → update DB user → update secret → wait for refresh → verify
- **api-key**: guide to provider dashboard → wait for new key → update secret → revoke old key
- **jwt** (dual-key): generate new secret → update with both old+new → wait TTL → remove old
- **manual**: document current value → show provider steps → wait → update → test

After rotation, update `~/.claude/rotation-history.json` with timestamp for the bucket.

**next_action: fix_error** — Show `message` and `details`. Common causes: PROJECT.yaml missing, `secrets.rotation.enabled` not set to true.

## Section Flags

- `--status` — check which secrets need rotation
- `--schedule` — show rotation schedule from PROJECT.yaml
- `--rotate <bucket>` — guide through rotating a specific secret
- `--setup-reminders` — create cron/CI reminder for daily rotation checks

## Debug

```bash
~/.claude/scripts/rotate-secret.sh --raw --status
```

## Completion Tracking

When the workflow completes successfully, run:
```bash
~/.claude/scripts/track-command.sh --command "rotate-secret" --event complete \
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
