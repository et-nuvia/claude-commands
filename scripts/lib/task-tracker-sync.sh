#!/usr/bin/env bash
# task-tracker-sync.sh - Unified external tracker sync (Asana, GitLab, GitHub)
#
# Reads PROJECT.yaml task_management.backend to determine which tracker to use.
# Returns next_action directives for LLM to handle MCP calls (Asana) or
# executes API calls directly (GitLab, GitHub).
#
# Provides: tracker_detect(), tracker_sync_status(), tracker_sync_comment(), tracker_sync_close()
#
# Usage: source "${SCRIPT_DIR}/lib/task-tracker-sync.sh"

# Guard against double-sourcing
[[ -n "${_TASK_TRACKER_SYNC_LOADED:-}" ]] && return 0
_TASK_TRACKER_SYNC_LOADED=1

_TRACKER_SYNC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source yaml helper if not already loaded
if ! declare -f yaml_get &>/dev/null; then
    source "${_TRACKER_SYNC_DIR}/yaml.sh"
fi

# Source the GitLab platform adapter when we need raw GitLab API
# access (gitlab_api). The function moved out of the generic
# git-api.sh dispatcher to keep platform-specific code in its
# platform file.
if ! declare -f gitlab_api &>/dev/null && [[ -f "${_TRACKER_SYNC_DIR}/git-platforms/gitlab.sh" ]]; then
    source "${_TRACKER_SYNC_DIR}/git-platforms/gitlab.sh"
fi

# Cached tracker backend
_TRACKER_BACKEND=""

# Detect which tracker backend is configured
# Returns: asana, gitlab, github, or none
# Usage: backend=$(tracker_detect)
tracker_detect() {
    if [[ -n "$_TRACKER_BACKEND" ]]; then
        echo "$_TRACKER_BACKEND"
        return 0
    fi

    _TRACKER_BACKEND=$(yaml_get '.task_management.backend // ""' PROJECT.yaml)

    if [[ -z "$_TRACKER_BACKEND" ]]; then
        # Auto-detect from environment
        if [[ "$(uname -s)" == "Darwin" ]]; then
            _TRACKER_BACKEND="asana"
        else
            _TRACKER_BACKEND="gitlab"
        fi
    fi

    echo "$_TRACKER_BACKEND"
}

# Sync task status to external tracker
# For Asana: returns JSON with next_action for LLM to execute MCP call
# For GitLab/GitHub: executes API call directly
#
# Usage: tracker_sync_status "TASK_EXTERNAL_ID" "completed|on_hold|in_progress"
# Output: JSON with status and next_action
tracker_sync_status() {
    local external_id="$1"
    local new_status="$2"
    local backend
    backend=$(tracker_detect)

    case "$backend" in
        asana)
            # Return directive for LLM to call Asana MCP
            local completed_flag="false"
            [[ "$new_status" == "completed" ]] && completed_flag="true"
            cat <<EOF
{
  "tracker": "asana",
  "action": "update_task",
  "task_gid": "$external_id",
  "params": {"completed": $completed_flag},
  "next_action": "sync_asana"
}
EOF
            ;;
        gitlab)
            local project_id
            project_id=$(yaml_get '.task_management.gitlab.project_id // ""' PROJECT.yaml)
            if [[ -z "$project_id" || -z "$external_id" ]]; then
                echo '{"tracker": "gitlab", "status": "skipped", "reason": "missing_config"}'
                return 0
            fi
            local state_event="reopen"
            [[ "$new_status" == "completed" ]] && state_event="close"
            local token_file="${HOME}/.gitlab-token"
            local instance
            instance=$(yaml_get '.git.instance // "gitlab.com"' PROJECT.yaml)
            if [[ -f "$token_file" ]]; then
                local token
                token=$(cat "$token_file")
                local encoded_project
                encoded_project=$(echo "$project_id" | sed 's|/|%2F|g')
                local http_code
                http_code=$(curl -s -o /dev/null -w "%{http_code}" \
                    -X PUT "https://${instance}/api/v4/projects/${encoded_project}/issues/${external_id}" \
                    -H "PRIVATE-TOKEN: ${token}" \
                    -d "state_event=${state_event}" 2>/dev/null)
                echo "{\"tracker\": \"gitlab\", \"status\": \"synced\", \"http_code\": ${http_code}}"
            else
                echo '{"tracker": "gitlab", "status": "skipped", "reason": "no_token"}'
            fi
            ;;
        github)
            if [[ -z "$external_id" ]]; then
                echo '{"tracker": "github", "status": "skipped", "reason": "no_issue_id"}'
                return 0
            fi
            local gh_state="open"
            [[ "$new_status" == "completed" ]] && gh_state="closed"
            if command -v gh &>/dev/null; then
                gh issue edit "$external_id" --state "$gh_state" 2>/dev/null
                echo "{\"tracker\": \"github\", \"status\": \"synced\", \"state\": \"${gh_state}\"}"
            else
                echo '{"tracker": "github", "status": "skipped", "reason": "gh_not_installed"}'
            fi
            ;;
        *)
            echo '{"tracker": "none", "status": "skipped", "reason": "no_backend"}'
            ;;
    esac
}

# Add comment to external tracker
# For Asana: returns directive for LLM MCP call
# For GitLab/GitHub: executes directly
#
# Usage: tracker_sync_comment "TASK_EXTERNAL_ID" "Comment text"
tracker_sync_comment() {
    local external_id="$1"
    local comment="$2"
    local backend
    backend=$(tracker_detect)

    case "$backend" in
        asana)
            cat <<EOF
{
  "tracker": "asana",
  "action": "add_comment",
  "task_gid": "$external_id",
  "params": {"text": $(echo "$comment" | jq -Rs .)},
  "next_action": "sync_asana"
}
EOF
            ;;
        gitlab)
            local project_id
            project_id=$(yaml_get '.task_management.gitlab.project_id // ""' PROJECT.yaml)
            if [[ -z "$project_id" || -z "$external_id" ]]; then
                echo '{"tracker": "gitlab", "status": "skipped", "reason": "missing_config"}'
                return 0
            fi
            local token_file="${HOME}/.gitlab-token"
            local instance
            instance=$(yaml_get '.git.instance // "gitlab.com"' PROJECT.yaml)
            if [[ -f "$token_file" ]]; then
                local token
                token=$(cat "$token_file")
                local encoded_project
                encoded_project=$(echo "$project_id" | sed 's|/|%2F|g')
                local http_code
                http_code=$(curl -s -o /dev/null -w "%{http_code}" \
                    -X POST "https://${instance}/api/v4/projects/${encoded_project}/issues/${external_id}/notes" \
                    -H "PRIVATE-TOKEN: ${token}" \
                    -d "body=$(echo "$comment" | jq -Rs .)" 2>/dev/null)
                echo "{\"tracker\": \"gitlab\", \"status\": \"synced\", \"http_code\": ${http_code}}"
            else
                echo '{"tracker": "gitlab", "status": "skipped", "reason": "no_token"}'
            fi
            ;;
        github)
            if [[ -z "$external_id" ]]; then
                echo '{"tracker": "github", "status": "skipped", "reason": "no_issue_id"}'
                return 0
            fi
            if command -v gh &>/dev/null; then
                gh issue comment "$external_id" --body "$comment" 2>/dev/null
                echo '{"tracker": "github", "status": "synced"}'
            else
                echo '{"tracker": "github", "status": "skipped", "reason": "gh_not_installed"}'
            fi
            ;;
        *)
            echo '{"tracker": "none", "status": "skipped", "reason": "no_backend"}'
            ;;
    esac
}

# Close task in external tracker (convenience wrapper)
# Usage: tracker_sync_close "TASK_EXTERNAL_ID" "Closing comment"
tracker_sync_close() {
    local external_id="$1"
    local comment="${2:-}"

    if [[ -n "$comment" ]]; then
        tracker_sync_comment "$external_id" "$comment"
    fi
    tracker_sync_status "$external_id" "completed"
}
