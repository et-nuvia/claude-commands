---
name: docs
description: Generate or update project documentation
user_invocable: true
---


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

