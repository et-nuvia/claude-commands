#!/usr/bin/env bash
set -euo pipefail

# deployment-config.sh - Display or validate deployment configuration
#
# STANDARD SCRIPT PATTERN: Section flags with --json/--raw output modes
#
# Usage:
#   ~/.claude/scripts/deployment-config.sh [--json|--raw] [--full|--section]
#
# Output Modes:
#   --json: Structured output for LLM, default (TOON when the caller is an AI agent, JSON otherwise)
#   --raw:  Verbose debugging output when LLM needs more details
#
# Section Flags:
#   --validate:  Validate PROJECT.yaml deployment config only
#   --show:      Show full configuration (alias for --full)
#   --full:      Show full configuration (default)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Custom status→action mappings (must be defined BEFORE sourcing)
map_status_to_action() {
    case "$1" in
        success) echo "display_summary" ;;
        *)       _default_map_status_to_action "$1" ;;
    esac
}

# Source shared libraries
source "${SCRIPT_DIR}/lib/output-framework.sh"
source "${SCRIPT_DIR}/lib/yaml.sh"

# Global variables
OUTPUT_MODE="json"
SECTION="full"

# =============================================================================
# Validation
# =============================================================================

section_validate() {
    log "${BLUE}Validating Configuration${NC}"

    if [[ ! -f "PROJECT.yaml" ]]; then
        exit_with_json "error" "PROJECT.yaml not found" "Run /project-config init to create configuration"
    fi

    local errors=()
    local warnings=()

    # Validate deployment section exists
    local has_deployment
    has_deployment=$(yaml_get '.deployment' PROJECT.yaml)
    if [[ -z "$has_deployment" ]]; then
        warnings+=("deployment section not configured - using pipeline defaults")
    fi

    # Validate CI configuration
    local ci_platform
    ci_platform=$(yaml_get '.ci.platform' PROJECT.yaml)
    if [[ -n "$ci_platform" && "$ci_platform" != "github" && "$ci_platform" != "gitlab" ]]; then
        errors+=("ci.platform must be 'github' or 'gitlab', got: $ci_platform")
    fi

    # Validate deployment method
    local method
    method=$(yaml_get_default '.deployment.method' 'pipeline' PROJECT.yaml)
    if [[ "$method" != "pipeline" && "$method" != "ssm" && "$method" != "ssh" && "$method" != "script" ]]; then
        errors+=("deployment.method must be 'pipeline', 'ssm', 'ssh', or 'script', got: $method")
    fi

    # Check for required environment-specific config
    if [[ "$method" == "ssm" ]]; then
        local staging_target
        staging_target=$(yaml_get '.deployment.staging.target' PROJECT.yaml)
        local prod_target
        prod_target=$(yaml_get '.deployment.production.target' PROJECT.yaml)
        [[ -z "$staging_target" ]] && warnings+=("deployment.staging.target not configured for SSM method")
        [[ -z "$prod_target" ]] && warnings+=("deployment.production.target not configured for SSM method")
    fi

    if [[ "$method" == "ssh" ]]; then
        local staging_host
        staging_host=$(yaml_get '.deployment.staging.host' PROJECT.yaml)
        local prod_host
        prod_host=$(yaml_get '.deployment.production.host' PROJECT.yaml)
        [[ -z "$staging_host" ]] && warnings+=("deployment.staging.host not configured for SSH method")
        [[ -z "$prod_host" ]] && warnings+=("deployment.production.host not configured for SSH method")
    fi

    # Return results
    if [[ ${#errors[@]} -gt 0 ]]; then
        exit_with_json "error" "Configuration validation failed" \
            "$(printf '%s; ' "${errors[@]}" | sed 's/; $//')"
    fi

    # Success
    local warnings_json="[]"
    if [[ ${#warnings[@]} -gt 0 ]]; then
        warnings_json=$(printf '%s\n' "${warnings[@]}" | jq -R . | jq -s .)
    fi

    if [[ "$SECTION" == "validate" ]]; then
        exit_with_json "success" "Configuration valid" "" \
            "\"warnings\": $warnings_json"
    fi

    log "${GREEN}✓${NC} Configuration valid"
}

# =============================================================================
# Show Configuration
# =============================================================================

section_show() {
    log "${BLUE}Loading Configuration${NC}"

    # Source deployment config library
    source "${SCRIPT_DIR}/lib/deployment-config.sh"

    if [[ "$OUTPUT_MODE" == "raw" ]]; then
        cat >&2 << EOF
Deployment Configuration
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Environment Type: ${ENV_TYPE}
Current Version:  ${VERSION}

Branches:
  Development:    ${DEV_BRANCH}
  Staging:        ${STAGING_BRANCH}
  Production:     ${PRODUCTION_BRANCH}

CI/CD:
  Platform:       ${CI_PLATFORM}

Deployment:
  Method:         ${DEPLOYMENT_METHOD}
  Health Check:   ${HEALTH_CHECK_PATH}
  Version Path:   ${VERSION_PATH}

Testing:
  E2E Command:    ${E2E_COMMAND:-not configured}
  E2E Timeout:    ${E2E_TIMEOUT}s

URLs:
  Staging:        ${STAGING_URL:-not configured}
  Production:     ${PRODUCTION_URL:-not configured}
  Staging Public: ${STAGING_PUBLIC_URL:-not configured}
  Prod Public:    ${PRODUCTION_PUBLIC_URL:-not configured}

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF
    fi

    local config_json
    config_json=$(cat << EOF | jq -c .
{
  "environment_type": "${ENV_TYPE}",
  "branches": {
    "dev": "${DEV_BRANCH}",
    "staging": "${STAGING_BRANCH}",
    "production": "${PRODUCTION_BRANCH}"
  },
  "ci": {
    "platform": "${CI_PLATFORM}"
  },
  "deployment": {
    "method": "${DEPLOYMENT_METHOD}",
    "health_check_path": "${HEALTH_CHECK_PATH}",
    "version_path": "${VERSION_PATH}"
  },
  "testing": {
    "e2e_command": "${E2E_COMMAND}",
    "e2e_timeout": ${E2E_TIMEOUT}
  },
  "urls": {
    "staging": "${STAGING_URL}",
    "production": "${PRODUCTION_URL}",
    "staging_public": "${STAGING_PUBLIC_URL}",
    "production_public": "${PRODUCTION_PUBLIC_URL}"
  },
  "version": "${VERSION}"
}
EOF
)

    exit_with_json "success" "Configuration loaded" "" \
        "\"config\": $config_json"
}

# =============================================================================
# Main Execution
# =============================================================================

main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json) OUTPUT_MODE="json"; shift ;;
            --toon) OUTPUT_MODE="json"; OUTPUT_FORMAT="toon"; shift ;;
            --raw) OUTPUT_MODE="raw"; shift ;;
            --full|--show) SECTION="full"; shift ;;
            --validate) SECTION="validate"; shift ;;
            -h|--help)
                sed -n '3,/^$/{ s/^# //; s/^#//; p }' "$0"
                exit 0
                ;;
            *) echo "Unknown option: $1" >&2; exit 2 ;;
        esac
    done

    case "$SECTION" in
        validate)
            section_validate
            ;;
        full)
            section_validate
            section_show
            ;;
    esac
}

main "$@"
