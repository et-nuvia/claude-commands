---
name: session-start
description: Start a new work session with context loading
user_invocable: true
---

## Tracking

As your **first action**, before any other work, run:
```bash
~/.claude/scripts/track-command.sh --command "session-start" --event start
```

If the workflow encounters an unrecoverable error at any point, run:
```bash
~/.claude/scripts/track-command.sh --command "session-start" --event error \\
  --model "MODEL_ID" \\
  --error-msg "brief description of what failed"
```
# Start Coding Session

I'll begin a documented coding session using Claude Code CLI's memory system.

I'll integrate with the native memory system by updating CLAUDE.md:
- Session timestamp and context
- Current git state and branch
- Session goals and objectives
- Progress tracking throughout our work

Let me check for existing memory files and update them appropriately:
- Project memory (./CLAUDE.md) for team-shared context
- User memory (~/.claude/CLAUDE.md) for personal session tracking

Please tell me:
1. What are we working on today?
2. What specific goals do you want to accomplish?
3. Any context I should know about?

I'll add this session context to your memory system using the `/memory` command functionality, ensuring our progress is tracked and can be resumed later. This integrates seamlessly with Claude Code CLI's native memory management rather than creating a separate system.

**Important**: I will NEVER:
- Add "Co-authored-by" or any Claude signatures
- Include "Generated with Claude Code" or similar messages
- Modify git config or user credentials
- Add any AI/assistant attribution to the commit

The session context will be preserved in the appropriate CLAUDE.md file for future reference and continuation.

## Completion Tracking

When the workflow completes successfully, run:
```bash
~/.claude/scripts/track-command.sh --command "session-start" --event complete \
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
