#!/usr/bin/env bash
set -euo pipefail

# feature-review.sh - Compare implementation against PROJECT-KNOWLEDGE.md
#
# STANDARD SCRIPT PATTERN: Section flags with --json/--raw output modes
#
# Usage:
#   ~/.claude/scripts/feature-review.sh [--json|--raw] [--full|--section] [--task-id <id>]
#
# Output Modes:
#   --json: Structured JSON output for LLM (default)
#   --raw:  Verbose debugging output when LLM needs more details
#
# Section Flags:
#   --identify:  Identify task and load context
#   --analyze:   Gather implementation context for comparison
#   --report:    Generate FRV report
#   --full:      Run all sections end-to-end (default)
#
# Workflow:
#   1. LLM calls: feature-review.sh --json --full
#   2. If PROJECT-KNOWLEDGE.md missing: Returns next_action=build_project_knowledge
#   3. If present: Gathers implementation context + knowledge for LLM comparison

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Custom status→action mappings (must be defined BEFORE sourcing)
map_status_to_action() {
    case "$1" in
        success)              echo "display_summary" ;;
        ready_for_opus)       echo "analyze_code" ;;
        needs_knowledge)      echo "build_project_knowledge" ;;
        ready_for_report)     echo "generate_report" ;;
        *)                    _default_map_status_to_action "$1" ;;
    esac
}

# Source shared libraries
source "${SCRIPT_DIR}/lib/output-framework.sh"
source "${SCRIPT_DIR}/lib/project-knowledge.sh"
source "${SCRIPT_DIR}/doc-utils.sh"

# Global variables
OUTPUT_MODE="json"
SECTION="full"
INPUT_ARG=""

# Task context
TASK_ID=""
TASK_DOC=""
TASK_TITLE=""
CURRENT_BRANCH=""
DEFAULT_BRANCH=""

#------------------------------------------------------------------------------
# Section 1: Identify Task
#------------------------------------------------------------------------------

section_identify() {
    log "${BLUE}Identifying Task${NC}"

    # Try explicit input
    if [[ -n "$INPUT_ARG" ]]; then
        if [[ "$INPUT_ARG" =~ ^[A-Fa-f0-9]{6}$ ]]; then
            TASK_ID=$(normalize_task_id "$INPUT_ARG")
        fi
    fi

    # Fall back to .current-task
    if [[ -z "$TASK_ID" ]] && load_current_task; then
        TASK_ID="$CT_TASK_ID"
        TASK_DOC="$CT_TASK_DOC"
        CURRENT_BRANCH="$CT_BRANCH"
    fi

    if [[ -z "$TASK_ID" ]]; then
        exit_with_json "error" "No task specified and no .current-task file" \
            "Provide task ID: feature-review.sh --task-id <ID>"
    fi

    # Find task document
    if [[ -z "$TASK_DOC" ]] || [[ ! -f "$TASK_DOC" ]]; then
        TASK_DOC=$(find_primary "$TASK_ID" 2>/dev/null || true)
    fi

    if [[ -n "$TASK_DOC" ]] && [[ -f "$TASK_DOC" ]]; then
        TASK_TITLE=$(get_doc_title "$TASK_DOC")
    fi

    CURRENT_BRANCH=${CURRENT_BRANCH:-$(git branch --show-current 2>/dev/null || echo "")}
    DEFAULT_BRANCH=$(get_default_branch 2>/dev/null || echo "main")

    log "${GREEN}✓${NC} Task: $TASK_ID - $TASK_TITLE"

    if [[ "$SECTION" == "identify" ]]; then
        exit_with_json "success" "Task identified: $TASK_TITLE" "" \
            "\"task_id\": \"$TASK_ID\"," \
            "\"task_doc\": \"$TASK_DOC\"," \
            "\"task_title\": \"$TASK_TITLE\"," \
            "\"branch\": \"$CURRENT_BRANCH\"," \
            "\"has_project_knowledge\": $(pk_exists && echo "true" || echo "false")"
    fi
}

#------------------------------------------------------------------------------
# Section 2: Analyze Implementation Context
#------------------------------------------------------------------------------

section_analyze() {
    log "${BLUE}Analyzing Implementation${NC}"

    # Check for PROJECT-KNOWLEDGE.md
    if ! pk_exists; then
        exit_with_json "needs_knowledge" \
            "PROJECT-KNOWLEDGE.md not found — cannot compare implementation against domain knowledge" \
            "Create docs/architecture/PROJECT-KNOWLEDGE.md to enable feature review. Use the template at ~/.claude/templates/PROJECT-KNOWLEDGE.md" \
            "\"task_id\": \"$TASK_ID\"," \
            "\"task_title\": \"$TASK_TITLE\"," \
            "\"template_path\": \"~/.claude/templates/PROJECT-KNOWLEDGE.md\"," \
            "\"target_path\": \"docs/architecture/PROJECT-KNOWLEDGE.md\""
    fi

    # Gather implementation context
    local changed_files=""
    changed_files=$(git diff --name-only "${DEFAULT_BRANCH}...${CURRENT_BRANCH}" 2>/dev/null || echo "")
    local file_count=0
    if [[ -n "$changed_files" ]]; then
        file_count=$(echo "$changed_files" | wc -l | tr -d ' ')
    fi

    # Get commit log
    local commits=""
    commits=$(git log --oneline "${DEFAULT_BRANCH}..${CURRENT_BRANCH}" 2>/dev/null || echo "")

    # Load project knowledge
    local pk_content=""
    pk_content=$(pk_load_full)

    # Load relevant PK sections
    local workflows=""
    workflows=$(pk_load_section "Core Workflows" 2>/dev/null || echo "")
    local business_rules=""
    business_rules=$(pk_load_section "Business Rules" 2>/dev/null || echo "")
    local service_map=""
    service_map=$(pk_load_section "Service Responsibility Map" 2>/dev/null || echo "")
    local integrations=""
    integrations=$(pk_load_section "Integration Flows" 2>/dev/null || echo "")

    # Find plan doc if available
    local plan_doc=""
    plan_doc=$(find_by_id "$TASK_ID" 2>/dev/null | grep -m1 "\-PLN\-" || true)

    log "${GREEN}✓${NC} Analysis context gathered"

    if [[ "$SECTION" == "analyze" ]]; then
        exit_with_json "ready_for_opus" "Implementation context gathered — needs Opus for comparison" "" \
            "\"task_id\": \"$TASK_ID\"," \
            "\"task_title\": \"$TASK_TITLE\"," \
            "\"task_doc\": \"$TASK_DOC\"," \
            "\"plan_doc\": \"$plan_doc\"," \
            "\"files_changed\": $file_count," \
            "\"changed_files\": $(echo "$changed_files" | jq -Rs 'split("\n") | map(select(length > 0))')," \
            "\"commits\": $(echo "$commits" | jq -Rs 'split("\n") | map(select(length > 0))')," \
            "\"project_knowledge\": {" \
            "  \"workflows\": $(echo "$workflows" | jq -Rs .)," \
            "  \"business_rules\": $(echo "$business_rules" | jq -Rs .)," \
            "  \"service_map\": $(echo "$service_map" | jq -Rs .)," \
            "  \"integrations\": $(echo "$integrations" | jq -Rs .)" \
            "}"
    fi
}

#------------------------------------------------------------------------------
# Section 3: Generate Report Context
#------------------------------------------------------------------------------

section_report() {
    log "${BLUE}Preparing Report Context${NC}"

    # Get FRV document filepath + template via new-doc.sh
    local frv_filepath=""
    local frv_template=""
    local frv_doc_json=""
    frv_doc_json=$("${SCRIPT_DIR}/new-doc.sh" --type FRV --description "feature-review" --id "$TASK_ID" --json 2>/dev/null || true)
    if [[ -n "$frv_doc_json" ]]; then
        frv_filepath=$(echo "$frv_doc_json" | jq -r '.filepath // empty')
        frv_template=$(echo "$frv_doc_json" | jq -r '.template // empty')
    fi

    exit_with_json "ready_for_report" "Ready for FRV document generation" "" \
        "\"task_id\": \"$TASK_ID\"," \
        "\"task_title\": \"$TASK_TITLE\"," \
        "\"frv_filepath\": $(printf '%s' "$frv_filepath" | jq -Rs .)," \
        "\"frv_template\": $(echo "$frv_template" | jq -Rs .)"
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
            --identify) SECTION="identify"; shift ;;
            --analyze) SECTION="analyze"; shift ;;
            --report) SECTION="report"; shift ;;
            --full) SECTION="full"; shift ;;
            --task-id) INPUT_ARG="$2"; shift 2 ;;
            *) INPUT_ARG="$1"; shift ;;
        esac
    done

    case "$SECTION" in
        identify)
            section_identify
            ;;
        analyze)
            section_identify
            section_analyze
            ;;
        report)
            section_identify
            section_analyze
            section_report
            ;;
        full)
            section_identify
            section_analyze
            section_report
            ;;
    esac
}

main "$@"
