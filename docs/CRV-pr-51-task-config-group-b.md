# Code Review — PR #51: task-management group B (config/validation)

**Branch:** `refactor/migrate-task-config-group-b`
**Commits:** `e72f94e` (#12 common.sh), `771a401` (#20 get-task-config.sh)
**Scope:** 2 files, 59 net lines added across `scripts/common.sh` and `scripts/get-task-config.sh`

## Summary

The PR routes tracker URL construction through the task adapter's `task_url` (good intent, with one correctness regression) and consolidates four OS-based backend fallbacks behind a profile-aware helper (clean, minor cleanup opportunity). Worth fixing the one regression before merge; the rest is fine.

---

## Findings

### 1. `task_url` ignores the explicitly-passed `tracker_backend` — **HIGH** (confidence: 95)

**File:** `scripts/common.sh:144-148`

`write_current_task` accepts an explicit `$tracker_backend` argument (one of `asana|gitlab|github`). The new code calls `task_url "$tracker_id"` and uses the returned URL — but `task_url` resolves the URL against the **active** backend (`.task_management.backend` from PROJECT.yaml or profile), not the parameter:

- `task-backends/asana.sh:151` → `https://app.asana.com/0/0/${id}` (active backend gate)
- `task-backends/gitlab-tasks.sh:151` → `_gitlab_tasks_project_id` (reads PROJECT.yaml)
- `task-backends/github-tasks.sh:...` → `_github_tasks_full_repo` (reads PROJECT.yaml)

**Failure mode:** a caller passing `tracker_backend=github` (or `gitlab`) in a project whose active backend is `asana` will get a `https://app.asana.com/0/0/<github-issue-id>` URL — non-empty, so the fallback case-branch never runs, and the wrong URL is written into `.current-task`.

**Why this matters:** the entire reason `write_current_task` accepts an explicit `$tracker_backend` is to support mixed scenarios (e.g., an Asana-tracked project that occasionally references a GitHub issue). Pre-migration, the case-branch respected that parameter exactly. Post-migration, the parameter is overridden whenever the adapter loads.

**Fix:** only call `task_url` when the explicit `$tracker_backend` matches the active backend. Otherwise fall through to the case-branch:

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

Alternative: drop the `task_url` call entirely and keep the original case-branch. The URLs are deterministic strings; the migration was nominal here, and the regression isn't worth the centralization.

---

### 2. Unused `task-api.sh` source in `get-task-config.sh` — **LOW** (confidence: 90)

**File:** `scripts/get-task-config.sh:34-35`

The script sources `lib/task-api.sh` but never calls any function from it. `_resolve_backend_default` uses only `profile_env_get`, which is already provided by `lib/load-profile.sh` (sourced on line 33).

**Effect:** harmless — extra source latency, slightly more state in scope.

**Fix:** remove the `source "${SCRIPT_DIR}/lib/task-api.sh"` line. The change still satisfies the spirit of #20 (the script consults the profile via the canonical lib).

---

### 3. `validate-project.py` (#42) — no code change, AC already satisfied — **INFO**

PR body closes #42 with a no-op. Verified by reading the file: it's a pure PROJECT.yaml schema validator, uses `subprocess` only for `git describe --tags`, and has zero direct backend calls. Token-file existence checks (`~/.asana-token`, `~/.gitlab-token`) are filesystem checks, not backend calls.

The judgment to close as already-satisfied is sound. If the team wants connectivity validation, that's an additive change tracked separately.

---

## Tests

PR did not add tests. Pre-existing bats failures (27) are unchanged on this branch (verified via comparison with `main`). No regressions introduced.

The high-severity finding (#1) is **not covered** by existing tests — there's no test that exercises `write_current_task` with a mismatched `tracker_backend` parameter. If finding #1 is fixed, a regression test in `scripts/tests/test-task-commands.bats` or similar would be cheap insurance.

---

## Security

No security-relevant changes. Tokens are still read from filesystem; no new credential paths; no new network calls.

---

## Recommendation

Block merge on finding #1 (correctness regression in `write_current_task` for cross-backend tracker references). The fix is mechanical. Findings #2 is a small cleanup that can go in the same fix commit.

If the team confirms `tracker_backend` is always the active backend in practice (i.e., `write_current_task` is never called with a mismatched explicit parameter), finding #1 downgrades to LOW and merge can proceed with a follow-up.
