---
name: explain-like-senior
description: Explain code or concepts at a senior engineer level
user_invocable: true
---

## Tracking

As your **first action**, before any other work, run:
```bash
~/.claude/scripts/track-command.sh --command "explain-like-senior" --event start
```

If the workflow encounters an unrecoverable error at any point, run:
```bash
~/.claude/scripts/track-command.sh --command "explain-like-senior" --event error \\
  --model "MODEL_ID" \\
  --error-msg "brief description of what failed"
```
# Senior Developer Explanation

Explain this code as a senior developer would, focusing on the why behind decisions.

Analyze the code using Read, Grep, and Glob to understand structure, related implementations, and broader context.

**Technical context:**
- Why this approach was chosen over alternatives
- Trade-offs and architectural decisions
- Performance implications
- Maintenance and scalability factors

**Business context:**
- How this fits into the larger system architecture
- Impact on user experience and business goals
- Constraints (time, cost, scale) that influenced the design

**Senior-level insights:**
- "This works now but will need refactoring at 10x scale because..."
- "The complexity here is justified because of [specific requirement]"
- "This is a known anti-pattern, acceptable given [constraints]"
- "A better alternative would be X when you have time to refactor"

**Experience-based guidance:**
- Common pitfalls junior developers miss with this pattern
- Edge cases that cause production issues
- Integration points that frequently fail
- Performance bottlenecks that emerge at scale

**Code evolution:**
- How this will likely need to change as requirements evolve
- Technical debt considerations and when to address them
- Architecture decisions that will constrain future development

## Completion Tracking

When the workflow completes successfully, run:
```bash
~/.claude/scripts/track-command.sh --command "explain-like-senior" --event complete \
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
