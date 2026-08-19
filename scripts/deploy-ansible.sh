#!/usr/bin/env bash
set -euo pipefail

# deploy-ansible.sh - Run Ansible playbooks with environment and inventory selection
#
# STANDARD SCRIPT PATTERN: Section flags with --json/--raw output modes
#
# Usage:
#   ~/.claude/scripts/deploy-ansible.sh [--json|--raw] [--full|--section]
#
# Output Modes:
#   --json: Structured output for LLM, default (TOON when the caller is an AI agent, JSON otherwise)
#   --raw:  Verbose debugging output when LLM needs more details
#
# Section Flags (run specific section only):
#   --validate:  Verify infrastructure and configuration
#   --prepare:   Determine environment, inventory, and playbook
#   --execute:   Build and run Ansible command
#   --report:    Save execution log and generate report
#   --full:      Run all sections end-to-end (default)
#
# Optional Flags:
#   --env ENV:        Pre-select environment (dev/staging/prod)
#   --playbook PB:    Pre-select playbook file
#   --check:          Enable check mode (dry-run)
#   --limit PATTERN:  Limit to specific hosts
#   --verbose:        Enable verbose Ansible output (-vv)
#   --extra-vars JSON: Pass extra variables
#
# Workflow:
#   1. LLM calls: script.sh --json --full
#   2. If error: Returns JSON with error details
#   3. LLM can retry with --raw for more debugging info
#   4. Or LLM runs specific --section after fixing issue

# Global variables
OUTPUT_MODE="json"  # json or raw
SECTION="full"      # full, validate, prepare, execute, report

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Custom status-to-action mapping
map_status_to_action() {
    case "$1" in
        success) echo "display_summary" ;;
        blocked) echo "notify_user_blocked" ;;
        *)       echo "fix_error" ;;
    esac
}

source "${SCRIPT_DIR}/lib/output-framework.sh"
source "${SCRIPT_DIR}/lib/yaml.sh"

# Configuration variables
ENV=""
INVENTORY=""
PLAYBOOK=""
LIMIT=""
CHECK_MODE=false
ASK_SUDO=false
VERBOSE=false
EXTRA_VARS=""
PROJECT_ROOT=""

# Execution results
ANSIBLE_STATUS=0
ANSIBLE_OUTPUT=""
LOG_FILE=""

#------------------------------------------------------------------------------
# Section Functions
#------------------------------------------------------------------------------

# Section 1: Validate infrastructure
section_validate() {
    log "${BLUE}Validating Infrastructure${NC}"

    PROJECT_ROOT=$(pwd)

    # Check infrastructure symlink
    if [[ ! -L "infrastructure" ]]; then
        exit_with_json "error" "Infrastructure not linked" "Run: /infra-verify to set up infrastructure link"
    fi

    # Check ansible directory
    if [[ ! -d "infrastructure/ansible" ]]; then
        exit_with_json "error" "Ansible directory not found" "Infrastructure link exists but infrastructure/ansible directory is missing"
    fi

    # Check for yq if PROJECT.yaml exists
    if [[ -f "PROJECT.yaml" ]] && ! command -v yq &> /dev/null; then
        log "${YELLOW}⚠${NC} yq not found - cannot read PROJECT.yaml"
    fi

    # If running only this section, return now
    if [[ "$SECTION" == "validate" ]]; then
        local json=$(cat <<EOF
{
  "status": "success",
  "next_action": "display_summary",
  "section": "validate",
  "message": "Infrastructure validated",
  "infrastructure_path": "$(readlink infrastructure)",
  "ansible_playbooks": $(find infrastructure/ansible/playbooks -name "*.yml" -o -name "*.yaml" 2>/dev/null | jq -R . | jq -s . || echo '[]'),
  "timestamp": "$(date -Iseconds)"
}
EOF
)
        log_json "$json"
        exit 0
    fi

    log "${GREEN}✓${NC} Infrastructure validated"
}

# Section 2: Prepare (determine environment, inventory, playbook)
section_prepare() {
    log "${BLUE}Preparing Deployment Configuration${NC}"

    # Determine environment
    if [[ -z "$ENV" ]]; then
        if [[ "$OUTPUT_MODE" == "raw" ]]; then
            log "Select Environment:"
            log "1. development"
            log "2. staging"
            log "3. production"
            log "4. custom"
            read -p "Choice (default: 1): " CHOICE
        else
            CHOICE="1"  # Default when --json is used
        fi

        case "$CHOICE" in
            1) ENV="development" ;;
            2) ENV="staging" ;;
            3) ENV="production" ;;
            4)
                if [[ "$OUTPUT_MODE" == "raw" ]]; then
                    read -p "Enter environment name: " ENV
                else
                    ENV="development"
                fi
                ;;
            *) ENV="development" ;;
        esac
    fi

    log "Environment: ${CYAN}$ENV${NC}"

    # Get inventory from PROJECT.yaml or common patterns
    if [[ -z "$INVENTORY" ]]; then
        if [[ -f "PROJECT.yaml" ]]; then
            INVENTORY=$(yaml_get ".infrastructure.environments.${ENV}.ansible_inventory" PROJECT.yaml)
        fi

        # Try common patterns if not in PROJECT.yaml
        if [[ -z "$INVENTORY" ]] || [[ "$INVENTORY" == "null" ]]; then
            if [[ -f "infrastructure/ansible/inventory/${ENV}.ini" ]]; then
                INVENTORY="inventory/${ENV}.ini"
            elif [[ -f "infrastructure/ansible/inventory/${ENV}" ]]; then
                INVENTORY="inventory/${ENV}"
            else
                INVENTORY="inventory/${ENV}.ini"  # Default guess
            fi
        fi
    fi

    log "Inventory: ${CYAN}$INVENTORY${NC}"

    # Select playbook
    if [[ -z "$PLAYBOOK" ]]; then
        if [[ "$OUTPUT_MODE" == "raw" ]]; then
            log ""
            log "Available playbooks:"
            find infrastructure/ansible/playbooks -name "*.yml" -o -name "*.yaml" 2>/dev/null | nl
            log ""
            log "Common playbooks:"
            log "1. deploy"
            log "2. configure"
            log "3. rollback"
            log "4. custom"
            read -p "Playbook choice (1-4, default: 1): " PB_CHOICE
        else
            PB_CHOICE="1"
        fi

        case "$PB_CHOICE" in
            1) PLAYBOOK="deploy.yml" ;;
            2) PLAYBOOK="configure.yml" ;;
            3) PLAYBOOK="rollback.yml" ;;
            4)
                if [[ "$OUTPUT_MODE" == "raw" ]]; then
                    read -p "Enter playbook path: " PLAYBOOK
                else
                    PLAYBOOK="deploy.yml"
                fi
                ;;
            *) PLAYBOOK="deploy.yml" ;;
        esac

        # Try to get from PROJECT.yaml if available
        if [[ -f "PROJECT.yaml" ]] && [[ "$PB_CHOICE" =~ ^[1-3]$ ]]; then
            local config_pb=""
            case "$PB_CHOICE" in
                1) config_pb=$(yaml_get '.infrastructure.tools[] | select(.name == "ansible") | .playbooks.deploy' PROJECT.yaml) ;;
                2) config_pb=$(yaml_get '.infrastructure.tools[] | select(.name == "ansible") | .playbooks.configure' PROJECT.yaml) ;;
                3) config_pb=$(yaml_get '.infrastructure.tools[] | select(.name == "ansible") | .playbooks.rollback' PROJECT.yaml) ;;
            esac

            if [[ -n "$config_pb" ]] && [[ "$config_pb" != "null" ]]; then
                PLAYBOOK="$config_pb"
            fi
        fi
    fi

    log "Playbook: ${CYAN}$PLAYBOOK${NC}"

    # Gather additional options (only in raw mode)
    if [[ "$OUTPUT_MODE" == "raw" ]] && [[ -z "$LIMIT" ]]; then
        log ""
        log "Target specific hosts?"
        log "1. No - run on all hosts (default)"
        log "2. Yes - limit to specific hosts"
        read -p "Choice (1-2): " LIMIT_CHOICE

        if [[ "$LIMIT_CHOICE" == "2" ]]; then
            read -p "Host pattern (e.g., web, web[0], web*): " LIMIT
        fi

        log ""
        read -p "Ask for sudo password? (y/n): " ASK_SUDO_INPUT
        [[ "$ASK_SUDO_INPUT" == "y" ]] && ASK_SUDO=true

        if [[ "$VERBOSE" != "true" ]]; then
            read -p "Run with higher verbosity? (y/n): " VERBOSE_INPUT
            [[ "$VERBOSE_INPUT" == "y" ]] && VERBOSE=true
        fi

        if [[ -z "$EXTRA_VARS" ]]; then
            read -p "Extra vars (JSON format, optional): " EXTRA_VARS
        fi
    fi

    # If running only this section, return now
    if [[ "$SECTION" == "prepare" ]]; then
        local json=$(cat <<EOF
{
  "status": "success",
  "next_action": "display_summary",
  "section": "prepare",
  "message": "Configuration prepared",
  "environment": "$ENV",
  "inventory": "$INVENTORY",
  "playbook": "$PLAYBOOK",
  "limit": "${LIMIT}",
  "check_mode": $CHECK_MODE,
  "verbose": $VERBOSE,
  "next_steps": ["Execute Ansible: deploy-ansible.sh --json --execute"],
  "timestamp": "$(date -Iseconds)"
}
EOF
)
        log_json "$json"
        exit 0
    fi

    log "${GREEN}✓${NC} Configuration prepared"
}

# Section 3: Execute Ansible command
section_execute() {
    log "${BLUE}Executing Ansible Playbook${NC}"

    # Navigate to ansible directory
    cd infrastructure/ansible || exit_with_json "error" "Failed to change to ansible directory"
    log "Working directory: ${CYAN}$(pwd)${NC}"

    # Build command
    local ansible_cmd="ansible-playbook"
    ansible_cmd="$ansible_cmd -i $INVENTORY"
    ansible_cmd="$ansible_cmd playbooks/$PLAYBOOK"

    if [[ -n "$LIMIT" ]]; then
        ansible_cmd="$ansible_cmd --limit=$LIMIT"
    fi

    if [[ "$CHECK_MODE" == true ]]; then
        ansible_cmd="$ansible_cmd --check"
    fi

    if [[ "$ASK_SUDO" == true ]]; then
        ansible_cmd="$ansible_cmd --ask-become-pass"
    fi

    if [[ "$VERBOSE" == true ]]; then
        ansible_cmd="$ansible_cmd -vv"
    fi

    if [[ -n "$EXTRA_VARS" ]]; then
        ansible_cmd="$ansible_cmd --extra-vars='$EXTRA_VARS'"
    fi

    log "Command: ${CYAN}$ansible_cmd${NC}"

    # Production confirmation
    if [[ "$ENV" == "production" ]]; then
        if [[ "$OUTPUT_MODE" != "raw" ]]; then
            exit_with_json "blocked" "Production deployment requires interactive confirmation" \
                "Re-run with --raw to confirm interactively"
        fi

        log ""
        log "${YELLOW}⚠  WARNING: Running against PRODUCTION${NC}"
        log ""
        read -p "Type 'yes' to proceed: " CONFIRM
        if [[ "$CONFIRM" != "yes" ]]; then
            exit_with_json "blocked" "Production deployment cancelled by user"
        fi
    fi

    # Execute Ansible
    log ""
    if ANSIBLE_OUTPUT=$(eval "$ansible_cmd" 2>&1); then
        ANSIBLE_STATUS=0
        log "${GREEN}✓${NC} Ansible playbook completed successfully"
        if [[ "$CHECK_MODE" == true ]]; then
            log "  (dry-run mode - no changes made)"
        fi
    else
        ANSIBLE_STATUS=$?
        log "${RED}✗${NC} Ansible playbook failed (exit code: $ANSIBLE_STATUS)"
    fi

    # Return to project root
    cd "$PROJECT_ROOT" || exit_with_json "error" "Failed to return to project root"

    # If running only this section, return now
    if [[ "$SECTION" == "execute" ]]; then
        if [[ $ANSIBLE_STATUS -eq 0 ]]; then
            local json=$(cat <<EOF
{
  "status": "success",
  "next_action": "display_summary",
  "section": "execute",
  "message": "Ansible playbook completed successfully",
  "environment": "$ENV",
  "playbook": "$PLAYBOOK",
  "check_mode": $CHECK_MODE,
  "exit_code": $ANSIBLE_STATUS,
  "output": $(echo "$ANSIBLE_OUTPUT" | tail -100 | jq -Rs .),
  "next_steps": ["Save report: deploy-ansible.sh --json --report"],
  "timestamp": "$(date -Iseconds)"
}
EOF
)
            log_json "$json"
            exit 0
        else
            local json=$(cat <<EOF
{
  "status": "error",
  "next_action": "fix_error",
  "section": "execute",
  "message": "Ansible playbook failed",
  "environment": "$ENV",
  "playbook": "$PLAYBOOK",
  "exit_code": $ANSIBLE_STATUS,
  "error_output": $(echo "$ANSIBLE_OUTPUT" | tail -100 | jq -Rs .),
  "next_steps": [
    "Review error output above",
    "Try --raw mode for full output: deploy-ansible.sh --raw --execute",
    "Check inventory and playbook configuration"
  ],
  "timestamp": "$(date -Iseconds)"
}
EOF
)
            log_json "$json"
            exit 1
        fi
    fi

    log "${GREEN}✓${NC} Execution complete"
}

# Section 4: Report (save log and generate summary)
section_report() {
    log "${BLUE}Generating Report${NC}"

    # Create log directory
    local log_dir="docs/ansible-runs"
    mkdir -p "$log_dir"

    # Generate log file
    LOG_FILE="${log_dir}/$(date +%Y-%m-%d-%H%M%S)-${ENV}-${PLAYBOOK%.yml}.log"

    cat > "$LOG_FILE" << EOF
# Ansible Execution Log

**Date**: $(date -Iseconds)
**Environment**: $ENV
**Inventory**: $INVENTORY
**Playbook**: $PLAYBOOK
**Limit**: ${LIMIT:-all hosts}
**Check Mode**: ${CHECK_MODE}
**Status**: $(if [[ $ANSIBLE_STATUS -eq 0 ]]; then echo "SUCCESS"; else echo "FAILED"; fi)

## Command
\`\`\`
ansible-playbook -i $INVENTORY playbooks/$PLAYBOOK${LIMIT:+ --limit=$LIMIT}${CHECK_MODE:+ --check}${VERBOSE:+ -vv}
\`\`\`

## Exit Code
$ANSIBLE_STATUS

## Notes
${EXTRA_VARS:+Extra vars: $EXTRA_VARS}

## Output (last 100 lines)
\`\`\`
$(echo "$ANSIBLE_OUTPUT" | tail -100)
\`\`\`
EOF

    log "Execution log: ${CYAN}$LOG_FILE${NC}"

    # If running only this section, return now
    if [[ "$SECTION" == "report" ]]; then
        local json=$(cat <<EOF
{
  "status": "success",
  "next_action": "display_summary",
  "section": "report",
  "message": "Report generated",
  "log_file": "$LOG_FILE",
  "timestamp": "$(date -Iseconds)"
}
EOF
)
        log_json "$json"
        exit 0
    fi

    log "${GREEN}✓${NC} Report generated"
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
            --prepare) SECTION="prepare"; shift ;;
            --execute) SECTION="execute"; shift ;;
            --report) SECTION="report"; shift ;;
            --full) SECTION="full"; shift ;;
            --env) ENV="$2"; shift 2 ;;
            --playbook) PLAYBOOK="$2"; shift 2 ;;
            --check) CHECK_MODE=true; shift ;;
            --limit) LIMIT="$2"; shift 2 ;;
            --verbose) VERBOSE=true; shift ;;
            --extra-vars) EXTRA_VARS="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    # Execute sections based on flag
    case "$SECTION" in
        validate)
            section_validate
            ;;
        prepare)
            section_validate  # Prerequisites first
            section_prepare
            ;;
        execute)
            section_validate  # Prerequisites first
            section_prepare   # Need configuration
            section_execute
            ;;
        report)
            # Assume execution already done
            section_report
            ;;
        full)
            section_validate
            section_prepare
            section_execute
            section_report

            # Full success - return complete results
            local json=$(cat <<EOF
{
  "status": $(if [[ $ANSIBLE_STATUS -eq 0 ]]; then echo '"success"'; else echo '"error"'; fi),
  "next_action": $(if [[ $ANSIBLE_STATUS -eq 0 ]]; then echo '"display_summary"'; else echo '"fix_error"'; fi),
  "message": "Ansible deployment $(if [[ $ANSIBLE_STATUS -eq 0 ]]; then echo 'completed successfully'; else echo 'failed'; fi)",
  "environment": "$ENV",
  "inventory": "$INVENTORY",
  "playbook": "$PLAYBOOK",
  "limit": "${LIMIT}",
  "check_mode": $CHECK_MODE,
  "verbose": $VERBOSE,
  "exit_code": $ANSIBLE_STATUS,
  "log_file": "$LOG_FILE",
  "warnings": $(if [[ "$ENV" == "production" ]]; then echo '["Production deployment"]'; else echo '[]'; fi),
  "timestamp": "$(date -Iseconds)"
}
EOF
)
            log_json "$json"
            exit $ANSIBLE_STATUS
            ;;
    esac
}

# Run main function
main "$@"
