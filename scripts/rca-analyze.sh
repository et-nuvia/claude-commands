#!/usr/bin/env bash
set -euo pipefail

# STANDARD SCRIPT PATTERN: Root Cause Analysis using 5 Whys methodology
#
# Usage:
#   ~/.claude/scripts/rca-analyze.sh [--json|--raw] [--full|--section] [--input flags]
#
# Output Modes:
#   --json: Structured output for LLM, default (TOON when the caller is an AI agent, JSON otherwise)
#   --raw:  Verbose debugging output when LLM needs more details
#
# Section Flags (run specific section only):
#   --gather:   Gather incident details (problem statement, context)
#   --analyze:  Perform 5 Whys analysis
#   --report:   Generate RCA report document
#   --full:     Run all sections end-to-end (default)
#
# Input Flags (pass data non-interactively):
#   --incident-id <id>     Incident identifier
#   --problem <text>       Problem statement
#   --why1 <text>          First why
#   --why2 <text>          Second why
#   --why3 <text>          Third why
#   --why4 <text>          Fourth why
#   --why5 <text>          Fifth why (root cause)
#   --factors <text>       Contributing factors (comma-separated: 1,2,3,4)
#
# Workflow:
#   1. LLM calls: rca-analyze.sh --json --gather
#   2. Script returns required fields for LLM to fill
#   3. LLM calls: rca-analyze.sh --json --analyze --incident-id ... --problem ... --why1 ... etc
#   4. Script returns analysis summary
#   5. LLM calls: rca-analyze.sh --json --report --incident-id ... --problem ... --why1 ... etc
#   6. Script generates RCA document and returns path
#
# Or all-in-one:
#   LLM calls: rca-analyze.sh --json --full --incident-id ... --problem ... --why1 ... etc

# Global variables
OUTPUT_MODE="json"  # json or raw
SECTION="full"      # full, gather, analyze, report

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/output-framework.sh"

# Data collected during analysis
INCIDENT_ID=""
PROBLEM=""
WHY1=""
WHY2=""
WHY3=""
WHY4=""
WHY5=""
FACTORS=""
ROOT_CAUSE=""
RCA_REPORT_PATH=""

#------------------------------------------------------------------------------
# Section Functions
#------------------------------------------------------------------------------

# Section 1: Gather incident details — returns required fields if not provided
section_gather() {
    log "${BLUE}Gathering Incident Details${NC}"
    log "══════════════════════════════════════"

    # If no input provided, return the required fields for LLM to fill
    if [[ -z "$INCIDENT_ID" || -z "$PROBLEM" ]]; then
        local json
        json=$(cat <<'ENDJSON'
{
  "status": "need_input",
  "next_action": "gather_user_input",
  "section": "gather",
  "message": "RCA requires incident details. Provide these via flags.",
  "required_fields": {
    "incident_id": "Incident ID or short identifier (e.g., INC-2833D5)",
    "problem": "Clear problem statement describing what happened"
  },
  "usage": "rca-analyze.sh --json --full --incident-id <id> --problem <text> --why1 <text> --why2 <text> --why3 <text> --why4 <text> --why5 <text> --factors <1,2,3,4>",
ENDJSON
)
        # Append timestamp and close
        json="${json}  \"timestamp\": \"$(date -Iseconds)\"
}"
        log_json "$json"
        exit 0
    fi

    log "Incident: $INCIDENT_ID"
    log "Problem: $PROBLEM"
    log "${GREEN}✓${NC} Incident details gathered"

    # If running only this section, return data now
    if [[ "$SECTION" == "gather" ]]; then
        local json
        json=$(cat <<ENDJSON
{
  "status": "success",
  "next_action": "display_summary",
  "section": "gather",
  "message": "Incident details gathered",
  "incident_id": $(echo "$INCIDENT_ID" | jq -Rs .),
  "problem": $(echo "$PROBLEM" | jq -Rs .),
  "next_steps": [
    "Continue with 5 Whys analysis: rca-analyze.sh --json --analyze --incident-id ... --problem ... --why1 ... --why5 ... --factors ..."
  ],
  "timestamp": "$(date -Iseconds)"
}
ENDJSON
)
        log_json "$json"
        exit 0
    fi
}

# Section 2: Perform 5 Whys analysis
section_analyze() {
    log "${BLUE}Performing 5 Whys Analysis${NC}"
    log "══════════════════════════════════════"

    # Check all required fields
    if [[ -z "$INCIDENT_ID" || -z "$PROBLEM" ]]; then
        local json
        json=$(cat <<'ENDJSON'
{
  "status": "need_input",
  "next_action": "gather_user_input",
  "section": "analyze",
  "message": "Analysis requires incident details and 5 Whys. Provide all via flags.",
  "required_fields": {
    "incident_id": "Incident ID",
    "problem": "Problem statement",
    "why1": "Why did this happen? (first level)",
    "why2": "Why? (second level)",
    "why3": "Why? (third level)",
    "why4": "Why? (fourth level)",
    "why5": "Why? (fifth level — root cause)",
    "factors": "Contributing factors: 1=Process, 2=Technology, 3=Human error, 4=External (comma-separated, e.g., 1,2)"
  },
  "usage": "rca-analyze.sh --json --analyze --incident-id <id> --problem <text> --why1 <text> --why2 <text> --why3 <text> --why4 <text> --why5 <text> --factors <1,2>",
ENDJSON
)
        json="${json}  \"timestamp\": \"$(date -Iseconds)\"
}"
        log_json "$json"
        exit 0
    fi

    # Validate 5 Whys are provided
    if [[ -z "$WHY1" || -z "$WHY2" || -z "$WHY3" || -z "$WHY4" || -z "$WHY5" ]]; then
        local json
        json=$(cat <<'ENDJSON'
{
  "status": "need_input",
  "next_action": "gather_user_input",
  "section": "analyze",
  "message": "All 5 Whys must be provided for analysis.",
  "missing_fields": "One or more of: --why1, --why2, --why3, --why4, --why5",
  "factor_options": {
    "1": "Process issues",
    "2": "Technology issues",
    "3": "Human error",
    "4": "External factors"
  },
ENDJSON
)
        json="${json}  \"timestamp\": \"$(date -Iseconds)\"
}"
        log_json "$json"
        exit 0
    fi

    ROOT_CAUSE="$WHY5"

    log "Problem: $PROBLEM"
    log "Why 1: $WHY1"
    log "Why 2: $WHY2"
    log "Why 3: $WHY3"
    log "Why 4: $WHY4"
    log "Why 5 (Root Cause): $WHY5"
    log "Factors: $FACTORS"
    log "${GREEN}✓${NC} 5 Whys analysis complete"

    # If running only this section, return analysis data
    if [[ "$SECTION" == "analyze" ]]; then
        local json
        json=$(cat <<ENDJSON
{
  "status": "success",
  "next_action": "display_summary",
  "section": "analyze",
  "message": "5 Whys analysis complete",
  "incident_id": $(echo "$INCIDENT_ID" | jq -Rs .),
  "problem": $(echo "$PROBLEM" | jq -Rs .),
  "why_1": $(echo "$WHY1" | jq -Rs .),
  "why_2": $(echo "$WHY2" | jq -Rs .),
  "why_3": $(echo "$WHY3" | jq -Rs .),
  "why_4": $(echo "$WHY4" | jq -Rs .),
  "why_5": $(echo "$WHY5" | jq -Rs .),
  "root_cause": $(echo "$ROOT_CAUSE" | jq -Rs .),
  "factors": $(echo "$FACTORS" | jq -Rs .),
  "next_steps": [
    "Generate RCA report: rca-analyze.sh --json --report (with same flags)"
  ],
  "timestamp": "$(date -Iseconds)"
}
ENDJSON
)
        log_json "$json"
        exit 0
    fi
}

# Section 3: Generate RCA report document
section_report() {
    log "${BLUE}Generating RCA Report${NC}"

    # If analysis data not available, cannot generate report
    if [[ -z "$INCIDENT_ID" || -z "$PROBLEM" || -z "$ROOT_CAUSE" ]]; then
        local json
        json=$(cat <<'ENDJSON'
{
  "status": "error",
  "next_action": "fix_error",
  "section": "report",
  "message": "Cannot generate report without analysis data. Run --full with all flags, or complete --gather and --analyze first.",
ENDJSON
)
        json="${json}  \"timestamp\": \"$(date -Iseconds)\"
}"
        log_json "$json"
        exit 1
    fi

    # Create report directory
    local report_dir="docs/rca"
    mkdir -p "$report_dir"

    # Generate report filename
    RCA_REPORT_PATH="${report_dir}/$(date +%Y-%m-%d)-${INCIDENT_ID}-rca.md"

    # Map factor numbers to descriptions
    local factor_list=""
    if [[ "$FACTORS" == *"1"* ]]; then
        factor_list+="- Process issues\n"
    fi
    if [[ "$FACTORS" == *"2"* ]]; then
        factor_list+="- Technology issues\n"
    fi
    if [[ "$FACTORS" == *"3"* ]]; then
        factor_list+="- Human error\n"
    fi
    if [[ "$FACTORS" == *"4"* ]]; then
        factor_list+="- External factors\n"
    fi

    # Generate report content
    cat > "$RCA_REPORT_PATH" << EOF
# Root Cause Analysis

**Incident**: $INCIDENT_ID
**Date**: $(date -Iseconds)

---

## Problem Statement

$PROBLEM

---

## 5 Whys Analysis

1. **Why did this happen?**
   $WHY1

2. **Why?**
   $WHY2

3. **Why?**
   $WHY3

4. **Why?**
   $WHY4

5. **Why?**
   $WHY5

---

## Root Cause

**$ROOT_CAUSE**

---

## Contributing Factors

$(echo -e "$factor_list")

---

## Corrective Actions

1. Immediate fix (completed):
   - [Description]

2. Short-term prevention (this week):
   - [ ] Action item 1
   - [ ] Action item 2

3. Long-term prevention (this month):
   - [ ] Process improvement
   - [ ] Monitoring enhancement
   - [ ] Training

---

## Prevention

To prevent recurrence:
- Add monitoring for [condition]
- Implement guardrails
- Update runbooks
- Team training on [topic]

EOF

    log "${GREEN}✓${NC} RCA report generated: $RCA_REPORT_PATH"

    # If running only this section, return report path
    if [[ "$SECTION" == "report" ]]; then
        local json
        json=$(cat <<ENDJSON
{
  "status": "success",
  "next_action": "display_summary",
  "section": "report",
  "message": "RCA report generated",
  "report_path": $(echo "$RCA_REPORT_PATH" | jq -Rs .),
  "timestamp": "$(date -Iseconds)"
}
ENDJSON
)
        log_json "$json"
        exit 0
    fi
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
            --gather) SECTION="gather"; shift ;;
            --analyze) SECTION="analyze"; shift ;;
            --report) SECTION="report"; shift ;;
            --full) SECTION="full"; shift ;;
            --incident-id) INCIDENT_ID="${2:-}"; shift 2 ;;
            --problem) PROBLEM="${2:-}"; shift 2 ;;
            --why1) WHY1="${2:-}"; shift 2 ;;
            --why2) WHY2="${2:-}"; shift 2 ;;
            --why3) WHY3="${2:-}"; shift 2 ;;
            --why4) WHY4="${2:-}"; shift 2 ;;
            --why5) WHY5="${2:-}"; ROOT_CAUSE="${2:-}"; shift 2 ;;
            --factors) FACTORS="${2:-}"; shift 2 ;;
            *) shift ;;
        esac
    done

    # Execute sections based on flag
    case "$SECTION" in
        gather)
            section_gather
            ;;
        analyze)
            section_analyze
            ;;
        report)
            section_report
            ;;
        full)
            section_gather
            section_analyze
            section_report

            # Full success - return complete results
            local json
            json=$(cat <<ENDJSON
{
  "status": "success",
  "next_action": "display_summary",
  "message": "Root cause analysis complete",
  "incident_id": $(echo "$INCIDENT_ID" | jq -Rs .),
  "problem": $(echo "$PROBLEM" | jq -Rs .),
  "root_cause": $(echo "$ROOT_CAUSE" | jq -Rs .),
  "report_path": $(echo "$RCA_REPORT_PATH" | jq -Rs .),
  "sections_completed": ["gather", "analyze", "report"],
  "next_steps": [
    "Review RCA with team",
    "Implement corrective actions",
    "Track prevention measures"
  ],
  "timestamp": "$(date -Iseconds)"
}
ENDJSON
)
            log_json "$json"
            exit 0
            ;;
    esac
}

# Run main function
main "$@"
