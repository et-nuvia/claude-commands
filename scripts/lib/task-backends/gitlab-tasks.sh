#!/usr/bin/env bash
# task-backends/gitlab-tasks.sh — GitLab Issues adapter for the task contract.
#
# Reuses the low-level gitlab_api() helper from ../git-api.sh for HTTP +
# auth. Adds task-lifecycle semantics on top: hold/resume via labels,
# status normalization, normalized JSON schema.
#
# Required config (PROJECT.yaml > profile fallback):
#   .task_management.gitlab.project_id  — "org/repo" form, or derived from remote
#
# Don't source this file directly — go through scripts/lib/task-api.sh.

# Pull in gitlab_api low-level helper.
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/../git-api.sh"

_GITLAB_TASKS_HOST="$(profile_env_get .git.instance 2>/dev/null)"
_GITLAB_TASKS_HOST="${_GITLAB_TASKS_HOST:-gitlab.com}"
_GITLAB_TASKS_TOKEN_FILE="${GITLAB_TOKEN_FILE:-${HOME}/.gitlab-token}"

# Project ID resolution: PROJECT.yaml task_management.gitlab.project_id
# → PROJECT.yaml git.repo → derive from git remote.
_gitlab_tasks_project_id() {
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
    echo "gitlab-tasks.sh: cannot determine project_id" >&2
    return 1
  fi
  echo "$id" | sed 's#/#%2F#g'
}

_gitlab_tasks_call() {
  local method="$1" endpoint="$2"
  shift 2
  GIT_API_URL="https://${_GITLAB_TASKS_HOST}/api/v4" GIT_TOKEN_FILE="$_GITLAB_TASKS_TOKEN_FILE" \
    gitlab_api "$method" "$endpoint" "$@"
}

# Map a GitLab issue into the normalized task schema. State comes from
# labels for hold/in-progress; from state field for open/closed.
_gitlab_normalize_task() {
  jq -c '{
    id: .iid,
    title: .title,
    status: (
      if .state == "closed" then "closed"
      elif ((.labels // []) | any(. == "on-hold")) then "on_hold"
      elif ((.labels // []) | any(. == "in-progress")) then "in_progress"
      else "open" end
    ),
    assignee: (.assignee.username // null),
    created_at: .created_at,
    updated_at: .updated_at,
    url: .web_url,
    raw: .
  }'
}

# ----------------------------------------------------------------------
# Read
# ----------------------------------------------------------------------

task_get() {
  local id="${1:?id required}"
  local proj
  proj=$(_gitlab_tasks_project_id) || return 1
  _gitlab_tasks_call GET "/projects/${proj}/issues/${id}" | _gitlab_normalize_task
}

task_list() {
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
          assignee_filter="&assignee_id=$(_gitlab_tasks_call GET /user | jq -r .id)"
        else
          assignee_filter="&assignee_username=$2"
        fi
        shift 2 ;;
      *) shift ;;
    esac
  done

  local proj
  proj=$(_gitlab_tasks_project_id) || return 1
  _gitlab_tasks_call GET "/projects/${proj}/issues?state=${state}${assignee_filter}&per_page=100" \
    | jq -c '.[]' \
    | while read -r issue; do echo "$issue" | _gitlab_normalize_task; done \
    | jq -sc .
}

task_search() {
  local query="${1:?query required}"
  local proj encoded
  proj=$(_gitlab_tasks_project_id) || return 1
  encoded=$(jq -nr --arg q "$query" '$q | @uri')
  _gitlab_tasks_call GET "/projects/${proj}/issues?search=${encoded}&per_page=100" \
    | jq -c '.[]' \
    | while read -r issue; do echo "$issue" | _gitlab_normalize_task; done \
    | jq -sc .
}

task_url() {
  local id="${1:?id required}"
  local proj
  proj=$(_gitlab_tasks_project_id) || return 1
  # Reverse the URL-encoded slash for the human-readable URL
  local repo
  repo=$(echo "$proj" | sed 's#%2F#/#g')
  echo "https://${_GITLAB_TASKS_HOST}/${repo}/-/issues/${id}"
}

task_health() {
  if [[ ! -f "$_GITLAB_TASKS_TOKEN_FILE" ]]; then
    echo "task_health(gitlab-tasks): token file not found: $_GITLAB_TASKS_TOKEN_FILE" >&2
    return 1
  fi
  if ! _gitlab_tasks_call GET /user >/dev/null; then
    echo "task_health(gitlab-tasks): auth or network failure" >&2
    return 1
  fi
  return 0
}

# ----------------------------------------------------------------------
# Write
# ----------------------------------------------------------------------

task_create() {
  local title="${1:?title required}" body="${2:-}" section="${3:-}"
  local proj
  proj=$(_gitlab_tasks_project_id) || return 1
  # GitLab doesn't have "sections" — translate to milestone if numeric, else label
  local extra_args=()
  if [[ -n "$section" ]]; then
    if [[ "$section" =~ ^[0-9]+$ ]]; then
      extra_args+=(--data-urlencode "milestone_id=${section}")
    else
      extra_args+=(--data-urlencode "labels=${section}")
    fi
  fi
  local resp
  resp=$(_gitlab_tasks_call POST "/projects/${proj}/issues" \
    --data-urlencode "title=${title}" \
    --data-urlencode "description=${body}" \
    "${extra_args[@]}") || return $?
  jq -c '{id: .iid, url: .web_url}' <<<"$resp"
}

task_update() {
  local id="${1:?id required}" field="${2:?field required}" value="${3:?value required}"
  local proj key
  proj=$(_gitlab_tasks_project_id) || return 1
  case "$field" in
    title)    key="title" ;;
    body)     key="description" ;;
    assignee) key="assignee_id" ;;
    *)
      echo "task_update(gitlab-tasks): unknown field '$field'" >&2
      return 3 ;;
  esac
  _gitlab_tasks_call PUT "/projects/${proj}/issues/${id}" \
    --data-urlencode "${key}=${value}" >/dev/null
}

task_close() {
  local id="${1:?id required}" comment="${2:-}"
  local proj
  proj=$(_gitlab_tasks_project_id) || return 1
  [[ -n "$comment" ]] && { task_comment "$id" "$comment" || true; }
  _gitlab_tasks_call PUT "/projects/${proj}/issues/${id}?state_event=close" >/dev/null
}

task_hold() {
  local id="${1:?id required}" reason="${2:?reason required}" waiting_on="${3:?waiting_on required}"
  local proj
  proj=$(_gitlab_tasks_project_id) || return 1
  task_comment "$id" "⏸️ On hold: ${reason}. Waiting on: ${waiting_on}." || return $?
  _gitlab_tasks_call PUT "/projects/${proj}/issues/${id}" \
    --data-urlencode "add_labels=on-hold" >/dev/null
}

task_resume() {
  local id="${1:?id required}" comment="${2:-}"
  local proj
  proj=$(_gitlab_tasks_project_id) || return 1
  _gitlab_tasks_call PUT "/projects/${proj}/issues/${id}" \
    --data-urlencode "remove_labels=on-hold" \
    --data-urlencode "state_event=reopen" >/dev/null || true
  if [[ -n "$comment" ]]; then
    task_comment "$id" "▶️ Resumed: ${comment}"
  else
    task_comment "$id" "▶️ Resumed"
  fi
}

task_comment() {
  local id="${1:?id required}" body="${2:?body required}"
  local proj
  proj=$(_gitlab_tasks_project_id) || return 1
  _gitlab_tasks_call POST "/projects/${proj}/issues/${id}/notes" \
    --data-urlencode "body=${body}" >/dev/null
}
