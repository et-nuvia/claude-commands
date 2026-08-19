#!/usr/bin/env bash
# asana-sync.sh - Inline Asana sync helpers for task workflow scripts
#
# Wraps ~/.claude/scripts/asana.sh so scripts can sync Asana directly
# (status custom field, completed flag, comments) instead of pausing and
# delegating to the LLM. All helpers are best-effort: they return non-zero
# on failure and never abort the caller (no set -e propagation surprises —
# callers must check the return code explicitly).
#
# Provides: asana_sync_available(), asana_sync_status_field(),
#           asana_sync_completed(), asana_sync_comment()
#
# Usage: source "${SCRIPT_DIR}/lib/asana-sync.sh"

# Guard against double-sourcing
[[ -n "${_ASANA_SYNC_LOADED:-}" ]] && return 0
_ASANA_SYNC_LOADED=1

# Overridable for tests (point at a mock)
ASANA_SH="${ASANA_SH:-${HOME}/.claude/scripts/asana.sh}"

# yaml_get is needed to read the sections / section_transitions config. It is
# usually already sourced by the caller (task-tracker-sync.sh), so guard.
if ! declare -F yaml_get >/dev/null 2>&1; then
    # shellcheck source=yaml.sh
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/yaml.sh" 2>/dev/null || true
fi

# True if the shim and a token are available
asana_sync_available() {
    [[ -x "$ASANA_SH" ]] || return 1
    [[ -n "${ASANA_ACCESS_TOKEN:-}" || -f "${HOME}/.asana-token" ]] || return 1
    return 0
}

# Set any configured custom field by its PROJECT.yaml logical key.
# Usage: asana_sync_field GID <status|complexity|sprint|score|...> VALUE
#
# --if-supported keeps a project that lacks the field (or the value) from
# failing the caller: syncing several fields across differently-configured
# projects should not abort partway through.
asana_sync_field() {
    local gid="$1" field="$2" value="$3"
    [[ -n "$gid" && -n "$field" && -n "$value" ]] || return 1
    asana_sync_available || return 1
    "$ASANA_SH" update-custom-field "$gid" --field "$field" --value "$value" --if-supported >/dev/null 2>&1
}

# Set the status field.
#
# The field is addressed by the LOGICAL key `status`, never by display name:
# the underlying field is called "Status Dev" in every conformant project, and
# resolving by name broke wherever that drift existed. Values are option keys
# from PROJECT.yaml (not_started|in_progress|waiting|hold|blocked|done); a
# display value like "In progress" still works via asana.sh's name fallback.
# Usage: asana_sync_status_field GID <option_key>
asana_sync_status_field() {
    local gid="$1" value="$2"
    asana_sync_field "$gid" "status" "$value"
}

# Map a task-lifecycle state to a Status Dev option key.
# Usage: key=$(asana_status_option_for "completed")
asana_status_option_for() {
    case "$1" in
        completed)   echo "done" ;;
        on_hold)     echo "hold" ;;
        in_progress) echo "in_progress" ;;
        blocked)     echo "blocked" ;;
        waiting)     echo "waiting" ;;
        not_started) echo "not_started" ;;
        *)           echo "" ;;
    esac
}

# Resolve a logical section name to its GID from PROJECT.yaml.
# Usage: gid=$(asana_section_gid "backlog")
asana_section_gid() {
    local logical="$1"
    [[ -n "$logical" ]] || return 1
    yaml_get ".task_management.asana.sections.${logical}.gid // \"\"" PROJECT.yaml
}

# Which logical section a lifecycle operation files a task into.
# Usage: logical=$(asana_section_for_operation "start")   # -> current_sprint
asana_section_for_operation() {
    local op="$1"
    [[ -n "$op" ]] || return 1
    yaml_get ".task_management.asana.section_transitions.${op} // \"\"" PROJECT.yaml
}

# Move a task into a logical section (backlog|current_sprint|bugs|archive).
# Usage: asana_sync_section GID backlog
asana_sync_section() {
    local gid="$1" logical="$2"
    [[ -n "$gid" && -n "$logical" ]] || return 1
    asana_sync_available || return 1
    local section_gid
    section_gid="$(asana_section_gid "$logical")"
    # An unconfigured section is a no-op, not a failure — projects that have not
    # been brought onto the standard layout simply have no sections block.
    [[ -n "$section_gid" ]] || return 0
    "$ASANA_SH" move-task-to-section "$gid" --section "$section_gid" >/dev/null 2>&1
}

# Move a task into whichever section a lifecycle operation maps to.
# Usage: asana_sync_section_for_operation GID start
asana_sync_section_for_operation() {
    local gid="$1" op="$2"
    local logical
    logical="$(asana_section_for_operation "$op")"
    [[ -n "$logical" ]] || return 0
    asana_sync_section "$gid" "$logical"
}

# Set the completed flag
# Usage: asana_sync_completed GID true|false
asana_sync_completed() {
    local gid="$1" flag="$2"
    [[ -n "$gid" && ( "$flag" == "true" || "$flag" == "false" ) ]] || return 1
    asana_sync_available || return 1
    "$ASANA_SH" update-task "$gid" --completed "$flag" >/dev/null 2>&1
}

# Add a comment
# Usage: asana_sync_comment GID "comment text"
asana_sync_comment() {
    local gid="$1" text="$2"
    [[ -n "$gid" && -n "$text" ]] || return 1
    asana_sync_available || return 1
    "$ASANA_SH" add-comment "$gid" --text "$text" >/dev/null 2>&1
}
