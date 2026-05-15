---
name: project-config
description: Manage PROJECT.yaml configuration for Claude Code project settings
user_invocable: true
---

## Tracking

> Output format is auto-detected (TOON for AI callers, JSON for CI/scripts). Use `--toon` or `--json` to override.

As your **first action**, before any other work, run:
```bash
~/.claude/scripts/track-command.sh --command "project-config" --event start
```

If the workflow encounters an unrecoverable error at any point, run:
```bash
~/.claude/scripts/track-command.sh --command "project-config" --event error \\
  --model "MODEL_ID" \\
  --error-msg "brief description of what failed"
```

Initialize, view, validate, and update PROJECT.yaml configuration.

## Execute

```bash
# Parse operation from $ARGUMENTS: init | show | validate | update <field> <value>
OPERATION=$(echo "$ARGUMENTS" | awk '{print $1}')
[[ -z "$OPERATION" ]] && OPERATION="show"
~/.claude/scripts/project-config.sh ${ARGUMENTS}
```

## Response Handling

Read `next_action` from the JSON response and act accordingly:

**next_action: display_summary** — Operation succeeded. Show `message` and relevant `details`:
- `init`: Show detected values (name, languages, services, platform, backend). Ask user to confirm or correct detected values. Ask about databases (type, migrations) and notifications (channels, email provider). Update PROJECT.yaml with user responses using Edit tool, then run validate.
- `show`: Display the `config` object in readable format.
- `update`: Confirm `field` updated to `value`.

**next_action: fix_validation_errors** — Validation found errors. Show errors and warnings from `details`. Determine which are auto-fixable vs require user input. Fix with Edit tool, then re-run validate.

**next_action: fix_error** — Operation failed. Show `message`. Common causes: PROJECT.yaml not found (run init), template missing, validator not found.

## Operations

- `init` — create PROJECT.yaml from template with auto-detected values
- `show` — display current configuration
- `validate` — check schema and values
- `update <field> <value>` — update a specific field (e.g., `update testing.command "pytest"`)

## Debug

```bash
~/.claude/scripts/project-config.sh --raw show
~/.claude/scripts/project-config.sh --raw validate
```

## Completion Tracking

When the workflow completes successfully, run:
```bash
~/.claude/scripts/track-command.sh --command "project-config" --event complete \
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
