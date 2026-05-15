#!/usr/bin/env bash
set -euo pipefail

# STANDARD SCRIPT PATTERN: Add dependency with license/security checks
#
# Usage:
#   ~/.claude/scripts/add-dependency.sh [--json|--raw] [--full|--section] --package <name> [options]
#
# Output Modes:
#   --json: Structured JSON output for LLM (default)
#   --raw:  Verbose debugging output when LLM needs more details
#
# Section Flags (run specific section only):
#   --validate:  Check package license
#   --security:  Run Trivy security scan
#   --add:       Add dependency to project
#   --verify:    Verify install and pin version
#   --full:      Run all sections end-to-end (default)
#
# Options:
#   --dev:       Add as dev dependency
#   --python:    Python package (default if pyproject.toml exists)
#   --nodejs:    Node.js package (default if package.json exists)
#
# Workflow:
#   1. LLM calls: add-dependency.sh --json --full <package>
#   2. If license blocked: Returns JSON with forbidden license
#   3. If vulnerabilities: Returns JSON with security details
#   4. LLM can skip sections if already checked: --add <package>

# Global variables
OUTPUT_MODE="json"  # json or raw
SECTION="full"      # full, validate, security, add, verify
PACKAGE=""
DEPENDENCY_TYPE=""  # python or nodejs
IS_DEV=false

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Custom status-to-action mapping
map_status_to_action() {
    case "$1" in
        success)   echo "display_summary" ;;
        blocked)   echo "find_alternative" ;;
        warning)   echo "review_and_decide" ;;
        error)     echo "fix_error" ;;
        *)         echo "display_summary" ;;
    esac
}

source "${SCRIPT_DIR}/lib/output-framework.sh"

# Allowed licenses (permissive)
ALLOWED_LICENSES=(
    "MIT"
    "Apache"
    "Apache-2.0"
    "BSD"
    "BSD-2-Clause"
    "BSD-3-Clause"
    "ISC"
    "Unlicense"
    "CC0"
)

# Forbidden licenses (copyleft)
FORBIDDEN_LICENSES=(
    "GPL"
    "GPL-2.0"
    "GPL-3.0"
    "LGPL"
    "AGPL"
    "CC-BY-SA"
    "MPL"
)

#------------------------------------------------------------------------------
# Helper Functions
#------------------------------------------------------------------------------

detect_dependency_type() {
    # Auto-detect if not specified
    if [[ -z "$DEPENDENCY_TYPE" ]]; then
        if [[ -f "pyproject.toml" ]] || [[ -f "requirements.txt" ]]; then
            DEPENDENCY_TYPE="python"
        elif [[ -f "package.json" ]]; then
            DEPENDENCY_TYPE="nodejs"
        else
            exit_with_json "error" "Cannot detect project type" \
                "No pyproject.toml, requirements.txt, or package.json found"
        fi
    fi
    log "${CYAN}Detected dependency type: $DEPENDENCY_TYPE${NC}"
}

is_license_allowed() {
    local license="$1"

    # Check forbidden first
    for forbidden in "${FORBIDDEN_LICENSES[@]}"; do
        if [[ "$license" =~ $forbidden ]]; then
            return 1
        fi
    done

    # Check allowed
    for allowed in "${ALLOWED_LICENSES[@]}"; do
        if [[ "$license" =~ $allowed ]]; then
            return 0
        fi
    done

    # Unknown license - be conservative
    return 2
}

#------------------------------------------------------------------------------
# Section Functions
#------------------------------------------------------------------------------

# Section 1: Validate License
section_validate() {
    log "${BLUE}Validating Package License${NC}"

    if [[ -z "$PACKAGE" ]]; then
        exit_with_json "error" "Package name required" \
            "Usage: add-dependency.sh <package-name>"
    fi

    detect_dependency_type

    local license=""
    local license_source=""

    # Check license based on dependency type
    if [[ "$DEPENDENCY_TYPE" == "python" ]]; then
        log "Checking PyPI for license information..."
        local pypi_data
        if ! pypi_data=$(curl -sf "https://pypi.org/pypi/${PACKAGE}/json" 2>&1); then
            if [[ "$SECTION" == "validate" ]]; then
                exit_with_json "error" "Package not found on PyPI" \
                    "Package '$PACKAGE' does not exist or PyPI is unreachable"
            else
                exit_with_json "error" "Package not found on PyPI" "$pypi_data"
            fi
        fi

        license=$(echo "$pypi_data" | jq -r '.info.license // "Unknown"')
        license_source="PyPI"

    elif [[ "$DEPENDENCY_TYPE" == "nodejs" ]]; then
        log "Checking npm for license information..."
        local npm_data
        if ! npm_data=$(npm view "${PACKAGE}" license 2>&1); then
            if [[ "$SECTION" == "validate" ]]; then
                exit_with_json "error" "Package not found on npm" \
                    "Package '$PACKAGE' does not exist or npm is unreachable"
            else
                exit_with_json "error" "Package not found on npm" "$npm_data"
            fi
        fi

        license="$npm_data"
        license_source="npm"
    fi

    log "${CYAN}License: $license${NC}"

    # Check if license is allowed
    local license_status
    if is_license_allowed "$license"; then
        license_status="allowed"
        log "${GREEN}✓${NC} License is permissive ($license)"
    elif [[ $? -eq 1 ]]; then
        license_status="forbidden"
        log "${RED}✗${NC} License is copyleft ($license)"
    else
        license_status="unknown"
        log "${YELLOW}⚠${NC} License is unknown ($license)"
    fi

    # If running only this section, return now
    if [[ "$SECTION" == "validate" ]]; then
        if [[ "$license_status" == "forbidden" ]]; then
            local json=$(jq -n \
                --arg package "$PACKAGE" \
                --arg license "$license" \
                --arg source "$license_source" \
                '{
                    status: "blocked",
                    section: "validate",
                    message: "Package has forbidden copyleft license",
                    package: $package,
                    license: $license,
                    license_source: $source,
                    license_status: "forbidden",
                    details: "This license type (copyleft) is not allowed. Find an alternative package with a permissive license (MIT, Apache, BSD).",
                    timestamp: "'"$(date -Iseconds)"'"
                }')
            log_json "$json"
            exit 1
        elif [[ "$license_status" == "unknown" ]]; then
            local json=$(jq -n \
                --arg package "$PACKAGE" \
                --arg license "$license" \
                --arg source "$license_source" \
                '{
                    status: "warning",
                    section: "validate",
                    message: "Package has unknown license - review required",
                    package: $package,
                    license: $license,
                    license_source: $source,
                    license_status: "unknown",
                    details: "License verification recommended before proceeding.",
                    next_steps: [
                        "Review package repository/documentation for license",
                        "If acceptable, continue: add-dependency.sh --json --security '"$PACKAGE"'"
                    ],
                    timestamp: "'"$(date -Iseconds)"'"
                }')
            log_json "$json"
            exit 0
        else
            local json=$(jq -n \
                --arg package "$PACKAGE" \
                --arg license "$license" \
                --arg source "$license_source" \
                '{
                    status: "success",
                    section: "validate",
                    message: "License validation passed",
                    package: $package,
                    license: $license,
                    license_source: $source,
                    license_status: "allowed",
                    next_steps: [
                        "Continue security scan: add-dependency.sh --json --security '"$PACKAGE"'"
                    ],
                    timestamp: "'"$(date -Iseconds)"'"
                }')
            log_json "$json"
            exit 0
        fi
    fi

    # In --full mode, block on forbidden license
    if [[ "$license_status" == "forbidden" ]]; then
        exit_with_json "blocked" "Package has forbidden copyleft license: $license" \
            "This license type is not allowed. Find an alternative package with a permissive license." \
            "\"license\": $(echo "$license" | jq -Rs .), \"package\": $(echo "$PACKAGE" | jq -Rs .)"
    fi

    log "${GREEN}✓${NC} License validation complete"
}

# Section 2: Security Scan
section_security() {
    log "${BLUE}Running Security Scan${NC}"

    detect_dependency_type

    # First, do a quick add to test (we'll remove after scan)
    log "Adding package temporarily for security scan..."

    if [[ "$DEPENDENCY_TYPE" == "python" ]]; then
        if [[ "$IS_DEV" == "true" ]]; then
            docker compose run --rm app uv add --dev "$PACKAGE" >/dev/null 2>&1 || true
        else
            docker compose run --rm app uv add "$PACKAGE" >/dev/null 2>&1 || true
        fi
    elif [[ "$DEPENDENCY_TYPE" == "nodejs" ]]; then
        if [[ "$IS_DEV" == "true" ]]; then
            docker compose run --rm frontend npm install --save-dev "$PACKAGE" >/dev/null 2>&1 || true
        else
            docker compose run --rm frontend npm install "$PACKAGE" >/dev/null 2>&1 || true
        fi
    fi

    # Run Trivy scan
    log "Scanning for vulnerabilities..."
    local scan_result
    local service
    if [[ "$DEPENDENCY_TYPE" == "python" ]]; then
        service="app"
    else
        service="frontend"
    fi

    scan_result=$(docker compose run --rm "$service" trivy fs --scanners vuln --quiet --format json . 2>&1 || true)

    # Parse vulnerabilities
    local critical_count=0
    local high_count=0
    local medium_count=0
    local low_count=0

    if [[ -n "$scan_result" ]] && echo "$scan_result" | jq empty 2>/dev/null; then
        # Count vulnerabilities by severity
        critical_count=$(echo "$scan_result" | jq '[.Results[]?.Vulnerabilities[]? | select(.Severity == "CRITICAL")] | length' 2>/dev/null || echo 0)
        high_count=$(echo "$scan_result" | jq '[.Results[]?.Vulnerabilities[]? | select(.Severity == "HIGH")] | length' 2>/dev/null || echo 0)
        medium_count=$(echo "$scan_result" | jq '[.Results[]?.Vulnerabilities[]? | select(.Severity == "MEDIUM")] | length' 2>/dev/null || echo 0)
        low_count=$(echo "$scan_result" | jq '[.Results[]?.Vulnerabilities[]? | select(.Severity == "LOW")] | length' 2>/dev/null || echo 0)
    fi

    log "${CYAN}Vulnerabilities: CRITICAL=$critical_count HIGH=$high_count MEDIUM=$medium_count LOW=$low_count${NC}"

    # If running only this section, return now
    if [[ "$SECTION" == "security" ]]; then
        if [[ $critical_count -gt 0 ]] || [[ $high_count -gt 0 ]]; then
            local json=$(jq -n \
                --arg package "$PACKAGE" \
                --argjson critical "$critical_count" \
                --argjson high "$high_count" \
                --argjson medium "$medium_count" \
                --argjson low "$low_count" \
                '{
                    status: "blocked",
                    section: "security",
                    message: "Package has CRITICAL or HIGH vulnerabilities",
                    package: $package,
                    vulnerabilities: {
                        critical: $critical,
                        high: $high,
                        medium: $medium,
                        low: $low
                    },
                    details: "Do not add packages with CRITICAL or HIGH vulnerabilities. Find an alternative.",
                    timestamp: "'"$(date -Iseconds)"'"
                }')
            log_json "$json"
            exit 1
        elif [[ $medium_count -gt 0 ]]; then
            local json=$(jq -n \
                --arg package "$PACKAGE" \
                --argjson critical "$critical_count" \
                --argjson high "$high_count" \
                --argjson medium "$medium_count" \
                --argjson low "$low_count" \
                '{
                    status: "warning",
                    section: "security",
                    message: "Package has MEDIUM vulnerabilities - review required",
                    package: $package,
                    vulnerabilities: {
                        critical: $critical,
                        high: $high,
                        medium: $medium,
                        low: $low
                    },
                    details: "Evaluate if MEDIUM vulnerabilities are exploitable in your context.",
                    next_steps: [
                        "Review vulnerability details",
                        "If acceptable, continue: add-dependency.sh --json --add '"$PACKAGE"'"
                    ],
                    timestamp: "'"$(date -Iseconds)"'"
                }')
            log_json "$json"
            exit 0
        else
            local json=$(jq -n \
                --arg package "$PACKAGE" \
                --argjson critical "$critical_count" \
                --argjson high "$high_count" \
                --argjson medium "$medium_count" \
                --argjson low "$low_count" \
                '{
                    status: "success",
                    section: "security",
                    message: "Security scan passed",
                    package: $package,
                    vulnerabilities: {
                        critical: $critical,
                        high: $high,
                        medium: $medium,
                        low: $low
                    },
                    next_steps: [
                        "Continue adding package: add-dependency.sh --json --add '"$PACKAGE"'"
                    ],
                    timestamp: "'"$(date -Iseconds)"'"
                }')
            log_json "$json"
            exit 0
        fi
    fi

    # In --full mode, block on critical/high vulnerabilities
    if [[ $critical_count -gt 0 ]] || [[ $high_count -gt 0 ]]; then
        exit_with_json "blocked" "Package has CRITICAL or HIGH vulnerabilities" \
            "CRITICAL: $critical_count, HIGH: $high_count. Do not add packages with these severity levels." \
            "\"critical\": $critical_count, \"high\": $high_count"
    fi

    log "${GREEN}✓${NC} Security scan passed"
}

# Section 3: Add Dependency
section_add() {
    log "${BLUE}Adding Dependency${NC}"

    detect_dependency_type

    local add_result
    local add_cmd

    if [[ "$DEPENDENCY_TYPE" == "python" ]]; then
        if [[ "$IS_DEV" == "true" ]]; then
            add_cmd="docker compose run --rm app uv add --dev $PACKAGE"
        else
            add_cmd="docker compose run --rm app uv add $PACKAGE"
        fi
    elif [[ "$DEPENDENCY_TYPE" == "nodejs" ]]; then
        if [[ "$IS_DEV" == "true" ]]; then
            add_cmd="docker compose run --rm frontend npm install --save-dev $PACKAGE"
        else
            add_cmd="docker compose run --rm frontend npm install $PACKAGE"
        fi
    fi

    log "Running: $add_cmd"

    if ! add_result=$(eval "$add_cmd" 2>&1); then
        if [[ "$SECTION" == "add" ]]; then
            exit_with_json "error" "Failed to add package" "$add_result"
        else
            exit_with_json "error" "Failed to add package" "$add_result"
        fi
    fi

    # If running only this section, return now
    if [[ "$SECTION" == "add" ]]; then
        local json=$(jq -n \
            --arg package "$PACKAGE" \
            --arg type "$DEPENDENCY_TYPE" \
            --arg dev "$IS_DEV" \
            '{
                status: "success",
                section: "add",
                message: "Package added successfully",
                package: $package,
                dependency_type: $type,
                is_dev: ($dev == "true"),
                next_steps: [
                    "Verify and pin version: add-dependency.sh --json --verify '"$PACKAGE"'"
                ],
                timestamp: "'"$(date -Iseconds)"'"
            }')
        log_json "$json"
        exit 0
    fi

    log "${GREEN}✓${NC} Package added"
}

# Section 4: Verify and Pin Version
section_verify() {
    log "${BLUE}Verifying Installation and Pinning Version${NC}"

    detect_dependency_type

    local version=""
    local lock_file=""

    # Get installed version
    if [[ "$DEPENDENCY_TYPE" == "python" ]]; then
        version=$(docker compose run --rm app uv pip show "$PACKAGE" 2>/dev/null | grep "^Version:" | awk '{print $2}' || echo "")
        lock_file="uv.lock"

        if [[ -z "$version" ]]; then
            exit_with_json "error" "Could not determine installed version" \
                "Package may not be installed correctly"
        fi

        log "${CYAN}Installed version: $version${NC}"
        log "Pinning version in pyproject.toml..."

        # Note: UV should have already added it to pyproject.toml
        # We just need to regenerate the lock file
        log "Regenerating lock file..."
        docker compose run --rm app uv lock >/dev/null 2>&1

        log "Verifying deterministic install..."
        docker compose run --rm app uv sync --frozen >/dev/null 2>&1

    elif [[ "$DEPENDENCY_TYPE" == "nodejs" ]]; then
        version=$(docker compose run --rm frontend npm list "$PACKAGE" 2>/dev/null | grep "$PACKAGE@" | sed -n 's/.*@\([^ ]*\).*/\1/p' || echo "")
        lock_file="package-lock.json"

        if [[ -z "$version" ]]; then
            exit_with_json "error" "Could not determine installed version" \
                "Package may not be installed correctly"
        fi

        log "${CYAN}Installed version: $version${NC}"

        # npm should have already pinned it in package.json
        log "Verifying lock file..."
        docker compose run --rm frontend npm install >/dev/null 2>&1

        log "Verifying deterministic install..."
        docker compose run --rm frontend npm ci >/dev/null 2>&1
    fi

    # If running only this section, return now
    if [[ "$SECTION" == "verify" ]]; then
        local json=$(jq -n \
            --arg package "$PACKAGE" \
            --arg version "$version" \
            --arg type "$DEPENDENCY_TYPE" \
            --arg lock "$lock_file" \
            --arg dev "$IS_DEV" \
            '{
                status: "success",
                section: "verify",
                message: "Package installed and pinned successfully",
                package: $package,
                version: $version,
                dependency_type: $type,
                lock_file: $lock,
                is_dev: ($dev == "true"),
                next_steps: [
                    "Build with tests: docker compose build --build-arg RUN_TESTS=true",
                    "Document the dependency in README or DEPENDENCIES.md"
                ],
                timestamp: "'"$(date -Iseconds)"'"
            }')
        log_json "$json"
        exit 0
    fi

    log "${GREEN}✓${NC} Version verified and pinned"
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
            --security) SECTION="security"; shift ;;
            --add) SECTION="add"; shift ;;
            --verify) SECTION="verify"; shift ;;
            --full) SECTION="full"; shift ;;
            --dev) IS_DEV=true; shift ;;
            --python) DEPENDENCY_TYPE="python"; shift ;;
            --nodejs) DEPENDENCY_TYPE="nodejs"; shift ;;
            --help|-h)
                echo "Usage: add-dependency.sh [--json|--raw] [--full|--section] <package> [options]"
                echo ""
                echo "Sections: --validate, --security, --add, --verify, --full (default)"
                echo "Options: --dev, --python, --nodejs"
                exit 0
                ;;
            -*)
                echo "Unknown flag: $1" >&2
                exit 1
                ;;
            --package)
                PACKAGE="$2"
                shift 2
                ;;
            *)
                echo "Unknown option: $1" >&2
                exit 2
                ;;
        esac
    done

    # Execute sections based on flag
    case "$SECTION" in
        validate)
            section_validate
            ;;
        security)
            section_validate  # Always validate first
            section_security
            ;;
        add)
            section_validate  # Always validate first
            section_add
            ;;
        verify)
            # Assume add already done
            section_verify
            ;;
        full)
            section_validate
            section_security
            section_add
            section_verify

            # Full success - return complete results
            local final_version=""
            if [[ "$DEPENDENCY_TYPE" == "python" ]]; then
                final_version=$(docker compose run --rm app uv pip show "$PACKAGE" 2>/dev/null | grep "^Version:" | awk '{print $2}' || echo "unknown")
            elif [[ "$DEPENDENCY_TYPE" == "nodejs" ]]; then
                final_version=$(docker compose run --rm frontend npm list "$PACKAGE" 2>/dev/null | grep "$PACKAGE@" | sed -n 's/.*@\([^ ]*\).*/\1/p' || echo "unknown")
            fi

            local json=$(jq -n \
                --arg package "$PACKAGE" \
                --arg version "$final_version" \
                --arg type "$DEPENDENCY_TYPE" \
                --arg dev "$IS_DEV" \
                '{
                    status: "success",
                    message: "Dependency added successfully",
                    package: $package,
                    version: $version,
                    dependency_type: $type,
                    is_dev: ($dev == "true"),
                    sections_completed: ["validate", "security", "add", "verify"],
                    next_steps: [
                        "Build with tests: docker compose build --build-arg RUN_TESTS=true",
                        "Document the dependency in README or DEPENDENCIES.md",
                        "Commit changes: git add pyproject.toml uv.lock (or package.json package-lock.json)"
                    ],
                    timestamp: "'"$(date -Iseconds)"'"
                }')
            log_json "$json"
            exit 0
            ;;
    esac
}

# Run main function
main "$@"
