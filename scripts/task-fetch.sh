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
#
# Migrated to use the task adapter shims (scripts/lib/task-api.sh).
# Backend-specific fetch paths were collapsed into a single
# task_list call; output shape is preserved for downstream consumers.

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source shared output framework and the task adapter dispatcher.
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/output-framework.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/yaml.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/load-profile.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/task-api.sh"

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

# Resolve the active backend the same way task-api.sh does so error
# messages and downstream output can name it.
_active_backend() {
    local b=""
    if [[ -n "${TASK_ADAPTER_OVERRIDE:-}" ]]; then
        b="$TASK_ADAPTER_OVERRIDE"
    elif [[ -f PROJECT.yaml ]]; then
        b=$(yaml_get '.task_management.backend' PROJECT.yaml 2>/dev/null || true)
    fi
    if [[ -z "$b" || "$b" == "null" ]]; then
        b=$(profile_env_get .task_management.backend 2>/dev/null || true)
    fi
    case "$b" in
        gitlab) echo "gitlab-tasks" ;;
        github) echo "github-tasks" ;;
        *)      echo "$b" ;;
    esac
}

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

    # Detect environment for reporting; backend comes from the adapter.
    if [[ -x "${SCRIPT_DIR}/detect-environment.sh" ]]; then
        ENV_TYPE=$("${SCRIPT_DIR}/detect-environment.sh" environment)
    else
        ENV_TYPE="unknown"
    fi

    if ! load_task_adapter; then
        exit_with_json "error" "Failed to load task adapter" "Set .task_management.backend in PROJECT.yaml or the active profile"
    fi
    BACKEND=$(_active_backend)

    log "${GREEN}✓${NC} Environment: $ENV_TYPE"
    log "${GREEN}✓${NC} Backend: $BACKEND"

    # Auth + connectivity probe via the adapter contract.
    if ! task_health >/dev/null 2>&1; then
        local hint=""
        case "$BACKEND" in
            asana)
                hint="Verify ~/.asana-token exists and is valid."
                ;;
            gitlab-tasks)
                hint="Verify ~/.gitlab-token exists and .task_management.gitlab.project_id is set in PROJECT.yaml."
                ;;
            github-tasks)
                hint="Verify gh auth status and .git.repo in PROJECT.yaml."
                ;;
            *)
                hint="Check adapter prerequisites for backend '$BACKEND'."
                ;;
        esac
        if [[ "$SECTION" == "validate" ]] || [[ "$OUTPUT_MODE" == "json" ]]; then
            exit_with_json "error" "Task backend health check failed" "$hint"
        else
            log "${RED}✗${NC} Task backend health check failed"
            echo "$hint"
            exit 1
        fi
    fi
    log "${GREEN}✓${NC} Task backend reachable"

    # If running only this section, return now
    if [[ "$SECTION" == "validate" ]]; then
        exit_with_json "success" "Validation complete" "All prerequisites satisfied" \
            '"environment": "'"$ENV_TYPE"'",' '"backend": "'"$BACKEND"'"'
    fi

    log "${GREEN}✓${NC} Validation complete"
}

# Section 2: Fetch tasks from backend (via adapter)
section_fetch() {
    log "${BLUE}Fetching Tasks from $BACKEND${NC}"

    # Normalized task list from the adapter. Each element matches the
    # contract: {id, title, status, assignee, created_at, updated_at,
    # url, raw}.
    local normalized
    if ! normalized=$(task_list --state "$STATUS" --assignee me 2>&1); then
        exit_with_json "error" "Failed to list tasks" "$normalized"
    fi

    # Optional project/label filter. Adapter-specific data lives under
    # .raw — Asana uses .raw.memberships[].project.name, GitLab uses
    # .raw.labels[], GitHub uses .raw.labels[].name. Try all three.
    if [[ -n "$PROJECT" ]]; then
        normalized=$(echo "$normalized" | jq --arg p "$PROJECT" '[
            .[] | select(
                ((.raw.memberships // []) | map(.project.name) | index($p)) // null != null
                or ((.raw.labels // []) | map(if type=="object" then .name else . end) | index($p)) // null != null
            )
        ]')
    fi

    # Map normalized schema → legacy output shape used by downstream
    # consumers (format_output, enrich_tasks_with_local_ids, callers
    # parsing .gid/.name/.due_on/.completed/.projects/.permalink_url).
    TASKS=$(echo "$normalized" | jq '[
        .[] | {
            gid: .id,
            name: .title,
            due_on: (.raw.due_on // .raw.due_date // null),
            completed: (.status == "closed"),
            projects: (
                (.raw.memberships // []) | map({name: .project.name})
                + ((.raw.labels // []) | map(if type=="object" then {name: .name} else {name: .} end))
            ),
            permalink_url: .url
        }
    ]')

    # Enrich each task with local V4 Task ID (6-char hex) when a TSK
    # doc references the backend-native ID.
    TASKS=$(enrich_tasks_with_local_ids "$TASKS")

    TASK_COUNT=$(echo "$TASKS" | jq 'length' 2>/dev/null || echo "0")
    log "${GREEN}✓${NC} Found $TASK_COUNT tasks"

    if [[ "$SECTION" == "fetch" ]]; then
        exit_with_json "success" "Tasks fetched successfully" "Retrieved $TASK_COUNT tasks" \
            '"backend": "'"$BACKEND"'",' '"task_count": '"$TASK_COUNT"',' '"tasks": '"$TASKS"
    fi
}

# For each task in the input JSON array, look up its local 6-char hex Task ID
# by scanning docs/ for a TSK file referencing the backend-native ID. Adds a
# "task_id" field (null if no local doc exists yet).
enrich_tasks_with_local_ids() {
    local tasks_json="$1"
    local docs_dir="docs"
    [[ -d "$docs_dir" ]] || { echo "$tasks_json"; return; }

    local map_file
    map_file=$(mktemp)
    trap "rm -f '$map_file'" RETURN

    # Filenames look like: <HEX6>-<YYMMDDHHMM>-TSK-<slug>.md
    # The doc references the backend-native ID under "task gid" / "issue id".
    while IFS= read -r -d '' file; do
        local basename hex6 id
        basename=$(basename "$file")
        hex6="${basename:0:6}"
        [[ "$hex6" =~ ^[0-9A-F]{6}$ ]] || continue
        id=$(grep -m1 -iE 'task gid|issue id|task id' "$file" 2>/dev/null | grep -oE '[0-9]{2,}' | head -n1)
        [[ -n "$id" ]] && echo "$id $hex6" >> "$map_file"
    done < <(find "$docs_dir" -type f -name "*-TSK-*.md" -print0 2>/dev/null)

    echo "$tasks_json" | jq -c --rawfile mapdata "$map_file" '
        ([$mapdata | split("\n") | map(select(length > 0) | split(" ") | {key: .[0], value: .[1]}) | from_entries]) as $m
        | map(. + {task_id: ($m[.gid] // null)})
    '
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

    case "$SECTION" in
        validate)
            section_validate
            ;;
        fetch)
            section_validate
            section_fetch
            ;;
        full)
            section_validate
            section_fetch

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
                format_output
            fi
            ;;
    esac
}

main "$@"
