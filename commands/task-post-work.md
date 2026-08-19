---
name: task-post-work
description: Run the full post-implementation pipeline — audit, arch review, code review, PR creation, and PR review — with a deterministic, gated fix-loop
user_invocable: true
---


> **Output format is auto-detected: TOON when an AI agent is the caller, JSON for tests/CI.** This is intentional — TOON carries the same fields in far fewer tokens. `--json` does NOT switch an LLM caller to JSON, and that is not a bug to work around. Read the TOON fields directly; never pipe script output through `jq`, a converter, or `head`/`tail`/`grep` to "fix" the format.


You are the **post-work pipeline orchestrator**. You do NOT decide the sequence or the gating — the `task-post-work.sh` state machine does. Your job is to execute the one phase it tells you to, report structured results back, and repeat until it says the pipeline is complete or blocked.

Each phase applies the same criteria and produces the same document type as its standalone command (`/task-audit`, `/task-arch-review`, `/task-code-review`, `/create-pr`, `/review-pr`). This command only chains them — it never replaces them. Two pipeline-specific deviations from standalone execution: on passes 2+ the review dispatch substitutes `incremental-reviewer` for the full reviewer (delta-scoped, ledger-aware), and when analysis is dispatched to a subagent the orchestrator writes the review doc from its findings.

## The pipeline (what the script enforces)

```
STAGE A (pre-PR):  task-audit  →  task-arch-review  →  task-code-review   ┐ fix-loop
STAGE B (PR):      create-pr   →  review-pr                                ┘ fix-loop
```

**Fix-loop severity ladder** (de-escalates each pass to force convergence — LLMs always find *something*):

| Pass | Fix findings at severity | On completion |
|------|--------------------------|----------------|
| 1 | **all** (critical, high, medium, low) | re-run reviews |
| 2 | critical, high, medium | re-run reviews |
| 3 | critical, high | re-run reviews |
| 4 | critical | re-run reviews |
| 5 | **verify only — fix nothing** | if any critical/high remain → **BLOCK**, else advance |

At any pass, if no findings remain **at or above the current threshold** and tests pass, the stage converges early and advances (lower-severity findings below the threshold are intentionally deferred, not fixed).

**Hard gates that halt the pipeline:**
- Failing tests that will not go green (surfaced by `task-audit`).
- Loop non-convergence: the verify pass (5) still finds critical or high.

Otherwise the pipeline runs fully automatically, including creating the PR.

## Severity normalization (CRITICAL — apply consistently every pass)

Each sub-command reports findings in its own vocabulary. Normalize **everything** to `{critical, high, medium, low}` before calling `--record-reviews`, and report `--tests pass|fail` from `task-audit`:

| Source | Maps to |
|--------|---------|
| `task-audit`: failing tests | `--tests fail` (a hard gate — always fix, all passes) |
| `task-audit`: uncovered service/helper w/ real logic | medium |
| `task-audit`: outstanding TODOs, minor recommendations | low |
| `task-arch-review`: HIGH candidate | high |
| `task-arch-review`: MEDIUM candidate | medium |
| `task-arch-review`: LOW candidate | low |
| `task-code-review`: security/breaking finding | critical |
| `task-code-review`: high-confidence correctness/perf finding | high |
| `task-code-review`: readability/medium-confidence finding | medium/low |
| `review-pr`: Critical issue | critical |
| `review-pr`: Major issue | high |
| `review-pr`: Minor issue | low |

Aggregate the counts **across all reviews that ran this pass** into a single object, e.g. `{"critical":1,"high":2,"medium":3,"low":4}`.

> `task-arch-review` normally asks the user per-candidate (fix in-place vs follow-up TSK). Inside this pipeline, treat every in-scope arch candidate as **fix in-place this pass** — do not pause to ask. Candidates *below* the current threshold that you are deferring may be spawned as follow-up TSKs via `/feature-to-task` after the pipeline completes.

## Step 1: Start the pipeline

```bash
~/.claude/scripts/task-post-work.sh --start
```

(Add `--task-id <id>` to target a specific task, or `--from-pass N` to resume at a later ladder pass.)

**Faster ladder experiment**: `export TASK_POST_WORK_START_PASS=3` makes every pipeline start at pass 3 (fix critical/high only, then verify). Transcript data shows passes 1–2 mostly churn on low-severity nits that the verify pass would have deferred anyway; starting at 3 typically saves one or two full review+fix cycles. `--from-pass` still overrides per-run. Unset the variable to return to the full ladder.

The script returns a `next_action`. **Follow it, then report back. Repeat.**

## Response Handling — drive the loop off `next_action`

### `run_reviews` — run this stage's reviews for the current pass
The response gives `stage`, `pass`, `threshold`, `fix_severities`, and **`docs_expected`** (the standalone documents this stage MUST leave behind).
1. Run **exactly the reviews the response's `reviews` field lists**, in that order, each exactly as the standalone command runs. The list is pass-aware:
   - `stage: pre_pr`, pass 1 and the verify pass → `/task-audit`, then `/task-arch-review`, then `/task-code-review`
   - `stage: pre_pr`, intermediate passes (2–4) → `/task-arch-review`, then `/task-code-review` only. **`/task-audit` is deliberately skipped** — `apply_fixes` already required green `make test` before `--record-fixes`, so re-auditing here would re-run a ~9-minute full suite that just passed. Report `--tests pass|fail` from that `apply_fixes` test run.
   - `stage: pr` → `/review-pr`
   **Subagent dispatch (default, model: sonnet):**
   - **Pass 1**: dispatch the heavy analysis to `code-reviewer` (full branch diff) / arch `Explore` subagents to keep context clean.
   - **Intermediate passes (2–4)**: dispatch the **`incremental-reviewer`** agent in **delta mode** instead of `code-reviewer`. Give it (a) the delta since the last reviewed commit — `git diff <last_reviewed_sha>...HEAD`, where `last_reviewed_sha` comes from the script's `run_reviews` response (or `--status` on resume); the agent expands to 1-hop callers itself — and (b) the **cumulative accepted-fixes ledger** from that same response (finding id → file:line → resolution → commit SHA). This prevents the fix→re-flag oscillation: hunks matching an accepted fix are intentional changes, not reverts, and must not be re-flagged.
   - **Verify pass (5)**: dispatch `incremental-reviewer` in **full mode** — the entire branch diff plus the cumulative ledger from all passes. The final gate re-checks that the whole branch is coherent (a fix that passed in isolation but subtly broke an assumption elsewhere gets caught here), while the ledger still prevents accepted fixes from being re-flagged as reverts. If the reviewer returns `oscillation_risk` entries, do NOT auto-fix them — surface them in the pass record and, if they survive to verify, in the blocked report as "reviewer disagreed with its own prior fix."
   A subagent's inline findings are NOT a substitute for the document. Every review phase MUST leave its standalone artifact on disk, exactly as the `docs_expected` field lists:
   - `pre_pr` → an **AUD** (task-audit), an **ARC** (task-arch-review), and a **CRV** (task-code-review), at `docs/active/<YYYY-MM>/<TASK_ID>-<DATETIME>-{AUD,ARC,CRV}-*.md` (V4 naming).
   - `pr` → the review-pr document at `docs/code-reviews/YYYY-MM-DD-pr-NNN-*.md`.
   When you dispatch to a subagent, **you (the orchestrator) write the doc** from the subagent's findings using that sub-command's template — the subagent returns data, you persist the artifact.
   **If a sub-command's script returns an empty/blank document path** (a known task-audit edge case) or otherwise doesn't write the file, do NOT skip it: construct the standard V4 path yourself (`<TASK_ID>-<datetime>-<TYPE>-<slug>.md` under `docs/active/<YYYY-MM>/`) and write the document from the findings + the sub-command's template.
2. Collect and normalize findings (table above) into one aggregate count object; determine `tests pass|fail` from the audit.
3. **Verify the artifacts exist before recording.** Confirm every doc named in `docs_expected` is now on disk for this task using the **Glob tool** — `docs/**/<TASK_ID>-*-{AUD,ARC,CRV}-*.md`, and `docs/code-reviews/*pr-<N>*` for STAGE B. Use Glob rather than shell `find`/`ls`: it never prompts, and an `ls` that matches nothing exits non-zero, which is indistinguishable from the artifact being missing for the wrong reason. Only on later passes where a doc already exists, update/append to it rather than duplicating. If any expected doc is missing, write it now — do not proceed to `--record-reviews` with a missing artifact.
4. Report back — the script decides what happens next:
   ```bash
   ~/.claude/scripts/task-post-work.sh --record-reviews \
     --findings '{"critical":0,"high":0,"medium":0,"low":0}' --tests pass
   ```

### `apply_fixes` — fix the in-scope findings for this pass
The response gives `fix_severities` (which severities to fix) and `in_scope_findings` (how many).
1. **Dispatch the `fix-implementer` agent (model: sonnet)** with the full findings list (id, severity, file:line, description, suggested fix), the current threshold, and the project's test command. It fixes every finding at or above the threshold (never below — deferring is how the loop converges), fixes failing tests regardless of threshold (hard gate), verifies `make test` green, and commits (single-purpose, conventional, no AI attribution).
2. **Record the ledger in the state file via `--record-fixes` (step 4)** — that is the durable copy the next pass consumes. Also append it to the current pass's review doc (CRV/ARC) under an "Accepted fixes (pass N)" heading for human readers. Treat `disputed` entries as still-open findings for the next pass; treat `failed` entries as unfixed (they will block at verify if critical/high).
3. Only fix inline yourself (no dispatch) when `in_scope_findings` ≤ 2 and the fixes are single-file trivial — and still record the same ledger.
4. Report back with the fix commit SHA and the `fix-implementer` ledger:
   ```bash
   ~/.claude/scripts/task-post-work.sh --record-fixes --sha <fix-commit-sha> \
     --ledger '[{"id":"F1","file":"path.py:42","resolution":"...","commit":"<sha>"}]'
   ```
   The script stores `last_reviewed_sha` (the next pass's delta baseline), appends to the cumulative `ledger` in its state file, advances to the next pass (lower threshold), and returns `run_reviews` carrying `review_mode` (`delta` for passes 2–4, `full` for verify), `last_reviewed_sha`, and the **cumulative ledger** — hand those straight to `incremental-reviewer`. A pipeline resumed in a fresh session recovers all three from `--status` (the state file), so never fall back to a blind full-branch re-review on passes 2–4.

### `run_create_pr` — STAGE A converged, create the PR
1. Run `/create-pr` exactly as standalone (it pushes the branch and opens the PR/MR).
2. Report back:
   ```bash
   ~/.claude/scripts/task-post-work.sh --record-pr-created
   ```
   The script starts STAGE B (review-pr fix-loop at pass 1).

### `run_pr_review` — run review-pr for the current pass
Same as `run_reviews` but the review is `/review-pr` against the open PR. Normalize its Critical/Major/Minor issues, then `--record-reviews`. When applying fixes in STAGE B, push the commits (so the PR updates) before the next `run_pr_review` pass re-reviews them.

### `display_summary` (status `pipeline_complete`) — done
Report to the user, per [Completion Format](docs/reference/ux/task-completion.md):
- Confirm all stages converged, PR URL, and the AUD/ARC/CRV/review documents produced. **List each artifact's path** — if any of AUD/ARC/CRV/review-doc is missing, write it before declaring the pipeline complete (a converged pipeline with a missing document is not complete).
- Summarize each stage's convergence (how many passes, findings fixed) from `--status` history.
- Note any below-threshold findings you deferred and suggest `/feature-to-task` for them.
- Suggest `/task-close` as the next step.

### `fix_error` (status `blocked`) — pipeline halted
The response gives `blocked_reason` plus surviving `critical`/`high` counts (or failing tests). Per [Error Format](docs/reference/ux/error-blocker.md):
- Stop the automatic loop. Do **not** create/advance the PR.
- Show the user exactly what survived the verify pass (with `file:line` refs from the last CRV/review doc) and why it couldn't be auto-fixed within the ladder.
- Recommend manual intervention, then re-verify with **`--resume-from-pass 5`** — NOT `--start --from-pass 5`, which wipes the state file (history, ledger, `last_reviewed_sha`) and forces the very blind full re-review the ledger exists to prevent. Record the manual fixes in the same call so the re-verify knows they're intentional:
  ```bash
  ~/.claude/scripts/task-post-work.sh --resume-from-pass 5 --sha <manual-fix-commit> \
    --ledger '[{"id":"F9","file":"path.py:42","resolution":"manual fix: ...","commit":"<sha>"}]'
  ```
  For deeper rework, recommend `/task-continue` instead.

## Inspecting / resetting

```bash
~/.claude/scripts/task-post-work.sh --status                 # show state + pass history (incl. ledger, last_reviewed_sha)
~/.claude/scripts/task-post-work.sh --resume-from-pass N     # re-enter an existing pipeline at pass N, preserving history/ledger (optional --sha/--ledger record manual fixes)
~/.claude/scripts/task-post-work.sh --reset                  # clear state to restart clean
~/.claude/scripts/task-post-work.sh --raw --status           # debug
```
`--start --from-pass N` is for **fresh** pipelines only — it re-initializes state and empties the ledger. To re-enter an in-flight or blocked pipeline, always use `--resume-from-pass`.

## Guardrails

- **Never skip a phase or reorder** — always do exactly what the returned `next_action` says. The determinism is the point.
- **Never fix below the current threshold** — that defeats convergence and can loop forever on nits.
- **Failing tests are always fixed** and always block at verify — never proceed with red tests.
- Each sub-command still produces its normal document and can be run alone; this orchestrator adds sequencing + gating only.
- **Never record reviews without the artifacts.** Every pass, the documents named in the response's `docs_expected` (AUD/ARC/CRV for `pre_pr`, the review-pr doc for `pr`) MUST exist on disk before `--record-reviews`. Dispatching analysis to a subagent does not waive this — the orchestrator writes the doc from the subagent's findings. A missing doc is a bug in the run, not an acceptable optimization.

