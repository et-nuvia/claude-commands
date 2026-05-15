#!/bin/bash
# =============================================================================
# SSH Helper Library
# =============================================================================
# Shared functions for SSH-based remote command execution.
# Used by deployment scripts.
#
# Configuration priority (highest to lowest):
#   1. Environment variables (STAGING_SSH_HOST, etc.)
#   2. Config files (scripts/deploy/config/staging.env)
#   3. PROJECT.yaml (deployment.<env>.path for DEPLOY_PATH)
#   4. Defaults
# =============================================================================

# Source common config if not already loaded
SCRIPT_DIR_SSH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ "${_COMMON_SH_LOADED:-}" != "true" ]] && [[ -f "$SCRIPT_DIR_SSH/common.sh" ]]; then
  source "$SCRIPT_DIR_SSH/common.sh"
fi

# Default SSH options
SSH_OPTIONS="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10"

# =============================================================================
# ssh_get_config - Get SSH config for an environment
# =============================================================================
# Arguments:
#   $1 - Environment (staging|production)
#
# Outputs:
#   Sets SSH_HOST, SSH_USER, SSH_KEY, DEPLOY_PATH variables
# =============================================================================
ssh_get_config() {
  local environment="$1"

  # Load from config file first
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  local config_file="$script_dir/config/${environment}.env"

  if [[ -f "$config_file" ]]; then
    # shellcheck source=/dev/null
    source "$config_file"
  fi

  # Environment variables override config file
  # DEPLOY_PATH falls back to common.sh value (from PROJECT.yaml) if not in config
  local default_deploy_path="${DEPLOY_PATH:-}"

  case "$environment" in
    staging)
      SSH_HOST="${STAGING_SSH_HOST:-${SSH_HOST:-}}"
      SSH_USER="${STAGING_SSH_USER:-${SSH_USER:-ec2-user}}"
      SSH_KEY="${STAGING_SSH_KEY:-${SSH_KEY:-}}"
      DEPLOY_PATH="${STAGING_DEPLOY_PATH:-${default_deploy_path}}"
      ;;
    production)
      SSH_HOST="${PRODUCTION_SSH_HOST:-${SSH_HOST:-}}"
      SSH_USER="${PRODUCTION_SSH_USER:-${SSH_USER:-ec2-user}}"
      SSH_KEY="${PRODUCTION_SSH_KEY:-${SSH_KEY:-}}"
      DEPLOY_PATH="${PRODUCTION_DEPLOY_PATH:-${default_deploy_path}}"
      ;;
    *)
      echo "Error: Unknown environment: $environment" >&2
      return 1
      ;;
  esac

  # Expand tilde in SSH_KEY path
  if [[ -n "$SSH_KEY" ]]; then
    SSH_KEY="${SSH_KEY/#\~/$HOME}"
  fi

  # Validate
  if [[ -z "$SSH_HOST" ]]; then
    echo "Error: SSH_HOST not configured for ${environment}" >&2
    echo "Set ${environment^^}_SSH_HOST or update config/${environment}.env" >&2
    return 1
  fi

  if [[ -n "$SSH_KEY" ]] && [[ ! -f "$SSH_KEY" ]]; then
    echo "Error: SSH key not found: $SSH_KEY" >&2
    return 1
  fi

  # Fix key permissions if needed
  if [[ -n "$SSH_KEY" ]] && [[ -f "$SSH_KEY" ]]; then
    local perms
    perms=$(stat -f %A "$SSH_KEY" 2>/dev/null || stat -c %a "$SSH_KEY" 2>/dev/null)
    if [[ "$perms" != "600" && "$perms" != "400" ]]; then
      chmod 600 "$SSH_KEY"
    fi
  fi

  export SSH_HOST SSH_USER SSH_KEY DEPLOY_PATH
}

# =============================================================================
# ssh_test_connection - Test SSH connection
# =============================================================================
# Arguments:
#   $1 - Environment (staging|production)
#
# Returns:
#   0 on success, 1 on failure
# =============================================================================
ssh_test_connection() {
  local environment="$1"

  ssh_get_config "$environment" || return 1

  echo "Testing SSH connection to ${SSH_USER}@${SSH_HOST}..."

  local ssh_cmd="ssh $SSH_OPTIONS"
  [[ -n "$SSH_KEY" ]] && ssh_cmd="$ssh_cmd -i \"$SSH_KEY\""

  if eval "$ssh_cmd" "${SSH_USER}@${SSH_HOST}" "echo 'Connection OK'" &>/dev/null; then
    echo "  Connection successful"
    return 0
  else
    echo "  Connection failed" >&2
    return 1
  fi
}

# =============================================================================
# ssh_run_command - Execute a command on remote server
# =============================================================================
# Arguments:
#   $1 - Environment (staging|production)
#   $2 - Command to execute (can be multiline)
#
# Returns:
#   Command exit code
# =============================================================================
ssh_run_command() {
  local environment="$1"
  local command="$2"

  ssh_get_config "$environment" || return 1

  local ssh_cmd="ssh $SSH_OPTIONS"
  [[ -n "$SSH_KEY" ]] && ssh_cmd="$ssh_cmd -i \"$SSH_KEY\""

  eval "$ssh_cmd" "${SSH_USER}@${SSH_HOST}" "$command"
}

# =============================================================================
# ssh_copy_file - Copy a file to remote server
# =============================================================================
# Arguments:
#   $1 - Environment (staging|production)
#   $2 - Local file path
#   $3 - Remote destination path
# =============================================================================
ssh_copy_file() {
  local environment="$1"
  local local_path="$2"
  local remote_path="$3"

  ssh_get_config "$environment" || return 1

  local scp_cmd="scp $SSH_OPTIONS"
  [[ -n "$SSH_KEY" ]] && scp_cmd="$scp_cmd -i \"$SSH_KEY\""

  eval "$scp_cmd" "$local_path" "${SSH_USER}@${SSH_HOST}:${remote_path}"
}

# =============================================================================
# ssh_copy_dir - Copy a directory to remote server
# =============================================================================
# Arguments:
#   $1 - Environment (staging|production)
#   $2 - Local directory path
#   $3 - Remote destination path
# =============================================================================
ssh_copy_dir() {
  local environment="$1"
  local local_path="$2"
  local remote_path="$3"

  ssh_get_config "$environment" || return 1

  local scp_cmd="scp $SSH_OPTIONS -r"
  [[ -n "$SSH_KEY" ]] && scp_cmd="$scp_cmd -i \"$SSH_KEY\""

  eval "$scp_cmd" "$local_path" "${SSH_USER}@${SSH_HOST}:${remote_path}"
}
