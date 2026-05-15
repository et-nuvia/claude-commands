---
name: docs
description: Generate or update project documentation
user_invocable: true
---

## Tracking

As your **first action**, before any other work, run:
```bash
~/.claude/scripts/track-command.sh --command "docs" --event start
```

If the workflow encounters an unrecoverable error at any point, run:
```bash
~/.claude/scripts/track-command.sh --command "docs" --event error \\
  --model "MODEL_ID" \\
  --error-msg "brief description of what failed"
```
# Documentation Manager

Manage project documentation by analyzing what changed and updating all relevant docs.

## Modes

**`/docs`** (default) — Overview: glob all markdown files, read each, report status.

Output:
```
DOCUMENTATION OVERVIEW
├── README.md - [current/outdated]
├── CHANGELOG.md - [last updated]
└── docs/*.md - [status]

KEY FINDINGS: missing/outdated/incomplete items
```

**`/docs update`** — Smart update after implementation:
1. Analyze conversation history and codebase changes
2. Compare code reality vs documentation
3. Update all affected docs: README, CHANGELOG, API docs, config, migration guides
4. Group CHANGELOG entries by type (Added, Fixed, Changed, Removed)

**Context-aware rules:**
- After new feature: README features + CHANGELOG
- After bug fixes: CHANGELOG + troubleshooting
- After refactoring: architecture docs + migration guide
- After security fixes: security policy + CHANGELOG

## Rules

**Always:**
- Read existing docs completely before updating
- Update in-place, never duplicate content
- Preserve custom content and formatting
- Match existing doc style
- Only create new docs if truly missing (no README, etc.)

**Never:**
- Delete existing documentation
- Overwrite custom sections
- Add AI attribution markers

After analysis, confirm approach with user before making changes.

## Completion Tracking

When the workflow completes successfully, run:
```bash
~/.claude/scripts/track-command.sh --command "docs" --event complete \
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
