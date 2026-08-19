#!/usr/bin/env bash
set -euo pipefail

# STANDARD SCRIPT PATTERN: Section flags with --json/--raw output modes
#
# Usage:
#   ~/.claude/scripts/rca-triage.sh [--json|--raw] [--full|--section]
#
# Output Modes:
#   --json: Structured output for LLM, default (TOON when the caller is an AI agent, JSON otherwise)
#   --raw:  Verbose debugging output when LLM needs more details
#
# Section Flags (run specific section only):
#   --assess:    Gather incident details and determine severity
#   --respond:   Create incident tracking document
#   --full:      Run all sections end-to-end (default)
#
# Workflow:
#   1. LLM calls: rca-triage.sh --json --full
#   2. Returns JSON with incident details for LLM to create INC document
#   3. LLM creates V4 document using /task-capture pattern

# Global variables
OUTPUT_MODE="json"  # json or raw
SECTION="full"      # full, assess, respond

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Custom status-to-action mapping
map_status_to_action() {
    case "$1" in
        success)            echo "display_summary" ;;
        need_input)         echo "gather_user_input" ;;
        ready_for_document) echo "create_document" ;;
        *)                  echo "fix_error" ;;
    esac
}

source "${SCRIPT_DIR}/lib/output-framework.sh"

#------------------------------------------------------------------------------
# Section Functions
#------------------------------------------------------------------------------

# Section 1: Assess incident
section_assess() {
    log "${BLUE}Incident Assessment${NC}"
    log "══════════════════════════════════════"
    log ""

    # Gather incident details (in raw mode, prompt user; in json mode, LLM provides)
    if [[ "$OUTPUT_MODE" == "raw" ]]; then
        # Interactive mode for human use
        read -p "Brief description: " DESCRIPTION
        read -p "When detected (YYYY-MM-DD HH:MM): " DETECTED_TIME

        log ""
        log "Severity:"
        log "1. SEV1 - Critical (service down, data loss)"
        log "2. SEV2 - High (major feature broken)"
        log "3. SEV3 - Medium (minor feature broken)"
        log "4. SEV4 - Low (cosmetic issue)"
        read -p "Severity (1-4): " SEVERITY_CHOICE

        case "$SEVERITY_CHOICE" in
            1) SEVERITY="SEV1"; RESPONSE_TIME="15 minutes" ;;
            2) SEVERITY="SEV2"; RESPONSE_TIME="1 hour" ;;
            3) SEVERITY="SEV3"; RESPONSE_TIME="4 hours" ;;
            4) SEVERITY="SEV4"; RESPONSE_TIME="1 day" ;;
            *) SEVERITY="SEV3"; RESPONSE_TIME="4 hours" ;;
        esac

        read -p "Affected service/component: " AFFECTED_SERVICE
        read -p "Number of users impacted: " USER_IMPACT
        read -p "Error messages/symptoms: " SYMPTOMS

        log ""
        log "Immediate action options:"
        log "1. Rollback recent deployment"
        log "2. Scale up resources"
        log "3. Restart affected service"
        log "4. Investigate further"
        read -p "Action (1-4): " ACTION_CHOICE

        case "$ACTION_CHOICE" in
            1) ACTION="Rollback"; COMMAND="/rollback-deployment" ;;
            2) ACTION="Scale up"; COMMAND="kubectl scale" ;;
            3) ACTION="Restart"; COMMAND="systemctl restart" ;;
            4) ACTION="Investigate"; COMMAND="" ;;
            *) ACTION="Investigate"; COMMAND="" ;;
        esac
    else
        # JSON mode: Return structure for LLM to populate
        # LLM should ask user for these details
        local json=$(cat <<EOF
{
  "status": "need_input",
  "next_action": "gather_user_input",
  "section": "assess",
  "message": "Incident assessment requires input",
  "required_fields": {
    "description": "Brief description of the incident",
    "detected_time": "When detected (YYYY-MM-DD HH:MM format)",
    "severity": "SEV1|SEV2|SEV3|SEV4",
    "affected_service": "Service or component affected",
    "user_impact": "Number of users impacted",
    "symptoms": "Error messages or symptoms observed"
  },
  "severity_levels": {
    "SEV1": {"label": "Critical", "description": "Service down, data loss", "response_time": "15 minutes"},
    "SEV2": {"label": "High", "description": "Major feature broken", "response_time": "1 hour"},
    "SEV3": {"label": "Medium", "description": "Minor feature broken", "response_time": "4 hours"},
    "SEV4": {"label": "Low", "description": "Cosmetic issue", "response_time": "1 day"}
  },
  "action_options": [
    "Rollback recent deployment",
    "Scale up resources",
    "Restart affected service",
    "Investigate further"
  ],
  "next_steps": [
    "LLM should ask user for incident details",
    "Then call: rca-triage.sh --json --respond with details"
  ],
  "timestamp": "$(date -Iseconds)"
}
EOF
)
        log_json "$json"
        exit 0
    fi

    if [[ "$SECTION" == "assess" ]]; then
        # Return assessment results
        local json=$(cat <<EOF
{
  "status": "success",
  "next_action": "display_summary",
  "section": "assess",
  "message": "Incident assessed",
  "assessment": {
    "description": "$DESCRIPTION",
    "detected_time": "$DETECTED_TIME",
    "severity": "$SEVERITY",
    "response_time": "$RESPONSE_TIME",
    "affected_service": "$AFFECTED_SERVICE",
    "user_impact": "$USER_IMPACT",
    "symptoms": "$SYMPTOMS",
    "recommended_action": "$ACTION",
    "command": "$COMMAND"
  },
  "timestamp": "$(date -Iseconds)"
}
EOF
)
        log_json "$json"
        exit 0
    fi

    log "${GREEN}✓${NC} Assessment complete: $SEVERITY - $DESCRIPTION"
}

# Section 2: Create incident response document
section_respond() {
    log "${BLUE}Creating Incident Response Document${NC}"

    # Generate incident ID
    local INCIDENT_ID="INC-$(date +%Y%m%d-%H%M%S)"

    # Get next task ID from task-capture
    local TASK_ID
    if [[ -f ~/.claude/scripts/task-capture.sh ]]; then
        TASK_ID=$(~/.claude/scripts/task-capture.sh --next-sequence 2>/dev/null || echo "9999")
    else
        TASK_ID="9999"
    fi

    # Determine active directory
    local RANGE="20$(date +%y-%m)"

    local DOC_DIR="$HOME/.claude/docs/active/$RANGE"
    mkdir -p "$DOC_DIR"

    local DATETIME=$(date +%y%m%d%H%M)
    local DOC_NAME="${TASK_ID}-${DATETIME}-INC-${INCIDENT_ID}.md"
    local DOC_PATH="${DOC_DIR}/${DOC_NAME}"

    if [[ "$SECTION" == "respond" ]]; then
        # Return structure for LLM to create INC document
        local json=$(cat <<EOF
{
  "status": "ready_for_document",
  "next_action": "create_document",
  "section": "respond",
  "message": "Ready to create incident document",
  "incident": {
    "incident_id": "$INCIDENT_ID",
    "task_id": "$TASK_ID",
    "document_path": "$DOC_PATH",
    "document_name": "$DOC_NAME"
  },
  "template": {
    "title": "Incident: $INCIDENT_ID",
    "sections": {
      "metadata": {
        "status": "INVESTIGATING",
        "severity": "To be filled by LLM",
        "detected": "To be filled by LLM",
        "description": "To be filled by LLM"
      },
      "impact": {
        "service": "To be filled by LLM",
        "users_affected": "To be filled by LLM",
        "symptoms": "To be filled by LLM"
      },
      "timeline": ["Incident detected", "Incident created", "Initial action"],
      "actions_taken": "To be filled by LLM",
      "next_steps": ["Monitor service", "Update stakeholders", "Continue investigation"]
    }
  },
  "next_steps": [
    "LLM should ask user for incident details if not already gathered",
    "LLM creates INC document at specified path using template",
    "LLM formats document following V4 naming convention"
  ],
  "timestamp": "$(date -Iseconds)"
}
EOF
)
        log_json "$json"
        exit 0
    fi

    log "${GREEN}✓${NC} Ready to create: $DOC_PATH"
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
            --assess) SECTION="assess"; shift ;;
            --respond) SECTION="respond"; shift ;;
            --full) SECTION="full"; shift ;;
            *) shift ;;
        esac
    done

    # Execute sections based on flag
    case "$SECTION" in
        assess)
            section_assess
            ;;
        respond)
            section_respond
            ;;
        full)
            section_assess
            section_respond

            # Full success - return complete incident tracking info
            local json=$(cat <<EOF
{
  "status": "success",
  "next_action": "create_document",
  "message": "Incident triage complete - ready for document creation",
  "sections_completed": ["assess", "respond"],
  "next_steps": [
    "LLM should create INC document using returned template and path",
    "LLM should ask user for any missing incident details",
    "Follow V4 document naming convention"
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
