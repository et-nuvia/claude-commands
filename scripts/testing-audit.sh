#!/usr/bin/env bash
# testing-audit.sh - Deterministic testing implementation audit
# Usage: ./testing-audit.sh --stage <stage> [--quick]
# Stages: scan, score, report, all (default)
#
# Audits project test infrastructure against the standards in:
#   ~/.claude/docs/reference/testing.md
#   ~/.claude/docs/reference/makefile.md
#
# Reads configuration from PROJECT.yaml (no environment variables).
# Outputs structured JSON to stdout, status messages to stderr.

set -euo pipefail

# Source shared libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"
source "${LIB_DIR}/common.sh"
source "${LIB_DIR}/project-config.sh"
source "${LIB_DIR}/output-framework.sh"  # log_json: TOON for AI callers

# Configuration
STAGE="all"
QUICK_MODE=false
OUTPUT_FILE="/tmp/testing-audit-result.json"

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --stage)    STAGE="$2"; shift 2 ;;
    --quick)    QUICK_MODE=true; shift ;;
    --output)   OUTPUT_FILE="$2"; shift 2 ;;
    *)
      print_error "Unknown argument: $1"
      echo "Usage: testing-audit.sh --stage <scan|score|report|all> [--quick] [--output FILE]" >&2
      exit 2
      ;;
  esac
done

# Require PROJECT.yaml
require_project_config

# Global state
APP_NAME=$(get_app_name)
MIN_COVERAGE=$(get_min_coverage)

# Scan results
TOTAL_CHECKS=0
PASSED_CHECKS=0
FAILED_CHECKS=0
WARNINGS=0

# Category scores
SCORE_HIERARCHY=0        # Target hierarchy: test → test-<service> → test-<service>-<type>
SCORE_JSON_CONTRACT=0    # Runner scripts produce standard JSON, aggregation works
SCORE_ABSTRACTION=0      # Callers don't need to know the framework
SCORE_SEEDING=0          # Seed-once, env var guard, leaf-only, no file sentinels
SCORE_DATA_ISOLATION=0   # Suite-scoped data, self-contained mutations
SCORE_COVERAGE=0         # Coverage targets, coverage commands, CI integration
SCORE_QUALITY=0          # AAA pattern, naming, fixtures, no skipped tests

OVERALL_SCORE=0

# Findings
FINDINGS_PASS=""
FINDINGS_FAIL=""
FINDINGS_WARN=""
FINDINGS_SKIP=""

# Discovered state
COMPONENTS=()
TEST_DIRS=()
RUNNER_SCRIPTS=()

#============================================================================
# Check Helpers
#============================================================================

record_check() {
  local category="$1"
  local name="$2"
  local result="$3"
  local detail="$4"

  TOTAL_CHECKS=$((TOTAL_CHECKS + 1))

  local entry="${category}|${name}|${result}|${detail}"

  case "$result" in
    pass)
      PASSED_CHECKS=$((PASSED_CHECKS + 1))
      FINDINGS_PASS="${FINDINGS_PASS}${entry}\n"
      print_success "$name" ;;
    fail)
      FAILED_CHECKS=$((FAILED_CHECKS + 1))
      FINDINGS_FAIL="${FINDINGS_FAIL}${entry}\n"
      print_error "$name: $detail" ;;
    warn)
      WARNINGS=$((WARNINGS + 1))
      FINDINGS_WARN="${FINDINGS_WARN}${entry}\n"
      print_warning "$name: $detail" ;;
    skip)
      FINDINGS_SKIP="${FINDINGS_SKIP}${entry}\n"
      print_debug "SKIP: $name: $detail" ;;
  esac
}

file_has_pattern() {
  local file="$1"
  local pattern="$2"
  grep -qE "$pattern" "$file" 2>/dev/null
}

count_pattern() {
  local file="$1"
  local pattern="$2"
  grep -cE "$pattern" "$file" 2>/dev/null || echo 0
}

# Recursively count files matching a glob in a directory
count_test_files() {
  local dir="$1"
  local pattern="$2"
  find "$dir" -name "$pattern" -type f 2>/dev/null | wc -l | tr -d ' '
}

#============================================================================
# Stage: Scan - Discover and check test infrastructure
#============================================================================

scan_stage() {
  print_info "Stage: Scanning test infrastructure..."

  # Discover components from PROJECT.yaml
  local comp_count
  comp_count=$(yq '.components | length' PROJECT.yaml 2>/dev/null || echo 0)

  for ((i=0; i<comp_count; i++)); do
    local comp_path
    comp_path=$(yq ".components[$i].path" PROJECT.yaml 2>/dev/null || echo "")
    if [[ -n "$comp_path" && "$comp_path" != "null" ]]; then
      COMPONENTS+=("$comp_path")
    fi
  done

  # Discover test directories
  for comp in "${COMPONENTS[@]}"; do
    for test_dir in "${comp}/test" "${comp}/tests" "${comp}/__tests__" "${comp}/src/__tests__" "${comp}/e2e"; do
      if [[ -d "$test_dir" ]]; then
        TEST_DIRS+=("$test_dir")
      fi
    done
  done

  # Discover runner scripts
  if [[ -d "scripts" ]]; then
    for f in scripts/test-*.sh; do
      [[ -f "$f" ]] && RUNNER_SCRIPTS+=("$f")
    done
  fi

  #--- Category: Hierarchy ---
  print_info ""
  print_info "Category: Target Hierarchy"

  if [[ -f "Makefile" ]]; then
    # Check for top-level test target
    if file_has_pattern "Makefile" '^test:'; then
      record_check "hierarchy" "Root test target" "pass" "make test exists"
    else
      record_check "hierarchy" "Root test target" "fail" "No 'test:' target in root Makefile"
    fi

    # Check for service-level targets
    for comp in "${COMPONENTS[@]}"; do
      if file_has_pattern "Makefile" "^test-${comp}:"; then
        record_check "hierarchy" "Service target: test-${comp}" "pass" "Found test-${comp}"

        # Check for sub-type targets
        local subtypes_found=0
        for subtype in unit e2e integration api; do
          if file_has_pattern "Makefile" "^test-${comp}-${subtype}:"; then
            subtypes_found=$((subtypes_found + 1))
          fi
        done

        if [[ $subtypes_found -gt 0 ]]; then
          record_check "hierarchy" "Sub-type targets for ${comp}" "pass" "Found ${subtypes_found} sub-type target(s)"
        else
          record_check "hierarchy" "Sub-type targets for ${comp}" "warn" "No test-${comp}-<type> sub-targets in root"
        fi
      else
        record_check "hierarchy" "Service target: test-${comp}" "warn" "No test-${comp} in root Makefile"
      fi
    done

    # Check service Makefiles for leaf targets
    for comp in "${COMPONENTS[@]}"; do
      local mf="${comp}/Makefile"
      [[ ! -f "$mf" ]] && continue

      local leaf_count=0
      for subtype in unit e2e integration api; do
        if file_has_pattern "$mf" "^test-${subtype}:|^test-${subtype} "; then
          leaf_count=$((leaf_count + 1))
        fi
      done

      if [[ $leaf_count -gt 0 ]]; then
        record_check "hierarchy" "Leaf targets in ${comp}/Makefile" "pass" "Found ${leaf_count} leaf test target(s)"
      elif file_has_pattern "$mf" '^test:'; then
        record_check "hierarchy" "Leaf targets in ${comp}/Makefile" "warn" "Has 'test' but no leaf targets (test-unit, test-e2e, etc.)"
      fi
    done
  fi

  #--- Category: JSON Contract ---
  print_info ""
  print_info "Category: JSON Contract"

  # Check runner scripts for standard JSON fields
  for script in "${RUNNER_SCRIPTS[@]}"; do
    local script_name
    script_name=$(basename "$script")

    # Check for standard JSON fields (search for field names in any quoting context)
    local has_target has_suites has_tests has_passed has_failed has_failed_tests
    has_target=$(file_has_pattern "$script" 'target:' && echo 1 || echo 0)
    has_suites=$(file_has_pattern "$script" 'suites:|numTotalTestSuites|count_suites' && echo 1 || echo 0)
    has_tests=$(file_has_pattern "$script" 'tests:|numTotalTests' && echo 1 || echo 0)
    has_passed=$(file_has_pattern "$script" 'passed:|numPassedTests' && echo 1 || echo 0)
    has_failed=$(file_has_pattern "$script" 'failed:|numFailedTests' && echo 1 || echo 0)
    has_failed_tests=$(file_has_pattern "$script" 'failed_tests:' && echo 1 || echo 0)

    local field_count=$((has_target + has_suites + has_tests + has_passed + has_failed + has_failed_tests))

    if [[ $field_count -ge 5 ]]; then
      record_check "json_contract" "Standard JSON fields (${script_name})" "pass" "${field_count}/6 standard fields present"
    elif [[ $field_count -ge 3 ]]; then
      record_check "json_contract" "Standard JSON fields (${script_name})" "warn" "Only ${field_count}/6 standard fields"
    else
      record_check "json_contract" "Standard JSON fields (${script_name})" "fail" "Only ${field_count}/6 standard fields — missing core contract"
    fi

    # Check for --details support (timing stats)
    if file_has_pattern "$script" 'DETAILS|--details|timing'; then
      record_check "json_contract" "DETAILS support (${script_name})" "pass" "Supports --details for timing stats"
    else
      record_check "json_contract" "DETAILS support (${script_name})" "warn" "No --details support"
    fi

    # Check for error fallback (outputs JSON even on framework crash)
    if file_has_pattern "$script" 'jq -n'; then
      record_check "json_contract" "Error fallback (${script_name})" "pass" "Produces JSON even on framework failure"
    else
      record_check "json_contract" "Error fallback (${script_name})" "warn" "May not produce JSON if framework crashes"
    fi
  done

  # Check aggregation script
  if [[ -f "scripts/test-aggregate.sh" ]]; then
    if file_has_pattern "scripts/test-aggregate.sh" '"targets"'; then
      record_check "json_contract" "Aggregator includes targets array" "pass" "test-aggregate.sh wraps children in targets array"
    else
      record_check "json_contract" "Aggregator includes targets array" "fail" "test-aggregate.sh missing targets array"
    fi

    if file_has_pattern "scripts/test-aggregate.sh" 'jq -s'; then
      record_check "json_contract" "Aggregator sums counters" "pass" "Uses jq -s to merge results"
    else
      record_check "json_contract" "Aggregator sums counters" "warn" "May not properly sum counters across children"
    fi
  elif [[ ${#RUNNER_SCRIPTS[@]} -gt 0 ]]; then
    record_check "json_contract" "Aggregation script" "warn" "Has runner scripts but no test-aggregate.sh"
  fi

  #--- Category: Abstraction ---
  print_info ""
  print_info "Category: Framework Abstraction"

  for comp in "${COMPONENTS[@]}"; do
    local mf="${comp}/Makefile"
    [[ ! -f "$mf" ]] && continue

    # Check that FORMAT mode uses runner scripts (not direct tool calls)
    if file_has_pattern "$mf" 'ifdef FORMAT'; then
      # In FORMAT mode, should call scripts not tools
      local format_block
      format_block=$(awk '/ifdef FORMAT/,/^(else|endif)/' "$mf" 2>/dev/null || echo "")

      if echo "$format_block" | grep -qE 'scripts/test-.*\.sh'; then
        record_check "abstraction" "FORMAT calls runner scripts (${comp})" "pass" "FORMAT mode calls runner scripts"
      elif echo "$format_block" | grep -qE 'npx jest|npx playwright|pytest|newman'; then
        record_check "abstraction" "FORMAT calls runner scripts (${comp})" "fail" "FORMAT mode calls framework directly — should use runner scripts"
      else
        record_check "abstraction" "FORMAT calls runner scripts (${comp})" "warn" "Could not verify FORMAT mode implementation"
      fi

      # In non-FORMAT mode, should call tools directly (for human output)
      local else_block
      else_block=$(awk '/^else/,/^endif/' "$mf" 2>/dev/null || echo "")

      if echo "$else_block" | grep -qE 'npx|pytest|npm|jest|playwright'; then
        record_check "abstraction" "Human mode calls tools (${comp})" "pass" "Non-FORMAT mode calls tools directly"
      fi
    else
      record_check "abstraction" "FORMAT branching (${comp})" "warn" "No ifdef FORMAT — no framework abstraction"
    fi
  done

  #--- Category: Seeding ---
  print_info ""
  print_info "Category: Database Seeding"

  if [[ "$QUICK_MODE" == "true" ]]; then
    record_check "seeding" "Seeding checks" "skip" "Skipped in quick mode"
  else
    local has_any_seed=false

    for mf in "Makefile" "${COMPONENTS[@]/%//Makefile}"; do
      [[ ! -f "$mf" ]] && continue

      if file_has_pattern "$mf" '_TEST_DB_SEEDED'; then
        has_any_seed=true
        record_check "seeding" "In-memory seed guard (${mf})" "pass" "Uses _TEST_DB_SEEDED env var"
      fi

      # Anti-pattern: file-based sentinel
      if file_has_pattern "$mf" 'touch.*/tmp/.*seed|/tmp/.*seed.*touch'; then
        record_check "seeding" "No file sentinel (${mf})" "fail" "File-based seed sentinel — won't reset on Ctrl+C"
      fi
    done

    # Check _PASS forwards _TEST_DB_SEEDED
    if [[ -f "Makefile" ]]; then
      if file_has_pattern "Makefile" '_PASS.*_TEST_DB_SEEDED'; then
        record_check "seeding" "Root _PASS forwards seed state" "pass" "_PASS includes _TEST_DB_SEEDED"
      elif [[ "$has_any_seed" == "true" ]]; then
        record_check "seeding" "Root _PASS forwards seed state" "warn" "Uses _TEST_DB_SEEDED but _PASS may not forward it to sub-makes"
      fi
    fi

    # Check leaf-only seeding
    for comp in "${COMPONENTS[@]}"; do
      local mf="${comp}/Makefile"
      [[ ! -f "$mf" ]] && continue

      if file_has_pattern "$mf" 'seed-test-db|_seed-test-db'; then
        # Aggregator should NOT have seed prerequisite
        if grep -E '^test:.*seed' "$mf" 2>/dev/null | grep -qv '^test-'; then
          record_check "seeding" "Leaf-only seeding (${comp})" "warn" "Aggregator 'test:' has seed prereq — should only be on leaf targets"
        fi

        # Leaf targets SHOULD have seed prerequisite
        local leaf_with_seed=0
        local leaf_without_seed=0
        for subtype in unit e2e integration api; do
          if file_has_pattern "$mf" "^test-${subtype}:.*seed"; then
            leaf_with_seed=$((leaf_with_seed + 1))
          elif file_has_pattern "$mf" "^test-${subtype}:"; then
            leaf_without_seed=$((leaf_without_seed + 1))
          fi
        done

        if [[ $leaf_with_seed -gt 0 && $leaf_without_seed -eq 0 ]]; then
          record_check "seeding" "All leaf targets seed (${comp})" "pass" "${leaf_with_seed} leaf target(s) have seed prereq"
        elif [[ $leaf_with_seed -gt 0 ]]; then
          record_check "seeding" "All leaf targets seed (${comp})" "warn" "${leaf_without_seed} leaf target(s) missing seed prereq"
        fi
      fi
    done

    if [[ "$has_any_seed" == "false" ]]; then
      # Check if there's a database at all
      local has_db
      has_db=$(yq '.databases | length' PROJECT.yaml 2>/dev/null || echo 0)
      if [[ "$has_db" -gt 0 ]]; then
        record_check "seeding" "Seed-once strategy" "warn" "Project has database(s) but no _TEST_DB_SEEDED pattern in Makefiles"
      else
        record_check "seeding" "Seed-once strategy" "skip" "No databases in PROJECT.yaml"
      fi
    fi
  fi

  #--- Category: Data Isolation ---
  print_info ""
  print_info "Category: Data Isolation"

  if [[ "$QUICK_MODE" == "true" ]]; then
    record_check "data_isolation" "Data isolation checks" "skip" "Skipped in quick mode"
  else
    # Check for seed files with suite-scoped naming
    local seed_files=0
    local suite_scoped=0
    for comp in "${COMPONENTS[@]}"; do
      for seed_dir in "${comp}/src/database/seed" "${comp}/test/seed" "${comp}/tests/seed" "${comp}/test/fixtures" "${comp}/tests/fixtures"; do
        if [[ -d "$seed_dir" ]]; then
          local count
          count=$(find "$seed_dir" -type f \( -name "*.ts" -o -name "*.js" -o -name "*.py" \) 2>/dev/null | wc -l | tr -d ' ')
          seed_files=$((seed_files + count))

          # Check for suite-scoped naming patterns
          local scoped
          scoped=$(find "$seed_dir" -type f -name "*suite*" -o -name "*fixture*" 2>/dev/null | wc -l | tr -d ' ')
          suite_scoped=$((suite_scoped + scoped))
        fi
      done
    done

    if [[ $seed_files -gt 0 ]]; then
      record_check "data_isolation" "Seed files exist" "pass" "Found ${seed_files} seed/fixture file(s)"
      if [[ $suite_scoped -gt 0 ]]; then
        record_check "data_isolation" "Suite-scoped naming" "pass" "${suite_scoped} file(s) with suite-scoped naming"
      else
        record_check "data_isolation" "Suite-scoped naming" "warn" "No seed files with suite-scoped naming convention"
      fi
    else
      record_check "data_isolation" "Seed files exist" "skip" "No seed/fixture files found"
    fi

    # Check test files for self-contained mutation patterns
    local test_file_count=0
    local has_before_after=0
    local has_cleanup=0

    for comp in "${COMPONENTS[@]}"; do
      for dir in "${TEST_DIRS[@]}"; do
        [[ ! -d "$dir" ]] && continue
        local count
        count=$(count_test_files "$dir" "*.spec.ts")
        count=$((count + $(count_test_files "$dir" "*.test.ts")))
        count=$((count + $(count_test_files "$dir" "*.spec.js")))
        count=$((count + $(count_test_files "$dir" "*_test.py")))
        test_file_count=$((test_file_count + count))
      done
    done

    if [[ $test_file_count -gt 0 ]]; then
      record_check "data_isolation" "Test files found" "pass" "${test_file_count} test file(s) across components"
    fi

    # Check for beforeEach/afterEach patterns (TypeScript/Jest)
    for dir in "${TEST_DIRS[@]}"; do
      [[ ! -d "$dir" ]] && continue
      local be_count
      be_count=$( (grep -rl 'beforeEach\|afterEach\|setUp\|tearDown' "$dir" 2>/dev/null || true) | wc -l | tr -d ' ')
      has_before_after=$((has_before_after + be_count))
    done

    if [[ $has_before_after -gt 0 ]]; then
      record_check "data_isolation" "Setup/teardown patterns" "pass" "${has_before_after} file(s) with beforeEach/afterEach or setUp/tearDown"
    elif [[ $test_file_count -gt 0 ]]; then
      record_check "data_isolation" "Setup/teardown patterns" "warn" "No beforeEach/afterEach found — mutating tests may not clean up"
    fi
  fi

  #--- Category: Coverage ---
  print_info ""
  print_info "Category: Coverage Configuration"

  local coverage_threshold="${MIN_COVERAGE}"
  if [[ -n "$coverage_threshold" && "$coverage_threshold" != "0" ]]; then
    record_check "coverage" "Coverage threshold in PROJECT.yaml" "pass" "min_coverage: ${coverage_threshold}%"
  else
    record_check "coverage" "Coverage threshold in PROJECT.yaml" "warn" "No min_coverage in PROJECT.yaml"
  fi

  # Check for coverage commands in Makefiles
  local has_cov_target=false
  for mf in "Makefile" "${COMPONENTS[@]/%//Makefile}"; do
    [[ ! -f "$mf" ]] && continue
    if file_has_pattern "$mf" 'test-cov|test:.*cov|coverage'; then
      has_cov_target=true
    fi
  done

  if [[ "$has_cov_target" == "true" ]]; then
    record_check "coverage" "Coverage target in Makefile" "pass" "Has test-cov or coverage target"
  else
    record_check "coverage" "Coverage target in Makefile" "warn" "No coverage target found"
  fi

  # Check for jest.config coverage settings
  for comp in "${COMPONENTS[@]}"; do
    for cfg in "${comp}/jest.config.ts" "${comp}/jest.config.js" "${comp}/package.json"; do
      if [[ -f "$cfg" ]] && file_has_pattern "$cfg" 'coverageThreshold|collectCoverage'; then
        record_check "coverage" "Jest coverage config (${comp})" "pass" "Coverage configured in $(basename "$cfg")"
        break
      fi
    done
  done

  #--- Category: Quality ---
  print_info ""
  print_info "Category: Test Quality"

  # Check for skipped tests
  local skipped_tests=0
  for dir in "${TEST_DIRS[@]}"; do
    [[ ! -d "$dir" ]] && continue
    local skip_count
    skip_count=$( (grep -rl '\.skip\|xit(\|xdescribe(\|@pytest.mark.skip\|@unittest.skip' "$dir" 2>/dev/null || true) | wc -l | tr -d ' ')
    skipped_tests=$((skipped_tests + skip_count))
  done

  if [[ $skipped_tests -eq 0 ]]; then
    record_check "quality" "No skipped tests" "pass" "No .skip, xit, xdescribe, or @skip found"
  elif [[ $skipped_tests -le 3 ]]; then
    record_check "quality" "No skipped tests" "warn" "${skipped_tests} file(s) with skipped tests"
  else
    record_check "quality" "No skipped tests" "fail" "${skipped_tests} file(s) with skipped tests — fix or remove"
  fi

  # Check for console.log/print in tests (test pollution)
  local debug_in_tests=0
  for dir in "${TEST_DIRS[@]}"; do
    [[ ! -d "$dir" ]] && continue
    local dbg_count
    dbg_count=$( (grep -rl 'console\.log\|console\.debug\|print(' "$dir" 2>/dev/null || true) | wc -l | tr -d ' ')
    debug_in_tests=$((debug_in_tests + dbg_count))
  done

  if [[ $debug_in_tests -eq 0 ]]; then
    record_check "quality" "No debug logging in tests" "pass" "No console.log/print found in test files"
  elif [[ $debug_in_tests -le 5 ]]; then
    record_check "quality" "No debug logging in tests" "warn" "${debug_in_tests} file(s) with debug logging"
  else
    record_check "quality" "No debug logging in tests" "warn" "${debug_in_tests} file(s) with debug logging — clean up"
  fi

  # Check for .only (accidental test isolation)
  local only_in_tests=0
  for dir in "${TEST_DIRS[@]}"; do
    [[ ! -d "$dir" ]] && continue
    local only_count
    only_count=$( (grep -rl '\.only\|fdescribe(\|fit(' "$dir" 2>/dev/null || true) | wc -l | tr -d ' ')
    only_in_tests=$((only_in_tests + only_count))
  done

  if [[ $only_in_tests -eq 0 ]]; then
    record_check "quality" "No .only in tests" "pass" "No .only, fdescribe, or fit found"
  else
    record_check "quality" "No .only in tests" "fail" "${only_in_tests} file(s) with .only — will skip other tests"
  fi

  print_info ""
  print_info "Scan complete: ${TOTAL_CHECKS} checks (${PASSED_CHECKS} pass, ${FAILED_CHECKS} fail, ${WARNINGS} warn)"
}

#============================================================================
# Stage: Score - Calculate category and overall scores
#============================================================================

score_stage() {
  print_info "Stage: Calculating scores..."

  for category in hierarchy json_contract abstraction seeding data_isolation coverage quality; do
    local full_pass=0 half_pass=0 total_cat=0

    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      [[ "${line%%|*}" == "$category" ]] && { full_pass=$((full_pass + 1)); total_cat=$((total_cat + 1)); }
    done <<< "$(echo -e "$FINDINGS_PASS")"

    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      [[ "${line%%|*}" == "$category" ]] && { half_pass=$((half_pass + 1)); total_cat=$((total_cat + 1)); }
    done <<< "$(echo -e "$FINDINGS_WARN")"

    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      [[ "${line%%|*}" == "$category" ]] && total_cat=$((total_cat + 1))
    done <<< "$(echo -e "$FINDINGS_FAIL")"

    local score=0
    if [[ $total_cat -gt 0 ]]; then
      score=$(( (full_pass * 2 + half_pass) * 100 / (total_cat * 2) ))
    fi

    case "$category" in
      hierarchy)       SCORE_HIERARCHY=$score ;;
      json_contract)   SCORE_JSON_CONTRACT=$score ;;
      abstraction)     SCORE_ABSTRACTION=$score ;;
      seeding)         SCORE_SEEDING=$score ;;
      data_isolation)  SCORE_DATA_ISOLATION=$score ;;
      coverage)        SCORE_COVERAGE=$score ;;
      quality)         SCORE_QUALITY=$score ;;
    esac
  done

  # Weighted overall score (7 categories, 100% total):
  #   Hierarchy: 15%, JSON Contract: 20%, Abstraction: 15%,
  #   Seeding: 15%, Data Isolation: 15%, Coverage: 10%, Quality: 10%
  OVERALL_SCORE=$(( \
    (SCORE_HIERARCHY * 15 + SCORE_JSON_CONTRACT * 20 + SCORE_ABSTRACTION * 15 \
    + SCORE_SEEDING * 15 + SCORE_DATA_ISOLATION * 15 + SCORE_COVERAGE * 10 + SCORE_QUALITY * 10) / 100 ))

  print_info ""
  print_info "Category Scores:"
  print_info "  Target Hierarchy:     ${SCORE_HIERARCHY}/100     (weight: 15%)"
  print_info "  JSON Contract:        ${SCORE_JSON_CONTRACT}/100     (weight: 20%)"
  print_info "  Framework Abstraction: ${SCORE_ABSTRACTION}/100     (weight: 15%)"
  print_info "  Database Seeding:     ${SCORE_SEEDING}/100     (weight: 15%)"
  print_info "  Data Isolation:       ${SCORE_DATA_ISOLATION}/100     (weight: 15%)"
  print_info "  Coverage Config:      ${SCORE_COVERAGE}/100     (weight: 10%)"
  print_info "  Test Quality:         ${SCORE_QUALITY}/100     (weight: 10%)"
  print_info ""
  print_info "  Overall: ${OVERALL_SCORE}/100"
}

#============================================================================
# Stage: Report - Output structured JSON
#============================================================================

findings_to_json() {
  local findings="$1"
  local json="["
  local first=true

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    local cat name result detail
    IFS='|' read -r cat name result detail <<< "$line"
    [[ -z "$cat" ]] && continue

    if [[ "$first" == "true" ]]; then
      first=false
    else
      json="${json},"
    fi
    detail="${detail//\"/\\\"}"
    name="${name//\"/\\\"}"
    json="${json}{\"category\":\"${cat}\",\"check\":\"${name}\",\"result\":\"${result}\",\"detail\":\"${detail}\"}"
  done <<< "$(echo -e "$findings")"

  json="${json}]"
  echo "$json"
}

report_stage() {
  print_info "Stage: Generating audit report..."

  local status
  if [[ $OVERALL_SCORE -ge 90 ]]; then
    status="EXCELLENT"
  elif [[ $OVERALL_SCORE -ge 70 ]]; then
    status="GOOD"
  elif [[ $OVERALL_SCORE -ge 50 ]]; then
    status="FAIR"
  else
    status="NEEDS_WORK"
  fi

  local next_action
  if [[ $FAILED_CHECKS -gt 0 ]]; then
    next_action="generate_report_with_fixes"
  elif [[ $WARNINGS -gt 3 ]]; then
    next_action="generate_report_with_recommendations"
  else
    next_action="display_summary"
  fi

  local pass_json fail_json warn_json skip_json
  pass_json=$(findings_to_json "$FINDINGS_PASS")
  fail_json=$(findings_to_json "$FINDINGS_FAIL")
  warn_json=$(findings_to_json "$FINDINGS_WARN")
  skip_json=$(findings_to_json "$FINDINGS_SKIP")

  # Build components list
  local comp_json="["
  local first=true
  for c in "${COMPONENTS[@]}"; do
    if [[ "$first" == "true" ]]; then first=false; else comp_json="${comp_json},"; fi
    comp_json="${comp_json}\"${c}\""
  done
  comp_json="${comp_json}]"

  # Build runner scripts list
  local runner_json="["
  first=true
  for r in "${RUNNER_SCRIPTS[@]}"; do
    if [[ "$first" == "true" ]]; then first=false; else runner_json="${runner_json},"; fi
    runner_json="${runner_json}\"${r}\""
  done
  runner_json="${runner_json}]"

  # Build test dirs list
  local dirs_json="["
  first=true
  for d in "${TEST_DIRS[@]}"; do
    if [[ "$first" == "true" ]]; then first=false; else dirs_json="${dirs_json},"; fi
    dirs_json="${dirs_json}\"${d}\""
  done
  dirs_json="${dirs_json}]"

  local result
  result=$(cat <<EOF
{
  "audit_type": "testing",
  "project": "${APP_NAME}",
  "timestamp": "$(date -Iseconds)",
  "quick_mode": ${QUICK_MODE},
  "status": "${status}",
  "next_action": "${next_action}",
  "scores": {
    "overall": ${OVERALL_SCORE},
    "categories": {
      "target_hierarchy": ${SCORE_HIERARCHY},
      "json_contract": ${SCORE_JSON_CONTRACT},
      "framework_abstraction": ${SCORE_ABSTRACTION},
      "database_seeding": ${SCORE_SEEDING},
      "data_isolation": ${SCORE_DATA_ISOLATION},
      "coverage_config": ${SCORE_COVERAGE},
      "test_quality": ${SCORE_QUALITY}
    },
    "weights": {
      "target_hierarchy": 15,
      "json_contract": 20,
      "framework_abstraction": 15,
      "database_seeding": 15,
      "data_isolation": 15,
      "coverage_config": 10,
      "test_quality": 10
    }
  },
  "summary": {
    "total_checks": ${TOTAL_CHECKS},
    "passed": ${PASSED_CHECKS},
    "failed": ${FAILED_CHECKS},
    "warnings": ${WARNINGS}
  },
  "discovery": {
    "components": ${comp_json},
    "test_directories": ${dirs_json},
    "runner_scripts": ${runner_json},
    "min_coverage": ${MIN_COVERAGE:-0}
  },
  "findings": {
    "pass": ${pass_json},
    "fail": ${fail_json},
    "warn": ${warn_json},
    "skip": ${skip_json}
  },
  "reference_docs": {
    "testing": "~/.claude/docs/reference/testing.md",
    "makefile": "~/.claude/docs/reference/makefile.md"
  }
}
EOF
)

  echo "$result" > "$OUTPUT_FILE"   # file stays JSON for programmatic consumers
  log_json "$result"                # stdout = TOON in AI context, JSON otherwise

  print_info "Report written to: $OUTPUT_FILE"
}

#============================================================================
# Main
#============================================================================

main() {
  case "$STAGE" in
    scan)   scan_stage ;;
    score)  scan_stage; score_stage ;;
    report) scan_stage; score_stage; report_stage ;;
    all)    scan_stage; score_stage; report_stage ;;
    *)
      print_error "Invalid stage: $STAGE"
      echo "Valid stages: scan, score, report, all" >&2
      exit 2
      ;;
  esac
}

main
