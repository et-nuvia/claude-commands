#!/usr/bin/env bash
set -euo pipefail

# STANDARD SCRIPT PATTERN: Section flags with --json/--raw output modes
#
# Usage:
#   ~/.claude/scripts/refactor.sh [--json|--raw] [--full|--section] [--scope <path>]
#
# Output Modes:
#   --json: Structured output for LLM, default (TOON when the caller is an AI agent, JSON otherwise)
#   --raw:  Verbose debugging output when LLM needs more details
#
# Section Flags (run specific section only):
#   --check-session:  Check for existing refactor session
#   --analyze:        Analyze codebase for refactoring opportunities
#   --plan:           Create refactoring plan
#   --validate:       Validate completeness and find loose ends
#   --full:           Run complete refactoring workflow (default)
#
# Workflow:
#   1. LLM calls: refactor.sh --json --full [scope]
#   2. Returns session status and next steps
#   3. LLM performs analysis and creates plan
#   4. Returns plan for user approval before execution

# Script directory (needed for sourcing library)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source shared library
source "${SCRIPT_DIR}/lib/output-framework.sh"

# Global variables
OUTPUT_MODE="json"  # json or raw
SECTION="full"      # full, check-session, analyze, plan, validate
SCOPE=""            # Optional: files, directories, or refactoring scope

# Refactor directory in current working directory
REFACTOR_DIR="refactor"
STATE_FILE="$REFACTOR_DIR/state.json"
PLAN_FILE="$REFACTOR_DIR/plan.md"

#------------------------------------------------------------------------------
# Helper Functions
#------------------------------------------------------------------------------

#------------------------------------------------------------------------------
# Section Functions
#------------------------------------------------------------------------------

# Section 1: Check for existing session
section_check_session() {
    log "${BLUE}Checking for existing refactor session${NC}"

    local session_exists="false"
    local session_id=""
    local progress=""
    local last_action=""
    local next_action=""

    if [[ -d "$REFACTOR_DIR" ]]; then
        session_exists="true"

        if [[ -f "$STATE_FILE" ]]; then
            session_id=$(jq -r '.session_id // "unknown"' "$STATE_FILE" 2>/dev/null || echo "unknown")
            progress=$(jq -r '.progress // "0/0"' "$STATE_FILE" 2>/dev/null || echo "0/0")
            last_action=$(jq -r '.last_action // "none"' "$STATE_FILE" 2>/dev/null || echo "none")
            next_action=$(jq -r '.next_action // "analyze"' "$STATE_FILE" 2>/dev/null || echo "analyze")
        fi
    fi

    if [[ "$SECTION" == "check-session" ]]; then
        local json=$(cat <<EOF
{
  "status": "success",
  "section": "check-session",
  "message": "Session check complete",
  "session_exists": $session_exists,
  "session_id": "$session_id",
  "progress": "$progress",
  "last_action": "$last_action",
  "next_action": "$next_action",
  "refactor_dir": "$REFACTOR_DIR",
  "state_file": "$STATE_FILE",
  "plan_file": "$PLAN_FILE",
  "timestamp": "$(date -Iseconds)"
}
EOF
)
        log_json "$json"
        exit 0
    fi

    log "${GREEN}✓${NC} Session check complete (exists: $session_exists)"
}

# Section 2: Analyze codebase
section_analyze() {
    log "${BLUE}Analyzing codebase for refactoring opportunities${NC}"

    # Create refactor directory if it doesn't exist
    if [[ ! -d "$REFACTOR_DIR" ]]; then
        log "Creating refactor directory: $REFACTOR_DIR"
        mkdir -p "$REFACTOR_DIR"
    fi

    # Initialize state if needed
    if [[ ! -f "$STATE_FILE" ]]; then
        log "Creating initial state file"
        local session_id="refactor_$(date +%Y_%m_%d_%H%M)"
        cat > "$STATE_FILE" <<EOF
{
  "session_id": "$session_id",
  "created": "$(date -Iseconds)",
  "progress": "0/0",
  "last_action": "initialized",
  "next_action": "analyze",
  "scope": "$SCOPE",
  "completed_tasks": [],
  "pending_tasks": []
}
EOF
    fi

    # Update state
    local temp_state=$(mktemp)
    jq '.last_action = "analyze" | .updated = "'$(date -Iseconds)'"' "$STATE_FILE" > "$temp_state"
    mv "$temp_state" "$STATE_FILE"

    if [[ "$SECTION" == "analyze" ]]; then
        local json=$(cat <<EOF
{
  "status": "ready_for_analysis",
  "section": "analyze",
  "message": "Ready for LLM analysis",
  "scope": "$SCOPE",
  "refactor_dir": "$REFACTOR_DIR",
  "next_steps": [
    "LLM should analyze codebase using Grep/Glob",
    "Identify code complexity hotspots",
    "Detect duplication across files",
    "Check architecture inconsistencies",
    "Assess test coverage",
    "Create plan: refactor.sh --json --plan"
  ],
  "timestamp": "$(date -Iseconds)"
}
EOF
)
        log_json "$json"
        exit 0
    fi

    log "${GREEN}✓${NC} Analysis phase ready"
}

# Section 3: Create refactoring plan
section_plan() {
    log "${BLUE}Creating refactoring plan${NC}"

    if [[ ! -d "$REFACTOR_DIR" ]]; then
        exit_with_json "error" "Refactor directory not found - run --analyze first"
    fi

    # Check if plan already exists
    if [[ -f "$PLAN_FILE" ]]; then
        log "Plan already exists at $PLAN_FILE"

        if [[ "$SECTION" == "plan" ]]; then
            local json=$(cat <<EOF
{
  "status": "plan_exists",
  "section": "plan",
  "message": "Refactoring plan already exists",
  "plan_file": "$PLAN_FILE",
  "next_steps": [
    "Review existing plan",
    "Update plan with new tasks if needed",
    "Execute refactoring incrementally",
    "Validate completeness: refactor.sh --json --validate"
  ],
  "timestamp": "$(date -Iseconds)"
}
EOF
)
            log_json "$json"
            exit 0
        fi
    else
        if [[ "$SECTION" == "plan" ]]; then
            local json=$(cat <<EOF
{
  "status": "ready_for_plan",
  "section": "plan",
  "message": "Ready for LLM to create plan",
  "plan_file": "$PLAN_FILE",
  "next_steps": [
    "LLM should create plan in $PLAN_FILE",
    "Include: Initial State Analysis",
    "Include: Refactoring Tasks (prioritized)",
    "Include: Validation Checklist",
    "Include: De-Para Mapping table",
    "After plan created, get user approval before executing"
  ],
  "timestamp": "$(date -Iseconds)"
}
EOF
)
            log_json "$json"
            exit 0
        fi
    fi

    log "${GREEN}✓${NC} Plan phase ready"
}

# Section 4: Validate completeness
section_validate() {
    log "${BLUE}Validating refactoring completeness${NC}"

    if [[ ! -d "$REFACTOR_DIR" ]]; then
        exit_with_json "error" "Refactor directory not found - no active session"
    fi

    if [[ ! -f "$PLAN_FILE" ]]; then
        exit_with_json "error" "Plan file not found - create plan first"
    fi

    if [[ "$SECTION" == "validate" ]]; then
        local json=$(cat <<EOF
{
  "status": "ready_for_validation",
  "section": "validate",
  "message": "Ready for deep validation analysis",
  "plan_file": "$PLAN_FILE",
  "state_file": "$STATE_FILE",
  "validation_tasks": [
    "Coverage Check - Find remaining old patterns",
    "Import Verification - Detect broken/orphaned imports",
    "Build & Test - Run full build and test suite",
    "Type Checking - Verify type safety if applicable",
    "Dead Code Detection - Identify removable legacy code",
    "De-Para Mapping - Generate comprehensive migration report"
  ],
  "next_steps": [
    "LLM performs deep code analysis",
    "Compare before/after for behavior preservation",
    "Fix any remaining issues automatically",
    "Generate final migration report",
    "Ensure 100% pattern consistency"
  ],
  "timestamp": "$(date -Iseconds)"
}
EOF
)
        log_json "$json"
        exit 0
    fi

    log "${GREEN}✓${NC} Validation phase ready"
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
            --check-session) SECTION="check-session"; shift ;;
            --analyze) SECTION="analyze"; shift ;;
            --plan) SECTION="plan"; shift ;;
            --validate) SECTION="validate"; shift ;;
            --full) SECTION="full"; shift ;;
            --scope) SCOPE="$2"; shift 2 ;;
            -h|--help)
                echo "Usage: $0 [--json|--raw] [--full|--check-session|--analyze|--plan|--validate] [--scope <path>]" >&2
                exit 0 ;;
            *) echo "Unknown option: $1" >&2; exit 2 ;;
        esac
    done

    # Execute sections based on flag
    case "$SECTION" in
        check-session)
            section_check_session
            ;;
        analyze)
            section_check_session  # Check session first
            section_analyze
            ;;
        plan)
            section_check_session
            section_analyze
            section_plan
            ;;
        validate)
            section_check_session
            section_validate
            ;;
        full)
            section_check_session
            local session_exists="false"
            if [[ -d "$REFACTOR_DIR" ]]; then
                session_exists="true"
            fi

            # Full workflow response
            local json=$(cat <<EOF
{
  "status": "ready",
  "message": "Refactoring engine initialized",
  "session_exists": $session_exists,
  "refactor_dir": "$REFACTOR_DIR",
  "scope": "$SCOPE",
  "workflow": {
    "session_check": "complete",
    "analysis": "ready",
    "planning": "ready",
    "execution": "pending",
    "validation": "pending"
  },
  "next_steps": [
    "$(if [[ "$session_exists" == "true" ]]; then echo "Resume existing session - review state.json and plan.md"; else echo "Start new session - analyze codebase"; fi)",
    "LLM performs codebase analysis",
    "LLM creates refactoring plan",
    "Get user approval before execution",
    "Execute refactorings incrementally with validation",
    "Final validation: refactor.sh --json --validate"
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
