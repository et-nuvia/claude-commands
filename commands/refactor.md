---
name: refactor
description: Intelligent code refactoring with session continuity and automatic validation
user_invocable: true
---

## Tracking

> Output format is auto-detected (TOON for AI callers, JSON for CI/scripts). Use `--toon` or `--json` to override.

As your **first action**, before any other work, run:
```bash
~/.claude/scripts/track-command.sh --command "refactor" --event start
```

If the workflow encounters an unrecoverable error at any point, run:
```bash
~/.claude/scripts/track-command.sh --command "refactor" --event error \\
  --model "MODEL_ID" \\
  --error-msg "brief description of what failed"
```

Systematic code refactoring with session management. Preserves functionality while improving structure through incremental, validated changes. Use **model: opus** for complex refactoring decisions.

Arguments: `$ARGUMENTS` — files, directories, or refactoring scope (optional)

## Execute

```bash
~/.claude/scripts/refactor.sh --full "$ARGUMENTS"
```

## Respond by next_action

Read `next_action` from the JSON result and act accordingly:

**analyze_codebase** — New or resumed session. Read the session files at `$RESULT.refactor_dir`:
- If resuming: read `state.json` and `plan.md`, continue from last checkpoint
- If new: analyze the scope with Glob and Read tools. Understand structure, dependencies, patterns. Document findings in `refactor/plan.md`. Then: `~/.claude/scripts/refactor.sh --json --plan`

**create_refactor_plan** — Analysis done. Create a detailed step-by-step refactoring plan in `refactor/plan.md`. Include: what changes, why, risk level, validation steps for each change. Then: `~/.claude/scripts/refactor.sh --json --execute`

**execute_refactoring** — Plan ready. Execute changes using Edit tool, one logical step at a time. Update plan.md checklist after each step. Commit at milestones. Then: `~/.claude/scripts/refactor.sh --json --validate`

**validate_refactoring** — Implementation done. Run tests from PROJECT.yaml. Verify behavior preserved. Search for regressions. Update plan.md with results. Report pass/fail.

**display_summary** — Refactoring complete. Report what was changed and test results.

**fix_error** — Script error. Report details. Try the debug block.

## Section Flags

`--analyze`, `--plan`, `--execute`, `--validate`, `--status`

## Debug

```bash
~/.claude/scripts/refactor.sh --raw --analyze "$ARGUMENTS"
~/.claude/scripts/refactor.sh --raw --validate
```

## Completion Tracking

When the workflow completes successfully, run:
```bash
~/.claude/scripts/track-command.sh --command "refactor" --event complete \
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
