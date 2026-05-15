#!/usr/bin/env bash
# secrets-api.sh — secrets backend adapter dispatcher.
#
# Sources the right adapter file from secrets-backends/ based on the
# active profile (or PROJECT.yaml override, or SM_ADAPTER_OVERRIDE env
# var). After load_sm_adapter() returns 0, the adapter's sm_* functions
# are defined and callable.
#
# Usage:
#   source "${SCRIPT_DIR}/lib/secrets-api.sh"
#   load_sm_adapter || exit 1
#   sm_get production /database DATABASE_PASSWORD
#
# See secrets-backends/README.md for the contract every adapter satisfies.

[[ -n "${_SECRETS_API_LOADED:-}" ]] && return 0
_SECRETS_API_LOADED=1

_SECRETS_API_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
source "${_SECRETS_API_DIR}/load-profile.sh"
# shellcheck disable=SC1091
source "${_SECRETS_API_DIR}/yaml.sh"

# ----------------------------------------------------------------------
# Dispatcher
# ----------------------------------------------------------------------

# load_sm_adapter — pick and source the right secrets-backends/<name>.sh.
# Returns 0 on success, 1 on unknown/missing backend.
load_sm_adapter() {
  [[ -n "${_SM_ADAPTER_LOADED:-}" ]] && return 0

  local backend=""
  if [[ -n "${SM_ADAPTER_OVERRIDE:-}" ]]; then
    backend="$SM_ADAPTER_OVERRIDE"
  elif [[ -f PROJECT.yaml ]]; then
    backend=$(yaml_get '.secrets.backend' PROJECT.yaml 2>/dev/null || true)
  fi
  if [[ -z "$backend" || "$backend" == "null" ]]; then
    backend=$(profile_env_get .secrets.backend 2>/dev/null || true)
  fi

  if [[ -z "$backend" ]]; then
    echo "secrets-api: no secrets backend configured (set .secrets.backend in PROJECT.yaml or profile)" >&2
    return 1
  fi

  # Translate common aliases to canonical adapter filenames.
  case "$backend" in
    aws|aws-secrets-manager|aws_secrets_manager) backend="aws-sm" ;;
  esac

  local adapter="${_SECRETS_API_DIR}/secrets-backends/${backend}.sh"
  if [[ ! -f "$adapter" ]]; then
    echo "secrets-api: no adapter for backend '${backend}' (expected ${adapter})" >&2
    return 1
  fi

  # shellcheck disable=SC1090
  source "$adapter" || return 1
  _SM_ADAPTER_LOADED="$backend"
  return 0
}

# sm_adapter_name — echo the loaded adapter's backend name (or empty).
sm_adapter_name() {
  echo "${_SM_ADAPTER_LOADED:-}"
}
