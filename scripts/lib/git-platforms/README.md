# Git Platform Adapters

This directory holds adapter shims for git platforms (GitHub, GitLab,
and any future provider). Scripts that need to work with issues, PRs,
or pipelines source `scripts/lib/git-api.sh`, which dispatches to the
adapter matching `profile_env_get .git.platform` (with PROJECT.yaml
override).

The goal: adding a new platform = one new file in this directory + one
case branch in the dispatcher.

## Usage from a calling script

```bash
source "${SCRIPT_DIR}/lib/git-api.sh"
load_git_adapter || exit 1

# Now the git_* functions are defined. Same call works for any platform.
git_issue_close 42 "Done in PR #99"
git_pipeline_status "$pipeline_id"
```

## Contract

Every adapter MUST implement every function below. All functions return
JSON on stdout (or empty), human-readable errors on stderr, and one of
the following exit codes:

| Code | Meaning |
|---|---|
| `0` | Success |
| `1` | Error (network, auth, validation, unexpected state) |
| `2` | Not found (the requested resource doesn't exist) |
| `3` | **Reserved.** Future contract additions that aren't yet implemented on every adapter should return `3` so callers can detect "this platform doesn't support that yet." Today, every function is implemented on every adapter — no function returns `3`. |

### Issues / work items

| Function | Args | Returns |
|---|---|---|
| `git_issue_get` | `<id>` | JSON `{id, title, state, assignee, labels, url, raw}` |
| `git_issue_list` | `[--state open\|closed\|all] [--assignee me\|<user>]` | JSON array |
| `git_issue_create` | `<title> <body>` | JSON `{id, url}` of new issue |
| `git_issue_close` | `<id> [comment]` | empty on success |
| `git_issue_comment` | `<id> <body>` | empty on success |
| `git_issue_label_add` | `<id> <label>` | empty on success |

### Pull / merge requests

| Function | Args | Returns |
|---|---|---|
| `git_pr_find_for_branch` | `<branch>` | JSON `{id, title, state, url}` or empty |
| `git_pr_create` | `<title> <body> [base]` | JSON `{id, url}` of new PR/MR |

### Pipelines / workflow runs

| Function | Args | Returns |
|---|---|---|
| `git_pr_list` | `[--state open\|closed\|all] [--limit N]` | JSON array `[{id, title, state, url, head_ref, base_ref, author, is_draft, raw}]` |
| `git_pr_get` | `<id>` | JSON `{id, title, state, url, head_ref, base_ref, author, body, additions, deletions, files_changed, created_at, raw}` |
| `git_pr_diff` | `<id>` | unified diff on stdout (see note) |
| `git_pr_checkout` | `<id>` | switches working tree to the PR head branch |
| `git_pipeline_list` | `[--ref <branch>] [--sha <sha>] [--limit N]` | JSON array `[{id, status, sha, ref, url, created_at}]` |
| `git_pipeline_status` | `<id>` | JSON `{id, status, conclusion, jobs}` |
| `git_pipeline_logs` | `<id> [job-name]` | log text on stdout (whole-pipeline or one named job) |
| `git_job_logs` | `<job_id> [--lines N]` | log text on stdout for a single job by native ID |
| `git_pipeline_watch` | `<id> [--interval SECONDS]` | blocks until terminal state; exit 0 on success, non-zero otherwise |

### Health

| Function | Args | Returns |
|---|---|---|
| `git_health` | — | exit 0 if auth/network OK, exit 1 with stderr details |

### Note on `git_pr_diff` output

GitHub's `gh pr diff` returns a full git unified diff including
`index <old_sha>..<new_sha> <mode>` lines. GitLab's API doesn't
expose blob SHAs in the `/changes` payload, so the synthesized
GitLab diff omits the `index` line. Standard diff parsers tolerate
this, but commands that round-trip through git (`git apply`,
`git apply --check`) require the `index` line and will reject
the GitLab output. If you need a true round-trippable diff on
GitLab, use `git_pr_checkout` and produce the diff locally with
`git diff <base>...HEAD`.

## Normalized status values

| Platform value | Normalized value |
|---|---|
| github: queued / in_progress | `running` |
| github: completed + success | `success` |
| github: completed + failure | `failed` |
| github: completed + cancelled | `cancelled` |
| gitlab: created / pending / running | `running` |
| gitlab: success | `success` |
| gitlab: failed | `failed` |
| gitlab: canceled | `cancelled` |

Use the normalized values in your scripts; the raw value is always
available under `.raw.status` if you need it.

## Adding a new adapter (e.g., Gitea)

1. Copy `gitlab.sh` as `<platform>.sh` — it has the simpler curl-based
   pattern and is closer to most self-hosted forge APIs than `github.sh`.
2. Implement every function in the contract. Use `_gitea_api()` (or
   equivalent) as your private low-level helper.
3. Add a case branch to `load_git_adapter()` in `../git-api.sh`.
4. Add the `<platform>` value as a valid choice in
   `profiles/default.yaml.example` under the `git.platform` field.

## Testing an adapter

```bash
# Force a specific adapter regardless of profile
GIT_ADAPTER_OVERRIDE=gitlab source scripts/lib/git-api.sh
load_git_adapter
git_health && echo OK || echo FAIL
```

## Why a flat namespace?

Function names like `git_issue_close` (not `gitlab::issue::close`) match
bash's lack of true namespacing. The dispatcher picks the adapter at
source time, so only one set of `git_*` functions exists per shell
session. This keeps call sites readable: `git_issue_close 42` reads as
prose, not as plumbing.
