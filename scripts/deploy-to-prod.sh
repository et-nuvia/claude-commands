#!/usr/bin/env bash
set -euo pipefail

# deploy-to-prod.sh - Deploy to production with strict risk analysis, merge, and monitoring
#
# STANDARD SCRIPT PATTERN: Section flags with --json/--raw output modes
#
# Usage:
#   ~/.claude/scripts/deploy-to-prod.sh [--json|--raw] [--full|--section]
#
# Output Modes:
#   --json: Structured JSON output for LLM (default)
#   --raw:  Verbose debugging output when LLM needs more details
#
# Section Flags (run specific section only):
#   --validate:      Validate git state only
#   --risk-analysis: Run automated risk analysis only (production strict)
#   --merge:         Attempt merge only (returns conflict details if needed)
#   --deploy:        Run pipeline + health + version (after merge)
#   --tag:           Create release tag and sync to staging/dev
#   --full:          Run all sections end-to-end (default)
#
# Workflow:
#   1. LLM calls: script.sh --json --full
#   2. If merge conflicts: Returns JSON with conflict details
#   3. LLM resolves conflicts using Read/Edit tools
#   4. LLM continues: script.sh --json --deploy
#   5. On success: script.sh --json --tag
#
# Features:
#   - Strictest risk thresholds for production
#   - LLM intervention at merge conflicts
#   - Auto-flow when everything succeeds
#   - --raw mode for debugging
#   - Idempotent: re-running --full after partial success resumes cleanly
#
# Rollback and smoke tests are owned by the CI pipeline, not this script.

# Global variables
OUTPUT_MODE="json"
SECTION="full"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Custom status-to-action mapping
map_status_to_action() {
    case "$1" in
        success)  echo "display_summary" ;;
        blocked)  echo "confirm_action" ;;
        conflict) echo "resolve_conflicts" ;;
        *)        echo "fix_error" ;;
    esac
}

source "${SCRIPT_DIR}/lib/output-framework.sh"

# Guard: deploy scripts must run from main checkout, not a worktree (DSN Decision 4)
if declare -f is_in_worktree &>/dev/null && is_in_worktree; then
    exit_with_json "error" "Deploy scripts must run from the main checkout, not a worktree" \
        "cd to the main repo checkout first, then re-run"
fi

# Cleanup on unexpected exit: abort any in-progress merge and return to the
# original branch. Without this, a Ctrl-C or set -e trip during section_tag
# can strand the working tree on staging/dev with a half-finished merge.
_ORIG_BRANCH=$(git branch --show-current 2>/dev/null || echo "")
_cleanup_on_error() {
    local rc=$?
    [[ $rc -eq 0 ]] && return 0
    git merge --abort >/dev/null 2>&1 || true
    git revert --abort >/dev/null 2>&1 || true
    if [[ -n "$_ORIG_BRANCH" ]]; then
        local current
        current=$(git branch --show-current 2>/dev/null || echo "")
        if [[ "$current" != "$_ORIG_BRANCH" ]]; then
            git checkout "$_ORIG_BRANCH" >/dev/null 2>&1 || true
        fi
    fi
    return $rc
}
trap '_cleanup_on_error' EXIT INT TERM

RISK_SCORE=0
RISK_STATUS="unknown"
MERGE_COMMIT=""
MERGE_STATUS="unknown"
PIPELINE_STATUS="unknown"
HEALTH_STATUS="unknown"
VERSION_STATUS="unknown"
RELEASE_TAG=""

# Deployment config variables
DEV_BRANCH=""
STAGING_BRANCH=""
PRODUCTION_BRANCH=""
CI_PLATFORM=""
VERSION=""
PRODUCTION_URL=""

# Conflict details
CONFLICT_FILES=()

#------------------------------------------------------------------------------
# Section Functions
#------------------------------------------------------------------------------

# Section 1: Validate git state
section_validate() {
    log "${BLUE}Validating Git State (Production)${NC}"

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
        if instance_result=$(dc_ensure_target_instances "production"); then
            local instance_status
            instance_status=$(echo "$instance_result" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "")
            if [[ "$instance_status" == "started" ]]; then
                log "${GREEN}✓${NC} Started inactive production instance (was stopped)"
            elif [[ "$instance_status" == "already_running" ]]; then
                log "${GREEN}✓${NC} Inactive production instance already running"
            elif [[ "$instance_status" == "skipped" ]]; then
                log "${GREEN}✓${NC} Instance check skipped"
            fi
        else
            exit_with_json "error" "Failed to ensure target production instance is running" "$instance_result"
        fi
    fi

    # Validate git state
    if ! ~/.claude/scripts/validate-git-state.sh --dev-branch "$STAGING_BRANCH" --staging-branch "$PRODUCTION_BRANCH" 2>&1; then
        exit_with_json "error" "Git validation failed" "Branches not in sync or uncommitted changes"
    fi

    if [[ "$SECTION" == "validate" ]]; then
        local json=$(cat <<EOF
{
  "status": "success",
  "next_action": "display_summary",
  "section": "validate",
  "staging_branch": "$STAGING_BRANCH",
  "production_branch": "$PRODUCTION_BRANCH",
  "version": "$VERSION",
  "ci_platform": "$CI_PLATFORM",
  "production_url": "${PRODUCTION_URL}",
  "timestamp": "$(date -Iseconds)"
}
EOF
)
        log_json "$json"
        exit 0
    fi

    log "${GREEN}✓${NC} Validation complete"
}

# Section 2: Risk analysis (production strict)
section_risk_analysis() {
    log "${BLUE}Analyzing Deployment Risks (Production Strict)${NC}"

    local risk_output
    if ! risk_output=$("${SCRIPT_DIR}/deploy-risk.sh" --json --gather --environment production 2>&1); then
        log "${YELLOW}⚠${NC} Risk analysis failed"
        RISK_SCORE=5
        RISK_STATUS="unknown"
    else
        RISK_SCORE=$(echo "$risk_output" | jq -r '.automated_scan.risk_score // 5' 2>/dev/null || echo "5")
        RISK_STATUS=$(echo "$risk_output" | jq -r '.automated_scan.status // "unknown"' 2>/dev/null || echo "unknown")
    fi

    # Production: 9+ blocks, 7+ warns
    local recommendation="proceed"
    if [[ $RISK_SCORE -ge 9 ]]; then
        recommendation="block"
    elif [[ $RISK_SCORE -ge 7 ]]; then
        recommendation="caution"
    fi

    if [[ "$SECTION" == "risk-analysis" ]]; then
        local json=$(cat <<EOF
{
  "status": $(if [[ $RISK_SCORE -ge 9 ]]; then echo '"blocked"'; else echo '"success"'; fi),
  "next_action": $(if [[ $RISK_SCORE -ge 9 ]]; then echo '"confirm_action"'; else echo '"display_summary"'; fi),
  "section": "risk-analysis",
  "risk_score": $RISK_SCORE,
  "risk_status": "$RISK_STATUS",
  "staging_branch": "$STAGING_BRANCH",
  "production_branch": "$PRODUCTION_BRANCH",
  "recommendation": "$recommendation",
  "threshold": "production (9+ blocks, 7+ warns)",
  "timestamp": "$(date -Iseconds)"
}
EOF
)
        log_json "$json"
        exit $(if [[ $RISK_SCORE -ge 9 ]]; then echo 1; else echo 0; fi)
    fi

    # In full mode, block if score too high
    if [[ $RISK_SCORE -ge 9 ]]; then
        exit_with_json "blocked" "Risk score too high for production" "Score: $RISK_SCORE/10. Review and mitigate risks before deploying."
    fi

    log "${GREEN}✓${NC} Risk score: $RISK_SCORE/10 ($RISK_STATUS)"
}

# Section 3: Merge (regular merge for production)
section_merge() {
    log "${BLUE}Merging to Production${NC}"

    # Idempotency guard: if source is already merged into target on origin, skip.
    # Lets re-runs of --full after a partial success proceed straight to deploy.
    git fetch origin "$STAGING_BRANCH" "$PRODUCTION_BRANCH" >/dev/null 2>&1 || true
    local _src_sha _tgt_sha
    _src_sha=$(git rev-parse "origin/$STAGING_BRANCH" 2>/dev/null || echo "")
    _tgt_sha=$(git rev-parse "origin/$PRODUCTION_BRANCH" 2>/dev/null || echo "")
    if [[ -n "$_src_sha" && -n "$_tgt_sha" ]] && \
       git merge-base --is-ancestor "$_src_sha" "$_tgt_sha" 2>/dev/null; then
        MERGE_STATUS="success"
        MERGE_COMMIT="$_tgt_sha"
        log "${GREEN}✓${NC} $STAGING_BRANCH already merged into $PRODUCTION_BRANCH ($_tgt_sha) — skipping merge"

        if [[ "$SECTION" == "merge" ]]; then
            local json=$(cat <<EOF
{
  "status": "success",
  "next_action": "display_summary",
  "section": "merge",
  "message": "Already merged (idempotent skip)",
  "merge_commit": "$MERGE_COMMIT",
  "staging_branch": "$STAGING_BRANCH",
  "production_branch": "$PRODUCTION_BRANCH",
  "next_steps": [
    "Continue deployment: deploy-to-prod.sh --json --deploy"
  ],
  "timestamp": "$(date -Iseconds)"
}
EOF
)
            log_json "$json"
            exit 0
        fi
        return 0
    fi

    # Capture git-merge.sh stdout (JSON) separately from stderr (logs).
    # --allow-diverged: production (master) normally has release-note autosync
    # commits from prior prod deploys that aren't on staging. git's merge
    # algorithm reconciles these via merge-base; SHA-level divergence is
    # expected here and must not halt the deploy.
    local merge_output merge_stderr merge_exit=0
    merge_stderr=$(mktemp)
    merge_output=$(~/.claude/scripts/git-merge.sh --json --full --allow-diverged --source "$STAGING_BRANCH" --target "$PRODUCTION_BRANCH" 2>"$merge_stderr") || merge_exit=$?
    local merge_stderr_contents
    merge_stderr_contents=$(cat "$merge_stderr" 2>/dev/null || echo "")
    rm -f "$merge_stderr"

    # Extract last JSON object from stdout (git-merge.sh may emit progress then JSON)
    local merge_json
    merge_json=$(echo "$merge_output" | awk 'BEGIN{depth=0; buf=""} /^\{/{buf=""; depth=0} {buf=buf"\n"$0; for(i=1;i<=length($0);i++){c=substr($0,i,1); if(c=="{")depth++; else if(c=="}"){depth--; if(depth==0){print buf; buf=""}}}}' | tail -1)
    if ! echo "$merge_json" | jq empty >/dev/null 2>&1; then
        merge_json="$merge_output"
    fi

    local merge_status
    merge_status=$(echo "$merge_json" | jq -r '.status // ""' 2>/dev/null || echo "")
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
            ;;

        needs_decision)
            # Branches diverged in a way --allow-diverged didn't resolve — surface to user
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
  "staging_branch": "$STAGING_BRANCH",
  "production_branch": "$PRODUCTION_BRANCH",
  "target_ahead_count": $target_ahead,
  "source_ahead_count": $source_ahead,
  "options": $options,
  "next_steps": [
    "Present options to the user and ask which strategy to use",
    "After user decides, resume with: deploy-to-prod.sh --json --merge"
  ],
  "timestamp": "$(date -Iseconds)"
}
EOF
)
            log_json "$json"
            exit 0
            ;;

        conflict)
            MERGE_STATUS="conflict"
            mapfile -t CONFLICT_FILES < <(echo "$merge_json" | jq -r '.conflict_files[]? // empty' 2>/dev/null)
            local conflict_count=${#CONFLICT_FILES[@]}
            local conflict_details
            conflict_details=$(echo "$merge_json" | jq -r '.details // ""' 2>/dev/null)

            local conflict_files_json
            if [[ $conflict_count -eq 0 ]]; then
                conflict_files_json="[]"
            else
                conflict_files_json=$(printf '%s\n' "${CONFLICT_FILES[@]}" | jq -R . | jq -s .)
            fi

            local json=$(cat <<EOF
{
  "status": "conflict",
  "next_action": "resolve_conflicts",
  "section": "merge",
  "message": "Production merge conflicts - LLM intervention required",
  "conflict_files": $conflict_files_json,
  "conflict_count": $conflict_count,
  "conflict_details": $(echo "$conflict_details" | jq -Rs .),
  "next_steps": [
    "LLM should resolve conflicts in listed files using Read/Edit tools",
    "After resolving: git add <files> && git commit",
    "Then continue: deploy-to-prod.sh --json --deploy (will auto-push the merge before monitoring)"
  ],
  "timestamp": "$(date -Iseconds)"
}
EOF
)
            log_json "$json"
            exit 1
            ;;

        *)
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

    # git-merge.sh --full includes cleanup which pushes. Verify the push actually
    # landed on origin — if it didn't, the pipeline won't run and the deploy would
    # silently appear to succeed against the previous build.
    if ! git fetch origin "$PRODUCTION_BRANCH" >/dev/null 2>&1; then
        exit_with_json "error" "Failed to fetch $PRODUCTION_BRANCH after merge" "Cannot verify merge was pushed"
    fi
    local remote_head
    remote_head=$(git rev-parse "origin/$PRODUCTION_BRANCH" 2>/dev/null || echo "")
    if [[ -z "$MERGE_COMMIT" || "$MERGE_COMMIT" == "null" ]]; then
        MERGE_COMMIT="$remote_head"
    fi
    if [[ "$remote_head" != "$MERGE_COMMIT" ]]; then
        exit_with_json "error" \
            "Merge commit not found on remote" \
            "Local merge: $MERGE_COMMIT, origin/$PRODUCTION_BRANCH: $remote_head. Push may have failed or been rejected."
    fi

    if [[ "$SECTION" == "merge" ]]; then
        local json=$(cat <<EOF
{
  "status": "success",
  "next_action": "display_summary",
  "section": "merge",
  "message": "Production merge completed successfully",
  "merge_commit": "$MERGE_COMMIT",
  "merge_type": "regular (preserves history)",
  "staging_branch": "$STAGING_BRANCH",
  "production_branch": "$PRODUCTION_BRANCH",
  "next_steps": [
    "Continue deployment: deploy-to-prod.sh --json --deploy"
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
    log "${BLUE}Deploying to Production${NC}"

    # Refuse to start a deploy section with a dirty working tree — a prior
    # interrupted run could have left half-staged files that would either
    # ride along on the merge or block subsequent git operations.
    if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
        exit_with_json "error" "Working tree is dirty" \
            "Resolve uncommitted changes before re-running --deploy (git status to inspect)"
    fi

    # Resolve the commit we expect the pipeline to build, and ensure it is on
    # origin. When --full ran end-to-end, section_merge already pushed via
    # git-merge.sh cleanup. When --deploy is invoked standalone after manual
    # conflict resolution, the local merge commit lives only on the developer's
    # machine — without an explicit push here, monitor-pipeline.sh would watch
    # the stale origin HEAD forever.
    git fetch origin "$PRODUCTION_BRANCH" >/dev/null 2>&1 || true
    local local_head remote_head
    local_head=$(git rev-parse "$PRODUCTION_BRANCH" 2>/dev/null || echo "")
    remote_head=$(git rev-parse "origin/$PRODUCTION_BRANCH" 2>/dev/null || echo "")

    if [[ -z "$MERGE_COMMIT" ]]; then
        MERGE_COMMIT="$local_head"
    fi

    if [[ -n "$local_head" && "$local_head" != "$remote_head" ]]; then
        # Confirm local is strictly ahead before pushing — refuse to push if
        # branches have diverged (would imply someone else pushed in the
        # meantime; safer to surface the conflict than fast-forward over it).
        if git merge-base --is-ancestor "$remote_head" "$local_head" 2>/dev/null; then
            log "${BLUE}→${NC} Pushing local $PRODUCTION_BRANCH ($local_head) to origin"
            if ! git push origin "$PRODUCTION_BRANCH" 2>&1; then
                exit_with_json "error" \
                    "Failed to push $PRODUCTION_BRANCH to origin" \
                    "Local: $local_head, origin: $remote_head. Resolve push failure (auth, branch protection, etc.) and retry --deploy."
            fi
            MERGE_COMMIT="$local_head"
        else
            exit_with_json "error" \
                "Local $PRODUCTION_BRANCH has diverged from origin" \
                "Local: $local_head, origin: $remote_head. origin is not an ancestor of local — refusing to push. Reconcile manually and retry."
        fi
    fi

    if [[ -z "$MERGE_COMMIT" ]]; then
        exit_with_json "error" "Cannot determine commit to deploy" "Both local and origin/$PRODUCTION_BRANCH are empty"
    fi

    # Monitor pipeline for THIS commit on the production branch. Matching by SHA
    # is critical — without it, the monitor matches the latest run on the branch
    # (often a stale, already-succeeded run) and reports false success.
    if ! ~/.claude/scripts/monitor-pipeline.sh --branch "$PRODUCTION_BRANCH" --head-sha "$MERGE_COMMIT" 2>&1; then
        git fetch origin "$PRODUCTION_BRANCH" >/dev/null 2>&1 || true
        local current_remote
        current_remote=$(git rev-parse "origin/$PRODUCTION_BRANCH" 2>/dev/null || echo "")
        if [[ "$current_remote" != "$MERGE_COMMIT" ]]; then
            PIPELINE_STATUS="not_started"
            exit_with_json "error" \
                "No pipeline run found for $MERGE_COMMIT on $PRODUCTION_BRANCH" \
                "origin/$PRODUCTION_BRANCH is at $current_remote, expected $MERGE_COMMIT. The push may have been rejected or the merge commit contains [skip ci]."
        fi
        PIPELINE_STATUS="failed"
        exit_with_json "error" "Pipeline failed on $PRODUCTION_BRANCH for $MERGE_COMMIT"
    fi
    PIPELINE_STATUS="success"
    log "${GREEN}✓${NC} Pipeline succeeded"

    # Refresh VERSION from git tags. The pipeline's tag-release job computes the
    # next version from conventional commits and pushes a new tag during deploy,
    # so the value captured at script startup (in deployment-config.sh) is one
    # release behind what was actually deployed. The refreshed value is used in
    # the success JSON and the --tag section; without it, both lag by one
    # release.
    git fetch --tags --force origin >/dev/null 2>&1 || true
    local refreshed_version
    refreshed_version=$(~/.claude/scripts/get-version.sh -g -q 2>/dev/null || echo "")
    if [[ -n "$refreshed_version" && "$refreshed_version" != "$VERSION" ]]; then
        log "${BLUE}→${NC} Refreshed version from git tags: $VERSION → $refreshed_version"
        VERSION="$refreshed_version"
    fi

    # Health check is informational only.
    if [[ -n "$PRODUCTION_URL" ]]; then
        if ~/.claude/scripts/check-health.sh --url "$PRODUCTION_URL" --health-path "$HEALTH_CHECK_PATH" 2>&1; then
            HEALTH_STATUS="healthy"
        else
            HEALTH_STATUS="unhealthy"
            log "${YELLOW}⚠${NC} Health check failed"
        fi
    else
        HEALTH_STATUS="skipped"
    fi

    # Verify version
    #
    # The check has to target the URL the deploy actually went to:
    #   - blue-green: the *inactive* color's domain (e.g. clearance-blue.x.com).
    #     PRODUCTION_URL is the roving domain, which still serves the
    #     previously-active color until DNS cutover, so checking it here
    #     would always fail.
    #   - other strategies: the deploy goes directly to PRODUCTION_URL.
    local _verify_url=""
    if [[ "$DEPLOY_STRATEGY" == "blue-green" ]]; then
        _verify_url=$(dc_get_target_url production || true)
        if [[ -z "$_verify_url" ]]; then
            VERSION_STATUS="skipped"
            log "${YELLOW}⚠${NC} Could not resolve target color URL — skipping version check"
        fi
    else
        _verify_url="$PRODUCTION_URL"
    fi

    if [[ -n "$_verify_url" ]]; then
        log "${BLUE}→${NC} Verifying version at: $_verify_url"
        if ~/.claude/scripts/check-deployed-version.sh --url "$_verify_url" --expected-version "$VERSION" --version-path "$VERSION_PATH" 2>&1; then
            VERSION_STATUS="verified"
        else
            VERSION_STATUS="unverified"
            log "${YELLOW}⚠${NC} Version verification failed"
        fi
    elif [[ -z "${VERSION_STATUS:-}" || "$VERSION_STATUS" == "unknown" ]]; then
        VERSION_STATUS="skipped"
    fi

    if [[ "$SECTION" == "deploy" ]]; then
        local json=$(cat <<EOF
{
  "status": "success",
  "next_action": "display_summary",
  "section": "deploy",
  "pipeline_status": "$PIPELINE_STATUS",
  "health_status": "$HEALTH_STATUS",
  "version_status": "$VERSION_STATUS",
  "production_url": "${PRODUCTION_URL}",
  "version": "$VERSION",
  "next_steps": [
    "Create release tag: deploy-to-prod.sh --json --tag"
  ],
  "timestamp": "$(date -Iseconds)"
}
EOF
)
        log_json "$json"
        exit 0
    fi

    log "${GREEN}✓${NC} Deployment complete"
}

# Section 5: Tag and sync
#
# Tagging is skipped when the pipeline handles version bumping + tagging itself
# (common pattern: prod pipeline computes next version from conventional commits,
# tags the deployed SHA, and pushes the tag). In that case the tag created here
# would collide. If $VERSION is empty or the tag already exists at the deployed
# SHA, we treat tagging as a no-op and proceed with branch sync-back.
section_tag() {
    log "${BLUE}Creating Release Tag${NC}"

    # Refuse to tag with a dirty working tree — the sync_branch step does
    # checkouts and merges that won't work cleanly otherwise.
    if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
        exit_with_json "error" "Working tree is dirty" \
            "Resolve uncommitted changes before re-running --tag (git status to inspect)"
    fi

    # Refresh tags so we can check for existing tags created by the pipeline
    git fetch origin --tags >/dev/null 2>&1 || true

    # Prefer a semver tag (vX.Y.Z) already pointing at the deployed commit —
    # that's the pipeline's bumped version. Filter to semver shape so we
    # don't pick up `latest`, `staging`, or other floating tags that happen
    # to share the commit. Sort by version and take the highest.
    local pipeline_tag
    pipeline_tag=$(git tag --points-at "$MERGE_COMMIT" 2>/dev/null \
        | grep -E '^v?[0-9]+\.[0-9]+\.[0-9]+([+-].*)?$' \
        | sort -V \
        | tail -1)

    if [[ -n "$pipeline_tag" ]]; then
        RELEASE_TAG="$pipeline_tag"
        log "${GREEN}✓${NC} Release tag already at $MERGE_COMMIT (pipeline-created): $RELEASE_TAG"
    elif [[ -z "$VERSION" ]]; then
        log "${YELLOW}⚠${NC} VERSION empty and no pipeline tag found — skipping tag creation"
        RELEASE_TAG=""
    else
        RELEASE_TAG="v${VERSION}"

        if git rev-parse -q --verify "refs/tags/$RELEASE_TAG" >/dev/null 2>&1; then
            # Tag already exists elsewhere. The pipeline is authoritative for
            # versioning — if it didn't tag our MERGE_COMMIT, assume it'll do
            # so later or intentionally skipped. Don't fight it: log and move
            # on to branch sync-back.
            local existing_sha
            existing_sha=$(git rev-list -n 1 "$RELEASE_TAG")
            log "${YELLOW}⚠${NC} Tag $RELEASE_TAG already at $existing_sha (not our $MERGE_COMMIT) — skipping tag creation (pipeline owns versioning)"
            RELEASE_TAG=""
        else
            if ! git tag -a "$RELEASE_TAG" -m "chore(release): v$VERSION" 2>&1; then
                exit_with_json "error" "Failed to create tag $RELEASE_TAG"
            fi
            if ! git push origin "$RELEASE_TAG" 2>&1; then
                # Drop the local tag so a retry doesn't see it as "already exists"
                # and skip pushing, or worse, treat it as the pipeline-created tag.
                git tag -d "$RELEASE_TAG" >/dev/null 2>&1 || true
                exit_with_json "error" "Failed to push tag $RELEASE_TAG (local tag deleted to keep state consistent)"
            fi
            log "${GREEN}✓${NC} Tag created and pushed: $RELEASE_TAG"
        fi
    fi

    # Sync production -> staging. Use a non-ff merge and fall back gracefully:
    # release-note autosync commits on master that aren't on staging mean
    # --ff-only is often impossible. A plain `git merge` creates a merge
    # commit and succeeds.
    sync_branch() {
        local from="$1" into="$2"
        log "Syncing $from -> $into"

        if ! git checkout "$into" >/dev/null 2>&1; then
            log "${RED}✗${NC} Failed to checkout $into"
            return 1
        fi
        if ! git pull --ff-only origin "$into" >/dev/null 2>&1; then
            log "${YELLOW}⚠${NC} Could not fast-forward $into from origin (continuing)"
        fi
        if ! git merge --no-edit "$from" >/dev/null 2>&1; then
            log "${RED}✗${NC} Merge $from -> $into failed (likely conflicts)"
            git merge --abort >/dev/null 2>&1 || true
            return 1
        fi
        if ! git push origin "$into" >/dev/null 2>&1; then
            log "${RED}✗${NC} Failed to push $into — resetting local $into to origin to avoid drift"
            # Without this, local $into is ahead of origin with an unpushed
            # merge commit; the next sync attempt sees it as already-merged
            # and silently does nothing, leaving origin permanently behind.
            git reset --hard "origin/$into" >/dev/null 2>&1 || true
            return 1
        fi
        log "${GREEN}✓${NC} Synced to $into"
        return 0
    }

    local sync_warnings=()
    sync_branch "$PRODUCTION_BRANCH" "$STAGING_BRANCH" || sync_warnings+=("$PRODUCTION_BRANCH->$STAGING_BRANCH")
    sync_branch "$STAGING_BRANCH"    "$DEV_BRANCH"     || sync_warnings+=("$STAGING_BRANCH->$DEV_BRANCH")

    # Return to production regardless. Abort any in-progress merge first
    # (sync_branch's failure path already resets, but defend against the case
    # where the merge step was interrupted by signal between merge and reset).
    git merge --abort >/dev/null 2>&1 || true
    git checkout "$PRODUCTION_BRANCH" >/dev/null 2>&1 || \
        log "${YELLOW}⚠${NC} Failed to return to $PRODUCTION_BRANCH — check working tree state"

    if [[ ${#sync_warnings[@]} -gt 0 ]]; then
        log "${YELLOW}⚠${NC} Branch sync-back had issues: ${sync_warnings[*]} — production deploy itself succeeded; resolve manually"
    fi

    if [[ "$SECTION" == "tag" ]]; then
        local json=$(cat <<EOF
{
  "status": "success",
  "next_action": "display_summary",
  "section": "tag",
  "release_tag": "$RELEASE_TAG",
  "version": "$VERSION",
  "synced_to": ["$STAGING_BRANCH", "$DEV_BRANCH"],
  "timestamp": "$(date -Iseconds)"
}
EOF
)
        log_json "$json"
        exit 0
    fi

    log "${GREEN}✓${NC} Tag and sync complete"
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
            --tag) SECTION="tag"; shift ;;
            --full) SECTION="full"; shift ;;
            *)
                exit_with_json "error" "Unknown argument: $1" \
                    "Valid flags: --json|--toon|--raw, --validate|--risk-analysis|--merge|--deploy|--tag|--full"
                ;;
        esac
    done

    # Load configuration
    if [[ ! -f "PROJECT.yaml" ]]; then
        exit_with_json "error" "PROJECT.yaml not found"
    fi

    if ! source "${SCRIPT_DIR}/lib/deployment-config.sh" 2>&1; then
        exit_with_json "error" "Failed to load deployment configuration"
    fi

    # Execute sections
    case "$SECTION" in
        validate)
            section_validate
            ;;
        risk-analysis)
            section_validate
            section_risk_analysis
            ;;
        merge)
            section_validate
            section_merge
            ;;
        deploy)
            section_deploy
            ;;
        tag)
            section_tag
            ;;
        full)
            section_validate
            section_risk_analysis
            section_merge
            section_deploy
            section_tag

            local json=$(cat <<EOF
{
  "status": "success",
  "next_action": "display_summary",
  "deployment": "production",
  "staging_branch": "$STAGING_BRANCH",
  "production_branch": "$PRODUCTION_BRANCH",
  "version": "$VERSION",
  "merge_commit": "$MERGE_COMMIT",
  "release_tag": "$RELEASE_TAG",
  "risk_score": $RISK_SCORE,
  "risk_status": "$RISK_STATUS",
  "pipeline_status": "$PIPELINE_STATUS",
  "health_status": "$HEALTH_STATUS",
  "version_status": "$VERSION_STATUS",
  "production_url": "${PRODUCTION_URL}",
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

main "$@"
