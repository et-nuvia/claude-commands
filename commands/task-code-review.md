---
name: task-code-review
description: Create a code review document for a task following the CRV template
user_invocable: true
---

## Tracking

> Output format is auto-detected (TOON for AI callers, JSON for CI/scripts). Use `--toon` or `--json` to override.

As your **first action**, before any other work, run:
```bash
~/.claude/scripts/track-command.sh --command "task-code-review" --event start
```

If the workflow encounters an unrecoverable error at any point, run:
```bash
~/.claude/scripts/track-command.sh --command "task-code-review" --event error \\
  --model "MODEL_ID" \\
  --error-msg "brief description of what failed"
```

You are a code review document creation assistant. Create comprehensive code review documents using the task-CRV template.

## Execute

```bash
~/.claude/scripts/task-code-review.sh --full
```

Script automatically:
- Identifies task from `.current-task` or task ID
- Discovers PR/MR from current branch (GitHub or GitLab), falls back to branch diff
- Captures diff to a temp file, computes stats, file list, and commit log
- Returns summary with `diff.pages` count telling you how many pages to fetch

## Load structural context (if available)

After the script returns, check if `.understand/graph.json` exists in cwd. If yes and the task ID is known (from `.current-task` or the task doc), pull ranked context:

```bash
~/.claude/scripts/understand-explore.sh --json --for-task <TASK_ID>
```

Take the top ~20 nodes and hold them alongside the diff. Most useful query for code review: **affected nodes beyond the diff** — the graph reveals callers and callees of changed symbols that the diff itself doesn't show, surfacing review hits the readability rubric alone would miss (e.g., a renamed symbol's stale callers). Skip silently if graph absent, no task ID, script errors, or empty result.

## Response Handling

### `analyze_code` — Summary ready, read the diff

The `--full` output includes:
- `stats`: files_changed, additions, deletions
- `diff.file`: path to the full diff on disk
- `diff_stats`: per-file line change summary
- `file_list`: all changed files
- `commit_log`: all commits on this branch
- `diff_source`: "pr", "mr", or "branch"

**Read the diff file directly** using the Read tool on `diff.file` path. For large diffs, use `offset`/`limit` to page through.

**Checkpoint large analyses**: if the diff is large (>500 lines or >10 files), save partial findings after every 2-3 files so the review can resume if interrupted:

```bash
~/.claude/scripts/task-code-review.sh --save-notes --task-id TASK_ID \
  --notes '{"files_reviewed":["src/foo.py","src/bar.py"],"findings":[{"file":"src/foo.py","line":42,"severity":"high","note":"..."}]}'
```

On resume, call `--load-notes --task-id TASK_ID` first; if `next_action == "resume_review"`, pick up from `notes.files_reviewed.length` onwards. The checkpoint file is deleted automatically when `--commit` succeeds.

**Model selection for analysis**: For large diffs (>500 lines or >10 files), dispatch the analysis to a subagent to keep the parent context clean. Choose the model based on what's being reviewed:
- **sonnet** (default): standard feature work, CRUD, config changes, docs, test additions
- **opus**: security-sensitive changes (auth, crypto, secrets handling), architectural changes (new services, schema migrations, API contracts), or cross-service coordination (>3 services touched)

The cost difference is ~5x — default to sonnet and only escalate when the diff genuinely requires deeper reasoning.

**Confidence scoring**: Only include findings in the CRV document with **confidence >= 80**. If you're unsure whether something is a real issue or a stylistic preference, skip it. Low-confidence noise wastes the reviewer's (and user's) attention. If you must note a low-confidence observation, prefix it with `(low confidence)` and put it in a separate "Notes" section, not in the main findings.

Then:
1. Analyze the diff across these dimensions (checkpoint as above for large diffs):
   - **Readability** (flag with confidence >= 80):
     - Nesting depth > 3 → suggest guard clauses / inversion
     - Related conditionals that could merge (e.g. auth + authz)
     - Complex boolean expressions inline → extract to named predicate
     - Duplicated logic across 2+ sites → extract to shared function
     - Cryptic identifiers (single-letter outside loops, abbreviations not in domain vocabulary)
   - **Correctness & security**: auth, input validation, secrets handling, injection vectors
   - **Performance**: N+1 queries, unnecessary allocations, blocking I/O on hot paths
   - **Testing**: coverage of changed lines, edge cases, mocking boundaries
   - **Documentation**: public APIs documented, non-obvious decisions explained
2. Create doc: `~/.claude/scripts/task-code-review.sh --json --create-doc`
3. Response contains `template` (CRV with scope pre-filled) and `crv_path`. Fill all `[LLM to fill in]` sections with your findings, write the completed document to `crv_path` using the Write tool.
4. Commit: `~/.claude/scripts/task-code-review.sh --json --commit`

### `display_summary` — Document committed
- Show CRV filename and commit hash
- If user asks to fix findings: apply fixes, run tests, then use `/git-commit` to commit the code fixes
- Always commit code fixes before proceeding to `/task-audit` or `/task-close`
- Format per [Completion Format](docs/reference/ux/task-completion.md).

### `fix_error` — Review failed
- Common: no `.current-task` file, task document missing
- If you want to target a specific PR: `--pr-url <url>`
- Debug: `~/.claude/scripts/task-code-review.sh --raw --full`
- Report per [Error Format](docs/reference/ux/error-blocker.md).

## Section Resumption

Resume from specific section after manual intervention:
- `--get-pr` — Skip task identification
- `--gather-info` — Skip PR discovery, go straight to diff capture
- `--create-doc` — Create CRV document skeleton (skips if CRV already exists)
- `--commit` — Commit existing CRV document (does NOT create a new one)

## Debugging

```bash
~/.claude/scripts/task-code-review.sh --raw --full
```

## Completion Tracking

When the workflow completes successfully, run:
```bash
~/.claude/scripts/track-command.sh --command "task-code-review" --event complete \
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
