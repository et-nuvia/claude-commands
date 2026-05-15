#!/usr/bin/env bash
#
# parse-test-output.sh - Extract test results from framework output
#
# Usage:
#   parse-test-output.sh [--framework pytest|vitest|jest|go|playwright] < input
#   echo "output" | parse-test-output.sh
#
# Output: JSON object with passed, failed, skipped, coverage_pct, duration_ms
#
# Auto-detects framework from output patterns if --framework not specified.

set -euo pipefail

FRAMEWORK=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --framework) FRAMEWORK="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: parse-test-output.sh [--framework pytest|vitest|jest|go|playwright] < input"
            exit 0
            ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# Read all input
INPUT=$(cat)

#------------------------------------------------------------------------------
# Auto-detect framework
#------------------------------------------------------------------------------

detect_framework() {
    if echo "$INPUT" | grep -qE '^\s*(=+).*(passed|failed|error).*\s*=+\s*$' 2>/dev/null; then
        echo "pytest"
    elif echo "$INPUT" | grep -qE '[0-9]+ passed' 2>/dev/null && echo "$INPUT" | grep -qE 'in [0-9.]+s' 2>/dev/null; then
        echo "pytest"
    elif echo "$INPUT" | grep -qE 'Tests:.*passed' 2>/dev/null || echo "$INPUT" | grep -qE 'Test Suites:' 2>/dev/null; then
        echo "vitest"
    elif echo "$INPUT" | grep -qE '^(ok|FAIL)\s' 2>/dev/null && echo "$INPUT" | grep -qE 'go test' 2>/dev/null; then
        echo "go"
    elif echo "$INPUT" | grep -qE '^(PASS|FAIL)$' 2>/dev/null; then
        echo "go"
    elif echo "$INPUT" | grep -qE '[0-9]+ passed.*\([0-9]+' 2>/dev/null && echo "$INPUT" | grep -qiE 'playwright|chromium|firefox|webkit' 2>/dev/null; then
        echo "playwright"
    else
        echo "unknown"
    fi
}

if [[ -z "$FRAMEWORK" ]]; then
    FRAMEWORK=$(detect_framework)
fi

#------------------------------------------------------------------------------
# Parse by framework
#------------------------------------------------------------------------------

parse_pytest() {
    local passed=0 failed=0 skipped=0 errors=0 coverage_pct=0 duration_ms=0

    # Extract summary: "X passed, Y failed, Z skipped in Ns"
    local summary
    summary=$(echo "$INPUT" | grep -E '[0-9]+ (passed|failed|skipped|error)' | tail -1 || true)

    if [[ -n "$summary" ]]; then
        passed=$(echo "$summary" | grep -oP '\d+(?= passed)' || echo "0")
        failed=$(echo "$summary" | grep -oP '\d+(?= failed)' || echo "0")
        skipped=$(echo "$summary" | grep -oP '\d+(?= skipped)' || echo "0")
        errors=$(echo "$summary" | grep -oP '\d+(?= error)' || echo "0")
    fi

    # Duration from "in X.XXs"
    local duration_str
    duration_str=$(echo "$INPUT" | grep -oP 'in \K[0-9.]+(?=s)' | tail -1 || echo "0")
    if [[ -n "$duration_str" && "$duration_str" != "0" ]]; then
        duration_ms=$(echo "$duration_str" | awk '{printf "%d", $1 * 1000}')
    fi

    # Coverage from TOTAL line
    if echo "$INPUT" | grep -q "TOTAL" 2>/dev/null; then
        coverage_pct=$(echo "$INPUT" | grep "TOTAL" | awk '{print $NF}' | tr -d '%' || echo "0")
    fi

    # Include errors in failed count for simplicity
    failed=$((failed + errors))

    echo "{\"passed\":$passed,\"failed\":$failed,\"skipped\":$skipped,\"coverage_pct\":$coverage_pct,\"duration_ms\":$duration_ms}"
}

parse_vitest() {
    local passed=0 failed=0 skipped=0 coverage_pct=0 duration_ms=0

    # "Tests:  X passed, Y failed, Z total" or "Tests  X passed | Y failed | Z total"
    local tests_line
    tests_line=$(echo "$INPUT" | grep -E 'Tests:?\s' | tail -1 || true)

    if [[ -n "$tests_line" ]]; then
        passed=$(echo "$tests_line" | grep -oP '\d+(?= passed)' || echo "0")
        failed=$(echo "$tests_line" | grep -oP '\d+(?= failed)' || echo "0")
        skipped=$(echo "$tests_line" | grep -oP '\d+(?= skipped)' || echo "0")
    fi

    # Duration: "Time: X.XXs" or "Duration  X.XX s"
    local dur_str
    dur_str=$(echo "$INPUT" | grep -oP '(?:Time|Duration)[:\s]+\K[0-9.]+' | tail -1 || echo "0")
    if [[ -n "$dur_str" && "$dur_str" != "0" ]]; then
        duration_ms=$(echo "$dur_str" | awk '{printf "%d", $1 * 1000}')
    fi

    # Coverage from "All files" or "Statements" line
    if echo "$INPUT" | grep -qE '(All files|Statements)' 2>/dev/null; then
        coverage_pct=$(echo "$INPUT" | grep -E '(All files|Statements)' | grep -oP '[0-9.]+(?=%)' | head -1 || echo "0")
    fi

    echo "{\"passed\":$passed,\"failed\":$failed,\"skipped\":$skipped,\"coverage_pct\":$coverage_pct,\"duration_ms\":$duration_ms}"
}

parse_go() {
    local passed=0 failed=0 skipped=0 coverage_pct=0 duration_ms=0

    # Count PASS/FAIL lines for individual tests
    passed=$(echo "$INPUT" | grep -c '--- PASS:' || echo "0")
    failed=$(echo "$INPUT" | grep -c '--- FAIL:' || echo "0")
    skipped=$(echo "$INPUT" | grep -c '--- SKIP:' || echo "0")

    # If no individual test lines, check overall result
    if [[ $passed -eq 0 && $failed -eq 0 ]]; then
        if echo "$INPUT" | grep -q '^PASS$'; then
            passed=1
        elif echo "$INPUT" | grep -q '^FAIL$'; then
            failed=1
        fi
    fi

    # Coverage percentage
    if echo "$INPUT" | grep -q 'coverage:' 2>/dev/null; then
        coverage_pct=$(echo "$INPUT" | grep -oP 'coverage: \K[0-9.]+' | head -1 || echo "0")
    fi

    # Duration from "(X.XXs)"
    local dur_str
    dur_str=$(echo "$INPUT" | grep -oP '\((\K[0-9.]+)(?=s\))' | tail -1 || echo "0")
    if [[ -n "$dur_str" && "$dur_str" != "0" ]]; then
        duration_ms=$(echo "$dur_str" | awk '{printf "%d", $1 * 1000}')
    fi

    echo "{\"passed\":$passed,\"failed\":$failed,\"skipped\":$skipped,\"coverage_pct\":$coverage_pct,\"duration_ms\":$duration_ms}"
}

parse_playwright() {
    local passed=0 failed=0 skipped=0 duration_ms=0

    # "X passed (Ys)" or "X failed"
    passed=$(echo "$INPUT" | grep -oP '\d+(?= passed)' | tail -1 || echo "0")
    failed=$(echo "$INPUT" | grep -oP '\d+(?= failed)' | tail -1 || echo "0")
    skipped=$(echo "$INPUT" | grep -oP '\d+(?= skipped)' | tail -1 || echo "0")

    # Duration from "(Xs)" or "(X.Xs)" or "(Xm)"
    local dur_str
    dur_str=$(echo "$INPUT" | grep -oP '\((\K[0-9.]+)(?=[sm]\))' | tail -1 || echo "0")
    local dur_unit
    dur_unit=$(echo "$INPUT" | grep -oP '\([0-9.]+\K[sm](?=\))' | tail -1 || echo "s")
    if [[ -n "$dur_str" && "$dur_str" != "0" ]]; then
        if [[ "$dur_unit" == "m" ]]; then
            duration_ms=$(echo "$dur_str" | awk '{printf "%d", $1 * 60000}')
        else
            duration_ms=$(echo "$dur_str" | awk '{printf "%d", $1 * 1000}')
        fi
    fi

    echo "{\"passed\":$passed,\"failed\":$failed,\"skipped\":$skipped,\"coverage_pct\":0,\"duration_ms\":$duration_ms}"
}

parse_unknown() {
    # Best-effort: look for common patterns
    local passed=0 failed=0 skipped=0

    passed=$(echo "$INPUT" | grep -oP '\d+(?= passed)' | tail -1 || echo "0")
    failed=$(echo "$INPUT" | grep -oP '\d+(?= failed)' | tail -1 || echo "0")
    skipped=$(echo "$INPUT" | grep -oP '\d+(?= skipped)' | tail -1 || echo "0")

    echo "{\"passed\":$passed,\"failed\":$failed,\"skipped\":$skipped,\"coverage_pct\":0,\"duration_ms\":0}"
}

#------------------------------------------------------------------------------
# Main
#------------------------------------------------------------------------------

case "$FRAMEWORK" in
    pytest)     parse_pytest ;;
    vitest|jest) parse_vitest ;;
    go)         parse_go ;;
    playwright) parse_playwright ;;
    *)          parse_unknown ;;
esac
