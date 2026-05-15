#!/usr/bin/env bash
# Test GitHub Actions pipeline templates

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source common functions
source "${SCRIPT_DIR}/lib/common.sh"

# Template directories
GLOBAL_TEMPLATES="${HOME}/.claude/templates/pipelines"
PROJECT_TEMPLATES=".claude/templates/pipelines"

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

# Test GitHub Python template exists
run_test "GitHub Python template exists" \
  "[[ -f '${GLOBAL_TEMPLATES}/github-python.yml' ]]"

# Test GitHub Node.js template exists
run_test "GitHub Node.js template exists" \
  "[[ -f '${GLOBAL_TEMPLATES}/github-nodejs.yml' ]]"

# Test GitHub Python template has YAML structure (not strict validation since it has template vars)
run_test "GitHub Python template has name field" \
  "grep -q 'name: CI/CD Pipeline' '${GLOBAL_TEMPLATES}/github-python.yml'"

# Test GitHub Node.js template has YAML structure
run_test "GitHub Node.js template has name field" \
  "grep -q 'name: CI/CD Pipeline' '${GLOBAL_TEMPLATES}/github-nodejs.yml'"

# Test GitHub Python template contains required jobs
run_test "GitHub Python template has lint job" \
  "grep -q 'lint:' '${GLOBAL_TEMPLATES}/github-python.yml'"

run_test "GitHub Python template has test job" \
  "grep -q 'test:' '${GLOBAL_TEMPLATES}/github-python.yml'"

# Test generate-pipeline.sh script
run_test "generate-pipeline.sh exists and is executable" \
  "[[ -x '${SCRIPT_DIR}/generate-pipeline.sh' ]]"

run_test "generate-pipeline.sh shows help" \
  "'${SCRIPT_DIR}/generate-pipeline.sh' --help > /dev/null 2>&1"

run_test "generate-pipeline.sh auto-detects platform" \
  "('${SCRIPT_DIR}/generate-pipeline.sh' --language python --dry-run 2>&1 | grep -qE '(Platform:|github|gitlab)') || test \$? -eq 141"

run_test "generate-pipeline.sh accepts --language flag" \
  "('${SCRIPT_DIR}/generate-pipeline.sh' --language python --dry-run 2>&1 | grep -qE 'Language:') || test \$? -eq 141"

run_test "generate-pipeline.sh accepts GitHub platform" \
  "'${SCRIPT_DIR}/generate-pipeline.sh' --platform github --language python --dry-run > /dev/null 2>&1"

run_test "generate-pipeline.sh accepts GitLab platform" \
  "'${SCRIPT_DIR}/generate-pipeline.sh' --platform gitlab --language nodejs --dry-run > /dev/null 2>&1"

run_test "generate-pipeline.sh validates platform value" \
  "! '${SCRIPT_DIR}/generate-pipeline.sh' --platform invalid --dry-run 2>&1"

run_test "generate-pipeline.sh validates language value" \
  "! '${SCRIPT_DIR}/generate-pipeline.sh' --language invalid --dry-run 2>&1"

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
