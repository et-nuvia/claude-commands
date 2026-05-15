---
name: fix-imports
description: Fix and organize import statements across the project
user_invocable: true
---

## Tracking

As your **first action**, before any other work, run:
```bash
~/.claude/scripts/track-command.sh --command "fix-imports" --event start
```

If the workflow encounters an unrecoverable error at any point, run:
```bash
~/.claude/scripts/track-command.sh --command "fix-imports" --event error \\
  --model "MODEL_ID" \\
  --error-msg "brief description of what failed"
```
# Fix Broken Imports

Systematically fix import statements broken by file moves or renames, with continuity across sessions.

Arguments: `$ARGUMENTS` - specific paths or import patterns to fix (optional)

## Session Handling

Session files are stored in `fix-imports/` in the current project root:
- `fix-imports/plan.md` - broken imports and fix plan
- `fix-imports/state.json` - resolution progress

On invocation:
- If `fix-imports/state.json` exists: resume from last import
- If argument is `resume`/`status`/`new`: handle accordingly
- Otherwise: scan for broken imports and create a new plan

## Phase 1: Import Analysis

Scan for all broken imports:
- File not found / module resolution failures
- Moved or renamed files
- Deleted dependencies
- Circular references

Use language-agnostic detection with awareness of path aliases and barrel exports. Write findings to `fix-imports/plan.md` with each broken import location, possible resolutions, confidence level, and fix approach.

## Phase 2: Resolution Planning

Resolution priority:
1. Exact filename matches
2. Similar name suggestions
3. Export symbol search
4. Path recalculation
5. Import removal if needed

Never guess ambiguous imports — show multiple matches with context and wait for a decision. Record all decisions for consistency.

## Phase 3: Fixing

```bash
# Create git checkpoint before starting
git stash  # or commit current work
```

Fix imports systematically:
- Update relative paths correctly
- Maintain path alias usage
- Preserve import grouping and sorting conventions
- Mark each fix in the plan
- Create incremental commits with meaningful messages

## Phase 4: Verification

After all fixes:
- Syntax validation
- Confirm no new broken imports introduced
- Circular dependency check
- Build verification if possible

## Safety

Never: guess ambiguous imports, break working imports, create circular dependencies, overwrite decisions from prior sessions.

## Completion Tracking

When the workflow completes successfully, run:
```bash
~/.claude/scripts/track-command.sh --command "fix-imports" --event complete \
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
