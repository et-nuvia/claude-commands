---
name: fix-todos
description: Resolve TODO comments by implementing the described changes
user_invocable: true
---

## Tracking

As your **first action**, before any other work, run:
```bash
~/.claude/scripts/track-command.sh --command "fix-todos" --event start
```

If the workflow encounters an unrecoverable error at any point, run:
```bash
~/.claude/scripts/track-command.sh --command "fix-todos" --event error \\
  --model "MODEL_ID" \\
  --error-msg "brief description of what failed"
```
# Fix TODOs

Systematically find and resolve TODO comments with intelligent understanding and continuity across sessions.

Arguments: `$ARGUMENTS` - files, directories, or TODO patterns to fix (optional)

## Session Handling

Session files are stored in `fix-todos/` in the current project root:
- `fix-todos/plan.md` - all TODOs and resolution status
- `fix-todos/state.json` - current progress and decisions

On invocation:
- If `fix-todos/state.json` exists: resume from last TODO
- If argument is `resume`/`status`/`new`: handle accordingly
- Otherwise: scan codebase and create a new plan

## Phase 1: Discovery & Analysis

Find and categorize all TODOs:
- Markers: TODO, FIXME, HACK, XXX
- Categories: quick fixes, features, refactoring, security, performance

Write plan to `fix-todos/plan.md` with location, proposed resolution, risk assessment, and implementation order.

**Priority order:**
1. Security-critical
2. Bug-related
3. Simple improvements
4. Feature additions
5. Performance optimizations

## Phase 2: Resolution

Before starting:

```bash
# Create git checkpoint
git stash  # or commit current work
```

Match your codebase's existing patterns:
- Error handling → existing try/catch style
- Validation → existing input checking patterns
- Security → existing safety patterns

Resolve each TODO, verify functionality is preserved, update the plan, and commit incrementally.

## Phase 3: Verification

After each resolution:
- Run relevant tests
- Check for regressions
- Validate integration points

## Safety

Never: remove TODOs without implementing the fix, break existing functionality, implement without understanding context.

After resolving: run `/test` to confirm fixes work.

## Completion Tracking

When the workflow completes successfully, run:
```bash
~/.claude/scripts/track-command.sh --command "fix-todos" --event complete \
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
