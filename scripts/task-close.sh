#!/usr/bin/env bash
set -euo pipefail

# STANDARD SCRIPT PATTERN: Section flags with --json/--raw output modes
#
# task-close.sh - Complete or defer task with comprehensive closeout and cleanup
#
# Usage:
#   ~/.claude/scripts/task-close.sh [--json|--raw] [--full|--section] [--task-id <id>]
#
# Output Modes:
#   --json: Structured JSON output for LLM (default)
#   --raw:  Verbose debugging output when LLM needs more details
#
# Section Flags:
#   --identify:  Identify task and determine status
#   --complete:  Handle completed task (verify, capture, update, find PR)
#   --defer:     Handle deferred task
#   --sync:      Update external systems and log work hours (requires LLM/MCP)
#   --cleanup:   Move documents, clean up branches, Docker
#   --full:      Run all sections end-to-end (default)
#
# Workflow:
#   1. LLM calls: task-close.sh --json --full
#   2. Script prompts user for status and details
#   3. Returns JSON with status="ready_for_sync" and all data
#   4. LLM handles MCP operations (Asana, Invoice Ninja)
#   5. LLM calls: task-close.sh --json --cleanup
#   6. Script moves docs, cleans up, returns success

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Custom next_action mapping (must be defined before sourcing output-framework)
map_status_to_action() {
    case "$1" in
        success)        echo "display_summary" ;;
        ready_for_sync)    echo "sync_asana" ;;
        ready_for_docs)    echo "generate_docs" ;;
        ready_for_cleanup) echo "cleanup" ;;
        verified)          echo "generate_docs" ;;
        needs_llm)         echo "parse_content" ;;
        needs_decision)    echo "confirm_action" ;;
        conflict)          echo "resolve_conflicts" ;;
        *)              echo "fix_error" ;;
    esac
}

# Source shared libraries
source "${SCRIPT_DIR}/lib/output-framework.sh"
source "${SCRIPT_DIR}/lib/yaml.sh"
source "${SCRIPT_DIR}/doc-utils.sh"
source "${SCRIPT_DIR}/get-default-branch.sh"

# Source profile + task adapter so closeout mutations (close issue, comment,
# transition MR) route through the task_* contract instead of the raw GitLab
# curl path that lib/task-close-complete.sh used directly. Without this the
# Group A/B adapter refactor was effectively half-applied: capture/hold used
# the adapter, close did not.
# shellcheck source=lib/load-profile.sh
source "${SCRIPT_DIR}/lib/load-profile.sh"
# shellcheck source=lib/task-api.sh
source "${SCRIPT_DIR}/lib/task-api.sh"

# Source section helpers
source "${SCRIPT_DIR}/lib/task-close-identify.sh"
source "${SCRIPT_DIR}/lib/task-close-complete.sh"
source "${SCRIPT_DIR}/lib/task-close-defer.sh"
source "${SCRIPT_DIR}/lib/task-close-sync.sh"
source "${SCRIPT_DIR}/lib/task-close-cleanup.sh"

# Global variables
OUTPUT_MODE="json"  # json or raw
SECTION="full"      # full, identify, complete, defer, sync, cleanup, extract-summary-data, create-summary
INPUT_ARG=""        # task ID or path

# AI-provided summary content (for --create-summary)
AI_SUMMARY_TITLE=""
AI_SUMMARY_OVERVIEW=""
AI_SUMMARY_ACCOMPLISHMENTS=""
AI_SUMMARY_KEY_OUTCOMES=""
AI_SUMMARY_PATTERNS=""
AI_SUMMARY_TIMESTAMP=""

# Task context
TASK_ID=""
TASK_DOC=""
TASK_TITLE=""
TASK_SLUG=""
STATUS=""           # completed or deferred
CURRENT_BRANCH=""
DEFAULT_BRANCH=""
ASANA_GID=""
DOCS_DIR=""
RANGE_FOLDER=""

# Completion data
PROGRESS_SUMMARY=""
WENT_WELL=""
CHALLENGES=""
DO_DIFFERENTLY=""
REUSABLE_PATTERNS=""
CRITERIA_STATUS=""
START_DATE=""
PR_DATE=""
MERGE_DATE=""
TOTAL_TIME=""
USER_HOURS=""
MOST_RECENT_DATE=""

# Deferral data
DEFERRAL_REASON=""
BLOCKER_DETAILS=""
EXPECTED_UNBLOCK_DATE=""
UNBLOCK_CONTACT=""
WORK_DONE=""
NEXT_STEPS=""

# External integrations
PR_NUMBER=""
PR_URL=""
PR_STATE=""
MR_NUMBER=""
ISSUE_NUMBER=""
ISSUE_ID=""
JIRA_KEY=""
GIT_PLATFORM=""
EXTERNAL_UPDATED=false

# Environment detection
IS_HOME=false
IS_TXTWIRE=false
SHOULD_SYNC_ASANA=false
WORK_HOURS_LOGGED=false

# AI mode - skip all interactive prompts
AI_MODE=false
AI_STATUS=""           # completed or deferred
AI_ACCOMPLISHED=""     # what was accomplished
AI_WENT_WELL=""       # what went well
AI_CHALLENGES=""      # challenges faced
AI_DIFFERENTLY=""     # what would be done differently
AI_PATTERNS=""        # reusable patterns
AI_DEFERRAL_REASON="" # reason for deferral
AI_BLOCKER=""         # blocker details
AI_EXPECTED_DATE=""   # expected unblock date
AI_CONTACT=""         # who can unblock

# Summary and cleanup
SUMMARY_FILENAME=""
DOC_COUNT=0
STOP_DOCKER=false
DELETE_BRANCH=false
MERGE_BRANCH=true     # default: squash merge on complete
MERGE_TARGET=""       # auto-detected parent branch

# Related documents
INCIDENT_DOCS="None"
SUMMARY_DOCS="None"
REFERENCE_DOCS="None"
CODE_CHANGES="None"

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
            --identify) SECTION="identify"; shift ;;
            --complete) SECTION="complete"; shift ;;
            --defer) SECTION="defer"; shift ;;
            --pre-verify) SECTION="pre-verify"; shift ;;
            --cleanup) SECTION="cleanup"; shift ;;
            --extract-summary-data) SECTION="extract-summary-data"; shift ;;
            --create-summary) SECTION="create-summary"; shift ;;
            --full) SECTION="full"; shift ;;
            --ai) AI_MODE=true; shift ;;
            --status) AI_STATUS="$2"; shift 2 ;;
            --accomplished) AI_ACCOMPLISHED="$2"; shift 2 ;;
            --went-well) AI_WENT_WELL="$2"; shift 2 ;;
            --challenges) AI_CHALLENGES="$2"; shift 2 ;;
            --differently) AI_DIFFERENTLY="$2"; shift 2 ;;
            --patterns) AI_PATTERNS="$2"; shift 2 ;;
            --deferral-reason) AI_DEFERRAL_REASON="$2"; shift 2 ;;
            --blocker) AI_BLOCKER="$2"; shift 2 ;;
            --expected-date) AI_EXPECTED_DATE="$2"; shift 2 ;;
            --contact) AI_CONTACT="$2"; shift 2 ;;
            --no-merge) MERGE_BRANCH=false; shift ;;
            --target-branch) MERGE_TARGET="$2"; shift 2 ;;
            --title) AI_SUMMARY_TITLE="$2"; shift 2 ;;
            --overview) AI_SUMMARY_OVERVIEW="$2"; shift 2 ;;
            --accomplishments) AI_SUMMARY_ACCOMPLISHMENTS="$2"; shift 2 ;;
            --key-outcomes) AI_SUMMARY_KEY_OUTCOMES="$2"; shift 2 ;;
            --summary-patterns) AI_SUMMARY_PATTERNS="$2"; shift 2 ;;
            --summary-title) AI_SUMMARY_TITLE="$2"; shift 2 ;;
            --summary-overview) AI_SUMMARY_OVERVIEW="$2"; shift 2 ;;
            --summary-accomplishments) AI_SUMMARY_ACCOMPLISHMENTS="$2"; shift 2 ;;
            --summary-key-outcomes) AI_SUMMARY_KEY_OUTCOMES="$2"; shift 2 ;;
            --summary-patterns) AI_SUMMARY_PATTERNS="$2"; shift 2 ;;
            --summary-timestamp) AI_SUMMARY_TIMESTAMP="$2"; shift 2 ;;
            --task-id) INPUT_ARG="$2"; shift 2 ;;
            *) echo "Unknown option: $1" >&2; exit 2 ;;
        esac
    done

    # Execute sections based on flag
    case "$SECTION" in
        identify)
            section_identify
            ;;
        complete)
            # Need to identify first
            section_identify
            if [[ "$STATUS" != "completed" ]]; then
                exit_with_json "error" "Task is not marked as completed" "Use --defer for deferred tasks"
            fi
            section_complete
            ;;
        defer)
            # Need to identify first
            section_identify
            if [[ "$STATUS" != "deferred" ]]; then
                exit_with_json "error" "Task is not marked as deferred" "Use --complete for completed tasks"
            fi
            section_defer
            ;;
        extract-summary-data)
            # Extract all data for AI synthesis
            section_identify
            section_extract_summary_data
            ;;
        create-summary)
            # Create summary from AI-provided content
            section_identify
            section_create_summary
            ;;
        pre-verify)
            # Run pre-merge verification BEFORE doc generation so failures abort
            # the flow before any SUM/LRN files are written or committed.
            # Identifies task first to set TASK_ID / MERGE_TARGET context.
            section_identify
            # A pre-verify is only meaningful once we know the task is "completed"
            # and will be merged. Force that assumption if caller hasn't set it.
            if [[ "$STATUS" != "completed" ]] && [[ "$AI_STATUS" == "completed" ]]; then
                STATUS="completed"
            fi
            section_pre_verify
            ;;
        cleanup)
            # Always identify task first to set necessary variables
            section_identify
            section_cleanup
            ;;
        full)
            section_identify

            if [[ "$STATUS" == "completed" ]]; then
                section_complete
                # Return for LLM to handle MCP operations
                # LLM will call --cleanup after syncing
                exit 0
            else
                section_defer
                # Return for LLM to handle MCP operations
                # LLM will call --cleanup after syncing
                exit 0
            fi
            ;;
    esac
}

# Run main function
main "$@"
