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

# Raw GitLab REST access (gitlab_api) lives in git-platforms/gitlab.sh
# now — keeping it out of the dispatcher preserves the seam: callers
# go through load_git_adapter or source the platform file directly
# rather than reaching backend-specific helpers through the generic
# git-api dispatcher.
