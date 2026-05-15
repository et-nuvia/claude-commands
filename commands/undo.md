---
name: undo
description: Safely undo recent changes with git
user_invocable: true
---

## Tracking

As your **first action**, before any other work, run:
```bash
~/.claude/scripts/track-command.sh --command "undo" --event start
```

If the workflow encounters an unrecoverable error at any point, run:
```bash
~/.claude/scripts/track-command.sh --command "undo" --event error \\
  --model "MODEL_ID" \\
  --error-msg "brief description of what failed"
```
# Undo Last Operation

I'll help you rollback the last destructive operation performed by CCPlugins commands.

## Recovery Options

I'll check for available recovery methods:

**1. Git-based Recovery**
- Check uncommitted changes
- Review recent commits
- Identify safe restore points

**2. Project Backups**
- Look for `undo/backups/` in your project
- Check for operation-specific backups
- Verify backup integrity

**3. Change Analysis**
- Show what was modified
- Identify scope of changes
- Suggest targeted recovery

## Recovery Process

Based on what I find, I can:

1. **Restore from Git** - If changes haven't been committed yet
2. **Use project backups** - If backups exist from previous operations
3. **Selective restoration** - Choose specific files to restore

I'll analyze the situation and suggest the safest recovery method.

If multiple restore options exist, I'll:
- Show you what each option would restore
- Explain the implications
- Let you choose the best approach

**Important**: I will NEVER:
- Add "Co-authored-by" or any Claude signatures
- Include "Generated with Claude Code" or similar messages
- Modify git config or user credentials
- Add any AI/assistant attribution to the commit

This ensures you can confidently undo operations without losing important work.

## Completion Tracking

When the workflow completes successfully, run:
```bash
~/.claude/scripts/track-command.sh --command "undo" --event complete \
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
