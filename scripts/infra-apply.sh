#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# infra-apply.sh - Apply Terraform plan to provision/modify infrastructure
#
# Usage:
#   ~/.claude/scripts/infra-apply.sh [--json|--raw] [--plan-file <path>] [--auto-confirm]
#
# Flags:
#   --json         Return structured JSON output (default)
#   --raw          Return raw output with verbose details
#   --plan-file    Specify plan file path
#   --auto-confirm Skip safety confirmation
#
# next_action values:
#   display_summary    - Apply completed successfully
#   confirm_with_user  - Requires user confirmation before proceeding
#   fix_error          - Apply failed, needs investigation

# Custom status-to-action mapping (must be defined before sourcing output-framework)
map_status_to_action() {
    case "$1" in
        needs_input)    echo "confirm_with_user" ;;
        needs_confirm)  echo "confirm_with_user" ;;
        success)        echo "display_summary" ;;
        *)              echo "fix_error" ;;
    esac
}

source "${SCRIPT_DIR}/lib/output-framework.sh"

# Global variables
OUTPUT_FORMAT="json"
AUTO_CONFIRM=false
PLAN_FILE=""
PROJECT_ROOT=""
ADD_COUNT=0
CHANGE_COUNT=0
DESTROY_COUNT=0
APPLY_STATUS=0
TERRAFORM_OUTPUTS=""
APPLY_LOG=""

#------------------------------------------------------------------------------
# Helper Functions
#------------------------------------------------------------------------------

log_info() {
    if [[ "$OUTPUT_FORMAT" != "json" ]]; then
        echo -e "${BLUE}ℹ${NC} $*" >&2
    fi
}

log_success() {
    if [[ "$OUTPUT_FORMAT" != "json" ]]; then
        echo -e "${GREEN}✓${NC} $*" >&2
    fi
}

log_warning() {
    if [[ "$OUTPUT_FORMAT" != "json" ]]; then
        echo -e "${YELLOW}⚠${NC} $*" >&2
    fi
}

log_error() {
    if [[ "$OUTPUT_FORMAT" != "json" ]]; then
        echo -e "${RED}✗${NC} $*" >&2
    fi
}

#------------------------------------------------------------------------------
# Locate Plan File
#------------------------------------------------------------------------------

locate_plan_file() {
    PROJECT_ROOT=$(pwd)

    if [[ -z "$PLAN_FILE" ]]; then
        if [[ "$OUTPUT_FORMAT" == "json" ]]; then
            local recent_plans=""
            if [[ -d "infrastructure/terraform/plans" ]]; then
                recent_plans=$(ls -t infrastructure/terraform/plans/*.tfplan 2>/dev/null | head -5 | tr '\n' ',' | sed 's/,$//')
            fi
            exit_with_json "needs_input" "Plan file not specified" "" \
                "\"recent_plans\": \"$recent_plans\""
        else
            echo "Recent plans:" >&2
            ls -lht infrastructure/terraform/plans/*.tfplan 2>/dev/null | head -5 >&2 || echo "  No plans found" >&2
            echo "" >&2
            read -p "Plan file path: " PLAN_FILE >&2
        fi
    fi

    if [[ ! -f "$PLAN_FILE" ]]; then
        if [[ -f "infrastructure/terraform/$PLAN_FILE" ]]; then
            PLAN_FILE="infrastructure/terraform/$PLAN_FILE"
        elif [[ -f "infrastructure/terraform/plans/$PLAN_FILE" ]]; then
            PLAN_FILE="infrastructure/terraform/plans/$PLAN_FILE"
        else
            exit_with_json "error" "Plan file not found" "" \
                "\"plan_file\": \"$PLAN_FILE\""
        fi
    fi

    log_success "Plan file located: $PLAN_FILE"
}

#------------------------------------------------------------------------------
# Review Plan
#------------------------------------------------------------------------------

review_plan() {
    cd infrastructure/terraform || exit 1

    local plan_content
    plan_content=$(terraform show "$PLAN_FILE" 2>&1)

    ADD_COUNT=$(echo "$plan_content" | grep -c "will be created" 2>/dev/null || echo "0")
    CHANGE_COUNT=$(echo "$plan_content" | grep -c "will be updated" 2>/dev/null || echo "0")
    DESTROY_COUNT=$(echo "$plan_content" | grep -c "will be destroyed" 2>/dev/null || echo "0")

    if [[ $DESTROY_COUNT -gt 0 ]]; then
        log_warning "CAUTION: This plan will DESTROY $DESTROY_COUNT resource(s)"
    fi

    cd "$PROJECT_ROOT" || exit 1
}

#------------------------------------------------------------------------------
# Confirm Application
#------------------------------------------------------------------------------

confirm_application() {
    if [[ "$AUTO_CONFIRM" == "true" ]]; then
        log_warning "Auto-confirm enabled - skipping safety check"
        return
    fi

    if [[ "$OUTPUT_FORMAT" == "json" ]]; then
        exit_with_json "needs_confirm" "Infrastructure changes require confirmation" "" \
            "\"plan_file\": \"$PLAN_FILE\", \"add_count\": $ADD_COUNT, \"change_count\": $CHANGE_COUNT, \"destroy_count\": $DESTROY_COUNT"
    else
        echo "" >&2
        log_warning "WARNING: This will make REAL changes to infrastructure"
        echo "  + $ADD_COUNT to create, ~ $CHANGE_COUNT to update, - $DESTROY_COUNT to destroy" >&2
        echo "" >&2
        read -p "Type 'yes' to apply: " CONFIRM >&2
        if [[ "$CONFIRM" != "yes" ]]; then
            log_info "Apply aborted by user"
            exit 0
        fi
    fi
}

#------------------------------------------------------------------------------
# Apply Plan
#------------------------------------------------------------------------------

apply_plan() {
    cd infrastructure/terraform || exit 1

    if terraform apply "$PLAN_FILE"; then
        APPLY_STATUS=0
        log_success "Infrastructure changes applied successfully"
    else
        APPLY_STATUS=$?
        exit_with_json "error" "Terraform apply failed" "" \
            "\"plan_file\": \"$PLAN_FILE\", \"exit_code\": $APPLY_STATUS"
    fi

    TERRAFORM_OUTPUTS=$(terraform output 2>/dev/null || echo "")

    cd "$PROJECT_ROOT" || exit 1
}

#------------------------------------------------------------------------------
# Document Application
#------------------------------------------------------------------------------

document_application() {
    mkdir -p docs/infra-plans

    APPLY_LOG="docs/infra-plans/applied-$(date +%Y-%m-%d-%H%M%S).log"
    cd infrastructure/terraform || exit 1
    terraform show > "$PROJECT_ROOT/$APPLY_LOG"
    cd "$PROJECT_ROOT" || exit 1

    log_success "Apply log saved: $APPLY_LOG"
}

#------------------------------------------------------------------------------
# Main Execution
#------------------------------------------------------------------------------

main() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --json) OUTPUT_FORMAT="json"; shift ;;
            --raw) OUTPUT_FORMAT="raw"; shift ;;
            --plan-file) PLAN_FILE="$2"; shift 2 ;;
            --auto-confirm) AUTO_CONFIRM=true; shift ;;
            *)
                if [[ -z "$PLAN_FILE" ]]; then PLAN_FILE="$1"; fi
                shift
                ;;
        esac
    done

    locate_plan_file
    review_plan
    confirm_application
    apply_plan
    document_application

    if [[ "$OUTPUT_FORMAT" == "json" ]]; then
        exit_with_json "success" "Infrastructure changes applied successfully" "" \
            "\"plan_file\": \"$PLAN_FILE\", \"add_count\": $ADD_COUNT, \"change_count\": $CHANGE_COUNT, \"destroy_count\": $DESTROY_COUNT, \"apply_log\": \"$APPLY_LOG\""
    else
        echo "" >&2
        echo "Infrastructure Apply Complete" >&2
        echo "  + $ADD_COUNT created, ~ $CHANGE_COUNT updated, - $DESTROY_COUNT destroyed" >&2
        echo "  Apply log: $APPLY_LOG" >&2
    fi
}

main "$@"
