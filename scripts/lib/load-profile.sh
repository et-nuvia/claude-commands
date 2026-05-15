#!/usr/bin/env bash
# load-profile.sh — read environment-specific config from the active profile.
#
# This is the keystone of the claude-commands config layering. Scripts that
# previously hardcoded values (registry hosts, git instance, task backend,
# etc.) should source this file and use the accessors below.
#
# Layering: profile defaults → environments.<active>.* → PROJECT.yaml (per
# project, handled elsewhere) → command flags. This file handles the first
# two layers.
#
# Usage:
#   source "${SCRIPTS_DIR}/lib/load-profile.sh"
#   load_profile                              # ensures profile is loaded
#   host=$(profile_env_get .registry.host)    # env-specific lookup
#   name=$(profile_get .identity.name)        # root-level lookup
#   env=$(profile_active_environment)         # "work" / "home" / etc.
#
# Defaults: if a key is missing, returns empty string. Pass a default as the
# second arg to override:
#   port=$(profile_env_get .registry.port 5000)
#
# Profile location resolution order:
#   1. $CLAUDE_PROFILE                        — explicit override
#   2. $CLAUDE_HOME/profiles/active.yaml      — when CLAUDE_HOME set
#   3. ~/.claude/profiles/active.yaml         — standard install
#
# If no profile exists, load_profile() falls back to the bundled example
# (profiles/default.yaml.example, relative to this script) with a stderr
# warning. This lets first-run / CI invocations work without a hard error,
# while still nudging users to create a real profile.

set -u

# Resolve our own directory regardless of how we were sourced
_LP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Pull in the yq abstraction (idempotent)
if ! declare -f yaml_get &>/dev/null; then
  # shellcheck disable=SC1091
  source "${_LP_DIR}/yaml.sh"
fi

# Cached state — set by load_profile, read by accessors
_PROFILE_PATH=""
_PROFILE_ENV=""
_PROFILE_LOADED=0
_PROFILE_IS_FALLBACK=0

# ----------------------------------------------------------------------
# Internal: find the profile file. Sets _PROFILE_PATH and
# _PROFILE_IS_FALLBACK directly (no subshell, so globals persist).
# ----------------------------------------------------------------------
_lp_resolve_path() {
  local candidate

  if [[ -n "${CLAUDE_PROFILE:-}" ]]; then
    if [[ ! -f "$CLAUDE_PROFILE" ]]; then
      echo "load-profile: CLAUDE_PROFILE=$CLAUDE_PROFILE not found" >&2
      return 1
    fi
    _PROFILE_PATH="$CLAUDE_PROFILE"
    _PROFILE_IS_FALLBACK=0
    return 0
  fi

  if [[ -n "${CLAUDE_HOME:-}" ]]; then
    candidate="${CLAUDE_HOME}/profiles/active.yaml"
  else
    candidate="${HOME}/.claude/profiles/active.yaml"
  fi

  if [[ -f "$candidate" ]]; then
    _PROFILE_PATH="$candidate"
    _PROFILE_IS_FALLBACK=0
    return 0
  fi

  # Fallback to bundled example (relative to this lib file)
  local example="${_LP_DIR}/../../profiles/default.yaml.example"
  if [[ -f "$example" ]]; then
    _PROFILE_PATH="$(cd "$(dirname "$example")" && pwd)/$(basename "$example")"
    _PROFILE_IS_FALLBACK=1
    return 0
  fi

  echo "load-profile: no profile found and no bundled example available" >&2
  return 1
}

# ----------------------------------------------------------------------
# Public: load_profile — idempotent. Resolves path, validates active env,
# caches both. Safe to call multiple times.
# ----------------------------------------------------------------------
load_profile() {
  if [[ "$_PROFILE_LOADED" == "1" ]]; then
    return 0
  fi

  _lp_resolve_path || return 1

  if [[ "$_PROFILE_IS_FALLBACK" == "1" ]]; then
    echo "load-profile: WARN no active profile, using example values from" >&2
    echo "  $_PROFILE_PATH" >&2
    echo "  Run: cp ${HOME}/.claude/profiles/default.yaml.example ${HOME}/.claude/profiles/active.yaml" >&2
  fi

  _PROFILE_ENV=$(yaml_get '.active_environment' "$_PROFILE_PATH" 2>/dev/null || true)
  if [[ -z "$_PROFILE_ENV" || "$_PROFILE_ENV" == "null" ]]; then
    echo "load-profile: profile is missing 'active_environment'" >&2
    echo "  file: $_PROFILE_PATH" >&2
    return 1
  fi

  # Sanity-check that the named environment exists
  local exists
  exists=$(yaml_get ".environments.${_PROFILE_ENV} | type" "$_PROFILE_PATH" 2>/dev/null || true)
  if [[ -z "$exists" || "$exists" == "null" ]]; then
    echo "load-profile: active_environment='${_PROFILE_ENV}' but environments.${_PROFILE_ENV} not defined" >&2
    echo "  file: $_PROFILE_PATH" >&2
    return 1
  fi

  _PROFILE_LOADED=1
  return 0
}

# ----------------------------------------------------------------------
# Public: profile_path — echo the resolved profile file path.
# ----------------------------------------------------------------------
profile_path() {
  load_profile || return 1
  echo "$_PROFILE_PATH"
}

# ----------------------------------------------------------------------
# Public: profile_active_environment — echo "work", "home", etc.
# ----------------------------------------------------------------------
profile_active_environment() {
  load_profile || return 1
  echo "$_PROFILE_ENV"
}

# ----------------------------------------------------------------------
# Public: profile_get <yaml-path> [default]
#   Root-level lookup (identity, paths, defaults, etc.)
# ----------------------------------------------------------------------
profile_get() {
  local path="$1"
  local default="${2:-}"
  load_profile || return 1

  local val
  val=$(yaml_get "$path" "$_PROFILE_PATH" 2>/dev/null || true)
  if [[ -z "$val" || "$val" == "null" ]]; then
    echo "$default"
  else
    echo "$val"
  fi
}

# ----------------------------------------------------------------------
# Public: profile_env_get <yaml-path-under-environment> [default]
#   Looks up under environments.<active>.<path>.
#   Example: profile_env_get .registry.host
# ----------------------------------------------------------------------
profile_env_get() {
  local path="$1"
  local default="${2:-}"
  load_profile || return 1

  # Strip leading "." for clean concatenation
  local clean="${path#.}"
  local full=".environments.${_PROFILE_ENV}.${clean}"
  profile_get "$full" "$default"
}

# ----------------------------------------------------------------------
# Public: profile_is_fallback — return 0 if we're running off the example.
#   Lets callers gate side effects ("don't push to a real registry if
#   we're using fallback config").
# ----------------------------------------------------------------------
profile_is_fallback() {
  load_profile || return 1
  [[ "$_PROFILE_IS_FALLBACK" == "1" ]]
}

# ----------------------------------------------------------------------
# Public: profile_dump — print resolved environment-block as YAML.
#   Useful for diagnostics: `bash -c "source load-profile.sh && profile_dump"`
# ----------------------------------------------------------------------
profile_dump() {
  load_profile || return 1
  echo "# profile: $_PROFILE_PATH"
  echo "# active_environment: $_PROFILE_ENV"
  yaml_get ".environments.${_PROFILE_ENV}" "$_PROFILE_PATH"
}
