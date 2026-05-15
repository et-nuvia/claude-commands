#!/usr/bin/env bash
# secrets-backends/infisical.sh — Infisical adapter for the secrets contract.
#
# Uses the infisical CLI (https://infisical.com/docs/cli/overview) for all
# operations. Reads the instance URL from profile .secrets.url and
# expects the CLI to be authenticated (via `infisical login` or service
# token in ~/.infisical/...).
#
# Don't source this file directly — go through scripts/lib/secrets-api.sh.

if ! command -v infisical >/dev/null 2>&1; then
  echo "secrets-backends/infisical.sh: infisical CLI not installed" >&2
  return 1
fi

# Resolve instance URL once. Empty means use Infisical Cloud defaults.
_INFISICAL_URL="$(profile_env_get .secrets.url 2>/dev/null)"
_INFISICAL_DOMAIN_ARGS=()
if [[ -n "$_INFISICAL_URL" ]]; then
  _INFISICAL_DOMAIN_ARGS=(--domain "${_INFISICAL_URL}/api")
fi

# Run the infisical CLI with shared --domain and stderr translation.
# Translates "not found" patterns in stderr to exit 2 per the contract.
_infisical_call() {
  local stderr rc
  stderr=$(mktemp)
  trap 'rm -f "$stderr"' RETURN
  if infisical "$@" "${_INFISICAL_DOMAIN_ARGS[@]}" 2>"$stderr"; then
    return 0
  fi
  rc=$?
  if grep -qiE "not found|does not exist|404" "$stderr"; then
    return 2
  fi
  cat "$stderr" >&2
  return "$rc"
}

# ----------------------------------------------------------------------
# Read
# ----------------------------------------------------------------------

sm_get() {
  local env="${1:?env required}"
  local path="${2:?path required}"
  local key="${3:?key required}"
  _infisical_call secrets get "$key" \
    --env "$env" --path "$path" --plain
}

sm_get_json() {
  local env="${1:?env required}"
  local path="${2:?path required}"
  # `infisical secrets` (no subcommand) lists everything at the path in
  # KEY=VALUE form when --plain is set. Compose JSON via jq.
  local raw
  raw=$(_infisical_call secrets --env "$env" --path "$path" --plain) || return $?
  jq -Rn '[inputs | capture("^(?<k>[^=]+)=(?<v>.*)$") | {(.k): .v}] | add // {}' <<<"$raw"
}

sm_ui_url() {
  local env="${1:?env required}"
  local path="${2:?path required}"
  if [[ -z "$_INFISICAL_URL" ]]; then
    # Cloud default
    echo "https://app.infisical.com/dashboard"
  else
    # Self-hosted UI doesn't have a direct deep-link for an env+path
    # combination; surface the dashboard and let the user navigate.
    echo "${_INFISICAL_URL}"
  fi
}

# ----------------------------------------------------------------------
# Write
# ----------------------------------------------------------------------

sm_set() {
  local env="${1:?env required}"
  local path="${2:?path required}"
  local key="${3:?key required}"
  local value="${4:?value required}"
  _infisical_call secrets set "${key}=${value}" \
    --env "$env" --path "$path" >/dev/null
}

sm_set_json() {
  local env="${1:?env required}"
  local path="${2:?path required}"
  local json="${3:?json required}"
  # Set each top-level key from the JSON object. NOTE: this does NOT
  # delete existing keys at the path that aren't in the JSON — Infisical
  # CLI has no native "replace all" operation. If true replace semantics
  # are needed, callers should sm_get_json first and compute a diff.
  local pairs
  pairs=$(jq -r 'to_entries | map("\(.key)=\(.value | tostring)") | .[]' <<<"$json") || return 1
  while IFS= read -r kv; do
    [[ -z "$kv" ]] && continue
    _infisical_call secrets set "$kv" --env "$env" --path "$path" >/dev/null || return $?
  done <<<"$pairs"
}

# ----------------------------------------------------------------------
# Versions
# ----------------------------------------------------------------------

sm_versions() {
  local env="${1:?env required}"
  local path="${2:?path required}"
  local key="${3:?key required}"
  # The Infisical CLI doesn't expose version history. Restoration is
  # manual via the web UI, per the existing rollback-secret.sh flow.
  # Return an empty array + warning so callers know to fall back.
  echo "infisical.sh: version history requires web UI; sm_versions returns empty" >&2
  echo "[]"
}

sm_restore() {
  local env="${1:?env required}"
  local path="${2:?path required}"
  local key="${3:?key required}"
  local version="${4:?version required}"
  local ui_url
  ui_url=$(sm_ui_url "$env" "$path")
  cat >&2 <<EOF
infisical.sh: programmatic version restore not supported by the CLI.
Manual steps:
  1. Open ${ui_url}
  2. Navigate to env=${env}, path=${path}
  3. Click the ${key} secret → Version History → Restore version ${version}
EOF
  return 3
}

# ----------------------------------------------------------------------
# Rotation
# ----------------------------------------------------------------------

sm_rotate_prepare() {
  # No-op: Infisical doesn't have a pending-value staging concept like
  # AWS SM. Rotation scripts handle the dual-write themselves.
  return 0
}

# ----------------------------------------------------------------------
# Health
# ----------------------------------------------------------------------

sm_health() {
  if ! command -v infisical >/dev/null 2>&1; then
    echo "sm_health(infisical): CLI not installed" >&2
    return 1
  fi
  # `infisical user` requires auth; failure means we're not logged in.
  if ! infisical user "${_INFISICAL_DOMAIN_ARGS[@]}" >/dev/null 2>&1; then
    echo "sm_health(infisical): CLI not authenticated (run: infisical login)" >&2
    return 1
  fi
  return 0
}
