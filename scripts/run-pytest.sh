#!/usr/bin/env bash
set -euo pipefail

# Run Python tests via pytest and return structured JSON results for LLM consumption
#
# Usage:
#   run-pytest.sh [--json|--raw] [--files "file1.py file2.py"] [--filter "pattern"]
#
# --json:   Return structured JSON with test counts and failure details
# --raw:    Pass through raw pytest output (for debugging)
# --files:  Space-separated list of specific test files to run
# --filter: Only run tests matching this pattern (pytest -k)
#
# JSON output format matches run-bats.sh contract:
# {
#   "status": "pass|fail",
#   "suites": 5,
#   "tests": 42,
#   "passed": 40,
#   "failed": 2,
#   "skipped": 0,
#   "warnings": 0,
#   "duration_seconds": 8,
#   "failures": [
#     {"suite": "test_validate_project.py", "test": "test_bad_syntax", "message": "AssertionError: ..."}
#   ],
#   "warning_messages": []
# }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="${SCRIPT_DIR}/tests"

FORMAT="json"
FILES=""
FILTER=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --json) FORMAT="json"; shift ;;
        --raw) FORMAT="raw"; shift ;;
        --files) FILES="$2"; shift 2 ;;
        --filter) FILTER="$2"; shift 2 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done

# Determine test targets
TARGETS=()
if [[ -n "$FILES" ]]; then
    for f in $FILES; do
        if [[ "$f" == /* ]]; then
            TARGETS+=("$f")
        elif [[ "$f" == */* ]]; then
            TARGETS+=("$f")
        else
            TARGETS+=("${TESTS_DIR}/$f")
        fi
    done
else
    # All test_*.py and test-*.py files
    while IFS= read -r f; do
        TARGETS+=("$f")
    done < <(find "${TESTS_DIR}" -maxdepth 1 \( -name "test_*.py" -o -name "test-*.py" \) -type f 2>/dev/null | sort)
fi

if [[ ${#TARGETS[@]} -eq 0 ]]; then
    if [[ "$FORMAT" == "json" ]]; then
        echo '{"status":"pass","suites":0,"tests":0,"passed":0,"failed":0,"skipped":0,"warnings":0,"duration_seconds":0,"failures":[],"warning_messages":["No Python test files found"]}'
    else
        echo "No Python test files found in ${TESTS_DIR}" >&2
    fi
    exit 0
fi

# Build pytest command via uv
PYTEST_ARGS=()
if [[ -n "$FILTER" ]]; then
    PYTEST_ARGS+=(-k "$FILTER")
fi

# Determine runner
RUNNER=""
if command -v uv &>/dev/null; then
    RUNNER="uv"
fi

if [[ "$FORMAT" == "raw" ]]; then
    if [[ "$RUNNER" == "uv" ]]; then
        exec uv run \
            --with pytest \
            --with pyyaml \
            --with 'jsonschema[format]' \
            --quiet \
            python -m pytest \
            --tb=short -v \
            "${PYTEST_ARGS[@]}" \
            "${TARGETS[@]}"
    else
        exec python3 -m pytest --tb=short -v "${PYTEST_ARGS[@]}" "${TARGETS[@]}"
    fi
fi

# JSON mode: run pytest with JSON output plugin or parse TAP-like output
START_TIME=$(date +%s)
PYTEST_OUTPUT=""
PYTEST_EXIT=0

if [[ "$RUNNER" == "uv" ]]; then
    PYTEST_OUTPUT=$(uv run \
        --with pytest \
        --with pyyaml \
        --with 'jsonschema[format]' \
        --quiet \
        python -m pytest \
        --tb=line -q \
        "${PYTEST_ARGS[@]}" \
        "${TARGETS[@]}" 2>&1) || PYTEST_EXIT=$?
else
    PYTEST_OUTPUT=$(python3 -m pytest --tb=line -q "${PYTEST_ARGS[@]}" "${TARGETS[@]}" 2>&1) || PYTEST_EXIT=$?
fi

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

# Parse pytest output
PASSED=0
FAILED=0
SKIPPED=0
TOTAL=0
declare -a FAILURES=()
declare -a SUITES_SEEN=()

# Pytest summary line format: "42 passed, 2 failed, 1 skipped in 8.23s"
# or "42 passed in 8.23s"
summary_line=""
while IFS= read -r line; do
    # Capture the summary line (last non-empty line with "passed" or "failed")
    if [[ "$line" =~ ([0-9]+)\ passed ]] || [[ "$line" =~ ([0-9]+)\ failed ]] || [[ "$line" =~ ([0-9]+)\ error ]]; then
        summary_line="$line"
    fi

    # Capture failure lines (format: "FAILED test_file.py::TestClass::test_name - reason")
    if [[ "$line" =~ ^FAILED\ (.+)::(.+)\ -\ (.+) ]]; then
        file="${BASH_REMATCH[1]}"
        test_name="${BASH_REMATCH[2]}"
        message="${BASH_REMATCH[3]}"
        suite="$(basename "$file")"

        if [[ ! " ${SUITES_SEEN[*]:-} " =~ " ${suite} " ]]; then
            SUITES_SEEN+=("$suite")
        fi

        if [[ ${#message} -gt 200 ]]; then
            message="${message:0:200}..."
        fi

        FAILURES+=("$(jq -nc --arg s "$suite" --arg t "$test_name" --arg m "$message" \
            '{suite: $s, test: $t, message: $m}')")
    fi

    # Track suites from test lines (format: "test_file.py::TestClass::test_name PASSED")
    if [[ "$line" =~ ^([^ ]+\.py):: ]]; then
        suite="$(basename "${BASH_REMATCH[1]}")"
        if [[ ! " ${SUITES_SEEN[*]:-} " =~ " ${suite} " ]]; then
            SUITES_SEEN+=("$suite")
        fi
    fi
done <<< "$PYTEST_OUTPUT"

# Parse summary line
if [[ -n "$summary_line" ]]; then
    if [[ "$summary_line" =~ ([0-9]+)\ passed ]]; then
        PASSED="${BASH_REMATCH[1]}"
    fi
    if [[ "$summary_line" =~ ([0-9]+)\ failed ]]; then
        FAILED="${BASH_REMATCH[1]}"
    fi
    if [[ "$summary_line" =~ ([0-9]+)\ skipped ]]; then
        SKIPPED="${BASH_REMATCH[1]}"
    fi
    if [[ "$summary_line" =~ ([0-9]+)\ error ]]; then
        FAILED=$((FAILED + ${BASH_REMATCH[1]}))
    fi
fi

TOTAL=$((PASSED + FAILED + SKIPPED))
SUITE_COUNT=${#SUITES_SEEN[@]}

# If we couldn't parse suites from output, count from target files
if [[ $SUITE_COUNT -eq 0 && $TOTAL -gt 0 ]]; then
    SUITE_COUNT=${#TARGETS[@]}
fi

# Build failures JSON array
FAILURES_JSON="[]"
if [[ ${#FAILURES[@]} -gt 0 ]]; then
    FAILURES_JSON=$(printf '%s\n' "${FAILURES[@]}" | jq -s '.')
fi

STATUS="pass"
if [[ $FAILED -gt 0 ]]; then
    STATUS="fail"
fi

jq -nc \
    --arg status "$STATUS" \
    --argjson suites "$SUITE_COUNT" \
    --argjson tests "$TOTAL" \
    --argjson passed "$PASSED" \
    --argjson failed "$FAILED" \
    --argjson skipped "$SKIPPED" \
    --argjson warnings 0 \
    --argjson duration "$DURATION" \
    --argjson failures "$FAILURES_JSON" \
    '{
        status: $status,
        suites: $suites,
        tests: $tests,
        passed: $passed,
        failed: $failed,
        skipped: $skipped,
        warnings: $warnings,
        duration_seconds: $duration,
        failures: $failures,
        warning_messages: []
    }'

# Always exit 0 in JSON mode — the status field carries pass/fail
exit 0
