#!/usr/bin/env bash
# secrets-backends/aws-sm.sh — AWS Secrets Manager adapter for the secrets contract.
#
# Uses the aws CLI for all operations. AWS SM stores secrets as opaque
# strings; by convention this adapter stores them as JSON objects so
# multiple keys can live under one "path".
#
# Secret naming convention:
#   <app_name>/<env>/<path>
#   e.g.   nuvia-app/production/database
#
# Where:
#   - app_name comes from PROJECT.yaml .app_name (required)
#   - env is the first arg to every function (production, staging, ...)
#   - path is the second arg (e.g. /database — leading slash stripped)
#
# Don't source this file directly — go through scripts/lib/secrets-api.sh.

if ! command -v aws >/dev/null 2>&1; then
  echo "secrets-backends/aws-sm.sh: aws CLI not installed" >&2
  return 1
fi

# Resolve the app name once. Required — AWS secret names need it.
_AWS_APP_NAME=""
if [[ -f PROJECT.yaml ]]; then
  _AWS_APP_NAME=$(yaml_get '.app_name' PROJECT.yaml 2>/dev/null || true)
fi
if [[ -z "$_AWS_APP_NAME" || "$_AWS_APP_NAME" == "null" ]]; then
  # Defer error until first call — sm_health and sm_ui_url need to be
  # usable without it for diagnostics.
  _AWS_APP_NAME=""
fi

# AWS region — try profile first, then env, then aws CLI default.
_AWS_REGION="$(profile_env_get .aws.region 2>/dev/null)"
[[ -z "$_AWS_REGION" ]] && _AWS_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"

# Build the canonical secret name for an env+path combo.
_aws_secret_name() {
  local env="$1" path="$2"
  if [[ -z "$_AWS_APP_NAME" ]]; then
    echo "aws-sm.sh: PROJECT.yaml .app_name is required for AWS SM addressing" >&2
    return 1
  fi
  # Strip leading slash for clean concatenation
  echo "${_AWS_APP_NAME}/${env}/${path#/}"
}

# Run the aws CLI with shared --region. Translates ResourceNotFoundException
# in stderr to exit 2 per the contract.
_aws_call() {
  local stderr rc
  stderr=$(mktemp)
  trap 'rm -f "$stderr"' RETURN
  local region_arg=()
  [[ -n "$_AWS_REGION" ]] && region_arg=(--region "$_AWS_REGION")
  if aws secretsmanager "$@" "${region_arg[@]}" 2>"$stderr"; then
    return 0
  fi
  rc=$?
  if grep -qE "ResourceNotFoundException|does not exist" "$stderr"; then
    return 2
  fi
  cat "$stderr" >&2
  return "$rc"
}

# Fetch the full secret JSON for an env+path. Used internally by sm_get
# and sm_get_json.
_aws_get_secret_blob() {
  local env="$1" path="$2"
  local name
  name=$(_aws_secret_name "$env" "$path") || return 1
  _aws_call get-secret-value --secret-id "$name" --query SecretString --output text
}

# ----------------------------------------------------------------------
# Read
# ----------------------------------------------------------------------

sm_get() {
  local env="${1:?env required}"
  local path="${2:?path required}"
  local key="${3:?key required}"
  local blob
  blob=$(_aws_get_secret_blob "$env" "$path") || return $?
  local val
  val=$(jq -r --arg k "$key" '.[$k] // empty' <<<"$blob")
  if [[ -z "$val" ]]; then
    return 2
  fi
  echo "$val"
}

sm_get_json() {
  local env="${1:?env required}"
  local path="${2:?path required}"
  _aws_get_secret_blob "$env" "$path"
}

sm_ui_url() {
  local env="${1:?env required}"
  local path="${2:?path required}"
  local name region
  name=$(_aws_secret_name "$env" "$path" 2>/dev/null) || name="<app>/${env}/${path#/}"
  region="${_AWS_REGION:-us-east-1}"
  # AWS console deep-link to the secret detail page
  echo "https://${region}.console.aws.amazon.com/secretsmanager/secret?name=${name}&region=${region}"
}

# ----------------------------------------------------------------------
# Write
# ----------------------------------------------------------------------

sm_set() {
  local env="${1:?env required}"
  local path="${2:?path required}"
  local key="${3:?key required}"
  local value="${4:?value required}"
  local blob name new_blob
  name=$(_aws_secret_name "$env" "$path") || return 1

  # Read-modify-write: AWS SM is one blob per secret, so updating one
  # key means merging into the existing JSON.
  blob=$(_aws_get_secret_blob "$env" "$path" 2>/dev/null)
  if [[ -z "$blob" ]]; then
    blob="{}"
    new_blob=$(jq -nc --arg k "$key" --arg v "$value" '{($k): $v}')
    _aws_call create-secret --name "$name" --secret-string "$new_blob" >/dev/null
  else
    new_blob=$(jq -c --arg k "$key" --arg v "$value" '. + {($k): $v}' <<<"$blob")
    _aws_call put-secret-value --secret-id "$name" --secret-string "$new_blob" >/dev/null
  fi
}

sm_set_json() {
  local env="${1:?env required}"
  local path="${2:?path required}"
  local json="${3:?json required}"
  local name
  name=$(_aws_secret_name "$env" "$path") || return 1
  # Replace the entire blob (matches the contract docstring)
  if _aws_call describe-secret --secret-id "$name" >/dev/null 2>&1; then
    _aws_call put-secret-value --secret-id "$name" --secret-string "$json" >/dev/null
  else
    _aws_call create-secret --name "$name" --secret-string "$json" >/dev/null
  fi
}

# ----------------------------------------------------------------------
# Versions
# ----------------------------------------------------------------------

sm_versions() {
  local env="${1:?env required}"
  local path="${2:?path required}"
  # key is part of the contract but AWS SM versions the whole blob, not
  # individual keys. Ignore the key arg; documented in contract README.
  local name raw
  name=$(_aws_secret_name "$env" "$path") || return 1
  raw=$(_aws_call list-secret-version-ids --secret-id "$name" --include-deprecated) || return $?
  jq -c '[.Versions[] | {
    version: .VersionId,
    created_at: .CreatedDate,
    is_current: ((.VersionStages // []) | index("AWSCURRENT") != null)
  }]' <<<"$raw"
}

sm_restore() {
  local env="${1:?env required}"
  local path="${2:?path required}"
  local _key="${3:?key required}"  # ignored — AWS versions the whole blob
  local version="${4:?version required}"
  local name current
  name=$(_aws_secret_name "$env" "$path") || return 1
  # Find which version is currently AWSCURRENT so we can move the stage
  current=$(_aws_call list-secret-version-ids --secret-id "$name" \
    | jq -r '.Versions[] | select(.VersionStages != null and (.VersionStages | index("AWSCURRENT"))) | .VersionId') || return $?
  if [[ -z "$current" ]]; then
    echo "sm_restore: no AWSCURRENT version found for $name" >&2
    return 1
  fi
  _aws_call update-secret-version-stage \
    --secret-id "$name" \
    --version-stage AWSCURRENT \
    --move-to-version-id "$version" \
    --remove-from-version-id "$current" >/dev/null
}

# ----------------------------------------------------------------------
# Rotation
# ----------------------------------------------------------------------

sm_rotate_prepare() {
  # AWS SM has rotation-as-a-service but it requires a Lambda. For the
  # manual dual-write flow our scripts use, no preparation is needed.
  return 0
}

# ----------------------------------------------------------------------
# Health
# ----------------------------------------------------------------------

sm_health() {
  if ! command -v aws >/dev/null 2>&1; then
    echo "sm_health(aws-sm): aws CLI not installed" >&2
    return 1
  fi
  local region_arg=()
  [[ -n "$_AWS_REGION" ]] && region_arg=(--region "$_AWS_REGION")
  if ! aws secretsmanager list-secrets --max-results 1 "${region_arg[@]}" >/dev/null 2>&1; then
    echo "sm_health(aws-sm): cannot list secrets — check IAM auth and region" >&2
    return 1
  fi
  return 0
}
