#!/usr/bin/env bash
# test-diagnose.sh - Multi-framework test failure diagnosis
#
# STANDARD SCRIPT PATTERN: Section flags with --json/--raw output modes
#
# Usage:
#   ~/.claude/scripts/test-diagnose.sh [--json|--raw] --service <svc> [--file <f>] [--grep <pat>]
#
# Auto-detects test framework (pytest/vitest/playwright) and runs tests
# with structured output parsing. Categorizes failures for targeted fixes.
#
# Output Modes:
#   --json: Structured output for LLM, default (TOON when the caller is an AI agent, JSON otherwise)
#   --raw:  Verbose debugging output
#
# Workflow:
#   1. LLM calls: test-diagnose.sh --json --service api
#   2. Returns categorized failures with fix suggestions
#   3. LLM fixes root cause, re-runs (max 3 retries)

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Global variables
OUTPUT_MODE="json"
SERVICE=""
FILE_FILTER=""
GREP_FILTER=""
FRAMEWORK=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/platform.sh"  # grep_op (portable grep -oP)

#------------------------------------------------------------------------------
# Make delegation - use Makefile when available
#------------------------------------------------------------------------------

try_make_delegation() {
    # Check if a Makefile with FORMAT=json support exists
    if [[ ! -f "Makefile" ]]; then
        return 1
    fi

    if ! make -n test FORMAT=json >/dev/null 2>&1; then
        return 1
    fi

    log "${BLUE}Delegating to make test FORMAT=json...${NC}"

    # Build ARGS for passthrough
    local make_args="--tb=short -q"
    [[ -n "$FILE_FILTER" ]] && make_args="$make_args $FILE_FILTER"
    [[ -n "$GREP_FILTER" ]] && make_args="$make_args -k \"$GREP_FILTER\""

    local make_output
    local make_exit=0
    make_output=$(make test FORMAT=json ARGS="$make_args" 2>&1) || make_exit=$?

    # The make output already has structured JSON from make-json-wrapper.sh
    # Add failure categorization on top if there are failures
    if [[ $make_exit -ne 0 ]] && echo "$make_output" | grep -q '"failed"'; then
        # Output the make result directly — it already has the right structure
        echo "$make_output"
    else
        echo "$make_output"
    fi
    exit $make_exit
}

#------------------------------------------------------------------------------
# Helper Functions
#------------------------------------------------------------------------------

log() {
    if [[ "$OUTPUT_MODE" == "raw" ]]; then
        echo -e "$@" >&2
    fi
}

output_json() {
    local status="$1"
    local next_action="$2"
    local message="$3"
    shift 3
    local extra_fields="$*"

    local json_base
    json_base=$(cat <<EOF
{
  "status": "$status",
  "next_action": "$next_action",
  "message": "$message",
  "framework": "$FRAMEWORK",
  "timestamp": "$(date -Iseconds)"
EOF
)

    if [[ -n "$extra_fields" ]]; then
        json_base="${json_base},
  ${extra_fields}
}"
    else
        json_base="${json_base}
}"
    fi

    echo "$json_base"
}

#------------------------------------------------------------------------------
# Detect test framework
#------------------------------------------------------------------------------

detect_framework() {
    # Check PROJECT.yaml first
    if [[ -f "PROJECT.yaml" ]]; then
        local stack
        stack=$(grep -A5 'tech_stack:' PROJECT.yaml 2>/dev/null || true)
        if echo "$stack" | grep -qi 'playwright'; then
            echo "playwright"
            return
        fi
        if echo "$stack" | grep -qi 'vitest\|jest'; then
            echo "vitest"
            return
        fi
        if echo "$stack" | grep -qi 'pytest'; then
            echo "pytest"
            return
        fi
    fi

    # File-based detection
    if [[ -f "playwright.config.ts" ]] || [[ -f "playwright.config.js" ]]; then
        echo "playwright"
    elif [[ -f "vitest.config.ts" ]] || [[ -f "vitest.config.js" ]] || [[ -f "jest.config.ts" ]] || [[ -f "jest.config.js" ]]; then
        echo "vitest"
    elif [[ -f "pytest.ini" ]] || [[ -f "pyproject.toml" ]] || [[ -f "setup.cfg" ]] || [[ -f "conftest.py" ]]; then
        echo "pytest"
    else
        echo "unknown"
    fi
}

#------------------------------------------------------------------------------
# Categorize pytest errors
#------------------------------------------------------------------------------

categorize_pytest_error() {
    local error_msg="$1"

    if echo "$error_msg" | grep -qi "ModuleNotFoundError\|ImportError\|No module"; then
        echo "import_error"
    elif echo "$error_msg" | grep -qi "AssertionError\|assert\|assertEqual\|!=\|=="; then
        echo "assertion_mismatch"
    elif echo "$error_msg" | grep -qi "TimeoutError\|timeout\|timed out"; then
        echo "timeout"
    elif echo "$error_msg" | grep -qi "ConnectionError\|ConnectionRefused\|ECONNREFUSED"; then
        echo "connection_error"
    elif echo "$error_msg" | grep -qi "TypeError\|ValueError\|KeyError\|AttributeError"; then
        echo "runtime_error"
    else
        echo "unknown"
    fi
}

#------------------------------------------------------------------------------
# Run pytest
#------------------------------------------------------------------------------

run_pytest() {
    local cmd="python -m pytest --tb=short -q"

    if [[ -n "$FILE_FILTER" ]]; then
        cmd="$cmd $FILE_FILTER"
    fi

    if [[ -n "$GREP_FILTER" ]]; then
        cmd="$cmd -k \"$GREP_FILTER\""
    fi

    log "${BLUE}Running: $cmd${NC}"

    local raw_output
    local exit_code=0
    raw_output=$("${SCRIPT_DIR}/docker-exec.sh" -s "$SERVICE" -- sh -c "$cmd 2>&1") || exit_code=$?

    # Parse pytest output
    local passed=0 failed=0 errors=0 total=0

    # Extract summary line like "5 passed, 2 failed, 1 error in 3.45s"
    local summary_line
    summary_line=$(echo "$raw_output" | grep -E '^\s*(=+|FAILED|PASSED|ERROR)' | tail -1 || true)
    if [[ -z "$summary_line" ]]; then
        summary_line=$(echo "$raw_output" | tail -5 | grep -E '[0-9]+ (passed|failed|error)' || true)
    fi

    passed=$(echo "$summary_line" | grep_op '\d+(?= passed)' || echo "0")
    failed=$(echo "$summary_line" | grep_op '\d+(?= failed)' || echo "0")
    errors=$(echo "$summary_line" | grep_op '\d+(?= error)' || echo "0")
    total=$((passed + failed + errors))

    # Extract failure details
    local failures_json="["
    local first=true

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue

        # Lines like "FAILED tests/test_foo.py::test_bar - AssertionError: ..."
        if [[ "$line" =~ ^FAILED[[:space:]]+(.+)[[:space:]]+-[[:space:]]+(.+) ]]; then
            local test_id="${BASH_REMATCH[1]}"
            local error_msg="${BASH_REMATCH[2]}"
            error_msg="${error_msg//\"/\\\"}"
            local category
            category=$(categorize_pytest_error "$error_msg")

            if [[ "$first" == "true" ]]; then
                first=false
            else
                failures_json="${failures_json}, "
            fi
            failures_json="${failures_json}{\"test\": \"${test_id}\", \"error\": \"${error_msg}\", \"category\": \"${category}\"}"
        fi
    done <<< "$(echo "$raw_output" | grep '^FAILED ')"

    # Also check for lines in short traceback format
    if [[ "$first" == "true" ]] && [[ $exit_code -ne 0 ]]; then
        # No FAILED lines found but tests failed — extract from short traceback
        local current_test=""
        while IFS= read -r line; do
            if [[ "$line" =~ ^___+[[:space:]](.+)[[:space:]]___+ ]]; then
                current_test="${BASH_REMATCH[1]}"
            elif [[ -n "$current_test" ]] && [[ "$line" =~ ^E[[:space:]]+(.+) ]]; then
                local error_msg="${BASH_REMATCH[1]}"
                error_msg="${error_msg//\"/\\\"}"
                local category
                category=$(categorize_pytest_error "$error_msg")

                if [[ "$first" == "true" ]]; then
                    first=false
                else
                    failures_json="${failures_json}, "
                fi
                failures_json="${failures_json}{\"test\": \"${current_test}\", \"error\": \"${error_msg}\", \"category\": \"${category}\"}"
                current_test=""
            fi
        done <<< "$raw_output"
    fi

    failures_json="${failures_json}]"

    if [[ $exit_code -eq 0 ]]; then
        output_json "success" "display_summary" "All $passed tests passed" \
            "\"passed\": $passed, \"failed\": 0, \"failures\": []"
    elif [[ $failed -eq 0 ]] && [[ $errors -gt 0 ]]; then
        output_json "error" "fix_error" "$errors collection errors (infrastructure issue)" \
            "\"passed\": $passed, \"failed\": $failed, \"errors\": $errors, \"failures\": $failures_json"
    else
        output_json "failure" "fix_failures" "$failed of $total tests failed" \
            "\"passed\": $passed, \"failed\": $failed, \"failures\": $failures_json"
    fi
}

#------------------------------------------------------------------------------
# Run vitest/jest
#------------------------------------------------------------------------------

run_vitest() {
    local cmd="npx vitest run --reporter=json"

    if [[ -n "$FILE_FILTER" ]]; then
        cmd="$cmd $FILE_FILTER"
    fi

    if [[ -n "$GREP_FILTER" ]]; then
        cmd="$cmd -t \"$GREP_FILTER\""
    fi

    log "${BLUE}Running: $cmd${NC}"

    local raw_output
    local exit_code=0
    raw_output=$("${SCRIPT_DIR}/docker-exec.sh" -s "$SERVICE" -- sh -c "$cmd 2>&1") || exit_code=$?

    # Try to extract JSON from output (vitest may prefix with non-JSON lines)
    local json_output
    json_output=$(echo "$raw_output" | sed -n '/^{/,/^}/p' | head -1)

    if [[ -z "$json_output" ]] || ! echo "$json_output" | python3 -m json.tool > /dev/null 2>&1; then
        # Fallback: parse text output
        local escaped_output
        escaped_output=$(echo "$raw_output" | tail -30 | sed 's/"/\\"/g' | tr '\n' ' ')
        if [[ $exit_code -eq 0 ]]; then
            output_json "success" "display_summary" "Tests passed" \
                "\"raw_output\": \"${escaped_output}\""
        else
            output_json "failure" "fix_failures" "Tests failed (could not parse JSON)" \
                "\"raw_output\": \"${escaped_output}\""
        fi
        return
    fi

    # Parse vitest JSON
    local results
    results=$(echo "$json_output" | python3 -c "
import sys, json
r = json.load(sys.stdin)
passed = r.get('numPassedTests', 0)
failed = r.get('numFailedTests', 0)
failures = []
for suite in r.get('testResults', []):
    for test in suite.get('assertionResults', []):
        if test.get('status') == 'failed':
            err = ' '.join(test.get('failureMessages', []))[:300]
            cat = 'unknown'
            err_lower = err.lower()
            if 'import' in err_lower or 'module' in err_lower or 'cannot find' in err_lower:
                cat = 'import_error'
            elif 'expect' in err_lower or 'tobe' in err_lower or 'assert' in err_lower:
                cat = 'assertion_mismatch'
            elif 'timeout' in err_lower:
                cat = 'timeout'
            elif 'econnrefused' in err_lower or 'network' in err_lower:
                cat = 'connection_error'
            elif 'typeerror' in err_lower or 'referenceerror' in err_lower:
                cat = 'runtime_error'
            failures.append({
                'test': test.get('fullName', test.get('title', '')),
                'file': suite.get('name', ''),
                'error': err.replace('\"', '\\\\\"'),
                'category': cat
            })
print(json.dumps({'passed': passed, 'failed': failed, 'failures': failures}))
" 2>/dev/null)

    if [[ -z "$results" ]]; then
        output_json "error" "fix_error" "Could not parse vitest output"
        return
    fi

    local passed failed failures_json
    passed=$(echo "$results" | python3 -c "import sys,json; print(json.load(sys.stdin)['passed'])")
    failed=$(echo "$results" | python3 -c "import sys,json; print(json.load(sys.stdin)['failed'])")
    failures_json=$(echo "$results" | python3 -c "import sys,json; print(json.dumps(json.load(sys.stdin)['failures']))")

    if [[ "$failed" -eq 0 ]]; then
        output_json "success" "display_summary" "All $passed tests passed" \
            "\"passed\": $passed, \"failed\": 0, \"failures\": []"
    else
        output_json "failure" "fix_failures" "$failed of $((passed + failed)) tests failed" \
            "\"passed\": $passed, \"failed\": $failed, \"failures\": $failures_json"
    fi
}

#------------------------------------------------------------------------------
# Parse Arguments
#------------------------------------------------------------------------------

while [[ $# -gt 0 ]]; do
    case "$1" in
        --json) OUTPUT_MODE="json"; shift ;;
            --toon) OUTPUT_MODE="json"; OUTPUT_FORMAT="toon"; shift ;;
        --raw) OUTPUT_MODE="raw"; shift ;;
        --service|-s) SERVICE="$2"; shift 2 ;;
        --file) FILE_FILTER="$2"; shift 2 ;;
        --grep) GREP_FILTER="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: $0 [--json|--raw] --service <svc> [--file <f>] [--grep <pat>]"
            exit 0
            ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "$SERVICE" ]]; then
    echo "Error: --service is required" >&2
    exit 1
fi

#------------------------------------------------------------------------------
# Main
#------------------------------------------------------------------------------

# Try make delegation first
try_make_delegation 2>/dev/null || true

# Detect framework
FRAMEWORK=$(detect_framework)
log "${BLUE}Detected framework: $FRAMEWORK${NC}"

case "$FRAMEWORK" in
    playwright)
        "${SCRIPT_DIR}/playwright-diagnose.sh" \
            --"$OUTPUT_MODE" \
            --service "$SERVICE" \
            ${FILE_FILTER:+--file "$FILE_FILTER"} \
            ${GREP_FILTER:+--grep "$GREP_FILTER"}
        ;;
    pytest)
        run_pytest
        ;;
    vitest)
        run_vitest
        ;;
    *)
        output_json "error" "fix_error" "Could not detect test framework" \
            "\"hint\": \"Ensure pytest.ini, vitest.config.ts, or playwright.config.ts exists\""
        exit 1
        ;;
esac
