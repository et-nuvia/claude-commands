# Changes to ~/.claude (Week of 2026-05-15 to 2026-05-22)

This document captures changes made in the `~/.claude` config repo that should be ported into the `claude-commands` project. The Understand-Anything command + script + reference doc files have already been copied across; everything else below requires manual application of diffs.

---

## 1. Understand-Anything Port (task 293A14) — Already Copied

Merged via squash commit `a0cde19` (MR !1), closed in `46c4565`.

**Files copied into this project:**

- `commands/understand-scan.md`
- `commands/understand-explore.md`
- `commands/understand-impact.md`
- `commands/understand.md`
- `scripts/understand-scan.sh`
- `scripts/understand-explore.sh`
- `scripts/understand-impact.sh`
- `scripts/understand-auto-update.sh`
- `scripts/install-understand-cron.sh`
- `docs/reference/understand-graph-schema.md`

**Still TODO for this port (not yet copied here):**

- `prompts/understand/understand-architecture-analyzer.md`
- `prompts/understand/understand-assemble-reviewer.md`
- `prompts/understand/understand-file-analyzer.md`
- `prompts/understand/understand-project-scanner.md`
- `schemas/understand-graph.schema.json`
- `scripts/tests/test-understand-auto-update.bats`
- `scripts/tests/test-understand-explore.bats`
- `.gitleaks.toml` (new file added with the port)
- Graph-integration blurbs appended to **12 existing commands**:
  `arch-explore.md`, `arch-grill.md`, `arch-interfaces.md`,
  `feature-performance.md`, `feature-refactor.md`, `feature-review.md`,
  `find-dead-code.md`, `predict-issues.md`, `refactor.md`,
  `task-code-review.md`, `task-design.md`, `task-plan.md`.
  Each got 1–26 lines instructing the command to auto-load `.understand/graph.json` after the PROJECT-KNOWLEDGE read.
- `CLAUDE.md` section: "Understand-Anything Graph Storage" (~23 lines covering `.understand/` gitignore policy, commands, auto-update cron, integration list).
- `.gitignore` rule: `.understand/*` plus `!.understand/graph.json`.

**Auto-update cron:** `scripts/install-understand-cron.sh` installs a nightly 3am job that walks `~/.claude/understand-watchlist.txt` and rescans repos whose graphs are stale (schema mismatch, age > 30d, > 20 commits, or > 10% files changed since scan). Successful rescans POST graph to the hosted viewer.

---

## 2. review-pr Fixes

### `ee71cff` — drop hand-rolled secret grep
**File:** `scripts/review-pr.sh` (–15 / +7 lines)

Removed the manual `grep -i token` step. It produced 18+ false positives per PR (DI-token references, TS type annotations, prose). Both `gitleaks` and `trivy fs --scanners secret` already run with tuned regexes for actual secret formats (AWS keys, GitHub PATs, JWTs).

### `9237d73` — use printf for GitLab project_id URL-encoding
**File:** `scripts/review-pr.sh` (4 lines)

`echo "$proj" | jq -sRr @uri` appends a trailing newline that becomes `%0A` in the URL, producing malformed GitLab API requests. Replace each `echo` with `printf '%s'`.

---

## 3. task-start Fix

### `c4adbbf` — push local default-branch commits first
**File:** `scripts/task-start.sh` (+17 lines)

If TSK/PLN commits land on `dev` directly before `/task-start` runs, branching off and later squash-merging the feature branch makes `origin/dev` diverge — `ff-only` pulls then fail. Fix: push the local ahead-commits before branching.

---

## 4. task-close Fixes

### `fbb21c4` — verify external merge before `--no-merge`
**File:** `scripts/lib/task-close-cleanup.sh` (+68 / –3 lines)

`--no-merge` previously trusted the caller's claim that an external squash-merge had happened, risking deletion of unmerged commits. New behavior: verify by patch-id that every feature commit has an equivalent on `origin/<target>`, and reconcile local target with origin (fast-forward, or refuse on divergence) before downstream cleanup runs.

### `7c06a06` — `--status` override consistency + short aliases
**Files:** `commands/task-close.md` (+2), `scripts/task-close.sh` (+28 / –16 lines)

Three bugs fixed in AI-mode close path:

1. `--status` now accepts short forms (`complete`/`defer`) in addition to full forms (`completed`/`deferred`). Previously `--status complete` fell through every dispatch branch and silently ran `section_defer`.
2. The case dispatch in `main()` re-read `STATUS` and compared against literal strings without honoring the AI override on most paths (only `--pre-verify` did). Now every dispatch path calls `apply_ai_status_override()` after `section_identify`.
3. `--full` no longer silently defaults to `section_defer` when `STATUS` is neither completed nor deferred — errors clearly and points the caller at `--status`.

Also updates `--complete` / `--defer` error messages and `task-close.md` to document the alias + override semantics.

---

## 5. task-code-review Doc Update

### `f0db826` — add readability rubric
**File:** `commands/task-code-review.md` (+11 / –1 lines)

Promotes readability to a first-class review dimension with concrete heuristics: nesting depth, merged conditionals, extracted predicates, duplication, naming. Replaces vague "code quality" prose so reviewers apply the rubric consistently.

---

## 6. Housekeeping

### `ff750d9` — move GitLab token to `~/.secrets/`
Standardize GitLab token storage under `~/.secrets/gitlab-token` (alongside other Infisical-managed files) instead of `~/.gitlab-token` directly in `$HOME`.

**Files touched** (path substitution `~/.gitlab-token` → `~/.secrets/gitlab-token`):
- `CLAUDE.md`
- `commands/task-capture.md`
- `docs/patterns/code-review.md`
- `docs/reference/deployment-scripts.md`
- `docs/reference/git-platforms.md`
- `docs/reference/gitlab-api.md`
- `docs/reference/task-intake.md`
- `docs/reference/task-management.md`
- `docs/workflows/release-notes-guide.md`
- `scripts/DEPLOYMENT_SCRIPTS.md`
- `scripts/README.md`
- `scripts/get-task-config.sh`
- `scripts/monitor-pipeline.sh`
- `scripts/project-config-detect.py`
- `scripts/review-pr.sh`
- `scripts/task-fetch.sh`
- `scripts/task-hold.sh`
- `scripts/tests/test-git-detect.bats`
- `scripts/validate-project.py`

(A global find/replace will do it.)

### `a7b0157` — gitignore `.DS_Store` and `scheduled_tasks.lock`
**File:** `.gitignore` (+4 lines). Adds macOS Finder metadata and the harness scheduler lock file. Also `git rm --cached` any existing tracked copies.

### `f3b5684` — enable agent push notifications
**File:** `settings.json` — set `"agentPushNotifEnabled": true`.

### `ce6d70e` — regenerate `tracking/analysis.html`
Refreshes the static tracking analysis snapshot. Re-run whatever generator the project uses for this file.

---

## Suggested Application Order

1. Housekeeping (`.gitignore`, `settings.json`, GitLab token path rename) — low risk, gets out of the way.
2. `task-code-review.md` readability rubric — pure doc change.
3. `review-pr.sh` two fixes — small, isolated.
4. `task-start.sh` push-first fix — isolated, but exercise with a test branch.
5. `task-close.sh` + `lib/task-close-cleanup.sh` — biggest behavioral changes; review carefully.
6. Finish the Understand-Anything port (prompts, schema, tests, command blurbs, CLAUDE.md section).
