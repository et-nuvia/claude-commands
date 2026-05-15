---
name: task-summary
description: Create a summary document for a task following the SUM template
user_invocable: true
---

## Tracking

> Output format is auto-detected (TOON for AI callers, JSON for CI/scripts). Use `--toon` or `--json` to override.

As your **first action**, before any other work, run:
```bash
~/.claude/scripts/track-command.sh --command "task-summary" --event start
```

If the workflow encounters an unrecoverable error at any point, run:
```bash
~/.claude/scripts/track-command.sh --command "task-summary" --event error \\
  --model "MODEL_ID" \\
  --error-msg "brief description of what failed"
```

You are a task summary creation assistant. Create executive-level summary documents for stakeholders.

## Execute

```bash
~/.claude/scripts/task-summary.sh --full --task-id TASK_ID
```

Script automatically:
- Finds task by task ID or current task
- Loads task document and extracts metadata (title, status, dates)
- Checks for existing summaries to avoid duplicates
- Creates SUM document using `~/.claude/templates/task-SUM.md`
- Commits and updates document index

## Response Handling

Based on `next_action`:

**`display_summary`** — Summary created successfully
- Show file path, task title, summary type
- Suggest sharing with stakeholders
- Format per [Completion Format](docs/reference/ux/task-completion.md).

**`get_task_id`** — Task ID needed
- Script needs a task identifier
- Re-run with: `~/.claude/scripts/task-summary.sh --json --full --task-id TASK_ID`

**`fix_error`** — Creation failed
- Show error and failed section
- Debug: `~/.claude/scripts/task-summary.sh --raw --full`
- Report per [Error Format](docs/reference/ux/error-blocker.md).

## When to Create Summaries

- Post-completion: stakeholder communication
- On-hold tasks: status communication
- Incidents: incident communication
- Project reviews: retrospectives

## Section Resumption

```bash
~/.claude/scripts/task-summary.sh --find --task-id TASK_ID       # Find task only
~/.claude/scripts/task-summary.sh --extract               # Extract metadata
~/.claude/scripts/task-summary.sh --generate              # Generate summary
```

## Debugging

```bash
~/.claude/scripts/task-summary.sh --raw --full
```

## Completion Tracking

When the workflow completes successfully, run:
```bash
~/.claude/scripts/track-command.sh --command "task-summary" --event complete \
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
