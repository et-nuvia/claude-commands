#!/usr/bin/env bash
set -euo pipefail

# plan-mitigate-risks.sh - Load and parse deployment risk documents for mitigation planning
#
# STANDARD SCRIPT PATTERN: Section flags with --json/--raw output modes
#
# Usage:
#   ~/.claude/scripts/plan-mitigate-risks.sh [--json|--raw] [--full|--section] [--file <path>]
#
# Output Modes:
#   --json: Structured JSON output for LLM (default)
#   --raw:  Verbose debugging output when LLM needs more details
#
# Section Flags:
#   --identify:  Find and load RSK document
#   --parse:     Parse risks by severity from document
#   --full:      Run all sections (default)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Custom status→action mappings (must be defined BEFORE sourcing)
map_status_to_action() {
    case "$1" in
        success)           echo "display_summary" ;;
        ready_for_opus)    echo "plan_mitigations" ;;
        needs_decision)    echo "select_risks" ;;
        *)                 _default_map_status_to_action "$1" ;;
    esac
}

# Source shared libraries
source "${SCRIPT_DIR}/lib/output-framework.sh"

# Global variables
OUTPUT_MODE="json"
SECTION="full"
RSK_FILE=""

#------------------------------------------------------------------------------
# Section: Identify RSK Document
#------------------------------------------------------------------------------

section_identify() {
    log "${BLUE}Identifying Risk Document${NC}"

    # If file provided, use it
    if [[ -n "$RSK_FILE" ]]; then
        if [[ ! -f "$RSK_FILE" ]]; then
            exit_with_json "error" "Risk document not found: $RSK_FILE"
        fi
        log "${GREEN}✓${NC} Using: $RSK_FILE"

        if [[ "$SECTION" == "identify" ]]; then
            exit_with_json "success" "Risk document found" "" \
                "\"rsk_file\": \"$RSK_FILE\""
        fi
        return 0
    fi

    # Search for recent RSK documents
    local risk_dir="docs/deployment-risks"
    local active_dir="docs/active"
    local rsk_files=""

    # Look in both locations
    if [[ -d "$risk_dir" ]]; then
        rsk_files=$(find "$risk_dir" -name "*.md" -type f 2>/dev/null | sort -r | head -10 || true)
    fi

    # Also check active docs for RSK type
    local active_rsk=""
    if [[ -d "$active_dir" ]]; then
        active_rsk=$(find "$active_dir" -name "*-RSK-*" -type f 2>/dev/null | sort -r | head -5 || true)
    fi

    if [[ -n "$active_rsk" ]]; then
        if [[ -n "$rsk_files" ]]; then
            rsk_files="${active_rsk}
${rsk_files}"
        else
            rsk_files="$active_rsk"
        fi
    fi

    if [[ -z "$rsk_files" ]]; then
        exit_with_json "error" "No risk documents found" \
            "Run /deploy-risk first to create a risk analysis, then re-run this command"
    fi

    # Build JSON array of available documents
    local docs_json="["
    local first=true
    while IFS= read -r doc; do
        [[ -z "$doc" ]] && continue
        local fname
        fname=$(basename "$doc")
        local fdate
        fdate=$(echo "$fname" | grep -oE '^[0-9]{4}-[0-9]{2}-[0-9]{2}' || echo "unknown")
        [[ "$first" == "true" ]] && first=false || docs_json+=","
        docs_json+="{\"path\":\"$doc\",\"filename\":\"$fname\",\"date\":\"$fdate\"}"
    done <<< "$rsk_files"
    docs_json+="]"

    # If only one, use it automatically
    local doc_count
    doc_count=$(echo "$rsk_files" | grep -c . || echo "0")
    if [[ $doc_count -eq 1 ]]; then
        RSK_FILE=$(echo "$rsk_files" | head -1)
        log "${GREEN}✓${NC} Using: $RSK_FILE"
        if [[ "$SECTION" == "identify" ]]; then
            exit_with_json "success" "Risk document found" "" \
                "\"rsk_file\": \"$RSK_FILE\"," \
                "\"available_docs\": $docs_json"
        fi
        return 0
    fi

    # Multiple docs — let LLM/user choose
    exit_with_json "needs_decision" "Multiple risk documents found — select one" "" \
        "\"available_docs\": $docs_json," \
        "\"instruction\": \"Present the list to the user and ask which to use, then re-run with --file <path>\""
}

#------------------------------------------------------------------------------
# Section: Parse Risks from Document
#------------------------------------------------------------------------------

section_parse() {
    log "${BLUE}Parsing Risk Document${NC}"

    if [[ -z "$RSK_FILE" || ! -f "$RSK_FILE" ]]; then
        exit_with_json "error" "No risk document loaded" "Run --identify first or provide --file"
    fi

    # Extract risk content
    local doc_content
    doc_content=$(cat "$RSK_FILE")

    # Count risks by parsing markdown headings and score patterns
    # Look for patterns like "Score: 8/10" or "Risk Score: 7" or severity indicators
    local critical_count=0 high_count=0 medium_count=0 low_count=0

    # Count by severity keywords in the document
    critical_count=$(echo "$doc_content" | grep -ciE 'critical|score:\s*(9|10)(/10)?' || echo "0")
    high_count=$(echo "$doc_content" | grep -ciE 'high.*risk|score:\s*(7|8)(/10)?' || echo "0")
    medium_count=$(echo "$doc_content" | grep -ciE 'medium.*risk|score:\s*(4|5|6)(/10)?' || echo "0")
    low_count=$(echo "$doc_content" | grep -ciE 'low.*risk|score:\s*(1|2|3)(/10)?' || echo "0")

    # Extract overall score if present
    local overall_score="unknown"
    local score_match
    score_match=$(echo "$doc_content" | grep -oEi 'overall.*score[:\s]*([0-9]+(\.[0-9]+)?)' | grep -oE '[0-9]+(\.[0-9]+)?' | head -1 || echo "")
    if [[ -n "$score_match" ]]; then
        overall_score="$score_match"
    fi

    # Get document date
    local doc_date
    doc_date=$(basename "$RSK_FILE" | grep -oE '^[0-9]{4}-[0-9]{2}-[0-9]{2}' || echo "unknown")

    log "${GREEN}✓${NC} Parsed: critical=$critical_count high=$high_count medium=$medium_count low=$low_count"

    SECTION="parse"
    exit_with_json "ready_for_opus" \
        "Risk document parsed — LLM must extract detailed risks and plan mitigations" "" \
        "\"rsk_file\": \"$RSK_FILE\"," \
        "\"doc_date\": \"$doc_date\"," \
        "\"overall_score\": \"$overall_score\"," \
        "\"severity_counts\": {\"critical\": $critical_count, \"high\": $high_count, \"medium\": $medium_count, \"low\": $low_count}," \
        "\"doc_content\": $(echo "$doc_content" | jq -Rs .)," \
        "\"next_steps\": [" \
        "  \"Extract each risk with: ID, title, category, severity, score, description, mitigation options\"," \
        "  \"Present risks grouped by severity to user\"," \
        "  \"Ask user which risks to mitigate (all critical+high recommended)\"," \
        "  \"For each selected risk, present mitigation options and let user choose\"," \
        "  \"Build implementation plan ordered by dependency and effort\"," \
        "  \"Create branch: git checkout -b mitigate/deployment-risks-$(date +%Y-%m-%d)\"," \
        "  \"Implement each mitigation atomically: one commit per risk (fix(risk-RID): description)\"," \
        "  \"Re-run /deploy-risk to verify score reduction\"" \
        "]"
}

#------------------------------------------------------------------------------
# Main Execution
#------------------------------------------------------------------------------

main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json) OUTPUT_MODE="json"; shift ;;
            --toon) OUTPUT_MODE="json"; OUTPUT_FORMAT="toon"; shift ;;
            --raw) OUTPUT_MODE="raw"; shift ;;
            --identify) SECTION="identify"; shift ;;
            --parse) SECTION="parse"; shift ;;
            --full) SECTION="full"; shift ;;
            --file) RSK_FILE="$2"; shift 2 ;;
            *) RSK_FILE="$1"; shift ;;
        esac
    done

    case "$SECTION" in
        identify)
            section_identify
            ;;
        parse)
            section_identify
            section_parse
            ;;
        full)
            section_identify
            section_parse
            ;;
    esac
}

main "$@"
