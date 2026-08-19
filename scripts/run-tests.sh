#!/usr/bin/env bash
set -euo pipefail

_RUN_TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_RUN_TESTS_DIR}/lib/platform.sh"  # grep_op (portable grep -oP)

# run-tests.sh - Universal test runner for multiple frameworks
#
# Usage:
#   run-tests.sh [--type <bash|python|node|playwright|newman|all>] [--suite <name>] [--test <name>] [--verbose <0-3>]
#
# Supported Frameworks:
#   - BATS (bash) - Bash Automated Testing System
#   - pytest (Python) - Python testing framework
#   - Jest/Mocha (Node) - JavaScript testing frameworks
#   - Playwright (E2E) - End-to-end browser testing
#   - Newman (API) - Postman collection runner
#
# Output Modes:
#   --verbose 0: JSON only, minimal (default)
#   --verbose 1: JSON + summary
#   --verbose 2: JSON + summary + failed test details
#   --verbose 3: JSON + full test output
#
# JSON Output Format:
#   Success: {"status": "success", "suites": N, "tests": N, "skipped": 0}
#   Failure: {"status": "failure", "passed": N, "failed": N, "skipped": N, "failures": [{suite, test, error}]}
#
# Features:
#   - Selective execution: Run specific suite or test
#   - Quality enforcement: Fails on skipped/fake tests
#   - Debug workflow: Run failing tests with more verbosity
#   - Final validation: Re-run all tests after fixes

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Default parameters
TEST_TYPE="all"
SUITE_FILTER=""
TEST_FILTER=""
VERBOSITY=0

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --type)
            TEST_TYPE="$2"
            shift 2
            ;;
        --suite)
            SUITE_FILTER="$2"
            shift 2
            ;;
        --test)
            TEST_FILTER="$2"
            shift 2
            ;;
        --verbose)
            VERBOSITY="$2"
            shift 2
            ;;
        --help)
            grep '^#' "$0" | sed 's/^# //; s/^#//'
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

# Logging functions
log_verbose() {
    local level=$1
    shift
    if [[ $VERBOSITY -ge $level ]]; then
        echo -e "$@" >&2
    fi
}

# Framework detection
detect_frameworks() {
    local frameworks=()

    # BATS (Bash)
    if find . -name "*.bats" 2>/dev/null | grep -q .; then
        frameworks+=("bash")
    fi

    # pytest (Python)
    if [[ -f "pytest.ini" ]] || [[ -f "pyproject.toml" ]] || find . -name "test_*.py" 2>/dev/null | grep -q .; then
        frameworks+=("python")
    fi

    # Jest/Mocha (Node)
    if [[ -f "jest.config.js" ]] || [[ -f "package.json" ]]; then
        if grep -q "jest\|mocha" package.json 2>/dev/null; then
            frameworks+=("node")
        fi
    fi

    # Playwright (E2E)
    if [[ -f "playwright.config.js" ]] || [[ -f "playwright.config.ts" ]]; then
        frameworks+=("playwright")
    fi

    # Newman (API)
    if find . -name "*.postman_collection.json" 2>/dev/null | grep -q .; then
        frameworks+=("newman")
    fi

    echo "${frameworks[@]}"
}

# BATS test runner
run_bats_tests() {
    log_verbose 1 "${BLUE}Running BATS tests...${NC}"

    local bats_files=$(find . -name "*.bats" 2>/dev/null)
    if [[ -z "$bats_files" ]]; then
        return 0
    fi

    # Apply filters
    if [[ -n "$SUITE_FILTER" ]]; then
        bats_files=$(echo "$bats_files" | grep "$SUITE_FILTER" || true)
    fi

    if [[ -z "$bats_files" ]]; then
        return 0
    fi

    # Run BATS
    local output
    local exit_code=0

    if [[ -n "$TEST_FILTER" ]]; then
        # BATS doesn't support filtering individual tests easily
        # Run all tests in matching suites and filter output
        output=$(bats $bats_files 2>&1) || exit_code=$?
    else
        output=$(bats $bats_files 2>&1) || exit_code=$?
    fi

    # Parse BATS output
    local total_tests=$(echo "$output" | grep_op '^\d+\.\.\d+' | tail -1 | grep_op '\d+$')
    local passed=$(echo "$output" | grep -c '^ok' || echo 0)
    local failed=$(echo "$output" | grep -c '^not ok' || echo 0)
    local skipped=$(echo "$output" | grep -c '# skip' || echo 0)

    # Detect fake tests (tests that always pass without assertions)
    # Look for tests with no assertion keywords
    local fake_tests=$(grep -r "^@test" . --include="*.bats" | while read -r line; do
        local test_file=$(echo "$line" | cut -d: -f1)
        local test_name=$(echo "$line" | grep_op '@test "\K[^"]+')

        # Extract test body (simplified - would need better parsing)
        if ! grep -A 10 "@test \"$test_name\"" "$test_file" | grep -qE '\[\[|\[|assert|expect|run'; then
            echo "$test_file: $test_name (no assertions)"
        fi
    done)

    if [[ -n "$fake_tests" ]]; then
        echo "$fake_tests" >&2
        exit_code=1
        failed=$((failed + $(echo "$fake_tests" | wc -l)))
    fi

    # Enforce no skipped tests
    if [[ $skipped -gt 0 ]]; then
        log_verbose 1 "${YELLOW}⚠️  Skipped tests detected (${skipped}) - treating as failures${NC}"
        failed=$((failed + skipped))
        exit_code=1
    fi

    if [[ $VERBOSITY -ge 3 ]]; then
        echo "$output" >&2
    elif [[ $VERBOSITY -ge 2 ]] && [[ $failed -gt 0 ]]; then
        echo "$output" | grep "^not ok" >&2
    fi

    # Return results
    if [[ $exit_code -eq 0 ]]; then
        echo "bash|success|$passed|0|0"
    else
        # Extract failure details
        local failures=$(echo "$output" | grep "^not ok" | sed 's/^not ok //' || echo "")
        echo "bash|failure|$passed|$failed|$skipped|$failures"
    fi

    return $exit_code
}

# pytest test runner
run_pytest_tests() {
    log_verbose 1 "${BLUE}Running pytest tests...${NC}"

    if ! command -v pytest &>/dev/null; then
        log_verbose 1 "${YELLOW}pytest not found, skipping Python tests${NC}"
        return 0
    fi

    # Build pytest command
    local pytest_cmd="pytest --tb=short -v"

    # JSON output for parsing
    pytest_cmd="$pytest_cmd --json-report --json-report-file=/tmp/pytest-report.json"

    # Apply filters
    if [[ -n "$SUITE_FILTER" ]]; then
        pytest_cmd="$pytest_cmd $SUITE_FILTER"
    fi

    if [[ -n "$TEST_FILTER" ]]; then
        pytest_cmd="$pytest_cmd -k $TEST_FILTER"
    fi

    # Run pytest
    local output
    local exit_code=0
    output=$(eval $pytest_cmd 2>&1) || exit_code=$?

    # Parse JSON report
    if [[ -f "/tmp/pytest-report.json" ]]; then
        local total=$(jq -r '.summary.total' /tmp/pytest-report.json)
        local passed=$(jq -r '.summary.passed // 0' /tmp/pytest-report.json)
        local failed=$(jq -r '.summary.failed // 0' /tmp/pytest-report.json)
        local skipped=$(jq -r '.summary.skipped // 0' /tmp/pytest-report.json)

        # Enforce no skipped tests
        if [[ $skipped -gt 0 ]]; then
            log_verbose 1 "${YELLOW}⚠️  Skipped tests detected (${skipped}) - treating as failures${NC}"
            failed=$((failed + skipped))
            exit_code=1
        fi

        if [[ $VERBOSITY -ge 3 ]]; then
            echo "$output" >&2
        elif [[ $VERBOSITY -ge 2 ]] && [[ $failed -gt 0 ]]; then
            jq -r '.tests[] | select(.outcome == "failed") | "\(.nodeid): \(.call.longrepr)"' /tmp/pytest-report.json >&2
        fi

        # Return results
        if [[ $exit_code -eq 0 ]]; then
            echo "python|success|$passed|0|0"
        else
            local failures=$(jq -c '.tests[] | select(.outcome == "failed") | {suite: .nodeid | split("::")[0], test: .nodeid | split("::")[1], error: .call.longrepr}' /tmp/pytest-report.json)
            echo "python|failure|$passed|$failed|$skipped|$failures"
        fi
    else
        # Fallback: parse text output
        echo "python|failure|0|1|0|Could not parse pytest output"
        exit_code=1
    fi

    return $exit_code
}

# Jest/Mocha test runner
run_node_tests() {
    log_verbose 1 "${BLUE}Running Node tests...${NC}"

    if [[ ! -f "package.json" ]]; then
        return 0
    fi

    # Determine test command
    local test_cmd=$(jq -r '.scripts.test // "npm test"' package.json)

    # Build command with filters
    if [[ -n "$TEST_FILTER" ]]; then
        test_cmd="$test_cmd --testNamePattern='$TEST_FILTER'"
    fi

    if [[ -n "$SUITE_FILTER" ]]; then
        test_cmd="$test_cmd --testPathPattern='$SUITE_FILTER'"
    fi

    # Add JSON output
    test_cmd="$test_cmd --json --outputFile=/tmp/jest-report.json"

    # Run tests
    local output
    local exit_code=0
    output=$(eval $test_cmd 2>&1) || exit_code=$?

    # Parse JSON report
    if [[ -f "/tmp/jest-report.json" ]]; then
        local total=$(jq -r '.numTotalTests' /tmp/jest-report.json)
        local passed=$(jq -r '.numPassedTests' /tmp/jest-report.json)
        local failed=$(jq -r '.numFailedTests' /tmp/jest-report.json)
        local skipped=$(jq -r '.numPendingTests' /tmp/jest-report.json)

        # Enforce no skipped tests
        if [[ $skipped -gt 0 ]]; then
            log_verbose 1 "${YELLOW}⚠️  Skipped tests detected (${skipped}) - treating as failures${NC}"
            failed=$((failed + skipped))
            exit_code=1
        fi

        if [[ $VERBOSITY -ge 3 ]]; then
            echo "$output" >&2
        elif [[ $VERBOSITY -ge 2 ]] && [[ $failed -gt 0 ]]; then
            jq -r '.testResults[] | .assertionResults[] | select(.status == "failed") | "\(.ancestorTitles | join(" > ")) > \(.title): \(.failureMessages[])"' /tmp/jest-report.json >&2
        fi

        # Return results
        if [[ $exit_code -eq 0 ]]; then
            echo "node|success|$passed|0|0"
        else
            local failures=$(jq -c '.testResults[] | .assertionResults[] | select(.status == "failed") | {suite: .ancestorTitles | join(" > "), test: .title, error: .failureMessages[0]}' /tmp/jest-report.json)
            echo "node|failure|$passed|$failed|$skipped|$failures"
        fi
    else
        echo "node|failure|0|1|0|Could not parse test output"
        exit_code=1
    fi

    return $exit_code
}

# Playwright test runner
run_playwright_tests() {
    log_verbose 1 "${BLUE}Running Playwright tests...${NC}"

    if ! command -v npx playwright &>/dev/null; then
        log_verbose 1 "${YELLOW}Playwright not found, skipping E2E tests${NC}"
        return 0
    fi

    # Build command
    local pw_cmd="npx playwright test"

    if [[ -n "$TEST_FILTER" ]]; then
        pw_cmd="$pw_cmd --grep '$TEST_FILTER'"
    fi

    if [[ -n "$SUITE_FILTER" ]]; then
        pw_cmd="$pw_cmd $SUITE_FILTER"
    fi

    # Add JSON reporter
    pw_cmd="$pw_cmd --reporter=json"

    # Run tests
    local output
    local exit_code=0
    output=$(eval $pw_cmd 2>&1) || exit_code=$?

    # Parse output (Playwright JSON format)
    local passed=$(echo "$output" | jq -r '.suites[].specs[].tests[] | select(.status == "passed") | .title' | wc -l)
    local failed=$(echo "$output" | jq -r '.suites[].specs[].tests[] | select(.status == "failed") | .title' | wc -l)
    local skipped=$(echo "$output" | jq -r '.suites[].specs[].tests[] | select(.status == "skipped") | .title' | wc -l)

    # Enforce no skipped tests
    if [[ $skipped -gt 0 ]]; then
        log_verbose 1 "${YELLOW}⚠️  Skipped tests detected (${skipped}) - treating as failures${NC}"
        failed=$((failed + skipped))
        exit_code=1
    fi

    if [[ $VERBOSITY -ge 3 ]]; then
        echo "$output" >&2
    elif [[ $VERBOSITY -ge 2 ]] && [[ $failed -gt 0 ]]; then
        echo "$output" | jq -r '.suites[].specs[].tests[] | select(.status == "failed") | "\(.title): \(.results[0].error.message)"' >&2
    fi

    # Return results
    if [[ $exit_code -eq 0 ]]; then
        echo "playwright|success|$passed|0|0"
    else
        local failures=$(echo "$output" | jq -c '.suites[].specs[].tests[] | select(.status == "failed") | {suite: .location.file, test: .title, error: .results[0].error.message}')
        echo "playwright|failure|$passed|$failed|$skipped|$failures"
    fi

    return $exit_code
}

# Newman test runner
run_newman_tests() {
    log_verbose 1 "${BLUE}Running Newman API tests...${NC}"

    if ! command -v newman &>/dev/null; then
        log_verbose 1 "${YELLOW}Newman not found, skipping API tests${NC}"
        return 0
    fi

    # Find Postman collections
    local collections=$(find . -name "*.postman_collection.json")

    if [[ -z "$collections" ]]; then
        return 0
    fi

    # Apply suite filter
    if [[ -n "$SUITE_FILTER" ]]; then
        collections=$(echo "$collections" | grep "$SUITE_FILTER" || true)
    fi

    if [[ -z "$collections" ]]; then
        return 0
    fi

    # Run each collection
    local total_passed=0
    local total_failed=0
    local total_skipped=0
    local all_failures=""

    for collection in $collections; do
        log_verbose 2 "Running collection: $(basename "$collection")"

        # Build Newman command
        local newman_cmd="newman run $collection --reporters cli,json --reporter-json-export /tmp/newman-report.json"

        # Run Newman
        local output
        local exit_code=0
        output=$(eval $newman_cmd 2>&1) || exit_code=$?

        # Parse JSON report
        if [[ -f "/tmp/newman-report.json" ]]; then
            local passed=$(jq -r '.run.stats.tests.passed' /tmp/newman-report.json)
            local failed=$(jq -r '.run.stats.tests.failed' /tmp/newman-report.json)
            local skipped=$(jq -r '.run.stats.tests.pending // 0' /tmp/newman-report.json)

            total_passed=$((total_passed + passed))
            total_failed=$((total_failed + failed))
            total_skipped=$((total_skipped + skipped))

            if [[ $failed -gt 0 ]] && [[ $VERBOSITY -ge 2 ]]; then
                jq -r '.run.executions[] | select(.assertions[]? | select(.error)) | "\(.item.name): \(.assertions[] | select(.error) | .assertion + " - " + .error.message)"' /tmp/newman-report.json >&2
            fi

            if [[ $failed -gt 0 ]]; then
                local collection_failures=$(jq -c '.run.executions[] | select(.assertions[]? | select(.error)) | {suite: .item.name, test: .assertions[] | select(.error) | .assertion, error: .error.message}' /tmp/newman-report.json)
                all_failures="$all_failures $collection_failures"
            fi
        fi
    done

    # Enforce no skipped tests
    if [[ $total_skipped -gt 0 ]]; then
        log_verbose 1 "${YELLOW}⚠️  Skipped tests detected (${total_skipped}) - treating as failures${NC}"
        total_failed=$((total_failed + total_skipped))
    fi

    if [[ $VERBOSITY -ge 3 ]]; then
        echo "$output" >&2
    fi

    # Return results
    local exit_code=0
    if [[ $total_failed -gt 0 ]]; then
        exit_code=1
    fi

    if [[ $exit_code -eq 0 ]]; then
        echo "newman|success|$total_passed|0|0"
    else
        echo "newman|failure|$total_passed|$total_failed|$total_skipped|$all_failures"
    fi

    return $exit_code
}

# Main orchestration
main() {
    local frameworks=()

    # Determine which frameworks to run
    if [[ "$TEST_TYPE" == "all" ]]; then
        frameworks=($(detect_frameworks))
    else
        frameworks=("$TEST_TYPE")
    fi

    log_verbose 1 "${BLUE}Detected frameworks: ${frameworks[*]}${NC}"

    # Aggregate results
    local total_suites=0
    local total_passed=0
    local total_failed=0
    local total_skipped=0
    local all_failures=()
    local overall_exit=0

    # Run each framework
    for framework in "${frameworks[@]}"; do
        local result=""
        case "$framework" in
            bash)
                result=$(run_bats_tests) || overall_exit=1
                ;;
            python)
                result=$(run_pytest_tests) || overall_exit=1
                ;;
            node)
                result=$(run_node_tests) || overall_exit=1
                ;;
            playwright)
                result=$(run_playwright_tests) || overall_exit=1
                ;;
            newman)
                result=$(run_newman_tests) || overall_exit=1
                ;;
        esac

        if [[ -n "$result" ]]; then
            IFS='|' read -r fw status passed failed skipped failures <<< "$result"
            total_suites=$((total_suites + 1))
            total_passed=$((total_passed + passed))
            total_failed=$((total_failed + failed))
            total_skipped=$((total_skipped + skipped))

            if [[ "$status" == "failure" ]] && [[ -n "$failures" ]]; then
                all_failures+=("$failures")
            fi
        fi
    done

    # Generate JSON output
    if [[ $overall_exit -eq 0 ]]; then
        cat <<EOF
{
  "status": "success",
  "suites": $total_suites,
  "tests": $total_passed,
  "skipped": 0
}
EOF
    else
        local failures_json="["
        local first=true
        for failure in "${all_failures[@]}"; do
            if [[ "$first" == true ]]; then
                first=false
            else
                failures_json="$failures_json,"
            fi
            failures_json="$failures_json$failure"
        done
        failures_json="$failures_json]"

        cat <<EOF
{
  "status": "failure",
  "passed": $total_passed,
  "failed": $total_failed,
  "skipped": $total_skipped,
  "failures": $failures_json
}
EOF
    fi

    # Summary output if verbose
    if [[ $VERBOSITY -ge 1 ]]; then
        if [[ $overall_exit -eq 0 ]]; then
            log_verbose 1 "${GREEN}✓ All tests passed${NC} (${total_passed} tests across ${total_suites} suites)"
        else
            log_verbose 1 "${RED}✗ Tests failed${NC} (${total_passed} passed, ${total_failed} failed, ${total_skipped} skipped)"
        fi
    fi

    exit $overall_exit
}

main
