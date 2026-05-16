---
command: analyze-conversations
group: outlier
backing_script: ~/.claude/scripts/analyze-conversations.sh
mutates: []
runtime: ~30-120s
destructive: false
requires_project_yaml: none
project_yaml_fields: []
requires_project_knowledge: none
project_knowledge_sections: []
---

# /analyze-conversations

Scans your Claude Code conversation history for recurring error patterns,
correction events, retry spikes, and context exhaustion — then produces a
structured report with specific recommendations for which commands or scripts
to improve and which manual workflows are ripe for automation. Only processes
new or changed conversations since the last run, so repeated invocations are
cheap.

---

## When to use it

- You suspect a particular command or script is causing repeated user friction
- Conversations have been growing unusually long and you want to find out why
- You want data-driven input before investing time in a new automation or skill

## Usage

```bash
/analyze-conversations [options]
```

**Common invocations:**

```bash
/analyze-conversations                        # default: incremental scan + analysis
/analyze-conversations --project <dir>        # scope to one project directory
/analyze-conversations --limit <n>            # cap the number of files processed
/analyze-conversations --reset                # force re-analysis of all conversations
/analyze-conversations --summary              # display the previous analysis without re-scanning
```

## Arguments

| Argument / Flag | Required | Description |
|---|---|---|
| `--project <dir>` | No | Scope scan to a single project's conversation files |
| `--limit <n>` | No | Maximum number of conversation files to process |
| `--reset` | No | Re-analyze all conversations, ignoring the incremental cache |
| `--summary` | No | Load and display the most recent saved analysis without running a new scan |

## Dependencies

**External commands / packages** (must be on `PATH`):

| Dependency | Why it's needed | Install |
|---|---|---|
| `jq` | Parse JSONL conversation files and aggregate results | `brew install jq` / `apt install jq` |

**Project files consumed:**

- `PROJECT.yaml` (PY) — No
- `PROJECT-KNOWLEDGE.md` (PK) — No
- `~/.claude/projects/<project>/<session_id>.jsonl` — Claude Code conversation files read during the analyze phase
- `/tmp/analyze-conversations-*` — intermediate result files written by the script

## Backing script

**Script**: `~/.claude/scripts/analyze-conversations.sh`

**Inputs:** `--full` (default), `--scan`, `--analyze`, `--aggregate`, or `--summary`. Optional `--project <dir>`, `--limit <n>`, `--reset`.

**Outputs (structured JSON on stdout):**

- `next_action` ∈ {`analyze_findings`, `display_summary`, `fix_error`}
- `findings.top_skills[]` — most-used skills by frequency
- `findings.top_tools[]` — most-used tools by frequency
- `findings.error_stats.high_error_sessions[]` — sessions with the most errors
- `findings.error_stats.by_project{}` — error counts per project
- `findings.correction_stats[]` — sessions where the user corrected Claude most often
- `findings.retry_stats[]` — tools retried excessively (flakiness candidates)
- `findings.long_conversations[]` — sessions exceeding 200 messages

**Invocation surface:**

```bash
~/.claude/scripts/analyze-conversations.sh --full                     # scan + analyze + aggregate
~/.claude/scripts/analyze-conversations.sh --scan                     # find new/changed files only
~/.claude/scripts/analyze-conversations.sh --analyze                  # process pending files from scan
~/.claude/scripts/analyze-conversations.sh --aggregate                # summarize batch results
~/.claude/scripts/analyze-conversations.sh --summary                  # load previous results
~/.claude/scripts/analyze-conversations.sh --raw --full               # debug: unformatted output
~/.claude/scripts/analyze-conversations.sh --raw --summary            # debug: raw summary JSON
```

## How it works

1. **Scan** — script walks `~/.claude/projects/` (or a scoped project directory),
   compares modification times against the incremental cache, and builds a list of
   new or changed `.jsonl` conversation files. `--reset` bypasses the cache.
2. **Analyze** — each pending conversation file is parsed for error events,
   user-correction messages, tool retry sequences, and message count. Results
   are written as per-session JSON to `/tmp/`.
3. **Aggregate** — session-level results are merged into project- and
   global-level summaries covering usage patterns, error hotspots, correction
   hot-spots, and retry signals.
4. **LLM report** — the LLM reads `findings` and produces a structured report
   across six areas: Usage Patterns, Error Hotspots, User Friction, Retry
   Patterns, Context Exhaustion, and Recommendations. For the top
   high-correction sessions, the LLM reads the raw `.jsonl` file to understand
   what went wrong.
5. **Follow-up routing** — the report closes by asking which recommendations
   the user wants to act on (improve a script, create a new command,
   change a default).

## Example workflows

### Scenario: Monthly health review

```
/analyze-conversations          # surface issues from the past month
/task-capture "Harden X script based on error patterns"
/task-start <id>
```

Run periodically to catch systemic friction before it compounds.

### Scenario: Targeted project review

```
/analyze-conversations --project ~/projects/nuvia-api
```

Narrows the scan to one project when you already know where the friction is.

### Scenario: Report output

```
/analyze-conversations
```

```
Usage Patterns
  Top skills:  task-continue (42), git-commit (31), deploy-to-stage (18)
  Top tools:   Bash (1,204), Read (876), Edit (541)

Error Hotspots
  High-error sessions: 3 sessions with 5+ errors each (project: nuvia-api)
  Possible cause: deploy-to-stage.sh --verify exits non-zero on first health check

User Friction
  Top correction session: proj/nuvia-api/abc123.jsonl — user corrected 7 times
  Pattern: Claude staged unrelated files during /git-commit

Recommendations
  1. Improve: analyze-conversations.sh — add retry backoff to health check
  2. Create: /pre-commit-check — automate the manual lint+test step users repeat
  3. Config: reduce default --limit from unlimited to 200 (speed)

Which recommendation would you like to act on?
```

## Notes & gotchas

- Only `.jsonl` files are scanned; older plain-text logs are ignored.
- The incremental cache is keyed on file modification time; touching a file
  without changing it forces a re-analyze of that session.
- For high-correction sessions, the LLM reads the raw conversation file —
  these can be large. Use `--limit` to prevent context exhaustion when
  the project has thousands of sessions.
- **If it fails:** `fix_error` usually means no conversations were found (wrong
  directory) or a `jq` parse error on a malformed `.jsonl` file. Debug with
  `~/.claude/scripts/analyze-conversations.sh --raw --full` to see which file
  caused the parse failure.
