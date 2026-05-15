---
name: review-implement
description: Implement fixes from code reviews or structured task lists
user_invocable: true
---

## Tracking

> Output format is auto-detected (TOON for AI callers, JSON for CI/scripts). Use `--toon` or `--json` to override.

As your **first action**, before any other work, run:
```bash
~/.claude/scripts/track-command.sh --command "review-implement" --event start
```

If the workflow encounters an unrecoverable error at any point, run:
```bash
~/.claude/scripts/track-command.sh --command "review-implement" --event error \\
  --model "MODEL_ID" \\
  --error-msg "brief description of what failed"
```

Parse a structured document (code review, implementation plan, task list) and implement the actionable items. Use **model: opus** for planning. Works with CRV, PLN, IMP, TSK document types.

## Find Document

If no path provided, search for recent documents:

```bash
find /home/eric/.claude/docs/active -name "*CRV*.md" -o -name "*PLN*.md" -o -name "*IMP*.md" -o -name "*TSK*.md" | sort -r | head -10
```

Ask the user to select one, or accept a path directly.

## Execute

```bash
~/.claude/scripts/review-implement.sh --full --document "path/to/document.md"
```

## Respond by next_action

Read `next_action` from the JSON result and act accordingly:

**implement_changes** — Document parsed successfully. Read `parsed_data` for the structured task list. Then:

1. Read the full document to understand context
2. Extract all actionable items (issues, tasks, review comments)
3. Present an implementation plan to the user showing what will be changed
4. Ask user to choose: implement all, implement selected items, or skip
5. Implement approved changes using Edit/Write tools
6. After each logical group of changes, run tests to verify nothing broke
7. Commit changes with conventional commit format referencing the document
8. Report what was implemented and what was skipped

**display_summary** — Complete. Report items implemented, items skipped, test results.

**fix_error** — Document not found or parse error. Report details. Verify the path exists and the document has proper structure.

## Section Flags

- `--validate` — Check document exists and is readable
- `--parse` — Parse document structure only

## Debug

```bash
~/.claude/scripts/review-implement.sh --raw --full --document "path/to/document.md"
~/.claude/scripts/review-implement.sh --raw --parse --document "path/to/document.md"
```

## Completion Tracking

When the workflow completes successfully, run:
```bash
~/.claude/scripts/track-command.sh --command "review-implement" --event complete \
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
