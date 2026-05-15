---
name: session-end
description: End a work session with summary and progress notes
user_invocable: true
---

## Tracking

As your **first action**, before any other work, run:
```bash
~/.claude/scripts/track-command.sh --command "session-end" --event start
```

If the workflow encounters an unrecoverable error at any point, run:
```bash
~/.claude/scripts/track-command.sh --command "session-end" --event error \\
  --model "MODEL_ID" \\
  --error-msg "brief description of what failed"
```
# End Coding Session

I'll summarize this coding session and update the memory system with our accomplishments.

Let me analyze what we accomplished by:
1. Reviewing files created/modified during our session
2. Checking git changes and commit history
3. Summarizing completed work and pending items

I'll update the appropriate CLAUDE.md file with:
- Session summary and accomplishments
- Files modified and their purposes
- Decisions made and rationale
- Pending work and next steps
- Any important context for future sessions

## Session Summary:

### Accomplished:
- All completed tasks from our conversation
- Files created/modified with their purposes
- Problems solved and solutions implemented

### Pending Items:
- Tasks started but not completed
- Known issues requiring attention
- Recommended next steps

### Handoff Notes:
- Key architectural decisions made
- Important context for team members
- Blockers or dependencies identified
- Technical debt considerations

**Important**: I will NEVER:
- Add "Co-authored-by" or any Claude signatures
- Include "Generated with Claude Code" or similar messages
- Modify git config or user credentials
- Add any AI/assistant attribution to the commit
- Use emojis in commits, PRs, or git-related content

I'll preserve this summary in your memory system, ensuring continuity for future sessions and seamless handoffs to team members. This integrates with Claude Code CLI's native memory management for persistent context.

## Completion Tracking

When the workflow completes successfully, run:
```bash
~/.claude/scripts/track-command.sh --command "session-end" --event complete \
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
