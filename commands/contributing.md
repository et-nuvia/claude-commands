---
name: contributing
description: Analyze project context and provide contribution strategy with intelligent issue management
user_invocable: true
---

## Tracking

> Output format is auto-detected (TOON for AI callers, JSON for CI/scripts). Use `--toon` or `--json` to override.

As your **first action**, before any other work, run:
```bash
~/.claude/scripts/track-command.sh --command "contributing" --event start
```

If the workflow encounters an unrecoverable error at any point, run:
```bash
~/.claude/scripts/track-command.sh --command "contributing" --event error \\
  --model "MODEL_ID" \\
  --error-msg "brief description of what failed"
```

Analyze the current project context, detect platform and standards, and determine the best contribution strategy. Then execute that strategy: commit changes, search for related issues, and create a PR/MR.

**Never include**: AI attribution, "Co-Authored-By: Claude", emojis in commits/PRs/issues.

## Execute

```bash
~/.claude/scripts/contributing.sh --full
```

## Respond by next_action

Read `next_action` from the JSON result and act accordingly:

**execute_contribution_strategy** — Analysis complete. Read `data.strategy.recommended_strategy` and execute:

- `commit_changes`: Stage and commit using conventional format. Run pre-flight checks first (tests, lint, typecheck). Only commit if all checks pass.
- `create_pr`: Push branch and create PR. For open source projects, read CONTRIBUTING.md, search for related issues (`gh search issues`), link them in the PR body. Use concise professional language, no emojis.
- `up_to_date`: No changes to contribute. Inform the user.

For any PR/commit creation: run tests, lint, and typecheck first. Stop and fix if any check fails.

**fix_error** — Script failed. Report error and try the debug block.

## Section Flags

- `--context` — Git state only
- `--standards` — Project standards only
- `--strategy` — Strategy generation only

## Debug

```bash
~/.claude/scripts/contributing.sh --raw --context
~/.claude/scripts/contributing.sh --raw --standards
~/.claude/scripts/contributing.sh --raw --full
```

## Completion Tracking

When the workflow completes successfully, run:
```bash
~/.claude/scripts/track-command.sh --command "contributing" --event complete \
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
