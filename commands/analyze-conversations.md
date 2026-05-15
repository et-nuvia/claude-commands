---
name: analyze-conversations
description: Analyze conversation transcripts for patterns, issues, and improvement opportunities
user_invocable: true
---

## Tracking

> Output format is auto-detected (TOON for AI callers, JSON for CI/scripts). Use `--toon` or `--json` to override.

As your **first action**, before any other work, run:
```bash
~/.claude/scripts/track-command.sh --command "analyze-conversations" --event start
```

If the workflow encounters an unrecoverable error at any point, run:
```bash
~/.claude/scripts/track-command.sh --command "analyze-conversations" --event error \\
  --model "MODEL_ID" \\
  --error-msg "brief description of what failed"
```

Analyze Claude Code conversation history for recurring issues, pain points, and improvement opportunities. Only processes new/changed conversations since last run.

## Execute

```bash
~/.claude/scripts/analyze-conversations.sh --full
```

Options: `--project <dir>` to scope to one project, `--limit <n>` to cap file count, `--reset` to re-analyze everything, `--summary` to view previous results.

## Response Handling

Read `next_action` from JSON:

**`analyze_findings`** (status: ready_for_llm) — Analysis complete, findings ready. Review the `findings` object and produce a structured report:

1. **Usage Patterns** — Report `top_skills` and `top_tools`. Identify which commands are used most. Note any tools with surprisingly high usage (possible automation opportunity).

2. **Error Hotspots** — From `error_stats`, identify:
   - Sessions with highest error counts (`high_error_sessions`)
   - Which projects have the most errors (`by_project`)
   - Suggest which scripts may need hardening

3. **User Friction** — From `correction_stats`, identify:
   - Sessions where the user had to correct Claude most often
   - Patterns in what caused corrections
   - For the top 5 high-correction sessions, read the conversation file to understand what went wrong:
     `~/.claude/projects/<project>/<session_id>.jsonl`

4. **Retry Patterns** — From `retry_stats`, identify tools that are retried excessively. These indicate flaky operations or unclear error messages.

5. **Context Exhaustion** — Report `long_conversations` (>200 messages). These may indicate tasks that should be broken down or automated better.

6. **Recommendations** — Based on all findings, produce:
   - **Existing commands/scripts to improve** — which ones cause the most errors or corrections
   - **New commands/scripts to create** — repeated manual workflows that could be automated
   - **Configuration changes** — settings or defaults that could reduce friction

Present the report in a readable format, then ask the user which recommendations they'd like to pursue.

**`display_summary`** (status: no_new_files) — No new conversations to analyze. Report the count and suggest `--reset` if user wants to re-analyze.

**`fix_error`** — Report the error message. Common causes: no conversations found, jq parsing failure, permission issues.

## Sections

| Flag | Purpose |
|------|---------|
| `--full` | Scan + analyze + aggregate (default) |
| `--scan` | Find new/changed conversation files only |
| `--analyze` | Process pending files from scan |
| `--aggregate` | Summarize batch results |
| `--summary` | Load and display previous analysis |

## Debug

```bash
~/.claude/scripts/analyze-conversations.sh --raw --full
~/.claude/scripts/analyze-conversations.sh --raw --summary
```

## Completion Tracking

When the workflow completes successfully, run:
```bash
~/.claude/scripts/track-command.sh --command "analyze-conversations" --event complete \
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
