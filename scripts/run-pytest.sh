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
#   "warning_messages": [],
#   "exit_code": 0,
#   "next_action": "display_summary|fix_failures|fix_error"
# }
#
# Accuracy contract: the pytest exit code is authoritative. A non-zero exit never
# yields status "pass", even when no "N failed" summary line was printed.
# Pytest exit codes: 0 ok, 1 tests failed, 2 interrupted/collection error,
# 3 internal error, 4 usage error, 5 no tests collected.
# JSON mode still exits 0 (callers parse `status`).

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
        echo '{"status":"pass","suites":0,"tests":0,"passed":0,"failed":0,"skipped":0,"warnings":1,"duration_seconds":0,"failures":[],"warning_messages":["No Python test files found"],"exit_code":0,"next_action":"verify_scope"}'
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

# Pytest exit codes: 0 ok, 1 tests failed, 2 interrupted/collection error,
# 3 internal error, 4 usage error, 5 no tests collected. The text summary alone
# is NOT sufficient — a collection error (import error, syntax error in a test
# file) prints no "N failed" line, so parsing alone would report a false pass.
declare -a WARNING_MESSAGES=()
case "$PYTEST_EXIT" in
    0) ;;
    1) ;;  # tests failed — already reflected in FAILED
    2) WARNING_MESSAGES+=("pytest exited 2: collection error or interrupted run — tests may not have executed") ;;
    3) WARNING_MESSAGES+=("pytest exited 3: internal error") ;;
    4) WARNING_MESSAGES+=("pytest exited 4: usage error (bad arguments)") ;;
    5) WARNING_MESSAGES+=("pytest exited 5: no tests were collected") ;;
    *) WARNING_MESSAGES+=("pytest exited ${PYTEST_EXIT}") ;;
esac

# A non-zero exit with no parsed failure count still means the run did not
# succeed — surface the tail of pytest's output so the caller learns why.
if [[ $PYTEST_EXIT -ne 0 && $FAILED -eq 0 ]]; then
    error_tail=$(printf '%s' "$PYTEST_OUTPUT" | tail -n 20 | tr '\n' ' ')
    error_tail="${error_tail:0:300}"
    FAILURES+=("$(jq -nc --arg s "pytest" --arg t "<invocation>" --arg m "$error_tail" \
        '{suite: $s, test: $t, message: $m}')")
fi

# If we couldn't parse suites from output, count from target files
if [[ $SUITE_COUNT -eq 0 && $TOTAL -gt 0 ]]; then
    SUITE_COUNT=${#TARGETS[@]}
fi

# Truthful status: honour PYTEST_EXIT, not just the text-parsed failure count.
STATUS="pass"
NEXT_ACTION="display_summary"
if [[ $FAILED -gt 0 ]]; then
    STATUS="fail"
    NEXT_ACTION="fix_failures"
elif [[ $PYTEST_EXIT -ne 0 ]]; then
    STATUS="fail"
    NEXT_ACTION="fix_error"
fi

WARNINGS_JSON="[]"
if [[ ${#WARNING_MESSAGES[@]} -gt 0 ]]; then
    WARNINGS_JSON=$(printf '%s\n' "${WARNING_MESSAGES[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))')
fi

# Rebuild the failures array — a collection-error entry may have been appended.
FAILURES_JSON="[]"
if [[ ${#FAILURES[@]} -gt 0 ]]; then
    FAILURES_JSON=$(printf '%s\n' "${FAILURES[@]}" | jq -s '.')
fi

jq -nc \
    --arg status "$STATUS" \
    --arg next_action "$NEXT_ACTION" \
    --argjson exit_code "$PYTEST_EXIT" \
    --argjson warning_messages "$WARNINGS_JSON" \
    --argjson suites "$SUITE_COUNT" \
    --argjson tests "$TOTAL" \
    --argjson passed "$PASSED" \
    --argjson failed "$FAILED" \
    --argjson skipped "$SKIPPED" \
    --argjson duration "$DURATION" \
    --argjson failures "$FAILURES_JSON" \
    '{
        status: $status,
        suites: $suites,
        tests: $tests,
        passed: $passed,
        failed: $failed,
        skipped: $skipped,
        warnings: ($warning_messages | length),
        duration_seconds: $duration,
        failures: $failures,
        warning_messages: $warning_messages,
        exit_code: $exit_code,
        next_action: $next_action
    }'

# Always exit 0 in JSON mode — the status field carries pass/fail
exit 0
