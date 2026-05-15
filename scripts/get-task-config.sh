#!/usr/bin/env bash
# get-task-config.sh - Get task management configuration from PROJECT.yaml
#
# Usage:
#   get-task-config.sh backend           # Get task backend (asana|gitlab)
#   get-task-config.sh asana-workspace   # Get Asana workspace ID
#   get-task-config.sh asana-project     # Get Asana project name/GID
#   get-task-config.sh asana-section     # Get Asana section name/GID
#   get-task-config.sh gitlab-project    # Get GitLab project ID
#   get-task-config.sh gitlab-labels     # Get GitLab default labels
#   get-task-config.sh all               # Get all task config as JSON
#
# Returns:
#   - Single value for specific queries
#   - JSON object for 'all' query
#   - Empty string if config not found
#   - Exit code 0 on success, 1 on error, 2 if PROJECT.yaml not found

set -euo pipefail

# Enable bash array compatibility in zsh
if [ -n "${ZSH_VERSION:-}" ]; then
  setopt KSH_ARRAYS
fi

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the project config library
# shellcheck source=lib/project-config.sh
source "${SCRIPT_DIR}/lib/project-config.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/load-profile.sh"

# Colors for output
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Usage information
usage() {
    cat << 'EOF'
Usage: get-task-config.sh <command>

Commands:
  backend           Get task backend (asana|gitlab)
  asana-workspace   Get Asana workspace ID
  asana-project     Get Asana project name/GID
  asana-section     Get Asana section name/GID
  gitlab-project    Get GitLab project ID
  gitlab-labels     Get GitLab default labels (one per line)
  all               Get all task config as JSON
  help              Show this help message

Environment:
  Auto-detects environment (work=macOS=asana, home=Linux=gitlab)
  Can be overridden in PROJECT.yaml

Exit Codes:
  0 - Success
  1 - Error (invalid command, config error)
  2 - PROJECT.yaml not found

Examples:
  # Get backend
  BACKEND=$(get-task-config.sh backend)

  # Get Asana config
  WORKSPACE_ID=$(get-task-config.sh asana-workspace)
  PROJECT=$(get-task-config.sh asana-project)
  SECTION=$(get-task-config.sh asana-section)

  # Get all config as JSON
  CONFIG=$(get-task-config.sh all)
  echo "$CONFIG" | jq -r '.backend'
EOF
}

# Check if PROJECT.yaml exists
check_project_config() {
    if [[ ! -f "PROJECT.yaml" ]]; then
        echo -e "${RED}Error: PROJECT.yaml not found in current directory${NC}" >&2
        echo "" >&2
        echo "Create one with: /project-config init" >&2
        echo "Or navigate to a directory with PROJECT.yaml" >&2
        exit 2
    fi
}

# Check if field exists in PROJECT.yaml (not null/empty)
field_exists() {
    local field="$1"
    local value
    value=$(yaml_get "${field}" PROJECT.yaml)
    [[ -n "${value}" ]]
}

# Get all task configuration as JSON
get_all_config() {
    # Get all config in one call
    local config
    config=$(get_project_config \
        task_backend=.task_management.backend \
        asana_workspace=.task_management.asana.workspace_id \
        asana_project=.task_management.asana.project \
        asana_section=.task_management.asana.section \
        gitlab_project=.task_management.gitlab.project_id)

    local backend
    backend=$(echo "$config" | jq -r '.task_backend')

    # Auto-detect if missing
    if [[ "$backend" == "__MISSING__" ]] || [[ "$backend" == "__INVALID__" ]]; then
        backend=$(uname -s | grep -q Darwin && echo "asana" || echo "gitlab")
    fi

    # Extract values
    local asana_workspace asana_project asana_section gitlab_project
    asana_workspace=$(echo "$config" | jq -r '.asana_workspace')
    asana_project=$(echo "$config" | jq -r '.asana_project')
    asana_section=$(echo "$config" | jq -r '.asana_section')
    gitlab_project=$(echo "$config" | jq -r '.gitlab_project')

    # Replace special values with empty string for output
    [[ "$asana_workspace" =~ ^__.*__$ ]] && asana_workspace=""
    [[ "$asana_project" =~ ^__.*__$ ]] && asana_project=""
    [[ "$asana_section" =~ ^__.*__$ ]] && asana_section=""
    [[ "$gitlab_project" =~ ^__.*__$ ]] && gitlab_project=""

    # Get GitLab labels as JSON array
    local labels_json="[]"
    if field_exists ".task_management.gitlab.default_labels"; then
        labels_json=$(yaml_get '.task_management.gitlab.default_labels' PROJECT.yaml)
        [[ -z "$labels_json" ]] && labels_json="[]"
    fi

    # Detect environment
    local env_type
    env_type=$(uname -s | grep -q Darwin && echo "work" || echo "home")

    # Build JSON output
    cat << EOF
{
  "backend": "${backend}",
  "environment": "${env_type}",
  "asana": {
    "workspace_id": "${asana_workspace}",
    "project": "${asana_project}",
    "section": "${asana_section}"
  },
  "gitlab": {
    "project_id": "${gitlab_project}",
    "default_labels": ${labels_json}
  }
}
EOF
}

# Validate Asana configuration
validate_asana_config() {
    config=$(get_project_config asana_workspace=.task_management.asana.workspace_id)
    workspace_id=$(echo "$config" | jq -r '.asana_workspace')

    if [[ "$workspace_id" =~ ^__.*__$ ]] || [[ -z "${workspace_id}" ]]; then
        echo -e "${YELLOW}Warning: Asana workspace_id not configured${NC}" >&2
        echo "Add to PROJECT.yaml:" >&2
        echo "task_management:" >&2
        echo "  asana:" >&2
        echo "    workspace_id: \"YOUR_WORKSPACE_GID\"" >&2
        return 1
    fi

    # Check for token
    if [[ ! -f "${HOME}/.asana-token" ]]; then
        echo -e "${YELLOW}Warning: ~/.asana-token not found${NC}" >&2
        echo "Create token at: https://app.asana.com/0/my-apps" >&2
        echo "Then save: echo 'YOUR_TOKEN' > ~/.asana-token && chmod 600 ~/.asana-token" >&2
        return 1
    fi

    return 0
}

# Validate GitLab configuration
validate_gitlab_config() {
    config=$(get_project_config gitlab_project=.task_management.gitlab.project_id)
    project_id=$(echo "$config" | jq -r '.gitlab_project')

    if [[ "$project_id" =~ ^__.*__$ ]] || [[ -z "${project_id}" ]]; then
        echo -e "${YELLOW}Warning: GitLab project_id not configured${NC}" >&2
        echo "Add to PROJECT.yaml:" >&2
        echo "task_management:" >&2
        echo "  gitlab:" >&2
        echo "    project_id: \"owner/repo\"" >&2
        return 1
    fi

    # Check for token
    if [[ ! -f "${HOME}/.gitlab-token" ]]; then
        local gitlab_host
        gitlab_host=$(profile_env_get .git.instance 2>/dev/null)
        gitlab_host="${gitlab_host:-gitlab.com}"
        echo -e "${YELLOW}Warning: ~/.gitlab-token not found${NC}" >&2
        echo "Create token at: https://${gitlab_host}/-/profile/personal_access_tokens" >&2
        echo "Then save: echo 'YOUR_TOKEN' > ~/.gitlab-token && chmod 600 ~/.gitlab-token" >&2
        return 1
    fi

    return 0
}

# Main command handler
main() {
    local command="${1:-help}"

    # Handle help
    if [[ "${command}" == "help" ]] || [[ "${command}" == "--help" ]] || [[ "${command}" == "-h" ]]; then
        usage
        exit 0
    fi

    # Check for PROJECT.yaml (except for help)
    check_project_config

    # Fail early - require jq
    if ! command -v jq &>/dev/null; then
        print_error "jq required but not installed"
        exit 1
    fi

    case "${command}" in
        backend)
            config=$(get_project_config task_backend=.task_management.backend)
            backend=$(echo "$config" | jq -r '.task_backend')
            [[ "$backend" =~ ^__.*__$ ]] && backend=$(uname -s | grep -q Darwin && echo "asana" || echo "gitlab")
            echo "$backend"
            ;;

        asana-workspace)
            config=$(get_project_config asana_workspace=.task_management.asana.workspace_id)
            workspace=$(echo "$config" | jq -r '.asana_workspace')
            [[ "$workspace" =~ ^__.*__$ ]] && workspace=""
            echo "$workspace"
            ;;

        asana-project)
            config=$(get_project_config asana_project=.task_management.asana.project)
            project=$(echo "$config" | jq -r '.asana_project')
            [[ "$project" =~ ^__.*__$ ]] && project=""
            echo "$project"
            ;;

        asana-section)
            config=$(get_project_config asana_section=.task_management.asana.section)
            section=$(echo "$config" | jq -r '.asana_section')
            [[ "$section" =~ ^__.*__$ ]] && section=""
            echo "$section"
            ;;

        gitlab-project)
            config=$(get_project_config gitlab_project=.task_management.gitlab.project_id)
            project=$(echo "$config" | jq -r '.gitlab_project')
            [[ "$project" =~ ^__.*__$ ]] && project=""
            echo "$project"
            ;;

        gitlab-labels)
            if field_exists ".task_management.gitlab.default_labels"; then
                yaml_get_array '.task_management.gitlab.default_labels' PROJECT.yaml || true
            fi
            ;;

        all)
            get_all_config
            ;;

        validate)
            # Validate configuration for current backend
            config=$(get_project_config task_backend=.task_management.backend)
            backend=$(echo "$config" | jq -r '.task_backend')
            [[ "$backend" =~ ^__.*__$ ]] && backend=$(uname -s | grep -q Darwin && echo "asana" || echo "gitlab")

            echo "Validating ${backend} configuration..." >&2

            if [[ "${backend}" == "asana" ]]; then
                validate_asana_config
            elif [[ "${backend}" == "gitlab" ]]; then
                validate_gitlab_config
            else
                echo -e "${RED}Error: Unknown backend: ${backend}${NC}" >&2
                exit 1
            fi
            ;;

        *)
            echo -e "${RED}Error: Unknown command: ${command}${NC}" >&2
            echo "" >&2
            usage
            exit 1
            ;;
    esac
}

main "$@"
