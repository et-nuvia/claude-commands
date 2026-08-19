#!/usr/bin/env bash
# Shared utility functions for task management scripts
# Source this file: source ~/.claude/scripts/common.sh

_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Source yaml helper if not already loaded
if ! declare -f yaml_get &>/dev/null; then
    source "${_COMMON_DIR}/lib/yaml.sh"
fi
# Source task adapter dispatcher if not already loaded. Functions in
# this file (e.g. write_current_task) call load_task_adapter on
# demand so common.sh can be sourced even when the adapter isn't
# resolvable yet (early bootstrap, no PROJECT.yaml).
if ! declare -f load_task_adapter &>/dev/null; then
    # shellcheck source=lib/task-api.sh
    source "${_COMMON_DIR}/lib/task-api.sh"
fi
# Source worktree utilities if not already loaded
if ! declare -f is_in_worktree &>/dev/null; then
    source "${_COMMON_DIR}/lib/worktree-utils.sh" 2>/dev/null || true
fi
# Source git utilities if not already loaded (detect_base_branch, used to
# derive parent_branch in task worktrees where the TSK doc doesn't record it)
if ! declare -f detect_base_branch &>/dev/null; then
    source "${_COMMON_DIR}/lib/git-utils.sh" 2>/dev/null || true
fi

# Validate and normalize a 6-char hex Task ID to uppercase
# Usage: normalize_task_id "a3f2b9"  → "A3F2B9"
normalize_task_id() {
  local input="$1"
  if [[ "$input" =~ ^[A-Fa-f0-9]{6}$ ]]; then
    echo "$input" | tr 'a-f' 'A-F'
  else
    echo "Error: invalid Task ID '$input' — must be 6 hex chars (e.g. A3F2B9)" >&2
    return 1
  fi
}

# Map status to next_action directive
# Usage: map_next_action "success" → "display_summary"
map_next_action() {
  local status="$1"
  case "$status" in
    success)           echo "display_summary" ;;
    conflict)          echo "resolve_conflicts" ;;
    needs_decision)    echo "confirm_action" ;;
    ready_for_sync)    echo "sync_asana" ;;
    needs_llm)         echo "parse_content" ;;
    ready_for_review)  echo "analyze_code" ;;
    *)                 echo "fix_error" ;;
  esac
}

# JSON-escape a string for embedding in JSON output
# Usage: json_escape "string with \"quotes\" and newlines"
json_escape() {
  printf '%s' "$1" | jq -Rs . 2>/dev/null || printf '"%s"' "$1"
}

# Resolve .current-task path relative to git repo root (not CWD)
# This ensures the file is found regardless of which directory a script runs from.
# In linked worktrees, git rev-parse --show-toplevel returns the WORKTREE root
# (not the main checkout), so .current-task is naturally per-worktree.
# Declare CT_* globals at module-load time so callers running under `set -u`
# can reference them before load_current_task() has been invoked (e.g., test
# harnesses that check `[ -z "$CT_TASK_ID" ]` after a failed load).
: "${CT_TASK_ID:=}"
: "${CT_TASK_DOC:=}"
: "${CT_BRANCH:=}"
: "${CT_PARENT_BRANCH:=}"
: "${CT_ASANA_GID:=}"
: "${CT_STARTED:=}"
: "${CT_TRACKER_BACKEND:=}"
: "${CT_TRACKER_ID:=}"
: "${CT_TRACKER_URL:=}"
: "${CT_WORKTREE_PATH:=}"

_resolve_current_task_path() {
  local root
  root=$(git rev-parse --show-toplevel 2>/dev/null) || root=""
  if [[ -n "$root" ]] && [[ -f "${root}/.current-task" ]]; then
    echo "${root}/.current-task"
  elif [[ -f ".current-task" ]]; then
    echo ".current-task"
  else
    return 1
  fi
}

# Echo the 6-char uppercase Task ID a task worktree encodes in its directory
# name (.worktrees/<task_id>), or return 1 if not in a task worktree.
# A "task worktree" is a linked worktree whose basename is a 6-hex Task ID —
# for these, the worktree itself is the source of truth for task identity and
# any .current-task file is ignored.
_worktree_task_id() {
  declare -f is_in_worktree &>/dev/null || return 1
  is_in_worktree || return 1
  local root base
  root=$(get_worktree_root 2>/dev/null) || return 1
  base=$(basename "$root")
  [[ "$base" =~ ^[A-Fa-f0-9]{6}$ ]] || return 1
  echo "$base" | tr 'a-f' 'A-F'
}

# Populate the non-derivable CT_* extras from a TSK document: the start date
# (Timeline → **Started**) and external tracker (External Tracking → Asana GID
# / GitLab issue). These aren't recoverable from worktree structure, so the
# TSK doc is their source of truth. Validation rejects unfilled [placeholder]
# values so partially-templated docs don't yield garbage. Never fails.
_load_metadata_from_tsk() {
  local doc="$1" val
  [[ -f "$doc" ]] || return 0

  # Started date (Timeline section) — must look like a real ISO date.
  val=$(grep -m1 -iE '^\*\*Started\*\*:' "$doc" 2>/dev/null \
        | sed -E 's/^\*\*Started\*\*:[[:space:]]*//' | tr -d '[]' || true)
  [[ "$val" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2} ]] && CT_STARTED="$val"

  # External tracker — Asana block takes precedence, then GitLab.
  if grep -qiE '^\*\*Asana\*\*:' "$doc" 2>/dev/null; then
    val=$(grep -m1 -iE '^-[[:space:]]*Task GID:' "$doc" 2>/dev/null \
          | sed -E 's/.*Task GID:[[:space:]]*//' | tr -d '[]' || true)
    if [[ "$val" =~ ^[0-9]+$ ]]; then
      CT_TRACKER_BACKEND="asana"; CT_TRACKER_ID="$val"; CT_ASANA_GID="$val"
      val=$(grep -m1 -iE '^-[[:space:]]*Task URL:' "$doc" 2>/dev/null \
            | sed -E 's/.*Task URL:[[:space:]]*//' | tr -d '[]' || true)
      [[ "$val" =~ ^https?:// ]] && CT_TRACKER_URL="$val"
    fi
  elif grep -qiE '^\*\*GitLab\*\*:' "$doc" 2>/dev/null; then
    val=$(grep -m1 -iE '^-[[:space:]]*Issue:' "$doc" 2>/dev/null \
          | sed -E 's/.*Issue:[[:space:]]*//' | tr -d '[]#' || true)
    if [[ "$val" =~ ^[0-9]+$ ]]; then
      CT_TRACKER_BACKEND="gitlab"; CT_TRACKER_ID="$val"
      val=$(grep -m1 -iE '^-[[:space:]]*Issue URL:' "$doc" 2>/dev/null \
            | sed -E 's/.*Issue URL:[[:space:]]*//' | tr -d '[]' || true)
      [[ "$val" =~ ^https?:// ]] && CT_TRACKER_URL="$val"
    fi
  fi
  return 0
}

# Given CT_TASK_ID is already set, fill the remaining context that is NOT
# carried by a .current-task file: current branch, parent (fork point), the TSK
# document path (find_primary is worktree-aware), and the TSK-sourced extras
# (started, external tracker). Only fills fields still empty, so callers that
# already know a value (e.g. the worktree's branch) keep it. Never fails.
_derive_task_context_extras() {
  [[ -z "$CT_BRANCH" ]] && CT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
  if [[ -z "$CT_PARENT_BRANCH" ]] && declare -f detect_base_branch &>/dev/null; then
    CT_PARENT_BRANCH=$(detect_base_branch 2>/dev/null || echo "")
  fi
  if [[ -z "$CT_TASK_DOC" ]] && declare -f find_primary &>/dev/null; then
    CT_TASK_DOC=$(find_primary "$CT_TASK_ID" 2>/dev/null || echo "")
  fi
  [[ -n "$CT_TASK_DOC" ]] && _load_metadata_from_tsk "$CT_TASK_DOC"
  [[ "$CT_TRACKER_BACKEND" == "asana" ]] && CT_ASANA_GID="$CT_TRACKER_ID"
  return 0
}

# Load all fields from .current-task (JSON format) into global variables
# Sets: CT_TASK_ID, CT_TASK_DOC, CT_BRANCH, CT_PARENT_BRANCH, CT_STARTED,
#       CT_TRACKER_BACKEND, CT_TRACKER_ID, CT_TRACKER_URL, CT_ASANA_GID
# Returns 0 if task context was loaded, 1 otherwise.
#
# Resolution order:
#   1. TASK worktree (.worktrees/<task_id>): the worktree IS the source of
#      truth. Identity derived from structure, extras from the TSK doc, and any
#      .current-task file is IGNORED.
#   2. .current-task JSON file, when present (the source of truth in a plain
#      checkout).
#   3. Fallback: a task branch name (feature/<task_id>-…) with no file — derive
#      identity from the branch and extras from the TSK doc, so a checkout on a
#      task branch is never "not found" just because the file is missing.
# Usage:
#   if load_current_task; then
#     echo "Working on $CT_TASK_ID from $CT_TASK_DOC"
#   fi
load_current_task() {
  CT_TASK_ID=""
  CT_TASK_DOC=""
  CT_BRANCH=""
  CT_PARENT_BRANCH=""
  CT_ASANA_GID=""
  CT_STARTED=""
  CT_TRACKER_BACKEND=""
  CT_TRACKER_ID=""
  CT_TRACKER_URL=""
  CT_WORKTREE_PATH=""

  # ── 1. Task worktree: derive deterministically, ignore any .current-task ──
  local wt_task_id
  if wt_task_id=$(_worktree_task_id 2>/dev/null); then
    CT_TASK_ID="$wt_task_id"
    CT_WORKTREE_PATH=$(get_worktree_root 2>/dev/null || echo "")
    _derive_task_context_extras
    return 0
  fi

  # ── 2. .current-task file (source of truth in a plain checkout) ──
  local ct_path
  if ! ct_path=$(_resolve_current_task_path); then
    # ── 3. No file — fall back to the task branch name (feature/<id>-…) ──
    local branch branch_id
    branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
    branch_id=$(echo "$branch" | sed -n 's|^[^/]*/\([A-Fa-f0-9]\{6\}\)-.*|\1|p')
    [[ -z "$branch_id" ]] && return 1
    CT_TASK_ID=$(echo "$branch_id" | tr 'a-f' 'A-F')
    CT_BRANCH="$branch"
    _derive_task_context_extras
    return 0
  fi

  # Parse JSON — fail if not valid JSON
  local json
  json=$(jq -r '.' "$ct_path" 2>/dev/null) || return 1

  CT_TASK_ID=$(jq -r '.task_id // empty' "$ct_path" 2>/dev/null)
  [[ -z "$CT_TASK_ID" ]] && return 1

  # Normalize to uppercase
  CT_TASK_ID=$(echo "$CT_TASK_ID" | tr 'a-f' 'A-F')

  CT_TASK_DOC=$(jq -r '.task_doc // empty' "$ct_path" 2>/dev/null)
  CT_BRANCH=$(jq -r '.branch // empty' "$ct_path" 2>/dev/null)
  CT_PARENT_BRANCH=$(jq -r '.parent_branch // empty' "$ct_path" 2>/dev/null)
  CT_STARTED=$(jq -r '.started // empty' "$ct_path" 2>/dev/null)

  # Task tracker fields (null-safe)
  CT_TRACKER_BACKEND=$(jq -r '.task_tracker.backend // empty' "$ct_path" 2>/dev/null)
  CT_TRACKER_ID=$(jq -r '.task_tracker.id // empty' "$ct_path" 2>/dev/null)
  CT_TRACKER_URL=$(jq -r '.task_tracker.url // empty' "$ct_path" 2>/dev/null)

  # Backwards-compatible alias: CT_ASANA_GID set when tracker is Asana
  if [[ "$CT_TRACKER_BACKEND" == "asana" ]]; then
    CT_ASANA_GID="$CT_TRACKER_ID"
  fi

  # Worktree path (set when task was started in worktree mode)
  CT_WORKTREE_PATH=$(jq -r '.worktree_path // empty' "$ct_path" 2>/dev/null)

  return 0
}

# Write .current-task in JSON format
# Usage: write_current_task TASK_ID BRANCH PARENT_BRANCH TASK_DOC [TRACKER_BACKEND] [TRACKER_ID]
# TRACKER_BACKEND: asana, gitlab, github, or empty
# TRACKER_ID: Asana GID, GitLab issue #, GitHub issue #, or empty
# URL is auto-generated from backend + ID
write_current_task() {
  local task_id="$1"
  local branch="$2"
  local parent_branch="$3"
  local task_doc="$4"
  local tracker_backend="${5:-}"
  local tracker_id="${6:-}"

  # In a task worktree the worktree IS the source of truth — do not create or
  # update a .current-task file there (load_current_task ignores it anyway).
  if _worktree_task_id &>/dev/null; then
    return 0
  fi

  local started
  started=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  local tracker_json="null"
  if [[ -n "$tracker_backend" ]] && [[ -n "$tracker_id" ]]; then
    local tracker_url=""
    # Prefer the adapter's task_url so URL construction lives in one
    # place — but only when the explicit tracker_backend matches the
    # active backend. task_url resolves against the configured
    # backend, so calling it with a mismatched tracker_id (e.g. a
    # GitHub issue ID in an Asana-configured project) would silently
    # return the wrong URL. The case-branch below handles the
    # cross-backend case correctly.
    local _active_backend
    _active_backend=$(yaml_get '.task_management.backend' PROJECT.yaml 2>/dev/null || true)
    if [[ -z "$_active_backend" || "$_active_backend" == "null" ]]; then
      _active_backend=$(profile_env_get .task_management.backend 2>/dev/null || true)
    fi
    if [[ "$tracker_backend" == "$_active_backend" ]] \
        && declare -f load_task_adapter &>/dev/null \
        && load_task_adapter 2>/dev/null \
        && declare -f task_url &>/dev/null; then
      tracker_url=$(task_url "$tracker_id" 2>/dev/null || true)
    fi
    if [[ -z "$tracker_url" ]]; then
      case "$tracker_backend" in
        asana)
          tracker_url="https://app.asana.com/0/0/${tracker_id}"
          ;;
        gitlab)
          local instance repo
          instance=$(yaml_get '.git.instance' PROJECT.yaml)
          repo=$(yaml_get '.git.repo' PROJECT.yaml)
          if [[ -n "$instance" ]] && [[ -n "$repo" ]]; then
            tracker_url="https://${instance}/${repo}/-/issues/${tracker_id}"
          fi
          ;;
        github)
          local repo
          repo=$(yaml_get '.git.repo' PROJECT.yaml)
          if [[ -n "$repo" ]]; then
            tracker_url="https://github.com/${repo}/issues/${tracker_id}"
          fi
          ;;
      esac
    fi
    tracker_json=$(jq -n \
      --arg backend "$tracker_backend" \
      --arg id "$tracker_id" \
      --arg url "$tracker_url" \
      '{backend: $backend, id: $id, url: $url}')
  fi

  # Detect worktree path (set when task runs in a linked worktree)
  local worktree_path_val=""
  if declare -f is_in_worktree &>/dev/null && is_in_worktree; then
    worktree_path_val=$(get_worktree_root 2>/dev/null || echo "")
  fi

  local ct_dest
  ct_dest=$(_resolve_current_task_path 2>/dev/null || { local r; r=$(git rev-parse --show-toplevel 2>/dev/null) && echo "${r}/.current-task" || echo ".current-task"; })

  jq -n \
    --arg task_id "$task_id" \
    --arg branch "$branch" \
    --arg parent_branch "$parent_branch" \
    --arg task_doc "$task_doc" \
    --arg started "$started" \
    --arg worktree_path "$worktree_path_val" \
    --argjson task_tracker "$tracker_json" \
    '{task_id: $task_id, branch: $branch, parent_branch: $parent_branch, task_doc: $task_doc, started: $started, task_tracker: $task_tracker}
     + (if $worktree_path != "" then {worktree_path: $worktree_path} else {} end)' \
    > "$ct_dest"
}

# Resolve task context from .current-task file and/or branch name
# Priority: explicit arg > .current-task + branch cross-reference > branch only > error
# On success: echoes the 6-char uppercase Task ID, returns 0
# On mismatch/not-found: echoes JSON with details for LLM to handle, returns 1
# Usage: TASK_ID=$(resolve_task_context "$optional_arg") || handle_error "$TASK_ID"
resolve_task_context() {
  local provided_id="${1:-}"
  local current_task_id=""
  local branch_task_id=""
  local branch=""

  # 1. If explicit ID provided, validate and use it
  if [[ -n "$provided_id" ]]; then
    normalize_task_id "$provided_id"
    return $?
  fi

  # 2. Check .current-task file
  if load_current_task; then
    current_task_id="$CT_TASK_ID"
  fi

  # 3. Extract task ID from branch name (feature/XXXXXX-desc, bugfix/XXXXXX-desc, etc.)
  branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
  if [[ -n "$branch" ]]; then
    local extracted
    extracted=$(echo "$branch" | sed -n 's|^[^/]*/\([A-Fa-f0-9]\{6\}\)-.*|\1|p')
    [[ -n "$extracted" ]] && branch_task_id=$(echo "$extracted" | tr 'a-f' 'A-F')
  fi

  # 4. Both exist — compare
  if [[ -n "$current_task_id" ]] && [[ -n "$branch_task_id" ]]; then
    if [[ "$current_task_id" == "$branch_task_id" ]]; then
      echo "$current_task_id"
      return 0
    else
      # Mismatch — LLM must ask user which is correct
      cat <<EOF
{"status":"mismatch","next_action":"resolve_task_mismatch","current_task_id":"$current_task_id","branch_task_id":"$branch_task_id","branch":"$branch","message":".current-task says $current_task_id but branch says $branch_task_id. Ask user: update .current-task or switch branch?"}
EOF
      return 1
    fi
  fi

  # 5. Only .current-task
  if [[ -n "$current_task_id" ]]; then
    echo "$current_task_id"
    return 0
  fi

  # 6. Only branch
  if [[ -n "$branch_task_id" ]]; then
    echo "$branch_task_id"
    return 0
  fi

  # 7. Neither
  cat <<EOF
{"status":"not_found","next_action":"fix_error","message":"No task context found. Provide task ID as argument, run /task-start, or switch to a task branch (feature/XXXXXX-desc)."}
EOF
  return 1
}

# Compute a deterministic 6-char uppercase hex Task ID
# Input: datetime (YYMMDDHHMM) + description slug (kebab-case)
# Usage: compute_task_id "2602140922" "convert-commands-to-scripts"
compute_task_id() {
  local datetime="$1"
  local description="$2"
  printf '%s%s' "$datetime" "$description" | sha256sum | head -c 6 | tr 'a-f' 'A-F'
}

# Extract YYYY-MM from YYMMDDHHMM datetime format
# Usage: compute_year_month "2602140922"  → "2026-02"
compute_year_month() {
  local datetime="$1"
  echo "20${datetime:0:2}-${datetime:2:2}"
}
