#!/usr/bin/env bash
set -euo pipefail

# STANDARD SCRIPT PATTERN: Section flags with --json/--raw output modes
#
# Usage:
#   ~/.claude/scripts/rca-pir.sh [--json|--raw] [--full|--gather|--generate]
#
# Output Modes:
#   --json: Structured output for LLM, default (TOON when the caller is an AI agent, JSON otherwise)
#   --raw:  Verbose debugging output when LLM needs more details
#
# Section Flags (run specific section only):
#   --gather:   Gather incident information from user
#   --generate: Generate PIR document from gathered data
#   --full:     Run all sections end-to-end (default)
#
# Workflow:
#   1. LLM calls: rca-pir.sh --json --full
#   2. If error: Returns JSON with error details
#   3. LLM can retry with --raw for more debugging info
#   4. Or LLM runs specific --section after fixing issue

# Global variables
OUTPUT_MODE="json"  # json or raw
SECTION="full"      # full, gather, generate

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/output-framework.sh"

# Data storage
INCIDENT_ID=""
START_TIME=""
END_TIME=""
DURATION=""
SUMMARY=""
ROOT_CAUSE=""
IMPACT=""
WENT_WELL=""
COULD_IMPROVE=""
SEVERITY=""

#------------------------------------------------------------------------------
# Section Functions
#------------------------------------------------------------------------------

# Section 1: Gather incident information
section_gather() {
    log "${BLUE}Gathering Incident Information${NC}"

    # Prompt for incident details
    read -p "Incident ID: " INCIDENT_ID
    read -p "Start time (e.g., 2026-02-14 10:30:00): " START_TIME
    read -p "Resolution time (e.g., 2026-02-14 11:15:00): " END_TIME
    read -p "Duration (minutes): " DURATION
    read -p "Severity (SEV1/SEV2/SEV3): " SEVERITY

    log ""
    read -p "Brief summary: " SUMMARY
    read -p "Root cause: " ROOT_CAUSE
    read -p "Impact (users/revenue): " IMPACT
    read -p "What went well: " WENT_WELL
    read -p "What could improve: " COULD_IMPROVE

    # Validate required fields
    if [[ -z "$INCIDENT_ID" || -z "$START_TIME" || -z "$END_TIME" || -z "$DURATION" ]]; then
        exit_with_json "error" "Required fields missing" "Incident ID, start time, end time, and duration are required"
    fi

    # If running only this section, return gathered data
    if [[ "$SECTION" == "gather" ]]; then
        local json=$(cat <<EOF
{
  "status": "success",
  "next_action": "display_summary",
  "section": "gather",
  "message": "Incident information gathered",
  "data": {
    "incident_id": "$INCIDENT_ID",
    "start_time": "$START_TIME",
    "end_time": "$END_TIME",
    "duration": "$DURATION",
    "severity": "$SEVERITY",
    "summary": "$SUMMARY",
    "root_cause": "$ROOT_CAUSE",
    "impact": "$IMPACT",
    "went_well": "$WENT_WELL",
    "could_improve": "$COULD_IMPROVE"
  },
  "next_steps": [
    "Continue to generate PIR: ~/.claude/scripts/rca-pir.sh --json --generate"
  ],
  "timestamp": "$(date -Iseconds)"
}
EOF
)
        log_json "$json"
        exit 0
    fi

    log "${GREEN}✓${NC} Information gathered"
}

# Section 2: Generate PIR document
section_generate() {
    log "${BLUE}Generating PIR Document${NC}"

    # Create PIR directory structure
    local pir_dir="docs/pir"
    mkdir -p "$pir_dir"

    # Generate filename
    local date_str=$(date +%Y-%m-%d)
    local pir_filename="${date_str}-${INCIDENT_ID}-pir.md"
    local pir_path="${pir_dir}/${pir_filename}"

    # Generate PIR document
    cat > "$pir_path" << EOF
# Post-Incident Review: $INCIDENT_ID

**Date**: $(date -Iseconds)
**Incident**: $INCIDENT_ID
**Severity**: ${SEVERITY:-[SEV1/SEV2/SEV3]}
**Duration**: $DURATION minutes

---

## Summary

${SUMMARY:-[Provide incident summary]}

---

## Timeline

- **$START_TIME** - Incident detected
- [Time] - Actions taken
- **$END_TIME** - Incident resolved

---

## Impact

${IMPACT:-[Describe impact on users/revenue]}

---

## Root Cause

${ROOT_CAUSE:-[Describe root cause]}

---

## What Went Well

${WENT_WELL:-[Describe what went well during incident response]}

---

## What Could Be Improved

${COULD_IMPROVE:-[Describe areas for improvement]}

---

## Action Items

- [ ] Update monitoring
- [ ] Improve alerting
- [ ] Update runbooks
- [ ] Team training

---

## Lessons Learned

1. [Key learning 1]
2. [Key learning 2]

EOF

    log "${GREEN}✓${NC} PIR document created: $pir_path"

    # If running only this section, return success
    if [[ "$SECTION" == "generate" ]]; then
        local json=$(cat <<EOF
{
  "status": "success",
  "next_action": "display_summary",
  "section": "generate",
  "message": "PIR document generated",
  "pir_path": "$pir_path",
  "pir_filename": "$pir_filename",
  "timestamp": "$(date -Iseconds)"
}
EOF
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
            --generate) SECTION="generate"; shift ;;
            --full) SECTION="full"; shift ;;
            *) shift ;;
        esac
    done

    # Execute sections based on flag
    case "$SECTION" in
        gather)
            section_gather
            ;;
        generate)
            # Generate requires data - if running standalone, error
            if [[ -z "$INCIDENT_ID" ]]; then
                exit_with_json "error" "No incident data provided" "Run --gather first or provide incident data via environment variables"
            fi
            section_generate
            ;;
        full)
            section_gather
            section_generate

            # Full success - return complete results
            local json=$(cat <<EOF
{
  "status": "success",
  "next_action": "display_summary",
  "message": "Post-Incident Review complete",
  "incident_id": "$INCIDENT_ID",
  "duration": "$DURATION",
  "pir_path": "docs/pir/$(date +%Y-%m-%d)-${INCIDENT_ID}-pir.md",
  "sections_completed": ["gather", "generate"],
  "next_steps": [
    "Review PIR with team",
    "Assign action items",
    "Track improvements"
  ],
  "timestamp": "$(date -Iseconds)"
}
EOF
)
            log_json "$json"
            exit 0
            ;;
    esac
}

# Run main function
main "$@"
