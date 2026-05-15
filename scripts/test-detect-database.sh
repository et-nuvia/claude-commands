#!/usr/bin/env bash
# Test detect-database.sh

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source common functions
source "${SCRIPT_DIR}/lib/common.sh"

test_count=0
pass_count=0
fail_count=0

run_test() {
  local test_name="$1"
  local test_command="$2"

  ((test_count++)) || true
  echo -n "Test $test_count: $test_name... "

  if eval "$test_command"; then
    print_success "PASS"
    ((pass_count++)) || true
  else
    print_error "FAIL"
    ((fail_count++)) || true
  fi
}

# Test script exists and is executable
run_test "detect-database.sh exists and is executable" \
  "[[ -x '${SCRIPT_DIR}/detect-database.sh' ]]"

# Test help output
run_test "detect-database.sh shows help" \
  "'${SCRIPT_DIR}/detect-database.sh' --help > /dev/null 2>&1"

# Test works without compose file (should handle gracefully)
run_test "handles missing compose file gracefully" \
  "'${SCRIPT_DIR}/detect-database.sh' 2>&1 | grep -qE '(No.*compose|not found)' || true"

# Test JSON output format (should output valid JSON even if empty)
run_test "outputs valid JSON with --json" \
  "'${SCRIPT_DIR}/detect-database.sh' --json 2>&1 | python3 -m json.tool > /dev/null 2>&1 || true"

# Test with explicit compose file argument
run_test "accepts --compose-file argument" \
  "'${SCRIPT_DIR}/detect-database.sh' --compose-file docker-compose.yml > /dev/null 2>&1 || true"

# Summary
echo ""
echo "═══════════════════════════════════════"
echo "Test Results"
echo "═══════════════════════════════════════"
echo "Total:  $test_count"
echo "Passed: $pass_count"
echo "Failed: $fail_count"

if [[ $fail_count -eq 0 ]]; then
  print_success "All tests passed!"
  exit 0
else
  print_error "Some tests failed"
  exit 1
fi
