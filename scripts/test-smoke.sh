#!/usr/bin/env bash
set -euo pipefail

# test-smoke.sh - Run project smoke tests with JSON output
#
# STANDARD SCRIPT PATTERN: Section flags with --json/--raw output modes
#
# Usage:
#   ~/.claude/scripts/test-smoke.sh [--json|--raw] [--full|--section]
#
# Output Modes:
#   --json: Structured JSON output for LLM (default)
#   --raw:  Verbose debugging output when LLM needs more details
#
# Section Flags (run specific section only):
#   --validate:  Validate smoke test setup exists
#   --execute:   Execute smoke tests
#   --full:      Validate + execute (default)
#
# Workflow:
#   1. LLM calls: script.sh --json --full
#   2. If tests pass: Returns JSON with success
#   3. If tests fail: Returns JSON with failed test details
#   4. If setup missing: Returns error with guidance
#
# Features:
#   - Validates smoke test infrastructure exists
#   - Runs project smoke tests
#   - Parses results from standard smoke-tests.sh format
#   - Returns structured results for LLM parsing

# Global variables
OUTPUT_MODE="json"
SECTION="full"
SMOKE_SCRIPT=""
TEST_RESULTS=""
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0
DURATION=0
TEST_STATUS=""
FAILED_TEST_NAMES=()

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/output-framework.sh"

#------------------------------------------------------------------------------
# Section Functions
#------------------------------------------------------------------------------

# Section 1: Validate smoke test setup
section_validate() {
    log "${BLUE}Validating Smoke Test Setup${NC}"

    # Check for smoke test script
    if [[ -f "./scripts/smoke-tests.sh" ]]; then
        SMOKE_SCRIPT="./scripts/smoke-tests.sh"
        log "${GREEN}✓${NC} Found smoke-tests.sh in ./scripts/"
    elif [[ -f "./smoke-tests.sh" ]]; then
        SMOKE_SCRIPT="./smoke-tests.sh"
        log "${GREEN}✓${NC} Found smoke-tests.sh in project root"
    else
        if [[ "$SECTION" == "validate" ]]; then
            local json=$(cat <<EOF
{
  "status": "error",
  "section": "validate",
  "message": "No smoke tests configured",
  "details": "Smoke test script not found at ./scripts/smoke-tests.sh or ./smoke-tests.sh",
  "next_steps": [
    "Run /test-smoke-eval to analyze project and suggest smoke tests",
    "Or create smoke tests manually following docs/testing-smoke.md"
  ],
  "timestamp": "$(date -Iseconds)"
}
EOF
)
            log_json "$json"
            exit 1
        else
            exit_with_json "error" "No smoke tests configured" "Run /test-smoke-eval to analyze coverage"
        fi
    fi

    # Check if services are running (docker compose ps)
    if command -v docker &>/dev/null; then
        if docker compose ps --format json 2>/dev/null | jq -e '.[].State == "running"' &>/dev/null; then
            log "${GREEN}✓${NC} Docker services are running"
        else
            if [[ "$SECTION" == "validate" ]]; then
                local json=$(cat <<EOF
{
  "status": "error",
  "section": "validate",
  "message": "Services not running",
  "details": "Docker Compose services are not running",
  "next_steps": [
    "Start services: make up",
    "Or: docker compose up -d",
    "Then retry smoke tests"
  ],
  "timestamp": "$(date -Iseconds)"
}
EOF
)
                log_json "$json"
                exit 1
            else
                exit_with_json "error" "Services not running" "Run 'make up' or 'docker compose up -d' first"
            fi
        fi
    fi

    # Validate script is executable
    if [[ ! -x "$SMOKE_SCRIPT" ]]; then
        log "${YELLOW}⚠${NC} Making smoke test script executable"
        chmod +x "$SMOKE_SCRIPT" 2>/dev/null || {
            exit_with_json "error" "Cannot make smoke test script executable" "Check permissions on $SMOKE_SCRIPT"
        }
    fi

    # If running only validation section, return now
    if [[ "$SECTION" == "validate" ]]; then
        local json=$(cat <<EOF
{
  "status": "success",
  "section": "validate",
  "message": "Smoke test setup validated",
  "smoke_script": "$SMOKE_SCRIPT",
  "services_running": true,
  "timestamp": "$(date -Iseconds)"
}
EOF
)
        log_json "$json"
        exit 0
    fi

    log "${GREEN}✓${NC} Validation complete"
}

# Section 2: Execute smoke tests
section_execute() {
    log "${BLUE}Executing Smoke Tests${NC}"

    # Run smoke tests and capture output
    local start_time=$(date +%s)
    local smoke_output
    local exit_code=0

    # Run the smoke test script with --output json flag
    if smoke_output=$("$SMOKE_SCRIPT" --output json 2>&1); then
        exit_code=0
        log "${GREEN}✓${NC} Smoke tests passed"
    else
        exit_code=$?
        log "${YELLOW}⚠${NC} Smoke tests completed with failures"
    fi

    local end_time=$(date +%s)
    DURATION=$((end_time - start_time))

    # Parse JSON output from smoke test script
    if echo "$smoke_output" | jq empty 2>/dev/null; then
        # Valid JSON output
        TEST_STATUS=$(echo "$smoke_output" | jq -r '.status // "unknown"')
        TOTAL_TESTS=$(echo "$smoke_output" | jq -r '.total_tests // 0')
        PASSED_TESTS=$(echo "$smoke_output" | jq -r '.passed // 0')
        FAILED_TESTS=$(echo "$smoke_output" | jq -r '.failed // 0')

        # Extract failed test names
        local failed_names
        failed_names=$(echo "$smoke_output" | jq -r '.failed_tests[]? // empty' 2>/dev/null || echo "")
        if [[ -n "$failed_names" ]]; then
            while IFS= read -r name; do
                FAILED_TEST_NAMES+=("$name")
            done <<< "$failed_names"
        fi

        TEST_RESULTS="$smoke_output"
    else
        # Not valid JSON - legacy format or error
        # Try to parse from plain text output
        TOTAL_TESTS=$(echo "$smoke_output" | sed -n 's/.*total_tests": \([0-9]\+\).*/\1/p' | head -1 || echo "0")
        PASSED_TESTS=$(echo "$smoke_output" | sed -n 's/.*passed": \([0-9]\+\).*/\1/p' | head -1 || echo "0")
        FAILED_TESTS=$(echo "$smoke_output" | sed -n 's/.*failed": \([0-9]\+\).*/\1/p' | head -1 || echo "0")

        if [[ "$exit_code" -eq 0 ]]; then
            TEST_STATUS="success"
        else
            TEST_STATUS="failure"
        fi

        # Build minimal JSON result
        TEST_RESULTS=$(cat <<EOF
{
  "action": "smoke_tests_complete",
  "status": "$TEST_STATUS",
  "total_tests": $TOTAL_TESTS,
  "passed": $PASSED_TESTS,
  "failed": $FAILED_TESTS,
  "duration_seconds": $DURATION
}
EOF
)
    fi

    # If running only execute section, return results now
    if [[ "$SECTION" == "execute" ]]; then
        local failed_list=""
        if [[ ${#FAILED_TEST_NAMES[@]} -gt 0 ]]; then
            failed_list=$(printf '"%s",' "${FAILED_TEST_NAMES[@]}")
            failed_list="[${failed_list%,}]"
        else
            failed_list="[]"
        fi

        local json=$(cat <<EOF
{
  "status": "$(if [[ "$TEST_STATUS" == "success" || "$FAILED_TESTS" -eq 0 ]]; then echo "success"; else echo "failure"; fi)",
  "section": "execute",
  "message": "Smoke tests completed: $PASSED_TESTS/$TOTAL_TESTS passed",
  "total_tests": $TOTAL_TESTS,
  "passed": $PASSED_TESTS,
  "failed": $FAILED_TESTS,
  "duration_seconds": $DURATION,
  "failed_tests": $failed_list,
  "test_results": $TEST_RESULTS,
  "timestamp": "$(date -Iseconds)"
}
EOF
)
        log_json "$json"
        exit $(if [[ "$FAILED_TESTS" -eq 0 ]]; then echo 0; else echo 1; fi)
    fi

    log "${GREEN}✓${NC} Tests execution complete"
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
            --execute) SECTION="execute"; shift ;;
            --full) SECTION="full"; shift ;;
            *) shift ;;
        esac
    done

    # Execute sections based on flag
    case "$SECTION" in
        validate)
            section_validate
            ;;
        execute)
            # Validate first (prerequisites)
            ORIGINAL_SECTION="$SECTION"
            SECTION="validate"
            section_validate
            SECTION="$ORIGINAL_SECTION"
            section_execute
            ;;
        full)
            section_validate
            section_execute

            # Full success - return complete results
            local failed_list=""
            if [[ ${#FAILED_TEST_NAMES[@]} -gt 0 ]]; then
                failed_list=$(printf '"%s",' "${FAILED_TEST_NAMES[@]}")
                failed_list="[${failed_list%,}]"
            else
                failed_list="[]"
            fi

            local final_status
            local final_message
            if [[ "$FAILED_TESTS" -eq 0 ]]; then
                final_status="success"
                final_message="All smoke tests passed: $PASSED_TESTS/$TOTAL_TESTS in ${DURATION}s"
            else
                final_status="failure"
                final_message="Smoke tests failed: $PASSED_TESTS/$TOTAL_TESTS passed in ${DURATION}s"
            fi

            local json=$(cat <<EOF
{
  "status": "$final_status",
  "message": "$final_message",
  "total_tests": $TOTAL_TESTS,
  "passed": $PASSED_TESTS,
  "failed": $FAILED_TESTS,
  "duration_seconds": $DURATION,
  "failed_tests": $failed_list,
  "test_results": $TEST_RESULTS,
  "timestamp": "$(date -Iseconds)"
}
EOF
)
            log_json "$json"
            exit $(if [[ "$FAILED_TESTS" -eq 0 ]]; then echo 0; else echo 1; fi)
            ;;
    esac
}

# Run main function
main "$@"
