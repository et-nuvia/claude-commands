#!/usr/bin/env bash
# run-jest.sh — Runs Jest (or vitest-compatible jest CLI) with --json and emits
# the standard LLM test envelope.
#
# Usage: run-jest.sh --target <name> --component <name> [--files "f1 f2"]
#                    [--filter pat] [--details] [-- jest args...]
#
# --files vs --filter (the recurring footgun — read this before using either):
#   --files "a.spec.ts b.spec.ts"  selects test FILES. Multiple space-separated
#       paths are supported. Paths may be absolute, repo-root-relative,
#       component-relative, or a bare basename (glob-matched under the component).
#       A path that matches no test file produces a WARNING, never a silent pass.
#   --filter "pattern"  maps to jest `-t`, which filters by TEST NAME. Jest marks
#       every non-matching test *pending* rather than running nothing, so a filter
#       that matches nothing looks like a huge `skipped` count. That case is
#       reported in `warnings`. If you meant "run this file", use --files.
#
# Envelope fields (superset of the historical contract — nothing removed):
#   status target component message next_action exit_code duration_ms timestamp
#   passed failed skipped coverage_pct covered_lines total_lines failures
#   suites_passed suites_failed suites_total tests_collected warnings min_coverage
#
# Accuracy contract:
#   * The jest exit code is always honoured — `exit_code` is never forced to 0.
#   * A suite that fails to COMPILE (numFailedTests == 0 but
#     numFailedTestSuites > 0) is an ERROR, and its reason is surfaced in
#     `failures` so the agent need not re-run.
#   * "Ran nothing" is never reported as a bare green run — it is
#     status "warning" with next_action "verify_scope", or a clean pass carrying
#     an explanatory `warnings` entry for the legitimate no-tests cases
#     (jest not installed, component with no test files).
#
# PROJECT.yaml aware (optional — absence is never fatal):
#   .testing.min_coverage  → echoed as `min_coverage` (default 80)
#   .languages[].root      → resolves --component to a working directory

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/yaml.sh
if [[ -f "$SCRIPT_DIR/lib/yaml.sh" ]]; then
  source "$SCRIPT_DIR/lib/yaml.sh"
fi

TARGET=""
COMPONENT=""
FILES_ARG=""
FILTER_ARG=""
EXTRA_JEST_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)    TARGET="$2";    shift 2 ;;
    --component) COMPONENT="$2"; shift 2 ;;
    --files)     FILES_ARG="$2"; shift 2 ;;
    --filter)    FILTER_ARG="$2"; shift 2 ;;
    --details)   shift ;;  # accepted for interface compatibility; unused here
    --)          shift; EXTRA_JEST_ARGS=("$@"); break ;;
    *)           EXTRA_JEST_ARGS+=("$1"); shift ;;
  esac
done

if [[ -z "$TARGET" ]];    then echo "--target required" >&2; exit 1; fi
if [[ -z "$COMPONENT" ]]; then COMPONENT="${TARGET}"; fi

TIMESTAMP=$(date -Iseconds)
START_MS=$(($(date +%s%N) / 1000000))

# --- Repo root + PROJECT.yaml discovery (all optional) ---------------------
REPO_ROOT=""
if REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null); then :; else REPO_ROOT=""; fi
[[ -z "$REPO_ROOT" ]] && REPO_ROOT="$PWD"

PROJECT_YAML=""
_probe="$PWD"
while [[ -n "$_probe" && "$_probe" != "/" ]]; do
  if [[ -f "$_probe/PROJECT.yaml" ]]; then PROJECT_YAML="$_probe/PROJECT.yaml"; break; fi
  _probe="$(dirname "$_probe")"
done

MIN_COVERAGE=80
if [[ -n "$PROJECT_YAML" ]] && declare -F yaml_get_default >/dev/null 2>&1; then
  MIN_COVERAGE=$(yaml_get_default '.testing.min_coverage' '80' "$PROJECT_YAML" 2>/dev/null || echo 80)
  [[ "$MIN_COVERAGE" =~ ^[0-9]+([.][0-9]+)?$ ]] || MIN_COVERAGE=80
fi

# Resolve the component working directory. The common case (and every historical
# caller) already runs from inside the component, so cwd wins whenever it looks
# like a JS project. Otherwise consult PROJECT.yaml .languages[].root.
COMPONENT_DIR="$PWD"
if [[ ! -f "$PWD/package.json" && -n "$PROJECT_YAML" ]] && declare -F yaml_get >/dev/null 2>&1; then
  _yaml_root=$(yaml_get ".languages[] | select(.root == \"${COMPONENT}\" or .root == \"./${COMPONENT}\" or .name == \"${COMPONENT}\") | .root" "$PROJECT_YAML" 2>/dev/null | head -n 1 || true)
  if [[ -n "$_yaml_root" ]]; then
    _yaml_root="${_yaml_root#./}"
    _cand="$_yaml_root"
    [[ "$_cand" != /* ]] && _cand="$(dirname "$PROJECT_YAML")/$_yaml_root"
    [[ -d "$_cand" ]] && COMPONENT_DIR="$_cand"
  fi
fi
cd "$COMPONENT_DIR"

# --- Envelope --------------------------------------------------------------
COVERAGE_PCT=0
COVERED_LINES=0
TOTAL_LINES=0
SUITES_PASSED=0
SUITES_FAILED=0
SUITES_TOTAL=0
TESTS_COLLECTED=0
WARNINGS=()

emit_envelope() {
  local status="$1" exit_code="$2" passed="$3" failed="$4" skipped="$5" message="$6"
  # $7 (optional): JSON array of failing tests ({service,file,test,reason}).
  # Defaults to [] so the field is always present and machine-parseable — callers
  # never have to re-run the suite to learn WHICH test failed.
  local failures_json="${7:-[]}"
  # $8 (optional): explicit next_action override.
  local next_action="${8:-}"
  if [[ -z "$next_action" ]]; then
    if [[ "$exit_code" -eq 0 && "$failed" -eq 0 && "$SUITES_FAILED" -eq 0 ]]; then
      next_action="display_summary"
    elif [[ "$failed" -gt 0 ]]; then
      next_action="fix_failures"
    else
      next_action="fix_error"
    fi
  fi
  local end_ms duration_ms
  end_ms=$(($(date +%s%N) / 1000000))
  duration_ms=$((end_ms - START_MS))
  local safe_msg
  safe_msg=$(printf '%s' "$message" | tr '\n' ' ' | cut -c1-200)
  local warnings_json="[]"
  if [[ ${#WARNINGS[@]} -gt 0 ]]; then
    warnings_json=$(printf '%s\n' "${WARNINGS[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))')
  fi
  jq -nc \
    --arg status "$status" --arg target "$TARGET" --arg component "$COMPONENT" \
    --arg message "$safe_msg" --arg next_action "$next_action" --arg timestamp "$TIMESTAMP" \
    --argjson exit_code "$exit_code" --argjson duration_ms "$duration_ms" \
    --argjson passed "$passed" --argjson failed "$failed" --argjson skipped "$skipped" \
    --argjson coverage_pct "$COVERAGE_PCT" --argjson covered_lines "$COVERED_LINES" \
    --argjson total_lines "$TOTAL_LINES" --argjson failures "$failures_json" \
    --argjson suites_passed "$SUITES_PASSED" --argjson suites_failed "$SUITES_FAILED" \
    --argjson suites_total "$SUITES_TOTAL" --argjson tests_collected "$TESTS_COLLECTED" \
    --argjson warnings "$warnings_json" --argjson min_coverage "$MIN_COVERAGE" \
    '{status:$status,target:$target,component:$component,message:$message,
      next_action:$next_action,exit_code:$exit_code,duration_ms:$duration_ms,
      timestamp:$timestamp,passed:$passed,failed:$failed,skipped:$skipped,
      coverage_pct:$coverage_pct,covered_lines:$covered_lines,total_lines:$total_lines,
      failures:$failures,suites_passed:$suites_passed,suites_failed:$suites_failed,
      suites_total:$suites_total,tests_collected:$tests_collected,
      warnings:$warnings,min_coverage:$min_coverage}'
}

# Legitimate no-tests case: jest is not available at all. Clean pass, but
# self-describing via `warnings` so it can't be mistaken for a real green run.
if ! npx jest --version >/dev/null 2>&1; then
  WARNINGS+=("jest is not installed/configured in ${COMPONENT_DIR} — 0 tests were run")
  emit_envelope "success" 0 0 0 0 "no tests (jest not installed)"
  exit 0
fi

# --- Resolve --files robustly ---------------------------------------------
RESOLVED_FILES=()
UNMATCHED_FILES=()
if [[ -n "$FILES_ARG" ]]; then
  # shellcheck disable=SC2206
  for token in $FILES_ARG; do
    match=""
    for cand in "$token" "$COMPONENT_DIR/$token" "$REPO_ROOT/$token"; do
      if [[ -f "$cand" ]]; then match="$cand"; break; fi
    done
    if [[ -z "$match" && "$token" != */* ]]; then
      # Bare basename: glob-match anywhere under the component.
      match=$(find "$COMPONENT_DIR" -name "$token" -type f -not -path '*/node_modules/*' 2>/dev/null | head -n 1 || true)
    fi
    if [[ -n "$match" ]]; then
      RESOLVED_FILES+=("$match")
    else
      UNMATCHED_FILES+=("$token")
    fi
  done
  for u in "${UNMATCHED_FILES[@]+"${UNMATCHED_FILES[@]}"}"; do
    WARNINGS+=("--files entry '${u}' matched no test file (tried absolute, repo-relative, component-relative, and basename glob)")
  done
  if [[ ${#RESOLVED_FILES[@]} -eq 0 ]]; then
    # Nothing to run: do NOT report a clean green run.
    WARNINGS+=("no test files matched --files \"${FILES_ARG}\"; nothing was executed")
    emit_envelope "warning" 0 0 0 0 "0 tests run — --files matched no test file" "[]" "verify_scope"
    exit 0
  fi
fi

# --- Build jest CLI args ---------------------------------------------------
JEST_ARGS=()
if [[ -n "$FILTER_ARG" ]]; then JEST_ARGS+=(-t "$FILTER_ARG"); fi
if [[ ${#RESOLVED_FILES[@]} -gt 0 ]]; then
  JEST_ARGS+=(--runTestsByPath "${RESOLVED_FILES[@]}")
fi
JEST_ARGS+=("${EXTRA_JEST_ARGS[@]+"${EXTRA_JEST_ARGS[@]}"}")

# Coverage is only meaningful on a FULL run. On narrow runs (FILES/FILTER) the
# numbers would be misleadingly low (collectCoverageFrom counts all source but
# only the selected files execute), so we skip coverage there. The coverage
# GATE is fed by `make test` (full), so this is the path that matters.
COV_DIR=""
if [[ -z "$FILES_ARG" && -z "$FILTER_ARG" ]]; then
  COV_DIR=$(mktemp -d)
  JEST_ARGS+=(--coverage --coverageReporters=json-summary --coverageDirectory "$COV_DIR")
fi

RAW=$(mktemp)
ERR=$(mktemp)
JEST_JSON=$(mktemp)
trap 'rm -f "$RAW" "$ERR" "$JEST_JSON"; [[ -n "$COV_DIR" ]] && rm -rf "$COV_DIR"' EXIT

# --- Watchdog -----------------------------------------------------------------
# A jest run can FINISH its tests and then never EXIT, when something left an
# open handle — an unclosed DB DataSource, a live HTTP server, a pending timer.
# jest prints "Jest did not exit one second after the test run has completed"
# and waits forever.
#
# Because this script runs jest with `--json --silent`, that produces ZERO
# output on stdout. A run that completed in 30 seconds is then indistinguishable
# from an infinite hang: the caller sees nothing at all, forever. The symptom
# reads as "the suite is slow", so the natural response is to raise the timeout
# and retry — which never terminates.
#
# So: bound the wait and report the diagnosis. Deliberately NOT --forceExit,
# which would paper over the open handle and let the real bug ship.
RUN_JEST_TIMEOUT_SECONDS="${RUN_JEST_TIMEOUT_SECONDS:-900}"

jest_exit=0
# `set -m` puts the background job in its own PROCESS GROUP, so the timeout path
# can kill the whole tree with one signal. This matters more than it looks: the
# tree is bash → npx(node) → jest main → N workers, and killing only the direct
# children (e.g. `pgrep -P`) orphans the workers — which, in the open-handle case
# this watchdog exists for, are exactly the processes still holding DB
# connections. Orphaned workers then poison the NEXT run with pool exhaustion.
# A group kill is depth-independent and needs no pgrep (absent in slim images).
set -m
npx jest --json --silent "${JEST_ARGS[@]+"${JEST_ARGS[@]}"}" > "$RAW" 2> "$ERR" &
jest_pid=$!
set +m

waited=0
timed_out=0
while kill -0 "$jest_pid" 2>/dev/null; do
  if [[ "$waited" -ge "$RUN_JEST_TIMEOUT_SECONDS" ]]; then
    timed_out=1
    # Negative pid = the whole process group. Fall back to the bare pid if the
    # group kill fails (e.g. job control unavailable in some shells).
    kill -9 -"$jest_pid" 2>/dev/null || kill -9 "$jest_pid" 2>/dev/null || true
    break
  fi
  sleep 1
  waited=$((waited + 1))
done

if [[ "$timed_out" -eq 1 ]]; then
  wait "$jest_pid" 2>/dev/null || true
  # jest's own stderr is the best evidence available — it usually already says
  # "Jest did not exit…", which names the real cause.
  err_tail=$(tr -d '\r' < "$ERR" | tail -n 20 | tr '\n' ' ' | cut -c1-300 || true)
  hint="jest did not exit within ${RUN_JEST_TIMEOUT_SECONDS}s. Tests may have PASSED and then hung on an open handle (unclosed DataSource / server / timer). Re-run WITHOUT FORMAT=json to see jest's own output, or add --detectOpenHandles."
  WARNINGS+=("$hint")
  failures_json=$(jq -nc --arg svc "$COMPONENT" --arg reason "${hint} stderr: ${err_tail}" \
    '[{service:$svc,file:"",test:"<jest watchdog>",reason:$reason}]')
  emit_envelope "error" 124 0 0 0 "jest timed out after ${RUN_JEST_TIMEOUT_SECONDS}s (did not exit)" "$failures_json"
  exit 124
fi

wait "$jest_pid" || jest_exit=$?

# jest can also emit the "did not exit" warning and THEN exit on its own. The
# run is valid, but the open handle is real and worth surfacing rather than
# leaving for whoever hits the hang next.
if grep -qi "did not exit" "$ERR" 2>/dev/null; then
  WARNINGS+=("jest reported it did not exit cleanly — an open handle (DataSource / server / timer) is leaking; run with --detectOpenHandles")
fi

# Jest --json may mix log output; extract the JSON blob. jest writes its result
# object as the LAST line of stdout. Don't match on a leading JSON key
# (e.g. '{"num.*') — jest's first key isn't fixed, so a key-prefix grep can miss
# the object and masquerade a real failure as "no tests found (pass)".
last_line=$(tail -n 1 "$RAW" 2>/dev/null || true)
if [[ -n "$last_line" ]] && printf '%s' "$last_line" | jq empty 2>/dev/null; then
  printf '%s' "$last_line" > "$JEST_JSON"
else
  grep '^{' "$RAW" 2>/dev/null | tail -n 1 > "$JEST_JSON" || true
fi

if [[ ! -s "$JEST_JSON" ]] || ! jq empty "$JEST_JSON" 2>/dev/null; then
  # No parseable jest result object. Distinguish the genuine "no tests found"
  # case from a jest invocation that actually blew up — the latter must never be
  # reported as a pass.
  err_tail=$(tr -d '\r' < "$ERR" | tail -n 20 | tr '\n' ' ' | cut -c1-300 || true)
  if [[ "$jest_exit" -eq 0 ]] || grep -qi "no tests found" "$ERR" 2>/dev/null; then
    WARNINGS+=("jest reported no test files for this invocation — 0 tests were run")
    emit_envelope "success" 0 0 0 0 "no tests found (pass)" "[]" "verify_scope"
    exit 0
  fi
  WARNINGS+=("jest exited ${jest_exit} without emitting a parseable JSON result — the run did not complete")
  failures_json=$(jq -nc --arg svc "$COMPONENT" --arg reason "$err_tail" \
    '[{service:$svc,file:"",test:"<jest invocation>",reason:$reason}]')
  emit_envelope "error" "$jest_exit" 0 0 0 "jest failed to run (exit ${jest_exit})" "$failures_json"
  exit 1
fi

# --- Parse jest JSON output ------------------------------------------------
passed=$(jq '.numPassedTests // 0'  "$JEST_JSON" 2>/dev/null || echo 0)
failed=$(jq '.numFailedTests // 0'  "$JEST_JSON" 2>/dev/null || echo 0)
skipped=$(jq '.numPendingTests // 0' "$JEST_JSON" 2>/dev/null || echo 0)
SUITES_PASSED=$(jq '.numPassedTestSuites // 0' "$JEST_JSON" 2>/dev/null || echo 0)
SUITES_FAILED=$(jq '.numFailedTestSuites // 0' "$JEST_JSON" 2>/dev/null || echo 0)
SUITES_TOTAL=$(jq '.numTotalTestSuites // 0'   "$JEST_JSON" 2>/dev/null || echo 0)
TESTS_COLLECTED=$(jq '.numTotalTests // 0'     "$JEST_JSON" 2>/dev/null || echo 0)

if [[ -n "$COV_DIR" && -f "$COV_DIR/coverage-summary.json" ]]; then
  COVERAGE_PCT=$(jq '.total.lines.pct // 0'      "$COV_DIR/coverage-summary.json" 2>/dev/null || echo 0)
  COVERED_LINES=$(jq '.total.lines.covered // 0' "$COV_DIR/coverage-summary.json" 2>/dev/null || echo 0)
  TOTAL_LINES=$(jq '.total.lines.total // 0'     "$COV_DIR/coverage-summary.json" 2>/dev/null || echo 0)
fi

# --filter maps to jest -t, which marks non-matching tests PENDING instead of
# running nothing — a filter typo therefore looks like a pass with a huge
# skipped count. Call that out explicitly.
if [[ -n "$FILTER_ARG" && "$passed" -eq 0 && "$failed" -eq 0 && "$skipped" -gt 0 ]]; then
  WARNINGS+=("--filter '${FILTER_ARG}' matched 0 tests; ${skipped} marked pending — did you mean --files?")
fi

# Per-assertion failures, PLUS suite-level failures that produced no failing
# assertion (the compile/import-error case) so the reason is never lost.
failures_json=$(jq -c --arg svc "$COMPONENT" '
  def clean: (. // "")
    | gsub("\\[[0-9;]*m"; "")   # ANSI colour codes
    | gsub(""; "")              # stray escape chars
    | gsub("\\[[0-9;]*m"; "")
    | gsub("\r"; "") | gsub("\n"; " ") | .[0:300];
  [ .testResults[]?
    | .name as $file
    | .assertionResults[]?
    | select(.status == "failed")
    | { service: $svc, file: $file, test: .fullName,
        reason: ((.failureMessages[0] // "") | clean) } ]
  + [ .testResults[]?
      | select(.status == "failed")
      | select([.assertionResults[]? | select(.status == "failed")] | length == 0)
      | { service: $svc, file: .name, test: "<suite failed to run>",
          reason: (.message | clean) } ]' "$JEST_JSON" 2>/dev/null || echo "[]")
[[ -z "$failures_json" ]] && failures_json="[]"

message="${passed} passed, ${failed} failed"
[[ "$SUITES_FAILED" -gt 0 ]] && message="${message}, ${SUITES_FAILED} suite(s) failed"

# --- Truthful status ------------------------------------------------------
# A failed SUITE with zero failed tests is the compile-failure case: nothing
# ran, so this must never be reported as success.
if [[ "$SUITES_FAILED" -gt 0 && "$failed" -eq 0 ]]; then
  WARNINGS+=("${SUITES_FAILED} test suite(s) failed to run (compile/import error) — 0 tests executed in them")
fi

if [[ "$failed" -gt 0 || "$SUITES_FAILED" -gt 0 || "$jest_exit" -ne 0 ]]; then
  # Never emit exit_code 0 for a failing run, even if jest itself reported 0.
  report_exit="$jest_exit"
  [[ "$report_exit" -eq 0 ]] && report_exit=1
  emit_envelope "error" "$report_exit" "$passed" "$failed" "$skipped" "$message" "$failures_json"
  exit 1
fi

if [[ "$TESTS_COLLECTED" -eq 0 ]]; then
  # Ran nothing, cleanly. Legitimate for a component with no test files, but it
  # must be distinguishable from a real green run.
  WARNINGS+=("0 tests were collected — verify the scope of this invocation (--files/--filter/testPathPattern)")
  if [[ -n "$FILES_ARG" || -n "$FILTER_ARG" ]]; then
    emit_envelope "warning" 0 0 0 0 "0 tests collected" "[]" "verify_scope"
    exit 0
  fi
  emit_envelope "success" 0 0 0 0 "no tests found (pass)" "[]" "verify_scope"
  exit 0
fi

emit_envelope "success" 0 "$passed" "$failed" "$skipped" "$message" "[]"
exit 0
