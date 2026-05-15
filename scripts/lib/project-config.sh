#!/usr/bin/env bash
# project-config.sh - Shared helper for loading PROJECT.yaml configuration
# Source this file in scripts that need project configuration
#
# Usage:
#   source "$(dirname "$0")/lib/project-config.sh"
#   require_project_config  # Exits if PROJECT.yaml missing
#
#   # Then use the helper functions:
#   APP_NAME=$(get_app_name)
#   SECRETS_BACKEND=$(get_secrets_backend)
#   TEST_COMMAND=$(get_test_command)

set -euo pipefail

SCRIPT_DIR_PC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR_PC}/yaml.sh"

PROJECT_CONFIG_FILE="PROJECT.yaml"

# Check if yq is available
check_yq() {
    if ! command -v yq &> /dev/null; then
        echo "Error: yq is required for project configuration"
        echo "Install: brew install yq (macOS) or snap install yq (Linux)"
        exit 1
    fi
}

# Require PROJECT.yaml to exist - call this at start of scripts
require_project_config() {
    if [[ ! -f "${PROJECT_CONFIG_FILE}" ]]; then
        echo "Error: PROJECT.yaml not found in current directory."
        echo ""
        echo "This command requires project configuration. Run:"
        echo "  /project-config init"
        echo ""
        echo "Or create PROJECT.yaml manually. See ~/.claude/templates/PROJECT.yaml"
        exit 1
    fi
    check_yq
}

# Get a value from PROJECT.yaml with optional default
# Usage: get_config ".path.to.key" "default_value"
get_config() {
    local path="$1"
    local default="${2:-}"
    local value

    value=$(yaml_get "${path} // \"${default}\"" "${PROJECT_CONFIG_FILE}")

    # Handle null/empty
    if [[ "${value}" == "null" || -z "${value}" ]]; then
        echo "${default}"
    else
        echo "${value}"
    fi
}

# Core project info
get_app_name() {
    get_config ".name" ""
}

get_version_file() {
    get_config ".version_file" ""
}

# Environment detection
get_env_type() {
    # Returns "work" or "home" based on platform
    if [[ "$(uname -s)" == "Darwin" ]]; then
        echo "work"
    else
        echo "home"
    fi
}

get_ci_platform() {
    local platform
    platform=$(get_config ".ci.platform" "")

    if [[ -z "${platform}" ]]; then
        # Auto-detect from git remote
        local remote
        remote=$(git remote get-url origin 2>/dev/null || echo "")
        if [[ "${remote}" == *"github.com"* ]]; then
            echo "github"
        else
            echo "gitlab"
        fi
    else
        echo "${platform}"
    fi
}

# Secrets configuration
get_secrets_backend() {
    local backend
    backend=$(get_config ".secrets.backend" "")

    if [[ -z "${backend}" ]]; then
        # Auto-detect from environment
        if [[ "$(uname -s)" == "Darwin" ]]; then
            echo "aws"
        else
            echo "infisical"
        fi
    else
        echo "${backend}"
    fi
}

# Testing configuration
get_test_command() {
    get_config ".testing.command" "make test"
}

get_coverage_command() {
    get_config ".testing.coverage_command" ""
}

get_e2e_command() {
    get_config ".testing.e2e_command" ""
}

get_min_coverage() {
    get_config ".testing.min_coverage" "80"
}

# Quality commands
get_lint_command() {
    get_config ".quality.lint_command" ""
}

get_format_command() {
    get_config ".quality.format_command" ""
}

get_typecheck_command() {
    get_config ".quality.typecheck_command" ""
}

# Docker configuration
get_compose_file() {
    get_config ".docker.compose_file" "docker-compose.yml"
}

get_docker_services() {
    yaml_get '.docker.services[]' "${PROJECT_CONFIG_FILE}"
}

get_registry() {
    local env="${1:-staging}"
    get_config ".docker.environments.${env}.registry" ""
}

# Deployment configuration
get_deploy_method() {
    local env_type="${1:-$(get_env_type)}"
    local target_env="${2:-staging}"
    get_config ".deployment.${env_type}.${target_env}.method" "ssh"
}

get_deploy_host() {
    local env_type="${1:-$(get_env_type)}"
    local target_env="${2:-staging}"
    get_config ".deployment.${env_type}.${target_env}.host" ""
}

get_deploy_user() {
    local env_type="${1:-$(get_env_type)}"
    local target_env="${2:-staging}"
    get_config ".deployment.${env_type}.${target_env}.user" ""
}

get_deploy_path() {
    local env_type="${1:-$(get_env_type)}"
    local target_env="${2:-staging}"
    get_config ".deployment.${env_type}.${target_env}.path" ""
}

get_deploy_target() {
    local env_type="${1:-$(get_env_type)}"
    local target_env="${2:-staging}"
    get_config ".deployment.${env_type}.${target_env}.target" ""
}

get_deploy_region() {
    local env_type="${1:-$(get_env_type)}"
    local target_env="${2:-staging}"
    get_config ".deployment.${env_type}.${target_env}.region" "us-east-1"
}

# Blue-green deployment helpers
# Returns "blue" or "green"
get_active_color() {
    local env_type="${1:-$(get_env_type)}"
    local target_env="${2:-staging}"
    get_config ".deployment.${env_type}.${target_env}.active" ""
}

# Returns the inactive color ("blue" if active is "green", vice versa)
get_inactive_color() {
    local env_type="${1:-$(get_env_type)}"
    local target_env="${2:-staging}"
    local active
    active=$(get_active_color "${env_type}" "${target_env}")
    if [[ "${active}" == "green" ]]; then
        echo "blue"
    else
        echo "green"
    fi
}

# Get instance ID for a specific color (or active by default)
get_deploy_instance_id() {
    local env_type="${1:-$(get_env_type)}"
    local target_env="${2:-staging}"
    local color="${3:-}"

    # If no color specified, use active color; fall back to single instance_id
    if [[ -z "${color}" ]]; then
        color=$(get_active_color "${env_type}" "${target_env}")
    fi

    if [[ -n "${color}" ]]; then
        get_config ".deployment.${env_type}.${target_env}.${color}.instance_id" ""
    else
        get_config ".deployment.${env_type}.${target_env}.instance_id" ""
    fi
}

# Get private IP for a specific color (or active by default)
get_deploy_private_ip() {
    local env_type="${1:-$(get_env_type)}"
    local target_env="${2:-staging}"
    local color="${3:-}"

    if [[ -z "${color}" ]]; then
        color=$(get_active_color "${env_type}" "${target_env}")
    fi

    if [[ -n "${color}" ]]; then
        get_config ".deployment.${env_type}.${target_env}.${color}.private_ip" ""
    else
        echo ""
    fi
}

# Get RDS host for an environment
get_deploy_rds_host() {
    local env_type="${1:-$(get_env_type)}"
    local target_env="${2:-staging}"
    get_config ".deployment.${env_type}.${target_env}.rds_host" ""
}

# Branch mapping
get_staging_branch() {
    get_config ".ci.branches.staging" "dev"
}

get_production_branch() {
    get_config ".ci.branches.production" "prod"
}

# Task management configuration
get_task_backend() {
    local backend
    backend=$(get_config ".task_management.backend" "")

    if [[ -z "${backend}" ]]; then
        # Auto-detect from environment
        if [[ "$(uname -s)" == "Darwin" ]]; then
            echo "asana"
        else
            echo "gitlab"
        fi
    else
        echo "${backend}"
    fi
}

get_asana_workspace_id() {
    get_config ".task_management.asana.workspace_id" ""
}

get_asana_project() {
    get_config ".task_management.asana.project" ""
}

get_asana_section() {
    get_config ".task_management.asana.section" ""
}

get_gitlab_project_id() {
    get_config ".task_management.gitlab.project_id" ""
}

get_gitlab_default_labels() {
    yaml_get '.task_management.gitlab.default_labels[]' "${PROJECT_CONFIG_FILE}"
}

# Print configuration summary (useful for debugging)
print_config_summary() {
    echo "=== PROJECT.yaml Summary ==="
    echo "App Name:        $(get_app_name)"
    echo "Environment:     $(get_env_type)"
    echo "CI Platform:     $(get_ci_platform)"
    echo "Secrets Backend: $(get_secrets_backend)"
    echo "Test Command:    $(get_test_command)"
    echo "Compose File:    $(get_compose_file)"
    echo "==========================="
}
