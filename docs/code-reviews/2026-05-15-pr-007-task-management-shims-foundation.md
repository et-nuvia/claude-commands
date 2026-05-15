# Code Review: PR #7 — Task management shim foundation

**PR**: https://github.com/et-nuvia/claude-commands/pull/7
**Branch**: `feat/task-management-shims` → `main`
**Author**: Eric Turner
**Reviewer**: Friendly AI Agent Assistant
**Date**: 2026-05-15
**Stats**: 1 commit · 8 files · ~880 lines added

---

## Summary

Foundation for [#4](https://github.com/et-nuvia/claude-commands/issues/4),
completing the shim trio with PRs #5 (git platforms) and #6 (secrets).
Adds a dispatcher (`scripts/lib/task-api.sh`) and four full adapters:
Asana (REST via PAT), GitLab Issues (reuses `gitlab_api` from #5),
GitHub Issues (gh CLI), and a `none` no-op. 6 bats contract tests
including a functional smoke test of `none`.

The architecture is sound and consistent with the prior two shims, but
the third adapter set is **substantially more complex** than the
previous foundations because (1) the contract has 11 functions vs 9-12
in the others, (2) status normalization spans four states across four
backends rather than two, and (3) Asana's CLI/MCP split required a
genuine design choice. Two real bugs slipped through that the
contract tests can't catch.

## Scores

| Category | Weight | Score | Weighted |
|---|---|---|---|
| Minimal Changes | 0.20 | **10** | 2.00 |
| Security | 0.25 | **9** | 2.25 |
| Best Practices | 0.20 | **7** | 1.40 |
| Code Quality | 0.15 | **7** | 1.05 |
| Testing | 0.10 | **7** | 0.70 |
| Documentation | 0.05 | **10** | 0.50 |
| Git Hygiene | 0.05 | **10** | 0.50 |
| **Overall** | | | **8.40 / 10** |

(Lower than #5's 8.75 and #6's 9.00. The bugs in M1/M2 below are why.)

## Critical Issues

None. Security clean:
- Trivy: 0 / 0 / 0 / 0
- Semgrep: 0 issues
- Gitleaks: 0 findings
- 16 "manual_secrets" are textual references in identifiers and doc
  text (`asana-token`, "Personal Access Token", etc.). No actual
  credentials. The Asana adapter correctly uses `Authorization:
  Bearer $(cat ...)` rather than embedding tokens in arg arrays.

## Major Issues

### M1 — `task_hold` in Asana doesn't actually mark held

**File**: `scripts/lib/task-backends/asana.sh:191-197`

```bash
task_hold() {
  ...
  task_comment "$id" "⏸️ On hold: ${reason}. Waiting on: ${waiting_on}." || return $?
}
```

This adds a comment but does NOT change any field that `_asana_normalize_task`
inspects to compute the `on_hold` status. The normalize function checks
`.memberships[].section.name` for "hold", but `task_hold` never moves
the task into such a section. As a result:

1. `task_hold $id` succeeds
2. `task_get $id` immediately after returns `"status": "open"` (not `"on_hold"`)
3. `task_list --state open` continues to return the held task

GitLab and GitHub adapters get this right — they apply the `on-hold`
label, and their normalize functions check for that label.

**Fix**: Either (a) move the task to a "Hold" section (requires
knowing or auto-creating the section), or (b) tag it via custom field,
or (c) add a non-destructive label-like prefix to the task name and
detect it in normalize. (a) is the canonical Asana convention.

Confidence: 95. Reproducible by reading the code; not caught by tests
because no functional test exists for the Asana adapter.

### M2 — `task_url` in `github-tasks.sh` makes a needless API call

**File**: `scripts/lib/task-backends/github-tasks.sh:115-118`

```bash
task_url() {
  local id="${1:?id required}"
  _gh_tasks issue view "$id" --json url -q .url
}
```

This costs a network round trip for what should be a deterministic
URL construction. Compare to `gitlab-tasks.sh` (which builds the URL
from `_GITLAB_TASKS_HOST` + repo) and `asana.sh` (which builds
`https://app.asana.com/0/0/${id}` without any API call).

For GitHub, the URL is always `https://github.com/<owner>/<repo>/issues/<id>`.
The owner/repo can come from PROJECT.yaml `.git.repo` or be auto-detected
from the git remote — same sources `_gh_tasks_repo()` already consults.

**Fix**:

```bash
task_url() {
  local id="${1:?id required}"
  local repo
  repo=$(_github_tasks_repo)
  if [[ -z "$repo" ]]; then
    repo=$(_gh_tasks repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null) || return 1
  fi
  echo "https://github.com/${repo}/issues/${id}"
}
```

Adds an API call only when PROJECT.yaml doesn't have `.git.repo`, and
even then it's `repo view` (cheap, cacheable) not `issue view`.

Confidence: 95.

## Minor Issues

### m1 — `task_search` in `github-tasks.sh` is not repo-scoped by default

**File**: `scripts/lib/task-backends/github-tasks.sh:108-114`

```bash
task_search() {
  local query="${1:?query required}"
  _gh_tasks search issues "$query" --limit 100 ...
```

`gh search issues "foo"` searches **all of GitHub** unless the query
includes a `repo:` qualifier. Other adapters scope to the project /
workspace automatically. Callers writing `task_search "auth bug"`
will get cross-org results, not project-local ones.

**Fix**: prepend `repo:<owner/repo>` to the query when a repo can be
determined:

```bash
local repo
repo=$(_github_tasks_repo)
[[ -z "$repo" ]] && repo=$(_gh_tasks repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)
[[ -n "$repo" ]] && query="repo:${repo} ${query}"
```

Confidence: 90.

### m2 — `task_create` `section` arg is ambiguous in GitLab

**File**: `scripts/lib/task-backends/gitlab-tasks.sh:171-181`

```bash
if [[ "$section" =~ ^[0-9]+$ ]]; then
  extra_args+=(--data-urlencode "milestone_id=${section}")
else
  extra_args+=(--data-urlencode "labels=${section}")
fi
```

The `section` arg maps to milestone OR label based on numeric
detection. This is convenient but fragile:

- "42" → milestone_id=42 (works if a milestone with that ID exists)
- "v1.0" → label `v1.0` (silently — even though the user might mean
  milestone "v1.0")
- "Sprint 3" → label `Sprint 3` (probably wrong)

The contract README says `section` is "Asana sections, GitLab
milestones, GitHub projects" — implying users will pass
backend-aware values. The auto-detection is a UX shortcut that hides
a real ambiguity.

**Fix**: either drop the auto-detection (always treat as label,
document that milestone setting requires `task_update` after create),
or require an explicit prefix (`milestone:42` vs `label:v1.0`).

Confidence: 85.

### m3 — `task_resume` swallows errors silently

**Files**: `scripts/lib/task-backends/{asana,gitlab-tasks,github-tasks}.sh`

All three resume functions chain operations with `|| true` so they
won't fail if the task wasn't actually closed/held:

```bash
# github-tasks.sh
_gh_tasks issue reopen "$id" >/dev/null 2>&1 || true
_gh_tasks issue edit "$id" --remove-label "on-hold" >/dev/null 2>&1 || true
```

This is intentional best-effort behavior — good. But it ALSO swallows
real errors (auth failures, network issues). If both operations fail
for environmental reasons, `task_resume` still returns 0 and the
caller has no signal.

**Fix**: be best-effort on individual operations but check at least
ONE succeeded. Or track failures and return non-zero if every
operation failed.

Confidence: 80.

### m4 — Subshell while-read pattern in `task_list` / `task_search`

**Files**: `scripts/lib/task-backends/{asana,gitlab-tasks,github-tasks}.sh`

```bash
| jq -c '.[]' \
| while read -r task; do echo "$task" | _normalize_task; done \
| jq -sc .
```

The `while read | jq -sc` pattern works but is fragile:

1. `read -r` without setting IFS strips leading/trailing whitespace —
   not an issue with `jq -c` output (no leading whitespace) but worth
   being explicit
2. If the inner `jq` in `_normalize_task` fails, the `while` keeps
   going and the error is silently dropped
3. The pattern repeats verbatim across three adapters — a helper would
   DRY this

**Fix**: use a single `jq` pass to do the normalization on the array,
avoiding the subshell entirely:

```bash
# gitlab-tasks task_list
_gitlab_tasks_call GET "/projects/${proj}/issues?..." \
  | jq -c "[.[] | $_GITLAB_TASKS_NORMALIZE_JQ]"
```

where `_GITLAB_TASKS_NORMALIZE_JQ` is the jq object expression. Same
pattern PR #5 used for the GitLab pipeline status normalization.

Confidence: 80. Works today; cleaner to refactor.

### m5 — No functional tests for Asana / GitLab / GitHub adapters

**File**: `scripts/tests/test-task-api-contract.bats`

Only the `none` adapter has a functional smoke test. The three real
adapters get the grep-based contract-completeness check only. The
bugs in M1 (asana task_hold) and M2 (github task_url inefficiency)
would have been caught by even basic functional tests against mocked
responses.

**Fix**: not blocking — functional tests for the real adapters need
mock harnesses (curl mocks for asana/gitlab-tasks, `gh` stub for
github-tasks). Worth a follow-up issue.

Confidence: 90.

## Positive Highlights

- **Scope discipline maintained for the third time**: foundation only,
  no migrations, even when the migration would obviously demonstrate
  the framework working end-to-end. This is now a clearly established
  pattern across #5, #6, #7.
- **Normalized schema is genuinely useful**: 4 states across 4
  backends, mapped explicitly in the README's status table. A caller
  writing "show me all on_hold tasks across both my work and home
  envs" no longer needs platform-specific code.
- **Asana adapter handles the MCP-vs-CLI split honestly**: the README
  explicitly documents that Claude sessions still use `mcp__asana__*`
  tools, and the shim exists for the script-driven path. Doesn't
  pretend MCP is universal.
- **Cross-shim reuse**: `gitlab-tasks.sh` sources `git-api.sh` and
  reuses `gitlab_api()` for HTTP+auth. Not pure duplication. The two
  shim systems are now coherent.
- **Per-adapter status normalization** with raw escape hatch
  (`.raw.state`) follows the same pattern as the pipeline status
  normalization in PR #5. Cross-PR consistency.
- **Dispatcher aliases** (`gitlab` → `gitlab-tasks`, `github` →
  `github-tasks`) let users write the natural short name in PROJECT.yaml
  while keeping the adapter filenames distinct from
  `git-platforms/{gitlab,github}.sh`. No collision.
- **Relationship to git-platform shims documented**: the README's
  closing section explains when to use `git_issue_*` vs `task_*`. This
  prevents the "wait, which abstraction do I use?" question that
  would otherwise arise.
- **`none` adapter consistency**: same shape and exit codes as the
  `none` backends in #6. Predictable behavior for opt-out users.
- **Stderr-to-exit-2 translation** in `_asana_call` and `_gh_tasks_get`
  mirrors the patterns from `_gh_get` (#5) and `_infisical_call` /
  `_aws_call` (#6). The "translate 404 → exit 2" convention is now
  established across all three shim systems.
- **Profile example updated** to document the new accepted values
  (`asana | gitlab | gitlab-tasks | github | github-tasks | none`)
  rather than just adding them silently.

## File-by-File Notes

| File | Notes |
|---|---|
| `scripts/lib/task-api.sh` | 70 lines. Clean. No issues. |
| `scripts/lib/task-backends/README.md` | Excellent. Status mapping table + Asana special case + git-platforms relationship section. |
| `scripts/lib/task-backends/asana.sh` | Apply M1 (real hold mechanism). Otherwise solid. |
| `scripts/lib/task-backends/gitlab-tasks.sh` | Apply m2 (section→milestone ambiguity). Cross-shim reuse is nice. |
| `scripts/lib/task-backends/github-tasks.sh` | Apply M2 (URL build) and m1 (search repo scoping). |
| `scripts/lib/task-backends/none.sh` | 30 lines. Simple, correct. |
| `scripts/tests/test-task-api-contract.bats` | Apply m5 (functional tests as follow-up). |
| `profiles/default.yaml.example` | One comment edit, correct. |

## Recommendations

**Merge?** Yes, after addressing M1 and M2.

**Suggested fixes before merge** (~30 min):

- **M1** — Implement real `task_hold` in Asana. Even the simplest
  version (add a "Held" custom field or move to a "Hold" section if
  one exists, fall back to comment-only with a stderr warning) is
  better than the current silent no-op.
- **M2** — Replace the API call in github-tasks `task_url` with
  deterministic URL construction.

**Defer to follow-up PR**:

- **m1** — github-tasks `task_search` repo scoping (5 minutes; can
  bundle with M2)
- **m2** — gitlab-tasks `section` disambiguation (small but needs a
  call on the API surface)
- **m3** — `task_resume` error handling refinement
- **m4** — refactor while-read to single-jq-pass (DRY win, not
  correctness)
- **m5** — functional tests with mocked CLIs/HTTP — separate "test
  infrastructure" PR

**Post-merge sequencing**:

1. Fix M1 + M2 (small commit on this branch), then merge.
2. With #5, #6, and this PR all merged, the three shim foundations
   are complete. Migration tracks are unblocked.
3. **Cross-cutting follow-up**: m5 (functional tests with mocks) is
   worth doing across all three shim systems at once — the test
   infrastructure (curl mocks, `gh` stub, `infisical` stub, `aws`
   stub) is reusable, and adding it now prevents future regressions
   on the migration PRs.

The foundation is sound and ready to merge after the two M-level
fixes. The minor items are real but don't block.

---

*Friendly AI Agent Assistant*
