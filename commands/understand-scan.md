---
name: understand-scan
description: Build or refresh the per-project understanding graph at .understand/graph.json via a 4-stage subagent pipeline (scan → file-analyze → architecture → assemble).
user_invocable: true
---

You are the orchestrator for the `/understand-scan` multi-agent pipeline. The script does deterministic file enumeration, hashing, and schema validation; you dispatch the four subagent stages and feed their outputs back to the script for validation and writing.

## Tracking

> Output format is auto-detected (TOON for AI callers, JSON for CI/scripts). Use `--toon` or `--json` to override.

As your **first action**, before any other work, run:
```bash
~/.claude/scripts/track-command.sh --command "understand-scan" --event start
mkdir -p .understand
( flock -n 9 || { echo "another /understand-scan is in progress (.understand/scan.lock held)"; exit 1; } ) 9>.understand/scan.lock
```

If the workflow encounters an unrecoverable error at any point, run:
```bash
~/.claude/scripts/track-command.sh --command "understand-scan" --event error \
  --model "MODEL_ID" \
  --error-msg "brief description of what failed"
```

## Cost guard

Read `.understand/config.json` if it exists and note `cost_ceiling_usd` (default `5`). Track cumulative LLM cost across the four stages. If it would exceed the ceiling, **abort** with: _"Cost ceiling $X exceeded; rerun with a higher ceiling in .understand/config.json."_ Do not silently continue.

## Execute

```bash
RESULT=$(~/.claude/scripts/understand-scan.sh --json --full)
```

Read `next_action` from `RESULT` and proceed.

## Response Handling

### `dispatch_file_analyzers`

The script returned a `plan` with `mode` (`scan` or `incremental`) and a `file_list` once you re-invoke the scan section. Workflow:

1. **Re-invoke the section the plan specifies** — either `understand-scan.sh --json --scan` (full) or `understand-scan.sh --json --incremental` (rescan against `.understand/graph.json` meta.file_hashes). Capture `file_list`, `count`. If `count == 0` (incremental, nothing changed), report _"No changes since last scan"_ and finish without dispatching subagents.

2. **Dispatch the project-scanner subagent** (1×, **model: sonnet**) with the prompt at `@prompts/understand/understand-project-scanner.md`. Pass: `cwd` (absolute), `commit_sha` (from `git rev-parse --short HEAD`), `project_knowledge_excerpt` (first ~2KB of `docs/architecture/PROJECT-KNOWLEDGE.md` if it exists, else null), and `files` (the `file_list`). Capture its output: `layers[]`, `file_roles[]`, `stack_notes`.

3. **Dispatch file-analyzer subagents in parallel batches** (N×, **model: sonnet**) using `@prompts/understand/understand-file-analyzer.md`. One dispatch per entry in `file_list` whose role/tier from the scanner is `tier1` or `tier2`. Send batches of **5–10 parallel dispatches per round** (single message, multiple tool calls) to stay inside the parent context budget. For each dispatch pass: `path`, `content` (read the file), `file_hash` (from `file_list`), `role` (from scanner), `layers` (from scanner), and the `project_knowledge_excerpt`. Collect per-file outputs: `nodes[]` and `edges[]`. **Skip `tier3` files entirely** — do not dispatch any subagent for them. They appear in `meta.file_hashes` (so incremental scans still detect changes) but contribute no nodes or edges.

4. **Dispatch the architecture-analyzer subagent** (1×, **model: opus**) with `@prompts/understand/understand-architecture-analyzer.md`. Pass: `initial_layers` (from scanner), `stack_notes`, and the aggregated `nodes[]` / `edges[]` from every file-analyzer. Capture: finalized `layers[]` (with colors) and `layer_overrides[]`.

5. **Dispatch the assemble-reviewer subagent** (1×, **model: opus**) with `@prompts/understand/understand-assemble-reviewer.md`. Pass: `meta` (commit_sha, `scanned_at` = current ISO-8601 UTC, `file_hashes` = `{path: hash}` map from `file_list`), the finalized `layers[]`, all per-file `nodes[] + edges[]`, and `layer_overrides[]` from architecture-analyzer. The subagent returns one complete graph JSON document. **Write that document to a staged path** `.understand/graph.staging.json` using the Write tool.

6. **Validate and persist** by calling:
   `~/.claude/scripts/understand-scan.sh --json --assemble --results-file .understand/graph.staging.json`
   Parse `next_action` from this call:
   - `display_summary` → graph written to `.understand/graph.json`. Proceed to "Completion".
   - `retry_assemble` → handle below.

### `retry_assemble`

The staged graph failed schema validation. The result contains `ajv_error` (a string).

1. **Re-dispatch the assemble-reviewer subagent** with the original inputs **plus** an `ajv_error` field containing the validator's message. Instruct it to repair and re-emit a complete graph that fixes the listed violations.
2. Overwrite `.understand/graph.staging.json` with the new output and re-call `understand-scan.sh --json --assemble --results-file .understand/graph.staging.json`.
3. **Retry budget: max 2.** If a second `retry_assemble` is returned, **stop** and surface the ajv error to the user with: _"Assemble-reviewer failed schema validation twice — see error above. Inspect `.understand/graph.staging.json` to debug."_ Do not loop further.

### `display_summary`

The graph is valid and written. Report to the user:
- Path: `.understand/graph.json`
- Mode: full scan vs incremental, and number of files analyzed
- Node count, edge count, layer count (read from the file via the Read tool — one read is fine)
- Cumulative cost vs ceiling
- Reminder: `.understand/graph.json` is committed by default; the rest of `.understand/` is gitignored (see CLAUDE.md "Understand-Anything Graph Storage")

### `fix_error`

Something the script can't recover from (missing schema, bad flags, unreadable results file). Debug with the block below, then surface the message to the user.

## Completion Tracking

When the workflow completes successfully, run:
```bash
~/.claude/scripts/track-command.sh --command "understand-scan" --event complete \
  --model "MODEL_ID" \
  --complexity COMPLEXITY \
  --tokens TOKENS_ESTIMATED \
  --cost COST_ESTIMATED
```

Replace values before calling:
- `MODEL_ID` — the model currently in use (from system context, e.g., `claude-opus-4-7`)
- `COMPLEXITY` — 1-5 based on: 1=read-only analysis, 2=single-file/simple git, 3=multi-file feature,
  4=cross-system/staging deploy, 5=production/infrastructure/security
- `TOKENS_ESTIMATED` — rough estimate of context used (input + output tokens combined)
- `COST_ESTIMATED` — approximate cost in USD based on model pricing

## Debugging

```bash
~/.claude/scripts/understand-scan.sh --raw --full
~/.claude/scripts/understand-scan.sh --raw --scan
~/.claude/scripts/understand-scan.sh --raw --validate
```

## See also

- Script: `scripts/understand-scan.sh` (file enumeration, hashing, ajv validation, graph write)
- Schema: `schemas/understand-graph.schema.json` (single source of truth)
- Subagent prompts: `prompts/understand/understand-{project-scanner,file-analyzer,architecture-analyzer,assemble-reviewer}.md`
- Config: `.understand/config.json` keys — `cost_ceiling_usd`, `max_file_size_kb`, `exclude_globs`
