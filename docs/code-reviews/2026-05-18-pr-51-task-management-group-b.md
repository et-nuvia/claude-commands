# PR #51 Review — task-management group B (config/validation)

**Branch:** `refactor/migrate-task-config-group-b` → `main`
**Commits:** `e72f94e` (#12 common.sh), `771a401` (#20 get-task-config.sh)
**Closes:** #12, #20, #42
**Scope:** 2 files, 59 net lines added (`scripts/common.sh`, `scripts/get-task-config.sh`); `scripts/validate-project.py` unchanged

## Summary

Continues the task-adapter migration started in PR #50. `common.sh` now prefers `task_url` for tracker URL construction with a fallback to the original case-branch; `get-task-config.sh` consolidates four OS-keyed backend fallbacks behind a profile-aware helper; `validate-project.py` closes #42 with no change (AC already satisfied — pure schema validator). One real correctness regression in `common.sh` should block merge; everything else is solid.

## Scores

| Category | Weight | Score | Notes |
|---|---|---|---|
| Minimal Changes | 0.20 | 9 | Focused; comments justify WHY |
| Security | 0.25 | 9 | See "Security" section — gitleaks hits are pre-existing false positives |
| Best Practices | 0.20 | 6 | High-severity correctness regression (finding #1) |
| Code Quality | 0.15 | 7 | Clean; one unused source line |
| Testing | 0.10 | 4 | No new tests; regression in #1 isn't covered |
| Documentation | 0.05 | 9 | Excellent commit messages, PR body, inline comments |
| Git Hygiene | 0.05 | 9 | One commit per issue, conventional commits, refs/closes proper |

**Weighted overall: 7.4**

## Critical Issues

_None confirmed._ Gitleaks reported 3 hits but they are pre-existing placeholder values, not introduced by this PR (see Security section).

## Major Issues

### M1 — `task_url` ignores the explicitly-passed `tracker_backend` parameter

**File:** `scripts/common.sh:144-148`
**Confidence:** 95

`write_current_task` accepts an explicit `$tracker_backend` argument. The new code calls `task_url "$tracker_id"`, but the adapter's `task_url` resolves the URL against the **active** backend (`.task_management.backend` from PROJECT.yaml/profile), not against the parameter passed in.

```bash
# scripts/lib/task-backends/asana.sh:151
task_url() {
  local id="${1:?id required}"
  echo "https://app.asana.com/0/0/${id}"  # Active = asana → always returns asana URL
}
```

**Failure mode:** a caller passing `tracker_backend=github` in a project whose active backend is `asana` gets `https://app.asana.com/0/0/<github-issue-id>` written into `.current-task` — non-empty, so the fallback case-branch never runs and the wrong URL persists.

**Fix:**

```bash
local active_backend
active_backend=$(yaml_get '.task_management.backend' PROJECT.yaml 2>/dev/null \
    || profile_env_get .task_management.backend 2>/dev/null || true)
if [[ "$tracker_backend" == "$active_backend" ]] \
    && declare -f load_task_adapter &>/dev/null \
    && load_task_adapter 2>/dev/null \
    && declare -f task_url &>/dev/null; then
  tracker_url=$(task_url "$tracker_id" 2>/dev/null || true)
fi
```

Or drop the `task_url` call entirely and keep the case-branch — the URLs are deterministic, and the migration was largely nominal for this function.

## Minor Issues

### m1 — Unused `task-api.sh` source in `get-task-config.sh`

**File:** `scripts/get-task-config.sh:34-35`
**Confidence:** 90

The script sources `lib/task-api.sh` but never calls a function from it. `_resolve_backend_default` uses only `profile_env_get`, which is already provided by `lib/load-profile.sh` (sourced on line 33). Safe to remove.

## Security

Trivy: clean. Semgrep: 0 issues. Manual secret grep: 0.

**Gitleaks flagged 3 hits, all pre-existing in commit `8049984` (initial import), not in this PR's diff:**

| File | Line | Match | Verdict |
|---|---|---|---|
| `docs/reference/asana-mcp-integration.md` | 113 | `asana_gid=1234567890123456` | Documentation placeholder |
| `docs/reference/asana-mcp-integration.md` | 1026 | `asana_gid=1234567890123456` | Documentation placeholder |
| `scripts/tests/test-common.bats` | 227 | `CT_ASANA_GID="1234567890123456"` | Test fixture |

`1234567890123456` is a 16-digit sequential placeholder, not a real Asana GID. Pre-existing; out of scope for this PR. Worth a follow-up to add gitleaks allowlist entries so future runs don't false-positive.

## Positive Highlights

- **Fallback discipline.** The migration keeps the hand-rolled case branch as a fallback when the adapter can't load. Behavior is preserved during early bootstrap.
- **Honest closure of #42.** PR body explains why `validate-project.py` doesn't need a code change rather than fabricating one to "close the issue." Good judgment.
- **Comments explain WHY.** Every new block has a comment giving the reasoning (centralization, profile-first resolution, fallback intent).
- **Commit messages.** One commit per issue, conventional commit format, body explains the constraint being preserved. Easy to revert if needed.

## File-by-File Review

### `scripts/common.sh` (+22, -11)

- **Top-of-file source block** (lines 14-21): correctly conditional on `declare -f load_task_adapter` not already being defined. Idempotent. Good.
- **`write_current_task` URL construction** (lines 141-176): see M1.
- Fallback case-branch is preserved verbatim — minimizes regression surface.

### `scripts/get-task-config.sh` (+20, -3)

- **`_resolve_backend_default`** (lines 38-49): clean. Profile → OS-default fallback ordering is correct. Behavior unchanged for callers without a profile-configured backend.
- **3 call-site replacements** (lines 131, 252, 298): mechanical and correct.
- **`task-api.sh` source** (line 35): see m1.

### `scripts/validate-project.py` (no change)

PR body documents the no-op closure of #42. Verified: pure PROJECT.yaml schema validator, `subprocess` used only for `git describe --tags`, zero direct backend calls. Token-file existence checks are filesystem operations, not backend communication.

## Recommendations

1. **Fix M1 before merge.** Mechanical change; preserves the explicit-parameter contract.
2. **Optional: drop m1's unused source.** One-liner cleanup.
3. **Follow-up issue: gitleaks allowlist.** Add entries for the three documented placeholder GIDs so future security scans on this repo don't false-positive.
4. **Consider adding a regression test** that exercises `write_current_task` with `tracker_backend != active_backend`. Cheap insurance against M1 recurring.

---

_Reviewed by Friendly AI Agent Assistant_
