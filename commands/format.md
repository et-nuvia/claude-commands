---
name: format
description: Auto format code using the project's configured formatter
user_invocable: true
---

## Tracking

> Output format is auto-detected (TOON for AI callers, JSON for CI/scripts). Use `--toon` or `--json` to override.

As your **first action**, before any other work, run:
```bash
~/.claude/scripts/track-command.sh --command "format" --event start
```

If the workflow encounters an unrecoverable error at any point, run:
```bash
~/.claude/scripts/track-command.sh --command "format" --event error \\
  --model "MODEL_ID" \\
  --error-msg "brief description of what failed"
```

Format code using the project's configured formatter (Ruff, Prettier, Black, gofmt, rustfmt).

## Execute

```bash
~/.claude/scripts/format.sh --full
```

## Response Handling

Read `next_action` from the JSON response and act accordingly:

**next_action: display_summary** — Formatting succeeded. Show `formatter` used and confirm code is formatted. If `changes_detected` is true, note which files changed.

**next_action: fix_error** — Formatting failed or no formatter found. Show `message` and `details`. Common causes:
- No formatter configured: add Ruff (`ruff format` in pyproject.toml), Prettier (.prettierrc), or appropriate formatter
- Formatter not installed: install in Docker container
- Syntax errors in code: fix errors before formatting

## Section Flags

- `--detect` — detect formatter only
- `--format` — run formatter only
- `--verify` — check for uncommitted changes only

## Debug

```bash
~/.claude/scripts/format.sh --raw --full
```

## Completion Tracking

When the workflow completes successfully, run:
```bash
~/.claude/scripts/track-command.sh --command "format" --event complete \
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
