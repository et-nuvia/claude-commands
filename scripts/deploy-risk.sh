#!/usr/bin/env bash
set -euo pipefail

# deploy-risk.sh - Comprehensive deployment risk analysis with historical context
#
# STANDARD SCRIPT PATTERN: Section flags with --json/--raw output modes
#
# Usage:
#   ~/.claude/scripts/deploy-risk.sh [--json|--raw] [--full|--section]
#
# Output Modes:
#   --json: Structured output for LLM, default (TOON when the caller is an AI agent, JSON otherwise)
#   --raw:  Verbose debugging output when LLM needs more details
#
# Section Flags (run specific section only):
#   --gather:    Gather deployment context only
#   --analyze:   Analyze risks only (requires context)
#   --score:     Calculate risk score only
#   --document:  Generate risk document only
#   --full:      Run all sections end-to-end (default)
#
# Workflow:
#   1. LLM calls: script.sh --json --full
#   2. If blocked: Returns JSON with risk details
#   3. LLM presents findings to user
#   4. User reviews and decides (mitigate or proceed)

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Custom status→action mappings (must be defined BEFORE sourcing)
map_status_to_action() {
    case "$1" in
        success)       echo "display_summary" ;;
        ready)         echo "proceed_to_analysis" ;;
        ready_for_llm) echo "llm_analyze" ;;
        *)             _default_map_status_to_action "$1" ;;
    esac
}

# Source shared output framework
source "${SCRIPT_DIR}/lib/output-framework.sh"

# Global variables
OUTPUT_MODE="json"  # json or raw
SECTION="full"      # full, gather, analyze, score, document
ENVIRONMENT=""
VERSION=""
RISK_SCORE=0
DEPLOYMENT=""
TIMESTAMP=""
CHAINED=false  # true when section_gather is invoked as part of the "full" chain

#------------------------------------------------------------------------------
# Parse Arguments
#------------------------------------------------------------------------------

while [[ $# -gt 0 ]]; do
    case "$1" in
        --json) OUTPUT_MODE="json"; shift ;;
            --toon) OUTPUT_MODE="json"; OUTPUT_FORMAT="toon"; shift ;;
        --raw) OUTPUT_MODE="raw"; shift ;;
        --full) SECTION="full"; shift ;;
        --gather) SECTION="gather"; shift ;;
        --analyze) SECTION="analyze"; shift ;;
        --score) SECTION="score"; shift ;;
        --document) SECTION="document"; shift ;;
        --environment) ENVIRONMENT="$2"; shift 2 ;;
        --version) VERSION="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

#------------------------------------------------------------------------------
# Section: Gather Context (includes automated code risk scan)
#------------------------------------------------------------------------------

section_gather() {
    log "${BLUE}=== Gathering Deployment Context ===${NC}"

    if [[ -z "$ENVIRONMENT" ]]; then
        exit_with_json "error" "Environment not specified" "Use --environment staging|production"
    fi

    if [[ -z "$VERSION" ]]; then
        VERSION=$("${SCRIPT_DIR}/get-version.sh" -q 2>/dev/null || echo "unknown")
    fi

    TIMESTAMP=$(date -Iseconds)

    # Determine comparison branches
    source "${SCRIPT_DIR}/lib/deployment-config.sh" 2>/dev/null || true
    local source_branch="${DEV_BRANCH:-dev}"
    local target_branch="${STAGING_BRANCH:-staging}"
    if [[ "$ENVIRONMENT" == "production" ]]; then
        source_branch="${STAGING_BRANCH:-staging}"
        target_branch="${PRODUCTION_BRANCH:-production}"
    fi

    # --- Automated code risk scan (formerly analyze-deployment-risk.sh) ---
    log "${BLUE}Running automated risk scan...${NC}"

    local risk_score=0
    local migration_risk=0 api_risk=0 security_risk=0 perf_risk=0 dep_risk=0
    local changed_files=0 changed_lines="0"

    git fetch origin "$source_branch" "$target_branch" >/dev/null 2>&1 || true

    # 1. Database migrations
    if git diff "origin/$target_branch"..."origin/$source_branch" --name-only 2>/dev/null | grep -qE "migrations?/"; then
        local migs
        migs=$(git diff "origin/$target_branch"..."origin/$source_branch" -- "**/migrations*" 2>/dev/null | grep -cE "^[+-].*DROP|^[+-].*DELETE FROM|^[+-].*ALTER.*TYPE" || echo "0")
        if [[ $migs -gt 0 ]]; then migration_risk=8; else migration_risk=3; fi
        risk_score=$((risk_score + migration_risk))
    fi

    # 2. Breaking API changes
    if git diff "origin/$target_branch"..."origin/$source_branch" 2>/dev/null | grep -qE "^-.*@(get|post|put|delete|patch)\(|^-.*def (get_|post_|put_|delete_)|^-\s+def \w+\(.*:"; then
        api_risk=6
        risk_score=$((risk_score + api_risk))
    fi

    # 3. Security risks
    if git diff "origin/$target_branch"..."origin/$source_branch" 2>/dev/null | grep -vE "password_reset|reset_token" | grep -qE "password|secret|api_key|token"; then
        security_risk=9; risk_score=$((risk_score + security_risk))
    elif git diff "origin/$target_branch"..."origin/$source_branch" 2>/dev/null | grep -qE "exec\(|eval\(|system\(|subprocess|shell=True"; then
        security_risk=8; risk_score=$((risk_score + security_risk))
    elif git diff "origin/$target_branch"..."origin/$source_branch" 2>/dev/null | grep -vE "WHERE" | grep -qE "\.query\(|\.execute\(|SELECT.*FROM"; then
        security_risk=7; risk_score=$((risk_score + security_risk))
    fi

    # 4. Performance risks
    if git diff "origin/$target_branch"..."origin/$source_branch" 2>/dev/null | grep -qE "for.*in.*\{.*query|\.map.*query|db\.query"; then
        perf_risk=6; risk_score=$((risk_score + perf_risk))
    fi

    # 5. Dependency changes
    if git diff "origin/$target_branch"..."origin/$source_branch" --name-only 2>/dev/null | grep -qE "package.json|requirements.txt|pyproject.toml|go.mod|Gemfile|Cargo.toml"; then
        local dep_changed
        dep_changed=$(git diff "origin/$target_branch"..."origin/$source_branch" -- package.json requirements.txt pyproject.toml go.mod Gemfile Cargo.toml 2>/dev/null | grep -cE "^[+-]" | head -1 || echo "0")
        if [[ $dep_changed -gt 5 ]]; then dep_risk=5; else dep_risk=2; fi
        risk_score=$((risk_score + dep_risk))
    fi

    # 6. Code volume
    changed_files=$(git diff "origin/$target_branch"..."origin/$source_branch" --name-only 2>/dev/null | wc -l | tr -d ' ')
    changed_lines=$(git diff "origin/$target_branch"..."origin/$source_branch" --shortstat 2>/dev/null | grep -oE '[0-9]+ insertion|[0-9]+ deletion' | grep -oE '[0-9]+' | awk '{sum+=$1} END{print sum+0}')
    if [[ $changed_files -gt 50 ]]; then risk_score=$((risk_score + 2))
    elif [[ $changed_files -gt 30 ]]; then risk_score=$((risk_score + 1)); fi

    # Cap at 10
    [[ $risk_score -gt 10 ]] && risk_score=10

    local auto_status="low"
    if [[ $risk_score -ge 9 ]]; then auto_status="critical"
    elif [[ $risk_score -ge 7 ]]; then auto_status="high"
    elif [[ $risk_score -ge 5 ]]; then auto_status="medium"
    elif [[ $risk_score -ge 3 ]]; then auto_status="low-medium"; fi

    log "${GREEN}✓${NC} Automated scan: score=$risk_score status=$auto_status"

    if [[ "$CHAINED" == "true" ]]; then
        # Part of the "full" chain — record results for the caller and return
        # instead of exiting, so subsequent sections can still run.
        log "${GREEN}✓${NC} Context gathered (chained)"
        return 0
    fi

    SECTION="gather"
    exit_with_json "ready" "Context gathered with automated risk scan" "" \
        "\"environment\": \"$ENVIRONMENT\"," \
        "\"version\": \"$VERSION\"," \
        "\"automated_scan\": {" \
        "  \"risk_score\": $risk_score," \
        "  \"max_score\": 10," \
        "  \"status\": \"$auto_status\"," \
        "  \"breakdown\": {\"migration\": $migration_risk, \"api\": $api_risk, \"security\": $security_risk, \"performance\": $perf_risk, \"dependencies\": $dep_risk}," \
        "  \"code_metrics\": {\"files_changed\": $changed_files, \"lines_changed\": \"$changed_lines\"}" \
        "}," \
        "\"source_branch\": \"$source_branch\"," \
        "\"target_branch\": \"$target_branch\""
}

#------------------------------------------------------------------------------
# Section: Analyze (LLM-Driven)
#------------------------------------------------------------------------------

section_analyze() {
    log "${BLUE}=== Risk Analysis ===${NC}"

    # This is primarily LLM-driven work
    # Script just runs automated checks that support LLM analysis

    local details=""

    # Check if we're in a git repo
    if ! git rev-parse --git-dir > /dev/null 2>&1; then
        exit_with_json "error" "Not a git repository" "Risk analysis requires git"
    fi

    # Get diff stats for context
    local diff_stats=""
    if git show-ref --verify --quiet refs/heads/main; then
        diff_stats=$(git diff main...HEAD --stat 2>&1 || echo "Unable to calculate diff")
    fi

    details="Analysis requires LLM to examine:
- Code changes (files, complexity, critical paths)
- Database migrations (schema changes, data risks)
- Dependencies (security, versions)
- Configuration changes
- Breaking changes
- Rollback capability
- Testing coverage
- Security vulnerabilities
- Performance impact
- Data integrity

Diff stats:
$diff_stats"

    if [[ "$CHAINED" == "true" ]]; then
        log "${GREEN}✓${NC} Risk analysis checks complete (chained)"
        return 0
    fi

    if [[ "$OUTPUT_MODE" == "json" ]]; then
        cat <<EOF
{
  "status": "ready_for_llm",
  "next_action": "llm_analyze",
  "message": "Automated checks complete, LLM analysis needed",
  "section": "analyze",
  "diff_available": $(if [[ -n "$diff_stats" ]]; then echo "true"; else echo "false"; fi),
  "details": $(echo "$details" | jq -Rs .)
}
EOF
    else
        log "${YELLOW}⚠ Risk analysis is LLM-driven${NC}"
        log "$details"
    fi

    return 0
}

#------------------------------------------------------------------------------
# Section: Calculate Score (LLM-Driven)
#------------------------------------------------------------------------------

section_score() {
    log "${BLUE}=== Calculating Risk Score ===${NC}"

    # Score calculation is done by LLM after analysis
    # This section just validates that we have the prerequisites

    local details="Risk score calculation requires LLM to:
1. Assess each risk category (0-10 scale)
2. Apply weights (Security 30%, Data Integrity 25%, etc.)
3. Calculate weighted average
4. Check for critical individual risks
5. Adjust for historical context
6. Apply deployment window factors"

    if [[ "$CHAINED" == "true" ]]; then
        log "${GREEN}✓${NC} Risk scoring checks complete (chained)"
        return 0
    fi

    if [[ "$OUTPUT_MODE" == "json" ]]; then
        cat <<EOF
{
  "status": "ready_for_llm",
  "next_action": "llm_score",
  "message": "Ready for LLM to calculate risk score",
  "section": "score",
  "details": $(echo "$details" | jq -Rs .)
}
EOF
    else
        log "${YELLOW}⚠ Risk scoring is LLM-driven${NC}"
        log "$details"
    fi

    return 0
}

#------------------------------------------------------------------------------
# Section: Generate Document (LLM-Driven)
#------------------------------------------------------------------------------

section_document() {
    log "${BLUE}=== Generating Risk Document ===${NC}"

    # Document generation is LLM-driven
    # Script just ensures output directory exists

    local risk_dir="docs/deployment-risks"
    if [[ ! -d "$risk_dir" ]]; then
        mkdir -p "$risk_dir" || exit_with_json "error" "Failed to create $risk_dir"
    fi

    local doc_name="$(date +%Y-%m-%d)-${ENVIRONMENT:-unknown}-${VERSION:-unknown}.md"
    local doc_path="$risk_dir/$doc_name"

    local details="Document should be created at: $doc_path

LLM must generate document with:
- Executive Summary
- Risk Breakdown Table
- Detailed Risk Analysis
- Mitigation Options (2+ per risk)
- Deployment Readiness Assessment
- Pre-deployment Checklist
- Rollback Plan
- Recommendation"

    if [[ "$CHAINED" == "true" ]]; then
        log "${GREEN}✓${NC} Document prerequisites complete (chained): $doc_path"
        return 0
    fi

    if [[ "$OUTPUT_MODE" == "json" ]]; then
        cat <<EOF
{
  "status": "ready_for_llm",
  "next_action": "llm_generate_document",
  "message": "Ready for LLM to generate risk document",
  "section": "document",
  "document_path": "$doc_path",
  "details": $(echo "$details" | jq -Rs .)
}
EOF
    else
        log "${YELLOW}⚠ Document generation is LLM-driven${NC}"
        log "$details"
    fi

    return 0
}

#------------------------------------------------------------------------------
# Main Execution
#------------------------------------------------------------------------------

main() {
    case "$SECTION" in
        full)
            CHAINED=true
            section_gather
            section_analyze
            section_score
            section_document

            local json=$(cat <<EOF
{
  "status": "ready_for_llm",
  "next_action": "llm_analyze",
  "message": "Automated checks complete across full chain; LLM analysis, scoring, and document generation needed",
  "environment": "$ENVIRONMENT",
  "version": "$VERSION",
  "timestamp": "$(date -Iseconds)"
}
EOF
)
            log_json "$json"
            exit 0
            ;;
        gather)
            section_gather
            ;;
        analyze)
            section_analyze
            ;;
        score)
            section_score
            ;;
        document)
            section_document
            ;;
        *)
            exit_with_json "error" "Unknown section: $SECTION"
            ;;
    esac
}

main "$@"
