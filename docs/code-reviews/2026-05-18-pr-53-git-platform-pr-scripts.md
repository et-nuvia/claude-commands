# PR #53 Review — git-platform PR scripts migration

**Branch:** `refactor/migrate-git-platform-pr-scripts` → `main`
**Commits:** 3 (`4183289` adapter extension, `49db96f` create-pr, `db8f53b` review-pr)
**Closes:** #13, #31
**Scope:** 5 files, 215 added / 93 removed

## Summary

Extends the git adapter contract with four PR functions (`git_pr_list`, `git_pr_get`, `git_pr_diff`, `git_pr_checkout`) — addressing gaps surfaced in PR #50's review — and migrates `review-pr.sh` and `create-pr.sh` onto them. The contract design and GitHub adapter are clean. The GitLab adapter has two real correctness gaps that introduce regressions in `review-pr.sh`. Recommend fixing both before merging or rolling forward.

## Scores

| Category | Weight | Score | Notes |
|---|---|---|---|
| Minimal Changes | 0.20 | 8 | Focused; GitLab `git_pr_get` is incomplete |
| Security | 0.25 | 9 | Trivy clean; pre-existing gitleaks placeholders unchanged |
| Best Practices | 0.20 | 7 | Major: commits regression on GitLab; minor: error-UX loss |
| Code Quality | 0.15 | 8 | Adapter design solid; small fallback/diff-format quibbles |
| Testing | 0.10 | 4 | No new tests for 4 new adapter functions |
| Documentation | 0.05 | 9 | README updated, commits + PR body excellent |
| Git Hygiene | 0.05 | 9 | 3 conventional commits, refs/closes proper |

**Weighted overall: 7.6**

## Critical Issues

_None._

## Major Issues

### M1 — GitLab `git_pr_get` doesn't fetch commits; `review-pr.sh` consumers get empty arrays

**File:** `scripts/lib/git-platforms/gitlab.sh` (the new `git_pr_get`), consumed in `scripts/review-pr.sh:section_fetch`
**Confidence:** 90

`git_pr_get` on GitLab fetches the MR object plus the `/changes` endpoint, then stuffs the result under `.raw` (with `changes` merged in). It **does not** call `/merge_requests/:id/commits`. So `.raw.commits` is undefined.

`review-pr.sh:section_fetch` then does:

```bash
PR_RAW_DATA=$(echo "$pr_normalized" | jq --argjson raw "$_raw" '{
  ...
  commits: ($raw.commits // [])
}')
```

GitLab consumers get `commits: []`. Pre-migration GitLab code explicitly fetched commits via a separate `curl`. This is a regression that breaks the LLM review workflow on GitLab projects (the model sees zero commits and can't reason about the change history).

**Fix:**

```bash
# in gitlab.sh git_pr_get, after the changes fetch:
local commits
commits=$(_gitlab_call GET "/projects/${proj}/merge_requests/${id}/commits" 2>/dev/null || echo "[]")

jq -c --argjson changes "$changes" --argjson commits "$commits" '{
  ...
  raw: (. + {changes: $changes, commits: $commits})
}' <<<"$raw"
```

GitHub's `git_pr_get` already includes commits in `.raw` via `gh pr view --json ...,commits`, so it's correct as-is.

### M2 — GitLab `git_pr_get` reports `changes_count` as `additions`

**File:** `scripts/lib/git-platforms/gitlab.sh:233`
**Confidence:** 85

```bash
additions: ($changes.changes_count // null),
deletions: null,
```

`changes_count` in GitLab's API is the count of **changed files**, not the number of added lines. Setting `additions` to this value is semantically wrong — downstream consumers (the LLM analysis) will think a 1-file 500-line change has `additions: 1`.

The pre-migration code on GitLab kept `LINES_ADDED=0, LINES_REMOVED=0` because the GitLab API doesn't expose per-MR add/delete counts in a single call. So neither version is fully correct, but the new version is *more wrong* (it puts a misleading number in the field instead of zero).

**Fix:** either

- Set `additions: null, deletions: null` and have consumers handle `null` semantics, **or**
- Compute additions/deletions from `.changes[].diff` by counting `^+` / `^-` lines per file. This is what the diff itself contains; one more `jq` pass adds the counts.

## Minor Issues

### m1 — `section_list` error-UX regression

**File:** `scripts/review-pr.sh:151`
**Confidence:** 90

Pre-migration:

```bash
if ! gh auth status >/dev/null 2>&1; then
    exit_with_json "error" "GitHub CLI not authenticated" "Run: gh auth login"
fi
# ... GitLab path had: "Create ~/.gitlab-token"
```

Post-migration:

```bash
load_git_adapter || exit_with_json "error" "Failed to load git adapter"
prs_json=$(git_pr_list --state open 2>&1 || echo "[]")
```

Auth failures now surface as `"Failed to load git adapter"` (when the adapter can't resolve) or get swallowed into the `|| echo "[]"` fallback (when `git_pr_list` returns non-zero because of auth). Users lose the actionable hint about how to fix auth.

**Fix:** call `git_health` after `load_git_adapter` and emit a platform-specific hint on failure. Or remove the `|| echo "[]"` fallback and report the real error from `git_pr_list`.

### m2 — `git_pr_checkout` silent fetch fallback

**File:** `scripts/lib/git-platforms/gitlab.sh:282`
**Confidence:** 85

```bash
git fetch origin "merge-requests/${id}/head:${target_branch}" 2>/dev/null \
  || git fetch origin "${target_branch}:${target_branch}" 2>/dev/null \
  || true
git checkout "$target_branch"
```

If **both** fetches fail, `|| true` swallows the failure and `git checkout "$target_branch"` runs anyway. The user sees a generic `pathspec '<branch>' did not match any file(s)` error instead of "couldn't fetch the MR head ref."

**Fix:** track success, error out before checkout if neither fetch worked:

```bash
if ! git fetch origin "merge-requests/${id}/head:${target_branch}" 2>/dev/null \
   && ! git fetch origin "${target_branch}:${target_branch}" 2>/dev/null; then
  echo "git_pr_checkout: failed to fetch MR #${id} head ref or branch ${target_branch}" >&2
  return 1
fi
git checkout "$target_branch"
```

### m3 — `git_pr_diff` GitLab synthesized diff is missing the `index` line

**File:** `scripts/lib/git-platforms/gitlab.sh:264`
**Confidence:** 80

Standard git unified diffs include an `index <old_sha>..<new_sha> <mode>` line between `diff --git` and `---/+++`. The GitLab API doesn't expose blob SHAs in the `/changes` payload, so the synthesized stream omits it. Most parsers tolerate this, but stricter ones (e.g., `git apply --check`) may reject the output.

**Fix:** acceptable as-is; document the limitation in `lib/git-platforms/README.md` so callers know not to feed `git_pr_diff` into `git apply` directly.

## Positive Highlights

- **Honest gap-surfacing in the PR body.** The behavior-change section calls out the things that might break (GitLab diff format differs slightly, downstream prompts looking for literal `gh pr create` need updating). This is the right level of detail.
- **Adapter contract is well-shaped.** Normalized schema with `.raw` escape hatch lets downstream consumers stay loosely coupled but still drop down when they need backend-specific fields.
- **GitHub adapter is straightforward and correct.** Direct `_gh` wrappers, normalized fields match `gh pr view --json` keys closely.
- **GitLab `git_pr_diff` synthesis is the right call.** Concatenating `.changes[].diff` into a unified-diff-shaped stream gives consumers one format regardless of backend.
- **Per-issue commit history.** Adapter extension is its own commit so it can be reverted independently of the script migrations.

## File-by-File Review

### `scripts/lib/git-platforms/github.sh` (+69)

Clean. All four new functions use the existing `_gh` / `_gh_get` wrappers. Normalized schema construction in `jq` is consistent with existing patterns.

### `scripts/lib/git-platforms/gitlab.sh` (+94)

See M1 (commits not fetched), M2 (changes_count mislabeled as additions), m2 (silent checkout fallback), m3 (missing index line). All four implementations are present and individually structured well; the issues are in semantics, not structure.

### `scripts/lib/git-platforms/README.md` (+4)

Four new contract entries added. Correctly placed. No issues.

### `scripts/create-pr.sh` (+5, -4)

Two strings updated. Cosmetic. Correct.

### `scripts/review-pr.sh` (+43, -89)

Substantive migration. Two backend branches in `section_list` collapsed into one adapter call (good). `section_fetch` does a careful remap from normalized → legacy PR_RAW_DATA shape (good, but consumes M1's empty commits). `section_security` checkout simplified (good). See m1 for the error-UX regression.

## Recommendations

1. **Fix M1 (GitLab commits)** before merge. One-block addition to `git_pr_get`, mechanical.
2. **Fix M2 (additions semantics)** before merge. Set to `null` if not computing from diff; otherwise add the computation.
3. **Fix m2 (silent checkout fallback)** in the same patch — it's a five-line change.
4. **Add a regression test** that exercises `git_pr_get` on a GitLab fixture and asserts `commits` is non-empty. Cheap insurance.
5. **Follow-up issue** for `git_health`-based error hints in `section_list` (m1). Doesn't need to block this PR but worth tracking.

---

_Reviewed by Friendly AI Agent Assistant_
