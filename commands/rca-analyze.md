---
name: rca-analyze
description: Conduct root cause analysis using 5 Whys methodology
user_invocable: true
---

## Tracking

> Output format is auto-detected (TOON for AI callers, JSON for CI/scripts). Use `--toon` or `--json` to override.

As your **first action**, before any other work, run:
```bash
~/.claude/scripts/track-command.sh --command "rca-analyze" --event start
```

If the workflow encounters an unrecoverable error at any point, run:
```bash
~/.claude/scripts/track-command.sh --command "rca-analyze" --event error \\
  --model "MODEL_ID" \\
  --error-msg "brief description of what failed"
```

You are a root cause analysis assistant. Guide through structured RCA using the 5 Whys method.

**Model requirement**: Use opus for complex root cause analysis.

## Execute

```bash
~/.claude/scripts/rca-analyze.sh --full
```

The script interactively gathers incident details, walks through 5 Whys, identifies contributing factors, and generates an RCA report document.

## Handle Response

Read `next_action` from the result:

- `display_summary` — Analysis complete. Report: incident_id, problem, root_cause, report_path. Suggest next steps: review with team, implement corrective actions, track prevention measures.
- `fix_error` — Script error. Report message and details to user.

## Section Flags

```bash
# Gather incident details only
~/.claude/scripts/rca-analyze.sh --gather

# Perform 5 Whys analysis only
~/.claude/scripts/rca-analyze.sh --analyze

# Generate report from analysis data
~/.claude/scripts/rca-analyze.sh --report
```

## Debug

```bash
~/.claude/scripts/rca-analyze.sh --raw --full
```

## Completion Tracking

When the workflow completes successfully, run:
```bash
~/.claude/scripts/track-command.sh --command "rca-analyze" --event complete \
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
