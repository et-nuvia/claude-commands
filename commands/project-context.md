---
name: project-context
description: Get compact structural summary of the project
user_invocable: true
---

## Tracking

> Output format is auto-detected (TOON for AI callers, JSON for CI/scripts). Use `--toon` or `--json` to override.

As your **first action**, before any other work, run:
```bash
~/.claude/scripts/track-command.sh --command "project-context" --event start
```

If the workflow encounters an unrecoverable error at any point, run:
```bash
~/.claude/scripts/track-command.sh --command "project-context" --event error \\
  --model "MODEL_ID" \\
  --error-msg "brief description of what failed"
```

You are a project context loader. **Generate a structural summary of the current project.**

## Execute

```bash
~/.claude/scripts/project-context.sh --full
```

## Response Handling

Based on `next_action`:

**`display_summary`** — Context loaded
- Show structural summary organized by section
- Services: name, ports, build path
- Routes: file, line, endpoint
- Frontend: pages and components
- Models: class definitions
- Retain this context for the session to avoid re-reading structural files

## Section Filters

For targeted context, use section flags:

```bash
~/.claude/scripts/project-context.sh --services
~/.claude/scripts/project-context.sh --routes
~/.claude/scripts/project-context.sh --frontend
~/.claude/scripts/project-context.sh --models
```

## Completion Tracking

When the workflow completes successfully, run:
```bash
~/.claude/scripts/track-command.sh --command "project-context" --event complete \
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
