#!/usr/bin/env bash
# Task Capture Script - Capture tasks from various sources and create TSK documents
#
# Usage:
#   task-capture.sh --json --full [INPUT]
#   task-capture.sh --json --parse [INPUT]
#   task-capture.sh --json --create-doc
#   task-capture.sh --json --sync-external
#   task-capture.sh --raw --<section>
#
# Sections: detect, parse, create-doc, sync-external, full
#
# JSON Output Format:
#   {
#     "status": "success|error|needs_input|needs_clarification",
#     "section": "detect|parse|create-doc|sync-external",
#     "message": "Human-readable summary",
#     "timestamp": "ISO 8601 datetime",
#     ...additional fields based on section...
#   }

set -euo pipefail

# Colors for --raw mode
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/load-profile.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/yaml.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/task-api.sh"

# Default mode
OUTPUT_MODE="json"
SECTION="full"
INPUT_TEXT=""
TASK_TITLE=""
TASK_DESCRIPTION=""
TASK_PRIORITY=""
TASK_SOURCE=""
TASK_ID_INPUT=""
TASK_BACKEND=""

# Parse flags
while [[ $# -gt 0 ]]; do
    case "$1" in
        --json) OUTPUT_MODE="json"; shift ;;
            --toon) OUTPUT_MODE="json"; OUTPUT_FORMAT="toon"; shift ;;
        --raw) OUTPUT_MODE="raw"; shift ;;
        --full) SECTION="full"; shift ;;
        --detect) SECTION="detect"; shift ;;
        --parse) SECTION="parse"; shift ;;
        --create-doc) SECTION="create-doc"; shift ;;
        --sync-external) SECTION="sync-external"; shift ;;
        --input) INPUT_TEXT="$2"; shift 2 ;;
        --title) TASK_TITLE="$2"; shift 2 ;;
        --description) TASK_DESCRIPTION="$2"; shift 2 ;;
        --priority) TASK_PRIORITY="$2"; shift 2 ;;
        --source) TASK_SOURCE="$2"; shift 2 ;;
        --task-id) TASK_ID_INPUT="$2"; shift 2 ;;
        --backend) TASK_BACKEND="$2"; shift 2 ;;
        --help|-h)
            cat << 'EOF'
Task Capture Script - Capture tasks from various sources

Usage:
  task-capture.sh --json --full --input <INPUT>                    # Full workflow
  task-capture.sh --json --detect --input <INPUT>                  # Detect source only
  task-capture.sh --json --parse --input <INPUT>                   # Parse content only
  task-capture.sh --json --create-doc --title <t> [--description <d>] [--priority <p>]  # Create TSK document
  task-capture.sh --json --sync-external --task-id <id> --backend <b>  # Sync to Asana/GitLab
  task-capture.sh --raw --<section>                                # Verbose debugging

Sections:
  detect          - Detect input source (Asana, GitLab, email, SMS, direct)
  parse           - Parse task content and extract requirements
  create-doc      - Create local TSK document
  sync-external   - Create/update external task (Asana/GitLab)
  full            - Run all sections (default)

Examples:
  # Asana URL
  task-capture.sh --json --full --input "https://app.asana.com/0/PROJECT/TASK"

  # GitLab issue
  task-capture.sh --json --full --input "#123"

  # Direct input
  task-capture.sh --json --full --input "Fix login bug"

  # Email paste (multiline)
  task-capture.sh --json --full --input "$(cat email.txt)"
EOF
            exit 0
            ;;
        *)
            # Treat positional arguments as input text
            if [[ -z "$INPUT_TEXT" ]]; then
                INPUT_TEXT="$1"
            else
                INPUT_TEXT="$INPUT_TEXT $1"
            fi
            shift
            ;;
    esac
done

# Helper: JSON output
json_output() {
    local status="$1"
    local section="$2"
    local message="$3"
    shift 3

    jq -n \
        --arg status "$status" \
        --arg section "$section" \
        --arg msg "$message" \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '$ARGS.named' \
        "$@"
}

# Helper: Detect environment
detect_environment() {
    local os_type
    os_type=$(uname -s)

    if [[ "$os_type" == "Darwin" ]]; then
        echo "work"
    else
        echo "home"
    fi
}

# Helper: Detect source from input
detect_source() {
    local input="$1"

    # Asana URL patterns:
    #   legacy: app.asana.com/0/<project>/<task>
    #   new:    app.asana.com/1/<workspace>/project/<project>/task/<task>
    if [[ "$input" =~ app\.asana\.com/0/[0-9]+/([0-9]+) ]] \
       || [[ "$input" =~ app\.asana\.com/1/[0-9]+/project/[0-9]+/task/([0-9]+) ]] \
       || [[ "$input" =~ app\.asana\.com/[0-9]+/[0-9]+/task/([0-9]+) ]]; then
        echo "asana_url"
        return 0
    fi

    # Asana GID (15+ digits)
    if [[ "$input" =~ ^[0-9]{15,}$ ]]; then
        echo "asana_gid"
        return 0
    fi

    # GitLab URL pattern — matches public gitlab.com or the profile's
    # configured self-hosted instance (regex-escaped for safety).
    local gitlab_host
    gitlab_host=$(profile_env_get .git.instance 2>/dev/null)
    local gitlab_host_re=""
    if [[ -n "$gitlab_host" && "$gitlab_host" != "gitlab.com" ]]; then
        gitlab_host_re=$(printf '%s' "$gitlab_host" | sed 's/[.[\*^$()+?{|]/\\&/g')
    fi
    if [[ "$input" =~ gitlab\.com.*issues/([0-9]+) ]] \
       || { [[ -n "$gitlab_host_re" ]] && [[ "$input" =~ ${gitlab_host_re}.*issues/([0-9]+) ]]; }; then
        echo "gitlab_url"
        return 0
    fi

    # GitLab issue number
    if [[ "$input" =~ ^#?([0-9]+)$ ]]; then
        echo "gitlab_issue"
        return 0
    fi

    # Email format (has headers like From:, Subject:)
    if [[ "$input" =~ From:|Subject:|To: ]]; then
        echo "email"
        return 0
    fi

    # Short message (< 200 chars, no newlines) likely SMS
    if [[ ${#input} -lt 200 ]] && [[ ! "$input" =~ $'\n' ]]; then
        echo "sms_or_direct"
        return 0
    fi

    # Default to direct input
    echo "direct"
}

# Helper: Extract Asana GID from input
extract_asana_gid() {
    local input="$1"

    # From URL (legacy or new format)
    if [[ "$input" =~ app\.asana\.com/0/[0-9]+/([0-9]+) ]] \
       || [[ "$input" =~ app\.asana\.com/1/[0-9]+/project/[0-9]+/task/([0-9]+) ]] \
       || [[ "$input" =~ app\.asana\.com/[0-9]+/[0-9]+/task/([0-9]+) ]]; then
        echo "${BASH_REMATCH[1]}"
        return 0
    fi

    # Direct GID
    if [[ "$input" =~ ^[0-9]{15,}$ ]]; then
        echo "$input"
        return 0
    fi

    return 1
}

# Helper: Extract GitLab issue ID
extract_gitlab_issue() {
    local input="$1"

    # From URL
    if [[ "$input" =~ issues/([0-9]+) ]]; then
        echo "${BASH_REMATCH[1]}"
        return 0
    fi

    # From issue number
    if [[ "$input" =~ ^#?([0-9]+)$ ]]; then
        echo "${BASH_REMATCH[1]}"
        return 0
    fi

    return 1
}

# Section: Detect source
section_detect() {
    local input="${INPUT_TEXT}"

    if [[ -z "$input" ]]; then
        if [[ "${OUTPUT_MODE}" == "json" ]]; then
            json_output "needs_input" "detect" "No input provided" \
                --arg details "Provide task input: URL, GID, issue number, or text description"
        else
            echo -e "${YELLOW}No input provided${NC}"
            echo "Provide: Asana URL/GID, GitLab issue, or task description"
        fi
        return 0
    fi

    local env
    env=$(detect_environment)

    local source
    source=$(detect_source "$input")

    local extracted_id=""
    case "$source" in
        asana_url|asana_gid)
            extracted_id=$(extract_asana_gid "$input")
            ;;
        gitlab_url|gitlab_issue)
            extracted_id=$(extract_gitlab_issue "$input")
            ;;
    esac

    if [[ "${OUTPUT_MODE}" == "json" ]]; then
        json_output "success" "detect" "Source detected: $source" \
            --arg env "$env" \
            --arg source "$source" \
            --arg input "$input" \
            --arg extracted_id "$extracted_id"
    else
        echo -e "${GREEN}✓${NC} Environment: $env"
        echo -e "${GREEN}✓${NC} Source: $source"
        [[ -n "$extracted_id" ]] && echo -e "${GREEN}✓${NC} Extracted ID: $extracted_id"
    fi
}

# Section: Parse task content
# This section is a PLACEHOLDER - actual parsing should be done by LLM (Opus)
section_parse() {
    local input="${INPUT_TEXT}"

    if [[ "${OUTPUT_MODE}" == "json" ]]; then
        json_output "needs_llm" "parse" "Task parsing requires LLM (Opus)" \
            --arg details "LLM should analyze input and extract: title, description, requirements, priority, task type" \
            --arg input "$input"
    else
        echo -e "${YELLOW}⚠${NC}  Task parsing requires LLM analysis"
        echo "LLM should extract:"
        echo "  - Task title"
        echo "  - Description/context"
        echo "  - Requirements (functional, technical, acceptance criteria)"
        echo "  - Priority (auto-detect from urgency/deadline)"
        echo "  - Task type (bug, feature, enhancement, etc.)"
    fi
}

# Section: Create local TSK document
section_create_doc() {
    local task_title="${TASK_TITLE}"
    local task_description="${TASK_DESCRIPTION}"
    local task_priority="${TASK_PRIORITY:-Medium}"
    local task_source="${TASK_SOURCE:-direct}"

    if [[ -z "$task_title" ]]; then
        if [[ "${OUTPUT_MODE}" == "json" ]]; then
            json_output "error" "create-doc" "Task title required" \
                --arg details "Use --title <title> before calling --create-doc"
        else
            echo -e "${RED}Error: --title required${NC}"
        fi
        return 1
    fi

    # Generate description slug
    local description_slug
    description_slug=$(echo "$task_title" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9 -]//g' | tr ' ' '-' | cut -d'-' -f1-4 | head -c 40)

    # Get filepath + template from new-doc.sh --json (no file written)
    local doc_json
    if ! doc_json=$("${SCRIPT_DIR}/new-doc.sh" --type TSK --description "$description_slug" --new --status active --json 2>/dev/null); then
        if [[ "${OUTPUT_MODE}" == "json" ]]; then
            json_output "error" "create-doc" "Failed to compute document path" \
                --arg details "$doc_json"
        else
            echo -e "${RED}Error computing document path${NC}"
        fi
        return 1
    fi

    local task_id filepath template
    task_id=$(echo "$doc_json" | jq -r '.task_id')
    filepath=$(echo "$doc_json" | jq -r '.filepath')
    template=$(echo "$doc_json" | jq -r '.template')

    if [[ -z "$filepath" || -z "$task_id" ]]; then
        if [[ "${OUTPUT_MODE}" == "json" ]]; then
            json_output "error" "create-doc" "Failed to get document path" \
                --arg details "$doc_json"
        else
            echo -e "${RED}Error: Could not determine document path${NC}"
        fi
        return 1
    fi

    if [[ "${OUTPUT_MODE}" == "json" ]]; then
        json_output "success" "create-doc" "TSK document ready — write completed document to filepath" \
            --arg next_action "write_document" \
            --arg task_id "$task_id" \
            --arg filepath "$filepath" \
            --arg title "$task_title" \
            --arg priority "$task_priority" \
            --arg template "$template"
    else
        echo -e "${GREEN}✓${NC} TSK document ready"
        echo "  Task ID: $task_id"
        echo "  File: $filepath"
        echo ""
        echo -e "${BLUE}Next: Write completed document to $filepath${NC}"
    fi
}

# Helper: Resolve the active task backend (mirrors task-api.sh dispatcher logic).
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

# Section: Sync to external system
section_sync_external() {
    # This section expects TSK document to exist and external tracking configured
    # It creates/updates Asana or GitLab task

    local task_id="${TASK_ID_INPUT}"
    local backend="${TASK_BACKEND}"

    if [[ -z "$task_id" ]]; then
        if [[ "${OUTPUT_MODE}" == "json" ]]; then
            json_output "error" "sync-external" "Task ID required" \
                --arg details "Use --task-id <id>"
        else
            echo -e "${RED}Error: --task-id required${NC}"
        fi
        return 1
    fi

    # Auto-detect backend if not explicitly passed
    if [[ -z "$backend" ]]; then
        backend=$(_active_backend)
    fi

    # No backend configured at all
    if [[ -z "$backend" || "$backend" == "null" ]]; then
        if [[ "${OUTPUT_MODE}" == "json" ]]; then
            json_output "skipped" "sync-external" "No external backend configured" \
                --arg details "No task_management.backend in PROJECT.yaml and no --backend flag"
        else
            echo -e "${YELLOW}⚠${NC}  No external backend configured - skipping"
        fi
        return 0
    fi

    # Backend is the app itself — no external sync needed
    if [[ "$backend" == "taskforge" || "$backend" == "none" ]]; then
        if [[ "${OUTPUT_MODE}" == "json" ]]; then
            json_output "skipped" "sync-external" "Backend is $backend — no external sync needed" \
                --arg backend "$backend" \
                --arg details "Task is already tracked in $backend"
        else
            echo -e "${GREEN}✓${NC}  Backend is $backend — no external sync needed"
        fi
        return 0
    fi

    # Load the adapter and sync via task_* contract (no MCP / direct backend calls).
    if ! load_task_adapter; then
        if [[ "${OUTPUT_MODE}" == "json" ]]; then
            json_output "error" "sync-external" "Failed to load task adapter for backend: $backend" \
                --arg backend "$backend"
        else
            echo -e "${RED}Error: Failed to load task adapter for backend: $backend${NC}"
        fi
        return 1
    fi

    # Probe auth/connectivity before attempting write.
    if ! task_health >/dev/null 2>&1; then
        if [[ "${OUTPUT_MODE}" == "json" ]]; then
            json_output "error" "sync-external" "Task backend health check failed" \
                --arg backend "$backend" \
                --arg details "Check credentials for backend '$backend'"
        else
            echo -e "${RED}Error: Task backend health check failed for $backend${NC}"
        fi
        return 1
    fi

    # Attempt to fetch the existing task by its backend-native ID.
    # If found, the task already exists externally — nothing to create.
    local existing
    if existing=$(task_get "$task_id" 2>/dev/null); then
        local ext_url
        ext_url=$(echo "$existing" | jq -r '.url // empty')
        if [[ "${OUTPUT_MODE}" == "json" ]]; then
            json_output "success" "sync-external" "Task already exists in $backend" \
                --arg backend "$backend" \
                --arg task_id "$task_id" \
                --arg url "$ext_url"
        else
            echo -e "${GREEN}✓${NC}  Task $task_id already exists in $backend"
            [[ -n "$ext_url" ]] && echo "  URL: $ext_url"
        fi
        return 0
    fi

    # Task not found externally — create it via the adapter.
    local title="${TASK_TITLE:-Task $task_id}"
    local body="${TASK_DESCRIPTION:-}"
    local create_result
    if ! create_result=$(task_create "$title" "$body" 2>&1); then
        if [[ "${OUTPUT_MODE}" == "json" ]]; then
            json_output "error" "sync-external" "Failed to create task in $backend" \
                --arg backend "$backend" \
                --arg details "$create_result"
        else
            echo -e "${RED}Error: Failed to create task in $backend: $create_result${NC}"
        fi
        return 1
    fi

    local new_id new_url
    new_id=$(echo "$create_result" | jq -r '.id // empty')
    new_url=$(echo "$create_result" | jq -r '.url // empty')

    if [[ "${OUTPUT_MODE}" == "json" ]]; then
        json_output "success" "sync-external" "Task created in $backend" \
            --arg backend "$backend" \
            --arg task_id "$task_id" \
            --arg external_id "$new_id" \
            --arg url "$new_url"
    else
        echo -e "${GREEN}✓${NC}  Task created in $backend"
        [[ -n "$new_id" ]] && echo "  External ID: $new_id"
        [[ -n "$new_url" ]] && echo "  URL: $new_url"
    fi
}

# Section: Full workflow
section_full() {
    # Run all sections in sequence
    # This is a simplified version - actual implementation would coordinate sections

    if [[ "${OUTPUT_MODE}" == "json" ]]; then
        json_output "needs_llm" "full" "Full workflow requires LLM orchestration" \
            --arg details "LLM should: 1) detect source, 2) parse with Opus, 3) create doc, 4) sync external" \
            --arg input "${INPUT_TEXT}"
    else
        echo -e "${BLUE}Full task capture workflow${NC}"
        echo ""
        echo "Steps:"
        echo "  1. Detect source (Asana, GitLab, email, etc.)"
        echo "  2. Parse task content with Opus"
        echo "  3. Create local TSK document"
        echo "  4. Sync to external system (if configured)"
        echo ""
        echo -e "${YELLOW}Note: This requires LLM orchestration${NC}"
    fi
}

# Main execution
main() {
    case "$SECTION" in
        detect)
            section_detect
            ;;
        parse)
            section_parse
            ;;
        create-doc)
            section_create_doc
            ;;
        sync-external)
            section_sync_external
            ;;
        full)
            section_full
            ;;
        *)
            if [[ "${OUTPUT_MODE}" == "json" ]]; then
                json_output "error" "main" "Invalid section: $SECTION"
            else
                echo -e "${RED}Error: Invalid section: $SECTION${NC}"
            fi
            exit 1
            ;;
    esac
}

main
