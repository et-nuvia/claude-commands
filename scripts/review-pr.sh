#!/usr/bin/env bash
set -euo pipefail

# review-pr.sh - AI-powered code review for GitHub/GitLab PRs/MRs
#
# STANDARD SCRIPT PATTERN: Section flags with --json/--raw output modes
#
# Usage:
#   ~/.claude/scripts/review-pr.sh [--json|--raw] [--full|--section] [--pr NUMBER]
#
# Output Modes:
#   --json: Structured JSON output for LLM (default)
#   --raw:  Verbose debugging output when LLM needs more details
#
# Section Flags (run specific section only):
#   --list:         List open PRs/MRs
#   --fetch:        Fetch PR/MR data (requires --pr)
#   --security:     Run security scans only (requires --pr)
#   --analyze:      Return data for LLM analysis (requires --pr)
#   --full:         List + fetch + security + return data for analysis
#
# Options:
#   --pr NUMBER:    PR/MR number to review
#
# Workflow:
#   1. LLM calls: script.sh --json --full
#   2. If no --pr: Returns list of open PRs for user to choose
#   3. LLM calls: script.sh --json --full --pr NUMBER
#   4. Script returns JSON with PR data, commits, files, security scans
#   5. LLM analyzes and generates review document
#
# Features:
#   - Platform detection (GitHub/GitLab)
#   - Security scanning (Trivy, Semgrep, gitleaks)
#   - Comprehensive data collection for LLM analysis
#   - --raw mode for debugging

# Script directory (needed for sourcing library)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source shared libraries
source "${SCRIPT_DIR}/lib/yaml.sh"
source "${SCRIPT_DIR}/lib/output-framework.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/load-profile.sh"

# Global variables
OUTPUT_MODE="json"
SECTION="full"
PLATFORM=""
PR_NUMBER=""
ORIGINAL_BRANCH=""
PR_BRANCH=""
BASE_BRANCH=""

# PR metadata
PR_TITLE=""
PR_AUTHOR=""
PR_BODY=""
PR_CREATED=""
FILES_CHANGED=0
LINES_ADDED=0
LINES_REMOVED=0
COMMIT_COUNT=0

# Cached raw fetch data — populated by section_fetch, reused by section_analyze
PR_RAW_DATA=""
PR_DIFF=""
PR_COMMITS_JSON="[]"
PR_FILES_JSON="[]"

# Security scan results
TRIVY_VULNS_CRITICAL=0
TRIVY_VULNS_HIGH=0
TRIVY_VULNS_MEDIUM=0
TRIVY_SECRETS=0
SEMGREP_ISSUES=0
GITLEAKS_SECRETS=0
MANUAL_SECRETS=0

# Set once section_security finishes so section_analyze never re-runs the
# scans just because a clean PR left all vuln counters at zero.
SCANS_DONE="false"

# Sidecar scan/diff files. Named by PR number rather than $$ so they survive
# this run for the caller (e.g. /review-pr subagents) to Read after the script
# exits. cleanup() intentionally does NOT remove them.
DIFF_FILE=""

# Sidecar scan files — resolved by PR number in resolve_sidecar_paths() once
# the PR is known, so a later run for the same PR reuses the same names and the
# caller can find them. Empty until then.
TRIVY_RESULTS=""
TRIVY_SECRETS_FILE=""
SEMGREP_RESULTS=""
GITLEAKS_RESULTS=""

# Name every sidecar after the PR being reviewed. Called from section_fetch and
# section_security, both of which run after PR_NUMBER is resolved.
resolve_sidecar_paths() {
    local key="${PR_NUMBER:-unknown}"
    TRIVY_RESULTS="/tmp/review-pr-trivy-${key}.json"
    TRIVY_SECRETS_FILE="/tmp/review-pr-trivy-secrets-${key}.json"
    SEMGREP_RESULTS="/tmp/review-pr-semgrep-${key}.json"
    GITLEAKS_RESULTS="/tmp/review-pr-gitleaks-${key}.json"
    DIFF_FILE="/tmp/review-pr-diff-${key}.txt"
}

#------------------------------------------------------------------------------
# Cleanup
#------------------------------------------------------------------------------

cleanup() {
    # Sidecar scan/diff files are intentionally NOT removed here — they are
    # named by PR number and read by the caller after this script exits.

    # Return to original branch if we checked out PR branch
    if [[ -n "$ORIGINAL_BRANCH" ]] && [[ -n "$PR_BRANCH" ]]; then
        if git rev-parse --verify "$ORIGINAL_BRANCH" >/dev/null 2>&1; then
            git checkout "$ORIGINAL_BRANCH" >/dev/null 2>&1 || true
        fi
    fi
}

trap cleanup EXIT

#------------------------------------------------------------------------------
# Helper Functions
#------------------------------------------------------------------------------

#------------------------------------------------------------------------------
# Platform Detection
#------------------------------------------------------------------------------

detect_platform() {
    log "${BLUE}Detecting Platform${NC}"

    # Try PROJECT.yaml first
    if [[ -f "PROJECT.yaml" ]]; then
        PLATFORM=$(yaml_get '.git.platform' PROJECT.yaml)
    fi

    # Fall back to remote URL
    if [[ -z "$PLATFORM" ]] || [[ "$PLATFORM" == "null" ]]; then
        local remote_url
        remote_url=$(git remote get-url origin 2>/dev/null || echo "")

        if [[ "$remote_url" =~ github\.com ]]; then
            PLATFORM="github"
        elif [[ "$remote_url" =~ gitlab ]]; then
            PLATFORM="gitlab"
        else
            exit_with_json "error" "Could not detect platform" "Add git.platform to PROJECT.yaml"
        fi
    fi

    log "${GREEN}✓${NC} Platform: $PLATFORM"
}

#------------------------------------------------------------------------------
# Section Functions
#------------------------------------------------------------------------------

# Section 1: List open PRs/MRs
section_list() {
    log "${BLUE}Listing Open PRs/MRs${NC}"

    detect_platform

    local prs_json=""

    if [[ "$PLATFORM" == "github" ]]; then
        # Check gh auth
        if ! gh auth status >/dev/null 2>&1; then
            exit_with_json "error" "GitHub CLI not authenticated" "Run: gh auth login"
        fi

        prs_json=$(gh pr list --json number,title,author,headRefName,baseRefName,isDraft 2>&1 || echo "[]")
    else
        # GitLab
        if [[ ! -f ~/.gitlab-token ]]; then
            exit_with_json "error" "GitLab token not found" "Create ~/.gitlab-token"
        fi

        local project_id
        if [[ -f "PROJECT.yaml" ]]; then
            project_id=$(yaml_get '.git.repo' PROJECT.yaml)
        fi

        if [[ -z "$project_id" ]] || [[ "$project_id" == "null" ]]; then
            exit_with_json "error" "GitLab project not configured" "Add git.repo to PROJECT.yaml"
        fi

        local token
        token=$(cat ~/.gitlab-token)
        local instance
        instance=$(yaml_get_default '.git.instance' "$(profile_env_get .git.instance)" PROJECT.yaml)

        prs_json=$(curl -s -H "PRIVATE-TOKEN: $token" \
            "https://$instance/api/v4/projects/$(echo "$project_id" | jq -sRr @uri)/merge_requests?state=opened" \
            | jq '[.[] | {number: .iid, title: .title, author: .author.username, headRefName: .source_branch, baseRefName: .target_branch, isDraft: .draft}]')
    fi

    if [[ "$SECTION" == "list" ]]; then
        local json=$(cat <<EOF
{
  "status": "success",
  "next_action": "choose_pr",
  "section": "list",
  "platform": "$PLATFORM",
  "prs": $prs_json,
  "timestamp": "$(date -Iseconds)"
}
EOF
)
        log_json "$json"
        exit 0
    fi

    log "${GREEN}✓${NC} Found $(echo "$prs_json" | jq 'length') open PRs/MRs"
}

# Section 2: Fetch PR/MR data
section_fetch() {
    log "${BLUE}Fetching PR/MR Data${NC}"

    resolve_sidecar_paths

    if [[ -z "$PR_NUMBER" ]]; then
        exit_with_json "error" "PR number required" "Use --pr NUMBER"
    fi

    detect_platform

    if [[ "$PLATFORM" == "github" ]]; then
        PR_RAW_DATA=$(gh pr view "$PR_NUMBER" --json number,title,author,body,files,commits,additions,deletions,createdAt,headRefName,baseRefName 2>&1)
        PR_DIFF=$(gh pr diff "$PR_NUMBER" | head -c 100000 || true)
        PR_COMMITS_JSON=$(echo "$PR_RAW_DATA" | jq '.commits')
        PR_FILES_JSON=$(echo "$PR_RAW_DATA" | jq '.files')
    else
        # GitLab
        local token
        token=$(cat ~/.gitlab-token)
        local instance project_id
        instance=$(yaml_get_default '.git.instance' "$(profile_env_get .git.instance)" PROJECT.yaml)
        project_id=$(yaml_get '.git.repo' PROJECT.yaml)

        PR_RAW_DATA=$(curl -s -H "PRIVATE-TOKEN: $token" \
            "https://$instance/api/v4/projects/$(echo "$project_id" | jq -sRr @uri)/merge_requests/$PR_NUMBER")

        local changes_data
        changes_data=$(curl -s -H "PRIVATE-TOKEN: $token" \
            "https://$instance/api/v4/projects/$(echo "$project_id" | jq -sRr @uri)/merge_requests/$PR_NUMBER/changes")

        PR_DIFF=$(echo "$changes_data" | jq -r '.changes[] | .diff' | head -c 100000 || true)
        PR_FILES_JSON=$(echo "$changes_data" | jq '.changes')

        PR_COMMITS_JSON=$(curl -s -H "PRIVATE-TOKEN: $token" \
            "https://$instance/api/v4/projects/$(echo "$project_id" | jq -sRr @uri)/merge_requests/$PR_NUMBER/commits")
    fi

    # Extract metadata from cached data
    if [[ "$PLATFORM" == "github" ]]; then
        PR_TITLE=$(echo "$PR_RAW_DATA" | jq -r '.title')
        PR_AUTHOR=$(echo "$PR_RAW_DATA" | jq -r '.author.login')
        PR_BODY=$(echo "$PR_RAW_DATA" | jq -r '.body // ""')
        PR_CREATED=$(echo "$PR_RAW_DATA" | jq -r '.createdAt')
        PR_BRANCH=$(echo "$PR_RAW_DATA" | jq -r '.headRefName')
        BASE_BRANCH=$(echo "$PR_RAW_DATA" | jq -r '.baseRefName')
        FILES_CHANGED=$(echo "$PR_RAW_DATA" | jq -r '.files | length')
        LINES_ADDED=$(echo "$PR_RAW_DATA" | jq -r '.additions')
        LINES_REMOVED=$(echo "$PR_RAW_DATA" | jq -r '.deletions')
        COMMIT_COUNT=$(echo "$PR_RAW_DATA" | jq -r '.commits | length')
    else
        PR_TITLE=$(echo "$PR_RAW_DATA" | jq -r '.title')
        PR_AUTHOR=$(echo "$PR_RAW_DATA" | jq -r '.author.username')
        PR_BODY=$(echo "$PR_RAW_DATA" | jq -r '.description // ""')
        PR_CREATED=$(echo "$PR_RAW_DATA" | jq -r '.created_at')
        PR_BRANCH=$(echo "$PR_RAW_DATA" | jq -r '.source_branch')
        BASE_BRANCH=$(echo "$PR_RAW_DATA" | jq -r '.target_branch')
        FILES_CHANGED=$(echo "$PR_FILES_JSON" | jq 'length')
        LINES_ADDED=0
        LINES_REMOVED=0
        COMMIT_COUNT=$(echo "$PR_RAW_DATA" | jq -r '.user_notes_count // 0')
    fi

    if [[ "$SECTION" == "fetch" ]]; then
        local json=$(cat <<EOF
{
  "status": "success",
  "next_action": "display_summary",
  "section": "fetch",
  "platform": "$PLATFORM",
  "pr_number": "$PR_NUMBER",
  "title": $(echo "$PR_TITLE" | jq -Rs .),
  "author": "$PR_AUTHOR",
  "body": $(echo "$PR_BODY" | jq -Rs .),
  "created": "$PR_CREATED",
  "pr_branch": "$PR_BRANCH",
  "base_branch": "$BASE_BRANCH",
  "files_changed": $FILES_CHANGED,
  "lines_added": $LINES_ADDED,
  "lines_removed": $LINES_REMOVED,
  "commit_count": $COMMIT_COUNT,
  "diff_size": ${#pr_diff},
  "timestamp": "$(date -Iseconds)"
}
EOF
)
        log_json "$json"
        exit 0
    fi

    log "${GREEN}✓${NC} Fetched PR #$PR_NUMBER: $PR_TITLE"
}

# Section 3: Security scans
section_security() {
    log "${BLUE}Running Security Scans${NC}"

    resolve_sidecar_paths

    if [[ -z "$PR_NUMBER" ]] || [[ -z "$PR_BRANCH" ]]; then
        # Fetch first if not already done
        section_fetch
    fi

    # Save original branch
    ORIGINAL_BRANCH=$(git branch --show-current)

    # Checkout PR branch
    log "${CYAN}Checking out PR branch: $PR_BRANCH${NC}"
    if [[ "$PLATFORM" == "github" ]]; then
        gh pr checkout "$PR_NUMBER" >/dev/null 2>&1 || exit_with_json "error" "Failed to checkout PR"
    else
        git fetch origin "$PR_BRANCH" >/dev/null 2>&1
        git checkout "$PR_BRANCH" >/dev/null 2>&1 || exit_with_json "error" "Failed to checkout branch"
    fi

    # Run all scanners in parallel to avoid sequential wait
    log "${CYAN}Running security scans in parallel${NC}"

    local trivy_pid="" trivy_secrets_pid="" semgrep_pid="" gitleaks_pid=""

    if command -v trivy >/dev/null 2>&1; then
        trivy fs . --severity CRITICAL,HIGH,MEDIUM --format json -o "$TRIVY_RESULTS" >/dev/null 2>&1 &
        trivy_pid=$!
        trivy fs . --scanners secret --format json -o "$TRIVY_SECRETS_FILE" >/dev/null 2>&1 &
        trivy_secrets_pid=$!
    fi

    if command -v semgrep >/dev/null 2>&1; then
        # --cache-dir avoids re-downloading rules on every run
        semgrep --config=auto --json --output="$SEMGREP_RESULTS" \
            --cache-dir "${HOME}/.cache/semgrep" . >/dev/null 2>&1 &
        semgrep_pid=$!
    fi

    if command -v gitleaks >/dev/null 2>&1; then
        gitleaks detect --source . --report-format json --report-path "$GITLEAKS_RESULTS" >/dev/null 2>&1 &
        gitleaks_pid=$!
    fi

    # Manual grep runs fast — do it while scanners are running
    log "${CYAN}Running manual secret detection${NC}"
    MANUAL_SECRETS=$(git diff "origin/$BASE_BRANCH...HEAD" 2>/dev/null | \
        { grep -iE "(password|secret|api[_-]?key|token|private[_-]?key|Bearer |Authorization:)" || true; } | \
        { grep -v "test\|example\|placeholder" || true; } | \
        wc -l | tr -d ' ')

    # Wait for all background scanners
    [[ -n "$trivy_pid" ]]         && wait "$trivy_pid"         || true
    [[ -n "$trivy_secrets_pid" ]] && wait "$trivy_secrets_pid" || true
    [[ -n "$semgrep_pid" ]]       && wait "$semgrep_pid"       || true
    [[ -n "$gitleaks_pid" ]]      && wait "$gitleaks_pid"      || true

    # Parse results
    if [[ -f "$TRIVY_RESULTS" ]]; then
        TRIVY_VULNS_CRITICAL=$(jq '[.Results[]?.Vulnerabilities[]? | select(.Severity=="CRITICAL")] | length' "$TRIVY_RESULTS" 2>/dev/null || echo "0")
        TRIVY_VULNS_HIGH=$(jq '[.Results[]?.Vulnerabilities[]? | select(.Severity=="HIGH")] | length' "$TRIVY_RESULTS" 2>/dev/null || echo "0")
        TRIVY_VULNS_MEDIUM=$(jq '[.Results[]?.Vulnerabilities[]? | select(.Severity=="MEDIUM")] | length' "$TRIVY_RESULTS" 2>/dev/null || echo "0")
    fi
    if [[ -f "$TRIVY_SECRETS_FILE" ]]; then
        TRIVY_SECRETS=$(jq '[.Results[]?.Secrets[]?] | length' "$TRIVY_SECRETS_FILE" 2>/dev/null || echo "0")
    fi
    if [[ -f "$SEMGREP_RESULTS" ]]; then
        SEMGREP_ISSUES=$(jq '.results | length' "$SEMGREP_RESULTS" 2>/dev/null || echo "0")
    fi
    if [[ -f "$GITLEAKS_RESULTS" ]]; then
        GITLEAKS_SECRETS=$(jq 'length' "$GITLEAKS_RESULTS" 2>/dev/null || echo "0")
    fi

    # Return to original branch
    git checkout "$ORIGINAL_BRANCH" >/dev/null 2>&1 || true

    if [[ "$SECTION" == "security" ]]; then
        local json=$(cat <<EOF
{
  "status": "success",
  "next_action": "display_summary",
  "section": "security",
  "pr_number": "$PR_NUMBER",
  "trivy": {
    "critical": $TRIVY_VULNS_CRITICAL,
    "high": $TRIVY_VULNS_HIGH,
    "medium": $TRIVY_VULNS_MEDIUM,
    "secrets": $TRIVY_SECRETS
  },
  "semgrep": {
    "issues": $SEMGREP_ISSUES
  },
  "gitleaks": {
    "secrets": $GITLEAKS_SECRETS
  },
  "manual": {
    "secrets": $MANUAL_SECRETS
  },
  "total_secrets": $((TRIVY_SECRETS + GITLEAKS_SECRETS + MANUAL_SECRETS)),
  "critical_block": $(if [[ $TRIVY_VULNS_CRITICAL -gt 0 ]] || [[ $((TRIVY_SECRETS + GITLEAKS_SECRETS + MANUAL_SECRETS)) -gt 0 ]]; then echo "true"; else echo "false"; fi),
  "timestamp": "$(date -Iseconds)"
}
EOF
)
        log_json "$json"
        exit 0
    fi

    SCANS_DONE="true"
    log "${GREEN}✓${NC} Security scans complete"
}

# Section 4: Return analysis data
section_analyze() {
    log "${BLUE}Preparing Data for LLM Analysis${NC}"

    # Make sure we have all data
    if [[ -z "$PR_TITLE" ]]; then
        section_fetch
    fi

    # Security scans if not already done. Keyed off an explicit flag, not off
    # the vuln counters — a genuinely clean PR leaves every counter at zero,
    # and testing the counters re-ran the whole scan suite on every call.
    if [[ "$SCANS_DONE" != "true" ]]; then
        section_security
    fi

    # Use cached fetch data — section_fetch already populated these globals
    # Read security scan files
    local trivy_data semgrep_data gitleaks_data
    trivy_data=$(cat "$TRIVY_RESULTS" 2>/dev/null || echo '{}')
    semgrep_data=$(cat "$SEMGREP_RESULTS" 2>/dev/null || echo '{}')
    gitleaks_data=$(cat "$GITLEAKS_RESULTS" 2>/dev/null || echo '[]')

    # Build comprehensive JSON response
    local json=$(cat <<EOF
{
  "status": "ready_for_analysis",
  "next_action": "analyze_pr",
  "section": "analyze",
  "platform": "$PLATFORM",
  "pr": {
    "number": "$PR_NUMBER",
    "title": $(echo "$PR_TITLE" | jq -Rs .),
    "author": "$PR_AUTHOR",
    "body": $(echo "$PR_BODY" | jq -Rs .),
    "created": "$PR_CREATED",
    "pr_branch": "$PR_BRANCH",
    "base_branch": "$BASE_BRANCH",
    "files_changed": $FILES_CHANGED,
    "lines_added": $LINES_ADDED,
    "lines_removed": $LINES_REMOVED,
    "commit_count": $COMMIT_COUNT
  },
  "commits": $PR_COMMITS_JSON,
  "files": $PR_FILES_JSON,
  "diff": $(echo "$PR_DIFF" | jq -Rs . | head -c 50000 || true),
  "security": {
    "trivy": {
      "critical": $TRIVY_VULNS_CRITICAL,
      "high": $TRIVY_VULNS_HIGH,
      "medium": $TRIVY_VULNS_MEDIUM,
      "secrets": $TRIVY_SECRETS,
      "details": $trivy_data
    },
    "semgrep": {
      "issues": $SEMGREP_ISSUES,
      "details": $semgrep_data
    },
    "gitleaks": {
      "secrets": $GITLEAKS_SECRETS,
      "details": $gitleaks_data
    },
    "manual_secrets": $MANUAL_SECRETS,
    "total_secrets": $((TRIVY_SECRETS + GITLEAKS_SECRETS + MANUAL_SECRETS)),
    "critical_block": $(if [[ $TRIVY_VULNS_CRITICAL -gt 0 ]] || [[ $((TRIVY_SECRETS + GITLEAKS_SECRETS + MANUAL_SECRETS)) -gt 0 ]]; then echo "true"; else echo "false"; fi)
  },
  "timestamp": "$(date -Iseconds)"
}
EOF
)

    log_json "$json"
    exit 0
}

#------------------------------------------------------------------------------
# Main
#------------------------------------------------------------------------------

main() {
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json)
                OUTPUT_MODE="json"
                shift
                ;;
            --raw)
                OUTPUT_MODE="raw"
                shift
                ;;
            --list)
                SECTION="list"
                shift
                ;;
            --fetch)
                SECTION="fetch"
                shift
                ;;
            --security)
                SECTION="security"
                shift
                ;;
            --analyze)
                SECTION="analyze"
                shift
                ;;
            --full)
                SECTION="full"
                shift
                ;;
            --pr)
                PR_NUMBER="$2"
                shift 2
                ;;
            *)
                exit_with_json "error" "Unknown argument: $1"
                ;;
        esac
    done

    # Execute based on section
    case "$SECTION" in
        list)
            section_list
            ;;
        fetch)
            section_fetch
            ;;
        security)
            section_security
            ;;
        analyze)
            section_analyze
            ;;
        full)
            if [[ -z "$PR_NUMBER" ]]; then
                # List PRs for user to choose
                section_list
                exit_with_json "success" "List PRs - user needs to choose" "Re-run with --pr NUMBER"
            else
                # Full workflow: fetch + security + analyze
                section_fetch
                section_security
                section_analyze
            fi
            ;;
        *)
            exit_with_json "error" "Invalid section: $SECTION"
            ;;
    esac
}

main "$@"
