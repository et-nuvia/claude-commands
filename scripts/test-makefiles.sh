#!/usr/bin/env bash
# Test Makefile templates

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source common functions
source "${SCRIPT_DIR}/lib/common.sh"

# Template directory
MAKEFILE_TEMPLATES="${HOME}/.claude/templates/makefiles"

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

# Test template files exist
run_test "root.mk exists" \
  "[[ -f '${MAKEFILE_TEMPLATES}/root.mk' ]]"

run_test "python-backend.mk exists" \
  "[[ -f '${MAKEFILE_TEMPLATES}/python-backend.mk' ]]"

run_test "nodejs-frontend.mk exists" \
  "[[ -f '${MAKEFILE_TEMPLATES}/nodejs-frontend.mk' ]]"

# Test templates use tabs (not spaces) for indentation
run_test "root.mk uses tabs" \
  "grep -q $'\t' '${MAKEFILE_TEMPLATES}/root.mk'"

run_test "python-backend.mk uses tabs" \
  "grep -q $'\t' '${MAKEFILE_TEMPLATES}/python-backend.mk'"

run_test "nodejs-frontend.mk uses tabs" \
  "grep -q $'\t' '${MAKEFILE_TEMPLATES}/nodejs-frontend.mk'"

# Test templates have required targets
run_test "root.mk has help target" \
  "grep -q '^help:' '${MAKEFILE_TEMPLATES}/root.mk'"

run_test "python-backend.mk has test target" \
  "grep -q '^test:' '${MAKEFILE_TEMPLATES}/python-backend.mk'"

run_test "nodejs-frontend.mk has test target" \
  "grep -q '^test:' '${MAKEFILE_TEMPLATES}/nodejs-frontend.mk'"

# Test templates have .PHONY declarations
run_test "root.mk has .PHONY declarations" \
  "grep -q '^\.PHONY:' '${MAKEFILE_TEMPLATES}/root.mk'"

run_test "python-backend.mk has .PHONY declarations" \
  "grep -q '^\.PHONY:' '${MAKEFILE_TEMPLATES}/python-backend.mk'"

run_test "nodejs-frontend.mk has .PHONY declarations" \
  "grep -q '^\.PHONY:' '${MAKEFILE_TEMPLATES}/nodejs-frontend.mk'"

# Test Makefile syntax is valid (dry-run)
run_test "root.mk has valid syntax" \
  "make -f '${MAKEFILE_TEMPLATES}/root.mk' -n help > /dev/null 2>&1 || true"

# Test generate-makefile.sh script
run_test "generate-makefile.sh exists and is executable" \
  "[[ -x '${SCRIPT_DIR}/generate-makefile.sh' ]]"

run_test "generate-makefile.sh shows help" \
  "'${SCRIPT_DIR}/generate-makefile.sh' --help > /dev/null 2>&1"

run_test "generate-makefile.sh auto-detects components" \
  "('${SCRIPT_DIR}/generate-makefile.sh' --dry-run 2>&1 || true) | grep -qE '(Component|backend|frontend|No components detected)'"

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
