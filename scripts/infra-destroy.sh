#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/yaml.sh"

# infra-destroy.sh - Safely destroy Terraform-managed infrastructure
#
# Usage:
#   ~/.claude/scripts/infra-destroy.sh [--json] [--env ENV] [--target RESOURCE] [--force-full]
#
# next_action values:
#   display_summary        - Destruction completed successfully
#   confirm_with_user      - Plan created, requires interactive user confirmation
#   fix_error              - Destruction failed or validation error
#   block_production       - Production blocked in JSON mode (requires interactive)

# Custom status-to-action mapping (must be defined before sourcing output-framework)
map_status_to_action() {
    case "$1" in
        blocked)                echo "confirm_with_user" ;;
        ready_for_confirmation) echo "confirm_with_user" ;;
        success)                echo "display_summary" ;;
        *)                      echo "fix_error" ;;
    esac
}

source "${SCRIPT_DIR}/lib/output-framework.sh"

# Global variables
ENV=""
WORKSPACE=""
VAR_FILE=""
TARGETS=()
FORCE_FULL=false
PROJECT_ROOT=""
OUTPUT_JSON=false
PLAN_FILE=""
PLAN_STATUS=0
DESTROY_STATUS=0
DESTROY_COUNT=0
RISK_LEVEL=""

#------------------------------------------------------------------------------
# Helper Functions
#------------------------------------------------------------------------------

log_info() {
    if [[ "$OUTPUT_JSON" != "true" ]]; then echo -e "${BLUE}ℹ${NC} $*" >&2; fi
}

log_success() {
    if [[ "$OUTPUT_JSON" != "true" ]]; then echo -e "${GREEN}✓${NC} $*" >&2; fi
}

log_warning() {
    if [[ "$OUTPUT_JSON" != "true" ]]; then echo -e "${YELLOW}⚠${NC} $*" >&2; fi
}

log_error() {
    if [[ "$OUTPUT_JSON" != "true" ]]; then echo -e "${RED}✗${NC} $*" >&2; fi
}

# Build common destroy fields for JSON output
_destroy_extra_fields() {
    local additional_fields="${1:-}"
    local targets_json
    targets_json=$(printf '%s\n' "${TARGETS[@]}" | jq -R . | jq -s . 2>/dev/null || echo "[]")

    local fields="\"environment\": \"${ENV}\", \"workspace\": \"${WORKSPACE}\", \"targeted\": $(if [[ ${#TARGETS[@]} -gt 0 ]]; then echo "true"; else echo "false"; fi), \"targets\": ${targets_json}, \"destroy_count\": ${DESTROY_COUNT}"
    if [[ -n "$additional_fields" ]]; then
        fields="${fields}, ${additional_fields}"
    fi
    echo "$fields"
}

#------------------------------------------------------------------------------
# Step 1: Verify Infrastructure
#------------------------------------------------------------------------------

verify_infrastructure() {
    PROJECT_ROOT=$(pwd)

    if [[ ! -L "infrastructure" ]]; then
        exit_with_json "error" "Infrastructure not linked" \
            "Run /infra-verify to set up infrastructure symlink" "$(_destroy_extra_fields)"
    fi

    if [[ ! -d "infrastructure/terraform" ]]; then
        exit_with_json "error" "Terraform directory not found" \
            "infrastructure/terraform does not exist" "$(_destroy_extra_fields)"
    fi

    log_success "Infrastructure verified"
}

#------------------------------------------------------------------------------
# Step 2: Determine Environment
#------------------------------------------------------------------------------

determine_environment() {
    if [[ -n "$ENV" ]]; then
        log_info "Using pre-selected environment: $ENV"
    else
        if [[ "$OUTPUT_JSON" == "true" ]]; then
            exit_with_json "error" "Environment required" \
                "Use --env flag to specify environment" "$(_destroy_extra_fields)"
        fi

        echo "⚠️  WARNING: This will DESTROY infrastructure" >&2
        echo "" >&2
        echo "Which environment?" >&2
        echo "1. development" >&2
        echo "2. staging" >&2
        echo "3. production (requires additional confirmation)" >&2
        echo "4. custom" >&2
        echo "" >&2
        read -p "Choice (1-4): " CHOICE >&2

        if [[ "$CHOICE" == "1" ]]; then ENV="development"
        elif [[ "$CHOICE" == "2" ]]; then ENV="staging"
        elif [[ "$CHOICE" == "3" ]]; then ENV="production"
        elif [[ "$CHOICE" == "4" ]]; then read -p "Enter environment name: " ENV >&2
        else log_error "Invalid choice. Aborted."; exit 0
        fi
    fi

    if [[ "$ENV" == "production" ]]; then
        if [[ "$OUTPUT_JSON" == "true" ]]; then
            exit_with_json "blocked" "Production destruction requires interactive confirmation" \
                "Use interactive mode - type DESTROY PRODUCTION when prompted" "$(_destroy_extra_fields)"
        fi

        echo "" >&2
        echo "🚨 DESTROYING PRODUCTION INFRASTRUCTURE 🚨" >&2
        echo "" >&2
        read -p "Type 'DESTROY PRODUCTION' to continue: " CONFIRM >&2

        if [[ "$CONFIRM" != "DESTROY PRODUCTION" ]]; then
            log_info "Aborted"
            exit 0
        fi
    fi

    log_info "Environment: $ENV"
}

#------------------------------------------------------------------------------
# Step 3: Get Workspace and Vars
#------------------------------------------------------------------------------

get_workspace_and_vars() {
    if [[ -f "PROJECT.yaml" ]]; then
        WORKSPACE=$(yaml_get ".infrastructure.environments.${ENV}.terraform_workspace")
    fi

    if [[ -z "$WORKSPACE" ]] || [[ "$WORKSPACE" == "null" ]]; then
        WORKSPACE="$ENV"
    fi

    if [[ -f "PROJECT.yaml" ]]; then
        VAR_FILE=$(yaml_get ".infrastructure.tools[] | select(.name == \"terraform\") | .var_files.${ENV}")
    fi

    if [[ -z "$VAR_FILE" ]] || [[ "$VAR_FILE" == "null" ]]; then
        if [[ -f "infrastructure/terraform/${ENV}.tfvars" ]]; then
            VAR_FILE="${ENV}.tfvars"
        elif [[ -f "infrastructure/terraform/vars/${ENV}.tfvars" ]]; then
            VAR_FILE="vars/${ENV}.tfvars"
        fi
    fi
}

#------------------------------------------------------------------------------
# Step 4: Setup Terraform
#------------------------------------------------------------------------------

setup_terraform() {
    cd infrastructure/terraform || exit 1

    if [[ ! -d ".terraform" ]]; then
        log_info "Initializing Terraform..."
        terraform init >/dev/null 2>&1
    fi

    CURRENT_WS=$(terraform workspace show)

    if [[ "$CURRENT_WS" != "$WORKSPACE" ]]; then
        terraform workspace select "$WORKSPACE" 2>/dev/null || {
            exit_with_json "error" "Workspace not found: $WORKSPACE" "" "$(_destroy_extra_fields)"
        }
    fi
}

#------------------------------------------------------------------------------
# Step 5: Choose Destruction Scope
#------------------------------------------------------------------------------

choose_destruction_scope() {
    if [[ ${#TARGETS[@]} -gt 0 ]]; then
        log_info "Using ${#TARGETS[@]} pre-specified target(s)"
        return
    fi

    if [[ "$OUTPUT_JSON" == "true" ]]; then
        if [[ "$FORCE_FULL" != "true" ]]; then
            exit_with_json "blocked" "Full environment destruction requires --force-full flag" \
                "Targeted destruction is STRONGLY RECOMMENDED. Use --target flags or --force-full" "$(_destroy_extra_fields)"
        fi
        return
    fi

    echo "" >&2
    echo "Destruction scope:" >&2
    echo "1. Target specific resources (RECOMMENDED)" >&2
    echo "2. Destroy ALL infrastructure in $ENV" >&2
    echo "" >&2
    read -p "Choice (1-2): " SCOPE_CHOICE >&2

    if [[ "$SCOPE_CHOICE" == "1" ]]; then
        echo "" >&2
        terraform state list | head -20 >&2
        echo "" >&2
        echo "Enter resources to destroy (empty line to finish):" >&2

        while true; do
            read -p "Resource: " RESOURCE >&2
            if [[ -z "$RESOURCE" ]]; then break; fi
            TARGETS+=("$RESOURCE")
        done

        if [[ ${#TARGETS[@]} -eq 0 ]]; then
            log_info "No resources specified. Aborted."
            exit 0
        fi
    fi
}

#------------------------------------------------------------------------------
# Step 6: Create and Analyze Destruction Plan
#------------------------------------------------------------------------------

create_destruction_plan() {
    # Build the command as an argv array (no eval) so resource names containing
    # shell metacharacters cannot be executed.
    local -a destroy_plan_cmd=(terraform plan -destroy)

    if [[ -n "$VAR_FILE" ]] && [[ -f "$VAR_FILE" ]]; then
        destroy_plan_cmd+=("-var-file=$VAR_FILE")
    fi

    for TARGET in "${TARGETS[@]}"; do
        destroy_plan_cmd+=("-target=$TARGET")
    done

    mkdir -p plans
    PLAN_FILE="plans/${WORKSPACE}-destroy-$(date +%Y%m%d-%H%M%S).tfplan"
    destroy_plan_cmd+=("-out=$PLAN_FILE")

    if ! "${destroy_plan_cmd[@]}" >/dev/null 2>&1; then
        PLAN_STATUS=$?
        exit_with_json "error" "Failed to create destruction plan" "" \
            "$(_destroy_extra_fields "\"exit_code\": ${PLAN_STATUS}")"
    fi

    terraform show "$PLAN_FILE" > "${PLAN_FILE}.txt"
    DESTROY_COUNT=$(grep -c "will be destroyed" "${PLAN_FILE}.txt" 2>/dev/null || echo "0")

    if [[ "$ENV" == "production" ]]; then RISK_LEVEL="CRITICAL"
    elif [[ $DESTROY_COUNT -gt 10 ]]; then RISK_LEVEL="HIGH"
    elif [[ ${#TARGETS[@]} -eq 0 ]]; then RISK_LEVEL="HIGH"
    else RISK_LEVEL="MEDIUM"
    fi

    log_info "Resources to destroy: $DESTROY_COUNT | Risk: $RISK_LEVEL"
}

#------------------------------------------------------------------------------
# Step 7: Save Review Doc and Get Confirmation
#------------------------------------------------------------------------------

save_and_confirm() {
    local review_file="docs/destroy-plans/$(date +%Y-%m-%d)-${WORKSPACE}-destroy.md"
    mkdir -p docs/destroy-plans

    cat > "$review_file" << EOF
# Infrastructure Destruction Plan

**Date**: $(date -Iseconds)
**Environment**: $ENV
**Workspace**: $WORKSPACE
**Risk Level**: $RISK_LEVEL
**Resources to Destroy**: $DESTROY_COUNT

## Full Destruction Plan

\`\`\`
$(cat "${PLAN_FILE}.txt")
\`\`\`
EOF

    if [[ "$OUTPUT_JSON" == "true" ]]; then
        exit_with_json "ready_for_confirmation" "Destruction plan created - requires interactive confirmation" "" \
            "$(_destroy_extra_fields "\"plan_file\": \"${PLAN_FILE}\", \"risk_level\": \"${RISK_LEVEL}\", \"review_file\": \"${review_file}\"")"
    fi

    echo "" >&2
    echo "Resources to destroy: $DESTROY_COUNT" >&2
    read -p "Type 'DESTROY' to proceed: " FINAL_CONFIRM >&2

    if [[ "$FINAL_CONFIRM" != "DESTROY" ]]; then
        log_info "Aborted"
        exit 0
    fi
}

#------------------------------------------------------------------------------
# Step 8: Execute Destruction
#------------------------------------------------------------------------------

execute_destruction() {
    log_warning "Destroying infrastructure..."

    if terraform apply "$PLAN_FILE"; then
        DESTROY_STATUS=0
        log_success "Infrastructure destroyed successfully"
    else
        DESTROY_STATUS=$?
        exit_with_json "error" "Destruction failed" \
            "Check Terraform state for partial destruction" \
            "$(_destroy_extra_fields "\"exit_code\": ${DESTROY_STATUS}")"
    fi

    cd "$PROJECT_ROOT" || exit 1
}

#------------------------------------------------------------------------------
# Step 9: Output Results
#------------------------------------------------------------------------------

output_results() {
    if [[ "$OUTPUT_JSON" == "true" ]]; then
        exit_with_json "success" "Infrastructure destroyed successfully" "" \
            "$(_destroy_extra_fields "\"plan_file\": \"${PLAN_FILE}\", \"risk_level\": \"${RISK_LEVEL}\", \"exit_code\": 0")"
    else
        echo "" >&2
        echo "Destruction Complete" >&2
        echo "  Environment: $ENV | Resources destroyed: $DESTROY_COUNT" >&2
    fi
}

#------------------------------------------------------------------------------
# Main Execution
#------------------------------------------------------------------------------

main() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --json) OUTPUT_JSON=true; shift ;;
            --env) ENV="$2"; shift 2 ;;
            --target) TARGETS+=("$2"); shift 2 ;;
            --force-full) FORCE_FULL=true; shift ;;
            *) shift ;;
        esac
    done

    verify_infrastructure
    determine_environment
    get_workspace_and_vars
    setup_terraform
    choose_destruction_scope
    create_destruction_plan
    save_and_confirm
    execute_destruction
    output_results

    exit 0
}

main "$@"
