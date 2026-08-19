---
name: analyze-command-health
description: Find which of your own commands and scripts to improve and speed up, from transcript evidence
user_invocable: true
---


> **Output format is auto-detected: TOON when an AI agent is the caller, JSON for tests/CI.** This is intentional — TOON carries the same fields in far fewer tokens. `--json` does NOT switch an LLM caller to JSON, and that is not a bug to work around. Read the TOON fields directly; never pipe script output through `jq`, a converter, or `head`/`tail`/`grep` to "fix" the format.


Attributes every tool call in your transcripts to the slash command that was in
effect when it ran, so latency, failures, chattiness, and permission-prompt
friction can be blamed on a specific command or backing script.

Complements `/analyze-conversations`, which reports session-level aggregates
(which skills/tools are popular). This one names what to fix.

## Execute

```bash
~/.claude/scripts/analyze-command-health.sh --since 30
```

Options: `--command <name>` to drill into one command · `--project <dir>` to scope
to one project · `--since <days>` (0 = all history) · `--top <n>` rows per section ·
`--all-scripts` to include third-party scripts · `--reset` to drop the cache.

## Response Handling

Read `next_action` from the output:

**`review_recommendations`** (status: ready_for_llm) — Produce a prioritized report.
`findings.recommendations` is rule-generated and evidence-backed; your job is
synthesis, not restatement:

1. **Verify before recommending.** Each recommendation names a target. Read that
   command/script before proposing a change — a high `error_rate_pct` is often a
   *designed* gate (`review_failed`, `blocked`), which is why the script reports
   `gated_errors` separately from `unexpected_errors`. Only `unexpected_errors`
   indicate a defect.

2. **Speed.** From `slowest_commands` and `slowest_scripts`, separate real
   execution cost from waiting. A `p90` driven by `pipeline-watch.sh` or a deploy
   poll is inherent; a `p90` driven by `calls_per_invocation` is fixable by moving
   the loop into the script. `stalled_calls` are permission/idle waits — fix those
   with allowlisting, not optimization.

3. **Chattiness.** For each entry in `chattiest_commands`, use `tool_mix` to say
   what the calls actually are. High `Bash` → consolidate into a script section.
   High `Read` → the script should return the content. High `Agent` → check whether
   the subagents are dispatched in parallel.

4. **Permission friction.** `antipattern_totals` and `permission_prompt_hotspots`
   count violations of the Command Hygiene rules in CLAUDE.md. Report the dominant
   pattern per command and the exact rewrite that removes it.

5. **Automation.** From `automation_candidates` and `repeated_shell_pattern`
   recommendations, propose make targets or new script sections. Skip anything
   already prescribed by CLAUDE.md (a bare `cd <worktree>` is intentional).

6. **Output.** Rank by (frequency × cost per occurrence), grouped as: *fix now*
   (unexpected failures), *speed up* (chatty/slow), *reduce friction* (hygiene),
   *automate* (repeated patterns). Cite the evidence for each, then ask which to pursue.

Do not act on `(no command)` as if it were a command — it is ad-hoc work outside
any slash command, useful only as a baseline.

**`display_summary`** (status: no_data) — No transcripts in the window. Suggest a
wider `--since`, or `--since 0` for all history.

**`fix_error`** — Report the message. Common causes: unknown `--project`, jq older
than 1.6.

## Debug

```bash
~/.claude/scripts/analyze-command-health.sh --raw --since 7 --limit 10
~/.claude/scripts/analyze-command-health.sh --raw --command task-continue
```

