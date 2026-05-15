#!/bin/bash
# =============================================================================
# SSM Helper Library
# =============================================================================
# Shared functions for executing commands on EC2 via AWS SSM.
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/ssm.sh"
#   ssm_run_command "$INSTANCE_ID" "echo hello"
# =============================================================================

# Source common config if not already loaded
SCRIPT_DIR_SSM="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ "${_COMMON_SH_LOADED:-}" != "true" ]] && [[ -f "$SCRIPT_DIR_SSM/common.sh" ]]; then
  source "$SCRIPT_DIR_SSM/common.sh"
fi

# Default timeout for SSM commands (5 minutes)
SSM_TIMEOUT="${SSM_TIMEOUT:-300}"

# Default poll interval (seconds)
SSM_POLL_INTERVAL="${SSM_POLL_INTERVAL:-10}"

# Maximum poll attempts (5 minutes with 10s intervals = 30 attempts)
SSM_MAX_ATTEMPTS="${SSM_MAX_ATTEMPTS:-30}"

# =============================================================================
# ssm_run_command - Execute a command on EC2 via SSM
# =============================================================================
# Arguments:
#   $1 - Instance ID
#   $2 - Command to execute (can be multiline)
#   $3 - (optional) Timeout in seconds (default: SSM_TIMEOUT)
#
# Returns:
#   0 on success, 1 on failure
# =============================================================================
ssm_run_command() {
  local instance_id="$1"
  local command="$2"
  local timeout="${3:-$SSM_TIMEOUT}"

  if [[ -z "$instance_id" ]]; then
    echo "Error: Instance ID required" >&2
    return 1
  fi

  if [[ -z "$command" ]]; then
    echo "Error: Command required" >&2
    return 1
  fi

  # Convert multiline command to JSON array format
  local commands_json
  commands_json=$(echo "$command" | jq -R -s 'split("\n") | map(select(length > 0))')

  # Send command via SSM
  local command_id
  command_id=$(aws ssm send-command \
    --instance-ids "$instance_id" \
    --document-name "AWS-RunShellScript" \
    --parameters "{\"commands\": $commands_json}" \
    --timeout-seconds "$timeout" \
    --region "${REGION:-us-west-1}" \
    --query 'Command.CommandId' \
    --output text 2>&1)

  if [[ $? -ne 0 ]] || [[ -z "$command_id" ]]; then
    echo "Error: Failed to send SSM command: $command_id" >&2
    return 1
  fi

  echo "SSM Command ID: $command_id" >&2

  # Poll for completion
  local status="Pending"
  local attempts=0

  while [[ "$attempts" -lt "$SSM_MAX_ATTEMPTS" ]]; do
    attempts=$((attempts + 1))

    status=$(aws ssm get-command-invocation \
      --command-id "$command_id" \
      --instance-id "$instance_id" \
      --region "${REGION:-us-west-1}" \
      --query 'Status' \
      --output text 2>/dev/null) || status="Pending"

    echo "  Poll $attempts/$SSM_MAX_ATTEMPTS: $status" >&2

    case "$status" in
      Success|Failed|Cancelled|TimedOut)
        break
        ;;
    esac

    sleep "$SSM_POLL_INTERVAL"
  done

  # Get command output
  local output
  output=$(aws ssm get-command-invocation \
    --command-id "$command_id" \
    --instance-id "$instance_id" \
    --region "${REGION:-us-west-1}" \
    --query 'StandardOutputContent' \
    --output text 2>/dev/null) || true

  local error_output
  error_output=$(aws ssm get-command-invocation \
    --command-id "$command_id" \
    --instance-id "$instance_id" \
    --region "${REGION:-us-west-1}" \
    --query 'StandardErrorContent' \
    --output text 2>/dev/null) || true

  # Output results
  if [[ -n "$output" ]] && [[ "$output" != "None" ]]; then
    echo "$output"
  fi

  if [[ -n "$error_output" ]] && [[ "$error_output" != "None" ]]; then
    echo "$error_output" >&2
  fi

  # Return based on status
  if [[ "$status" == "Success" ]]; then
    return 0
  else
    echo "Error: SSM command failed with status: $status" >&2
    return 1
  fi
}

# =============================================================================
# get_instance_id - Get instance ID from common.sh config, env var, or config file
# =============================================================================
# Arguments:
#   $1 - Environment (staging|production)
#
# Returns:
#   Instance ID via stdout, or empty on failure
# =============================================================================
get_instance_id() {
  local environment="$1"
  local instance_id=""

  # 1. Check INSTANCE_ID from common.sh (set by load_config)
  instance_id="${INSTANCE_ID:-}"

  # 2. Try environment-prefixed env vars
  if [[ -z "$instance_id" ]]; then
    case "$environment" in
      staging)
        instance_id="${STAGING_INSTANCE_ID:-}"
        ;;
      production)
        instance_id="${PRODUCTION_INSTANCE_ID:-}"
        ;;
    esac
  fi

  # 3. Try config file
  if [[ -z "$instance_id" ]]; then
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    local config_file="$script_dir/config/${environment}.env"

    if [[ -f "$config_file" ]]; then
      # shellcheck source=/dev/null
      source "$config_file"
      case "$environment" in
        staging)
          instance_id="${STAGING_INSTANCE_ID:-}"
          ;;
        production)
          instance_id="${PRODUCTION_INSTANCE_ID:-}"
          ;;
      esac
    fi
  fi

  echo "$instance_id"
}
