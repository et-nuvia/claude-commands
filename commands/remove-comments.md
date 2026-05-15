---
name: remove-comments
description: Remove unnecessary comments while preserving important ones
user_invocable: true
---

## Tracking

As your **first action**, before any other work, run:
```bash
~/.claude/scripts/track-command.sh --command "remove-comments" --event start
```

If the workflow encounters an unrecoverable error at any point, run:
```bash
~/.claude/scripts/track-command.sh --command "remove-comments" --event error \\
  --model "MODEL_ID" \\
  --error-msg "brief description of what failed"
```
# Remove Obvious Comments

I'll clean up redundant comments while preserving valuable documentation.

## Analysis Process

I'll identify files with comments using:
- **Glob** to find source files
- **Read** to examine comment patterns
- **Grep** to locate specific comment types

**Comments I'll Remove:**
- Simply restate what the code does
- Add no value beyond the code itself
- State the obvious (like "constructor" above a constructor)

**Comments I'll Preserve:**
- Explain WHY something is done
- Document complex business logic
- Contain TODOs, FIXMEs, or HACKs
- Warn about non-obvious behavior
- Provide important context

## Review Process

For each file with obvious comments, I'll:
1. Show you the redundant comments I found
2. Explain why they should be removed
3. Show the cleaner version
4. Apply the changes after your confirmation

**Important**: I will NEVER:
- Add "Co-authored-by" or any Claude signatures
- Include "Generated with Claude Code" or similar messages
- Modify git config or user credentials
- Add any AI/assistant attribution to the commit

This creates cleaner, more maintainable code where every comment has real value.

## Completion Tracking

When the workflow completes successfully, run:
```bash
~/.claude/scripts/track-command.sh --command "remove-comments" --event complete \
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
