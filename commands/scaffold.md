---
name: scaffold
description: Generate project scaffolding from templates
user_invocable: true
---

## Tracking

As your **first action**, before any other work, run:
```bash
~/.claude/scripts/track-command.sh --command "scaffold" --event start
```

If the workflow encounters an unrecoverable error at any point, run:
```bash
~/.claude/scripts/track-command.sh --command "scaffold" --event error \\
  --model "MODEL_ID" \\
  --error-msg "brief description of what failed"
```
# Intelligent Scaffolding

Create complete feature structures based on your project's existing patterns, with continuity across sessions.

Arguments: `$ARGUMENTS` - feature name or component to scaffold

## Session Handling

Session files are stored in `scaffold/` in the current project root:
- `scaffold/plan.md` - scaffolding plan and component list
- `scaffold/state.json` - created files and progress

On invocation:
- If `scaffold/state.json` exists: resume incomplete scaffolding
- If argument is `resume`/`status`/`new`: handle accordingly
- Otherwise: analyze patterns and create a new plan

## Phase 1: Pattern Discovery

Analyze the project to understand:
- File organization and directory structure
- Naming conventions (files, classes, functions)
- Testing patterns and framework
- Import/export styles
- Documentation standards

Find the most similar existing feature to use as a reference template.

## Phase 2: Scaffolding Plan

Write plan to `scaffold/plan.md` listing every file to create, the template pattern to follow, integration requirements, and creation order.

Show the full plan for confirmation before creating any files.

**Typical components:**
- Main feature files
- Test files (matching your test framework)
- Documentation if the project has a docs pattern
- Configuration updates and integration points

## Phase 3: Creation & Integration

```bash
# Create git checkpoint before starting
git stash  # or commit current work
```

Create files systematically:
- Follow the exact naming and structure conventions discovered
- Generate content from existing code patterns, not generic boilerplate
- Never overwrite existing files — stop and report a conflict

After all files are created, update integration points:
- Route configurations
- Module exports
- Build configuration

## Safety

Never: overwrite existing files, break existing imports, deviate from discovered patterns without asking.

## Completion Tracking

When the workflow completes successfully, run:
```bash
~/.claude/scripts/track-command.sh --command "scaffold" --event complete \
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
