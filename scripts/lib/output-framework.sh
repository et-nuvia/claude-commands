#!/usr/bin/env bash
# Output Framework Library
# Shared output functions for all deterministic AI scripts
#
# Provides: log(), log_json(), exit_with_json(), color constants,
#           plus log_info/log_success/log_error/log_warn/log_debug via logging.sh
# Requires: OUTPUT_MODE and SECTION to be set by the sourcing script
#
# Usage: source "${SCRIPT_DIR}/lib/output-framework.sh"
#
# Scripts can customize next_action mapping by defining map_status_to_action()
# BEFORE sourcing this library, or by overriding it after sourcing.
#
# Valid status values:
#   success              - Operation completed successfully
#   error                - Operation failed
#   needs_decision       - User must choose between options
#   ready_for_opus       - Requires Opus model for analysis
#   requires_opus        - Alias for ready_for_opus
#   blocked              - Cannot proceed (external dependency)
#   ready_for_sync       - Ready for external tracker sync
#   conflict             - Merge/state conflict needs resolution
#   warning              - Completed with warnings
#   skipped              - Section skipped (precondition not met)
#   ready_for_cleanup    - Ready for cleanup phase
#   ready_for_docs       - Ready for document generation
#   needs_llm            - Requires LLM for content parsing
#   intervention_needed  - Manual intervention required
#   review_passed        - Quality review passed
#   review_failed        - Quality review failed
#   no_new_files         - No new files to process
#   drift_detected       - Configuration drift found
#
# Valid next_action values:
#   display_summary      - Show results to user
#   fix_error            - Diagnose and fix the problem
#   confirm_action       - Ask user to confirm before proceeding
#   resolve_conflicts    - Handle merge/state conflicts
#   parse_content        - Use LLM to parse/analyze content
#   sync_asana           - Execute Asana MCP operations
#   generate_docs        - Generate documentation
#   cleanup              - Run cleanup operations
#   use_opus_model       - Switch to Opus for next step
#   generate_plan        - Generate implementation plan
#   generate_document    - Generate output document
#   fix_plan             - Fix plan quality issues
#   continue             - Proceed to next phase
#   analyze_code         - Analyze code context
#   generate_report      - Generate analysis report
#   build_project_knowledge - Create PROJECT-KNOWLEDGE.md

# Guard against double-sourcing
[[ -n "${_OUTPUT_FRAMEWORK_LOADED:-}" ]] && return 0
_OUTPUT_FRAMEWORK_LOADED=1

# Source unified logging library
_OF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_OF_DIR}/logging.sh"

# =============================================================================
# Color Constants
# =============================================================================

# Only define if not already set (allows caller to override)
: "${RED:=\033[0;31m}"
: "${GREEN:=\033[0;32m}"
: "${YELLOW:=\033[1;33m}"
: "${BLUE:=\033[0;34m}"
: "${CYAN:=\033[0;36m}"
: "${MAGENTA:=\033[0;35m}"
: "${NC:=\033[0m}"

# =============================================================================
# Core Output Functions
# =============================================================================

# Log to stderr only in raw mode (suppressed in json mode)
# Usage: log "Processing file..."
#        log "${GREEN}Success${NC}"
log() {
    if [[ "${OUTPUT_MODE:-json}" == "raw" ]]; then
        echo -e "$@" >&2
    fi
}

# Output structured data to stdout.
# When OUTPUT_FORMAT=toon, converts JSON to TOON via json2toon.py.
# Otherwise outputs raw JSON.
# Usage: log_json "$json_string"
log_json() {
    if [[ "${OUTPUT_FORMAT:-json}" == "toon" ]]; then
        local _lib_dir
        _lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        echo "$1" | python3 "${_lib_dir}/json2toon.py" 2>/dev/null || echo "$1"
    else
        echo "$1"
    fi
}

# Detect output format from flags and environment.
# Priority: explicit --toon > explicit --json > CLAUDE_CODE env > default json
# Called automatically; scripts can also set OUTPUT_FORMAT directly.
_detect_output_format() {
    # Already set explicitly by script
    [[ -n "${OUTPUT_FORMAT:-}" ]] && return

    # Check common AI tool env vars
    if [[ "${CLAUDE_CODE:-}" == "1" ]] || [[ "${CURSOR:-}" == "1" ]] || [[ "${AI_CALLER:-}" == "1" ]]; then
        OUTPUT_FORMAT="toon"
    else
        OUTPUT_FORMAT="json"
    fi
}
_detect_output_format

# =============================================================================
# next_action Mapping
# =============================================================================

# Default status-to-action mapping. Scripts can override this function
# after sourcing to provide custom mappings.
#
# Usage (in calling script, AFTER sourcing):
#   map_status_to_action() {
#       case "$1" in
#           ready) echo "proceed_to_analysis" ;;
#           ready_for_llm) echo "llm_analyze" ;;
#           *) _default_map_status_to_action "$1" ;;
#       esac
#   }
_default_map_status_to_action() {
    case "$1" in
        success)              echo "display_summary" ;;
        intervention_needed)  echo "fix_error" ;;
        blocked)              echo "fix_error" ;;
        *)                    echo "fix_error" ;;
    esac
}

# If no custom mapping defined, use default
if ! declare -f map_status_to_action >/dev/null 2>&1; then
    map_status_to_action() {
        _default_map_status_to_action "$1"
    }
fi

# =============================================================================
# exit_with_json
# =============================================================================

# Exit with structured JSON response
#
# Usage:
#   exit_with_json "error" "Something went wrong"
#   exit_with_json "error" "Something went wrong" "detailed error info"
#   exit_with_json "success" "Done" "" '"count": 5, "items": []'
#   exit_with_json "success" "Done" "" '"key1": "v1",' '"key2": "v2"'
#
# Parameters:
#   $1 - status: success|error|intervention_needed|blocked|<custom>
#   $2 - message: human-readable message
#   $3 - details: (optional) additional details string, jq-escaped
#   $4+ - extra: (optional) raw JSON fields to append, variadic (joined with spaces)
#
# The function:
#   - Maps status to next_action via map_status_to_action()
#   - Includes section from $SECTION variable
#   - Adds ISO-8601 timestamp
#   - Exits 0 for success, 1 for everything else
exit_with_json() {
    local status="$1"
    local message="$2"
    local details="${3:-}"
    shift 3 2>/dev/null || shift $#
    local extra="$*"

    local next_action
    next_action=$(map_status_to_action "$status")

    local json_base
    json_base=$(cat <<EOF
{
  "status": "$status",
  "next_action": "$next_action",
  "message": "$message",
  "section": "${SECTION:-}",
  "details": $(echo "$details" | jq -Rs . 2>/dev/null || echo '""'),
  "timestamp": "$(date -Iseconds)"
EOF
)

    if [[ -n "$extra" ]]; then
        json_base="${json_base},
  ${extra}"
    fi

    json_base="${json_base}
}"

    log_json "$json_base"

    # Exit 0 for non-error statuses (LLM decides next action)
    # Exit 1 for true failures (error, blocked, conflict, intervention_needed, review_failed)
    case "$status" in
        success|needs_decision|ready|ready_for_*|requires_*|review_passed|skipped|no_new_files|warning|drift_detected|intervention_needed)
            exit 0
            ;;
        *)
            exit 1
            ;;
    esac
}
