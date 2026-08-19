#!/usr/bin/env bash
# makefile-audit.sh - Deterministic Makefile implementation audit
# Usage: ./makefile-audit.sh --stage <stage> [--quick]
# Stages: scan, score, report, all (default)
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
source "${LIB_DIR}/output-framework.sh"  # log_json: TOON for AI callers

# Configuration
STAGE="all"
QUICK_MODE=false
OUTPUT_FILE="/tmp/makefile-audit-result.json"

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --stage)    STAGE="$2"; shift 2 ;;
    --quick)    QUICK_MODE=true; shift ;;
    --output)   OUTPUT_FILE="$2"; shift 2 ;;
    *)
      print_error "Unknown argument: $1"
      echo "Usage: makefile-audit.sh --stage <scan|score|report|all> [--quick] [--output FILE]" >&2
      exit 2
      ;;
  esac
done

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
  grep -cE "$pattern" "$file" 2>/dev/null || true
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

    if file_has_pattern "$mf" '^\.DEFAULT_GOAL[[:space:]]*:=[[:space:]]*help'; then
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
    # The awk help recipe may be split across backslash-continued lines, so match
    # its components independently rather than on a single physical line.
    if file_has_pattern "$mf" "awk" && file_has_pattern "$mf" 'a-zA-Z0-9_-.*## '; then
      record_check "help" "Awk-based help recipe (${mf})" "pass" "Uses awk with digit support"
    elif file_has_pattern "$mf" "awk" && file_has_pattern "$mf" 'a-zA-Z_-.*## '; then
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

  # FORMAT support = either in-Makefile branching (ifdef/ifeq) OR the runner-script
  # pattern where FORMAT is defaulted (FORMAT ?=) and forwarded inline to scripts
  # (FORMAT=$(FORMAT) ./scripts/run-*.sh). Both keep JSON output AI-consumable.
  local FORMAT_SUPPORT='ifdef FORMAT|ifeq.*FORMAT|FORMAT[[:space:]]*[?]=|FORMAT=[$][(]FORMAT[)]'
  for mf in "${MAKEFILES_FOUND[@]}"; do
    if file_has_pattern "$mf" 'ifdef FORMAT|ifeq.*FORMAT'; then
      record_check "json_output" "FORMAT branching (${mf})" "pass" "Has FORMAT-based branching"
    elif file_has_pattern "$mf" 'FORMAT[[:space:]]*[?]=' && file_has_pattern "$mf" 'FORMAT=[$][(]FORMAT[)]'; then
      record_check "json_output" "FORMAT branching (${mf})" "pass" "Forwards FORMAT inline to runner scripts / sub-makes"
    else
      record_check "json_output" "FORMAT branching (${mf})" "warn" "No FORMAT=json support"
    fi
  done

  if [[ -f "Makefile" ]]; then
    if file_has_pattern "Makefile" '_PASS[[:space:]]*='; then
      record_check "json_output" "_PASS variable (root)" "pass" "Forwards FORMAT/FILES/FILTER via _PASS"
    elif file_has_pattern "Makefile" 'FORMAT=[$][(]FORMAT[)]'; then
      record_check "json_output" "_PASS variable (root)" "pass" "Forwards FORMAT inline to sub-makes (FILES/FILTER via env inheritance)"
    else
      record_check "json_output" "_PASS variable (root)" "warn" "No _PASS variable — args may not forward to sub-makes"
    fi
  fi

  for comp in "${COMPONENTS[@]}"; do
    local mf="${comp}/Makefile"
    [[ ! -f "$mf" ]] && continue

    if file_has_pattern "$mf" '_SCRIPT_FLAGS[[:space:]]*='; then
      record_check "json_output" "_SCRIPT_FLAGS variable (${comp})" "pass" "Translates make vars to script flags"
    elif file_has_pattern "$mf" 'FORMAT=[$][(]FORMAT[)].*scripts/(run|test)-'; then
      record_check "json_output" "_SCRIPT_FLAGS variable (${comp})" "pass" "Passes FORMAT to runner scripts inline"
    elif file_has_pattern "$mf" "$FORMAT_SUPPORT"; then
      record_check "json_output" "_SCRIPT_FLAGS variable (${comp})" "warn" "Has FORMAT support but no _SCRIPT_FLAGS"
    else
      record_check "json_output" "_SCRIPT_FLAGS variable (${comp})" "skip" "No FORMAT support"
    fi

    if file_has_pattern "$mf" '_PASS[[:space:]]*='; then
      record_check "json_output" "_PASS variable (${comp})" "pass" "Forwards args to sub-makes"
    elif file_has_pattern "$mf" 'FORMAT=[$][(]FORMAT[)]'; then
      record_check "json_output" "_PASS variable (${comp})" "pass" "Forwards FORMAT inline (FILES/FILTER via env inheritance)"
    elif file_has_pattern "$mf" "$FORMAT_SUPPORT"; then
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
    # Wiki spec: runner scripts use the run-<tool>.sh naming convention.
    local runner_count=0
    for tool in jest playwright pytest newman bats aggregate eslint; do
      if [[ -f "scripts/run-${tool}.sh" ]]; then
        runner_count=$((runner_count + 1))
        has_runners=true
      fi
    done

    if [[ $runner_count -gt 0 ]]; then
      record_check "test_abstraction" "Runner scripts exist" "pass" "Found ${runner_count} run-<tool>.sh runner script(s) in scripts/"
    else
      record_check "test_abstraction" "Runner scripts exist" "warn" "No run-<tool>.sh runner scripts in scripts/"
    fi

    if [[ -f "scripts/run-aggregate.sh" ]]; then
      record_check "test_abstraction" "Aggregation script" "pass" "run-aggregate.sh exists"
    else
      record_check "test_abstraction" "Aggregation script" "warn" "No run-aggregate.sh — aggregator targets may not produce standard JSON"
    fi
  else
    record_check "test_abstraction" "Scripts directory" "warn" "No scripts/ directory"
  fi

  # Check that service Makefiles call runner scripts (not tools directly) in FORMAT mode
  for comp in "${COMPONENTS[@]}"; do
    local mf="${comp}/Makefile"
    [[ ! -f "$mf" ]] && continue

    if file_has_pattern "$mf" '(scripts/|SCRIPTS_DIR[)}]/)run-.*\.sh'; then
      record_check "test_abstraction" "Runner script usage (${comp})" "pass" "Calls runner scripts in FORMAT mode"
    elif file_has_pattern "$mf" "$FORMAT_SUPPORT"; then
      record_check "test_abstraction" "Runner script usage (${comp})" "warn" "Has FORMAT support but calls tools directly instead of runner scripts"
    else
      record_check "test_abstraction" "Runner script usage (${comp})" "skip" "No FORMAT support"
    fi
  done

  # Check aggregation pattern in Makefiles (tmpdir + aggregate runner script)
  for mf in "${MAKEFILES_FOUND[@]}"; do
    if file_has_pattern "$mf" 'mktemp.*-d.*run-aggregate'; then
      record_check "test_abstraction" "Aggregation pattern (${mf})" "pass" "Uses tmpdir + run-aggregate.sh for combining results"
    elif file_has_pattern "$mf" 'run-aggregate'; then
      record_check "test_abstraction" "Aggregation pattern (${mf})" "pass" "References run-aggregate.sh"
    elif file_has_pattern "$mf" "$FORMAT_SUPPORT"; then
      # Only check if this Makefile has aggregate targets (calls sub-targets)
      if file_has_pattern "$mf" 'MAKE.*test-'; then
        record_check "test_abstraction" "Aggregation pattern (${mf})" "warn" "Calls sub-test-targets but doesn't aggregate JSON results"
      fi
    fi
  done

  # Runner-script hygiene for docker-based local runners (wiki: patterns/
  # makefile-hierarchy.md). Only applies when runner scripts drive docker.
  local docker_runners=()
  if [[ -d "scripts" ]]; then
    for rs in scripts/run-*.sh scripts/ensure-test-image.sh scripts/test-image.sh; do
      [[ -f "$rs" ]] || continue
      if file_has_pattern "$rs" 'docker (run|build)'; then
        docker_runners+=("$rs")
      fi
    done
  fi

  if [[ ${#docker_runners[@]} -gt 0 ]]; then
    # (1) Per-worktree test image tag: a shared tag with per-checkout freshness
    # stamps makes sibling worktrees invalidate each other (rebuild ping-pong).
    if [[ -f "scripts/test-image.sh" ]] || [[ -f "scripts/test-image-name.sh" ]] || { [[ -f "scripts/ensure-test-image.sh" ]] && file_has_pattern "scripts/ensure-test-image.sh" 'cksum.*IMG|IMG=.*cksum|test-image-name'; }; then
      record_check "test_abstraction" "Per-worktree test image tag" "pass" "Test image tag keyed to checkout path"
    else
      record_check "test_abstraction" "Per-worktree test image tag" "warn" "Docker test runners appear to share one image tag across worktrees — concurrent worktrees force rebuild ping-pong. Key the tag to the checkout path (wiki: makefile-hierarchy.md)"
    fi

    # (2) Jest positional patterns must precede array options: yargs array
    # options (--testPathIgnorePatterns) swallow a following *positional*, so a
    # bare FILES positional after them silently stops scoping and the full suite
    # runs. Emitting FILES/FILTER as NAMED flags (--testPathPattern / -t) is
    # immune to ordering — yargs binds them regardless of position — so treat the
    # named-flag form as safe even when EXTRA_ARGS trails --testPathIgnorePatterns.
    if [[ -f "scripts/run-jest.sh" ]]; then
      local joined_jest
      joined_jest=$(perl -0pe 's/\\\n/ /g' scripts/run-jest.sh 2>/dev/null || cat scripts/run-jest.sh)
      if grep -qE 'EXTRA_ARGS\+=\([^)]*--testPathPattern' <<< "$joined_jest"; then
        record_check "test_abstraction" "Jest args before array options" "pass" "FILES scoped via named --testPathPattern flag (position-independent, immune to array-option swallow)"
      elif grep -qE 'testPathIgnorePatterns[^)]*("\$\{EXTRA_ARGS\[@\]\}"|\$FILES|\$\{FILES\})' <<< "$joined_jest"; then
        record_check "test_abstraction" "Jest args before array options" "fail" "run-jest.sh passes FILES/EXTRA_ARGS after --testPathIgnorePatterns as a bare positional — the array option swallows it and FILES/FILTER silently don't scope; emit FILES as --testPathPattern instead (wiki: makefile-hierarchy.md)"
      else
        record_check "test_abstraction" "Jest args before array options" "pass" "Positional patterns precede array options in run-jest.sh"
      fi
    fi

    # (3) Interrupt cleanup: docker run --rm only removes the container on
    # normal exit; Ctrl+C leaks it and leaked runs snowball VM load.
    for rs in "${docker_runners[@]}"; do
      file_has_pattern "$rs" 'docker run' || continue
      if file_has_pattern "$rs" 'cidfile' && file_has_pattern "$rs" '^\s*trap |trap ['\''"]'; then
        record_check "test_abstraction" "Container cleanup on interrupt (${rs})" "pass" "Uses --cidfile + trap cleanup"
      else
        record_check "test_abstraction" "Container cleanup on interrupt (${rs})" "warn" "docker run without --cidfile + trap — interrupted runs leak containers (wiki: makefile-hierarchy.md)"
      fi
    done

    # (4) OOM-kill detection: a containerized runner is the first casualty when
    # the Docker VM runs out of memory. SIGKILL means the tool emits NOTHING and
    # the runner exits 137 (128+9; 139 = 128+11 SIGSEGV from the same pressure).
    # For tools that are silent when clean — tsc --noEmit, eslint — an OOM is
    # therefore indistinguishable from a pass to any caller judging by output,
    # which is a green check on code that was never analysed. Prefer ONE shared
    # guard sourced by every runner over per-runner copies.
    local oom_guard_lib=""
    for candidate in scripts/lib/oom-guard.sh scripts/oom-guard.sh scripts/lib/docker-guard.sh; do
      [[ -f "$candidate" ]] && { oom_guard_lib="$candidate"; break; }
    done

    if [[ -n "$oom_guard_lib" ]]; then
      # A guard that unconditionally runs `set -e` switches errexit ON in a caller
      # that had it off, so its own non-zero return aborts that caller mid-script
      # — empty output, exit 137, i.e. the very silent failure it exists to
      # prevent. Require the save/restore form.
      if file_has_pattern "$oom_guard_lib" 'had_errexit|SAVED_ERREXIT|\$-.*\*e\*'; then
        record_check "test_abstraction" "OOM-kill guard (${oom_guard_lib})" "pass" "Shared guard detects 137/139 and preserves the caller's errexit"
      else
        record_check "test_abstraction" "OOM-kill guard (${oom_guard_lib})" "warn" "${oom_guard_lib} detects OOM but may not save/restore the caller's errexit — an unconditional 'set -e' makes the guard itself abort callers silently (wiki: makefile-hierarchy.md)"
      fi

      for rs in "${docker_runners[@]}"; do
        file_has_pattern "$rs" 'docker run' || continue
        if file_has_pattern "$rs" 'guard_oom|oom-guard'; then
          record_check "test_abstraction" "OOM guard wired (${rs})" "pass" "Routes docker run through the shared OOM guard"
        else
          record_check "test_abstraction" "OOM guard wired (${rs})" "warn" "${rs} runs docker without the OOM guard — an exit-137 kill reports as an unexplained failure, or as a PASS for tools that are silent when clean (wiki: makefile-hierarchy.md)"
        fi
      done
    else
      # No shared lib: accept an inline 137 check, but flag the duplication risk.
      local inline_oom=0
      for rs in "${docker_runners[@]}"; do
        file_has_pattern "$rs" '\b137\b' && inline_oom=$((inline_oom + 1))
      done
      if [[ $inline_oom -gt 0 ]]; then
        record_check "test_abstraction" "OOM-kill guard" "warn" "${inline_oom} runner(s) check exit 137 inline with no shared guard (scripts/lib/oom-guard.sh) — the check will drift between runners (wiki: makefile-hierarchy.md)"
      else
        record_check "test_abstraction" "OOM-kill guard" "fail" "No OOM-kill detection in any docker runner: a 137 SIGKILL produces empty output, which reads as CLEAN for silent-on-success tools like tsc --noEmit and eslint — a pass on code that was never checked. Add scripts/lib/oom-guard.sh and route every docker run through it (wiki: makefile-hierarchy.md)"
      fi
    fi

    # (5) Labelled auto-reclaim: a reused per-worktree tag leaves DANGLING images
    # (ten rebuilds = one tag + nine untagged), and a worktree removed without
    # `worktree-clean` leaks its images forever. Require build-time tim.* labels
    # (tags address, labels reclaim) plus a post-build sweep. The label filter is
    # the entire safety boundary — a name-glob prune or `docker builder prune`
    # would destroy the SHARED layer cache and cold-rebuild every other checkout.
    local img_helper=""
    for candidate in scripts/test-image.sh scripts/ensure-test-image.sh; do
      [[ -f "$candidate" ]] && { img_helper="$candidate"; break; }
    done

    if [[ -n "$img_helper" ]]; then
      # No leading '--' in the pattern: grep would parse it as an option.
      if file_has_pattern "$img_helper" 'label[= ]+tim\.|tim\.worktree'; then
        record_check "test_abstraction" "Test-image build labels (${img_helper})" "pass" "Builds carry tim.repo/tim.service/tim.worktree labels for label-filtered reclaim"
      else
        record_check "test_abstraction" "Test-image build labels (${img_helper})" "warn" "${img_helper} builds test images without tim.* labels — reclaim then has no safe filter and per-worktree images accumulate (wiki: makefile-hierarchy.md#test-image-lifecycle-belongs-to-the-target-not-the-caller)"
      fi

      if file_has_pattern "$img_helper" 'image prune|docker rmi'; then
        if file_has_pattern "$img_helper" 'worktree list'; then
          record_check "test_abstraction" "Test-image auto-reclaim (${img_helper})" "pass" "Post-build dangling sweep plus orphan sweep reconciled against git worktree list"
        else
          record_check "test_abstraction" "Test-image auto-reclaim (${img_helper})" "warn" "${img_helper} prunes dangling images but has no orphan sweep — images from removed worktrees are never reclaimed unless worktree-clean is remembered. Reconcile tim.worktree against 'git worktree list --porcelain' (wiki: makefile-hierarchy.md)"
        fi
      else
        record_check "test_abstraction" "Test-image auto-reclaim (${img_helper})" "warn" "${img_helper} never reclaims: a reused per-worktree tag leaves one dangling image per rebuild, and removed worktrees leak theirs. Add a post-build label-filtered 'docker image prune' plus an orphan sweep (wiki: makefile-hierarchy.md)"
      fi

      # Hard failure: nuking the shared builder cache cold-rebuilds every checkout.
      if file_has_pattern "$img_helper" 'builder prune|buildx prune'; then
        record_check "test_abstraction" "Reclaim spares shared layer cache (${img_helper})" "fail" "${img_helper} runs 'docker builder prune' — that destroys the SHARED layer cache and forces every other worktree and the primary checkout into a cold rebuild. Reclaim must be label-filtered image removal only (wiki: makefile-hierarchy.md)"
      else
        record_check "test_abstraction" "Reclaim spares shared layer cache (${img_helper})" "pass" "No builder-cache pruning in the image helper"
      fi
    fi
  fi

  #--- Category: Seeding Strategy ---
  print_info ""
  print_info "Category: Database Seeding"

  if [[ "$QUICK_MODE" == "true" ]]; then
    record_check "seeding" "Seeding checks" "skip" "Skipped in quick mode"
  else
    # Recognize EITHER guard convention: the seed-once guard (_TEST_DB_SEEDED)
    # or the wiki test-db-reset pattern's reset-once guard (*_TEST_DB_RESET).
    # Either one satisfies "reset/seed the test DB exactly once per suite".
    local has_seed_guard=false
    for mf in "${MAKEFILES_FOUND[@]}"; do
      if file_has_pattern "$mf" '_TEST_DB_SEEDED|_TEST_DB_RESET'; then
        has_seed_guard=true
        record_check "seeding" "Reset/seed-once guard (${mf})" "pass" "Uses a *_TEST_DB_SEEDED / *_TEST_DB_RESET env-var guard"
      fi
    done

    if [[ "$has_seed_guard" == "false" ]]; then
      # Does the project have a database at all? Seed/reset/migrate targets are
      # the tell. A pure unit-test project that mocks the DB has none of these
      # and legitimately needs no test-DB reset.
      local has_db_targets=false
      for mf in "${MAKEFILES_FOUND[@]}"; do
        if file_has_pattern "$mf" 'seed|reset-db|reset-test-db|migrate'; then
          has_db_targets=true
        fi
      done

      if [[ "$has_db_targets" == "true" ]]; then
        # The project has a database. Per the test-db-reset pattern, ANY test
        # tier that touches a real DB must reset it exactly once per suite
        # (behind a guard so hierarchical `make` targets don't re-reset). Without
        # this, tests are not idempotent across runs and the DB accumulates
        # stale test data from past runs. This is a real defect, not a nit —
        # DO NOT dismiss it as a false positive just because the seed targets
        # aren't currently wired as test prerequisites: that missing wiring IS
        # the gap. (If EVERY test tier mocks the DB, note that explicitly when
        # accepting this finding.)
        record_check "seeding" "Reset/seed-once guard" "fail" "Project has a database (seed/reset/migrate targets) but no *_TEST_DB_SEEDED / *_TEST_DB_RESET guard wiring a reset into the test path — tests aren't idempotent and the DB accumulates stale test data. See the test-db-reset pattern."
      else
        record_check "seeding" "Reset/seed-once guard" "skip" "No database targets found — tests appear to mock the DB"
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

  echo "$result" > "$OUTPUT_FILE"   # file stays JSON for programmatic consumers
  log_json "$result"                # stdout = TOON in AI context, JSON otherwise

  print_info "Report written to: $OUTPUT_FILE"
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
}

main
