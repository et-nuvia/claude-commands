#!/usr/bin/env bash
set -euo pipefail

# Run BATS tests and return structured JSON results for LLM consumption
#
# Usage:
#   run-bats.sh [--json|--raw] [--files "file1.bats file2.bats"] [--filter "pattern"]
#
# --json:   Return structured JSON with suite/test counts and failure details
# --raw:    Pass through raw BATS output (for debugging)
# --files:  Space-separated list of specific .bats files to run (relative to tests dir)
# --filter: Only run tests matching this pattern (bats --filter)
#
# JSON output format:
# {
#   "status": "pass|fail",
#   "suites": 5,
#   "tests": 926,
#   "passed": 920,
#   "failed": 4,
#   "skipped": 2,
#   "warnings": 1,
#   "duration_seconds": 12,
#   "failures": [
#     {"suite": "test-plan-progress.bats", "test": "counts total subtasks", "line": 84, "message": "expected 9, got 8"}
#   ],
#   "warning_messages": ["BW01: ..."]
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

# Build bats command
BATS_ARGS=()
BATS_ARGS+=(--tap)
BATS_ARGS+=(-T)  # timing

if [[ -n "$FILTER" ]]; then
    BATS_ARGS+=(--filter "$FILTER")
fi

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
    TARGETS+=("$TESTS_DIR")
fi

if [[ "$FORMAT" == "raw" ]]; then
    exec bats "${BATS_ARGS[@]}" "${TARGETS[@]}"
fi

# Run bats and capture output + exit code
START_TIME=$(date +%s)
TAP_OUTPUT=""
BATS_EXIT=0
TAP_OUTPUT=$(bats "${BATS_ARGS[@]}" "${TARGETS[@]}" 2>&1) || BATS_EXIT=$?
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

# Parse TAP output into JSON
PASSED=0
FAILED=0
SKIPPED=0
TOTAL=0
declare -a FAILURES=()
declare -a WARNINGS=()
declare -a SUITES_SEEN=()

current_suite=""

while IFS= read -r line; do
    # Track test plan line (1..N)
    if [[ "$line" =~ ^1\.\.([0-9]+) ]]; then
        TOTAL="${BASH_REMATCH[1]}"
        continue
    fi

    # Helper: flush accumulated failure into FAILURES array
    # Must be called before processing the next test result line
    flush_failure() {
        if [[ -n "${failure_msg:-}" ]]; then
            if [[ ${#failure_msg} -gt 200 ]]; then
                failure_msg="${failure_msg:0:200}..."
            fi
            FAILURES+=("$(jq -nc --arg s "${fail_suite:-unknown}" --arg t "${fail_test:-unknown}" --arg m "$failure_msg" \
                '{suite: $s, test: $t, message: $m}')")
            failure_msg=""
        fi
    }

    # Track ok/not ok lines
    if [[ "$line" =~ ^ok\ ([0-9]+)\ (.+) ]]; then
        flush_failure  # save any pending failure from previous test

        test_name="${BASH_REMATCH[2]}"
        # Remove timing info if present (bats -T adds " in NNms")
        test_name=$(echo "$test_name" | sed -E 's/ in [0-9]+m?s$//')

        if [[ "$line" == *"# skip"* ]]; then
            SKIPPED=$((SKIPPED + 1))
        else
            PASSED=$((PASSED + 1))
        fi

        # Extract suite from test name (format: "suite-name: test description")
        if [[ "$test_name" =~ ^([^:]+):\ (.+) ]]; then
            suite="${BASH_REMATCH[1]}"
            if [[ ! " ${SUITES_SEEN[*]:-} " =~ " ${suite} " ]]; then
                SUITES_SEEN+=("$suite")
            fi
        fi
        continue
    fi

    if [[ "$line" =~ ^not\ ok\ ([0-9]+)\ (.+) ]]; then
        flush_failure  # save any pending failure from previous test

        test_num="${BASH_REMATCH[1]}"
        test_name="${BASH_REMATCH[2]}"
        test_name=$(echo "$test_name" | sed -E 's/ in [0-9]+m?s$//')
        FAILED=$((FAILED + 1))

        # Extract suite — track separately for failure attribution
        suite="unknown"
        fail_suite="unknown"
        fail_test="$test_name"
        if [[ "$test_name" =~ ^([^:]+):\ (.+) ]]; then
            suite="${BASH_REMATCH[1]}"
            fail_suite="$suite"
            fail_test="${BASH_REMATCH[2]}"
            test_name="${BASH_REMATCH[2]}"
            if [[ ! " ${SUITES_SEEN[*]:-} " =~ " ${suite} " ]]; then
                SUITES_SEEN+=("$suite")
            fi
        fi

        # Collect failure details from subsequent lines (# prefix)
        failure_msg=""
        continue
    fi

    # Collect failure detail lines (indented with # )
    if [[ "$line" =~ ^#\  ]] && [[ -n "${fail_test:-}" ]]; then
        detail="${line#\# }"
        if [[ -z "$failure_msg" ]]; then
            failure_msg="$detail"
        else
            failure_msg="${failure_msg}; ${detail}"
        fi
        continue
    fi

    # Track warnings
    if [[ "$line" =~ ^BW[0-9]+: ]]; then
        WARNINGS+=("$(echo "$line" | head -c 150)")
    fi
done <<< "$TAP_OUTPUT"

# Flush any remaining failure from the last test
flush_failure

# If TOTAL wasn't set from TAP plan line, compute it
if [[ $TOTAL -eq 0 ]]; then
    TOTAL=$((PASSED + FAILED + SKIPPED))
fi

SUITE_COUNT=${#SUITES_SEEN[@]}

# Build failures JSON array
FAILURES_JSON="[]"
if [[ ${#FAILURES[@]} -gt 0 ]]; then
    FAILURES_JSON=$(printf '%s\n' "${FAILURES[@]}" | jq -s '.')
fi

# Build warnings JSON array
WARNINGS_JSON="[]"
if [[ ${#WARNINGS[@]} -gt 0 ]]; then
    WARNINGS_JSON=$(printf '%s\n' "${WARNINGS[@]}" | jq -Rs 'split("\n") | map(select(length > 0))')
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
    --argjson warnings "${#WARNINGS[@]}" \
    --argjson duration "$DURATION" \
    --argjson failures "$FAILURES_JSON" \
    --argjson warning_messages "$WARNINGS_JSON" \
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
        warning_messages: $warning_messages
    }'

# Always exit 0 in JSON mode — the status field carries pass/fail
exit 0
