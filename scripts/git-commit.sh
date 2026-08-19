#!/usr/bin/env bash
set -euo pipefail

# STANDARD SCRIPT PATTERN: Git commit workflow with --json/--raw output modes
#
# Usage:
#   ~/.claude/scripts/git-commit.sh [--json|--raw] [--section] [--files "file1 file2..."]
#
# Output Modes:
#   --json: Structured output for LLM, default (TOON when the caller is an AI agent, JSON otherwise)
#   --raw:  Verbose debugging output when LLM needs more details
#
# Section Flags (run specific section only):
#   --analyze:       Analyze git state — file lists, stats, diff page count
#   --analyze-diffs: Return paged diffs (use with --page N, default page 1)
#   --execute:       Execute commits from plan (requires plan file)
#
# Additional Flags:
#   --files:     Focus on specific files only (comma or space separated)
#   --page:      Page number for --analyze-diffs (1-based, default 1)
#   --plan-file: Path to commit plan file (default: /tmp/git-commit-plan.json)
#
# Workflow:
#   1. LLM calls: git-commit.sh --json --analyze
#   2. Returns: File lists, stats, recent commits, diff_pages count
#   3. LLM calls: git-commit.sh --json --analyze-diffs --page 1 (repeat for each page)
#   4. LLM generates commit plan based on all diffs
#   5. LLM calls: git-commit.sh --json --execute --plan-file /path/to/plan.json

# Script directory (needed for sourcing library)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Custom next_action mapping (must be defined before sourcing output-framework)
map_status_to_action() {
    case "$1" in
        success)         echo "display_summary" ;;
        partial_failure) echo "fix_failed_commits" ;;
        *)               echo "fix_error" ;;
    esac
}

# Source shared library
source "${SCRIPT_DIR}/lib/output-framework.sh"

# Global variables
OUTPUT_MODE="json"  # json or raw
SECTION="analyze"   # analyze, analyze-diffs, execute
FOCUS_FILES=""      # User-specified files to focus on
PLAN_FILE="/tmp/git-commit-plan.json"
PAGE=1              # Page number for analyze-diffs
LINES_PER_PAGE=500  # Lines per diff page

#------------------------------------------------------------------------------
# Helper Functions
#------------------------------------------------------------------------------

# Build ordered list of all changed files (staged, unstaged, untracked)
# Outputs one "source:file" per line
get_all_changed_files() {
    local staged unstaged untracked

    staged=$(git diff --name-only --cached 2>/dev/null || echo "")
    unstaged=$(git diff --name-only 2>/dev/null || echo "")
    untracked=$(git ls-files --others --exclude-standard 2>/dev/null || echo "")

    if [[ -n "$staged" ]]; then
        while IFS= read -r f; do
            [[ -z "$f" ]] && continue
            echo "staged:$f"
        done <<< "$staged"
    fi
    if [[ -n "$unstaged" ]]; then
        while IFS= read -r f; do
            [[ -z "$f" ]] && continue
            echo "unstaged:$f"
        done <<< "$unstaged"
    fi
    if [[ -n "$untracked" ]]; then
        while IFS= read -r f; do
            [[ -z "$f" ]] && continue
            echo "untracked:$f"
        done <<< "$untracked"
    fi
}

# Get diff/content for a single file as JSON object
# Args: $1 = "source:filepath"
get_file_diff() {
    local entry="$1"
    local source="${entry%%:*}"
    local file="${entry#*:}"
    local diff_output=""
    local line_count=0

    case "$source" in
        staged)
            diff_output=$(git diff --cached -U1 -- "$file" 2>/dev/null || echo "")
            ;;
        unstaged)
            diff_output=$(git diff -U1 -- "$file" 2>/dev/null || echo "")
            ;;
        untracked)
            diff_output=$(cat "$file" 2>/dev/null || echo "")
            ;;
    esac

    if [[ -n "$diff_output" ]]; then
        line_count=$(echo "$diff_output" | wc -l | tr -d ' ')
    fi

    echo "$line_count"
}

# Calculate total diff lines and page count (based on file-start assignment)
# Each file is assigned to the page where its cumulative start falls.
# Returns: "total_lines page_count"
calculate_diff_pages() {
    local all_files="$1"
    local total_lines=0
    local max_page=1

    while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue
        local file_start=$total_lines
        local lines
        lines=$(get_file_diff "$entry")
        total_lines=$((total_lines + lines))

        # Which page does this file's start fall on?
        local file_page=$(( file_start / LINES_PER_PAGE + 1 ))
        if [[ $file_page -gt $max_page ]]; then
            max_page=$file_page
        fi
    done <<< "$all_files"

    echo "$total_lines $max_page"
}

#------------------------------------------------------------------------------
# Section Functions
#------------------------------------------------------------------------------

# Section 1: Analyze git state — summary only, no diffs
section_analyze() {
    log "${BLUE}Analyzing Git State${NC}"

    # Check if we're in a git repository
    if ! git rev-parse --git-dir >/dev/null 2>&1; then
        exit_with_json "error" "Not in a git repository" "Run git init or cd to a git repository"
    fi

    # Get file lists
    local staged_files
    staged_files=$(git diff --name-only --cached 2>/dev/null || echo "")
    local unstaged_files
    unstaged_files=$(git diff --name-only 2>/dev/null || echo "")
    local untracked_files
    untracked_files=$(git ls-files --others --exclude-standard 2>/dev/null || echo "")

    if [[ -n "$FOCUS_FILES" ]]; then
        log "${YELLOW}Focusing on: $FOCUS_FILES${NC}"
    fi

    # Get diff stats
    local staged_diff_stat=""
    if [[ -n "$staged_files" ]]; then
        staged_diff_stat=$(git diff --cached --stat 2>/dev/null || echo "")
    fi
    local unstaged_diff_stat=""
    if [[ -n "$unstaged_files" ]]; then
        unstaged_diff_stat=$(git diff --stat 2>/dev/null || echo "")
    fi

    # Recent commits for style matching
    local recent_commits
    recent_commits=$(git log --oneline -10 2>/dev/null || echo "")

    # Calculate diff pages
    log "Calculating diff pages..."
    local all_files
    all_files=$(get_all_changed_files)
    local page_info
    page_info=$(calculate_diff_pages "$all_files")
    local total_diff_lines="${page_info%% *}"
    local diff_pages="${page_info##* }"

    local total_changes
    total_changes=$(echo "$staged_files" "$unstaged_files" "$untracked_files" | wc -w | tr -d ' ')

    local json=$(cat <<EOF
{
  "status": "success",
  "section": "analyze",
  "message": "Git state analyzed successfully",
  "focus_files": $(echo "$FOCUS_FILES" | jq -Rs 'split(" ") | map(select(length > 0))'),
  "staged_files": $(echo "$staged_files" | jq -Rs 'split("\n") | map(select(length > 0))'),
  "unstaged_files": $(echo "$unstaged_files" | jq -Rs 'split("\n") | map(select(length > 0))'),
  "untracked_files": $(echo "$untracked_files" | jq -Rs 'split("\n") | map(select(length > 0))'),
  "staged_diff_stat": $(echo "$staged_diff_stat" | jq -Rs .),
  "unstaged_diff_stat": $(echo "$unstaged_diff_stat" | jq -Rs .),
  "recent_commits": $(echo "$recent_commits" | jq -Rs 'split("\n") | map(select(length > 0))'),
  "total_changes": $total_changes,
  "total_diff_lines": $total_diff_lines,
  "diff_pages": $diff_pages,
  "lines_per_page": $LINES_PER_PAGE,
  "timestamp": "$(date -Iseconds)"
}
EOF
)

    log_json "$json"
    exit 0
}

# Section 2: Analyze diffs — paged output
section_analyze_diffs() {
    log "${BLUE}Collecting diffs (page $PAGE)${NC}"

    if ! git rev-parse --git-dir >/dev/null 2>&1; then
        exit_with_json "error" "Not in a git repository" "Run git init or cd to a git repository"
    fi

    local all_files
    all_files=$(get_all_changed_files)

    # Assign each file to a page based on where its cumulative start falls.
    # A file belongs to exactly one page — the page containing its start line.
    # Files are included fully on their assigned page (no splitting, no duplicates).
    local page_start_line=$(( (PAGE - 1) * LINES_PER_PAGE ))
    local page_end_line=$(( PAGE * LINES_PER_PAGE ))
    local cumulative_lines=0
    local first=true
    local files_on_page=0
    local total_lines_all=0

    printf '{"status":"success","section":"analyze-diffs","page":%d,"file_diffs":[' "$PAGE"

    while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue
        local source="${entry%%:*}"
        local file="${entry#*:}"

        # Get this file's diff/content
        local diff_output=""
        case "$source" in
            staged)   diff_output=$(git diff --cached -U1 -- "$file" 2>/dev/null || echo "") ;;
            unstaged) diff_output=$(git diff -U1 -- "$file" 2>/dev/null || echo "") ;;
            untracked) diff_output=$(cat "$file" 2>/dev/null || echo "") ;;
        esac

        local line_count=0
        if [[ -n "$diff_output" ]]; then
            line_count=$(echo "$diff_output" | wc -l | tr -d ' ')
        fi

        local file_start=$cumulative_lines
        cumulative_lines=$((cumulative_lines + line_count))
        total_lines_all=$cumulative_lines

        # File belongs to the page where its start line falls
        # Skip files that start before this page
        if [[ $file_start -lt $page_start_line ]]; then
            continue
        fi
        # Stop if file starts at or after this page's end
        if [[ $file_start -ge $page_end_line ]]; then
            continue
        fi

        # This file starts within the current page — include it fully
        $first || printf ','
        first=false
        files_on_page=$((files_on_page + 1))

        local key="diff"
        [[ "$source" == "untracked" ]] && key="content"

        printf '{"file":%s,"source":"%s","%s":%s,"lines":%d}' \
            "$(printf '%s' "$file" | jq -Rs .)" \
            "$source" \
            "$key" \
            "$(printf '%s' "$diff_output" | jq -Rs .)" \
            "$line_count"

    done <<< "$all_files"

    # Recalculate accurate page count using file-start assignment
    local page_info
    page_info=$(calculate_diff_pages "$all_files")
    local total_pages="${page_info##* }"
    total_lines_all="${page_info%% *}"

    printf '],"files_on_page":%d,"total_pages":%d,"total_diff_lines":%d,"timestamp":"%s"}\n' \
        "$files_on_page" "$total_pages" "$total_lines_all" "$(date -Iseconds)"

    exit 0
}

# Section 3: Execute commits from plan
section_execute() {
    log "${BLUE}Executing Commits from Plan${NC}"

    # Check if plan file exists
    if [[ ! -f "$PLAN_FILE" ]]; then
        exit_with_json "error" "Commit plan file not found" "Expected plan file at: $PLAN_FILE"
    fi

    # Validate plan file is valid JSON
    if ! jq empty "$PLAN_FILE" 2>/dev/null; then
        exit_with_json "error" "Invalid commit plan JSON" "Plan file is not valid JSON: $PLAN_FILE"
    fi

    # Extract commits from plan
    local commit_count
    commit_count=$(jq '.commits | length' "$PLAN_FILE" 2>/dev/null || echo "0")

    if [[ "$commit_count" -eq 0 ]]; then
        exit_with_json "error" "No commits in plan" "Plan file contains no commits"
    fi

    log "${CYAN}Found $commit_count commit(s) in plan${NC}"

    # Track results
    local results=()
    local failed=0

    # Execute each commit
    for ((i=0; i<commit_count; i++)); do
        local commit_data
        commit_data=$(jq -c ".commits[$i]" "$PLAN_FILE")

        # Support both title/body and message formats
        local title
        title=$(echo "$commit_data" | jq -r '.title // empty' 2>/dev/null || true)
        local body
        body=$(echo "$commit_data" | jq -r '.body // empty' 2>/dev/null || true)

        # Fallback: parse .message into title + body (split on first blank line)
        if [[ -z "$title" ]]; then
            local raw_message
            raw_message=$(echo "$commit_data" | jq -r '.message // empty' 2>/dev/null || true)
            if [[ -n "$raw_message" ]]; then
                title=$(echo "$raw_message" | head -1)
                body=$(echo "$raw_message" | tail -n +3)
            fi
        fi

        if [[ -z "$title" ]]; then
            results+=("{\"order\":$((i+1)),\"status\":\"failed\",\"title\":\"(missing)\",\"error\":\"No title or message field in commit plan\"}")
            failed=$((failed + 1))
            log "${RED}✗${NC} No title or message in commit $((i+1))"
            continue
        fi

        local files
        files=$(echo "$commit_data" | jq -r '.files[]' 2>/dev/null || true)

        log "${BLUE}Commit $((i+1))/$commit_count: $title${NC}"
        log "${CYAN}Files: $files${NC}"

        # Clear stale index.lock if present (left by crashed git processes)
        local git_dir
        git_dir=$(git rev-parse --git-dir 2>/dev/null || echo ".git")
        if [[ -f "${git_dir}/index.lock" ]]; then
            log "${YELLOW}⚠${NC} Removing stale ${git_dir}/index.lock"
            rm -f "${git_dir}/index.lock"
        fi

        # Ensure clean staging area before each commit
        git reset HEAD -- . >/dev/null 2>&1 || true

        # Stage files one at a time (handles adds, modifications, and deletions)
        local stage_failed=false
        local stage_error=""
        while IFS= read -r file; do
            [[ -z "$file" ]] && continue
            local attempt=0
            local staged=false
            while [[ $attempt -lt 3 ]]; do
                if git add -A -- "$file" 2>/tmp/git-commit-error.log; then
                    staged=true
                    break
                fi
                attempt=$((attempt + 1))
                # If index.lock appeared, remove it and retry
                if grep -q "index.lock" /tmp/git-commit-error.log 2>/dev/null; then
                    log "${YELLOW}⚠${NC} index.lock detected, removing and retrying ($attempt/3)"
                    rm -f "${git_dir}/index.lock"
                    sleep 0.2
                else
                    break
                fi
            done
            if [[ "$staged" != "true" ]]; then
                stage_error=$(cat /tmp/git-commit-error.log 2>/dev/null || echo "unknown error")
                log "${RED}✗${NC} Failed to stage: $file"
                log "$stage_error"
                stage_failed=true
                break
            fi
        done <<< "$files"

        if [[ "$stage_failed" == "true" ]]; then
            git reset HEAD -- . >/dev/null 2>&1 || true
            local escaped_error
            escaped_error=$(printf '%s' "$stage_error" | tr '\n' ' ' | cut -c1-200)
            results+=("{\"order\":$((i+1)),\"status\":\"failed\",\"title\":$(printf '%s' "$title" | jq -Rs .),\"error\":$(printf '%s' "Failed to stage files: $escaped_error" | jq -Rs .)}")
            failed=$((failed + 1))
            continue
        fi

        # Verify something is staged
        if git diff --cached --quiet 2>/dev/null; then
            results+=("{\"order\":$((i+1)),\"status\":\"failed\",\"title\":$(printf '%s' "$title" | jq -Rs .),\"error\":\"No changes staged after adding files\"}")
            failed=$((failed + 1))
            log "${RED}✗${NC} Nothing staged for commit $((i+1))"
            continue
        fi

        # Construct commit message (title + body)
        local commit_message="$title"
        if [[ -n "$body" ]]; then
            commit_message="$title

$body"
        fi

        # Create commit using HEREDOC format
        local commit_output
        if ! commit_output=$(git commit -m "$(cat <<EOF
$commit_message
EOF
)" 2>&1); then
            # Check if pre-commit hook failed
            if echo "$commit_output" | grep -q "hook"; then
                results+=("{\"order\":$((i+1)),\"status\":\"hook_failed\",\"title\":$(printf '%s' "$title" | jq -Rs .),\"error\":$(printf '%s' "$commit_output" | jq -Rs .)}")
                failed=$((failed + 1))
                log "${RED}✗${NC} Pre-commit hook failed"
            else
                results+=("{\"order\":$((i+1)),\"status\":\"failed\",\"title\":$(printf '%s' "$title" | jq -Rs .),\"error\":$(printf '%s' "$commit_output" | jq -Rs .)}")
                failed=$((failed + 1))
                log "${RED}✗${NC} Commit failed"
            fi
            continue
        fi

        # Get commit hash
        local commit_hash
        commit_hash=$(git rev-parse HEAD)

        results+=("{\"order\":$((i+1)),\"status\":\"success\",\"title\":$(printf '%s' "$title" | jq -Rs .),\"hash\":\"$commit_hash\"}")
        log "${GREEN}✓${NC} Commit created: $commit_hash"
    done

    # Build results JSON
    local results_json="["
    for ((i=0; i<${#results[@]}; i++)); do
        results_json+="${results[$i]}"
        if [[ $i -lt $((${#results[@]} - 1)) ]]; then
            results_json+=","
        fi
    done
    results_json+="]"

    # Final status
    local final_status="success"
    if [[ $failed -gt 0 ]]; then
        final_status="partial_failure"
    fi

    local json=$(cat <<EOF
{
  "status": "$final_status",
  "section": "execute",
  "message": "Executed $commit_count commit(s), $failed failed",
  "total_commits": $commit_count,
  "successful_commits": $((commit_count - failed)),
  "failed_commits": $failed,
  "results": $results_json,
  "timestamp": "$(date -Iseconds)"
}
EOF
)

    log_json "$json"
    if [[ $failed -gt 0 ]]; then
        exit 1
    fi
    exit 0
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
            --analyze-diffs) SECTION="analyze-diffs"; shift ;;
            --analyze) SECTION="analyze"; shift ;;
            --execute) SECTION="execute"; shift ;;
            --full) SECTION="analyze"; shift ;;
            --files)
                shift
                FOCUS_FILES="$1"
                shift
                ;;
            --page)
                shift
                PAGE="$1"
                shift
                ;;
            --plan-file)
                shift
                PLAN_FILE="$1"
                shift
                ;;
            *) shift ;;
        esac
    done

    # Execute sections based on flag
    case "$SECTION" in
        analyze)
            section_analyze
            ;;
        analyze-diffs)
            section_analyze_diffs
            ;;
        execute)
            section_execute
            ;;
    esac
}

# Run main function
main "$@"
