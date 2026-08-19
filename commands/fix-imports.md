---
name: fix-imports
description: Fix and organize import statements across the project
user_invocable: true
---


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

