#!/usr/bin/env bash
set -euo pipefail

# Aggregate JSON results from multiple test sub-targets
#
# Usage:
#   run-test-aggregator.sh --targets "test-bats test-api" [--format json|raw]
#
# Calls each target via `make <target> FORMAT=json`, collects results,
# and produces a summary with per-target breakdown.
#
# JSON output format:
# {
#   "status": "pass|fail",
#   "suites": 10,
#   "tests": 150,
#   "passed": 148,
#   "failed": 2,
#   "skipped": 0,
#   "warnings": 0,
#   "duration_seconds": 25,
#   "failures": [...],
#   "warning_messages": [...],
#   "targets": [
#     {
#       "name": "test-bats",
#       "status": "pass",
#       "tests": 52,
#       "passed": 52,
#       "failed": 0,
#       "skipped": 0,
#       "duration_seconds": 3
#     },
#     {
#       "name": "test-api",
#       "status": "fail",
#       "tests": 98,
#       "passed": 96,
#       "failed": 2,
#       "skipped": 0,
#       "duration_seconds": 22,
#       "failures": [...]
#     }
#   ]
# }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

FORMAT="json"
TARGETS=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --targets) TARGETS="$2"; shift 2 ;;
        --format) FORMAT="$2"; shift 2 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done

if [[ -z "$TARGETS" ]]; then
    echo '{"status":"error","message":"No targets specified. Use --targets \"test-bats test-api\""}' >&2
    exit 2
fi

if [[ "$FORMAT" == "raw" ]]; then
    # In raw mode, just run each target sequentially with raw output
    for target in $TARGETS; do
        echo "=== $target ==="
        make -C "$PROJECT_DIR" --no-print-directory "$target" FORMAT=raw || true
        echo ""
    done
    exit 0
fi

# Collect JSON results from each target
declare -a TARGET_RESULTS=()
TOTAL_SUITES=0
TOTAL_TESTS=0
TOTAL_PASSED=0
TOTAL_FAILED=0
TOTAL_SKIPPED=0
TOTAL_WARNINGS=0
TOTAL_DURATION=0
OVERALL_STATUS="pass"
declare -a ALL_FAILURES=()
declare -a ALL_WARNING_MSGS=()

for target in $TARGETS; do
    RESULT=""
    RESULT=$(make -C "$PROJECT_DIR" --no-print-directory "$target" FORMAT=json 2>/dev/null) || true

    # Validate we got JSON
    if ! echo "$RESULT" | jq -e . >/dev/null 2>&1; then
        # Target didn't return valid JSON — record as error
        TARGET_RESULTS+=("$(jq -nc --arg name "$target" '{
            name: $name,
            status: "error",
            tests: 0, passed: 0, failed: 0, skipped: 0,
            duration_seconds: 0,
            message: "Target did not return valid JSON"
        }')")
        OVERALL_STATUS="fail"
        continue
    fi

    # Extract fields
    local_status=$(echo "$RESULT" | jq -r '.status // "unknown"')
    local_suites=$(echo "$RESULT" | jq -r '.suites // 0')
    local_tests=$(echo "$RESULT" | jq -r '.tests // 0')
    local_passed=$(echo "$RESULT" | jq -r '.passed // 0')
    local_failed=$(echo "$RESULT" | jq -r '.failed // 0')
    local_skipped=$(echo "$RESULT" | jq -r '.skipped // 0')
    local_warnings=$(echo "$RESULT" | jq -r '.warnings // 0')
    local_duration=$(echo "$RESULT" | jq -r '.duration_seconds // 0')

    # Accumulate totals
    TOTAL_SUITES=$((TOTAL_SUITES + local_suites))
    TOTAL_TESTS=$((TOTAL_TESTS + local_tests))
    TOTAL_PASSED=$((TOTAL_PASSED + local_passed))
    TOTAL_FAILED=$((TOTAL_FAILED + local_failed))
    TOTAL_SKIPPED=$((TOTAL_SKIPPED + local_skipped))
    TOTAL_WARNINGS=$((TOTAL_WARNINGS + local_warnings))
    TOTAL_DURATION=$((TOTAL_DURATION + local_duration))

    if [[ "$local_status" == "fail" ]]; then
        OVERALL_STATUS="fail"
    fi

    # Build per-target result (include failures only if present)
    local_failures=$(echo "$RESULT" | jq -c '.failures // []')
    local_warning_msgs=$(echo "$RESULT" | jq -c '.warning_messages // []')

    if [[ "$local_failures" != "[]" ]]; then
        # Add target failures to global list
        while IFS= read -r f; do
            ALL_FAILURES+=("$f")
        done < <(echo "$local_failures" | jq -c '.[]')

        TARGET_RESULTS+=("$(jq -nc \
            --arg name "$target" \
            --arg status "$local_status" \
            --argjson tests "$local_tests" \
            --argjson passed "$local_passed" \
            --argjson failed "$local_failed" \
            --argjson skipped "$local_skipped" \
            --argjson duration "$local_duration" \
            --argjson failures "$local_failures" \
            '{name: $name, status: $status, tests: $tests, passed: $passed,
              failed: $failed, skipped: $skipped, duration_seconds: $duration,
              failures: $failures}')")
    else
        TARGET_RESULTS+=("$(jq -nc \
            --arg name "$target" \
            --arg status "$local_status" \
            --argjson tests "$local_tests" \
            --argjson passed "$local_passed" \
            --argjson failed "$local_failed" \
            --argjson skipped "$local_skipped" \
            --argjson duration "$local_duration" \
            '{name: $name, status: $status, tests: $tests, passed: $passed,
              failed: $failed, skipped: $skipped, duration_seconds: $duration}')")
    fi

    # Collect warnings
    if [[ "$local_warning_msgs" != "[]" ]]; then
        while IFS= read -r w; do
            ALL_WARNING_MSGS+=("$w")
        done < <(echo "$local_warning_msgs" | jq -c '.[]')
    fi
done

# Build arrays
TARGETS_JSON="[]"
if [[ ${#TARGET_RESULTS[@]} -gt 0 ]]; then
    TARGETS_JSON=$(printf '%s\n' "${TARGET_RESULTS[@]}" | jq -s '.')
fi

FAILURES_JSON="[]"
if [[ ${#ALL_FAILURES[@]} -gt 0 ]]; then
    FAILURES_JSON=$(printf '%s\n' "${ALL_FAILURES[@]}" | jq -s '.')
fi

WARNINGS_JSON="[]"
if [[ ${#ALL_WARNING_MSGS[@]} -gt 0 ]]; then
    WARNINGS_JSON=$(printf '%s\n' "${ALL_WARNING_MSGS[@]}" | jq -s '.')
fi

jq -nc \
    --arg status "$OVERALL_STATUS" \
    --argjson suites "$TOTAL_SUITES" \
    --argjson tests "$TOTAL_TESTS" \
    --argjson passed "$TOTAL_PASSED" \
    --argjson failed "$TOTAL_FAILED" \
    --argjson skipped "$TOTAL_SKIPPED" \
    --argjson warnings "$TOTAL_WARNINGS" \
    --argjson duration "$TOTAL_DURATION" \
    --argjson failures "$FAILURES_JSON" \
    --argjson warning_messages "$WARNINGS_JSON" \
    --argjson targets "$TARGETS_JSON" \
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
        warning_messages: $warning_messages,
        targets: $targets
    }'

exit 0
