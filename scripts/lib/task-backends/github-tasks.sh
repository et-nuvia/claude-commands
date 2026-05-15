#!/usr/bin/env bash
# task-backends/github-tasks.sh — GitHub Issues adapter for the task contract.
#
# Uses the gh CLI for all operations. Adds task-lifecycle semantics on
# top of GitHub Issues: hold/resume via labels, status normalization,
# normalized JSON schema.
#
# Don't source this file directly — go through scripts/lib/task-api.sh.

if ! command -v gh >/dev/null 2>&1; then
  echo "task-backends/github-tasks.sh: gh CLI not installed" >&2
  return 1
fi

# Repo: PROJECT.yaml .git.repo wins; otherwise let gh auto-detect.
_github_tasks_repo() {
  if [[ -f PROJECT.yaml ]]; then
    local r
    r=$(yaml_get '.git.repo' PROJECT.yaml 2>/dev/null || true)
    if [[ -n "$r" && "$r" != "null" ]]; then echo "$r"; return; fi
  fi
  echo ""
}

_gh_tasks() {
  local repo
  repo=$(_github_tasks_repo)
  if [[ -n "$repo" ]]; then gh --repo "$repo" "$@"
  else gh "$@"; fi
}

# Translate "not found" stderr patterns to exit 2.
_gh_tasks_get() {
  local stderr rc
  stderr=$(mktemp)
  trap 'rm -f "$stderr"' RETURN
  if _gh_tasks "$@" 2>"$stderr"; then return 0; fi
  rc=$?
  if grep -qiE "could not resolve|not found|no .* found" "$stderr"; then
    return 2
  fi
  cat "$stderr" >&2
  return "$rc"
}

# jq snippet that maps one gh-json issue into the normalized task schema.
_GITHUB_NORMALIZE_JQ='{
  id: .number,
  title: .title,
  status: (
    if (.state | ascii_downcase) == "closed" then "closed"
    elif (((.labels // []) | map(.name)) | any(. == "on-hold")) then "on_hold"
    elif (((.labels // []) | map(.name)) | any(. == "in-progress")) then "in_progress"
    else "open" end
  ),
  assignee: (.assignees[0].login // null),
  created_at: .createdAt,
  updated_at: .updatedAt,
  url: .url,
  raw: .
}'

_GH_ISSUE_FIELDS='number,title,state,assignees,labels,url,createdAt,updatedAt,body'

# ----------------------------------------------------------------------
# Read
# ----------------------------------------------------------------------

task_get() {
  local id="${1:?id required}"
  _gh_tasks_get issue view "$id" --json "$_GH_ISSUE_FIELDS" | jq -c "$_GITHUB_NORMALIZE_JQ"
}

task_list() {
  local state="open" assignee_arg=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --state)    state="$2"; shift 2 ;;
      --assignee) assignee_arg=(--assignee "$2"); shift 2 ;;
      *) shift ;;
    esac
  done
  _gh_tasks issue list --state "$state" "${assignee_arg[@]}" --limit 100 \
       --json "$_GH_ISSUE_FIELDS" \
    | jq -c "[.[] | $_GITHUB_NORMALIZE_JQ]"
}

# Resolve owner/repo in form "owner/repo". Tries PROJECT.yaml first,
# then asks gh once (cheap; caches the result for the shell session).
_github_tasks_full_repo() {
  if [[ -n "${_GH_FULL_REPO_CACHED:-}" ]]; then
    echo "$_GH_FULL_REPO_CACHED"
    return
  fi
  local r
  r=$(_github_tasks_repo)
  if [[ -z "$r" ]]; then
    r=$(_gh_tasks repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null) || return 1
  fi
  _GH_FULL_REPO_CACHED="$r"
  echo "$r"
}

task_search() {
  local query="${1:?query required}"
  # Auto-scope to current repo unless the query already includes repo: qualifier
  if [[ ! "$query" =~ repo: ]]; then
    local repo
    repo=$(_github_tasks_full_repo 2>/dev/null)
    [[ -n "$repo" ]] && query="repo:${repo} ${query}"
  fi
  _gh_tasks search issues "$query" --limit 100 \
       --json "$_GH_ISSUE_FIELDS,repository" \
    | jq -c "[.[] | $_GITHUB_NORMALIZE_JQ]"
}

task_url() {
  local id="${1:?id required}"
  local repo
  repo=$(_github_tasks_full_repo) || return 1
  echo "https://github.com/${repo}/issues/${id}"
}

task_health() {
  if ! gh auth status >/dev/null 2>&1; then
    echo "task_health(github-tasks): gh CLI not authenticated (run: gh auth login)" >&2
    return 1
  fi
  return 0
}

# ----------------------------------------------------------------------
# Write
# ----------------------------------------------------------------------

task_create() {
  local title="${1:?title required}" body="${2:-}" section="${3:-}"
  local args=(--title "$title" --body "$body")
  # GitHub doesn't have sections; treat the arg as a label if provided
  [[ -n "$section" ]] && args+=(--label "$section")
  local url num
  url=$(_gh_tasks issue create "${args[@]}") || return $?
  num="${url##*/}"
  [[ "$num" =~ ^[0-9]+$ ]] || { echo "task_create: could not parse id from $url" >&2; return 1; }
  jq -nc --arg id "$num" --arg url "$url" '{id: ($id | tonumber), url: $url}'
}

task_update() {
  local id="${1:?id required}" field="${2:?field required}" value="${3:?value required}"
  case "$field" in
    title) _gh_tasks issue edit "$id" --title "$value" >/dev/null ;;
    body)  _gh_tasks issue edit "$id" --body "$value" >/dev/null ;;
    assignee) _gh_tasks issue edit "$id" --add-assignee "$value" >/dev/null ;;
    *)
      echo "task_update(github-tasks): unknown field '$field'" >&2
      return 3 ;;
  esac
}

task_close() {
  local id="${1:?id required}" comment="${2:-}"
  if [[ -n "$comment" ]]; then
    _gh_tasks issue close "$id" --comment "$comment" >/dev/null
  else
    _gh_tasks issue close "$id" >/dev/null
  fi
}

task_hold() {
  local id="${1:?id required}" reason="${2:?reason required}" waiting_on="${3:?waiting_on required}"
  task_comment "$id" "⏸️ On hold: ${reason}. Waiting on: ${waiting_on}." || return $?
  _gh_tasks issue edit "$id" --add-label "on-hold" >/dev/null
}

task_resume() {
  local id="${1:?id required}" comment="${2:-}"
  # Best-effort: try to reopen and remove hold label. Both individually
  # may legitimately fail (task wasn't closed; no hold label). But at
  # least ONE must succeed plus the comment, otherwise something is
  # actually wrong (auth/network) and we should signal.
  local reopen_rc=1 unlabel_rc=1
  _gh_tasks issue reopen "$id" >/dev/null 2>&1 && reopen_rc=0
  _gh_tasks issue edit "$id" --remove-label "on-hold" >/dev/null 2>&1 && unlabel_rc=0
  if [[ -n "$comment" ]]; then
    task_comment "$id" "▶️ Resumed: ${comment}" || return $?
  else
    task_comment "$id" "▶️ Resumed" || return $?
  fi
  # Comment succeeded above; if BOTH state ops also failed, surface a warning.
  if [[ "$reopen_rc" -ne 0 && "$unlabel_rc" -ne 0 ]]; then
    echo "task_resume(github-tasks): neither reopen nor label removal succeeded — task may already be in the desired state" >&2
  fi
  return 0
}

task_comment() {
  local id="${1:?id required}" body="${2:?body required}"
  _gh_tasks issue comment "$id" --body "$body" >/dev/null
}
