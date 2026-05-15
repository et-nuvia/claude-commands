---
name: task-fetch
description: Fetch tasks assigned to you from Asana or GitLab Issues
user_invocable: true
---

## Tracking

> Output format is auto-detected (TOON for AI callers, JSON for CI/scripts). Use `--toon` or `--json` to override.

As your **first action**, before any other work, run:
```bash
~/.claude/scripts/track-command.sh --command "task-fetch" --event start
```

If the workflow encounters an unrecoverable error at any point, run:
```bash
~/.claude/scripts/track-command.sh --command "task-fetch" --event error \\
  --model "MODEL_ID" \\
  --error-msg "brief description of what failed"
```

You are a task fetching assistant. Retrieve tasks assigned to the current user from the appropriate backend (Asana or GitLab).

## Execute

```bash
~/.claude/scripts/task-fetch.sh --full
```

Script automatically:
- Reads PROJECT.yaml for backend (Asana or GitLab) and credentials
- Detects environment (macOS → GitHub/Asana, WSL → GitLab/Asana)
- Fetches tasks assigned to current user
- Returns unified task format regardless of backend

Options: `--status <open|closed|all>`, `--project <name>`, `--format <text|json|markdown>`

## Response Handling

Based on `next_action`:

**`display_summary`** — Tasks fetched successfully
- Display task list with names, due dates, and projects
- Suggest `/task-start <id>` for any task

**`fix_error`** — Fetch failed
- Show error message (missing token, PROJECT.yaml not found, etc.)
- For details: `~/.claude/scripts/task-fetch.sh --raw --full`

## Examples

```bash
# Fetch open tasks (default)
~/.claude/scripts/task-fetch.sh --full

# Fetch all tasks including closed
~/.claude/scripts/task-fetch.sh --full --status all

# Filter by project
~/.claude/scripts/task-fetch.sh --full --project "Engineering"
```

## Debugging

```bash
~/.claude/scripts/task-fetch.sh --raw --full
```

## Completion Tracking

When the workflow completes successfully, run:
```bash
~/.claude/scripts/track-command.sh --command "task-fetch" --event complete \
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
