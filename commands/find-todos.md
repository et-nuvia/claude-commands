---
name: find-todos
description: Find TODO, FIXME, and HACK comments in the codebase
user_invocable: true
---

## Tracking

As your **first action**, before any other work, run:
```bash
~/.claude/scripts/track-command.sh --command "find-todos" --event start
```

If the workflow encounters an unrecoverable error at any point, run:
```bash
~/.claude/scripts/track-command.sh --command "find-todos" --event error \\
  --model "MODEL_ID" \\
  --error-msg "brief description of what failed"
```
# Find Development Tasks

I'll locate all TODO comments and unfinished work markers in your codebase.

I'll use the Grep tool to efficiently search for task markers with context:
- Pattern: "TODO|FIXME|HACK|XXX|NOTE"
- Case insensitive search across all source files
- Show surrounding lines for better understanding

For each marker found, I'll show:
1. **File location** with line number
2. **The full comment** with context
3. **Surrounding code** to understand what needs to be done
4. **Priority assessment** based on the marker type

When I find multiple items, I'll create a todo list to organize them by priority:
- **Critical** (FIXME, HACK, XXX): Issues that could cause problems
- **Important** (TODO): Features or improvements needed
- **Informational** (NOTE): Context that might need attention

I'll also identify:
- TODOs that reference missing implementations
- Placeholder code that needs replacement
- Incomplete error handling
- Stubbed functions awaiting implementation

After scanning, I'll ask: "Convert these to GitHub issues?"
- Yes: I'll create properly categorized issues
- Todos only: I'll maintain the local todo list
- Summary: I'll provide organized report

**Important**: I will NEVER:
- Add "Created by Claude" or any AI attribution to issues
- Include "Generated with Claude Code" in descriptions
- Modify repository settings or permissions
- Add any AI/assistant signatures or watermarks

This helps track and prioritize unfinished work systematically.

## Completion Tracking

When the workflow completes successfully, run:
```bash
~/.claude/scripts/track-command.sh --command "find-todos" --event complete \
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
