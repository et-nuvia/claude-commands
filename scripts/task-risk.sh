#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# STANDARD SCRIPT PATTERN: Section flags with --json/--raw output modes
#
# Usage:
#   ~/.claude/scripts/task-risk.sh [--json|--raw] [--full|--section] [--env ENV]
#
# Output Modes:
#   --json: Structured output for LLM, default (TOON when the caller is an AI agent, JSON otherwise)
#   --raw:  Verbose debugging output when LLM needs more details
#
# Section Flags (run specific section only):
#   --validate:  Validate prerequisites and gather context
#   --analyze:   Perform comprehensive risk analysis (USE OPUS)
#   --document:  Create V4 RSK document
#   --full:      Run all sections end-to-end (default)
#
# Additional Flags:
#   --env ENV:   Target environment (staging|production)
#
# Workflow:
#   1. LLM calls: task-risk.sh --json --full --env production
#   2. Script validates, analyzes, and creates document
#   3. Returns JSON with risk score and document path
#   4. If error: LLM can retry with --raw for more debugging info

# Global variables
OUTPUT_MODE="json"  # json or raw
SECTION="full"      # full, validate, analyze, document
ENVIRONMENT=""      # staging or production
TASK_ID=""
VERSION=""
DEPLOYMENT_WINDOW=""
RISK_SCORE=""
RISK_ANALYSIS=""
DOC_PATH=""

# Source shared libraries
source "${SCRIPT_DIR}/lib/output-framework.sh"

#------------------------------------------------------------------------------
# Section Functions
#------------------------------------------------------------------------------

# Section 1: Validate
section_validate() {
    log "${BLUE}Validating Prerequisites${NC}"

    # Check if in git repo
    if ! git rev-parse --git-dir >/dev/null 2>&1; then
        exit_with_json "error" "Not in a git repository" "Current directory: $(pwd)"
    fi

    # Check for environment
    if [[ -z "$ENVIRONMENT" ]]; then
        exit_with_json "error" "Environment not specified" "Use --env staging or --env production"
    fi

    # Validate environment value
    if [[ "$ENVIRONMENT" != "staging" && "$ENVIRONMENT" != "production" ]]; then
        exit_with_json "error" "Invalid environment" "Must be 'staging' or 'production', got: $ENVIRONMENT"
    fi

    # Use explicit --task-id first, fall back to .current-task
    if [[ -n "$TASK_ID" ]]; then
        log "${GREEN}✓${NC} Found task by ID: $TASK_ID"
    elif load_current_task; then
        TASK_ID="$CT_TASK_ID"
        log "${GREEN}✓${NC} Found current task: $TASK_ID"
    fi

    # Get version from git tags or PROJECT.yaml
    if command -v ~/.claude/scripts/get-version.sh &>/dev/null; then
        VERSION=$(~/.claude/scripts/get-version.sh 2>/dev/null || echo "unknown")
    else
        VERSION=$(git rev-parse --short HEAD)
    fi

    # Get deployment window info
    local day_of_week=$(date +%A)
    local time_utc=$(date -u +%H:%M)
    local date_iso=$(date -Iseconds)
    DEPLOYMENT_WINDOW="${day_of_week}, ${date_iso} (${time_utc} UTC)"

    # If running only this section, return now
    if [[ "$SECTION" == "validate" ]]; then
        local json=$(cat <<EOF
{
  "status": "success",
  "section": "validate",
  "message": "Validation complete",
  "environment": "$ENVIRONMENT",
  "version": "$VERSION",
  "task_id": "$TASK_ID",
  "deployment_window": "$DEPLOYMENT_WINDOW",
  "timestamp": "$(date -Iseconds)"
}
EOF
)
        log_json "$json"
        exit 0
    fi

    log "${GREEN}✓${NC} Validation complete"
}

# Section 2: Analyze (LLM INTERVENTION - requires OPUS)
section_analyze() {
    log "${BLUE}Performing Risk Analysis${NC}"
    log "${YELLOW}⚠️  This section requires LLM (Opus) intervention${NC}"

    # This section MUST be performed by LLM with Opus model
    # The script returns a prompt for LLM to analyze

    # Gather data for LLM analysis
    local git_diff=""
    local git_log=""
    local comparison_base=""

    if [[ "$ENVIRONMENT" == "staging" ]]; then
        comparison_base="main"
    else
        comparison_base="prod"
    fi

    # Get changes since last deployment
    if git rev-parse "$comparison_base" >/dev/null 2>&1; then
        git_diff=$(git diff "${comparison_base}...HEAD" --stat 2>/dev/null || echo "Unable to get diff")
        git_log=$(git log "${comparison_base}...HEAD" --oneline 2>/dev/null || echo "Unable to get log")
    else
        git_diff="Comparison base '$comparison_base' not found"
        git_log="Comparison base '$comparison_base' not found"
    fi

    # Find previous risk analyses for trend
    local prev_analyses=""
    if [[ -d docs ]]; then
        prev_analyses=$(find docs -name "*-RSK-*.md" 2>/dev/null | sort -r | head -5 || echo "")
    fi

    # If running only this section, return data for LLM
    if [[ "$SECTION" == "analyze" ]]; then
        local json=$(cat <<EOF
{
  "status": "ready_for_analysis",
  "section": "analyze",
  "message": "LLM should analyze risks using Opus model",
  "environment": "$ENVIRONMENT",
  "version": "$VERSION",
  "deployment_window": "$DEPLOYMENT_WINDOW",
  "comparison_base": "$comparison_base",
  "git_diff": $(echo "$git_diff" | jq -Rs .),
  "git_log": $(echo "$git_log" | jq -Rs .),
  "previous_analyses": $(echo "$prev_analyses" | jq -Rs .),
  "next_steps": [
    "LLM MUST use model: opus for this analysis",
    "Analyze all 10 risk categories (0-10 scale each)",
    "Calculate weighted risk score using formula in command",
    "Store results in RISK_ANALYSIS variable",
    "Continue: task-risk.sh --json --document"
  ],
  "timestamp": "$(date -Iseconds)"
}
EOF
)
        log_json "$json"
        exit 0
    fi

    # In --full mode, we need LLM to perform analysis
    # Return the data and exit with intervention status
    local json=$(cat <<EOF
{
  "status": "intervention_required",
  "section": "analyze",
  "message": "LLM intervention required for risk analysis (Opus model)",
  "environment": "$ENVIRONMENT",
  "version": "$VERSION",
  "deployment_window": "$DEPLOYMENT_WINDOW",
  "comparison_base": "$comparison_base",
  "git_diff": $(echo "$git_diff" | jq -Rs .),
  "git_log": $(echo "$git_log" | jq -Rs .),
  "previous_analyses": $(echo "$prev_analyses" | jq -Rs .),
  "next_steps": [
    "LLM MUST use model: opus for comprehensive risk analysis",
    "Analyze all 10 risk categories (Code, DB, Dependencies, Config, Breaking, Rollback, Testing, Security, Performance, Data Integrity)",
    "Review historical context and previous RSK documents",
    "Calculate weighted risk score",
    "After analysis, call: task-risk.sh --json --document --env $ENVIRONMENT"
  ],
  "timestamp": "$(date -Iseconds)"
}
EOF
)
    log_json "$json"
    exit 1
}

# Section 3: Document
section_document() {
    log "${BLUE}Creating V4 RSK Document${NC}"

    # This section creates the RSK document
    # LLM should have already performed analysis and will write the document

    # Derive description from task title or branch name
    local raw_title=""
    if [[ -n "$TASK_ID" ]]; then
        # Try to find primary task doc and extract title
        source "${SCRIPT_DIR}/doc-utils.sh" 2>/dev/null || true
        if command -v find_primary &>/dev/null; then
            local primary_doc
            primary_doc=$(find_primary "$TASK_ID" 2>/dev/null || echo "")
            if [[ -n "$primary_doc" ]]; then
                raw_title=$(basename "$primary_doc" .md | sed -E 's/^[A-F0-9]{6}-[0-9]{10}-[A-Z]{3}-//')
            fi
        fi
    fi
    if [[ -z "$raw_title" ]]; then
        # Fall back to branch name
        raw_title=$(git rev-parse --abbrev-ref HEAD 2>/dev/null | sed 's|.*/||; s|^[0-9]*-||')
    fi
    local description
    description=$(echo "$raw_title" | tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:]' '-' | sed 's/^-//;s/-$//' | cut -c1-40)
    # Append environment suffix
    description="${description}-${ENVIRONMENT}"

    # Get filepath + template from new-doc.sh --json (no file written)
    local doc_json=""
    if [[ -n "$TASK_ID" ]]; then
        doc_json=$("${SCRIPT_DIR}/new-doc.sh" --type RSK --description "${description}" --id "${TASK_ID}" --status "active" --json 2>/dev/null) || true
    else
        doc_json=$("${SCRIPT_DIR}/new-doc.sh" --type RSK --description "${description}" --new --status "active" --json 2>/dev/null) || true
    fi

    DOC_PATH=$(echo "$doc_json" | jq -r '.filepath // empty')
    local doc_template
    doc_template=$(echo "$doc_json" | jq -r '.template // empty')

    # Extract task ID from new-doc output if we didn't have one
    if [[ -z "$TASK_ID" ]]; then
        TASK_ID=$(echo "$doc_json" | jq -r '.task_id // empty')
    fi

    # If running only this section, return document info
    if [[ "$SECTION" == "document" ]]; then
        local json=$(cat <<EOF
{
  "status": "ready_for_documentation",
  "section": "document",
  "message": "Write completed RSK document to filepath using Write tool",
  "next_action": "write_document",
  "task_id": "$TASK_ID",
  "document_path": "$DOC_PATH",
  "template": $(echo "$doc_template" | jq -Rs .),
  "environment": "$ENVIRONMENT",
  "version": "$VERSION",
  "deployment_window": "$DEPLOYMENT_WINDOW",
  "next_steps": [
    "Fill template with risk analysis (10 categories with scores and mitigations)",
    "Write completed document to document_path using Write tool",
    "Commit the document with conventional commit"
  ],
  "timestamp": "$(date -Iseconds)"
}
EOF
)
        log_json "$json"
        exit 0
    fi

    log "${GREEN}✓${NC} Document creation ready: $DOC_PATH"
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
            --validate) SECTION="validate"; shift ;;
            --analyze) SECTION="analyze"; shift ;;
            --document) SECTION="document"; shift ;;
            --full) SECTION="full"; shift ;;
            --env) ENVIRONMENT="$2"; shift 2 ;;
            --task-id) TASK_ID="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    # Execute sections based on flag
    case "$SECTION" in
        validate)
            section_validate
            ;;
        analyze)
            section_validate  # Prerequisites first
            section_analyze
            ;;
        document)
            section_validate  # Prerequisites first
            section_document
            ;;
        full)
            section_validate
            section_analyze
            # Note: section_analyze will exit with intervention_required
            # LLM will perform analysis and then call --document
            ;;
    esac
}

# Run main function
main "$@"
