#!/usr/bin/env bash
set -euo pipefail

# task-resume.sh - Resume a completed or on-hold task with new input
#
# Section-based workflow with JSON output for LLM orchestration.
# Script handles deterministic operations, LLM handles MCP (Asana, etc.)
#
# Usage:
#   task-resume.sh --search <input_text>           # Find matching tasks
#   task-resume.sh --reopen <task_id> <input>     # Reopen task
#   task-resume.sh --document <task_id> <input>   # Create UPD document
#   task-resume.sh --setup <task_id>              # Setup environment
#   task-resume.sh --full <input_text>             # Full workflow
#   task-resume.sh --json <input_text>             # JSON output (full)
#   task-resume.sh --raw <input_text>              # Verbose output (full)
#
# Sections:
#   --search    : Parse input, find matching tasks, return top matches
#   --reopen    : Move documents from completed/ to active/, update status
#   --document  : Create new UPD/FND document with input content
#   --setup     : Restore branch, create .current-task file
#   --full      : Execute all sections (default)
#
# Output modes:
#   --json : JSON output for LLM orchestration (default for sections)
#   --raw  : Verbose colored output for debugging
#
# Status values:
#   success           : Section completed successfully
#   needs_selection   : Multiple matches found, user must choose
#   needs_llm         : LLM intervention required (populate document, sync Asana)
#   error             : Section failed

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source utilities
source "${SCRIPT_DIR}/doc-utils.sh"
source "${SCRIPT_DIR}/get-default-branch.sh"

# Colors for raw mode
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

#------------------------------------------------------------------------------
# Global Variables
#------------------------------------------------------------------------------

OUTPUT_MODE="json"  # json | raw
SECTION=""          # search | reopen | document | setup | full
INPUT_TEXT=""
TASK_ID=""
INPUT_SOURCE=""
SELECTED_TASK=""
TASK_TITLE=""
TASK_SLUG=""
PREVIOUS_STATUS=""
RANGE_FOLDER=""
NEW_DOC_FILENAME=""
NEW_DOC_TYPE=""
PRESERVED_BRANCH=""
BRANCH_RESTORED=false
MOVED_COUNT=0
ASANA_GID=""
SHOULD_SYNC_ASANA=false
DOCS_DIR="$(find_docs_dir 2>/dev/null || echo "docs")"

#------------------------------------------------------------------------------
# Logging Functions
#------------------------------------------------------------------------------

log_info() {
    [[ "$OUTPUT_MODE" == "raw" ]] && echo -e "${BLUE}ℹ${NC} $*" || true
}

log_success() {
    [[ "$OUTPUT_MODE" == "raw" ]] && echo -e "${GREEN}✓${NC} $*" || true
}

log_warning() {
    [[ "$OUTPUT_MODE" == "raw" ]] && echo -e "${YELLOW}⚠${NC} $*" || true
}

log_error() {
    echo -e "${RED}✗${NC} $*" >&2
}

print_header() {
    if [[ "$OUTPUT_MODE" == "raw" ]]; then
        echo ""
        echo -e "${CYAN}$1${NC}"
        printf '%.0s─' {1..60}
        echo ""
    fi
}

#------------------------------------------------------------------------------
# JSON Output Functions
#------------------------------------------------------------------------------

output_json_error() {
    local section="$1"
    local message="$2"
    local details="${3:-}"

    cat <<EOF
{
  "status": "error",
  "section": "$section",
  "message": "$message",
  "details": "$details",
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
EOF
    exit 1
}

output_json_success() {
    local section="$1"
    shift

    echo "{"
    echo "  \"status\": \"success\","
    echo "  \"section\": \"$section\","
    while [[ $# -gt 0 ]]; do
        echo "  $1"
        shift
        [[ $# -gt 0 ]] && echo ","
    done
    echo "  \"timestamp\": \"$(date -u +"%Y-%m-%dT%H:%M:%SZ")\""
    echo "}"
}

#------------------------------------------------------------------------------
# Section 1: Search for Matching Tasks
#------------------------------------------------------------------------------

# Determine input source
detect_input_source() {
    if [[ "$INPUT_TEXT" =~ ^[A-Fa-f0-9]{6}$ ]]; then
        INPUT_SOURCE="task_id"
    elif [[ "$INPUT_TEXT" =~ asana\.com|gitlab|github ]]; then
        INPUT_SOURCE="url"
    elif [[ "$INPUT_TEXT" =~ From:|Subject:|To: ]]; then
        INPUT_SOURCE="email"
    elif [[ "${#INPUT_TEXT}" -lt 200 ]] && [[ "$INPUT_TEXT" =~ [0-9]{3}-[0-9]{3}-[0-9]{4} ]]; then
        INPUT_SOURCE="sms"
    elif [[ "$INPUT_TEXT" =~ ^[A-Z][a-z]+:\ .* ]]; then
        INPUT_SOURCE="cliq"
    else
        INPUT_SOURCE="direct"
    fi
}

# Extract keywords for matching
extract_keywords() {
    local text="$1"

    echo "$text" | \
        tr '[:upper:]' '[:lower:]' | \
        grep -oE '\b[a-z]{4,}\b' | \
        grep -vE '^(with|from|that|this|have|been|were|will|should|could|would|about|when|what|where)$' | \
        head -20 | \
        tr '\n' ' '
}

# Score task match
score_task_match() {
    local task_file="$1"
    local keywords="$2"
    local score=0

    # Read task content (first 100 lines for performance)
    local task_content=$(head -100 "$task_file" 2>/dev/null || echo "")
    local task_content_lower=$(echo "$task_content" | tr '[:upper:]' '[:lower:]')

    # Score based on keyword matches
    for keyword in $keywords; do
        local count=$(echo "$task_content_lower" | grep -o "$keyword" | wc -l)
        score=$((score + count * 10))
    done

    # Bonus for exact phrase matches
    local input_lower=$(echo "$INPUT_TEXT" | tr '[:upper:]' '[:lower:]')
    if echo "$task_content_lower" | grep -qF "$input_lower"; then
        score=$((score + 50))
    fi

    # Bonus for title match
    local title=$(grep -m1 "^#\s" "$task_file" | tr '[:upper:]' '[:lower:]' || echo "")
    for keyword in $keywords; do
        if echo "$title" | grep -q "$keyword"; then
            score=$((score + 20))
        fi
    done

    echo "$score"
}

section_search() {
    print_header "Searching for Matching Tasks"

    # Detect input source
    detect_input_source
    log_info "Input source: $INPUT_SOURCE"

    # If direct task ID provided, find it directly
    if [[ "$INPUT_SOURCE" == "task_id" ]]; then
        TASK_ID=$(normalize_task_id "$INPUT_TEXT")
        SELECTED_TASK=$(find_primary "$TASK_ID")

        if [[ -z "$SELECTED_TASK" ]]; then
            output_json_error "search" "Task not found for task ID $TASK_ID" "No TSK/INC document found"
        fi

        TASK_TITLE=$(get_doc_title "$SELECTED_TASK")
        PREVIOUS_STATUS=$(get_status "$TASK_ID")

        if [[ "$OUTPUT_MODE" == "json" ]]; then
            cat <<EOF
{
  "status": "found",
  "section": "search",
  "task_id": "$TASK_ID",
  "task_title": "$TASK_TITLE",
  "task_status": "$PREVIOUS_STATUS",
  "task_file": "$SELECTED_TASK",
  "input_source": "$INPUT_SOURCE",
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
EOF
        else
            log_success "Found task $TASK_ID: $TASK_TITLE"
            echo "  Status: $PREVIOUS_STATUS"
        fi
        return 0
    fi

    # Extract keywords from input
    local keywords=$(extract_keywords "$INPUT_TEXT")
    log_info "Keywords: $keywords"

    # Search in completed, on-hold, then active tasks
    local search_dirs=(
        "$DOCS_DIR/completed"
        "$DOCS_DIR/active"
    )

    # Find all TSK/INC documents and score them
    local matches=""
    for dir in "${search_dirs[@]}"; do
        [[ ! -d "$dir" ]] && continue

        while IFS= read -r task_file; do
            [[ -z "$task_file" ]] && continue

            local score=$(score_task_match "$task_file" "$keywords")

            # Only include matches with score > 20
            if [[ $score -gt 20 ]]; then
                matches+="${score}:${task_file}"$'\n'
            fi
        done < <(find "$dir" -type f \( -name "*-TSK-*" -o -name "*-INC-*" \) 2>/dev/null | sort -r)
    done

    if [[ -z "$matches" ]]; then
        if [[ "$OUTPUT_MODE" == "json" ]]; then
            cat <<EOF
{
  "status": "not_found",
  "section": "search",
  "message": "No matching tasks found",
  "input_source": "$INPUT_SOURCE",
  "suggestion": "Create new task with /task-capture",
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
EOF
        else
            log_warning "No matching tasks found"
            echo "Create new task: /task-capture"
        fi
        exit 0
    fi

    # Sort by score (descending) and take top 5
    local top_matches=$(echo "$matches" | sort -t: -k1 -nr | head -5)
    local match_count=$(echo "$top_matches" | wc -l)
    local best_match=$(echo "$top_matches" | head -1)
    local best_score=$(echo "$best_match" | cut -d: -f1)
    local best_file=$(echo "$best_match" | cut -d: -f2)

    log_info "Found $match_count matching tasks"

    # Auto-select if high confidence (score > 100)
    if [[ $best_score -gt 100 ]]; then
        SELECTED_TASK="$best_file"
        TASK_ID=$(get_task_id "$(basename "$SELECTED_TASK")")
        TASK_TITLE=$(get_doc_title "$SELECTED_TASK")
        PREVIOUS_STATUS=$(get_status "$TASK_ID")

        log_success "High confidence match: $TASK_ID - $TASK_TITLE (score: $best_score)"

        if [[ "$OUTPUT_MODE" == "json" ]]; then
            cat <<EOF
{
  "status": "found",
  "section": "search",
  "task_id": "$TASK_ID",
  "task_title": "$TASK_TITLE",
  "task_status": "$PREVIOUS_STATUS",
  "task_file": "$SELECTED_TASK",
  "match_score": $best_score,
  "confidence": "high",
  "input_source": "$INPUT_SOURCE",
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
EOF
        fi
        return 0
    fi

    # Multiple matches - return for user selection
    if [[ "$OUTPUT_MODE" == "json" ]]; then
        echo "{"
        echo "  \"status\": \"matches_found\","
        echo "  \"section\": \"search\","
        echo "  \"input_source\": \"$INPUT_SOURCE\","
        echo "  \"match_count\": $match_count,"
        echo "  \"matches\": ["

        local idx=0
        while IFS= read -r match; do
            local score=$(echo "$match" | cut -d: -f1)
            local file=$(echo "$match" | cut -d: -f2)
            local seq=$(get_task_id "$(basename "$file")")
            local title=$(grep -m1 "^#\s" "$file" | sed 's/^#\s*\(Task\|Design\|Plan\|Incident\|Audit\|Summary\|Code Review\):\s*//' || echo "Untitled")
            local status=$(get_status "$seq")
            local doc_count=$(find_by_id "$seq" | wc -l)

            [[ $idx -gt 0 ]] && echo ","

            echo "    {"
            echo "      \"task_id\": \"$seq\","
            echo "      \"title\": \"$title\","
            echo "      \"status\": \"$status\","
            echo "      \"score\": $score,"
            echo "      \"document_count\": $doc_count,"
            echo "      \"best_match\": $([ $idx -eq 0 ] && echo "true" || echo "false")"
            echo -n "    }"

            idx=$((idx + 1))
        done <<< "$top_matches"

        echo ""
        echo "  ],"
        echo "  \"timestamp\": \"$(date -u +"%Y-%m-%dT%H:%M:%SZ")\""
        echo "}"
    else
        print_header "Matching Tasks Found"

        local idx=1
        while IFS= read -r match; do
            local score=$(echo "$match" | cut -d: -f1)
            local file=$(echo "$match" | cut -d: -f2)
            local seq=$(get_task_id "$(basename "$file")")
            local title=$(grep -m1 "^#\s" "$file" | sed 's/^#\s*\(Task\|Design\|Plan\|Incident\|Audit\|Summary\|Code Review\):\s*//' || echo "Untitled")
            local status=$(get_status "$seq")

            if [[ $idx -eq 1 ]]; then
                echo "${idx}. [BEST MATCH] Task ID ${seq} - ${title}"
            else
                echo "${idx}. Task ID ${seq} - ${title}"
            fi
            echo "   Status: ${status^}"
            echo "   Score: ${score}"
            echo ""

            idx=$((idx + 1))
        done <<< "$top_matches"
    fi
}

#------------------------------------------------------------------------------
# Section 2: Reopen Task
#------------------------------------------------------------------------------

# Precheck section: inspect the task and report whether external sync is needed
# WITHOUT modifying anything. Lets the LLM sync Asana BEFORE we move docs, so a
# failed Asana call doesn't leave local state (docs in active/) out of sync
# with external state (Asana still 'Completed').
section_precheck() {
    print_header "Precheck (Asana sync detection)"

    TASK_ID=$(normalize_task_id "$TASK_ID")
    SELECTED_TASK=$(find_primary "$TASK_ID")

    if [[ -z "$SELECTED_TASK" ]]; then
        output_json_error "precheck" "Task not found for task ID $TASK_ID"
    fi

    TASK_TITLE=$(get_doc_title "$SELECTED_TASK")
    PREVIOUS_STATUS=$(get_status "$TASK_ID")

    # Extract Asana GID from the task doc
    ASANA_GID=$(grep -m1 "^- Asana GID:" "$SELECTED_TASK" 2>/dev/null | sed 's/.*: *//' || echo "")

    # Only flag should_sync_asana if backend is configured AND the task has a GID
    if [[ -f "PROJECT.yaml" ]] && [[ "$(yaml_get '.task_management.backend' PROJECT.yaml)" == "asana" ]] && [[ -n "$ASANA_GID" ]]; then
        SHOULD_SYNC_ASANA=true
    fi

    if [[ "$OUTPUT_MODE" == "json" ]]; then
        cat <<EOF
{
  "status": "success",
  "section": "precheck",
  "task_id": "$TASK_ID",
  "task_title": "$TASK_TITLE",
  "previous_status": "$PREVIOUS_STATUS",
  "task_file": "$SELECTED_TASK",
  "asana_gid": "${ASANA_GID:-null}",
  "should_sync_asana": $SHOULD_SYNC_ASANA,
  "hint": "If should_sync_asana is true, flip Asana to 'In Progress' BEFORE running --reopen. Failed Asana sync after --reopen leaves docs in active/ while Asana still shows Completed.",
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
EOF
    else
        log_info "Task: $TASK_ID - $TASK_TITLE"
        log_info "Previous status: $PREVIOUS_STATUS"
        log_info "Asana GID: ${ASANA_GID:-<none>}"
        log_info "should_sync_asana: $SHOULD_SYNC_ASANA"
    fi
}

section_reopen() {
    print_header "Reopening Task"

    # Normalize and validate task ID
    TASK_ID=$(normalize_task_id "$TASK_ID")
    SELECTED_TASK=$(find_primary "$TASK_ID")

    if [[ -z "$SELECTED_TASK" ]]; then
        output_json_error "reopen" "Task not found for task ID $TASK_ID"
    fi

    TASK_TITLE=$(get_doc_title "$SELECTED_TASK")
    PREVIOUS_STATUS=$(get_status "$TASK_ID")
    TASK_SLUG=$(echo "$TASK_TITLE" | tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:]' '-' | sed 's/^-\|-$//' | cut -c1-40)

    log_info "Task: $TASK_ID - $TASK_TITLE"
    log_info "Previous status: $PREVIOUS_STATUS"

    # Determine range folder
    RANGE_FOLDER=$(basename "$(dirname "$SELECTED_TASK")")

    # Move documents if in completed/
    if [[ "$PREVIOUS_STATUS" == "completed" ]]; then
        log_info "Moving documents from completed/ to active/${RANGE_FOLDER}/"

        # Ensure target folder exists
        mkdir -p "$DOCS_DIR/active/$RANGE_FOLDER"

        # Move all documents for this task ID
        MOVED_COUNT=0
        while IFS= read -r doc; do
            [[ -z "$doc" ]] && continue

            local basename=$(basename "$doc")
            local target="$DOCS_DIR/active/$RANGE_FOLDER/$basename"

            # Use git mv if in git repo, otherwise regular mv
            if git rev-parse --git-dir >/dev/null 2>&1; then
                git mv "$doc" "$target" 2>/dev/null || mv "$doc" "$target"
            else
                mv "$doc" "$target"
            fi

            log_success "Moved: $basename"
            MOVED_COUNT=$((MOVED_COUNT + 1))
        done < <(find_by_id "$TASK_ID")

        # Update SELECTED_TASK path
        SELECTED_TASK="$DOCS_DIR/active/$RANGE_FOLDER/$(basename "$SELECTED_TASK")"
    fi

    # Extract Asana GID if present
    if [[ -f "$SELECTED_TASK" ]]; then
        ASANA_GID=$(grep -m1 "^- Asana GID:" "$SELECTED_TASK" | sed 's/.*: *//' || echo "")

        # Check if PROJECT.yaml has Asana configured
        if [[ -f "PROJECT.yaml" ]] && [[ "$(yaml_get '.task_management.backend' PROJECT.yaml)" == "asana" ]]; then
            SHOULD_SYNC_ASANA=true
        fi
    fi

    # Check for preserved branch (on-hold tasks)
    if [[ "$PREVIOUS_STATUS" == "on-hold" ]]; then
        PRESERVED_BRANCH=$(grep -m1 "^\*\*Preserved Branch\*\*:" "$SELECTED_TASK" | sed 's/.*: *//' || echo "")

        if [[ -n "$PRESERVED_BRANCH" ]]; then
            log_info "Preserved branch: $PRESERVED_BRANCH"
        fi
    fi

    if [[ "$OUTPUT_MODE" == "json" ]]; then
        cat <<EOF
{
  "status": "success",
  "section": "reopen",
  "task_id": "$TASK_ID",
  "task_title": "$TASK_TITLE",
  "task_slug": "$TASK_SLUG",
  "previous_status": "$PREVIOUS_STATUS",
  "task_file": "$SELECTED_TASK",
  "moved_count": $MOVED_COUNT,
  "range_folder": "$RANGE_FOLDER",
  "preserved_branch": "${PRESERVED_BRANCH:-null}",
  "asana_gid": "${ASANA_GID:-null}",
  "should_sync_asana": $SHOULD_SYNC_ASANA,
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
EOF
    else
        log_success "Task reopened: $TASK_ID"
        echo "  Moved: $MOVED_COUNT documents"
        echo "  Location: docs/active/${RANGE_FOLDER}/"
    fi
}

#------------------------------------------------------------------------------
# Section 3: Create Input Document
#------------------------------------------------------------------------------

section_document() {
    print_header "Creating Input Document"

    # Determine document type based on input source
    case "$INPUT_SOURCE" in
        email|sms|cliq)
            NEW_DOC_TYPE="UPD"
            ;;
        url)
            NEW_DOC_TYPE="FND"
            ;;
        direct|task_id)
            NEW_DOC_TYPE="UPD"
            ;;
        *)
            NEW_DOC_TYPE="UPD"
            ;;
    esac

    # Create description from input source
    local description="${INPUT_SOURCE}-input"

    log_info "Document type: $NEW_DOC_TYPE"
    log_info "Description: $description"

    # Get task info if not already loaded
    if [[ -z "$TASK_TITLE" ]]; then
        TASK_ID=$(normalize_task_id "$TASK_ID")
        SELECTED_TASK=$(find_primary "$TASK_ID")

        if [[ -z "$SELECTED_TASK" ]]; then
            output_json_error "document" "Task not found for task ID $TASK_ID"
        fi

        TASK_TITLE=$(get_doc_title "$SELECTED_TASK")
        RANGE_FOLDER=$(basename "$(dirname "$SELECTED_TASK")")
    fi

    if [[ "$OUTPUT_MODE" == "json" ]]; then
        # Return template structure for LLM to populate
        cat <<EOF
{
  "status": "needs_llm",
  "section": "document",
  "message": "Document template ready for LLM to populate and create",
  "task_id": "$TASK_ID",
  "doc_type": "$NEW_DOC_TYPE",
  "description": "$description",
  "input_source": "$INPUT_SOURCE",
  "input_text": $(echo "$INPUT_TEXT" | jq -Rs .),
  "task_file": "$SELECTED_TASK",
  "task_title": "$TASK_TITLE",
  "range_folder": "$RANGE_FOLDER",
  "instructions": "1. Call new-doc.sh to create document, 2. Populate with input content, 3. Link in task document",
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
EOF
    else
        log_info "Document template ready"
        echo "  Type: $NEW_DOC_TYPE"
        echo "  Description: $description"
        echo "  LLM will create and populate document"
    fi
}

#------------------------------------------------------------------------------
# Section 4: Setup Environment
#------------------------------------------------------------------------------

section_setup() {
    print_header "Setting Up Environment"

    # Get task info if not already loaded
    if [[ -z "$TASK_TITLE" ]]; then
        TASK_ID=$(normalize_task_id "$TASK_ID")
        SELECTED_TASK=$(find_primary "$TASK_ID")

        if [[ -z "$SELECTED_TASK" ]]; then
            output_json_error "setup" "Task not found for task ID $TASK_ID"
        fi

        TASK_TITLE=$(get_doc_title "$SELECTED_TASK")
        TASK_SLUG=$(echo "$TASK_TITLE" | tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:]' '-' | sed 's/^-\|-$//' | cut -c1-40)
        PREVIOUS_STATUS=$(get_status "$TASK_ID")

        # Extract Asana GID and preserved branch
        ASANA_GID=$(grep -m1 "^- Asana GID:" "$SELECTED_TASK" | sed 's/.*: *//' || echo "")
        PRESERVED_BRANCH=$(grep -m1 "^\*\*Preserved Branch\*\*:" "$SELECTED_TASK" | sed 's/.*: *//' || echo "")
    fi

    # Determine branch name
    local branch_name=""
    if [[ -n "$PRESERVED_BRANCH" ]] && git rev-parse --verify "$PRESERVED_BRANCH" >/dev/null 2>&1; then
        branch_name="$PRESERVED_BRANCH"
        BRANCH_RESTORED=true
        log_success "Branch restored: $branch_name"
    else
        branch_name="feature/${TASK_ID}-${TASK_SLUG}"

        # Check if branch exists
        if git rev-parse --verify "$branch_name" >/dev/null 2>&1; then
            log_info "Branch exists: $branch_name"
        else
            log_info "Branch will be created: $branch_name"
        fi
    fi

    # Worktree detection/recreation (DSN Decision 15)
    # Check if there's an existing worktree for this task, or recreate from branch
    if declare -f get_worktree_path &>/dev/null; then
        local wt_path
        wt_path=$(get_worktree_path "$TASK_ID" 2>/dev/null || echo "")
        if [[ -n "$wt_path" ]] && [[ -d "$wt_path" ]]; then
            # Worktree exists — cd into it
            cd "$wt_path" || log_warn "Failed to cd into worktree: $wt_path"
            log_success "Resumed worktree: $wt_path"
        elif [[ -n "$branch_name" ]] && git rev-parse --verify "$branch_name" >/dev/null 2>&1; then
            # Worktree missing but branch exists — recreate
            wt_path=$(create_task_worktree "$TASK_ID" "$branch_name" 2>/dev/null || echo "")
            if [[ -n "$wt_path" ]] && [[ -d "$wt_path" ]]; then
                cd "$wt_path" || log_warn "Failed to cd into recreated worktree: $wt_path"
                log_success "Recreated worktree from preserved branch: $wt_path"
            fi
        fi
    fi

    # Derive tracker backend from PROJECT.yaml
    local tracker_backend=""
    local tracker_id=""
    tracker_backend=$(yaml_get '.task_management.backend' PROJECT.yaml)
    # yaml_get normalizes null to empty

    if [[ "$tracker_backend" == "asana" ]] && [[ -n "$ASANA_GID" ]]; then
        tracker_id="$ASANA_GID"
    fi

    # Determine parent branch — default branch as fallback for resumed tasks
    local parent_branch
    parent_branch=$(get_default_branch 2>/dev/null || echo "main")

    # Write .current-task in JSON format
    write_current_task "$TASK_ID" "$branch_name" "$parent_branch" "${SELECTED_TASK}" "$tracker_backend" "$tracker_id"

    if [[ "$OUTPUT_MODE" == "json" ]]; then
        cat <<EOF
{
  "status": "success",
  "section": "setup",
  "task_id": "$TASK_ID",
  "branch_name": "$branch_name",
  "branch_restored": $BRANCH_RESTORED,
  "preserved_branch": "${PRESERVED_BRANCH:-null}",
  "asana_gid": "${ASANA_GID:-null}",
  "current_task_written": true,
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
EOF
    else
        log_success "Environment setup ready"
        echo "  Branch: $branch_name"
        echo "  Restored: $BRANCH_RESTORED"
    fi
}

#------------------------------------------------------------------------------
# Main Execution
#------------------------------------------------------------------------------

usage() {
    cat <<EOF
Usage: task-resume.sh [OPTIONS] [SECTION] [ARGUMENTS]

Resume a completed or on-hold task with new input.

Options:
  --json          JSON output (default for sections)
  --raw           Verbose colored output (for debugging)

Sections:
  --search <input_text>             Find matching tasks
  --reopen <task_id> <input_text>  Reopen task and move documents
  --document <task_id> <input>     Create input document template
  --setup <task_id>                Setup environment (branch, .current-task)
  --full <input_text>               Execute all sections (default)

Examples:
  task-resume.sh --search "Customer email about login issue"
  task-resume.sh --reopen DA9FB6 "Michelle's entity move error"
  task-resume.sh --document DA9FB6 "Error details..."
  task-resume.sh --setup DA9FB6
  task-resume.sh --full "New requirement from Cliq"

EOF
    exit 0
}

main() {
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json)
                OUTPUT_MODE="json"
                shift
                ;;
            --raw)
                OUTPUT_MODE="raw"
                shift
                ;;
            --search|--precheck|--reopen|--document|--setup|--full)
                SECTION="${1#--}"
                shift
                break
                ;;
            -h|--help)
                usage
                ;;
            *)
                # Default to full workflow with input
                SECTION="full"
                break
                ;;
        esac
    done

    # Default to full workflow
    [[ -z "$SECTION" ]] && SECTION="full"

    # Execute section
    case "$SECTION" in
        search)
            INPUT_TEXT="$*"
            [[ -z "$INPUT_TEXT" ]] && output_json_error "search" "No input text provided"
            section_search
            ;;

        precheck)
            TASK_ID="$1"
            [[ -z "$TASK_ID" ]] && output_json_error "precheck" "No task ID provided"
            section_precheck
            ;;

        reopen)
            TASK_ID="$1"
            shift
            INPUT_TEXT="$*"
            [[ -z "$TASK_ID" ]] && output_json_error "reopen" "No task ID provided"
            [[ -z "$INPUT_TEXT" ]] && output_json_error "reopen" "No input text provided"
            detect_input_source
            section_reopen
            ;;

        document)
            TASK_ID="$1"
            shift
            INPUT_TEXT="$*"
            [[ -z "$TASK_ID" ]] && output_json_error "document" "No task ID provided"
            [[ -z "$INPUT_TEXT" ]] && output_json_error "document" "No input text provided"
            detect_input_source
            section_document
            ;;

        setup)
            TASK_ID="$1"
            [[ -z "$TASK_ID" ]] && output_json_error "setup" "No task ID provided"
            section_setup
            ;;

        full)
            INPUT_TEXT="$*"
            [[ -z "$INPUT_TEXT" ]] && output_json_error "full" "No input text provided"

            # Execute all sections in sequence
            print_header "Task Resume - Full Workflow"

            # Section 1: Search
            section_search
            # Note: If matches found, command must handle selection and call --reopen
            # Full workflow assumes auto-select or direct task ID

            if [[ -z "$SELECTED_TASK" ]]; then
                output_json_error "full" "No task selected after search"
            fi

            # Section 2: Reopen
            section_reopen

            # Section 3: Document (returns needs_llm)
            section_document

            # Section 4: Setup
            section_setup

            # Return aggregated result for LLM
            if [[ "$OUTPUT_MODE" == "json" ]]; then
                cat <<EOF
{
  "status": "needs_llm",
  "section": "full",
  "message": "Task reopened, LLM must create document and sync Asana",
  "task_id": "$TASK_ID",
  "task_title": "$TASK_TITLE",
  "task_file": "$SELECTED_TASK",
  "previous_status": "$PREVIOUS_STATUS",
  "moved_count": $MOVED_COUNT,
  "doc_type": "$NEW_DOC_TYPE",
  "input_source": "$INPUT_SOURCE",
  "input_text": $(echo "$INPUT_TEXT" | jq -Rs .),
  "branch_name": "$branch_name",
  "branch_restored": $BRANCH_RESTORED,
  "asana_gid": "${ASANA_GID:-null}",
  "should_sync_asana": $SHOULD_SYNC_ASANA,
  "next_steps": [
    "Create $NEW_DOC_TYPE document with new-doc.sh",
    "Populate document with input content",
    "Update task document status to Reopened",
    "Sync Asana if configured",
    "Commit changes"
  ],
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
EOF
            fi
            ;;

        *)
            output_json_error "main" "Unknown section: $SECTION"
            ;;
    esac
}

main "$@"
