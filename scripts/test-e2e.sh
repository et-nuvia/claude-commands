#!/usr/bin/env bash
set -euo pipefail

# test-e2e.sh - Run end-to-end tests with JSON output
#
# Usage:
#   ~/.claude/scripts/test-e2e.sh [--json|--raw] [--full|--validate|--detect|--execute]
#   Options: --headed --debug --browser <name> --pattern <pat> --file <path> --env <env>

OUTPUT_MODE="json"; SECTION="full"
TEST_HEADED=""; TEST_DEBUG=""; TEST_BROWSER=""; TEST_PATTERN=""; TEST_FILE=""; TEST_ENV=""
DETECTED_FRAMEWORK=""; DETECTED_COMMAND=""; SERVICE_NAME=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/yaml.sh"
source "${SCRIPT_DIR}/lib/output-framework.sh"

#------------------------------------------------------------------------------
# Make delegation - use Makefile when available
#------------------------------------------------------------------------------

try_make_e2e_delegation() {
    # Check if a Makefile with test-e2e and FORMAT=json support exists
    if [[ ! -f "Makefile" ]]; then
        return 1
    fi

    if ! make -n test-e2e FORMAT=json >/dev/null 2>&1; then
        return 1
    fi

    log "${BLUE}Delegating to make test-e2e FORMAT=json...${NC}"

    # Build ARGS for passthrough
    local make_args=""
    [[ -n "$TEST_FILE" ]] && make_args="$TEST_FILE"
    [[ -n "$TEST_PATTERN" ]] && make_args="$make_args -g \"$TEST_PATTERN\""
    [[ -n "$TEST_HEADED" ]] && make_args="$make_args --headed"
    [[ -n "$TEST_DEBUG" ]] && make_args="$make_args --debug"
    [[ -n "$TEST_BROWSER" ]] && make_args="$make_args --project=$TEST_BROWSER"

    local make_output
    local make_exit=0
    make_output=$(make test-e2e FORMAT=json ARGS="$make_args" 2>&1) || make_exit=$?

    echo "$make_output"
    exit $make_exit
}

section_validate() {
    log "${BLUE}Validating E2E Test Environment${NC}"
    local running_services
    if ! running_services=$(docker compose ps --filter "status=running" --format "{{.Name}}" 2>/dev/null); then
        exit_with_json "error" "Docker Compose not available" "Install Docker Compose v2."
    fi
    if [[ -z "$running_services" ]]; then
        exit_with_json "error" "Docker services not running" "Run: make up or docker compose up -d"
    fi
    log "${GREEN}✓${NC} Docker services running"
    if [[ "$SECTION" == "validate" ]]; then
        local services_json=$(echo "$running_services" | jq -R . | jq -s .)
        exit_with_json "success" "Environment validation complete" "" "\"running_services\":$services_json"
    fi
}

section_detect() {
    log "${BLUE}Detecting E2E Test Framework${NC}"
    if [[ -f "PROJECT.yaml" ]]; then
        local e2e_command
        if e2e_command=$(yaml_get '.testing.e2e_command' PROJECT.yaml) && [[ -n "$e2e_command" && "$e2e_command" != "null" ]]; then
            DETECTED_COMMAND="$e2e_command"; DETECTED_FRAMEWORK="custom"; SERVICE_NAME="frontend"
            [[ "$e2e_command" == *"playwright"* ]] && DETECTED_FRAMEWORK="playwright"
            [[ "$e2e_command" == *"cypress"* ]] && { DETECTED_FRAMEWORK="cypress"; }
            [[ "$e2e_command" == *"pytest"* ]] && { DETECTED_FRAMEWORK="pytest"; SERVICE_NAME="backend"; }
            [[ "$SECTION" == "detect" ]] && exit_with_json "success" "Framework detected from PROJECT.yaml" "" "\"framework\":\"$DETECTED_FRAMEWORK\",\"command\":\"$DETECTED_COMMAND\",\"service\":\"$SERVICE_NAME\""
            return 0
        fi
    fi
    if [[ -f "package.json" ]]; then
        grep -q '"playwright"' package.json 2>/dev/null && { DETECTED_FRAMEWORK="playwright"; DETECTED_COMMAND="npx playwright test"; SERVICE_NAME="frontend"; }
        grep -q '"cypress"' package.json 2>/dev/null && { DETECTED_FRAMEWORK="cypress"; DETECTED_COMMAND="npx cypress run"; SERVICE_NAME="frontend"; }
    fi
    if [[ -z "$DETECTED_FRAMEWORK" ]]; then
        [[ -f "playwright.config.ts" || -f "playwright.config.js" ]] && { DETECTED_FRAMEWORK="playwright"; DETECTED_COMMAND="npx playwright test"; SERVICE_NAME="frontend"; }
        [[ -f "cypress.config.js" || -f "cypress.json" ]] && { DETECTED_FRAMEWORK="cypress"; DETECTED_COMMAND="npx cypress run"; SERVICE_NAME="frontend"; }
    fi
    if [[ -f "pyproject.toml" ]] || [[ -f "requirements.txt" ]]; then
        grep -q "playwright" requirements.txt pyproject.toml 2>/dev/null && { DETECTED_FRAMEWORK="playwright-python"; DETECTED_COMMAND="pytest tests/e2e/"; SERVICE_NAME="backend"; }
    fi
    if [[ -z "$DETECTED_FRAMEWORK" ]]; then
        exit_with_json "error" "No E2E framework detected" "Add testing.e2e_command to PROJECT.yaml or install Playwright/Cypress"
    fi
    log "${GREEN}✓${NC} Detected: $DETECTED_FRAMEWORK"
    [[ "$SECTION" == "detect" ]] && exit_with_json "success" "Framework detected" "" "\"framework\":\"$DETECTED_FRAMEWORK\",\"command\":\"$DETECTED_COMMAND\",\"service\":\"$SERVICE_NAME\""
}

section_execute() {
    log "${BLUE}Executing E2E Tests${NC}"
    local target_env="${TEST_ENV:-local}"
    if [[ -z "$TEST_ENV" ]]; then
        local branch; branch=$(git branch --show-current 2>/dev/null || echo "")
        [[ "$branch" =~ ^(dev|staging)$ ]] && target_env="staging"
        [[ "$branch" =~ ^(prod|production|main)$ ]] && target_env="production"
    fi
    local test_command="$DETECTED_COMMAND"
    case "$DETECTED_FRAMEWORK" in
        playwright)
            [[ -n "$TEST_HEADED" ]] && test_command="$test_command --headed"
            [[ -n "$TEST_DEBUG" ]] && test_command="$test_command --debug"
            [[ -n "$TEST_BROWSER" ]] && test_command="$test_command --project=$TEST_BROWSER"
            [[ -n "$TEST_FILE" ]] && test_command="$test_command $TEST_FILE"
            [[ -n "$TEST_PATTERN" ]] && test_command="$test_command -g \"$TEST_PATTERN\""
            ;;
        playwright-python|selenium)
            [[ -n "$TEST_FILE" ]] && test_command="$test_command $TEST_FILE"
            [[ -n "$TEST_PATTERN" ]] && test_command="$test_command -k \"$TEST_PATTERN\""
            test_command="$test_command -v"
            ;;
        cypress)
            [[ -n "$TEST_HEADED" ]] && test_command="$test_command --headed --browser chrome"
            [[ -n "$TEST_FILE" ]] && test_command="$test_command --spec $TEST_FILE"
            ;;
    esac
    local test_output; local test_exit_code=0
    if [[ "$OUTPUT_MODE" == "raw" ]]; then
        docker compose exec -T "$SERVICE_NAME" bash -c "$test_command" || test_exit_code=$?
    else
        test_output=$(docker compose exec -T "$SERVICE_NAME" bash -c "$test_command" 2>&1) || test_exit_code=$?
    fi
    local passed=0 failed=0 total=0 duration=""
    if [[ "$test_exit_code" -eq 0 ]]; then
        [[ "$test_output" =~ ([0-9]+)\ passed.*\(([0-9]+[a-z]+)\) ]] && { passed="${BASH_REMATCH[1]}"; total="$passed"; duration="${BASH_REMATCH[2]}"; }
        exit_with_json "success" "All E2E tests passed" "" "\"framework\":\"$DETECTED_FRAMEWORK\",\"environment\":\"$target_env\",\"total_tests\":$total,\"passed\":$passed,\"failed\":0,\"duration\":\"$duration\""
    else
        [[ "${test_output:-}" =~ ([0-9]+)\ passed ]] && passed="${BASH_REMATCH[1]}"
        [[ "${test_output:-}" =~ ([0-9]+)\ failed ]] && failed="${BASH_REMATCH[1]}"
        total=$((passed + failed))
        exit_with_json "error" "E2E tests failed: $failed/$total" "" "\"framework\":\"$DETECTED_FRAMEWORK\",\"environment\":\"$target_env\",\"total_tests\":$total,\"passed\":$passed,\"failed\":$failed,\"test_output\":$(echo "${test_output:-}" | tail -50 | jq -Rs .)"
    fi
}

main() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --json) OUTPUT_MODE="json"; shift ;;
            --toon) OUTPUT_MODE="json"; OUTPUT_FORMAT="toon"; shift ;;
            --raw) OUTPUT_MODE="raw"; shift ;;
            --validate) SECTION="validate"; shift ;;
            --detect) SECTION="detect"; shift ;;
            --execute) SECTION="execute"; shift ;;
            --full) SECTION="full"; shift ;;
            --headed|-h) TEST_HEADED="true"; shift ;;
            --debug|-d) TEST_DEBUG="true"; shift ;;
            --browser) TEST_BROWSER="$2"; shift 2 ;;
            --pattern) TEST_PATTERN="$2"; shift 2 ;;
            --file) TEST_FILE="$2"; shift 2 ;;
            --env) TEST_ENV="$2"; shift 2 ;;
            *) shift ;;
        esac
    done
    case "$SECTION" in
        validate) section_validate ;;
        detect) section_validate; section_detect ;;
        execute|full) try_make_e2e_delegation 2>/dev/null || { section_validate; section_detect; section_execute; } ;;
    esac
}

main "$@"
