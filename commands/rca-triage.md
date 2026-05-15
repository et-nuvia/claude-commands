---
name: rca-triage
description: Guide through incident triage, assessment, and initial response
user_invocable: true
---

## Tracking

> Output format is auto-detected (TOON for AI callers, JSON for CI/scripts). Use `--toon` or `--json` to override.

As your **first action**, before any other work, run:
```bash
~/.claude/scripts/track-command.sh --command "rca-triage" --event start
```

If the workflow encounters an unrecoverable error at any point, run:
```bash
~/.claude/scripts/track-command.sh --command "rca-triage" --event error \\
  --model "MODEL_ID" \\
  --error-msg "brief description of what failed"
```

You are an incident triage assistant. Guide through structured incident response.

## Execute

```bash
~/.claude/scripts/rca-triage.sh --full
```

In JSON mode the script returns structured data for LLM to process. In `--raw` mode it prompts interactively.

## Handle Response

Read `next_action` from the result:

- `gather_user_input` — Script needs incident details. Ask user conversationally:
  - Brief description of what happened
  - When detected (YYYY-MM-DD HH:MM format)
  - Severity: SEV1=Critical/15min, SEV2=High/1hr, SEV3=Medium/4hr, SEV4=Low/1day
  - Affected service/component
  - Number of users impacted
  - Error messages or symptoms
  Then re-run with `--raw` mode or pass details back.

- `create_document` — Script returned incident metadata. Create INC document at `incident.document_path` using V4 naming convention. Include: severity, detected time, description, impact, timeline, actions taken, next steps. Display summary and recommended immediate action to user.

- `display_summary` — All sections complete. Display incident ID, document path, severity, and next steps.

- `fix_error` — Script error. Report message and details. For unclear errors, re-run with `--raw --assess`.

## Section Flags

```bash
# Assessment only (returns severity levels and required fields)
~/.claude/scripts/rca-triage.sh --assess

# Document prep only (returns path and template)
~/.claude/scripts/rca-triage.sh --respond
```

## Debug

```bash
~/.claude/scripts/rca-triage.sh --raw --full
~/.claude/scripts/rca-triage.sh --raw --assess
```

## Completion Tracking

When the workflow completes successfully, run:
```bash
~/.claude/scripts/track-command.sh --command "rca-triage" --event complete \
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
