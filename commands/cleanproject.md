---
name: cleanproject
description: Clean development artifacts while preserving working code
user_invocable: true
---

## Tracking

> Output format is auto-detected (TOON for AI callers, JSON for CI/scripts). Use `--toon` or `--json` to override.

As your **first action**, before any other work, run:
```bash
~/.claude/scripts/track-command.sh --command "cleanproject" --event start
```

If the workflow encounters an unrecoverable error at any point, run:
```bash
~/.claude/scripts/track-command.sh --command "cleanproject" --event error \\
  --model "MODEL_ID" \\
  --error-msg "brief description of what failed"
```

Identify and remove development artifacts (logs, temp files, debug files, backups) while preserving all working code. Creates a git checkpoint before cleanup.

## Execute

```bash
~/.claude/scripts/cleanproject.sh --full
```

## Respond by next_action

Read `next_action` from the JSON result and act accordingly:

**display_summary** — Cleanup complete. Report: files deleted count, breakdown by type (temporary, debug, backup). If nothing was found, tell the user the project is already clean.

**fix_failed_files** — Some files could not be deleted. Report which files failed. Check if they are in use (`lsof <file>`) or have wrong permissions (`ls -la <file>`). After resolving, re-run: `~/.claude/scripts/cleanproject.sh --json --cleanup`

**fix_error** — Script failed. Report the section and error message. Try the debug block below.

## Section Flags

Run individual sections when needed:
- `--identify` — Find cleanup targets only (no deletion)
- `--analyze` — Safety analysis only
- `--cleanup` — Perform deletion only

## Restore from Checkpoint

If cleanup removed something important, restore via git:
```bash
git log --oneline -5   # find "Pre-cleanup checkpoint"
git reset --hard <sha>
```

## Debug

```bash
~/.claude/scripts/cleanproject.sh --raw --identify
~/.claude/scripts/cleanproject.sh --raw --analyze
~/.claude/scripts/cleanproject.sh --raw --cleanup
```

## Completion Tracking

When the workflow completes successfully, run:
```bash
~/.claude/scripts/track-command.sh --command "cleanproject" --event complete \
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
