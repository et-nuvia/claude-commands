#!/usr/bin/env bash
# task-api.sh — task management adapter dispatcher.
#
# Sources the right adapter file from task-backends/ based on the active
# profile (or PROJECT.yaml override, or TASK_ADAPTER_OVERRIDE env var).
# After load_task_adapter() returns 0, the adapter's task_* functions
# are defined and callable.
#
# Usage:
#   source "${SCRIPT_DIR}/lib/task-api.sh"
#   load_task_adapter || exit 1
#   task_close 42 "done in PR #99"
#
# See task-backends/README.md for the contract every adapter satisfies.

[[ -n "${_TASK_API_LOADED:-}" ]] && return 0
_TASK_API_LOADED=1

_TASK_API_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
source "${_TASK_API_DIR}/load-profile.sh"
# shellcheck disable=SC1091
source "${_TASK_API_DIR}/yaml.sh"

# ----------------------------------------------------------------------
# Dispatcher
# ----------------------------------------------------------------------

# load_task_adapter — pick and source the right task-backends/<name>.sh.
# Returns 0 on success, 1 on unknown/missing backend.
load_task_adapter() {
  [[ -n "${_TASK_ADAPTER_LOADED:-}" ]] && return 0

  local backend=""
  if [[ -n "${TASK_ADAPTER_OVERRIDE:-}" ]]; then
    backend="$TASK_ADAPTER_OVERRIDE"
  elif [[ -f PROJECT.yaml ]]; then
    backend=$(yaml_get '.task_management.backend' PROJECT.yaml 2>/dev/null || true)
  fi
  if [[ -z "$backend" || "$backend" == "null" ]]; then
    backend=$(profile_env_get .task_management.backend 2>/dev/null || true)
  fi

  if [[ -z "$backend" ]]; then
    echo "task-api: no task backend configured (set .task_management.backend in PROJECT.yaml or profile)" >&2
    return 1
  fi

  # Aliases — both "gitlab" and "gitlab-tasks" point at the same adapter.
  # Same for github. Lets users configure the natural short name.
  case "$backend" in
    gitlab) backend="gitlab-tasks" ;;
    github) backend="github-tasks" ;;
  esac

  local adapter="${_TASK_API_DIR}/task-backends/${backend}.sh"
  if [[ ! -f "$adapter" ]]; then
    echo "task-api: no adapter for backend '${backend}' (expected ${adapter})" >&2
    return 1
  fi

  # shellcheck disable=SC1090
  source "$adapter" || return 1
  _TASK_ADAPTER_LOADED="$backend"
  return 0
}

# task_adapter_name — echo the loaded adapter's backend name (or empty).
task_adapter_name() {
  echo "${_TASK_ADAPTER_LOADED:-}"
}
