#!/usr/bin/env bash
set -euo pipefail

_MERGE_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_MERGE_SCRIPT_DIR}/lib/git-utils.sh"

# Restore original branch and abort merge on unhandled failure
_ORIG_BRANCH=""
_cleanup_on_error() {
    # Abort any in-progress merge and reset dirty state
    git merge --abort >/dev/null 2>&1 || true
    git reset --merge >/dev/null 2>&1 || true
    git reset --hard HEAD >/dev/null 2>&1 || true
    # Return to the original branch if we switched away
    if [[ -n "$_ORIG_BRANCH" ]]; then
        local current
        current=$(git branch --show-current 2>/dev/null || echo "")
        if [[ "$current" != "$_ORIG_BRANCH" ]]; then
            git checkout "$_ORIG_BRANCH" >/dev/null 2>&1 || true
        fi
    fi
}
trap '_cleanup_on_error' ERR

# STANDARD SCRIPT PATTERN: Git merge operations (regular or squash)
#
# Usage:
#   ~/.claude/scripts/git-merge.sh --source <branch> --target <branch> [options] [--json|--raw] [--full|--section]
#
# Options:
#   --squash              Use squash merge instead of regular merge
#   --message "msg"       Custom merge commit message
#
# Output Modes:
#   --json    Structured JSON output for LLM (default)
#   --raw     Verbose debugging output when LLM needs more details
#
# Section Flags (run specific section only):
#   --validate    Validate branches and git state
#   --analyze     Analyze commits and generate merge message
#   --merge       Execute the merge operation (intervention point for conflicts)
#   --cleanup     Push merged branch and cleanup
#   --full        Run all sections end-to-end (default)
#
# Workflow:
#   1. LLM calls: git-merge.sh main feature --json --full
#   2. If conflicts: Returns JSON with conflict details
#   3. LLM resolves conflicts using Read/Edit tools
#   4. LLM resumes: git-merge.sh main feature --json --cleanup
#
# Exit codes:
#   0 = Success
#   1 = Conflicts or intervention needed
#   2 = Error

# Script directory (needed for sourcing library)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Custom next_action mapping (must be defined before sourcing output-framework)
map_status_to_action() {
    case "$1" in
        success)         echo "display_summary" ;;
        conflict)        echo "resolve_conflicts" ;;
        needs_decision)  echo "ask_rebase_strategy" ;;
        *)               echo "fix_error" ;;
    esac
}

# Source shared library
source "${SCRIPT_DIR}/lib/output-framework.sh"

# Global variables
OUTPUT_MODE="json"
SECTION="full"
SOURCE_BRANCH=""
TARGET_BRANCH=""
SQUASH=false
CUSTOM_MESSAGE=""
ALLOW_DIVERGED=false

# State variables (populated during execution)
MERGE_TYPE="regular"
COMMITS_COUNT=0
MERGE_MESSAGE=""
VERSION_TYPE=""

#------------------------------------------------------------------------------
# Helper Functions
#------------------------------------------------------------------------------

# Check if target has commits ahead of source - USE LOCAL BRANCHES
# Skip for squash merges (squash handles divergence naturally) and for --allow-diverged
# (deploy workflows where cherry-picks / release-note syncs on the target are expected)
# Exits with needs_decision JSON if a blocking divergence is found.
check_target_divergence() {
    local target_ahead=$(git rev-list --count "$SOURCE_BRANCH..$TARGET_BRANCH" 2>/dev/null || echo "0")
    if [[ "$target_ahead" -gt 0 ]] && [[ "$SQUASH" != "true" ]] && [[ "$ALLOW_DIVERGED" != "true" ]]; then
        log "${YELLOW}⚠ Target branch has $target_ahead commits not in source${NC}"
        exit_with_json "needs_decision" \
            "Target branch ($TARGET_BRANCH) has $target_ahead commit(s) not in source ($SOURCE_BRANCH)" \
            "" \
            "\"target_ahead_count\": $target_ahead, \"source_branch\": \"$SOURCE_BRANCH\", \"target_branch\": \"$TARGET_BRANCH\", \"source_ahead_count\": $COMMITS_COUNT, \"options\": [\"rebase\", \"merge_anyway\", \"cancel\"]"
    elif [[ "$target_ahead" -gt 0 ]] && [[ "$ALLOW_DIVERGED" == "true" ]]; then
        log "${YELLOW}⚠ Target branch has $target_ahead commits not in source (--allow-diverged set, git merge will reconcile via merge-base)${NC}"
    elif [[ "$target_ahead" -gt 0 ]]; then
        log "${YELLOW}⚠ Target branch has $target_ahead commits not in source (squash merge handles this)${NC}"
    fi
}

#------------------------------------------------------------------------------
# Section 1: Validate
#------------------------------------------------------------------------------

section_validate() {
    log "${BLUE}Validating branches and git state${NC}"

    # Save original branch for cleanup-on-error
    _ORIG_BRANCH=$(git branch --show-current 2>/dev/null || echo "")

    # Check if we're in a git repository
    if ! git rev-parse --git-dir >/dev/null 2>&1; then
        exit_with_json "error" "Not in a git repository" "Run this command from within a git repository"
    fi

    # Check for uncommitted changes (ignore untracked files)
    if [[ -n "$(git diff --name-only 2>/dev/null)$(git diff --cached --name-only 2>/dev/null)" ]]; then
        local changes=$(git status --porcelain -uno)
        exit_with_json "error" "Working directory has uncommitted changes" "$changes" \
            "\"next_steps\": [\"Commit or stash changes before merging\", \"git stash\", \"git add . && git commit -m 'message'\"]"
    fi

    # Fetch latest branches
    log "Fetching latest branches..."
    if ! git fetch origin >/dev/null 2>&1; then
        exit_with_json "error" "Failed to fetch from remote" "Check network connection and remote access"
    fi

    # Verify source branch exists (check LOCAL first, then remote)
    if ! git rev-parse --verify "$SOURCE_BRANCH" >/dev/null 2>&1; then
        # Source doesn't exist locally, check remote
        if ! git rev-parse --verify "origin/$SOURCE_BRANCH" >/dev/null 2>&1; then
            local available_branches=$(git branch -a | grep -v HEAD | sed 's/remotes\/origin\///' | head -10)
            exit_with_json "error" "Source branch not found: $SOURCE_BRANCH" "$available_branches" \
                "\"available_branches\": $(echo "$available_branches" | jq -R . | jq -s .)"
        else
            # Branch exists on remote but not local - check it out
            log "${YELLOW}Source branch exists on remote, checking out locally${NC}"
            git checkout -b "$SOURCE_BRANCH" "origin/$SOURCE_BRANCH" >/dev/null 2>&1
        fi
    fi

    # Verify target branch exists (check LOCAL first, then remote)
    if ! git rev-parse --verify "$TARGET_BRANCH" >/dev/null 2>&1; then
        # Target doesn't exist locally, check remote
        if ! git rev-parse --verify "origin/$TARGET_BRANCH" >/dev/null 2>&1; then
            local available_branches=$(git branch -a | grep -v HEAD | sed 's/remotes\/origin\///' | head -10)
            exit_with_json "error" "Target branch not found: $TARGET_BRANCH" "$available_branches" \
                "\"available_branches\": $(echo "$available_branches" | jq -R . | jq -s .)"
        else
            # Branch exists on remote but not local - check it out
            log "${YELLOW}Target branch exists on remote, checking out locally${NC}"
            git checkout -b "$TARGET_BRANCH" "origin/$TARGET_BRANCH" >/dev/null 2>&1
        fi
    fi

    # Check if source has commits ahead of target (USE LOCAL BRANCHES)
    COMMITS_COUNT=$(git rev-list --count "$TARGET_BRANCH..$SOURCE_BRANCH" 2>/dev/null || echo "0")
    if [[ "$COMMITS_COUNT" -eq 0 ]]; then
        exit_with_json "error" "No commits to merge" "Source branch ($SOURCE_BRANCH) has no commits ahead of target ($TARGET_BRANCH)"
    fi

    # Check if target has commits ahead of source - USE LOCAL BRANCHES
    check_target_divergence

    log "${GREEN}✓${NC} Validation complete"

    if [[ "$SECTION" == "validate" ]]; then
        exit_with_json "success" "Validation complete" "" \
            "\"source_branch\": \"$SOURCE_BRANCH\", \"target_branch\": \"$TARGET_BRANCH\", \"commits_count\": $COMMITS_COUNT, \"merge_type\": \"$MERGE_TYPE\""
    fi
}

#------------------------------------------------------------------------------
# Section 2: Analyze
#------------------------------------------------------------------------------

section_analyze() {
    log "${BLUE}Analyzing commits and changes${NC}"

    # Checkout target branch
    git checkout "$TARGET_BRANCH" >/dev/null 2>&1
    # Only pull if branch exists on remote
    if git ls-remote --heads origin "$TARGET_BRANCH" 2>/dev/null | grep -q .; then
        git pull origin "$TARGET_BRANCH" >/dev/null 2>&1
    fi

    # Get commits being merged (USE LOCAL BRANCHES)
    local commits=$(git log --format="%h %s" "$TARGET_BRANCH..$SOURCE_BRANCH")
    local commits_detailed=$(git log --format="%h %s%n%b" "$TARGET_BRANCH..$SOURCE_BRANCH")

    # Get file change summary (USE LOCAL BRANCHES)
    local files_changed=$(git diff --stat "$TARGET_BRANCH..$SOURCE_BRANCH")
    local files_list=$(git diff --name-status "$TARGET_BRANCH..$SOURCE_BRANCH")

    # Determine semantic version type from commits
    VERSION_TYPE="patch"  # Default
    if echo "$commits_detailed" | grep -qiE '(BREAKING CHANGE|!)'; then
        VERSION_TYPE="major"
    elif echo "$commits" | grep -qiE '^[a-f0-9]+ feat[(:!]'; then
        VERSION_TYPE="minor"
    fi

    log "${CYAN}Commits to merge:${NC}"
    log "$commits"
    log ""
    log "${CYAN}Files changed:${NC}"
    log "$files_changed"

    # Generate merge message if not provided
    if [[ -z "$CUSTOM_MESSAGE" ]]; then
        if [[ "$SQUASH" == "true" ]]; then
            MERGE_MESSAGE="chore(deploy): squash $SOURCE_BRANCH to $TARGET_BRANCH"
        else
            MERGE_MESSAGE="chore(release): merge $SOURCE_BRANCH to $TARGET_BRANCH"
        fi
    else
        MERGE_MESSAGE="$CUSTOM_MESSAGE"
    fi

    log "${GREEN}✓${NC} Analysis complete"

    if [[ "$SECTION" == "analyze" ]]; then
        exit_with_json "success" "Analysis complete" "" \
            "\"commits_count\": $COMMITS_COUNT, \"version_type\": \"$VERSION_TYPE\", \"merge_message\": $(echo "$MERGE_MESSAGE" | jq -Rs .), \"commits\": $(echo "$commits" | jq -R . | jq -s .), \"files_changed\": $(echo "$files_list" | jq -R . | jq -s .)"
    fi
}

#------------------------------------------------------------------------------
# Section 3: Merge (LLM Intervention Point)
#------------------------------------------------------------------------------

section_merge() {
    log "${BLUE}Executing $MERGE_TYPE merge${NC}"
    log "  From: ${CYAN}$SOURCE_BRANCH${NC}"
    log "  To: ${CYAN}$TARGET_BRANCH${NC}"

    # Ensure on target branch
    git checkout "$TARGET_BRANCH" >/dev/null 2>&1
    # Only pull if branch exists on remote
    if git ls-remote --heads origin "$TARGET_BRANCH" 2>/dev/null | grep -q .; then
        git pull origin "$TARGET_BRANCH" >/dev/null 2>&1
    fi

    # Re-check divergence: the pull above may have advanced target since section_validate ran
    check_target_divergence

    # Prepare merge arguments
    local merge_args=()
    if [[ "$SQUASH" == "true" ]]; then
        merge_args+=("--squash")
    else
        # Force a real merge commit with the generated message (default merge
        # commits never contain $MERGE_MESSAGE, so set it explicitly here)
        merge_args+=("--no-ff" "-m" "$MERGE_MESSAGE")
    fi
    # CRITICAL: Merge from LOCAL branch, not origin (prevents orphaned commits)
    merge_args+=("$SOURCE_BRANCH")

    # Attempt merge
    if git merge "${merge_args[@]}" >/dev/null 2>&1; then
        # Merge succeeded - handle commit
        if [[ "$SQUASH" == "true" ]]; then
            # Squash merge needs manual commit — include Dev-SHA for traceability
            local source_sha=$(git rev-parse "$SOURCE_BRANCH")
            local full_message="${MERGE_MESSAGE}

Dev-SHA: ${source_sha}"
            if ! git commit -m "$full_message" >/dev/null 2>&1; then
                git merge --abort >/dev/null 2>&1 || true
                exit_with_json "error" "Failed to create merge commit" "Merge succeeded but commit failed"
            fi
        fi
        # Regular merges pass -m "$MERGE_MESSAGE" directly above, so no post-hoc
        # message fixup is needed here.

        # Verify package-lock.json sync after merge (root and 1 level deep)
        local lockfile_fixed=false
        if [[ -f "package.json" ]] && [[ -f "package-lock.json" ]]; then
            if ! npm ls --package-lock-only >/dev/null 2>&1; then
                log "${YELLOW}⚠️  package-lock.json out of sync — regenerating${NC}"
                npm install --package-lock-only >/dev/null 2>&1
                git add package-lock.json
                git commit --amend --no-edit >/dev/null 2>&1
                lockfile_fixed=true
            fi
        fi
        for subdir in */; do
            if [[ -f "${subdir}package.json" ]] && [[ -f "${subdir}package-lock.json" ]]; then
                if ! (cd "$subdir" && npm ls --package-lock-only >/dev/null 2>&1); then
                    log "${YELLOW}⚠️  ${subdir}package-lock.json out of sync — regenerating${NC}"
                    (cd "$subdir" && npm install --package-lock-only >/dev/null 2>&1)
                    git add "${subdir}package-lock.json"
                    git commit --amend --no-edit >/dev/null 2>&1
                    lockfile_fixed=true
                fi
            fi
        done

        local merge_hash=$(git rev-parse HEAD)
        log "${GREEN}✓${NC} Merge completed successfully"
        log "  Commit: ${CYAN}$merge_hash${NC}"

        if [[ "$SECTION" == "merge" ]]; then
            exit_with_json "success" "Merge completed successfully" "" \
                "\"merge_hash\": \"$merge_hash\", \"merge_type\": \"$MERGE_TYPE\", \"source_branch\": \"$SOURCE_BRANCH\", \"target_branch\": \"$TARGET_BRANCH\", \"merge_message\": $(echo "$MERGE_MESSAGE" | jq -Rs .), \"next_steps\": [\"Continue cleanup: git-merge.sh $SOURCE_BRANCH $TARGET_BRANCH --json --cleanup\"]"
        fi

    else
        # Merge conflicts detected
        log "${YELLOW}⚠ Merge conflict detected${NC}"

        local conflict_files=$(git diff --name-only --diff-filter=U 2>/dev/null || echo "")
        local conflict_count=$(echo "$conflict_files" | grep -c . || echo "0")

        # Files that can be auto-resolved without LLM intervention:
        # - Generated indexes: take target (ours), regenerate after merge
        # - docs/completed/: take source (theirs) — source branch has final state
        # - docs/release_notes/: take source (theirs) — release notes always flow
        #   forward (dev → staging → prod); the source branch is authoritative
        local auto_gen_patterns=("docs/DOCUMENT-INDEX.md" "docs/SEQUENCE-TRACKER.md")
        local has_real_conflicts=false
        local auto_resolved_count=0

        while IFS= read -r cfile; do
            [[ -z "$cfile" ]] && continue
            local resolved=false

            # Auto-generated index files: take target, regenerate later
            for pattern in "${auto_gen_patterns[@]}"; do
                if [[ "$cfile" == "$pattern" ]]; then
                    git checkout --ours "$cfile" >/dev/null 2>&1
                    git add "$cfile" >/dev/null 2>&1
                    log "${GREEN}✓${NC} Auto-resolved generated file: $cfile"
                    ((auto_resolved_count++)) || true
                    resolved=true
                    break
                fi
            done

            # Completed docs: take source branch version (has final/checked state)
            if [[ "$resolved" == "false" ]] && [[ "$cfile" == docs/completed/* ]]; then
                git checkout --theirs "$cfile" >/dev/null 2>&1
                git add "$cfile" >/dev/null 2>&1
                log "${GREEN}✓${NC} Auto-resolved completed doc (took source): $cfile"
                ((auto_resolved_count++)) || true
                resolved=true
            fi

            # Release notes: always take source (theirs). Release notes flow
            # forward dev → staging → prod; the source branch is authoritative,
            # so a conflict here is resolved in favor of source rather than
            # halting the deploy for manual intervention.
            if [[ "$resolved" == "false" ]] && [[ "$cfile" == docs/release_notes/* ]]; then
                # Source may have modified or deleted the file. Prefer the
                # source version; if source deleted it, honor the deletion.
                if git checkout --theirs "$cfile" >/dev/null 2>&1; then
                    git add "$cfile" >/dev/null 2>&1
                    log "${GREEN}✓${NC} Auto-resolved release note (took source): $cfile"
                else
                    git rm -f "$cfile" >/dev/null 2>&1 || true
                    log "${GREEN}✓${NC} Auto-resolved release note (source deleted): $cfile"
                fi
                ((auto_resolved_count++)) || true
                resolved=true
            fi

            if [[ "$resolved" == "false" ]]; then
                has_real_conflicts=true
            fi
        done <<< "$conflict_files"

        if [[ "$has_real_conflicts" == "false" ]]; then
            # All conflicts were auto-generated — complete the merge
            log "${GREEN}✓${NC} All $auto_resolved_count conflicts were in generated files — auto-resolved"

            if [[ "$SQUASH" == "true" ]]; then
                local source_sha=$(git rev-parse "$SOURCE_BRANCH")
                local full_message="${MERGE_MESSAGE}

Dev-SHA: ${source_sha}"
                if ! git commit -m "$full_message" >/dev/null 2>&1; then
                    git merge --abort >/dev/null 2>&1 || true
                    exit_with_json "error" "Failed to create merge commit after auto-resolve" "Auto-resolved generated files but commit failed"
                fi
            else
                git commit --no-edit >/dev/null 2>&1 || true
            fi

            # Regenerate auto-generated docs
            if [[ -x "${SCRIPT_DIR}/update-docs.sh" ]]; then
                log "${BLUE}ℹ${NC} Regenerating auto-generated docs..."
                "${SCRIPT_DIR}/update-docs.sh" >/dev/null 2>&1 || true
                if [[ -n "$(git diff --name-only 2>/dev/null)" ]]; then
                    git add docs/DOCUMENT-INDEX.md docs/SEQUENCE-TRACKER.md 2>/dev/null || true
                    git commit --amend --no-edit >/dev/null 2>&1 || true
                    log "${GREEN}✓${NC} Regenerated and amended docs"
                fi
            fi

            local merge_hash=$(git rev-parse HEAD)
            log "${GREEN}✓${NC} Merge completed successfully (with auto-resolved conflicts)"
            log "  Commit: ${CYAN}$merge_hash${NC}"

            if [[ "$SECTION" == "merge" ]]; then
                exit_with_json "success" "Merge completed successfully (auto-resolved $auto_resolved_count generated files)" "" \
                    "\"merge_hash\": \"$merge_hash\", \"merge_type\": \"$MERGE_TYPE\", \"source_branch\": \"$SOURCE_BRANCH\", \"target_branch\": \"$TARGET_BRANCH\", \"auto_resolved\": $auto_resolved_count, \"merge_message\": $(echo "$MERGE_MESSAGE" | jq -Rs .), \"next_steps\": [\"Continue cleanup: git-merge.sh $SOURCE_BRANCH $TARGET_BRANCH --json --cleanup\"]"
            fi
        else
            # Real conflicts remain — need LLM intervention
            # Re-collect only the unresolved conflict files
            local remaining_conflicts=$(git diff --name-only --diff-filter=U 2>/dev/null || echo "")
            local remaining_count=$(echo "$remaining_conflicts" | grep -c . || echo "0")

            log "${RED}❌ $remaining_count file(s) have real conflicts requiring intervention${NC}"
            if [[ $auto_resolved_count -gt 0 ]]; then
                log "${GREEN}✓${NC} Auto-resolved $auto_resolved_count generated file(s)"
            fi

            local conflict_details=""
            if [[ -n "$remaining_conflicts" ]]; then
                conflict_details=$(echo "$remaining_conflicts" | head -3 | while read -r file; do
                    echo "=== $file ==="
                    git diff "$file" 2>/dev/null | head -50
                done)
            fi

            # Abort the merge and restore original branch (LLM will re-run after resolving)
            git merge --abort >/dev/null 2>&1 || true
            if [[ -n "$_ORIG_BRANCH" ]]; then
                git checkout "$_ORIG_BRANCH" >/dev/null 2>&1 || true
            fi

            exit_with_json "conflict" "Merge conflicts detected - LLM intervention required" "$conflict_details" \
                "\"conflict_files\": $(echo "$remaining_conflicts" | jq -R . | jq -s .), \"conflict_count\": $remaining_count, \"auto_resolved\": $auto_resolved_count, \"next_steps\": [\"LLM should read each conflict file using Read tool\", \"Resolve conflicts using Edit tool\", \"Stage resolved files: git add <files>\", \"Continue merge: git-merge.sh $SOURCE_BRANCH $TARGET_BRANCH --json --cleanup\"]"
        fi
    fi
}

#------------------------------------------------------------------------------
# Section 4: Cleanup
#------------------------------------------------------------------------------

section_cleanup() {
    log "${BLUE}Cleaning up: push and delete source branch${NC}"

    # Check if we have a merge commit to push
    local merge_hash=$(git rev-parse HEAD 2>/dev/null || echo "")
    if [[ -z "$merge_hash" ]]; then
        exit_with_json "error" "No merge commit found" "Run --merge section first"
    fi

    # Push to remote
    log "Pushing to remote..."
    if ! git push origin "$TARGET_BRANCH" >/dev/null 2>&1; then
        exit_with_json "error" "Failed to push merged branch" "Merge created locally but push failed. Manual push required: git push origin $TARGET_BRANCH"
    fi

    log "${GREEN}✓${NC} Pushed to remote"

    # Delete local source branch (if exists, we're not on it, and it's not protected)
    local current_branch=$(git branch --show-current)
    if is_protected_branch "$SOURCE_BRANCH"; then
        log "${YELLOW}⚠${NC} Skipping deletion of protected branch: $SOURCE_BRANCH"
    elif [[ "$current_branch" != "$SOURCE_BRANCH" ]] && git show-ref --verify --quiet "refs/heads/$SOURCE_BRANCH"; then
        log "Deleting local branch: $SOURCE_BRANCH"
        git branch -d "$SOURCE_BRANCH" >/dev/null 2>&1 || git branch -D "$SOURCE_BRANCH" >/dev/null 2>&1 || true

        # Delete remote source branch
        if git show-ref --verify --quiet "refs/remotes/origin/$SOURCE_BRANCH"; then
            log "Deleting remote branch: origin/$SOURCE_BRANCH"
            git push origin --delete "$SOURCE_BRANCH" >/dev/null 2>&1 || true
        fi
    fi

    log "${GREEN}✓${NC} Cleanup complete"

    if [[ "$SECTION" == "cleanup" ]]; then
        exit_with_json "success" "Cleanup complete" "" \
            "\"merge_hash\": \"$merge_hash\", \"pushed\": true, \"source_branch_deleted\": true"
    fi
}

#------------------------------------------------------------------------------
# Main Execution
#------------------------------------------------------------------------------

main() {
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --json) OUTPUT_MODE="json"; shift ;;
            --toon) OUTPUT_MODE="json"; OUTPUT_FORMAT="toon"; shift ;;
            --raw) OUTPUT_MODE="raw"; shift ;;
            --validate) SECTION="validate"; shift ;;
            --analyze) SECTION="analyze"; shift ;;
            --merge) SECTION="merge"; shift ;;
            --cleanup) SECTION="cleanup"; shift ;;
            --full) SECTION="full"; shift ;;
            --squash) SQUASH=true; MERGE_TYPE="squash"; shift ;;
            --allow-diverged) ALLOW_DIVERGED=true; shift ;;
            --message)
                CUSTOM_MESSAGE="$2"
                shift 2
                ;;
            --source)
                SOURCE_BRANCH="$2"
                shift 2
                ;;
            --target)
                TARGET_BRANCH="$2"
                shift 2
                ;;
            *)
                exit_with_json "error" "Unknown option: $1" "Usage: git-merge.sh --source <branch> --target <branch> [--squash] [--allow-diverged] [--message \"msg\"] [--json|--raw] [--full|--section]"
                ;;
        esac
    done

    # Validate required arguments
    if [[ -z "$SOURCE_BRANCH" || -z "$TARGET_BRANCH" ]]; then
        exit_with_json "error" "Missing required arguments" "Usage: git-merge.sh --source <branch> --target <branch> [--squash] [--allow-diverged] [--message \"msg\"] [--json|--raw] [--full|--section]"
    fi

    # Execute sections based on flag
    case "$SECTION" in
        validate)
            section_validate
            ;;
        analyze)
            section_validate
            section_analyze
            ;;
        merge)
            section_validate
            section_analyze
            section_merge
            ;;
        cleanup)
            # Assume merge already done
            section_cleanup
            ;;
        full)
            section_validate
            section_analyze
            section_merge
            section_cleanup

            # Full success - return complete results
            local merge_hash=$(git rev-parse HEAD)
            exit_with_json "success" "Merge completed successfully" "" \
                "\"merge_type\": \"$MERGE_TYPE\", \"merge_hash\": \"$merge_hash\", \"source_branch\": \"$SOURCE_BRANCH\", \"target_branch\": \"$TARGET_BRANCH\", \"commits_merged\": $COMMITS_COUNT, \"version_type\": \"$VERSION_TYPE\", \"pushed\": true, \"source_branch_deleted\": true"
            ;;
    esac
}

# Run main function
main "$@"
