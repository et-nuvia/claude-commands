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
#   --json: Structured JSON output for LLM (default)
#   --raw:  Verbose debugging output when LLM needs more details
#
# Section Flags (run specific section only):
#   --validate:      Validate git state only
#   --risk-analysis: Run automated risk analysis only
#   --merge:         Attempt merge only (returns conflict details if needed)
#   --deploy:        Run pipeline + health + version (after merge)
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
RISK_SCORE=0
RISK_STATUS="unknown"
MERGE_COMMIT=""
MERGE_STATUS="unknown"
PIPELINE_STATUS="unknown"
HEALTH_STATUS="unknown"
VERSION_STATUS="unknown"

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
    if ! ~/.claude/scripts/monitor-pipeline.sh --branch "$STAGING_BRANCH" --head-sha "$MERGE_COMMIT" 2>&1; then
        PIPELINE_STATUS="failed"
        exit_with_json "error" "Pipeline failed"
    fi
    PIPELINE_STATUS="success"
    log "${GREEN}✓${NC} Pipeline succeeded"

    # Check health
    if [[ -n "$STAGING_URL" ]]; then
        if ~/.claude/scripts/check-health.sh --url "$STAGING_URL" --health-path "$HEALTH_CHECK_PATH" 2>&1; then
            HEALTH_STATUS="healthy"
        else
            HEALTH_STATUS="unhealthy"
            log "${YELLOW}⚠${NC} Health check failed (non-blocking)"
        fi
    else
        HEALTH_STATUS="skipped"
    fi

    # Verify version
    #
    # The check has to target the URL the deploy actually went to:
    #   - blue-green: the *inactive* color's domain (e.g. clearance-staging-blue).
    #     STAGING_URL is the roving domain, which still serves the
    #     previously-active color until DNS cutover, so checking it here
    #     would always fail.
    #   - other strategies: the deploy goes directly to STAGING_URL.
    # Mismatch is non-blocking on staging (warning only), unlike production.
    local _verify_url=""
    if [[ "$DEPLOY_STRATEGY" == "blue-green" ]]; then
        _verify_url=$(dc_get_target_url staging || true)
        if [[ -z "$_verify_url" ]]; then
            VERSION_STATUS="skipped"
            log "${YELLOW}⚠${NC} Could not resolve target color URL — skipping version check"
        fi
    else
        _verify_url="$STAGING_URL"
    fi

    if [[ -n "$_verify_url" ]]; then
        log "${BLUE}→${NC} Verifying version at: $_verify_url"
        if ~/.claude/scripts/check-deployed-version.sh --url "$_verify_url" --expected-version "$VERSION" --version-path "$VERSION_PATH" 2>&1; then
            VERSION_STATUS="verified"
        else
            VERSION_STATUS="unverified"
            log "${YELLOW}⚠${NC} Version verification failed (non-blocking)"
        fi
    elif [[ -z "${VERSION_STATUS:-}" || "$VERSION_STATUS" == "unknown" ]]; then
        VERSION_STATUS="skipped"
    fi

    if [[ "$SECTION" == "deploy" ]]; then
        # Return deployment results
        local json=$(cat <<EOF
{
  "status": "success",
  "next_action": "display_summary",
  "section": "deploy",
  "pipeline_status": "$PIPELINE_STATUS",
  "health_status": "$HEALTH_STATUS",
  "version_status": "$VERSION_STATUS",
  "staging_url": "${STAGING_URL}",
  "version": "$VERSION",
  "timestamp": "$(date -Iseconds)"
}
EOF
)
        log_json "$json"
        exit 0
    fi

    log "${GREEN}✓${NC} Deployment complete"
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

            # Collect any post-deploy warnings (skipped checks that weren't configured are OK)
            local issues_json="[]"
            local issues=()
            [[ "$HEALTH_STATUS" == "unhealthy" ]] && issues+=("\"health check failed\"")
            [[ "$VERSION_STATUS" == "unverified" ]] && issues+=("\"deployed version did not match expected $VERSION\"")
            if [[ ${#issues[@]} -gt 0 ]]; then
                issues_json="[$(IFS=,; echo "${issues[*]}")]"
            fi

            local final_status final_action
            if [[ "$issues_json" == "[]" ]]; then
                final_status="success"
                final_action="display_summary"
            else
                final_status="warning"
                final_action="display_summary"
            fi

            local json=$(cat <<EOF
{
  "status": "$final_status",
  "next_action": "$final_action",
  "deployment": "staging",
  "dev_branch": "$DEV_BRANCH",
  "staging_branch": "$STAGING_BRANCH",
  "version": "$VERSION",
  "merge_commit": "$MERGE_COMMIT",
  "risk_score": $RISK_SCORE,
  "risk_status": "$RISK_STATUS",
  "pipeline_status": "$PIPELINE_STATUS",
  "health_status": "$HEALTH_STATUS",
  "version_status": "$VERSION_STATUS",
  "issues": $issues_json,
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
