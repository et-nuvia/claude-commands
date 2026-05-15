#!/usr/bin/env bash
set -euo pipefail

# STANDARD SCRIPT PATTERN: Section flags with --json/--raw output modes
#
# Usage:
#   ~/.claude/scripts/task-fetch.sh [--json|--raw] [--full|--fetch] [options]
#
# Output Modes:
#   --json: Structured JSON output for LLM (default)
#   --raw:  Verbose debugging output when LLM needs more details
#
# Section Flags (run specific section only):
#   --validate:  Validate prerequisites (config, tokens)
#   --fetch:     Fetch tasks from backend
#   --full:      Run all sections end-to-end (default)
#
# Options:
#   --format <format>  Output format (text|json|markdown) - default: text
#   --status <status>  Filter by status (open|closed|all) - default: open
#   --project <name>   Filter by project/label
#
# Workflow:
#   1. LLM calls: task-fetch.sh --json --full
#   2. If error: Returns JSON with error details
#   3. LLM can retry with --raw for more debugging info

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source shared output framework
source "${SCRIPT_DIR}/lib/output-framework.sh"
source "${SCRIPT_DIR}/lib/yaml.sh"

# Global variables
OUTPUT_MODE="json"  # json or raw
SECTION="full"      # full, validate, fetch
FORMAT="text"       # text, json, markdown
STATUS="open"       # open, closed, all
PROJECT=""
BACKEND=""
ENV_TYPE=""
TASKS=""
TASK_COUNT=0

#------------------------------------------------------------------------------
# Section Functions
#------------------------------------------------------------------------------

# Section 1: Validate prerequisites
section_validate() {
    log "${BLUE}Validating Prerequisites${NC}"

    # Check for PROJECT.yaml
    if [[ ! -f "PROJECT.yaml" ]]; then
        if [[ "$SECTION" == "validate" ]] || [[ "$OUTPUT_MODE" == "json" ]]; then
            exit_with_json "error" "PROJECT.yaml not found" "Run: /project-config init"
        else
            log "${RED}✗${NC} PROJECT.yaml not found"
            exit 1
        fi
    fi
    log "${GREEN}✓${NC} PROJECT.yaml found"

    # Detect environment and backend
    if [[ -x "${SCRIPT_DIR}/detect-environment.sh" ]]; then
        ENV_TYPE=$("${SCRIPT_DIR}/detect-environment.sh" environment)
        DEFAULT_BACKEND=$("${SCRIPT_DIR}/detect-environment.sh" task-backend)
    else
        ENV_TYPE="unknown"
        DEFAULT_BACKEND="asana"
    fi

    # Read backend from PROJECT.yaml or use default
    BACKEND=$(yaml_get '.task_management.backend' PROJECT.yaml)
    if [[ "$BACKEND" == "null" ]] || [[ -z "$BACKEND" ]]; then
        BACKEND="$DEFAULT_BACKEND"
    fi

    log "${GREEN}✓${NC} Environment: $ENV_TYPE"
    log "${GREEN}✓${NC} Backend: $BACKEND"

    # Validate backend-specific requirements
    if [[ "$BACKEND" == "asana" ]]; then
        if [[ ! -f "$HOME/.asana-token" ]]; then
            local error_msg="Asana token not found at ~/.asana-token

Create token:
1. Go to Asana Settings → Apps → Developer Apps
2. Create Personal Access Token
3. Save: echo \"TOKEN\" > ~/.asana-token && chmod 600 ~/.asana-token"
            if [[ "$SECTION" == "validate" ]] || [[ "$OUTPUT_MODE" == "json" ]]; then
                exit_with_json "error" "Asana token not found" "$error_msg"
            else
                log "${RED}✗${NC} Asana token not found"
                echo "$error_msg"
                exit 1
            fi
        fi
        log "${GREEN}✓${NC} Asana token found"
    elif [[ "$BACKEND" == "gitlab" ]]; then
        if [[ ! -f "$HOME/.gitlab-token" ]]; then
            local error_msg="GitLab token not found at ~/.gitlab-token

Create token:
1. Go to GitLab Settings → Access Tokens
2. Create Personal Access Token with api scope
3. Save: echo \"TOKEN\" > ~/.gitlab-token && chmod 600 ~/.gitlab-token"
            if [[ "$SECTION" == "validate" ]] || [[ "$OUTPUT_MODE" == "json" ]]; then
                exit_with_json "error" "GitLab token not found" "$error_msg"
            else
                log "${RED}✗${NC} GitLab token not found"
                echo "$error_msg"
                exit 1
            fi
        fi
        log "${GREEN}✓${NC} GitLab token found"

        # Validate project ID for GitLab
        local project_id=$(yaml_get '.task_management.gitlab.project_id' PROJECT.yaml)
        if [[ "$project_id" == "null" ]] || [[ -z "$project_id" ]]; then
            local error_msg="GitLab project_id not set in PROJECT.yaml

Add to PROJECT.yaml:
task_management:
  gitlab:
    project_id: \"owner/repo\""
            if [[ "$SECTION" == "validate" ]] || [[ "$OUTPUT_MODE" == "json" ]]; then
                exit_with_json "error" "GitLab project_id not configured" "$error_msg"
            else
                log "${RED}✗${NC} GitLab project_id not configured"
                echo "$error_msg"
                exit 1
            fi
        fi
        log "${GREEN}✓${NC} GitLab project_id configured"
    else
        exit_with_json "error" "Unknown backend: $BACKEND" "Supported: asana, gitlab"
    fi

    # If running only this section, return now
    if [[ "$SECTION" == "validate" ]]; then
        exit_with_json "success" "Validation complete" "All prerequisites satisfied" \
            '"environment": "'"$ENV_TYPE"'",' '"backend": "'"$BACKEND"'"'
    fi

    log "${GREEN}✓${NC} Validation complete"
}

# Section 2: Fetch tasks from backend
section_fetch() {
    log "${BLUE}Fetching Tasks from $BACKEND${NC}"

    if [[ "$BACKEND" == "asana" ]]; then
        fetch_asana_tasks
    elif [[ "$BACKEND" == "gitlab" ]]; then
        fetch_gitlab_tasks
    else
        exit_with_json "error" "Unknown backend: $BACKEND" "Supported: asana, gitlab"
    fi

    # Count tasks
    TASK_COUNT=$(echo "$TASKS" | jq 'length' 2>/dev/null || echo "0")
    log "${GREEN}✓${NC} Found $TASK_COUNT tasks"

    # If running only this section, return now
    if [[ "$SECTION" == "fetch" ]]; then
        exit_with_json "success" "Tasks fetched successfully" "Retrieved $TASK_COUNT tasks" \
            '"backend": "'"$BACKEND"'",' '"task_count": '"$TASK_COUNT"',' '"tasks": '"$TASKS"
    fi
}

# Fetch tasks from Asana
fetch_asana_tasks() {
    log "Fetching from Asana API..."

    local token=$(cat "$HOME/.asana-token")

    # Get user ID
    local user_id=$(curl -s -H "Authorization: Bearer ${token}" \
        "https://app.asana.com/api/1.0/users/me" | \
        jq -r '.data.gid' 2>/dev/null || echo "")

    if [[ -z "$user_id" ]]; then
        exit_with_json "error" "Failed to get Asana user ID" "Check token validity"
    fi

    # Asana requires workspace when filtering by assignee.
    # Read workspace_id from PROJECT.yaml.
    local workspace_id=$(yaml_get '.task_management.asana.workspace_id' PROJECT.yaml)
    if [[ "$workspace_id" == "null" ]] || [[ -z "$workspace_id" ]]; then
        exit_with_json "error" "Asana workspace_id not configured" "Add task_management.asana.workspace_id to PROJECT.yaml"
    fi

    # Build query parameters.
    # Asana's /tasks endpoint returns only incomplete tasks when `completed_since=now`
    # is provided. For "closed" or "all", omit it and filter client-side.
    local extra_params=""
    if [[ "$STATUS" == "open" ]]; then
        extra_params="&completed_since=now"
    fi

    # Fetch tasks
    local response=$(curl -s -H "Authorization: Bearer ${token}" \
        "https://app.asana.com/api/1.0/tasks?assignee=${user_id}&workspace=${workspace_id}${extra_params}&opt_fields=name,due_on,completed,projects.name,permalink_url&limit=100")

    # Surface Asana API errors instead of silently returning []
    local api_error=$(echo "$response" | jq -r '.errors[0].message // empty' 2>/dev/null)
    if [[ -n "$api_error" ]]; then
        exit_with_json "error" "Asana API error" "$api_error"
    fi

    TASKS=$(echo "$response" | jq -c '.data // []' 2>/dev/null || echo "[]")

    # Client-side filter for "closed" (API has no completed=true filter when using assignee+workspace)
    if [[ "$STATUS" == "closed" ]]; then
        TASKS=$(echo "$TASKS" | jq -c '[.[] | select(.completed == true)]')
    fi

    # Filter by project if specified
    if [[ -n "$PROJECT" ]]; then
        TASKS=$(echo "$TASKS" | jq --arg proj "$PROJECT" '[.[] | select(.projects[]?.name == $proj)]')
    fi

    # Enrich each task with local V4 Task ID (6-char hex) if a TSK doc exists.
    # TSK docs record the Asana GID under External Tracking; filenames start with the 6-char hex.
    TASKS=$(enrich_tasks_with_local_ids "$TASKS")

    log "${GREEN}✓${NC} Asana tasks fetched"
}

# For each task in the input JSON array, look up its local 6-char hex Task ID
# by scanning docs/ for a TSK file referencing the Asana GID. Adds a
# "task_id" field (null if no local doc exists yet).
enrich_tasks_with_local_ids() {
    local tasks_json="$1"
    local docs_dir="docs"
    [[ -d "$docs_dir" ]] || { echo "$tasks_json"; return; }

    # Build a gid → task_id map by scanning TSK docs once.
    # Filenames look like: <HEX6>-<YYMMDDHHMM>-TSK-<slug>.md
    local map_file
    map_file=$(mktemp)
    trap "rm -f '$map_file'" RETURN

    # Find all TSK docs and extract the Asana GID referenced inside.
    while IFS= read -r -d '' file; do
        local basename hex6 gid
        basename=$(basename "$file")
        hex6="${basename:0:6}"
        # Only accept valid 6-char uppercase hex prefixes
        [[ "$hex6" =~ ^[0-9A-F]{6}$ ]] || continue
        # Extract the first Asana Task GID line from the doc
        gid=$(grep -m1 -iE 'task gid' "$file" 2>/dev/null | grep -oE '[0-9]{10,}' | head -n1)
        [[ -n "$gid" ]] && echo "$gid $hex6" >> "$map_file"
    done < <(find "$docs_dir" -type f -name "*-TSK-*.md" -print0 2>/dev/null)

    # Inject task_id into each task
    echo "$tasks_json" | jq -c --slurpfile _ignore <(echo '[]') '.' | \
        jq -c --rawfile mapdata "$map_file" '
            ([$mapdata | split("\n") | map(select(length > 0) | split(" ") | {key: .[0], value: .[1]}) | from_entries]) as $m
            | map(. + {task_id: ($m[0][.gid] // null)})
        '
}

# Fetch tasks from GitLab
fetch_gitlab_tasks() {
    log "Fetching from GitLab API..."

    local token=$(cat "$HOME/.gitlab-token")
    local project_id=$(yaml_get '.task_management.gitlab.project_id' PROJECT.yaml)
    local gitlab_url=$(yaml_get_default '.task_management.gitlab.instance' 'https://git.turnersrus.com' PROJECT.yaml)

    # Build query parameters
    local state_param="opened"
    if [[ "$STATUS" == "closed" ]]; then
        state_param="closed"
    elif [[ "$STATUS" == "all" ]]; then
        state_param="all"
    fi

    # Fetch issues
    local response=$(curl -s --header "PRIVATE-TOKEN: ${token}" \
        "${gitlab_url}/api/v4/projects/${project_id}/issues?assignee_id=@me&state=${state_param}&scope=assigned_to_me")

    # Filter by label if project specified
    if [[ -n "$PROJECT" ]]; then
        response=$(echo "$response" | jq --arg label "$PROJECT" '[.[] | select(.labels[]? == $label)]')
    fi

    # Convert to unified format
    TASKS=$(echo "$response" | jq '[.[] | {
        gid: (.iid | tostring),
        name: .title,
        due_on: .due_date,
        completed: (.state == "closed"),
        projects: [{name: (.labels[0] // "No Label")}],
        permalink_url: .web_url
    }]' 2>/dev/null || echo "[]")

    log "${GREEN}✓${NC} GitLab issues fetched"
}

# Format output based on FORMAT option
format_output() {
    case "$FORMAT" in
        text)
            if [[ "$OUTPUT_MODE" == "raw" ]]; then
                echo ""
                echo "Found $TASK_COUNT tasks:"
                echo ""
            fi
            echo "$TASKS" | jq -r '.[] |
                "\(.gid). \(.name)" +
                (if .due_on then " (Due: \(.due_on))" else "" end) +
                (if .projects[0].name then " [\(.projects[0].name)]" else "" end)'
            ;;
        json)
            echo "$TASKS" | jq '.'
            ;;
        markdown)
            echo ""
            echo "# My Tasks"
            echo ""
            echo "$TASKS" | jq -r 'to_entries[] |
                "## \(.key + 1). \(.value.name)\n" +
                (if .value.projects[0].name then "- **Project**: \(.value.projects[0].name)\n" else "" end) +
                (if .value.due_on then "- **Due**: \(.value.due_on)\n" else "" end) +
                "- **URL**: \(.value.permalink_url)\n"'
            ;;
    esac
}

#------------------------------------------------------------------------------
# Main Execution
#------------------------------------------------------------------------------

main() {
    # Parse flags
    while [[ $# -gt 0 ]]; do
        case $1 in
            --json) OUTPUT_MODE="json"; shift ;;
            --toon) OUTPUT_MODE="json"; OUTPUT_FORMAT="toon"; shift ;;
            --raw) OUTPUT_MODE="raw"; shift ;;
            --validate) SECTION="validate"; shift ;;
            --fetch) SECTION="fetch"; shift ;;
            --full) SECTION="full"; shift ;;
            --format)
                FORMAT="$2"
                shift 2
                ;;
            --status)
                STATUS="$2"
                shift 2
                ;;
            --project)
                PROJECT="$2"
                shift 2
                ;;
            *)
                shift
                ;;
        esac
    done

    # Execute sections based on flag
    case "$SECTION" in
        validate)
            section_validate
            ;;
        fetch)
            section_validate  # Prerequisites first
            section_fetch
            ;;
        full)
            section_validate
            section_fetch

            # Full success - format and return results
            if [[ "$OUTPUT_MODE" == "json" ]]; then
                local filters_json
                filters_json=$(jq -n --arg s "$STATUS" --arg p "$PROJECT" --arg f "$FORMAT" \
                    '{status: $s, project: $p, format: $f}')
                exit_with_json "success" "Tasks fetched successfully" "Retrieved $TASK_COUNT tasks" \
                    '"backend": "'"$BACKEND"'",' \
                    '"environment": "'"$ENV_TYPE"'",' \
                    '"task_count": '"$TASK_COUNT"',' \
                    '"tasks": '"$TASKS"',' \
                    '"filters": '"$filters_json"
            else
                # Raw mode - output formatted tasks
                format_output
            fi
            ;;
    esac
}

# Run main function
main "$@"
