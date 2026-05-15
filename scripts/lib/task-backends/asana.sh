#!/usr/bin/env bash
# task-backends/asana.sh — Asana adapter for the task management contract.
#
# Uses Asana's REST API v1.0 directly with a Personal Access Token from
# ~/.asana-token. This adapter exists for SCRIPT-DRIVEN code paths;
# Claude sessions can continue to use mcp__asana__* tools directly.
#
# Required config (PROJECT.yaml > profile fallback):
#   .task_management.asana.workspace_id   — Asana workspace GID
#   .task_management.asana.default_project — Asana project GID (optional;
#                                            falls back to workspace-wide ops)
#
# Don't source this file directly — go through scripts/lib/task-api.sh.

_ASANA_TOKEN_FILE="${ASANA_TOKEN_FILE:-${HOME}/.asana-token}"
_ASANA_API_BASE="https://app.asana.com/api/1.0"

if ! command -v curl >/dev/null 2>&1; then
  echo "task-backends/asana.sh: curl not installed" >&2
  return 1
fi

# Lookup helpers — PROJECT.yaml first, then profile.
_asana_workspace_id() {
  local v
  if [[ -f PROJECT.yaml ]]; then
    v=$(yaml_get '.task_management.asana.workspace_id' PROJECT.yaml 2>/dev/null || true)
    [[ -n "$v" && "$v" != "null" ]] && { echo "$v"; return; }
  fi
  v=$(profile_env_get .task_management.asana.workspace_id 2>/dev/null)
  echo "$v"
}

_asana_default_project() {
  local v
  if [[ -f PROJECT.yaml ]]; then
    v=$(yaml_get '.task_management.asana.default_project' PROJECT.yaml 2>/dev/null || true)
    [[ -n "$v" && "$v" != "null" ]] && { echo "$v"; return; }
  fi
  profile_env_get .task_management.asana.default_project 2>/dev/null
}

# Low-level API wrapper. Translates 404 → exit 2, other non-2xx → exit 1.
_asana_call() {
  local method="${1:?method required}"
  local endpoint="${2:?endpoint required}"
  shift 2

  if [[ ! -f "$_ASANA_TOKEN_FILE" ]]; then
    echo "asana.sh: token file not found: $_ASANA_TOKEN_FILE" >&2
    return 1
  fi

  local tmpfile http_code
  tmpfile=$(mktemp)
  trap 'rm -f "$tmpfile"' RETURN

  http_code=$(curl -s -o "$tmpfile" -w '%{http_code}' \
    --connect-timeout 10 --max-time 30 \
    -X "$method" \
    -H "Authorization: Bearer $(cat "$_ASANA_TOKEN_FILE")" \
    -H "Accept: application/json" \
    "$@" \
    "${_ASANA_API_BASE}${endpoint}")

  if [[ "$http_code" -ge 200 && "$http_code" -lt 300 ]]; then
    cat "$tmpfile"
    return 0
  elif [[ "$http_code" == "404" ]]; then
    return 2
  else
    echo "Asana API error: HTTP ${http_code} on ${method} ${endpoint}" >&2
    cat "$tmpfile" >&2
    return 1
  fi
}

# Map an Asana task into the normalized contract schema.
_asana_normalize_task() {
  jq -c '{
    id: .gid,
    title: .name,
    status: (
      if .completed == true then "closed"
      # On-hold convention: Asana custom field or section name containing "hold"
      elif (.memberships // []) | any(.section.name? // "" | ascii_downcase | contains("hold")) then "on_hold"
      elif (.memberships // []) | any(.section.name? // "" | ascii_downcase | contains("in progress")) then "in_progress"
      else "open" end
    ),
    assignee: (.assignee.name // null),
    created_at: .created_at,
    updated_at: .modified_at,
    url: .permalink_url,
    raw: .
  }'
}

# ----------------------------------------------------------------------
# Read
# ----------------------------------------------------------------------

task_get() {
  local id="${1:?id required}"
  _asana_call GET "/tasks/${id}?opt_fields=gid,name,completed,assignee.name,memberships.section.name,created_at,modified_at,permalink_url" \
    | jq -c '.data' | _asana_normalize_task
}

task_list() {
  local state="open" assignee="me"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --state)    state="$2"; shift 2 ;;
      --assignee) assignee="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  local ws qs project
  ws=$(_asana_workspace_id)
  if [[ -z "$ws" ]]; then
    echo "asana.sh: workspace_id not configured" >&2
    return 1
  fi

  project=$(_asana_default_project)
  qs="opt_fields=gid,name,completed,assignee.name,memberships.section.name,created_at,modified_at,permalink_url"
  qs="${qs}&workspace=${ws}&assignee=${assignee}"
  [[ -n "$project" ]] && qs="${qs}&project=${project}"
  case "$state" in
    open)   qs="${qs}&completed_since=now" ;;  # Asana: only incomplete tasks
    closed) qs="${qs}&completed=true" ;;
    all)    ;;
  esac

  _asana_call GET "/tasks?${qs}" \
    | jq -c '.data[]' \
    | while read -r task; do echo "$task" | _asana_normalize_task; done \
    | jq -sc .
}

task_search() {
  local query="${1:?query required}"
  local ws
  ws=$(_asana_workspace_id)
  if [[ -z "$ws" ]]; then
    echo "asana.sh: workspace_id not configured" >&2
    return 1
  fi
  # Asana's search endpoint requires URL-encoded text
  local encoded
  encoded=$(jq -nr --arg q "$query" '$q | @uri')
  _asana_call GET "/workspaces/${ws}/tasks/search?text=${encoded}&opt_fields=gid,name,completed,assignee.name,memberships.section.name,created_at,modified_at,permalink_url" \
    | jq -c '.data[]' \
    | while read -r task; do echo "$task" | _asana_normalize_task; done \
    | jq -sc .
}

task_url() {
  local id="${1:?id required}"
  # Build directly without an API call — Asana URLs are deterministic
  echo "https://app.asana.com/0/0/${id}"
}

task_health() {
  if [[ ! -f "$_ASANA_TOKEN_FILE" ]]; then
    echo "task_health(asana): token file not found: $_ASANA_TOKEN_FILE" >&2
    return 1
  fi
  if ! _asana_call GET /users/me >/dev/null; then
    echo "task_health(asana): API call failed (check token validity)" >&2
    return 1
  fi
  return 0
}

# ----------------------------------------------------------------------
# Write
# ----------------------------------------------------------------------

task_create() {
  local title="${1:?title required}" body="${2:-}" section="${3:-}"
  local ws project body_json
  ws=$(_asana_workspace_id)
  project=$(_asana_default_project)
  if [[ -z "$ws" ]]; then
    echo "asana.sh: workspace_id not configured" >&2
    return 1
  fi
  body_json=$(jq -nc --arg n "$title" --arg notes "$body" --arg ws "$ws" --arg proj "$project" '
    {data: ({name: $n, notes: $notes, workspace: $ws}
            + (if $proj == "" then {} else {projects: [$proj]} end))}')
  local resp
  resp=$(_asana_call POST /tasks -H "Content-Type: application/json" -d "$body_json") || return $?
  local gid url
  gid=$(jq -r '.data.gid' <<<"$resp")
  url=$(jq -r '.data.permalink_url' <<<"$resp")
  # Place in section if requested
  if [[ -n "$section" ]]; then
    _asana_call POST "/sections/${section}/addTask" -H "Content-Type: application/json" \
      -d "$(jq -nc --arg t "$gid" '{data: {task: $t}}')" >/dev/null || true
  fi
  jq -nc --arg id "$gid" --arg url "$url" '{id: $id, url: $url}'
}

task_update() {
  local id="${1:?id required}" field="${2:?field required}" value="${3:?value required}"
  local body_json
  case "$field" in
    title) body_json=$(jq -nc --arg v "$value" '{data: {name: $v}}') ;;
    body)  body_json=$(jq -nc --arg v "$value" '{data: {notes: $v}}') ;;
    assignee) body_json=$(jq -nc --arg v "$value" '{data: {assignee: $v}}') ;;
    *)
      echo "task_update(asana): unknown field '$field' (supported: title, body, assignee)" >&2
      return 3 ;;
  esac
  _asana_call PUT "/tasks/${id}" -H "Content-Type: application/json" -d "$body_json" >/dev/null
}

task_close() {
  local id="${1:?id required}" comment="${2:-}"
  if [[ -n "$comment" ]]; then
    task_comment "$id" "$comment" || true
  fi
  _asana_call PUT "/tasks/${id}" -H "Content-Type: application/json" \
    -d '{"data":{"completed":true}}' >/dev/null
}

task_hold() {
  local id="${1:?id required}" reason="${2:?reason required}" waiting_on="${3:?waiting_on required}"
  # Asana doesn't have a native "on-hold" state. Convention:
  #   1. Add a comment recording the reason + waiting_on
  #   2. Move the task into a section whose name contains "hold"
  #      (case-insensitive) so _asana_normalize_task detects on_hold
  #      via .memberships[].section.name
  task_comment "$id" "⏸️ On hold: ${reason}. Waiting on: ${waiting_on}." || return $?

  local project
  project=$(_asana_default_project)
  if [[ -z "$project" ]]; then
    echo "task_hold(asana): no default_project configured; comment added but task is not marked on_hold" >&2
    return 0
  fi

  # Find a section in the project whose name contains "hold"
  local sections hold_section
  sections=$(_asana_call GET "/projects/${project}/sections?opt_fields=gid,name") || return $?
  hold_section=$(jq -r '.data[] | select((.name | ascii_downcase) | contains("hold")) | .gid' <<<"$sections" | head -1)

  if [[ -z "$hold_section" ]]; then
    echo "task_hold(asana): no section named '*hold*' found in project ${project}; comment added but task is not marked on_hold" >&2
    return 0
  fi

  _asana_call POST "/sections/${hold_section}/addTask" -H "Content-Type: application/json" \
    -d "$(jq -nc --arg t "$id" '{data: {task: $t}}')" >/dev/null
}

task_resume() {
  local id="${1:?id required}" comment="${2:-}"
  # Reopen if completed, OR remove from hold section. Both are best-effort.
  _asana_call PUT "/tasks/${id}" -H "Content-Type: application/json" \
    -d '{"data":{"completed":false}}' >/dev/null || true
  if [[ -n "$comment" ]]; then
    task_comment "$id" "▶️ Resumed: ${comment}"
  else
    task_comment "$id" "▶️ Resumed"
  fi
}

task_comment() {
  local id="${1:?id required}" body="${2:?body required}"
  _asana_call POST "/tasks/${id}/stories" -H "Content-Type: application/json" \
    -d "$(jq -nc --arg t "$body" '{data: {text: $t}}')" >/dev/null
}
