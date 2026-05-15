# Code Review: PR #5 — Git platform shim foundation

**PR**: https://github.com/et-nuvia/claude-commands/pull/5
**Branch**: `feat/git-platform-shims` → `main`
**Author**: Eric Turner
**Reviewer**: Friendly AI Agent Assistant
**Date**: 2026-05-15
**Stats**: 1 commit · 5 files · +756 / −33

---

## Summary

Foundation for [#1](https://github.com/et-nuvia/claude-commands/issues/1).
Introduces a dispatcher (`scripts/lib/git-api.sh`) that picks a git
platform adapter at source time based on profile / PROJECT.yaml /
override, plus two full adapter implementations (`gitlab.sh`,
`github.sh`) under `scripts/lib/git-platforms/`. Adds a contract README
that codifies the 12-function interface and 4 bats tests that enforce
every adapter implements every function via grep.

**No script migrations.** This is deliberate: the foundation is a
coherent unit and merging it lets parallel migration PRs branch off
`main`. The PR description spells out the upcoming migration groups
explicitly.

The work is well-scoped, well-tested for what it commits to, and
designed for extensibility (the README has a 4-step guide for adding
Gitea, Bitbucket, etc.).

## Scores

| Category | Weight | Score | Weighted |
|---|---|---|---|
| Minimal Changes | 0.20 | **10** | 2.00 |
| Security | 0.25 | **9** | 2.25 |
| Best Practices | 0.20 | **8** | 1.60 |
| Code Quality | 0.15 | **8** | 1.20 |
| Testing | 0.10 | **7** | 0.70 |
| Documentation | 0.05 | **10** | 0.50 |
| Git Hygiene | 0.05 | **10** | 0.50 |
| **Overall** | | | **8.75 / 10** |

## Critical Issues

None. Security scans returned clean:
- Trivy: 0 critical / 0 high / 0 medium / 0 secrets
- Semgrep: 0 issues
- Gitleaks: 0 findings
- 14 "manual_secrets" from grep are all token *variable references*
  (`GIT_TOKEN_FILE`, `PRIVATE-TOKEN: $(cat …)`, etc.) — no actual
  credentials introduced. Same false-positive pattern as PR #3.

> Note: the script set `critical_block: true` despite no real findings,
> because `manual_secrets > 0` triggers the flag regardless of content.
> Worth fixing in `review-pr.sh` someday so legitimate refactors don't
> trip the block — but that's the review tooling, not this PR.

## Major Issues

### M1 — Exit code 3 documented but not used

**File**: `scripts/lib/git-platforms/README.md`

The contract says functions return exit 3 for "unsupported on this
backend", but no current adapter actually returns 3 — both implement
every function fully. The exit code is reserved-but-unenforced, which
risks future drift (someone adds a new function to the contract but
only implements it in one adapter).

Either:
1. Mark exit 3 as "reserved for future use; do not return today" with a
   note, or
2. Add a contract test that runs each function with a dummy arg and
   confirms it doesn't crash with "command not found"

Confidence: 85.

### M2 — Only one positive load test

**File**: `scripts/tests/test-git-api-contract.bats`

The dispatcher test suite asserts:
1. Unknown platform rejected ✓
2. `gitlab` override loads correctly ✓
3. Every adapter implements every function (grep) ✓
4. Every adapter is sourceable in isolation ✓

It does NOT positively test `github` override loading. Test #4 iterates
through both adapters and sources each, but doesn't verify the
resulting function definitions stick (because each iteration runs in
its own bash subshell via `run bash -c`). A loaded github adapter
that's missing `git_health` would slip through.

Add a parameterized test like:

```bash
@test "dispatcher: load_git_adapter accepts github override" {
  GIT_ADAPTER_OVERRIDE=github run bash -c \
    'source scripts/lib/git-api.sh; load_git_adapter && declare -F git_health'
  [ "$status" -eq 0 ]
  [[ "$output" == *"git_health"* ]]
}
```

Confidence: 90.

## Minor Issues

### m1 — `_gitlab_normalize_status` helper used inconsistently

**File**: `scripts/lib/git-platforms/gitlab.sh:43-51, 196-204`

`_gitlab_normalize_status` is defined as a helper, but only called from
`git_pipeline_status`. `git_pipeline_list` (line ~190) replicates the
same normalization inline via jq. Either:

- Always use the helper (replace inline jq with bash post-processing), or
- Inline both occurrences (delete the helper)

Inline jq in `git_pipeline_list` is probably the better choice
performance-wise (one process vs N), but the inconsistency is a
maintenance risk: if the canonical status set changes, both spots need
updates and nothing flags the drift.

Confidence: 85.

### m2 — `_gitlab_project_id` returns empty string on total failure

**File**: `scripts/lib/git-platforms/gitlab.sh:18-32`

If PROJECT.yaml doesn't exist, no `git remote` is set, AND we're not in
a git repo at all, the function echoes empty string. Downstream calls
then build URLs like `/projects//issues/42` and get a confusing GitLab
404. Better to fail fast:

```bash
_gitlab_project_id() {
  ...
  if [[ -z "$id" || "$id" == "null" ]]; then
    echo "gitlab.sh: cannot determine project_id (set PROJECT.yaml .git.repo or run from a git repo)" >&2
    return 1
  fi
  echo "$id" | sed 's#/#%2F#g'
}
```

And every caller should `proj=$(_gitlab_project_id) || return $?`.

Confidence: 90.

### m3 — `git_pipeline_logs` all-jobs path is complex

**File**: `scripts/lib/git-platforms/gitlab.sh:225-237`

The "no job_name → concatenate all jobs" path uses a pipe to
`while read`, with a nested `jq` lookup inside the loop to get the job
name from a captured variable. It works, but it's read-once-and-think
code. A `for` loop over a jq-flattened list would be clearer:

```bash
jq -r '.[] | "\(.id):\(.name)"' <<<"$jobs" | while IFS=: read -r job_id name; do
  echo "=== job: $name ($job_id) ==="
  _gitlab_call GET "/projects/${proj}/jobs/${job_id}/trace" 2>/dev/null || true
done
```

Same behavior, fewer moving parts.

Confidence: 80.

### m4 — `git_pr_create` URL parsing is fragile

**File**: `scripts/lib/git-platforms/github.sh:142, 154`

```bash
num=$(echo "$url" | grep -oE '[0-9]+$')
```

This assumes the gh-printed URL ends in `/<number>`. It does today, but
if gh ever appends a fragment, query string, or trailing slash, the
parse fails silently and `id` becomes empty. Safer:

```bash
num=$(gh pr view "$url" --json number -q .number)
```

Two API calls instead of one, but never breaks on URL format changes.
Or: keep the regex but assert `[[ "$num" =~ ^[0-9]+$ ]]` and error out
otherwise.

Confidence: 85.

### m5 — 404/not-found handling inconsistent

**File**: `scripts/lib/git-platforms/{gitlab.sh,github.sh}`

The contract documents exit code 2 for "not found", and
`git_pr_find_for_branch` correctly returns 2 when no PR matches. But
other "get one thing" functions (`git_issue_get`, `git_pipeline_status`)
let the underlying API failure bubble up as exit 1, not 2. A caller
distinguishing "not found" from "auth/network error" has to inspect
stderr.

Either:
1. Translate API 404 → exit 2 in each get-style function, or
2. Acknowledge in the contract that exit 2 is only used by *list/find*
   operations, and update the README

Confidence: 80.

### m6 — Contract test won't catch `function foo {}` syntax

**File**: `scripts/tests/test-git-api-contract.bats:30-44`

```bash
if ! grep -qE "^${fn}\(\)" "$adapter"; then
```

This catches `git_issue_get()` but not `function git_issue_get {}`. Not
an issue today (all current functions use the parens style), but the
test silently passes for a function declared with `function` keyword
that has no `()`. Add a second alternation:

```bash
if ! grep -qE "^(${fn}\(\)|function ${fn}( |\{))" "$adapter"; then
```

Confidence: 95. Cosmetic; the convention is implicit.

## Positive Highlights

- **Scope discipline**: the PR explicitly does NOT migrate any
  existing scripts, even though the temptation to "do one easy
  migration to prove it works" is real. Splitting foundation from
  migrations is the right call for review readability.
- **Contract README**: the documentation in `git-platforms/README.md`
  is genuinely good. It includes the function table, JSON schema,
  status normalization rules, a 4-step adapter-add guide, and the
  rationale for the flat namespace. This is the kind of doc that
  prevents future "wait, how was this supposed to work?" tickets.
- **Grep-based contract test**: enforcing "every adapter implements
  every function" by scanning files (rather than runtime introspection
  that requires loading everything) is fast, simple, and runs without
  network access. Clever choice.
- **Idempotent loading**: both `_GIT_API_LOADED` and
  `_GIT_ADAPTER_LOADED` guards prevent double-source issues. The
  pattern matches `load-profile.sh` from PR #3 — good consistency.
- **Backwards compatibility**: the existing low-level `gitlab_api()`
  helper is preserved in the dispatcher file, so any script outside the
  new framework that uses it raw continues to work. No forced
  migration.
- **Status normalization**: collapsing 8+ GitHub workflow states and
  6+ GitLab pipeline states into 5 canonical values
  (`running|success|failed|cancelled|unknown`) is the right
  abstraction. Callers that switch on status no longer need
  platform-specific branches.
- **Sensible failure modes**: github.sh refuses to load if `gh` isn't
  installed (clean `return 1` at top-level when sourced). gitlab.sh
  falls back to `gitlab.com` if no instance configured. Neither leaves
  the dispatcher in a half-loaded state.
- **`GIT_ADAPTER_OVERRIDE` env var**: deliberately included so tests
  can force a specific adapter regardless of profile. This is the kind
  of testing affordance that's easy to forget when designing
  production code paths.
- **Bug caught mid-development**: the `local platform` → `local platform=""`
  fix during foundation building shows real verification, not just
  "looks right".

## File-by-File Notes

| File | Notes |
|---|---|
| `scripts/lib/git-api.sh` | 132 lines, refactored cleanly. Dispatcher + idempotency + preserved helper. No issues. |
| `scripts/lib/git-platforms/README.md` | 104 lines. Exemplary. Apply M1 (clarify exit 3). |
| `scripts/lib/git-platforms/gitlab.sh` | 261 lines. Apply m1, m2, m3, m5. |
| `scripts/lib/git-platforms/github.sh` | 226 lines. Apply m4, m5. |
| `scripts/tests/test-git-api-contract.bats` | 66 lines. Apply M2 (positive github test), m6 (function-syntax variant). |

## Recommendations

**Merge?** Yes — with no blockers.

**Suggested follow-up before merge** (~30 min, all small):

- **M2** — add positive github load test (5 lines)
- **m2** — `_gitlab_project_id` fail-fast (5 lines)
- **m6** — alternation in grep pattern (1 line)

**Defer to follow-up PRs** (let foundation merge, address in cleanup or
during migration work):

- **M1** — exit code 3 doc clarification
- **m1** — normalize_status consistency (decide direction first)
- **m3** — pipeline_logs readability
- **m4** — PR URL parsing safety
- **m5** — 404 → exit 2 across get-style functions (probably batch
  into one followup commit)

**Post-merge sequencing**:

1. Land this PR.
2. Optional: open small follow-up PR for the in-merge nits if they
   matter to you (M2 specifically is worth doing soon — it's the test
   coverage gap).
3. Start migration PR #1: task lifecycle group (`task-fetch.sh`,
   `task-hold.sh`, `task-capture.sh`, `lib/task-close-complete.sh`).
   Smallest group, exercises issues + PRs. Good first migration.
4. Then pipeline group, then PR creation group.
5. Lock-in PR: grep-based pre-commit hook blocking direct
   `gh`/`glab`/curl-to-API outside adapters.

The foundation is a good piece of work. Land it.

---

*Friendly AI Agent Assistant*
