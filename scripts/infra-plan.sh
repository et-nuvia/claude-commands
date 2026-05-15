#!/usr/bin/env bash
set -euo pipefail

# STANDARD SCRIPT PATTERN: Terraform plan orchestration with section flags
#
# Usage:
#   ~/.claude/scripts/infra-plan.sh [--json|--raw] [--full|--section] [options]
#
# Output Modes:
#   --json: Structured JSON output for LLM (default)
#   --raw:  Verbose debugging output when LLM needs more details
#
# Section Flags (run specific section only):
#   --validate:      Validate infrastructure setup and prerequisites
#   --init:          Initialize Terraform workspace
#   --plan:          Execute terraform plan
#   --analyze:       Analyze plan output and assess risk
#   --document:      Create plan review document
#   --full:          Run all sections end-to-end (default)
#
# Optional Flags:
#   --env ENV:       Pre-select environment (dev/staging/prod)
#   --workspace WS:  Pre-select workspace name
#   --reinit:        Force Terraform re-initialization
#   --target RES:    Target specific resources (can be repeated)

# Global variables
OUTPUT_MODE="json"  # json or raw
SECTION="full"      # full, validate, init, plan, analyze, document

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/yaml.sh"
source "${SCRIPT_DIR}/lib/output-framework.sh"
ENVIRONMENT=""
WORKSPACE=""
REINIT=false
TARGETS=()

# Terraform state
INFRA_DIR=""
VAR_FILE=""
PLAN_FILE=""
ADD_COUNT=0
CHANGE_COUNT=0
DESTROY_COUNT=0
RISK_LEVEL=""

#------------------------------------------------------------------------------
# Section 1: Validate Infrastructure Setup
#------------------------------------------------------------------------------

section_validate() {
    log "${BLUE}Validating Infrastructure Setup${NC}"

    if [[ ! -L "infrastructure" ]]; then
        if [[ "$SECTION" == "validate" ]]; then
            log_json "{\"status\":\"error\",\"section\":\"validate\",\"message\":\"Infrastructure not linked\",\"next_action\":\"fix_error\",\"details\":\"Run /infra-verify to set up infrastructure symlink\",\"timestamp\":\"$(date -Iseconds)\"}"
            exit 1
        else
            exit_with_json "error" "Infrastructure not linked" "Run /infra-verify to set up infrastructure symlink"
        fi
    fi

    if [[ ! -d "infrastructure/terraform" ]]; then
        if [[ "$SECTION" == "validate" ]]; then
            log_json "{\"status\":\"error\",\"section\":\"validate\",\"message\":\"Terraform directory not found\",\"next_action\":\"fix_error\",\"details\":\"Expected: infrastructure/terraform\",\"timestamp\":\"$(date -Iseconds)\"}"
            exit 1
        else
            exit_with_json "error" "Terraform directory not found" "Expected: infrastructure/terraform"
        fi
    fi

    INFRA_DIR="$(pwd)/infrastructure/terraform"

    if [[ ! -f "PROJECT.yaml" ]]; then
        log "${YELLOW}⚠️  PROJECT.yaml not found - using defaults${NC}"
    fi

    if [[ -z "$ENVIRONMENT" ]]; then
        if [[ -f "PROJECT.yaml" ]]; then
            ENVIRONMENT=$(yaml_get '.infrastructure.environments | keys | .[0]')
        fi
        if [[ -z "$ENVIRONMENT" ]] || [[ "$ENVIRONMENT" == "null" ]]; then
            ENVIRONMENT="development"
        fi
    fi

    if [[ -z "$WORKSPACE" ]]; then
        if [[ -f "PROJECT.yaml" ]]; then
            WORKSPACE=$(yaml_get ".infrastructure.environments.${ENVIRONMENT}.terraform_workspace")
        fi
        if [[ -z "$WORKSPACE" ]] || [[ "$WORKSPACE" == "null" ]]; then
            WORKSPACE="$ENVIRONMENT"
        fi
    fi

    if [[ -f "PROJECT.yaml" ]]; then
        VAR_FILE=$(yaml_get ".infrastructure.tools[] | select(.name == \"terraform\") | .var_files.${ENVIRONMENT}")
    fi

    if [[ -z "$VAR_FILE" ]] || [[ "$VAR_FILE" == "null" ]]; then
        if [[ -f "$INFRA_DIR/${ENVIRONMENT}.tfvars" ]]; then
            VAR_FILE="${ENVIRONMENT}.tfvars"
        elif [[ -f "$INFRA_DIR/vars/${ENVIRONMENT}.tfvars" ]]; then
            VAR_FILE="vars/${ENVIRONMENT}.tfvars"
        else
            VAR_FILE=""
        fi
    fi

    if [[ "$SECTION" == "validate" ]]; then
        log_json "{\"status\":\"success\",\"section\":\"validate\",\"message\":\"Infrastructure validation complete\",\"next_action\":\"display_summary\",\"environment\":\"$ENVIRONMENT\",\"workspace\":\"$WORKSPACE\",\"var_file\":\"$VAR_FILE\",\"infra_dir\":\"$INFRA_DIR\",\"timestamp\":\"$(date -Iseconds)\"}"
        exit 0
    fi

    log "${GREEN}✓${NC} Validation complete"
}

#------------------------------------------------------------------------------
# Section 2: Initialize Terraform
#------------------------------------------------------------------------------

section_init() {
    log "${BLUE}Initializing Terraform${NC}"

    cd "$INFRA_DIR"

    local needs_init=false
    if [[ ! -d ".terraform" ]]; then
        needs_init=true
    elif [[ "$REINIT" == "true" ]]; then
        needs_init=true
    fi

    if [[ "$needs_init" == "true" ]]; then
        local init_output
        if ! init_output=$(terraform init ${REINIT:+-reconfigure} 2>&1); then
            cd - > /dev/null
            if [[ "$SECTION" == "init" ]]; then
                log_json "{\"status\":\"error\",\"section\":\"init\",\"message\":\"Terraform initialization failed\",\"next_action\":\"fix_error\",\"details\":$(echo "$init_output" | jq -Rs .),\"timestamp\":\"$(date -Iseconds)\"}"
                exit 1
            else
                exit_with_json "error" "Terraform initialization failed" "$init_output"
            fi
        fi
        log "${GREEN}✓${NC} Terraform initialized"
    else
        log "Terraform already initialized"
    fi

    local current_ws
    current_ws=$(terraform workspace show 2>/dev/null || echo "default")

    if [[ "$current_ws" != "$WORKSPACE" ]]; then
        if terraform workspace list 2>/dev/null | grep -q "\\b${WORKSPACE}\\b"; then
            terraform workspace select "$WORKSPACE" >/dev/null 2>&1
        else
            terraform workspace new "$WORKSPACE" >/dev/null 2>&1
        fi
    fi

    cd - > /dev/null

    if [[ "$SECTION" == "init" ]]; then
        log_json "{\"status\":\"success\",\"section\":\"init\",\"message\":\"Terraform initialization complete\",\"next_action\":\"display_summary\",\"workspace\":\"$WORKSPACE\",\"initialized\":$(if [[ "$needs_init" == "true" ]]; then echo "true"; else echo "false"; fi),\"timestamp\":\"$(date -Iseconds)\"}"
        exit 0
    fi

    log "${GREEN}✓${NC} Workspace ready: $WORKSPACE"
}

#------------------------------------------------------------------------------
# Section 3: Execute Terraform Plan
#------------------------------------------------------------------------------

section_plan() {
    log "${BLUE}Executing Terraform Plan${NC}"

    cd "$INFRA_DIR"

    local plan_cmd="terraform plan"

    if [[ -n "$VAR_FILE" ]] && [[ -f "$VAR_FILE" ]]; then
        plan_cmd="$plan_cmd -var-file=$VAR_FILE"
    fi

    for target in "${TARGETS[@]}"; do
        plan_cmd="$plan_cmd -target=$target"
    done

    mkdir -p plans

    if [[ ${#TARGETS[@]} -gt 0 ]]; then
        PLAN_FILE="plans/${WORKSPACE}-targeted-$(date +%Y%m%d-%H%M%S).tfplan"
    else
        PLAN_FILE="plans/${WORKSPACE}-$(date +%Y%m%d-%H%M%S).tfplan"
    fi

    plan_cmd="$plan_cmd -out=$PLAN_FILE"

    local plan_output
    local plan_exit=0
    if ! plan_output=$(eval "$plan_cmd" 2>&1); then
        plan_exit=$?
        cd - > /dev/null
        if [[ "$SECTION" == "plan" ]]; then
            log_json "{\"status\":\"error\",\"section\":\"plan\",\"message\":\"Terraform plan failed\",\"next_action\":\"fix_error\",\"exit_code\":$plan_exit,\"details\":$(echo "$plan_output" | jq -Rs .),\"timestamp\":\"$(date -Iseconds)\"}"
            exit 1
        else
            exit_with_json "error" "Terraform plan failed (exit $plan_exit)" "$plan_output"
        fi
    fi

    cd - > /dev/null

    PLAN_FILE="$INFRA_DIR/$PLAN_FILE"

    if [[ "$SECTION" == "plan" ]]; then
        log_json "{\"status\":\"success\",\"section\":\"plan\",\"message\":\"Terraform plan executed successfully\",\"next_action\":\"display_summary\",\"plan_file\":\"$PLAN_FILE\",\"timestamp\":\"$(date -Iseconds)\"}"
        exit 0
    fi

    log "${GREEN}✓${NC} Plan saved: $PLAN_FILE"
}

#------------------------------------------------------------------------------
# Section 4: Analyze Plan Output
#------------------------------------------------------------------------------

section_analyze() {
    log "${BLUE}Analyzing Plan Output${NC}"

    if [[ ! -f "$PLAN_FILE" ]]; then
        if [[ "$SECTION" == "analyze" ]]; then
            log_json "{\"status\":\"error\",\"section\":\"analyze\",\"message\":\"Plan file not found\",\"next_action\":\"fix_error\",\"details\":\"Run --plan section first to generate plan\",\"timestamp\":\"$(date -Iseconds)\"}"
            exit 1
        else
            exit_with_json "error" "Plan file not found" "Run --plan section first"
        fi
    fi

    cd "$INFRA_DIR"

    local plan_text="${PLAN_FILE}.txt"
    terraform show "$PLAN_FILE" > "$plan_text" 2>/dev/null

    ADD_COUNT=$(grep -c "will be created" "$plan_text" 2>/dev/null || echo "0")
    CHANGE_COUNT=$(grep -c "will be updated" "$plan_text" 2>/dev/null || echo "0")
    DESTROY_COUNT=$(grep -c "will be destroyed" "$plan_text" 2>/dev/null || echo "0")

    if [[ $DESTROY_COUNT -gt 0 ]]; then
        RISK_LEVEL="HIGH"
    elif [[ $CHANGE_COUNT -gt 5 ]] || [[ $ADD_COUNT -gt 5 ]]; then
        RISK_LEVEL="MEDIUM"
    else
        RISK_LEVEL="LOW"
    fi

    local resources_create=""
    local resources_destroy=""

    if [[ $ADD_COUNT -gt 0 ]]; then
        resources_create=$(grep "will be created" "$plan_text" | head -10 || echo "")
    fi

    if [[ $DESTROY_COUNT -gt 0 ]]; then
        resources_destroy=$(grep "will be destroyed" "$plan_text" || echo "")
    fi

    cd - > /dev/null

    if [[ "$SECTION" == "analyze" ]]; then
        log_json "{\"status\":\"success\",\"section\":\"analyze\",\"message\":\"Plan analysis complete\",\"next_action\":\"display_summary\",\"add_count\":$ADD_COUNT,\"change_count\":$CHANGE_COUNT,\"destroy_count\":$DESTROY_COUNT,\"risk_level\":\"$RISK_LEVEL\",\"timestamp\":\"$(date -Iseconds)\"}"
        exit 0
    fi

    log "${GREEN}✓${NC} Analysis complete"
}

#------------------------------------------------------------------------------
# Section 5: Create Plan Review Document
#------------------------------------------------------------------------------

section_document() {
    log "${BLUE}Creating Plan Review Document${NC}"

    mkdir -p docs/infra-plans

    local review_file="docs/infra-plans/$(date +%Y-%m-%d)-${WORKSPACE}-plan.md"
    local plan_text="${PLAN_FILE}.txt"

    local full_plan=""
    if [[ -f "$plan_text" ]]; then
        full_plan=$(cat "$plan_text")
    fi

    cat > "$review_file" << EOF
# Infrastructure Plan Review

**Date**: $(date -Iseconds)
**Environment**: $ENVIRONMENT
**Workspace**: $WORKSPACE
**Var File**: ${VAR_FILE:-none}

---

## Summary

- Resources to add: $ADD_COUNT
- Resources to change: $CHANGE_COUNT
- Resources to destroy: $DESTROY_COUNT

---

## Risk Assessment

**Risk Level**: $RISK_LEVEL

---

## Full Plan Output

\`\`\`
$full_plan
\`\`\`

---

## Next Steps

1. If approved: /infra-apply $PLAN_FILE
2. If rejected: Modify Terraform and re-run /infra-plan

**Plan file**: $PLAN_FILE
**Valid for**: 24 hours
EOF

    if [[ "$SECTION" == "document" ]]; then
        log_json "{\"status\":\"success\",\"section\":\"document\",\"message\":\"Plan review document created\",\"next_action\":\"display_summary\",\"review_file\":\"$review_file\",\"timestamp\":\"$(date -Iseconds)\"}"
        exit 0
    fi

    log "${GREEN}✓${NC} Review document: $review_file"
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
            --validate) SECTION="validate"; shift ;;
            --init) SECTION="init"; shift ;;
            --plan) SECTION="plan"; shift ;;
            --analyze) SECTION="analyze"; shift ;;
            --document) SECTION="document"; shift ;;
            --full) SECTION="full"; shift ;;
            --env) ENVIRONMENT="$2"; shift 2 ;;
            --workspace) WORKSPACE="$2"; shift 2 ;;
            --reinit) REINIT=true; shift ;;
            --target) TARGETS+=("$2"); shift 2 ;;
            *) shift ;;
        esac
    done

    case "$SECTION" in
        validate)
            section_validate
            ;;
        init)
            section_validate
            section_init
            ;;
        plan)
            section_validate
            section_init
            section_plan
            ;;
        analyze)
            section_analyze
            ;;
        document)
            section_document
            ;;
        full)
            section_validate
            section_init
            section_plan
            section_analyze
            section_document

            local review_file="docs/infra-plans/$(date +%Y-%m-%d)-${WORKSPACE}-plan.md"
            local targets_json
            targets_json=$(printf '%s\n' "${TARGETS[@]}" | jq -R . | jq -s . 2>/dev/null || echo "[]")

            log_json "{\"status\":\"success\",\"message\":\"Terraform plan complete\",\"next_action\":\"display_summary\",\"environment\":\"$ENVIRONMENT\",\"workspace\":\"$WORKSPACE\",\"var_file\":\"$VAR_FILE\",\"targets\":$targets_json,\"plan_file\":\"$PLAN_FILE\",\"add_count\":$ADD_COUNT,\"change_count\":$CHANGE_COUNT,\"destroy_count\":$DESTROY_COUNT,\"risk_level\":\"$RISK_LEVEL\",\"review_file\":\"$review_file\",\"timestamp\":\"$(date -Iseconds)\"}"
            exit 0
            ;;
    esac
}

main "$@"
