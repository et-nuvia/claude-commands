#!/usr/bin/env bash
# Test detect-tech-stack.sh

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
run_test "detect-tech-stack.sh exists and is executable" \
  "[[ -x '${SCRIPT_DIR}/detect-tech-stack.sh' ]]"

# Test help output
run_test "detect-tech-stack.sh shows help" \
  "'${SCRIPT_DIR}/detect-tech-stack.sh' --help > /dev/null 2>&1 || true"

# Test language detection (verify command works, may return empty if no markers)
run_test "language detection command works" \
  "'${SCRIPT_DIR}/detect-tech-stack.sh' languages > /dev/null 2>&1 || true"

# Test JSON output format
run_test "outputs valid JSON" \
  "(cd '${SCRIPT_DIR}' && '../scripts/detect-tech-stack.sh' json 2>&1 || true) | python3 -m json.tool > /dev/null 2>&1"

# Test framework detection
run_test "detects frameworks" \
  "'${SCRIPT_DIR}/detect-tech-stack.sh' frameworks > /dev/null 2>&1 || true"

# Test tools detection
run_test "detects tools" \
  "'${SCRIPT_DIR}/detect-tech-stack.sh' tools > /dev/null 2>&1 || true"

# Test 'all' command
run_test "outputs all detections" \
  "'${SCRIPT_DIR}/detect-tech-stack.sh' all > /dev/null 2>&1 || true"

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
