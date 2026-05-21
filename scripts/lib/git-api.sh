#!/usr/bin/env bash
# git-api.sh — git platform adapter dispatcher.
#
# Sources the right adapter file from git-platforms/ based on the active
# profile (or PROJECT.yaml override, or GIT_ADAPTER_OVERRIDE env var).
# After load_git_adapter() returns 0, the adapter's `git_*` functions are
# defined and callable.
#
# Usage:
#   source "${SCRIPT_DIR}/lib/git-api.sh"
#   load_git_adapter || exit 1
#   git_issue_close 42 "done"
#
# See git-platforms/README.md for the contract every adapter must satisfy.

[[ -n "${_GIT_API_LOADED:-}" ]] && return 0
_GIT_API_LOADED=1

_GIT_API_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
source "${_GIT_API_DIR}/load-profile.sh"
# shellcheck disable=SC1091
source "${_GIT_API_DIR}/yaml.sh"

# ----------------------------------------------------------------------
# Dispatcher
# ----------------------------------------------------------------------

# load_git_adapter — pick and source the right git-platforms/<name>.sh.
# Returns 0 on success, 1 on unknown/missing platform.
load_git_adapter() {
  [[ -n "${_GIT_ADAPTER_LOADED:-}" ]] && return 0

  local platform=""
  if [[ -n "${GIT_ADAPTER_OVERRIDE:-}" ]]; then
    platform="$GIT_ADAPTER_OVERRIDE"
  elif [[ -f PROJECT.yaml ]]; then
    platform=$(yaml_get '.git.platform' PROJECT.yaml 2>/dev/null || true)
  fi
  if [[ -z "$platform" || "$platform" == "null" ]]; then
    platform=$(profile_env_get .git.platform 2>/dev/null || true)
  fi

  if [[ -z "$platform" ]]; then
    echo "git-api: no git platform configured (set .git.platform in PROJECT.yaml or profile)" >&2
    return 1
  fi

  local adapter="${_GIT_API_DIR}/git-platforms/${platform}.sh"
  if [[ ! -f "$adapter" ]]; then
    echo "git-api: no adapter for platform '${platform}' (expected ${adapter})" >&2
    return 1
  fi

  # shellcheck disable=SC1090
  source "$adapter" || return 1
  _GIT_ADAPTER_LOADED="$platform"
  return 0
}

# git_adapter_name — echo the loaded adapter's platform name (or empty).
git_adapter_name() {
  echo "${_GIT_ADAPTER_LOADED:-}"
}

# ----------------------------------------------------------------------
# Low-level GitLab helper — kept here (not in gitlab.sh) so it stays
# accessible to scripts that need raw API access without going through
# the high-level adapter. The gitlab.sh adapter uses this internally.
#
# Usage: gitlab_api GET "/projects/ID/pipelines" [extra_curl_args...]
# Requires: GIT_API_URL and GIT_TOKEN_FILE variables set by caller.
# Returns JSON on stdout. Exit codes match the contract:
#   0 on 2xx
#   2 on 404 (not found)
#   1 on any other HTTP error (with stderr message)
# ----------------------------------------------------------------------
gitlab_api() {
  local method="${1:?method required}"
  local endpoint="${2:?endpoint required}"
  shift 2

  [[ -n "${GIT_API_URL:-}" ]] || { echo "Error: GIT_API_URL not set" >&2; return 1; }
  [[ -f "${GIT_TOKEN_FILE:-}" ]] || { echo "Error: Token file not found: ${GIT_TOKEN_FILE:-unset}" >&2; return 1; }

  local tmpfile
  tmpfile=$(mktemp)
  # Use eager-expanded trap text so $tmpfile is resolved NOW, while in scope.
  # The previous single-quoted form was evaluated when the trap fired (on
  # RETURN, after `local tmpfile` had gone out of scope), which under
  # `set -u` in any caller produced "tmpfile: unbound variable".
  trap "rm -f '$tmpfile'" RETURN

  local http_code
  http_code=$(curl -s -o "$tmpfile" -w '%{http_code}' \
    --connect-timeout 10 --max-time 30 \
    -X "$method" \
    --header "PRIVATE-TOKEN: $(cat "$GIT_TOKEN_FILE")" \
    "$@" \
    "${GIT_API_URL}${endpoint}")

  if [[ "$http_code" =~ ^2[0-9][0-9]$ ]]; then
    cat "$tmpfile"
    return 0
  elif [[ "$http_code" == "404" ]]; then
    # Quiet — callers will translate this to exit 2; not necessarily an error
    return 2
  else
    echo "GitLab API error: HTTP ${http_code} on ${method} ${endpoint}" >&2
    cat "$tmpfile" >&2
    return 1
  fi
}
