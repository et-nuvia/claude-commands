#!/usr/bin/env bash
# git-platforms/gitlab.sh — GitLab adapter for the git platform contract.
#
# All work goes through GitLab's REST API v4. Resolves host from profile
# .git.instance and reads the token from ~/.gitlab-token.
#
# Don't source this file directly — go through scripts/lib/git-api.sh,
# which handles dispatch and sets up the shared state.

# Resolve host + token file paths once.
_GITLAB_HOST="$(profile_env_get .git.instance 2>/dev/null)"
_GITLAB_HOST="${_GITLAB_HOST:-gitlab.com}"
_GITLAB_TOKEN_FILE="${GITLAB_TOKEN_FILE:-${HOME}/.gitlab-token}"

# Project ID resolution: try PROJECT.yaml first, then derive from remote.
# Exits 1 with a clear message if nothing resolves — prevents calls that
# would otherwise build URLs like /projects//issues/42 and confuse with
# upstream 404s.
_gitlab_project_id() {
  local id=""
  if [[ -f PROJECT.yaml ]]; then
    id=$(yaml_get '.task_management.gitlab.project_id' PROJECT.yaml 2>/dev/null || true)
    if [[ -z "$id" || "$id" == "null" ]]; then
      id=$(yaml_get '.git.repo' PROJECT.yaml 2>/dev/null || true)
    fi
  fi
  if [[ -z "$id" || "$id" == "null" ]]; then
    id=$(git remote get-url origin 2>/dev/null | sed 's#.*[:/]\(.*\)\.git#\1#' || true)
  fi
  if [[ -z "$id" || "$id" == "null" ]]; then
    echo "gitlab.sh: cannot determine project_id (set PROJECT.yaml .git.repo or run from a git repo)" >&2
    return 1
  fi
  # URL-encode '/' for the API
  echo "$id" | sed 's#/#%2F#g'
}

# Low-level wrapper that sets GIT_API_URL + GIT_TOKEN_FILE and delegates
# to gitlab_api() from git-api.sh.
_gitlab_call() {
  local method="$1" endpoint="$2"
  shift 2
  GIT_API_URL="https://${_GITLAB_HOST}/api/v4" GIT_TOKEN_FILE="$_GITLAB_TOKEN_FILE" \
    gitlab_api "$method" "$endpoint" "$@"
}

# Map a raw GitLab pipeline status to the normalized contract value.
# Used from both bash (git_pipeline_status) and jq (git_pipeline_list) —
# the jq form below MUST stay in sync with this case statement.
_gitlab_normalize_status() {
  case "$1" in
    success)                       echo "success" ;;
    failed)                        echo "failed" ;;
    canceled|cancelled)            echo "cancelled" ;;
    created|pending|running|preparing|waiting_for_resource|manual|scheduled) echo "running" ;;
    *)                             echo "unknown" ;;
  esac
}

# jq snippet that performs the same normalization on .status. Embed by
# string-pasting into a larger jq expression. Kept here so both
# occurrences live next to the bash version above.
#
# Uses `as $s` to capture .status before the inner pipe (otherwise the
# `index(...)` call would re-bind `.` and lose context).
_GITLAB_NORMALIZE_JQ='
  (.status as $s |
   if $s == "success" then "success"
   elif $s == "failed" then "failed"
   elif $s == "canceled" or $s == "cancelled" then "cancelled"
   elif (["created","pending","running","preparing","waiting_for_resource","manual","scheduled"] | index($s)) then "running"
   else "unknown" end)
'

# ----------------------------------------------------------------------
# Issues
# ----------------------------------------------------------------------

git_issue_get() {
  local id="${1:?id required}"
  local proj raw
  proj=$(_gitlab_project_id) || return 1
  raw=$(_gitlab_call GET "/projects/${proj}/issues/${id}") || return $?
  jq -c '{
    id: .iid,
    title: .title,
    state: .state,
    assignee: (.assignee.username // null),
    labels: .labels,
    url: .web_url,
    raw: .
  }' <<<"$raw"
}

git_issue_list() {
  local state="opened" assignee_filter=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --state)
        case "$2" in
          open)   state="opened" ;;
          closed) state="closed" ;;
          all)    state="all" ;;
          *)      state="$2" ;;
        esac
        shift 2 ;;
      --assignee)
        if [[ "$2" == "me" ]]; then
          assignee_filter="&assignee_id=$(_gitlab_call GET /user | jq -r .id)"
        else
          assignee_filter="&assignee_username=$2"
        fi
        shift 2 ;;
      *) shift ;;
    esac
  done

  local proj raw
  proj=$(_gitlab_project_id) || return 1
  raw=$(_gitlab_call GET "/projects/${proj}/issues?state=${state}${assignee_filter}&per_page=100") || return $?
  jq -c '[.[] | {
    id: .iid, title: .title, state: .state,
    assignee: (.assignee.username // null), labels: .labels,
    url: .web_url, raw: .
  }]' <<<"$raw"
}

git_issue_create() {
  local title="${1:?title required}" body="${2:-}"
  local proj raw
  proj=$(_gitlab_project_id) || return 1
  raw=$(_gitlab_call POST "/projects/${proj}/issues" \
    --data-urlencode "title=${title}" \
    --data-urlencode "description=${body}") || return $?
  jq -c '{id: .iid, url: .web_url}' <<<"$raw"
}

git_issue_close() {
  local id="${1:?id required}" comment="${2:-}"
  local proj
  proj=$(_gitlab_project_id) || return 1
  if [[ -n "$comment" ]]; then
    git_issue_comment "$id" "$comment" || true
  fi
  _gitlab_call PUT "/projects/${proj}/issues/${id}?state_event=close" >/dev/null
}

git_issue_comment() {
  local id="${1:?id required}" body="${2:?body required}"
  local proj
  proj=$(_gitlab_project_id) || return 1
  _gitlab_call POST "/projects/${proj}/issues/${id}/notes" \
    --data-urlencode "body=${body}" >/dev/null
}

git_issue_label_add() {
  local id="${1:?id required}" label="${2:?label required}"
  local proj
  proj=$(_gitlab_project_id) || return 1
  _gitlab_call PUT "/projects/${proj}/issues/${id}" \
    --data-urlencode "add_labels=${label}" >/dev/null
}

# ----------------------------------------------------------------------
# Merge requests (PRs in GitLab parlance)
# ----------------------------------------------------------------------

git_pr_find_for_branch() {
  local branch="${1:?branch required}"
  local proj raw
  proj=$(_gitlab_project_id) || return 1
  raw=$(_gitlab_call GET "/projects/${proj}/merge_requests?source_branch=${branch}&state=opened") || return $?
  local first
  first=$(jq -c '.[0] // empty' <<<"$raw")
  [[ -z "$first" ]] && return 2
  jq -c '{id: .iid, title: .title, state: .state, url: .web_url}' <<<"$first"
}

git_pr_create() {
  local title="${1:?title required}" body="${2:-}" base="${3:-}"
  local proj raw current
  proj=$(_gitlab_project_id) || return 1
  current=$(git symbolic-ref --short HEAD 2>/dev/null) || {
    echo "git_pr_create: cannot determine current branch" >&2; return 1
  }
  [[ -z "$base" ]] && base=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@origin/@@')
  [[ -z "$base" ]] && base="main"
  raw=$(_gitlab_call POST "/projects/${proj}/merge_requests" \
    --data-urlencode "source_branch=${current}" \
    --data-urlencode "target_branch=${base}" \
    --data-urlencode "title=${title}" \
    --data-urlencode "description=${body}") || return $?
  jq -c '{id: .iid, url: .web_url}' <<<"$raw"
}

# git_pr_list [--state open|closed|all] [--limit N]
git_pr_list() {
  local state="opened" limit=30
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --state)
        case "$2" in
          open)   state="opened" ;;
          closed) state="closed" ;;
          all)    state="all" ;;
          *)      state="$2" ;;
        esac
        shift 2 ;;
      --limit) limit="$2"; shift 2 ;;
      *)       shift ;;
    esac
  done
  local proj raw
  proj=$(_gitlab_project_id) || return 1
  raw=$(_gitlab_call GET "/projects/${proj}/merge_requests?state=${state}&per_page=${limit}") || return $?
  jq -c '[.[] | {
    id: .iid,
    title: .title,
    state: (.state | sub("^opened$"; "open")),
    url: .web_url,
    head_ref: .source_branch,
    base_ref: .target_branch,
    author: .author.username,
    is_draft: (.draft // .work_in_progress // false),
    raw: .
  }]' <<<"$raw"
}

# git_pr_get <id>
git_pr_get() {
  local id="${1:?id required}"
  local proj raw changes
  proj=$(_gitlab_project_id) || return 1
  raw=$(_gitlab_call GET "/projects/${proj}/merge_requests/${id}") || return $?
  # changes endpoint gives per-file diffs and counts
  changes=$(_gitlab_call GET "/projects/${proj}/merge_requests/${id}/changes" 2>/dev/null || echo "{}")
  jq -c --argjson changes "$changes" '{
    id: .iid,
    title: .title,
    state: (.state | sub("^opened$"; "open")),
    url: .web_url,
    head_ref: .source_branch,
    base_ref: .target_branch,
    author: .author.username,
    is_draft: (.draft // .work_in_progress // false),
    body: .description,
    additions: ($changes.changes_count // null),
    deletions: null,
    files_changed: (($changes.changes // []) | length),
    created_at: .created_at,
    raw: (. + {changes: $changes})
  }' <<<"$raw"
}

# git_pr_diff <id>
# Fetch the unified diff for an MR by id. GitLab doesn't return a
# single concatenated unified diff like gh pr diff — it returns
# per-file change objects under .changes[].diff. Concatenate them
# into a unified-diff-shaped stream so callers see the same format
# regardless of backend.
git_pr_diff() {
  local id="${1:?id required}"
  local proj changes
  proj=$(_gitlab_project_id) || return 1
  changes=$(_gitlab_call GET "/projects/${proj}/merge_requests/${id}/changes") || return $?
  jq -r '.changes[]? |
    "diff --git a/\(.old_path) b/\(.new_path)\n" +
    (if .deleted_file then "deleted file mode \(.b_mode // "100644")\n" else "" end) +
    (if .new_file then "new file mode \(.b_mode // "100644")\n" else "" end) +
    "--- a/\(.old_path)\n+++ b/\(.new_path)\n" + .diff
  ' <<<"$changes"
}

# git_pr_checkout <id>
# Fetch the MR head and switch the working tree to it. Uses the
# Git refs that GitLab exposes for MRs (refs/merge-requests/<iid>/head).
git_pr_checkout() {
  local id="${1:?id required}"
  local proj target_branch
  proj=$(_gitlab_project_id) || return 1
  # Resolve the source_branch so we have a human-friendly local name
  target_branch=$(_gitlab_call GET "/projects/${proj}/merge_requests/${id}" \
                  | jq -r '.source_branch') || return $?
  git fetch origin "merge-requests/${id}/head:${target_branch}" 2>/dev/null \
    || git fetch origin "${target_branch}:${target_branch}" 2>/dev/null \
    || true
  git checkout "$target_branch"
}

# ----------------------------------------------------------------------
# Pipelines
# ----------------------------------------------------------------------

git_pipeline_list() {
  local ref="" sha="" limit=10
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --ref)   ref="$2";   shift 2 ;;
      --sha)   sha="$2";   shift 2 ;;
      --limit) limit="$2"; shift 2 ;;
      *)       shift ;;
    esac
  done

  local proj qs="per_page=${limit}"
  proj=$(_gitlab_project_id) || return 1
  [[ -n "$ref" ]] && qs="${qs}&ref=${ref}"
  [[ -n "$sha" ]] && qs="${qs}&sha=${sha}"
  local raw
  raw=$(_gitlab_call GET "/projects/${proj}/pipelines?${qs}") || return $?
  jq -c "[.[] | {
    id: .id,
    status: (${_GITLAB_NORMALIZE_JQ}),
    sha: .sha, ref: .ref, url: .web_url, created_at: .created_at, raw: .
  }]" <<<"$raw"
}

git_pipeline_status() {
  local id="${1:?id required}"
  local proj raw jobs
  proj=$(_gitlab_project_id) || return 1
  raw=$(_gitlab_call GET "/projects/${proj}/pipelines/${id}") || return $?
  jobs=$(_gitlab_call GET "/projects/${proj}/pipelines/${id}/jobs?per_page=100") || jobs="[]"
  local normalized
  normalized=$(_gitlab_normalize_status "$(jq -r .status <<<"$raw")")
  jq -c --arg status "$normalized" --argjson jobs "$jobs" '{
    id: .id,
    status: $status,
    conclusion: (if .status == "success" or .status == "failed" or .status == "canceled"
                 then .status else null end),
    jobs: ($jobs | map({id: .id, name: .name, status: .status, url: .web_url})),
    raw: .
  }' <<<"$raw"
}

git_pipeline_logs() {
  local id="${1:?id required}" job_name="${2:-}"
  local proj jobs
  proj=$(_gitlab_project_id) || return 1
  jobs=$(_gitlab_call GET "/projects/${proj}/pipelines/${id}/jobs?per_page=100") || return $?

  if [[ -n "$job_name" ]]; then
    local job_id
    job_id=$(jq -r --arg n "$job_name" '.[] | select(.name == $n) | .id' <<<"$jobs" | head -1)
    if [[ -z "$job_id" ]]; then
      echo "git_pipeline_logs: no job named '$job_name' in pipeline $id" >&2
      return 2
    fi
    _gitlab_call GET "/projects/${proj}/jobs/${job_id}/trace"
  else
    # Concatenate logs from all jobs. Emit "id:name" pairs from jq, then
    # split in bash — no nested jq lookup inside the loop.
    jq -r '.[] | "\(.id):\(.name)"' <<<"$jobs" | while IFS=: read -r job_id name; do
      echo "=== job: $name ($job_id) ==="
      _gitlab_call GET "/projects/${proj}/jobs/${job_id}/trace" 2>/dev/null || true
    done
  fi
}

# git_job_logs <job_id> [--lines N]
# Fetch logs for a single job by its native ID.
git_job_logs() {
  local job_id="${1:?job_id required}"
  shift || true
  local lines=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --lines) lines="$2"; shift 2 ;;
      *)       shift ;;
    esac
  done
  local proj
  proj=$(_gitlab_project_id) || return 1
  if [[ -n "$lines" ]]; then
    _gitlab_call GET "/projects/${proj}/jobs/${job_id}/trace" | tail -n "$lines"
  else
    _gitlab_call GET "/projects/${proj}/jobs/${job_id}/trace"
  fi
}

# git_pipeline_watch <id> [--interval SECONDS]
# Poll until the pipeline reaches a terminal state. GitLab has no
# native watch, so we poll git_pipeline_status. Emits status lines
# to stderr; exit 0 if success, non-zero otherwise.
git_pipeline_watch() {
  local id="${1:?id required}"
  shift || true
  local interval=10
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --interval) interval="$2"; shift 2 ;;
      *)          shift ;;
    esac
  done
  local status
  while :; do
    status=$(git_pipeline_status "$id" | jq -r '.status') || return 1
    echo "pipeline ${id}: ${status}" >&2
    case "$status" in
      success)               return 0 ;;
      failed|cancelled)      return 1 ;;
      *)                     sleep "$interval" ;;
    esac
  done
}

# ----------------------------------------------------------------------
# Health
# ----------------------------------------------------------------------

git_health() {
  if [[ ! -f "$_GITLAB_TOKEN_FILE" ]]; then
    echo "git_health(gitlab): token file not found: $_GITLAB_TOKEN_FILE" >&2
    return 1
  fi
  if ! _gitlab_call GET /user >/dev/null; then
    echo "git_health(gitlab): auth or network failure for $_GITLAB_HOST" >&2
    return 1
  fi
  return 0
}
