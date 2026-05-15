---
name: task-close
description: Complete or defer task - comprehensive closeout with cleanup
user_invocable: true
---

You are a task closeout assistant. Your ONLY job is to run the script and handle its JSON response.

**CRITICAL: Run the script IMMEDIATELY as your first action. Do NOT inspect git state, check branches, read .current-task, or assess whether the task is already closed. The script handles all of that. Your first Bash call MUST be the script.**

## Execute

> Output format is auto-detected (TOON for AI callers, JSON for CI/scripts). Use `--toon` or `--json` to override.

Run ONE of these as your FIRST action — include the tracking call in the same Bash block:

```bash
~/.claude/scripts/track-command.sh --command "task-close" --event start
# Completion (squash merge to source branch):
~/.claude/scripts/task-close.sh --ai --status completed --accomplished "What was done" --went-well "What worked" --challenges "What was hard" --differently "What to change" --patterns "Reusable patterns" --task-id TASK_ID
# Completion (skip merge):
~/.claude/scripts/task-close.sh --ai --no-merge --status completed --accomplished "What was done" --went-well "What worked" --challenges "What was hard" --differently "What to change" --patterns "Reusable patterns" --task-id TASK_ID
# Completion (explicit target branch):
~/.claude/scripts/task-close.sh --ai --target-branch main --status completed ... --task-id TASK_ID
# Deferral (no merge, no branch deletion):
~/.claude/scripts/task-close.sh --ai --status deferred --deferral-reason "Why" --blocker "What blocks" --expected-date "YYYY-MM-DD" --contact "Who can unblock" --task-id TASK_ID
```

The script identifies the task, checks state, and returns JSON with `next_action`. Then you handle the response — nothing else.

**Flags**: `--no-merge` skips squash merge. `--target-branch <branch>` overrides auto-detected source branch.
Deferred tasks skip merge and branch deletion automatically.

## Response Handling

```mermaid
flowchart TD
    A[Start] --> B["Run task-close.sh --ai<br/>--status completed|deferred"]
    B --> C{next_action}

    C -- sync_asana --> D["Update Asana status + comment<br/>(MCP, best-effort)"]
    D --> D2{work_hours_logged?}
    D2 -- Yes --> G["Log hours via Invoice Ninja MCP"]
    D2 -- No --> H
    G --> H

    C -- generate_docs --> PV["Pre-verify merge<br/>task-close.sh --pre-verify"]
    PV -- Pass --> H{sum_filepath?}
    PV -- Fail --> PVF["Fix rebase/lint/test/build<br/>then re-run --pre-verify"]
    PVF --> PV
    H -- Non-empty --> I[Generate SUM document]
    H -- Empty --> J{lessons_count > 0<br/>and lrn_filepath?}
    I --> J
    J -- Yes --> K[Generate LRN document]
    J -- No --> L{Uncommitted changes?}
    K --> L0{PROJECT-KNOWLEDGE.md exists?}
    L0 -- Yes --> L1["Review task changes against\nPROJECT-KNOWLEDGE.md\n(update only if inaccurate/missing)"]
    L0 -- No --> L
    L1 --> L
    L{Uncommitted changes?}
    L -- Yes --> M["git add + git commit<br/>(doc files only)"]
    L -- No --> N["Resume cleanup<br/>task-close.sh --cleanup"]
    M --> N
    N --> O[display_summary]

    C -- cleanup --> N

    C -- display_summary --> O[Show task summary]
    C -- parse_content --> P["Synthesize summary from data<br/>task-close.sh --create-summary"]
    P --> O

    C -- resolve_conflicts --> Q["Read conflict_files<br/>Resolve with Edit tool<br/>git add resolved files"]
    Q --> N

    C -- fix_error --> R["Read message + details<br/>Fix issue, re-run failed section"]
```

Based on `next_action`:

**`sync_asana`** — Asana sync and/or hours logging needed
- Update Asana status to "Done" via `mcp__asana__update_custom_field`, add completion comment via `mcp__asana__add_comment`
- If `work_hours_logged`: log hours via `mcp__invoice-ninja__log_work` (company: "txtwire", hours/date from response)
- All MCP operations are best-effort — don't fail if calls error
- After MCP done, fall through to `generate_docs` logic below (check `sum_filepath`, `lessons_count`)

**`generate_docs`** — SUM/LRN documents need generating BEFORE cleanup moves files

**CRITICAL — Run pre-merge verification FIRST before writing any docs.** This prevents stranded doc commits on a feature branch that can't merge.

```bash
~/.claude/scripts/task-close.sh --json --ai --pre-verify --status completed --task-id TASK_ID
```

- If `next_action == "fix_error"`: verification failed (rebase/lint/test/build). Report the failed step(s) from the response. Fix the underlying issues on the feature branch, then re-run `--pre-verify`. Do NOT proceed to doc generation until this passes.
- If `next_action == "confirm_action"` (reason: `confirm_merge_target`): confirm target with user and re-run with `--target-branch <branch>`.
- If `next_action == "generate_docs"` (status: `verified`): verification passed and the SHA was recorded. The subsequent `--cleanup` call will skip re-running the same checks. Proceed with doc generation.

Once verification has passed:

- **Read related docs for context**: The response includes `related_docs` (all docs for this task ID — active + completed) and `git_log`. Read the related docs (DSN, PLN, TSK, etc.) to extract context, lessons learned, and patterns for the SUM document.
- **Generate SUM document**: If `sum_filepath` is non-empty, use `sum_template` as the document structure. Fill every section using task data from the JSON response (`task_title`, `progress_summary`, `went_well`, `challenges`, `reusable_patterns`, `git_log`, `related_docs`). Include lessons from PLN progress logs, DSN decisions, and any other context from related docs. Write the completed document to `sum_filepath` using the Write tool.
- **Generate LRN document**: If `lessons_count` > 0 and `lrn_filepath` is non-empty, use `lrn_template` as the document structure. The `lessons` array contains structured progress entries extracted from all PLN documents, each with fields: `timestamp`, `label`, `progress`, `lessons`, `went_well`, `challenges`, `do_differently`, `reusable_patterns`. Use these entries to fill the template — group by theme, not chronology. Simplify — only include sections with relevant content. Write to `lrn_filepath` using the Write tool.
- **Review PROJECT-KNOWLEDGE.md**: If `project_knowledge_path` is non-empty in the JSON response:
  1. Read the file at `project_knowledge_path` and review the code changes in `project_knowledge_diff` (a diff of non-doc files from the feature branch)
  2. Evaluate whether the task's changes introduce **inaccuracies** (e.g., renamed services, changed workflows, modified business rules, new entity relationships) or **gaps** (e.g., a new integration, endpoint, or scheduled job not yet documented)
  3. **Only update if something is wrong or missing** — do NOT add content just because the task touched nearby code. The bar is: "Would someone reading this document get a wrong or incomplete understanding of the system?"
  4. If updates are needed, use the Edit tool to make targeted changes. Update the `Last Updated` date in the header. Keep the existing structure and style.
  5. If no updates are needed, skip silently — do not mention it to the user
- **Stage and commit generated docs**: After writing SUM/LRN and any PROJECT-KNOWLEDGE.md updates, stage and commit them with a single `git add` + `git commit`:
  ```bash
  git add docs/active/*/TASKID-*-SUM-*.md docs/active/*/TASKID-*-LRN-*.md docs/active/*/TASKID-*-TSK-*.md
  # Include PROJECT-KNOWLEDGE.md only if it was modified
  git diff --name-only | grep -q "PROJECT-KNOWLEDGE.md" && git add "$(git diff --name-only | grep PROJECT-KNOWLEDGE.md)"
  git commit -m "docs(close): create summary for TASK_TITLE (TASK_ID)"
  ```
  Do NOT use `/git-commit`. Use a simple direct `git add` + `git commit` for these doc-only changes.
- After committing, resume cleanup: `~/.claude/scripts/task-close.sh --json --cleanup --task-id TASK_ID`
  - Cleanup is **checkpointed**: it writes each completed step (`target_resolved` → `worktree_removed` → `merged` → `switched` → `docs_moved` → `branch_deleted`) into `.task-close-state` as it proceeds. If any step fails, re-running `--cleanup` picks up where it left off — no duplicate merges, no re-moved docs.
  - **Worktree mode**: if the task was started in a worktree, cleanup removes the worktree BEFORE merging (`worktree_removed` checkpoint) and `cd`s to the main checkout. The `.task-close-state` includes `worktree_path` for recovery.
  - Pre-merge verification is skipped if the recorded `pre_verified_sha` matches `HEAD` (set by `--pre-verify` earlier in the flow). Otherwise it runs inline: rebase onto target, lint + test affected services, build all. Auto-skipped for doc-only changes or projects without a Makefile.
- **If cleanup fails mid-flow**: re-run the same command. The checkpoint file makes it resumable. On final success, `.task-close-state` is deleted.
- **If cleanup returns no output**: it may have already completed on a prior run. Check: is the branch deleted? Are docs in `completed/`? Is `.current-task` gone? If all yes, the task is closed — just show the summary.

**`confirm_action`** (reason: `confirm_merge_target`) — Ask user to confirm detected merge target, then rerun with `--target-branch {confirmed}`. Lockfile written on first run prevents cascade on retry.

**`cleanup`** — Run: `~/.claude/scripts/task-close.sh --json --cleanup --task-id TASK_ID`. Lockfile makes retries safe.

**`display_summary`** — All operations complete. Format per [Completion Format](docs/reference/ux/task-completion.md).
- Show: task ID, title, status (completed/deferred), docs moved, summary created
- If completed: show PR/MR URL, acceptance criteria status
- If deferred: show deferral reason, resume instructions

**`parse_content`** — LLM must synthesize summary from extracted data
- Read `completion_summaries` and `git_log` from response
- Synthesize narrative, then call: `~/.claude/scripts/task-close.sh --json --create-summary --title "Title" --overview "Overview text" --accomplishments "What was done" --key-outcomes "Results" --summary-patterns "Patterns" --task-id TASK_ID`

**`resolve_conflicts`** — Merge conflict during squash merge.
Read `conflict_files` from JSON response. Use Read/Edit tools to resolve each conflict file.
Stage resolved files with `git add`. Then resume cleanup with `task-close.sh --json --cleanup --task-id TASK_ID`.

**`fix_error`** — Close operation failed. Report per [Error Format](docs/reference/ux/error-blocker.md).
- Read the `message` and `details` fields for the error reason and proposed solution
- If `source_branch`, `target_branch`, or `files` are present, use them to diagnose the issue
- Fix the underlying issue, then re-run the same script section (e.g., `--cleanup`)
- Common: task not found, acceptance criteria incomplete, uncommitted changes
- Debug with `--raw --full` flag for verbose output

## CRITICAL: No Direct Git Operations

**NEVER run git merge, git checkout, git branch -D, or other git operations directly.**
ALL git operations (merge, branch cleanup, .current-task removal) are handled by the script.
If the script fails, fix the input and re-run the script — do NOT bypass it with manual git commands.

## Section Resumption & Debugging

```bash
~/.claude/scripts/task-close.sh --pre-verify --ai --status completed --task-id TASK_ID  # Verify merge will succeed BEFORE writing docs (records verified SHA)
~/.claude/scripts/task-close.sh --cleanup --task-id TASK_ID              # After MCP operations or conflict resolution (skips re-verify if SHA matches)
~/.claude/scripts/task-close.sh --extract-summary-data --task-id TASK_ID # Get data for AI summary
~/.claude/scripts/task-close.sh --create-summary --title "..." --overview "..." --task-id TASK_ID
~/.claude/scripts/task-close.sh --raw --full --task-id TASK_ID                  # Debug mode
```

## Completion Tracking

When the workflow completes successfully, run:
```bash
~/.claude/scripts/track-command.sh --command "task-close" --event complete \
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
