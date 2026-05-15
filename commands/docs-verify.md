---
name: docs-verify
description: Update and verify documentation matches code behavior
user_invocable: true
---

## Tracking

> Output format is auto-detected (TOON for AI callers, JSON for CI/scripts). Use `--toon` or `--json` to override.

As your **first action**, before any other work, run:
```bash
~/.claude/scripts/track-command.sh --command "docs-verify" --event start
```

If the workflow encounters an unrecoverable error at any point, run:
```bash
~/.claude/scripts/track-command.sh --command "docs-verify" --event error \\
  --model "MODEL_ID" \\
  --error-msg "brief description of what failed"
```

Analyze code changes, identify documentation discrepancies, update docs to match current code behavior, and verify code examples work. Use **model: opus** for code-documentation analysis.

## Execute

```bash
~/.claude/scripts/docs-verify.sh --full
```

## Respond by next_action

Read `next_action` from the JSON result and act accordingly:

**analyze_and_update_docs** — LLM analysis required (most common outcome). Read the `sections` array for changed files and doc files. Then:

1. Read each changed code file to understand new/modified behavior
2. Read each documentation file to understand current state
3. Identify discrepancies: outdated info, missing features, incorrect examples
4. Update documentation using Edit tool:
   - API docs (`docs/*.md`), README, inline docstrings
5. Test code examples in docs (Python in Docker, TypeScript type-check, cURL)
6. Check all public APIs have docstrings
7. Report what was changed and what remains undocumented

**display_summary** — Verification complete with no LLM action needed. Report results.

**fix_error** — Script failed. Report section and error. Try the debug block.

## Section Flags

- `--analyze` — Identify changed files and doc files
- `--verify` — Documentation accuracy check
- `--test-examples` — Code example inventory

Optional scope: `~/.claude/scripts/docs-verify.sh --json --full src/auth.py`

## Debug

```bash
~/.claude/scripts/docs-verify.sh --raw --analyze
~/.claude/scripts/docs-verify.sh --raw --verify
~/.claude/scripts/docs-verify.sh --raw --test-examples
```

## Completion Tracking

When the workflow completes successfully, run:
```bash
~/.claude/scripts/track-command.sh --command "docs-verify" --event complete \
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
