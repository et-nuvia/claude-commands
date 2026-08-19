#!/usr/bin/env bash
set -euo pipefail

# deploy-to-stage.sh - Deploy to staging with risk analysis, merge, and pipeline monitoring
#
# STANDARD SCRIPT PATTERN: Section flags with --json/--raw output modes
#
# Usage:
#   ~/.claude/scripts/deploy-to-stage.sh [--json|--raw] [--full|--section]
#
# Output Modes:
#   --json: Structured output for LLM, default (TOON when the caller is an AI agent, JSON otherwise)
#   --raw:  Verbose debugging output when LLM needs more details
#
# Section Flags (run specific section only):
#   --validate:      Validate git state only
#   --risk-analysis: Run automated risk analysis only
#   --merge:         Attempt merge only (returns conflict details if needed)
#   --deploy:        Push merge commit + monitor pipeline to completion (after merge).
#                    Health/version are NOT re-checked here — the pipeline's
#                    deploy + smoke jobs already gate them.
#   --full:          Run all sections end-to-end (default)
#
# Workflow:
#   1. LLM calls: script.sh --json --full
#   2. If merge conflicts: Returns JSON with conflict details
#   3. LLM resolves conflicts using Read/Edit tools
#   4. LLM continues: script.sh --json --deploy
#
# Features:
#   - Orchestrates existing reusable scripts
#   - LLM intervention at merge conflicts (only when needed)
#   - Auto-flow when everything succeeds (no user input)
#   - --raw mode for debugging when --json insufficient

# Global variables
OUTPUT_MODE="json"  # json or raw
SECTION="full"      # full, validate, risk-analysis, merge, deploy

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Custom status-to-action mapping
map_status_to_action() {
    case "$1" in
        success)         echo "display_summary" ;;
        blocked)         echo "confirm_action" ;;
        conflict)        echo "resolve_conflicts" ;;
        needs_decision)  echo "ask_rebase_strategy" ;;
        *)               echo "fix_error" ;;
    esac
}

source "${SCRIPT_DIR}/lib/output-framework.sh"
source "${SCRIPT_DIR}/lib/deploy-stash.sh"
RISK_SCORE=0
RISK_STATUS="unknown"
MERGE_COMMIT=""
MERGE_STATUS="unknown"
PIPELINE_STATUS="unknown"

# Deployment config variables
DEV_BRANCH=""
STAGING_BRANCH=""
PRODUCTION_BRANCH=""
CI_PLATFORM=""
VERSION=""
STAGING_URL=""

# Conflict details
CONFLICT_FILES=()

#------------------------------------------------------------------------------
# Section Functions
#------------------------------------------------------------------------------

# Section 1: Validate git state
section_validate() {
    log "${BLUE}Validating Git State${NC}"

    if [[ ! -f "PROJECT.yaml" ]]; then
        exit_with_json "error" "PROJECT.yaml not found" "Run: /project-config init"
    fi

    # Load config
    if ! source "${SCRIPT_DIR}/lib/deployment-config.sh" 2>&1; then
        exit_with_json "error" "Failed to load deployment configuration"
    fi

    # Stash a dirty working tree (marked) so the merge/branch-switch runs clean;
    # the user is offered a pop-into-dev-or-drop choice on success.
    deploy_autostash "deploy-to-stage"

    # Ensure target (inactive) instances are running for blue-green deployments
    if [[ "$DEPLOY_STRATEGY" == "blue-green" ]]; then
        log "${BLUE}Checking target instance state${NC}"
        local instance_result
        if instance_result=$(dc_ensure_target_instances "staging"); then
            local instance_status
            instance_status=$(echo "$instance_result" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "")
            if [[ "$instance_status" == "started" ]]; then
                log "${GREEN}✓${NC} Started inactive staging instance (was stopped)"
            elif [[ "$instance_status" == "already_running" ]]; then
                log "${GREEN}✓${NC} Inactive staging instance already running"
            elif [[ "$instance_status" == "skipped" ]]; then
                log "${GREEN}✓${NC} Instance check skipped"
            fi
        else
            exit_with_json "error" "Failed to ensure target staging instance is running" "$instance_result"
        fi
    fi

    # Validate git state
    if ! ~/.claude/scripts/validate-git-state.sh --dev-branch "$DEV_BRANCH" --staging-branch "$STAGING_BRANCH" 2>&1; then
        exit_with_json "error" "Git validation failed" "Branches not in sync or uncommitted changes"
    fi

    if [[ "$SECTION" == "validate" ]]; then
        # Return success with config details
        local json=$(cat <<EOF
{
  "status": "success",
  "next_action": "display_summary",
  "section": "validate",
  "dev_branch": "$DEV_BRANCH",
  "staging_branch": "$STAGING_BRANCH",
  "version": "$VERSION",
  "ci_platform": "$CI_PLATFORM",
  "staging_url": "${STAGING_URL}",
  "timestamp": "$(date -Iseconds)"
}
EOF
)
        log_json "$json"
        exit 0
    fi

    log "${GREEN}✓${NC} Validation complete"
}

# Section 2: Risk analysis
section_risk_analysis() {
    log "${BLUE}Analyzing Deployment Risks${NC}"

    local risk_output
    if ! risk_output=$("${SCRIPT_DIR}/deploy-risk.sh" --json --gather --environment staging 2>&1); then
        log "${YELLOW}⚠${NC} Risk analysis failed, continuing with unknown risk"
        RISK_SCORE=5
        RISK_STATUS="unknown"
    else
        RISK_SCORE=$(echo "$risk_output" | jq -r '.automated_scan.risk_score // 5' 2>/dev/null || echo "5")
        RISK_STATUS=$(echo "$risk_output" | jq -r '.automated_scan.status // "unknown"' 2>/dev/null || echo "unknown")
    fi

    if [[ "$SECTION" == "risk-analysis" ]]; then
        # Return risk analysis results
        local json=$(cat <<EOF
{
  "status": "success",
  "next_action": "display_summary",
  "section": "risk-analysis",
  "risk_score": $RISK_SCORE,
  "risk_status": "$RISK_STATUS",
  "dev_branch": "$DEV_BRANCH",
  "staging_branch": "$STAGING_BRANCH",
  "recommendation": $(if [[ $RISK_SCORE -ge 9 ]]; then echo '"block"'; elif [[ $RISK_SCORE -ge 7 ]]; then echo '"caution"'; else echo '"proceed"'; fi),
  "timestamp": "$(date -Iseconds)"
}
EOF
)
        log_json "$json"
        exit 0
    fi

    # In --full mode, halt on critical risk so the LLM/user can decide.
    # Exit 0 because this is a "paused for input" state, not a failure —
    # next_action=confirm_action in the JSON tells the LLM to prompt the user.
    if [[ $RISK_SCORE -ge 9 ]]; then
        local json=$(cat <<EOF
{
  "status": "blocked",
  "next_action": "confirm_action",
  "section": "risk-analysis",
  "message": "Risk score $RISK_SCORE/10 ($RISK_STATUS) — user confirmation required before proceeding",
  "risk_score": $RISK_SCORE,
  "risk_status": "$RISK_STATUS",
  "dev_branch": "$DEV_BRANCH",
  "staging_branch": "$STAGING_BRANCH",
  "recommendation": "block",
  "options": ["proceed_anyway", "cancel"],
  "next_steps": [
    "Review risk details: deploy-to-stage.sh --raw --risk-analysis",
    "If user approves, resume with: deploy-to-stage.sh --json --merge"
  ],
  "timestamp": "$(date -Iseconds)"
}
EOF
)
        log_json "$json"
        exit 0
    fi

    log "${GREEN}✓${NC} Risk score: $RISK_SCORE/10 ($RISK_STATUS)"
}

# Section 3: Merge (LLM intervention point if conflicts or divergence)
section_merge() {
    log "${BLUE}Merging to Staging${NC}"

    # Attempt merge — capture stdout (JSON) separately from stderr (logs)
    local merge_output
    local merge_stderr
    local merge_exit=0
    merge_stderr=$(mktemp)
    # Regular merge (--no-ff) per Branch, Merge & Deploy SOP
    # Preserves commit SHAs so staging→master promotion only brings new commits
    # --allow-diverged: staging normally has cherry-picks and release-note syncs not on dev;
    # git's merge algorithm reconciles these via merge-base, so SHA-level divergence is expected
    # and should not halt the deploy. Genuine conflicts still surface as status=conflict.
    merge_output=$(~/.claude/scripts/git-merge.sh --json --full --allow-diverged --source "$DEV_BRANCH" --target "$STAGING_BRANCH" 2>"$merge_stderr") || merge_exit=$?
    local merge_stderr_contents
    merge_stderr_contents=$(cat "$merge_stderr" 2>/dev/null || echo "")
    rm -f "$merge_stderr"

    # Extract last JSON object from stdout (git-merge.sh may emit progress then JSON)
    local merge_json
    merge_json=$(echo "$merge_output" | awk 'BEGIN{depth=0; buf=""} /^\{/{buf=""; depth=0} {buf=buf"\n"$0; for(i=1;i<=length($0);i++){c=substr($0,i,1); if(c=="{")depth++; else if(c=="}"){depth--; if(depth==0){print buf; buf=""}}}}' | tail -1)
    # Fallback: if awk extraction produced nothing parseable, use raw output
    if ! echo "$merge_json" | jq empty >/dev/null 2>&1; then
        merge_json="$merge_output"
    fi

    local merge_status
    merge_status=$(echo "$merge_json" | jq -r '.status // ""' 2>/dev/null || echo "")

    # If JSON parse failed entirely, fall back to exit-code heuristic
    if [[ -z "$merge_status" ]]; then
        if [[ $merge_exit -eq 0 ]]; then
            merge_status="success"
        else
            merge_status="error"
        fi
    fi

    case "$merge_status" in
        success)
            MERGE_STATUS="success"
            MERGE_COMMIT=$(echo "$merge_json" | jq -r '.merge_hash // ""' 2>/dev/null)
            [[ -z "$MERGE_COMMIT" || "$MERGE_COMMIT" == "null" ]] && MERGE_COMMIT=$(git rev-parse HEAD)
            ;;

        needs_decision)
            # Branches diverged — user must choose rebase, merge_anyway, or cancel
            MERGE_STATUS="needs_decision"
            local message target_ahead source_ahead options
            message=$(echo "$merge_json" | jq -r '.message // "Branches diverged"' 2>/dev/null)
            target_ahead=$(echo "$merge_json" | jq -r '.target_ahead_count // 0' 2>/dev/null)
            source_ahead=$(echo "$merge_json" | jq -r '.source_ahead_count // 0' 2>/dev/null)
            options=$(echo "$merge_json" | jq -c '.options // ["rebase","merge_anyway","cancel"]' 2>/dev/null)

            local json=$(cat <<EOF
{
  "status": "needs_decision",
  "next_action": "ask_rebase_strategy",
  "section": "merge",
  "message": $(echo "$message" | jq -Rs .),
  "dev_branch": "$DEV_BRANCH",
  "staging_branch": "$STAGING_BRANCH",
  "target_ahead_count": $target_ahead,
  "source_ahead_count": $source_ahead,
  "options": $options,
  "next_steps": [
    "Present options to the user and ask which strategy to use",
    "rebase: rebase $DEV_BRANCH onto $STAGING_BRANCH (rewrites dev history — risky if SHAs consumed elsewhere)",
    "merge_anyway: create a merge commit bringing $DEV_BRANCH into $STAGING_BRANCH (preserves both histories)",
    "cancel: abort deployment and investigate the $target_ahead commits on staging not in dev",
    "After user decides, resume with: deploy-to-stage.sh --json --merge"
  ],
  "timestamp": "$(date -Iseconds)"
}
EOF
)
            log_json "$json"
            # Exit 0: paused for user input, not a failure (matches git-merge.sh convention)
            exit 0
            ;;

        conflict)
            MERGE_STATUS="conflict"
            local conflict_files conflict_count conflict_details
            conflict_files=$(echo "$merge_json" | jq -c '.conflict_files // []' 2>/dev/null)
            conflict_count=$(echo "$merge_json" | jq -r '.conflict_count // 0' 2>/dev/null)
            conflict_details=$(echo "$merge_json" | jq -r '.details // ""' 2>/dev/null)

            local json=$(cat <<EOF
{
  "status": "conflict",
  "next_action": "resolve_conflicts",
  "section": "merge",
  "message": "Merge conflicts detected - LLM intervention required",
  "conflict_files": $conflict_files,
  "conflict_count": $conflict_count,
  "conflict_details": $(echo "$conflict_details" | jq -Rs .),
  "next_steps": [
    "LLM should resolve conflicts in listed files using Read/Edit tools",
    "After resolving: git add <files> && git commit",
    "Then continue: deploy-to-stage.sh --json --deploy"
  ],
  "timestamp": "$(date -Iseconds)"
}
EOF
)
            log_json "$json"
            exit 1
            ;;

        *)
            # Error or unknown status — surface it verbatim
            MERGE_STATUS="error"
            local err_message err_details
            err_message=$(echo "$merge_json" | jq -r '.message // "git-merge.sh failed"' 2>/dev/null)
            err_details=$(echo "$merge_json" | jq -r '.details // ""' 2>/dev/null)
            if [[ -z "$err_details" || "$err_details" == "null" ]]; then
                err_details="$merge_stderr_contents"
            fi
            exit_with_json "error" "Merge failed: $err_message" "$err_details"
            ;;
    esac

    # Merge succeeded — push to remote if git-merge.sh didn't already
    # (git-merge.sh --full includes cleanup which pushes, but if it stopped mid-flow
    #  for any reason, this is a no-op safety push)
    if ! git push origin "$STAGING_BRANCH" >/dev/null 2>&1; then
        log "${YELLOW}⚠${NC} Push to origin/$STAGING_BRANCH returned non-zero (may already be pushed)"
    fi

    if [[ "$SECTION" == "merge" ]]; then
        # Return success
        local json=$(cat <<EOF
{
  "status": "success",
  "next_action": "display_summary",
  "section": "merge",
  "message": "Merge completed successfully",
  "merge_commit": "$MERGE_COMMIT",
  "dev_branch": "$DEV_BRANCH",
  "staging_branch": "$STAGING_BRANCH",
  "next_steps": [
    "Continue deployment: deploy-to-stage.sh --json --deploy"
  ],
  "timestamp": "$(date -Iseconds)"
}
EOF
)
        log_json "$json"
        exit 0
    fi

    log "${GREEN}✓${NC} Merged: $MERGE_COMMIT"
}

# Section 4: Deploy (pipeline + health + version)
section_deploy() {
    log "${BLUE}Deploying to Staging${NC}"

    # Resolve the commit we expect the pipeline to build. Set by section_merge
    # during --full; fall back to local STAGING_BRANCH HEAD when called
    # standalone (typical after manual conflict resolution: user resolved
    # conflicts + git commit, then re-ran --deploy).
    #
    # Critical: if local HEAD is ahead of origin (the manual-merge case),
    # push it first. Otherwise monitor-pipeline.sh polls a SHA the remote
    # has never seen and times out — or worse, matches a stale run on the
    # branch and reports immediate false-positive success.
    if [[ -z "$MERGE_COMMIT" ]]; then
        git fetch origin "$STAGING_BRANCH" >/dev/null 2>&1 || true
        local _local_head _remote_head
        _local_head=$(git rev-parse "$STAGING_BRANCH" 2>/dev/null || echo "")
        _remote_head=$(git rev-parse "origin/$STAGING_BRANCH" 2>/dev/null || echo "")
        if [[ -n "$_local_head" && "$_local_head" != "$_remote_head" ]]; then
            # Confirm local is strictly ahead (not diverged) before pushing.
            if git merge-base --is-ancestor "$_remote_head" "$_local_head" 2>/dev/null; then
                log "${BLUE}→${NC} Local $STAGING_BRANCH is ahead of origin — pushing before monitoring pipeline"
                if ! git push origin "$STAGING_BRANCH" 2>&1; then
                    exit_with_json "error" "Failed to push local $STAGING_BRANCH to origin" \
                        "Resolve manually then re-run: deploy-to-stage.sh --json --deploy"
                fi
                MERGE_COMMIT="$_local_head"
            else
                exit_with_json "error" "Local $STAGING_BRANCH has diverged from origin/$STAGING_BRANCH" \
                    "Investigate divergence (git log origin/$STAGING_BRANCH..$STAGING_BRANCH) before re-running --deploy"
            fi
        else
            MERGE_COMMIT="$_remote_head"
        fi
    fi

    # Monitor pipeline for THIS commit. Matching by SHA prevents the monitor
    # from matching a stale run on the branch (which would return immediate
    # false-positive success when the push didn't actually land).
    # Distinguish the monitor's three exit codes: 0=success, 1=failure,
    # 2=timeout. Collapsing 2 into 1 reports a still-running pipeline as a
    # failed deploy and sends people hunting a break that doesn't exist.
    local _monitor_rc=0
    ~/.claude/scripts/monitor-pipeline.sh --branch "$STAGING_BRANCH" --head-sha "$MERGE_COMMIT" 2>&1 || _monitor_rc=$?
    if [[ $_monitor_rc -eq 2 ]]; then
        # The merge is already pushed and the pipeline is still going, so this
        # is "unverified", not "broken" — it may well go green on its own.
        PIPELINE_STATUS="timeout"
        exit_with_json "error" "Pipeline still RUNNING when the monitor stopped watching — this is NOT a failure. Watch it to completion with '~/.claude/scripts/pipeline-watch.sh --branch ${STAGING_BRANCH} --head-sha ${MERGE_COMMIT}' (those flags keep it on the deploy run rather than another workflow on the same commit), then re-run this script with --deploy to finish the post-deploy steps. If this pipeline is legitimately this slow, raise ci.pipeline_timeout in PROJECT.yaml (default 540s, capped at 540s so this message can reach you before the Bash tool's 600s limit — for longer waits use pipeline-watch.sh)."
    elif [[ $_monitor_rc -ne 0 ]]; then
        PIPELINE_STATUS="failed"
        exit_with_json "error" "Pipeline failed"
    fi
    PIPELINE_STATUS="success"
    log "${GREEN}✓${NC} Pipeline succeeded — build + deploy + smoke (health + version canary) all gated in-pipeline"

    # NOTE: health and deployed-version are deliberately NOT re-checked here.
    # The staging pipeline's deploy + smoke jobs already gate on Docker health
    # status and the version canary; re-running check-health.sh /
    # check-deployed-version.sh from the client would just duplicate work the
    # pipeline already performed (and gated the deploy on). Pipeline success IS
    # the health+version gate.

    if [[ "$SECTION" == "deploy" ]]; then
        local _stash_ref _next_action _stash_json
        _stash_ref=$(deploy_find_marked_stash)
        if [[ -n "$_stash_ref" ]]; then
            _next_action="prompt_stash"
            _stash_json=$(deploy_stash_details_json "$_stash_ref")
        else
            _next_action="display_summary"
            _stash_json="null"
        fi
        # Return deployment results
        local json=$(cat <<EOF
{
  "status": "success",
  "next_action": "$_next_action",
  "stash": $_stash_json,
  "section": "deploy",
  "pipeline_status": "$PIPELINE_STATUS",
  "staging_url": "${STAGING_URL}",
  "version": "$VERSION",
  "timestamp": "$(date -Iseconds)"
}
EOF
)
        return_to_dev
        log_json "$json"
        exit 0
    fi

    return_to_dev
    log "${GREEN}✓${NC} Deployment complete"
}

# On successful completion, return the working tree to the dev branch. The merge
# step leaves us on the staging branch; callers expect to resume work on dev.
# The dev branch NAME is sourced from PROJECT.yaml (DEV_BRANCH), never hardcoded.
return_to_dev() {
    if [[ -z "$DEV_BRANCH" ]]; then
        return
    fi
    local current
    current=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
    if [[ "$current" == "$DEV_BRANCH" ]]; then
        return
    fi
    if git checkout "$DEV_BRANCH" >/dev/null 2>&1; then
        log "${GREEN}✓${NC} Returned to ${DEV_BRANCH} branch"
    else
        log "${YELLOW}⚠${NC} Could not switch back to ${DEV_BRANCH} (left on ${current:-current branch})"
    fi
}

#------------------------------------------------------------------------------
# Main Execution
#------------------------------------------------------------------------------

main() {
    # Parse flags
    while [[ $# -gt 0 ]]; do
        case $1 in
            --json) OUTPUT_MODE="json"; shift ;;
            --toon) OUTPUT_MODE="json"; OUTPUT_FORMAT="toon"; shift ;;
            --raw) OUTPUT_MODE="raw"; shift ;;
            --validate) SECTION="validate"; shift ;;
            --risk-analysis) SECTION="risk-analysis"; shift ;;
            --merge) SECTION="merge"; shift ;;
            --deploy) SECTION="deploy"; shift ;;
            --full) SECTION="full"; shift ;;
            *) shift ;;
        esac
    done

    # Load configuration (always needed)
    if [[ ! -f "PROJECT.yaml" ]]; then
        exit_with_json "error" "PROJECT.yaml not found"
    fi

    if ! source "${SCRIPT_DIR}/lib/deployment-config.sh" 2>&1; then
        exit_with_json "error" "Failed to load deployment configuration"
    fi

    # Execute sections based on flag
    case "$SECTION" in
        validate)
            section_validate
            ;;
        risk-analysis)
            section_validate  # Need config first
            section_risk_analysis
            ;;
        merge)
            section_validate  # Need config first
            section_merge
            ;;
        deploy)
            # Assume merge already done, just deploy
            section_deploy
            ;;
        full)
            section_validate
            section_risk_analysis
            section_merge
            section_deploy

            # Pipeline success IS the gate — its deploy + smoke jobs already
            # validated health + version. No client-side post-deploy checks to
            # collect, so a green pipeline is an unqualified success.
            # section_deploy already returned us to dev; if we auto-stashed a
            # dirty tree at the start, prompt to pop-into-dev or drop it.
            local _stash_ref _next_action _stash_json
            _stash_ref=$(deploy_find_marked_stash)
            if [[ -n "$_stash_ref" ]]; then
                _next_action="prompt_stash"
                _stash_json=$(deploy_stash_details_json "$_stash_ref")
            else
                _next_action="display_summary"
                _stash_json="null"
            fi
            local json=$(cat <<EOF
{
  "status": "success",
  "next_action": "$_next_action",
  "stash": $_stash_json,
  "deployment": "staging",
  "dev_branch": "$DEV_BRANCH",
  "staging_branch": "$STAGING_BRANCH",
  "version": "$VERSION",
  "merge_commit": "$MERGE_COMMIT",
  "risk_score": $RISK_SCORE,
  "risk_status": "$RISK_STATUS",
  "pipeline_status": "$PIPELINE_STATUS",
  "staging_url": "${STAGING_URL}",
  "ci_platform": "$CI_PLATFORM",
  "timestamp": "$(date -Iseconds)"
}
EOF
)
            log_json "$json"
            exit 0
            ;;
    esac
}

# Run main function
main "$@"
