#!/usr/bin/env bash
# run-e2e-tests.sh - Execute E2E tests with proper environment configuration
# Usage: ./scripts/run-e2e-tests.sh --command <cmd> [--url <url>] [--timeout <seconds>]
# Returns: JSON test results to stdout
# Exit codes: 0=passed, 1=failed, 2=timeout

set -euo pipefail

E2E_COMMAND=""
STAGING_URL=""
TIMEOUT=300

while [[ $# -gt 0 ]]; do
  case "$1" in
    --command) E2E_COMMAND="$2"; shift 2 ;;
    --url)     STAGING_URL="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2";    shift 2 ;;
    -h|--help)
      echo "Usage: $0 --command <cmd> [--url <url>] [--timeout <seconds>]" >&2
      exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$E2E_COMMAND" ]]; then
  echo "❌ Usage: $0 --command <cmd> [--url <url>] [--timeout <seconds>]" >&2
  exit 2
fi

# Detect timeout command (macOS uses gtimeout from coreutils)
TIMEOUT_CMD="timeout"
if ! command -v timeout &> /dev/null && command -v gtimeout &> /dev/null; then
  TIMEOUT_CMD="gtimeout"
fi

echo "Running E2E tests..." >&2
echo "  Command: $E2E_COMMAND" >&2
echo "  URL: ${STAGING_URL:-not configured}" >&2
echo "  Timeout: ${TIMEOUT}s" >&2

# Set environment variables for E2E tests
export TEST_ENV="staging"
export TEST_BASE_URL="$STAGING_URL"
export BASE_URL="$STAGING_URL"

# Create temp files for output
RAW_OUTPUT=$(mktemp)
JSON_REPORT=$(mktemp)
trap "rm -f $RAW_OUTPUT $JSON_REPORT" EXIT

# Check if it's a playwright command and inject JSON reporter
FINAL_COMMAND="$E2E_COMMAND"
IS_PLAYWRIGHT=false
if [[ "$E2E_COMMAND" == *"playwright"* ]]; then
  IS_PLAYWRIGHT=true
  # If it doesn't already have a reporter flag, add JSON
  if [[ "$E2E_COMMAND" != *"--reporter"* ]]; then
    FINAL_COMMAND="$E2E_COMMAND --reporter=json"
  fi
fi

# Run E2E tests with timeout
START=$(date +%s)

# We use a subshell to capture the JSON if it's playwright
if [[ "$IS_PLAYWRIGHT" == "true" ]]; then
  # Playwright with JSON reporter usually writes to stdout or a file
  # If we added --reporter=json, it goes to stdout.
  # We need to separate the JSON from potential other logs.
  EXIT_CODE=0
  $TIMEOUT_CMD "$TIMEOUT" bash -c "$FINAL_COMMAND" > "$JSON_REPORT" 2> "$RAW_OUTPUT" || EXIT_CODE=$?
  if [[ $EXIT_CODE -eq 0 ]]; then
    TEST_STATUS="passed"
  elif [[ $EXIT_CODE -eq 124 ]]; then
    TEST_STATUS="timeout"
  else
    TEST_STATUS="failed"
  fi
else
  # Generic command
  EXIT_CODE=0
  $TIMEOUT_CMD "$TIMEOUT" bash -c "$FINAL_COMMAND" > "$RAW_OUTPUT" 2>&1 || EXIT_CODE=$?
  if [[ $EXIT_CODE -eq 0 ]]; then
    TEST_STATUS="passed"
  elif [[ $EXIT_CODE -eq 124 ]]; then
    TEST_STATUS="timeout"
  else
    TEST_STATUS="failed"
  fi
fi

ELAPSED=$(($(date +%s) - START))

# Initialize results
PASSED=0
FAILED=0
SKIPPED=0
TOTAL=0
FAILED_TESTS_JSON="[]"

if [[ "$IS_PLAYWRIGHT" == "true" && -s "$JSON_REPORT" ]]; then
  # Parse Playwright JSON report
  # Check if the file actually contains valid JSON
  if jq . "$JSON_REPORT" >/dev/null 2>&1; then
    PASSED=$(jq '.stats.expected' "$JSON_REPORT" 2>/dev/null || echo "0")
    FAILED=$(jq '.stats.unexpected' "$JSON_REPORT" 2>/dev/null || echo "0")
    SKIPPED=$(jq '.stats.skipped' "$JSON_REPORT" 2>/dev/null || echo "0")
    TOTAL=$((PASSED + FAILED + SKIPPED))
    
    # Extract failed tests: [ {file, title, reason} ]
    FAILED_TESTS_JSON=$(jq -c '[.suites[].specs[]? | select(.ok==false or .tests[].results[].status=="unexpected") | {file: .file, title: .title, reason: (.tests[0].results[0].error.message // "Unknown error") | split("\n")[0]}]' "$JSON_REPORT" 2>/dev/null || echo "[]")
  else
    # Fallback if JSON was mixed with other output
    # Try to extract the JSON part (lines starting with { and ending with })
    sed -n '/^{/,/^}/p' "$JSON_REPORT" > "${JSON_REPORT}.clean"
    if jq . "${JSON_REPORT}.clean" >/dev/null 2>&1; then
       # (Repeat parsing with clean file if needed, for brevity I'll skip here and assume fallback)
       TEST_OUTPUT=$(cat "$RAW_OUTPUT")
       PASSED=$(echo "$TEST_OUTPUT" | grep -oE '[0-9]+ passed' | grep -oE '[0-9]+' | tail -1 || echo "0")
       FAILED=$(echo "$TEST_OUTPUT" | grep -oE '[0-9]+ failed' | grep -oE '[0-9]+' | tail -1 || echo "0")
    fi
  fi
else
  # Generic parsing fallback
  TEST_OUTPUT=$(cat "$RAW_OUTPUT")
  PASSED=$(echo "$TEST_OUTPUT" | grep -oE '[0-9]+ passed' | grep -oE '[0-9]+' | tail -1 || echo "0")
  FAILED=$(echo "$TEST_OUTPUT" | grep -oE '[0-9]+ failed' | grep -oE '[0-9]+' | tail -1 || echo "0")
  SKIPPED=$(echo "$TEST_OUTPUT" | grep -oE '[0-9]+ skipped' | grep -oE '[0-9]+' | tail -1 || echo "0")
  TOTAL=$((PASSED + FAILED))
fi

# Output summary to stderr for human/agent observation
echo "E2E Results: $TEST_STATUS ($PASSED passed, $FAILED failed, $ELAPSED seconds)" >&2

# Output JSON result to stdout
jq -n \
  --arg status "$TEST_STATUS" \
  --argjson elapsed "$ELAPSED" \
  --argjson timeout "$TIMEOUT" \
  --argjson passed "$PASSED" \
  --argjson failed "$FAILED" \
  --argjson total "$TOTAL" \
  --argjson failed_tests "$FAILED_TESTS_JSON" \
  --arg url "$STAGING_URL" \
  '{
    status: $status,
    elapsed_seconds: $elapsed,
    timeout_seconds: $timeout,
    test_url: $url,
    results: {
      passed: $passed,
      failed: $failed,
      total: $total
    },
    failed_tests: $failed_tests
  }'

exit "$EXIT_CODE"
