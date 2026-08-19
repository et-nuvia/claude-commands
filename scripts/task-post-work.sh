#!/usr/bin/env bash
set -euo pipefail

# task-post-work.sh - Orchestrate the post-implementation review pipeline.
#
# Purpose-built state machine that sequences the existing task-close-adjacent
# commands deterministically (the SCRIPT decides the next step, not the LLM):
#
#   STAGE A (pre-PR):  task-audit  ->  task-arch-review  ->  task-code-review
#                      wrapped in a de-escalating fix-loop
#   STAGE B (PR):      create-pr   ->  review-pr
#                      wrapped in the same fix-loop
#
# Fix-loop severity ladder (forces convergence — LLMs always find *something*):
#   pass 1: fix everything          (critical, high, medium, low)
#   pass 2: fix critical/high/medium
#   pass 3: fix critical/high
#   pass 4: fix critical
#   pass 5: VERIFY ONLY — if any critical or high remain -> BLOCK
#
# Hard gates that halt the pipeline:
#   - failing tests that will not go green
#   - loop non-convergence (pass 5 still finds critical/high)
# Otherwise the pipeline runs fully automatically through create-pr + review-pr.
#
# Each sub-command remains independently runnable (/task-audit, /create-pr, ...);
# this orchestrator just calls them in order and gates on their results.
#
# The LLM drives each phase and reports structured results back; this script
# holds all sequencing/gating/threshold logic in a resumable state file so the
# pipeline can survive interruption and is deterministic across runs.
#
# Usage:
#   task-post-work.sh --start   [--task-id <id>] [--from-pass N]
#   task-post-work.sh --resume-from-pass N [--sha <commit>] [--ledger '<json>']
#   task-post-work.sh --record-reviews --findings '<json>' --tests pass|fail
#   task-post-work.sh --record-fixes [--sha <fix-commit>] [--ledger '<json>']
#   task-post-work.sh --record-pr-created
#   task-post-work.sh --status
#   task-post-work.sh --reset   [--task-id <id>]
#   [--json|--raw]
#
#   --findings JSON: {"critical":N,"high":N,"medium":N,"low":N}
#                    (aggregate across whatever reviews ran this pass)
#   --sha:     the fix commit SHA — becomes last_reviewed_sha, the delta
#              baseline for the next pass's incremental-reviewer dispatch
#   --ledger:  JSON array of accepted fixes from fix-implementer:
#              [{"id":"...","file":"path:line","resolution":"...","commit":"sha"}]
#              Appended to the cumulative state ledger; echoed back on every
#              ready_for_reviews so pass N+1 (and the full-mode verify pass)
#              can hand the reviewer the complete accepted-fixes history even
#              after a context loss / fresh session.

OUTPUT_MODE="json"
SECTION="status"
TASK_INPUT=""
FINDINGS_JSON=""
TESTS_RESULT=""
FROM_PASS=""
FIX_SHA=""
LEDGER_JSON=""

TASK_ID=""
TASK_DOC=""
TASK_BRANCH=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/output-framework.sh"

# --- next_action mapping (custom) ------------------------------------------
# Proceed-states use ready_for_* names so output-framework exits 0 (not a
# failure); only `blocked` exits non-zero, which correctly signals a halt.
map_status_to_action() {
    case "$1" in
        ready_for_reviews)    echo "run_reviews" ;;
        ready_for_fixes)      echo "apply_fixes" ;;
        ready_for_pr)         echo "run_create_pr" ;;
        ready_for_pr_review)  echo "run_pr_review" ;;
        blocked)              echo "fix_error" ;;
        *)                    _default_map_status_to_action "$1" ;;
    esac
}

#------------------------------------------------------------------------------
# State helpers
#------------------------------------------------------------------------------

# Durable location — this state is what makes the pipeline resumable, and in
# /tmp a reboot mid-pipeline silently discarded it, forcing a full restart
# (every review re-run from pass 1). Old /tmp state is migrated on first read.
STATE_DIR="${HOME}/.claude/state"

state_file() {
    mkdir -p "$STATE_DIR" 2>/dev/null || true
    local id="${1:-unknown}"
    local new="${STATE_DIR}/task-post-work-${id}.state.json"
    local old="/tmp/task-post-work-${id}.state.json"
    if [[ ! -f "$new" && -f "$old" ]]; then
        mv "$old" "$new" 2>/dev/null || true
    fi
    echo "$new"
}

# Severities in-scope to fix for a given pass.
threshold_for_pass() {
    case "$1" in
        1) echo "all" ;;
        2) echo "chm" ;;
        3) echo "ch" ;;
        4) echo "c" ;;
        *) echo "verify" ;;
    esac
}

# Human-readable list of severities to fix for a threshold.
severities_for_threshold() {
    case "$1" in
        all)    echo "critical, high, medium, low" ;;
        chm)    echo "critical, high, medium" ;;
        ch)     echo "critical, high" ;;
        c)      echo "critical" ;;
        verify) echo "(verify only — fix nothing)" ;;
    esac
}

# Count of findings at/above a threshold, given a findings JSON.
in_scope_count() {
    local threshold="$1" f="$2"
    local c h m l
    c=$(echo "$f" | jq -r '.critical // 0')
    h=$(echo "$f" | jq -r '.high // 0')
    m=$(echo "$f" | jq -r '.medium // 0')
    l=$(echo "$f" | jq -r '.low // 0')
    case "$threshold" in
        all) echo $(( c + h + m + l )) ;;
        chm) echo $(( c + h + m )) ;;
        ch)  echo $(( c + h )) ;;
        c)   echo $(( c )) ;;
        *)   echo 0 ;;
    esac
}

#------------------------------------------------------------------------------
# Task identification
#------------------------------------------------------------------------------

identify_task() {
    if [[ ! -f "${SCRIPT_DIR}/doc-utils.sh" ]]; then
        exit_with_json "error" "doc-utils.sh not found" "Required utility script missing"
    fi
    source "${SCRIPT_DIR}/doc-utils.sh"

    if [[ -n "$TASK_INPUT" ]]; then
        if [[ "$TASK_INPUT" =~ ^[A-Fa-f0-9]{6}$ ]]; then
            TASK_ID=$(normalize_task_id "$TASK_INPUT")
            TASK_DOC=$(find_primary "$TASK_ID" 2>/dev/null || echo "")
        fi
    elif load_current_task; then
        TASK_DOC="$CT_TASK_DOC"
        TASK_BRANCH="$CT_BRANCH"
        TASK_ID="$CT_TASK_ID"
    fi

    if [[ ! -f "${TASK_DOC:-}" ]]; then
        exit_with_json "error" "Task document not found" "Provide --task-id or run /task-start first"
    fi
    TASK_ID=$(get_task_id "$(basename "$TASK_DOC")")
}

#------------------------------------------------------------------------------
# Sections
#------------------------------------------------------------------------------

section_start() {
    identify_task
    local sf; sf=$(state_file "$TASK_ID")
    # Start-pass resolution: --from-pass > TASK_POST_WORK_START_PASS env > 1.
    # Setting the env var to 3 starts the ladder at critical/high — transcript
    # data suggests passes 1-2 mostly churn on low-severity nits the verify
    # pass would defer anyway; the env var makes that experiment one export.
    local start_pass="${FROM_PASS:-${TASK_POST_WORK_START_PASS:-1}}"
    local threshold; threshold=$(threshold_for_pass "$start_pass")

    jq -n \
        --arg task_id "$TASK_ID" \
        --arg branch "$TASK_BRANCH" \
        --argjson pass "$start_pass" \
        --arg threshold "$threshold" \
        '{task_id:$task_id, branch:$branch, stage:"pre_pr", pass:$pass,
          threshold:$threshold, awaiting:"reviews", pr_created:false,
          blocked_reason:"", history:[], last_reviewed_sha:"", ledger:[]}' > "$sf"

    exit_with_json "ready_for_reviews" \
        "Pipeline started for ${TASK_ID} — STAGE A pass ${start_pass}" "" \
        "$(printf '"task_id":"%s", "stage":"pre_pr", "pass":%s, "threshold":"%s", "fix_severities":"%s", "docs_expected":"%s", "state_file":"%s"' \
            "$TASK_ID" "$start_pass" "$threshold" "$(severities_for_threshold "$threshold")" "$(docs_for_stage pre_pr "$threshold")" "$sf")"
}

# Load state or error.
load_state() {
    identify_task
    local sf; sf=$(state_file "$TASK_ID")
    if [[ ! -f "$sf" ]]; then
        exit_with_json "error" "No pipeline state for ${TASK_ID}" "Run --start first"
    fi
    STATE=$(cat "$sf")
    STATE_FILE="$sf"
    STAGE=$(echo "$STATE" | jq -r '.stage')
    PASS=$(echo "$STATE" | jq -r '.pass')
    THRESHOLD=$(echo "$STATE" | jq -r '.threshold')
}

# The review phases that run each pass, by stage AND pass threshold.
#
# task-audit runs the full suite + coverage (p90 ~9 minutes measured) — the
# most expensive phase by far. On intermediate fix passes (2-4) it is
# redundant verification: apply_fixes already requires green `make test`
# before --record-fixes, so re-auditing there re-runs tests that just passed.
# The audit therefore runs on pass 1 (baseline) and the verify pass (final
# gate) only; intermediate passes re-run just the two review phases whose
# findings were fixed. Gate integrity is unchanged — nothing converges or
# blocks without a full audit having run at both ends.
reviews_for_stage() {
    local stage="$1" threshold="${2:-all}"
    case "$stage" in
        pre_pr)
            case "$threshold" in
                chm|ch|c) echo "task-arch-review, task-code-review" ;;
                *)        echo "task-audit, task-arch-review, task-code-review" ;;
            esac
            ;;
        pr) echo "review-pr" ;;
    esac
}

# The standalone documents each stage's reviews MUST leave behind. The
# orchestrator is required to produce (and verify) these artifacts every pass,
# even when it dispatches the analysis to a subagent instead of the full skill —
# a subagent's inline findings are NOT a substitute for the doc. See the command's
# run_reviews handling.
docs_for_stage() {
    local stage="$1" threshold="${2:-all}"
    case "$stage" in
        pre_pr)
            case "$threshold" in
                # Intermediate passes skip task-audit, so no AUD update is due.
                chm|ch|c) echo "ARC (task-arch-review), CRV (task-code-review)" ;;
                *)        echo "AUD (task-audit), ARC (task-arch-review), CRV (task-code-review)" ;;
            esac
            ;;
        pr) echo "code-review doc (review-pr, docs/code-reviews/)" ;;
    esac
}

# Advance from a converged review stage to the next phase.
advance_stage() {
    local sf="$1"
    if [[ "$STAGE" == "pre_pr" ]]; then
        jq '.stage="pr" | .pass=1 | .threshold="all" | .awaiting="create_pr"' \
            "$sf" > "${sf}.tmp" && mv "${sf}.tmp" "$sf"
        exit_with_json "ready_for_pr" \
            "STAGE A converged — creating PR" "" \
            "$(printf '"task_id":"%s", "stage":"pr", "next_phase":"create-pr"' "$TASK_ID")"
    else
        jq '.stage="complete" | .awaiting="none"' \
            "$sf" > "${sf}.tmp" && mv "${sf}.tmp" "$sf"
        exit_with_json "success" \
            "Pipeline complete for ${TASK_ID} — all reviews converged, PR created and reviewed" "" \
            "$(printf '"task_id":"%s", "stage":"complete"' "$TASK_ID")"
    fi
}

section_record_reviews() {
    load_state
    [[ -n "$FINDINGS_JSON" ]] || exit_with_json "error" "Missing --findings" "Pass aggregated counts: {\"critical\":N,\"high\":N,\"medium\":N,\"low\":N}"
    echo "$FINDINGS_JSON" | jq empty 2>/dev/null || exit_with_json "error" "Invalid --findings JSON" "$FINDINGS_JSON"
    [[ "$TESTS_RESULT" == "pass" || "$TESTS_RESULT" == "fail" ]] || exit_with_json "error" "Missing/invalid --tests" "Use --tests pass|fail"

    local crit high
    crit=$(echo "$FINDINGS_JSON" | jq -r '.critical // 0')
    high=$(echo "$FINDINGS_JSON" | jq -r '.high // 0')

    # Record this pass in history.
    local reviews; reviews=$(reviews_for_stage "$STAGE" "$THRESHOLD")
    jq --argjson pass "$PASS" --arg threshold "$THRESHOLD" \
       --argjson findings "$FINDINGS_JSON" --arg tests "$TESTS_RESULT" \
       --arg reviews "$reviews" \
       '.history += [{pass:$pass, threshold:$threshold, reviews:$reviews, findings:$findings, tests:$tests}]' \
       "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"

    # VERIFY pass (5): block on critical/high or failing tests; else converge.
    if [[ "$THRESHOLD" == "verify" ]]; then
        if (( crit + high > 0 )) || [[ "$TESTS_RESULT" == "fail" ]]; then
            local reason="Pass 5 verify still found ${crit} critical / ${high} high finding(s)"
            [[ "$TESTS_RESULT" == "fail" ]] && reason="${reason}; tests failing"
            jq --arg r "$reason" '.stage="blocked" | .awaiting="none" | .blocked_reason=$r' \
                "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
            exit_with_json "blocked" \
                "BLOCKED: ${reason}" "$reason" \
                "$(printf '"task_id":"%s", "stage":"blocked", "critical":%s, "high":%s, "tests":"%s"' \
                    "$TASK_ID" "$crit" "$high" "$TESTS_RESULT")"
        fi
        advance_stage "$STATE_FILE"
        return
    fi

    # Fix passes (1-4): fix in-scope findings and/or failing tests, else converge.
    local scope; scope=$(in_scope_count "$THRESHOLD" "$FINDINGS_JSON")
    if (( scope > 0 )) || [[ "$TESTS_RESULT" == "fail" ]]; then
        jq '.awaiting="fixes"' "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
        local test_note=""
        [[ "$TESTS_RESULT" == "fail" ]] && test_note=" Tests are FAILING — fixing them is mandatory (hard gate)."
        exit_with_json "ready_for_fixes" \
            "STAGE $([[ $STAGE == pre_pr ]] && echo A || echo B) pass ${PASS}: fix ${scope} in-scope finding(s).${test_note}" "" \
            "$(printf '"task_id":"%s", "stage":"%s", "pass":%s, "threshold":"%s", "fix_severities":"%s", "in_scope_findings":%s, "tests":"%s"' \
                "$TASK_ID" "$STAGE" "$PASS" "$THRESHOLD" "$(severities_for_threshold "$THRESHOLD")" "$scope" "$TESTS_RESULT")"
    fi

    # Nothing in-scope and tests green -> converged early.
    advance_stage "$STATE_FILE"
}

section_record_fixes() {
    load_state
    [[ "$(echo "$STATE" | jq -r '.awaiting')" == "fixes" ]] || \
        exit_with_json "error" "Not awaiting fixes" "Current state expects: $(echo "$STATE" | jq -r '.awaiting')"

    # Validate optional ledger JSON before touching state.
    if [[ -n "$LEDGER_JSON" ]]; then
        echo "$LEDGER_JSON" | jq -e 'type == "array"' >/dev/null 2>&1 || \
            exit_with_json "error" "Invalid --ledger JSON (must be an array)" "$LEDGER_JSON"
    fi

    local next_pass=$(( PASS + 1 ))
    (( next_pass > 5 )) && next_pass=5
    local next_threshold; next_threshold=$(threshold_for_pass "$next_pass")

    jq --argjson p "$next_pass" --arg t "$next_threshold" \
        --arg sha "$FIX_SHA" --argjson new_ledger "${LEDGER_JSON:-[]}" \
        '.pass=$p | .threshold=$t | .awaiting="reviews"
         | (if $sha != "" then .last_reviewed_sha=$sha else . end)
         | .ledger = ((.ledger // []) + $new_ledger)' \
        "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"

    local reviews; reviews=$(reviews_for_stage "$STAGE" "$next_threshold")
    local last_sha cum_ledger review_mode
    last_sha=$(jq -r '.last_reviewed_sha // ""' "$STATE_FILE")
    cum_ledger=$(jq -c '.ledger // []' "$STATE_FILE")
    review_mode="delta"
    local verify_note=""
    if [[ "$next_threshold" == "verify" ]]; then
        review_mode="full"
        verify_note=" This is the VERIFY pass — re-run reviews in FULL mode (entire branch diff + cumulative ledger) but fix nothing; any surviving critical/high will BLOCK."
    fi

    exit_with_json "ready_for_reviews" \
        "Fixes recorded — advancing to pass ${next_pass} (${next_threshold}). Re-run: ${reviews}.${verify_note}" "" \
        "$(printf '"task_id":"%s", "stage":"%s", "pass":%s, "threshold":"%s", "fix_severities":"%s", "reviews":"%s", "docs_expected":"%s", "review_mode":"%s", "last_reviewed_sha":"%s", "ledger":%s' \
            "$TASK_ID" "$STAGE" "$next_pass" "$next_threshold" "$(severities_for_threshold "$next_threshold")" "$reviews" "$(docs_for_stage "$STAGE" "$next_threshold")" "$review_mode" "$last_sha" "$cum_ledger")"
}

# Resume an existing pipeline at a given pass WITHOUT wiping accumulated state.
# This is the recovery path after a blocked verify (manual fixes applied, then
# --resume-from-pass 5 to re-verify). Unlike --start --from-pass, it preserves
# history, ledger, and last_reviewed_sha — a full-mode verify without the
# ledger is exactly the blind re-review that causes fix->re-flag oscillation.
# Optional --sha/--ledger record the manual fixes just like --record-fixes.
section_resume_from_pass() {
    load_state
    [[ "$FROM_PASS" =~ ^[1-5]$ ]] || exit_with_json "error" "Invalid --resume-from-pass" "Pass must be 1-5"
    if [[ -n "$LEDGER_JSON" ]]; then
        echo "$LEDGER_JSON" | jq -e 'type == "array"' >/dev/null 2>&1 || \
            exit_with_json "error" "Invalid --ledger JSON (must be an array)" "$LEDGER_JSON"
    fi

    local threshold; threshold=$(threshold_for_pass "$FROM_PASS")
    # A blocked pipeline resumes into pre_pr unless the PR was already created.
    local resume_stage="$STAGE"
    if [[ "$STAGE" == "blocked" || "$STAGE" == "complete" ]]; then
        resume_stage=$([[ "$(echo "$STATE" | jq -r '.pr_created')" == "true" ]] && echo "pr" || echo "pre_pr")
    fi

    jq --argjson p "$FROM_PASS" --arg t "$threshold" --arg stage "$resume_stage" \
        --arg sha "$FIX_SHA" --argjson new_ledger "${LEDGER_JSON:-[]}" \
        '.stage=$stage | .pass=$p | .threshold=$t | .awaiting="reviews" | .blocked_reason=""
         | (if $sha != "" then .last_reviewed_sha=$sha else . end)
         | .ledger = ((.ledger // []) + $new_ledger)' \
        "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"

    local reviews; reviews=$(reviews_for_stage "$resume_stage" "$threshold")
    local last_sha cum_ledger review_mode
    last_sha=$(jq -r '.last_reviewed_sha // ""' "$STATE_FILE")
    cum_ledger=$(jq -c '.ledger // []' "$STATE_FILE")
    review_mode=$([[ "$threshold" == "verify" ]] && echo "full" || echo "delta")

    local action="ready_for_reviews"
    [[ "$resume_stage" == "pr" ]] && action="ready_for_pr_review"
    exit_with_json "$action" \
        "Resumed ${TASK_ID} at pass ${FROM_PASS} (${threshold}) — history and ledger preserved. Re-run: ${reviews}." "" \
        "$(printf '"task_id":"%s", "stage":"%s", "pass":%s, "threshold":"%s", "fix_severities":"%s", "reviews":"%s", "docs_expected":"%s", "review_mode":"%s", "last_reviewed_sha":"%s", "ledger":%s' \
            "$TASK_ID" "$resume_stage" "$FROM_PASS" "$threshold" "$(severities_for_threshold "$threshold")" "$reviews" "$(docs_for_stage "$resume_stage" "$threshold")" "$review_mode" "$last_sha" "$cum_ledger")"
}

section_record_pr_created() {
    load_state
    [[ "$STAGE" == "pr" ]] || exit_with_json "error" "Not in PR stage" "Current stage: $STAGE"
    jq '.pr_created=true | .awaiting="reviews"' \
        "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
    exit_with_json "ready_for_pr_review" \
        "PR created — STAGE B pass 1: run review-pr and fix all findings" "" \
        "$(printf '"task_id":"%s", "stage":"pr", "pass":1, "threshold":"all", "fix_severities":"%s", "reviews":"review-pr", "docs_expected":"%s"' \
            "$TASK_ID" "$(severities_for_threshold all)" "$(docs_for_stage pr)")"
}

section_status() {
    load_state
    exit_with_json "success" "Pipeline state for ${TASK_ID}" "" \
        "$(printf '"task_id":"%s", "state":%s' "$TASK_ID" "$STATE")"
}

section_reset() {
    identify_task
    local sf; sf=$(state_file "$TASK_ID")
    rm -f "$sf"
    exit_with_json "success" "Pipeline state cleared for ${TASK_ID}" "" \
        "$(printf '"task_id":"%s"' "$TASK_ID")"
}

#------------------------------------------------------------------------------
# Arg parsing
#------------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case $1 in
        --json)               OUTPUT_MODE="json"; shift ;;
        --raw)                OUTPUT_MODE="raw"; shift ;;
        --start)              SECTION="start"; shift ;;
        --record-reviews)     SECTION="record-reviews"; shift ;;
        --record-fixes)       SECTION="record-fixes"; shift ;;
        --record-pr-created)  SECTION="record-pr-created"; shift ;;
        --status)             SECTION="status"; shift ;;
        --reset)              SECTION="reset"; shift ;;
        --task-id)            TASK_INPUT="$2"; shift 2 ;;
        --from-pass)          FROM_PASS="$2"; shift 2 ;;
        --resume-from-pass)   SECTION="resume-from-pass"; FROM_PASS="$2"; shift 2 ;;
        --findings)           FINDINGS_JSON="$2"; shift 2 ;;
        --tests)              TESTS_RESULT="$2"; shift 2 ;;
        --sha)                FIX_SHA="$2"; shift 2 ;;
        --ledger)             LEDGER_JSON="$2"; shift 2 ;;
        *) break ;;
    esac
done

case "$SECTION" in
    start)             section_start ;;
    record-reviews)    section_record_reviews ;;
    record-fixes)      section_record_fixes ;;
    resume-from-pass)  section_resume_from_pass ;;
    record-pr-created) section_record_pr_created ;;
    status)            section_status ;;
    reset)             section_reset ;;
    *) exit_with_json "error" "Unknown section: $SECTION" "Valid: --start, --record-reviews, --record-fixes, --record-pr-created, --status, --reset" ;;
esac
