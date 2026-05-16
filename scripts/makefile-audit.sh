#!/usr/bin/env bash
# makefile-audit.sh - Deterministic Makefile implementation audit with optional auto-fix
# Usage: ./makefile-audit.sh --stage <stage> [--quick] [--fix] [--full]
# Stages: scan, score, report, all (default)
# Flags:  --fix   Apply auto-fixable improvements after audit
#         --full  Run full audit (--stage all) then apply fixes
#
# Audits project Makefiles against the standards in:
#   ~/.claude/docs/reference/makefile.md
#   ~/.claude/docs/reference/testing.md
#
# Reads configuration from PROJECT.yaml (no environment variables).
# Outputs structured JSON to stdout, status messages to stderr.

set -euo pipefail

# Source shared libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"
source "${LIB_DIR}/common.sh"
source "${LIB_DIR}/project-config.sh"

# Configuration
STAGE="all"
QUICK_MODE=false
FIX_MODE=false
FULL_MODE=false
OUTPUT_FILE="/tmp/makefile-audit-result.json"

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --stage)    STAGE="$2"; shift 2 ;;
    --quick)    QUICK_MODE=true; shift ;;
    --output)   OUTPUT_FILE="$2"; shift 2 ;;
    --fix)      FIX_MODE=true; shift ;;
    --full)     FULL_MODE=true; shift ;;
    *)
      print_error "Unknown argument: $1"
      echo "Usage: makefile-audit.sh --stage <scan|score|report|all> [--quick] [--fix] [--full] [--output FILE]" >&2
      exit 2
      ;;
  esac
done

# --full implies audit (stage all) + fix
if [[ "$FULL_MODE" == "true" ]]; then
  STAGE="all"
  FIX_MODE=true
fi

# Require PROJECT.yaml
require_project_config

# Global state
APP_NAME=$(get_app_name)

# Scan results
TOTAL_CHECKS=0
PASSED_CHECKS=0
FAILED_CHECKS=0
WARNINGS=0

# Category scores
SCORE_STRUCTURE=0       # Project structure, file presence, .PHONY, .DEFAULT_GOAL
SCORE_HELP=0            # Self-documenting help recipe, ## annotations, arg annotations
SCORE_NAMING=0          # Target naming convention: <action>-<service>-<subtype>
SCORE_DELEGATION=0      # Root delegates to service Makefiles, --no-print-directory
SCORE_JSON_OUTPUT=0     # FORMAT=json support, ifdef FORMAT, _PASS, _SCRIPT_FLAGS
SCORE_TEST_ABSTRACTION=0 # Runner scripts, aggregation, framework abstraction
SCORE_SEEDING=0         # Database seeding strategy (_TEST_DB_SEEDED, leaf-only)

OVERALL_SCORE=0

# Findings
FINDINGS_PASS=""
FINDINGS_FAIL=""
FINDINGS_WARN=""
FINDINGS_SKIP=""

# Discovered Makefiles
MAKEFILES_FOUND=()
COMPONENTS=()

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

# Check if a file contains a pattern (case-insensitive by default)
file_has_pattern() {
  local file="$1"
  local pattern="$2"
  grep -qE "$pattern" "$file" 2>/dev/null
}

# Count pattern occurrences in file
count_pattern() {
  local file="$1"
  local pattern="$2"
  grep -cE "$pattern" "$file" 2>/dev/null || echo 0
}

#============================================================================
# Stage: Scan - Discover and check all Makefiles
#============================================================================

scan_stage() {
  print_info "Stage: Scanning Makefiles..."

  # Discover project components from PROJECT.yaml
  local comp_count
  comp_count=$(yaml_get '.components | length' PROJECT.yaml)
  [[ -z "$comp_count" ]] && comp_count=0

  for ((i=0; i<comp_count; i++)); do
    local comp_path
    comp_path=$(yaml_get ".components[$i].path" PROJECT.yaml)
    if [[ -n "$comp_path" && "$comp_path" != "null" ]]; then
      COMPONENTS+=("$comp_path")
    fi
  done

  # Discover Makefiles
  if [[ -f "Makefile" ]]; then
    MAKEFILES_FOUND+=("Makefile")
  fi
  for comp in "${COMPONENTS[@]}"; do
    if [[ -f "${comp}/Makefile" ]]; then
      MAKEFILES_FOUND+=("${comp}/Makefile")
    fi
  done

  #--- Category: Structure ---
  print_info ""
  print_info "Category: Structure"

  if [[ -f "Makefile" ]]; then
    record_check "structure" "Root Makefile exists" "pass" "Found Makefile"
  else
    record_check "structure" "Root Makefile exists" "fail" "No Makefile in project root"
  fi

  local missing_service_makes=()
  for comp in "${COMPONENTS[@]}"; do
    if [[ -f "${comp}/Makefile" ]]; then
      record_check "structure" "Service Makefile: ${comp}" "pass" "Found ${comp}/Makefile"
    else
      record_check "structure" "Service Makefile: ${comp}" "fail" "Missing ${comp}/Makefile"
      missing_service_makes+=("$comp")
    fi
  done

  for mf in "${MAKEFILES_FOUND[@]}"; do
    if file_has_pattern "$mf" '^\.PHONY:'; then
      record_check "structure" ".PHONY declarations (${mf})" "pass" "Has .PHONY"
    else
      record_check "structure" ".PHONY declarations (${mf})" "fail" "Missing .PHONY declarations"
    fi

    if file_has_pattern "$mf" '^\.DEFAULT_GOAL\s*:=\s*help'; then
      record_check "structure" ".DEFAULT_GOAL := help (${mf})" "pass" "Default target is help"
    else
      record_check "structure" ".DEFAULT_GOAL := help (${mf})" "warn" "Missing .DEFAULT_GOAL := help"
    fi
  done

  #--- Category: Help ---
  print_info ""
  print_info "Category: Help System"

  for mf in "${MAKEFILES_FOUND[@]}"; do
    # Check for awk-based help (correct) vs grep-based (old)
    if file_has_pattern "$mf" "awk.*a-zA-Z0-9_-.*## "; then
      record_check "help" "Awk-based help recipe (${mf})" "pass" "Uses awk with digit support"
    elif file_has_pattern "$mf" "awk.*a-zA-Z_-.*## "; then
      record_check "help" "Awk-based help recipe (${mf})" "warn" "Awk help missing digits in char class [a-zA-Z_-] — targets with numbers (e.g. test-e2e) won't show"
    elif file_has_pattern "$mf" "grep.*## "; then
      record_check "help" "Awk-based help recipe (${mf})" "fail" "Uses old grep-based help — does not support argument annotations"
    else
      record_check "help" "Awk-based help recipe (${mf})" "fail" "No self-documenting help recipe found"
    fi

    # Check for ## annotations on targets
    local target_count annotated_count
    target_count=$(count_pattern "$mf" '^[a-zA-Z0-9_-]+:')
    annotated_count=$(count_pattern "$mf" '^[a-zA-Z0-9_-]+:.*## ')
    if [[ $target_count -gt 0 ]]; then
      local pct=$((annotated_count * 100 / target_count))
      if [[ $pct -ge 80 ]]; then
        record_check "help" "Target ## annotations (${mf})" "pass" "${annotated_count}/${target_count} targets annotated (${pct}%)"
      elif [[ $pct -ge 50 ]]; then
        record_check "help" "Target ## annotations (${mf})" "warn" "${annotated_count}/${target_count} targets annotated (${pct}%) — aim for 80%+"
      else
        record_check "help" "Target ## annotations (${mf})" "fail" "Only ${annotated_count}/${target_count} targets annotated (${pct}%)"
      fi
    fi

    # Check for ##   argument annotations on test targets
    if file_has_pattern "$mf" '^##   [A-Z]+='; then
      record_check "help" "Argument ##   annotations (${mf})" "pass" "Has argument annotations"
    else
      # Only warn if the Makefile has test targets with FORMAT support
      if file_has_pattern "$mf" 'ifdef FORMAT|FORMAT='; then
        record_check "help" "Argument ##   annotations (${mf})" "warn" "Has FORMAT support but no ##   argument annotations"
      else
        record_check "help" "Argument ##   annotations (${mf})" "skip" "No FORMAT support — argument annotations not applicable"
      fi
    fi
  done

  #--- Category: Naming Convention ---
  print_info ""
  print_info "Category: Naming Convention"

  if [[ -f "Makefile" ]]; then
    # Check for <action>-<service> pattern in root Makefile
    local has_delegating=false
    for comp in "${COMPONENTS[@]}"; do
      if file_has_pattern "Makefile" "^test-${comp}:"; then
        has_delegating=true
        record_check "naming" "test-${comp} target exists" "pass" "Found test-${comp}"
      elif file_has_pattern "Makefile" "^test-${comp:0:1}:"; then
        has_delegating=true
        record_check "naming" "test-${comp} target naming" "warn" "Uses abbreviated name test-${comp:0:1} — full names (test-${comp}) preferred"
      fi
    done

    if [[ "$has_delegating" == "false" && ${#COMPONENTS[@]} -gt 0 ]]; then
      record_check "naming" "Delegating test targets" "fail" "No test-<service> targets found in root Makefile"
    fi

    # Check for <action>-<service>-<subtype> pattern
    local has_subtypes=false
    for comp in "${COMPONENTS[@]}"; do
      if file_has_pattern "Makefile" "^test-${comp}-"; then
        has_subtypes=true
      fi
    done

    if [[ "$has_subtypes" == "true" ]]; then
      record_check "naming" "Sub-type targets (test-<service>-<type>)" "pass" "Found test-<service>-<subtype> targets"
    elif [[ ${#COMPONENTS[@]} -gt 0 ]]; then
      record_check "naming" "Sub-type targets (test-<service>-<type>)" "warn" "No test-<service>-<subtype> targets in root"
    fi
  fi

  #--- Category: Delegation ---
  print_info ""
  print_info "Category: Delegation"

  if [[ -f "Makefile" ]]; then
    for comp in "${COMPONENTS[@]}"; do
      if [[ ! -f "${comp}/Makefile" ]]; then continue; fi

      if file_has_pattern "Makefile" "MAKE.*-C ${comp}"; then
        record_check "delegation" "Root delegates to ${comp}" "pass" "Found \$(MAKE) -C ${comp}"
      else
        record_check "delegation" "Root delegates to ${comp}" "fail" "Root Makefile doesn't delegate to ${comp}/Makefile"
      fi
    done

    # Check for --no-print-directory
    if file_has_pattern "Makefile" 'no-print-directory'; then
      record_check "delegation" "--no-print-directory on sub-makes" "pass" "Uses --no-print-directory"
    else
      record_check "delegation" "--no-print-directory on sub-makes" "warn" "Missing --no-print-directory — JSON output may contain Make directory banners"
    fi
  fi

  #--- Category: JSON Output ---
  print_info ""
  print_info "Category: JSON Output"

  for mf in "${MAKEFILES_FOUND[@]}"; do
    if file_has_pattern "$mf" 'ifdef FORMAT|ifeq.*FORMAT'; then
      record_check "json_output" "FORMAT branching (${mf})" "pass" "Has FORMAT-based branching"
    else
      record_check "json_output" "FORMAT branching (${mf})" "warn" "No FORMAT=json support"
    fi
  done

  if [[ -f "Makefile" ]]; then
    if file_has_pattern "Makefile" '_PASS\s*=|_PASS='; then
      record_check "json_output" "_PASS variable (root)" "pass" "Forwards FORMAT/FILES/FILTER via _PASS"
    else
      record_check "json_output" "_PASS variable (root)" "warn" "No _PASS variable — args may not forward to sub-makes"
    fi
  fi

  for comp in "${COMPONENTS[@]}"; do
    local mf="${comp}/Makefile"
    [[ ! -f "$mf" ]] && continue

    if file_has_pattern "$mf" '_SCRIPT_FLAGS\s*=|_SCRIPT_FLAGS='; then
      record_check "json_output" "_SCRIPT_FLAGS variable (${comp})" "pass" "Translates make vars to script flags"
    elif file_has_pattern "$mf" 'ifdef FORMAT'; then
      record_check "json_output" "_SCRIPT_FLAGS variable (${comp})" "warn" "Has FORMAT support but no _SCRIPT_FLAGS"
    else
      record_check "json_output" "_SCRIPT_FLAGS variable (${comp})" "skip" "No FORMAT support"
    fi

    if file_has_pattern "$mf" '_PASS\s*=|_PASS='; then
      record_check "json_output" "_PASS variable (${comp})" "pass" "Forwards args to sub-makes"
    elif file_has_pattern "$mf" 'ifdef FORMAT'; then
      record_check "json_output" "_PASS variable (${comp})" "warn" "Has FORMAT support but no _PASS"
    else
      record_check "json_output" "_PASS variable (${comp})" "skip" "No FORMAT support"
    fi
  done

  #--- Category: Test Abstraction ---
  print_info ""
  print_info "Category: Test Abstraction"

  # Check for runner scripts
  local has_runners=false
  if [[ -d "scripts" ]]; then
    local runner_count=0
    for pattern in test-jest test-playwright test-pytest test-newman test-bats test-aggregate; do
      if [[ -f "scripts/${pattern}.sh" ]]; then
        runner_count=$((runner_count + 1))
        has_runners=true
      fi
    done

    if [[ $runner_count -gt 0 ]]; then
      record_check "test_abstraction" "Runner scripts exist" "pass" "Found ${runner_count} runner script(s) in scripts/"
    else
      record_check "test_abstraction" "Runner scripts exist" "warn" "No test runner scripts in scripts/"
    fi

    if [[ -f "scripts/test-aggregate.sh" ]]; then
      record_check "test_abstraction" "Aggregation script" "pass" "test-aggregate.sh exists"
    else
      record_check "test_abstraction" "Aggregation script" "warn" "No test-aggregate.sh — aggregator targets may not produce standard JSON"
    fi
  else
    record_check "test_abstraction" "Scripts directory" "warn" "No scripts/ directory"
  fi

  # Check that service Makefiles call runner scripts (not tools directly) in FORMAT mode
  for comp in "${COMPONENTS[@]}"; do
    local mf="${comp}/Makefile"
    [[ ! -f "$mf" ]] && continue

    if file_has_pattern "$mf" 'scripts/test-.*\.sh'; then
      record_check "test_abstraction" "Runner script usage (${comp})" "pass" "Calls runner scripts in FORMAT mode"
    elif file_has_pattern "$mf" 'ifdef FORMAT'; then
      record_check "test_abstraction" "Runner script usage (${comp})" "warn" "Has FORMAT support but calls tools directly instead of runner scripts"
    else
      record_check "test_abstraction" "Runner script usage (${comp})" "skip" "No FORMAT support"
    fi
  done

  # Check aggregation pattern in Makefiles (tmpdir + test-aggregate.sh)
  for mf in "${MAKEFILES_FOUND[@]}"; do
    if file_has_pattern "$mf" 'mktemp.*-d.*test-aggregate'; then
      record_check "test_abstraction" "Aggregation pattern (${mf})" "pass" "Uses tmpdir + test-aggregate.sh for combining results"
    elif file_has_pattern "$mf" 'test-aggregate'; then
      record_check "test_abstraction" "Aggregation pattern (${mf})" "pass" "References test-aggregate.sh"
    elif file_has_pattern "$mf" 'ifdef FORMAT'; then
      # Only check if this Makefile has aggregate targets (calls sub-targets)
      if file_has_pattern "$mf" 'MAKE.*test-'; then
        record_check "test_abstraction" "Aggregation pattern (${mf})" "warn" "Calls sub-test-targets but doesn't aggregate JSON results"
      fi
    fi
  done

  #--- Category: Seeding Strategy ---
  print_info ""
  print_info "Category: Database Seeding"

  if [[ "$QUICK_MODE" == "true" ]]; then
    record_check "seeding" "Seeding checks" "skip" "Skipped in quick mode"
  else
    # Check for _TEST_DB_SEEDED pattern
    local has_seed_guard=false
    for mf in "${MAKEFILES_FOUND[@]}"; do
      if file_has_pattern "$mf" '_TEST_DB_SEEDED'; then
        has_seed_guard=true
        record_check "seeding" "Seed guard variable (${mf})" "pass" "Uses _TEST_DB_SEEDED env var"
      fi
    done

    if [[ "$has_seed_guard" == "false" ]]; then
      # Check if there are any seed targets at all
      local has_seed_target=false
      for mf in "${MAKEFILES_FOUND[@]}"; do
        if file_has_pattern "$mf" 'seed'; then
          has_seed_target=true
        fi
      done

      if [[ "$has_seed_target" == "true" ]]; then
        record_check "seeding" "Seed-once guard" "warn" "Has seed targets but no _TEST_DB_SEEDED guard — tests may seed multiple times"
      else
        record_check "seeding" "Seed-once guard" "skip" "No seed targets found"
      fi
    fi

    # Check that seed prerequisite is on leaf targets only (not aggregators)
    for comp in "${COMPONENTS[@]}"; do
      local mf="${comp}/Makefile"
      [[ ! -f "$mf" ]] && continue

      if file_has_pattern "$mf" '_seed-test-db|seed-test-db'; then
        # Check if aggregator targets (test:) have the seed prerequisite (they shouldn't)
        if grep -qE '^test:.*seed' "$mf" 2>/dev/null; then
          record_check "seeding" "Leaf-only seeding (${comp})" "warn" "Aggregator target 'test' has seed prerequisite — only leaf targets should seed"
        else
          record_check "seeding" "Leaf-only seeding (${comp})" "pass" "Seed prerequisite on leaf targets only"
        fi
      fi
    done

    # Check for file-based sentinel (anti-pattern)
    for mf in "${MAKEFILES_FOUND[@]}"; do
      if file_has_pattern "$mf" '/tmp/.*seed.*touch|touch.*/tmp/.*seed'; then
        record_check "seeding" "No file-based sentinel (${mf})" "fail" "Uses file-based seed sentinel — survives Ctrl+C, use env var instead"
      fi
    done
  fi

  print_info ""
  print_info "Scan complete: ${TOTAL_CHECKS} checks (${PASSED_CHECKS} pass, ${FAILED_CHECKS} fail, ${WARNINGS} warn)"
}

#============================================================================
# Stage: Score - Calculate category and overall scores
#============================================================================

score_stage() {
  print_info "Stage: Calculating scores..."

  for category in structure help naming delegation json_output test_abstraction seeding; do
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
      structure)        SCORE_STRUCTURE=$score ;;
      help)             SCORE_HELP=$score ;;
      naming)           SCORE_NAMING=$score ;;
      delegation)       SCORE_DELEGATION=$score ;;
      json_output)      SCORE_JSON_OUTPUT=$score ;;
      test_abstraction) SCORE_TEST_ABSTRACTION=$score ;;
      seeding)          SCORE_SEEDING=$score ;;
    esac
  done

  # Weighted overall score (7 categories, 100% total):
  #   Structure: 15%, Help: 10%, Naming: 15%, Delegation: 15%,
  #   JSON Output: 20%, Test Abstraction: 15%, Seeding: 10%
  OVERALL_SCORE=$(( \
    (SCORE_STRUCTURE * 15 + SCORE_HELP * 10 + SCORE_NAMING * 15 + SCORE_DELEGATION * 15 \
    + SCORE_JSON_OUTPUT * 20 + SCORE_TEST_ABSTRACTION * 15 + SCORE_SEEDING * 10) / 100 ))

  print_info ""
  print_info "Category Scores:"
  print_info "  Structure:          ${SCORE_STRUCTURE}/100  (weight: 15%)"
  print_info "  Help System:        ${SCORE_HELP}/100  (weight: 10%)"
  print_info "  Naming Convention:  ${SCORE_NAMING}/100  (weight: 15%)"
  print_info "  Delegation:         ${SCORE_DELEGATION}/100  (weight: 15%)"
  print_info "  JSON Output:        ${SCORE_JSON_OUTPUT}/100  (weight: 20%)"
  print_info "  Test Abstraction:   ${SCORE_TEST_ABSTRACTION}/100  (weight: 15%)"
  print_info "  Database Seeding:   ${SCORE_SEEDING}/100  (weight: 10%)"
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

  # Build Makefiles list
  local files_json="["
  local first=true
  for f in "${MAKEFILES_FOUND[@]}"; do
    if [[ "$first" == "true" ]]; then first=false; else files_json="${files_json},"; fi
    files_json="${files_json}\"${f}\""
  done
  files_json="${files_json}]"

  # Build components list
  local comp_json="["
  first=true
  for c in "${COMPONENTS[@]}"; do
    if [[ "$first" == "true" ]]; then first=false; else comp_json="${comp_json},"; fi
    comp_json="${comp_json}\"${c}\""
  done
  comp_json="${comp_json}]"

  local result
  result=$(cat <<EOF
{
  "audit_type": "makefile",
  "project": "${APP_NAME}",
  "timestamp": "$(date -Iseconds)",
  "quick_mode": ${QUICK_MODE},
  "status": "${status}",
  "next_action": "${next_action}",
  "scores": {
    "overall": ${OVERALL_SCORE},
    "categories": {
      "structure": ${SCORE_STRUCTURE},
      "help_system": ${SCORE_HELP},
      "naming_convention": ${SCORE_NAMING},
      "delegation": ${SCORE_DELEGATION},
      "json_output": ${SCORE_JSON_OUTPUT},
      "test_abstraction": ${SCORE_TEST_ABSTRACTION},
      "database_seeding": ${SCORE_SEEDING}
    },
    "weights": {
      "structure": 15,
      "help_system": 10,
      "naming_convention": 15,
      "delegation": 15,
      "json_output": 20,
      "test_abstraction": 15,
      "database_seeding": 10
    }
  },
  "summary": {
    "total_checks": ${TOTAL_CHECKS},
    "passed": ${PASSED_CHECKS},
    "failed": ${FAILED_CHECKS},
    "warnings": ${WARNINGS}
  },
  "components": ${comp_json},
  "findings": {
    "pass": ${pass_json},
    "fail": ${fail_json},
    "warn": ${warn_json},
    "skip": ${skip_json}
  },
  "files_scanned": ${files_json},
  "reference_docs": {
    "makefile": "~/.claude/docs/reference/makefile.md",
    "testing": "~/.claude/docs/reference/testing.md"
  }
}
EOF
)

  echo "$result" > "$OUTPUT_FILE"
  echo "$result"

  print_info "Report written to: $OUTPUT_FILE"
}

#============================================================================
# Stage: Fix - Apply auto-fixable improvements to discovered Makefiles
#
# Auto-fixable issues (ported from makefile-optimize.sh):
#   - Missing FORMAT ?= human
#   - Missing MAKEFLAGS += --no-print-directory
#   - Missing JSON_WRAPPER variable
#   - Missing targets meta-target
#
# Non-auto-fixable (manual, as documented in makefile-optimize.sh):
#   - Adding ifeq ($(FORMAT),json) branches to existing targets
#   - Adding missing standard targets (test, lint, format, etc.)
#   - Adding @ prefix to recipe lines
#============================================================================

fix_stage() {
  print_info "Stage: Applying auto-fixes..."

  if [[ ${#MAKEFILES_FOUND[@]} -eq 0 ]]; then
    print_error "No Makefiles found — run scan first or ensure Makefiles exist"
    return 1
  fi

  local fixes_applied=0
  local fixed_files=()

  for makefile in "${MAKEFILES_FOUND[@]}"; do
    local modified=false

    # Fix: Add FORMAT ?= human (and companion vars) if missing.
    # When inserting, we add FORMAT, MAKEFLAGS, and JSON_WRAPPER together as a
    # cohesive block rather than individually, to avoid partial states.
    if ! grep -q 'FORMAT ?= human' "$makefile"; then
      local temp_file
      temp_file=$(mktemp)
      if grep -q '^\.PHONY:' "$makefile"; then
        # Insert the block after the first .PHONY line
        awk '/^\.PHONY:/{print; print ""; print "# LLM-optimized output support"; print "FORMAT ?= human"; print "MAKEFLAGS += --no-print-directory"; print "JSON_WRAPPER ?= $(HOME)/.claude/scripts/lib/make-json-wrapper.sh"; next}1' "$makefile" > "$temp_file"
      else
        {
          printf '# LLM-optimized output support\n'
          printf 'FORMAT ?= human\n'
          printf 'MAKEFLAGS += --no-print-directory\n'
          printf 'JSON_WRAPPER ?= $(HOME)/.claude/scripts/lib/make-json-wrapper.sh\n'
          printf '\n'
          cat "$makefile"
        } > "$temp_file"
      fi
      mv "$temp_file" "$makefile"
      modified=true
      fixes_applied=$((fixes_applied + 3))
      print_success "Fixed: Added FORMAT/MAKEFLAGS/JSON_WRAPPER to ${makefile}"
    else
      # FORMAT already exists — patch MAKEFLAGS and JSON_WRAPPER individually if absent

      if ! grep -q 'MAKEFLAGS.*--no-print-directory' "$makefile"; then
        # macOS sed requires empty string for in-place without backup
        sed -i'' '/FORMAT ?= human/a\'$'\nMAKEFLAGS += --no-print-directory' "$makefile"
        modified=true
        fixes_applied=$((fixes_applied + 1))
        print_success "Fixed: Added MAKEFLAGS to ${makefile}"
      fi

      if ! grep -q 'JSON_WRAPPER' "$makefile"; then
        sed -i'' '/MAKEFLAGS.*--no-print-directory/a\'$'\nJSON_WRAPPER ?= $(HOME)/.claude/scripts/lib/make-json-wrapper.sh' "$makefile"
        modified=true
        fixes_applied=$((fixes_applied + 1))
        print_success "Fixed: Added JSON_WRAPPER to ${makefile}"
      fi
    fi

    # Fix: Add targets meta-target if missing.
    # The targets target emits a JSON list of available targets in FORMAT=json mode
    # and falls back to `make help` in human mode.
    if ! grep -qE '^targets:' "$makefile"; then
      local component_name
      component_name=$(basename "$(dirname "$(realpath "$makefile")")")
      [[ "$makefile" == "Makefile" ]] && component_name="root"
      # Use printf to avoid heredoc tab-stripping issues with Makefile recipe indentation
      printf '\ntargets: ## List all available targets\nifeq ($(FORMAT),json)\n\t@echo '"'"'{"status":"success","target":"targets","component":"%s","targets":[]}'"'"'\nelse\n\t@$(MAKE) help\nendif\n' "$component_name" >> "$makefile"
      modified=true
      fixes_applied=$((fixes_applied + 1))
      print_success "Fixed: Added targets meta-target to ${makefile}"
    fi

    [[ "$modified" == "true" ]] && fixed_files+=("$makefile")
  done

  print_info ""
  print_info "Auto-fix complete: ${fixes_applied} fix(es) applied to ${#fixed_files[@]} file(s)"

  # Build fixed files JSON array
  local fixed_json="["
  local first=true
  for f in "${fixed_files[@]}"; do
    if [[ "$first" == "true" ]]; then first=false; else fixed_json="${fixed_json},"; fi
    fixed_json="${fixed_json}\"${f}\""
  done
  fixed_json="${fixed_json}]"

  # Emit a concise JSON summary for fix-only mode; in full mode the caller
  # already has the audit report and only needs to know what was patched.
  local fix_result
  fix_result=$(cat <<EOF
{
  "fix_stage": {
    "fixes_applied": ${fixes_applied},
    "files_modified": ${fixed_json}
  }
}
EOF
)

  # Merge fix summary into the existing audit result file if it exists, otherwise emit standalone
  if [[ -f "$OUTPUT_FILE" ]]; then
    local merged
    merged=$(python3 -c "
import sys, json
audit = json.load(open('$OUTPUT_FILE'))
fix = json.load(sys.stdin)
audit.update(fix)
print(json.dumps(audit, indent=2))
" <<< "$fix_result" 2>/dev/null || true)
    if [[ -n "$merged" ]]; then
      echo "$merged" > "$OUTPUT_FILE"
      print_info "Fix summary merged into: $OUTPUT_FILE"
    fi
  else
    echo "$fix_result" > "$OUTPUT_FILE"
    echo "$fix_result"
    print_info "Fix summary written to: $OUTPUT_FILE"
  fi
}

#============================================================================
# Main
#============================================================================

main() {
  case "$STAGE" in
    scan)
      scan_stage
      ;;
    score)
      scan_stage
      score_stage
      ;;
    report)
      scan_stage
      score_stage
      report_stage
      ;;
    all)
      scan_stage
      score_stage
      report_stage
      ;;
    *)
      print_error "Invalid stage: $STAGE"
      echo "Valid stages: scan, score, report, all" >&2
      exit 2
      ;;
  esac

  # Apply fixes after audit if requested
  if [[ "$FIX_MODE" == "true" ]]; then
    fix_stage
  fi
}

main
