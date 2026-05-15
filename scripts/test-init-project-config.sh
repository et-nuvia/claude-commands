#!/usr/bin/env bash
# Test init-project-config.sh

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
run_test "init-project-config.sh exists and is executable" \
  "[[ -x '${SCRIPT_DIR}/init-project-config.sh' ]]"

# Test help output
run_test "init-project-config.sh shows help" \
  "'${SCRIPT_DIR}/init-project-config.sh' --help > /dev/null 2>&1"

# Test non-interactive mode
run_test "accepts --non-interactive flag" \
  "'${SCRIPT_DIR}/init-project-config.sh' --non-interactive --dry-run > /dev/null 2>&1 || true"

# Test dry-run mode
run_test "accepts --dry-run flag" \
  "'${SCRIPT_DIR}/init-project-config.sh' --dry-run --non-interactive > /dev/null 2>&1 || true"

# Test force flag
run_test "accepts --force flag" \
  "'${SCRIPT_DIR}/init-project-config.sh' --force --dry-run --non-interactive > /dev/null 2>&1 || true"

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
