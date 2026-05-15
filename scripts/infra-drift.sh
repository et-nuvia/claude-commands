#!/usr/bin/env bash
set -euo pipefail

# STANDARD SCRIPT PATTERN: Terraform drift detection
#
# Usage:
#   ~/.claude/scripts/infra-drift.sh [--json|--raw] [--full|--check|--analyze]
#
# Output Modes:
#   --json: Structured JSON output for LLM (default)
#   --raw:  Verbose debugging output when LLM needs more details
#
# Section Flags (run specific section only):
#   --validate:  Validate Terraform setup and prerequisites
#   --check:     Check for drift in selected environment(s)
#   --analyze:   Analyze drift patterns across environments
#   --full:      Run all sections end-to-end (default)
#
# Environment Selection:
#   --env=ENV:   Check specific environment (development|staging|production)
#   --all-envs:  Check all environments (default)
#
# Workflow:
#   1. LLM calls: infra-drift.sh --json --full
#   2. If drift found: Returns JSON with drift details
#   3. LLM can generate drift report and suggest remediation
#   4. Or LLM runs --analyze to identify patterns

# Global variables
OUTPUT_MODE="json"      # json or raw
SECTION="full"          # full, validate, check, analyze
ENVS=()                 # Environments to check
CHECK_ALL_ENVS=true     # Default: check all environments
PROJECT_ROOT=""
TERRAFORM_DIR=""
DRIFT_FOUND=false
DRIFT_SUMMARY=()
DRIFT_DETAILS=()

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/yaml.sh"

# Custom status-to-action mapping
map_status_to_action() {
    case "$1" in
        drift_detected) echo "review_drift" ;;
        success)        echo "display_summary" ;;
        *)              echo "fix_error" ;;
    esac
}

source "${SCRIPT_DIR}/lib/output-framework.sh"

exit_with_error() {
    local message="$1"
    local details="${2:-}"
    exit_with_json "error" "$message" "$details"
}

#------------------------------------------------------------------------------
# Parse Arguments
#------------------------------------------------------------------------------

while [[ $# -gt 0 ]]; do
    case "$1" in
        --json) OUTPUT_MODE="json"; shift ;;
            --toon) OUTPUT_MODE="json"; OUTPUT_FORMAT="toon"; shift ;;
        --raw) OUTPUT_MODE="raw"; shift ;;
        --full) SECTION="full"; shift ;;
        --validate) SECTION="validate"; shift ;;
        --check) SECTION="check"; shift ;;
        --analyze) SECTION="analyze"; shift ;;
        --env=*)
            CHECK_ALL_ENVS=false
            ENVS+=("${1#*=}")
            shift
            ;;
        --all-envs) CHECK_ALL_ENVS=true; shift ;;
        *)
            exit_with_error "Unknown flag: $1"
            ;;
    esac
done

# Default to full if no section specified
if [[ "$SECTION" == "full" ]]; then
    RUN_VALIDATE=true
    RUN_CHECK=true
    RUN_ANALYZE=true
else
    RUN_VALIDATE=false
    RUN_CHECK=false
    RUN_ANALYZE=false

    case "$SECTION" in
        validate) RUN_VALIDATE=true ;;
        check) RUN_CHECK=true ;;
        analyze) RUN_ANALYZE=true ;;
    esac
fi

#------------------------------------------------------------------------------
# Section: Validate
#------------------------------------------------------------------------------

validate_setup() {
    log "${CYAN}[VALIDATE]${NC} Checking Terraform setup..."

    # Find PROJECT.yaml
    PROJECT_ROOT="$PWD"
    if [[ ! -f "$PROJECT_ROOT/PROJECT.yaml" ]]; then
        exit_with_error "PROJECT.yaml not found in current directory" \
            "Run this command from your project root"
    fi

    # Check for Terraform directory
    TERRAFORM_DIR="$PROJECT_ROOT/infrastructure/terraform"
    if [[ ! -d "$TERRAFORM_DIR" ]]; then
        exit_with_error "Terraform directory not found" \
            "Expected: $TERRAFORM_DIR"
    fi

    # Check terraform command availability
    if ! command -v terraform &> /dev/null; then
        exit_with_error "Terraform not installed" \
            "Install Terraform: https://www.terraform.io/downloads"
    fi

    # Check yq availability (for parsing PROJECT.yaml)
    if ! command -v yq &> /dev/null; then
        exit_with_error "yq not installed" \
            "Install yq: https://github.com/mikefarah/yq"
    fi

    # Get environments from PROJECT.yaml if not specified
    if [[ "$CHECK_ALL_ENVS" == "true" ]]; then
        ENVS=()
        # Try to extract environments from PROJECT.yaml
        if yaml_get '.infrastructure.environments' "$PROJECT_ROOT/PROJECT.yaml" &> /dev/null; then
            mapfile -t ENVS < <(yaml_get '.infrastructure.environments | keys | .[]' "$PROJECT_ROOT/PROJECT.yaml")
        fi

        # Fallback to common environments if none found
        if [[ ${#ENVS[@]} -eq 0 ]]; then
            ENVS=("development" "staging" "production")
        fi
    fi

    log "${GREEN}✓${NC} Terraform setup validated"
    log "  Terraform dir: $TERRAFORM_DIR"
    log "  Environments: ${ENVS[*]}"
}

#------------------------------------------------------------------------------
# Section: Check Drift
#------------------------------------------------------------------------------

check_drift() {
    log "${CYAN}[CHECK]${NC} Checking for drift..."

    cd "$TERRAFORM_DIR" || exit_with_error "Cannot cd to Terraform directory" "$TERRAFORM_DIR"

    DRIFT_FOUND=false
    DRIFT_SUMMARY=()
    DRIFT_DETAILS=()

    for ENV in "${ENVS[@]}"; do
        log ""
        log "${BLUE}Checking $ENV for drift...${NC}"

        # Get workspace from PROJECT.yaml
        WORKSPACE=$(yaml_get ".infrastructure.environments.${ENV}.terraform_workspace" "$PROJECT_ROOT/PROJECT.yaml")
        [[ -z "$WORKSPACE" ]] && WORKSPACE="$ENV"

        # Get var file from PROJECT.yaml
        VAR_FILE=$(yaml_get ".infrastructure.tools[] | select(.name == \"terraform\") | .var_files.${ENV}" "$PROJECT_ROOT/PROJECT.yaml")

        # Switch workspace
        if ! terraform workspace select "$WORKSPACE" 2>/dev/null; then
            if ! terraform workspace new "$WORKSPACE" 2>/dev/null; then
                DRIFT_SUMMARY+=("{\"environment\":\"$ENV\",\"status\":\"error\",\"message\":\"Failed to switch/create workspace: $WORKSPACE\"}")
                continue
            fi
        fi

        # Build terraform plan command
        PLAN_CMD="terraform plan -detailed-exitcode -no-color"
        if [[ -n "$VAR_FILE" ]] && [[ -f "$VAR_FILE" ]]; then
            PLAN_CMD="$PLAN_CMD -var-file=$VAR_FILE"
        fi

        # Capture output
        DRIFT_OUTPUT=$(mktemp)
        set +e
        $PLAN_CMD > "$DRIFT_OUTPUT" 2>&1
        EXIT_CODE=$?
        set -e

        case $EXIT_CODE in
            0)
                log "${GREEN}✓${NC} No drift detected in $ENV"
                DRIFT_SUMMARY+=("{\"environment\":\"$ENV\",\"status\":\"no_drift\",\"message\":\"Infrastructure matches code\"}")
                ;;
            1)
                log "${RED}❌${NC} Error checking $ENV"
                ERROR_MSG=$(head -20 "$DRIFT_OUTPUT")
                DRIFT_SUMMARY+=("{\"environment\":\"$ENV\",\"status\":\"error\",\"message\":\"Terraform plan failed\",\"details\":\"$ERROR_MSG\"}")
                ;;
            2)
                log "${YELLOW}⚠️${NC}  DRIFT DETECTED in $ENV"
                DRIFT_FOUND=true

                # Analyze drift
                ADD_COUNT=$(grep -c "will be created" "$DRIFT_OUTPUT" 2>/dev/null || echo "0")
                CHANGE_COUNT=$(grep -c "will be updated in-place" "$DRIFT_OUTPUT" 2>/dev/null || echo "0")
                REPLACE_COUNT=$(grep -c "must be replaced" "$DRIFT_OUTPUT" 2>/dev/null || echo "0")
                DESTROY_COUNT=$(grep -c "will be destroyed" "$DRIFT_OUTPUT" 2>/dev/null || echo "0")
                TOTAL_DRIFT=$((ADD_COUNT + CHANGE_COUNT + REPLACE_COUNT + DESTROY_COUNT))

                log "  Resources to add: $ADD_COUNT"
                log "  Resources to update: $CHANGE_COUNT"
                log "  Resources to replace: $REPLACE_COUNT"
                log "  Resources to destroy: $DESTROY_COUNT"

                # Get drifted resources (first 20)
                DRIFTED_RESOURCES=$(grep -E "(will be created|will be updated|must be replaced|will be destroyed)" "$DRIFT_OUTPUT" 2>/dev/null | head -20 || echo "")

                # Save drift report
                DRIFT_REPORT_DIR="$PROJECT_ROOT/docs/drift-reports"
                mkdir -p "$DRIFT_REPORT_DIR"
                DRIFT_REPORT="$DRIFT_REPORT_DIR/$(date +%Y-%m-%d)-${ENV}-drift.md"

                cat > "$DRIFT_REPORT" << EOF
# Terraform Drift Report

**Environment**: $ENV
**Workspace**: $WORKSPACE
**Date**: $(date -Iseconds)

## Summary

- Resources to add: $ADD_COUNT
- Resources to update: $CHANGE_COUNT
- Resources to replace: $REPLACE_COUNT
- Resources to destroy: $DESTROY_COUNT
- **Total drift**: $TOTAL_DRIFT resources

## Drifted Resources

\`\`\`
$DRIFTED_RESOURCES
\`\`\`

## Full Terraform Plan Output

\`\`\`
$(cat "$DRIFT_OUTPUT")
\`\`\`

## Possible Causes

- Manual changes made in cloud console
- Changes made outside Terraform
- Resource state out of sync
- External automation modifying resources

## Remediation

1. Review drift above
2. If expected: Update Terraform code to match
3. If unexpected: Run \`/infra-plan\` and \`/infra-apply\` to restore

## Next Steps

- Investigate: Review changes in cloud console
- Restore: /infra-plan and /infra-apply to sync
- Import: terraform import if new resources should be managed
- Remove: terraform state rm if resources should be unmanaged
EOF

                log "${GREEN}✓${NC} Drift report saved: $DRIFT_REPORT"

                # Add to summary
                DRIFT_SUMMARY+=("{\"environment\":\"$ENV\",\"status\":\"drift\",\"total\":$TOTAL_DRIFT,\"add\":$ADD_COUNT,\"update\":$CHANGE_COUNT,\"replace\":$REPLACE_COUNT,\"destroy\":$DESTROY_COUNT,\"report\":\"$DRIFT_REPORT\"}")

                # Store details for analysis
                DRIFT_DETAILS+=("$ENV:$DRIFTED_RESOURCES")
                ;;
        esac

        rm -f "$DRIFT_OUTPUT"
    done

    cd "$PROJECT_ROOT" || exit 1
}

#------------------------------------------------------------------------------
# Section: Analyze Drift Patterns
#------------------------------------------------------------------------------

analyze_drift_patterns() {
    log "${CYAN}[ANALYZE]${NC} Analyzing drift patterns..."

    DRIFT_REPORT_DIR="$PROJECT_ROOT/docs/drift-reports"

    if [[ ! -d "$DRIFT_REPORT_DIR" ]]; then
        log "${YELLOW}⚠️${NC}  No drift reports directory found"
        return
    fi

    REPORT_COUNT=$(find "$DRIFT_REPORT_DIR" -name "*.md" 2>/dev/null | wc -l)

    if [[ $REPORT_COUNT -eq 0 ]]; then
        log "${YELLOW}⚠️${NC}  No drift reports found"
        return
    fi

    log "Found $REPORT_COUNT drift report(s)"

    if [[ $REPORT_COUNT -gt 1 ]]; then
        # Extract commonly drifted resource types
        COMMON_DRIFT=$(find "$DRIFT_REPORT_DIR" -name "*.md" -exec grep -h "will be updated\|will be replaced" {} \; 2>/dev/null | \
            sed -n 's/.*# \([a-z_]\+\.\).*/\1/p' 2>/dev/null | sort | uniq -c | sort -rn | head -5 || echo "")

        if [[ -n "$COMMON_DRIFT" ]]; then
            log ""
            log "${YELLOW}Recurring drift patterns:${NC}"
            echo "$COMMON_DRIFT" | while read -r count resource; do
                log "  $resource: $count occurrence(s)"
            done
        fi
    fi
}

#------------------------------------------------------------------------------
# Main Execution
#------------------------------------------------------------------------------

# Run sections based on flags
if [[ "$RUN_VALIDATE" == "true" ]] || [[ "$SECTION" == "full" ]]; then
    validate_setup
fi

if [[ "$RUN_CHECK" == "true" ]] || [[ "$SECTION" == "full" ]]; then
    check_drift
fi

if [[ "$RUN_ANALYZE" == "true" ]] || [[ "$SECTION" == "full" ]]; then
    analyze_drift_patterns
fi

#------------------------------------------------------------------------------
# Final Output
#------------------------------------------------------------------------------

# Build drift summary array for JSON
DRIFT_SUMMARY_JSON="["
for i in "${!DRIFT_SUMMARY[@]}"; do
    if [[ $i -gt 0 ]]; then
        DRIFT_SUMMARY_JSON="$DRIFT_SUMMARY_JSON,"
    fi
    DRIFT_SUMMARY_JSON="$DRIFT_SUMMARY_JSON${DRIFT_SUMMARY[$i]}"
done
DRIFT_SUMMARY_JSON="$DRIFT_SUMMARY_JSON]"

if [[ "$DRIFT_FOUND" == "true" ]]; then
    exit_with_json "drift_detected" "Configuration drift detected in one or more environments" "" \
        "\"drift_found\": true, \"environments_checked\": ${#ENVS[@]}, \"drift_summary\": $DRIFT_SUMMARY_JSON"
else
    exit_with_json "success" "No drift detected - infrastructure matches code" "" \
        "\"drift_found\": false, \"environments_checked\": ${#ENVS[@]}, \"drift_summary\": $DRIFT_SUMMARY_JSON"
fi
