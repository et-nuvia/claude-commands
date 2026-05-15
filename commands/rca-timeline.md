---
name: rca-timeline
description: Create detailed incident timeline from logs and events
user_invocable: true
---

## Tracking

> Output format is auto-detected (TOON for AI callers, JSON for CI/scripts). Use `--toon` or `--json` to override.

As your **first action**, before any other work, run:
```bash
~/.claude/scripts/track-command.sh --command "rca-timeline" --event start
```

If the workflow encounters an unrecoverable error at any point, run:
```bash
~/.claude/scripts/track-command.sh --command "rca-timeline" --event error \\
  --model "MODEL_ID" \\
  --error-msg "brief description of what failed"
```

You are an incident timeline assistant. Reconstruct incident timeline from logs and events.

## Execute

Provide incident parameters if known, otherwise the script will request them:

```bash
~/.claude/scripts/rca-timeline.sh --full
```

The script gathers parameters, collects events from available sources (logs, deployments, alerts), and generates a timeline document.

## Handle Response

Read `next_action` from the result:

- `display_summary` — Timeline created. Report: incident_id, timeline_doc path, start_time to end_time. Suggest: review document, fill actual timestamps, create RCA with `/rca-analyze`.
- `gather_user_input` — Parameters missing. Ask user for: incident ID, start time (YYYY-MM-DD HH:MM), end time. Then re-run: `~/.claude/scripts/rca-timeline.sh --json --full --incident "INC-001" --start "2026-02-14 10:30" --end "2026-02-14 12:45"`
- `fix_error` — Script error. Report message and details.

## Section Flags

```bash
~/.claude/scripts/rca-timeline.sh --gather --incident "INC-001" --start "2026-02-14 10:30" --end "2026-02-14 12:45"
~/.claude/scripts/rca-timeline.sh --collect
~/.claude/scripts/rca-timeline.sh --generate
```

## Debug

```bash
~/.claude/scripts/rca-timeline.sh --raw --gather
~/.claude/scripts/rca-timeline.sh --raw --generate
```

## Completion Tracking

When the workflow completes successfully, run:
```bash
~/.claude/scripts/track-command.sh --command "rca-timeline" --event complete \
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
