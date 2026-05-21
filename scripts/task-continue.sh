#!/usr/bin/env bash
set -euo pipefail

# task-continue.sh - Continue work on task with progress tracking
#
# STANDARD SCRIPT PATTERN: Section flags with --json/--raw output modes
#
# Usage:
#   ~/.claude/scripts/task-continue.sh [--json|--raw] [--full|--section] [options] [--task-id <id>]
#
# Output Modes:
#   --json: Structured JSON output for LLM (default)
#   --raw:  Verbose debugging output when LLM needs more details
#
# Section Flags (run specific section only):
#   --identify:      Identify and load task only
#   --verify-branch: Verify branch and git state only
#   --run-tests:     Run tests and validate coverage only
#   --gather:        Gather work progress (non-interactive, from git + flags)
#   --commit:        Update plan, commit changes, update index
#   --full:          Run all sections end-to-end (default)
#
# Plan Progress Flags (passed through to plan-progress.sh):
#   --completed-tasks "1.1,1.2"        Mark plan tasks as complete [x]
#   --actual-time "1.1=45m,1.2=1h"     Set actual time for completed tasks
#   --lessons "text"                    Lessons learned for this session
#   --progress-note "text"             Progress summary for plan entry
#   --task-label "Task 1.2"            Label for the progress entry heading
#   --went-well "text"                 What went well this session
#   --challenges "text"                Challenges encountered
#   --differently "text"               What would be done differently
#   --patterns "text"                  Reusable patterns discovered
#
# Workflow:
#   1. LLM calls: task-continue.sh --json --full --task-id <id>
#   2. Returns task context, plan info, recent commits for LLM to determine next work
#   3. LLM does work, then calls: task-continue.sh --json --run-tests --task-id <id>
#   4. If tests fail: Returns JSON with failure details for LLM to fix
#   5. LLM calls: task-continue.sh --json --commit --task-id <id> --progress-note "..." --lessons "..."

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source shared libraries
source "${SCRIPT_DIR}/lib/output-framework.sh"
source "${SCRIPT_DIR}/lib/yaml.sh"
source "${SCRIPT_DIR}/doc-utils.sh"
source "${SCRIPT_DIR}/get-default-branch.sh"

# Global variables
OUTPUT_MODE="json"  # json or raw
SECTION="full"      # full, identify, verify-branch, run-tests, gather, commit

INPUT_ARG=""
TASK_ID=""
TASK_DOC=""
TASK_TITLE=""
CURRENT_BRANCH=""
DEFAULT_BRANCH=""
PLAN_DOC=""
PLAN_UPDATED=false
TASK_TYPE=""
ASANA_GID=""

# Test state
TEST_COMMAND=""
TEST_PASSED=false
COVERAGE_PERCENT="0"
TASK_COVERAGE_PERCENT="0"
MIN_COVERAGE="80"

# Progress state
CHANGED_FILES=""
COMMIT_HASH=""

# Plan progress flags (passed to plan-progress.sh)
COMPLETED_TASKS=""
ACTUAL_TIME=""
LESSONS=""
PROGRESS_NOTE=""
TASK_LABEL=""
WENT_WELL=""
CHALLENGES_NOTE=""
DO_DIFFERENTLY=""
PATTERNS=""

#------------------------------------------------------------------------------
# Helper Functions
#------------------------------------------------------------------------------

print_header() {
    log "${CYAN}$1${NC}"
    log "$(printf '%.0s=' {1..60})"
}

#------------------------------------------------------------------------------
# Section Functions
#------------------------------------------------------------------------------

# Section 1: Identify and load task
section_identify() {
    print_header "Identifying Task"

    # Priority: explicit --task-id > .current-task > error
    if [[ -n "$INPUT_ARG" ]]; then
        if [[ "$INPUT_ARG" =~ ^[A-Fa-f0-9]{6}$ ]]; then
            TASK_ID=$(normalize_task_id "$INPUT_ARG")
            TASK_DOC=$(find_primary "$TASK_ID" 2>/dev/null || echo "")

            if [[ -z "$TASK_DOC" ]]; then
                exit_with_json "error" "No primary task found for task ID $TASK_ID" \
                    "Check docs/active/ for available tasks"
            fi
            log "${GREEN}✓${NC} Found task by ID: $(basename "$TASK_DOC")"
        else
            TASK_DOC=$(find docs/active -name "*-TSK-*.md" -o -name "*-INC-*.md" 2>/dev/null | grep "$INPUT_ARG" | head -1 || true)
            log "${GREEN}✓${NC} Found task by name: $(basename "${TASK_DOC:-}")"
        fi
    elif load_current_task; then
        TASK_DOC="$CT_TASK_DOC"
        CURRENT_BRANCH="$CT_BRANCH"
        ASANA_GID="$CT_ASANA_GID"

        if [[ -n "$TASK_DOC" ]] && [[ -f "$TASK_DOC" ]]; then
            log "${GREEN}✓${NC} Found current task: $(basename "$TASK_DOC")"
        else
            TASK_DOC=""
        fi
    fi

    # Validate task document exists
    if [[ ! -f "$TASK_DOC" ]]; then
        exit_with_json "error" "Task document not found" \
            "Usage: task-continue.sh --task-id <id>"
    fi

    # Extract metadata
    TASK_ID=$(get_task_id "$(basename "$TASK_DOC")")
    TASK_TITLE=$(get_doc_title "$TASK_DOC")

    # Detect task type from document type
    local filename=$(basename "$TASK_DOC")
    if echo "$filename" | grep -q "\-INC\-"; then
        TASK_TYPE="incident"
    else
        TASK_TYPE="feature"
    fi

    log "${GREEN}✓${NC} Resuming: $TASK_TITLE (Task ID: $TASK_ID)"

    if [[ "$SECTION" == "identify" ]]; then
        exit_with_json "success" "Task context loaded" "" \
            "\"task_id\":\"$TASK_ID\",\"task_title\":\"$TASK_TITLE\",\"task_doc\":\"$TASK_DOC\",\"task_type\":\"$TASK_TYPE\",\"current_branch\":\"$CURRENT_BRANCH\""
    fi
}

# Section 2: Verify branch and git state
section_verify_branch() {
    print_header "Verifying Branch State"

    # Get default branch
    DEFAULT_BRANCH=$(get_default_branch)

    # Verify current branch
    local current_git_branch=$(git branch --show-current)

    if [[ -z "$CURRENT_BRANCH" ]]; then
        CURRENT_BRANCH="$current_git_branch"
    fi

    if [[ "$current_git_branch" != "$CURRENT_BRANCH" ]] && [[ -n "$CURRENT_BRANCH" ]]; then
        log "${YELLOW}⚠${NC} Current branch ($current_git_branch) differs from expected ($CURRENT_BRANCH)"

        if git checkout "$CURRENT_BRANCH" >/dev/null 2>&1; then
            log "${GREEN}✓${NC} Switched to $CURRENT_BRANCH"
        else
            exit_with_json "error" "Cannot switch to branch $CURRENT_BRANCH"
        fi
    fi

    log "${GREEN}✓${NC} On branch: $(git branch --show-current)"

    # Check for uncommitted changes (allow them, we'll commit them)
    local uncommitted_count
    uncommitted_count=$(git status --porcelain | wc -l | tr -d ' ')

    # Pull latest changes
    git fetch origin >/dev/null 2>&1 || true
    git pull origin "$CURRENT_BRANCH" >/dev/null 2>&1 || true

    # Doc-index regeneration intentionally skipped here (also in section_commit).
    # `update-docs.sh` is O(docs) bash regex and takes minutes on large repos;
    # the index files are auto-regenerated bookkeeping. Run manually or at
    # /task-close. See section_commit for the longer comment.

    if [[ "$SECTION" == "verify-branch" ]]; then
        exit_with_json "success" "Branch verified" "" \
            "\"current_branch\":\"$CURRENT_BRANCH\",\"default_branch\":\"$DEFAULT_BRANCH\",\"uncommitted_changes\":$uncommitted_count"
    fi
}

# Section 3: Find and load plan document
section_find_plan() {
    log "${BLUE}Loading Plan Document${NC}"

    # Find all documents for this task ID
    local all_docs
    all_docs=$(find_by_id "$TASK_ID")

    # Find the plan document (PLN type)
    PLAN_DOC=$(echo "$all_docs" | grep "\-PLN\-" | head -1 || true)

    if [[ -z "$PLAN_DOC" ]]; then
        log "${YELLOW}⚠${NC} No plan document found for task ID $TASK_ID"
    else
        log "${GREEN}✓${NC} Plan: $(basename "$PLAN_DOC")"
    fi
}

# Section 4: Run tests and validate coverage
section_run_tests() {
    print_header "Running Tests"

    local min_coverage="80"

    # Load config from PROJECT.yaml if available
    if [[ -f "PROJECT.yaml" ]]; then
        local yaml_command
        yaml_command=$(yaml_get '.testing.command' PROJECT.yaml)
        min_coverage=$(yaml_get_default '.testing.min_coverage' '80' PROJECT.yaml)
        [[ "$min_coverage" == "null" ]] && min_coverage="80"

        # If PROJECT.yaml specifies a test command, use it
        if [[ -n "$yaml_command" ]] && [[ "$yaml_command" != "null" ]]; then
            TEST_COMMAND="$yaml_command"
        fi
    fi

    # Default: use Makefile test targets (FORMAT=json auto-detected for AI callers)
    # Never run test tools directly — always go through Make targets
    if [[ -z "$TEST_COMMAND" ]] || [[ "$TEST_COMMAND" == "null" ]]; then
        if [[ -f "Makefile" ]] && grep -q "^test:" Makefile; then
            TEST_COMMAND="make test"
        elif [[ -f "package.json" ]]; then
            TEST_COMMAND="npm test"
        elif [[ -f "pyproject.toml" ]] || [[ -f "pytest.ini" ]]; then
            TEST_COMMAND="pytest"
        elif [[ -f "go.mod" ]]; then
            TEST_COMMAND="go test ./..."
        elif [[ -f "Cargo.toml" ]]; then
            TEST_COMMAND="cargo test"
        else
            log "${YELLOW}⚠${NC} No test framework detected - skipping"
            TEST_PASSED=true

            if [[ "$SECTION" == "run-tests" ]]; then
                exit_with_json "success" "No test framework detected - skipping" "" \
                    "\"tests_skipped\":true,\"reason\":\"no_test_framework\""
            fi
            return
        fi
    fi

    log "${BLUE}ℹ${NC} Using test command: $TEST_COMMAND"

    # Discover available Make test targets for the LLM
    local available_targets=""
    if [[ -f "Makefile" ]]; then
        available_targets=$(grep -oE '^test[-a-zA-Z]*:' Makefile | sed 's/://' | tr '\n' ',' | sed 's/,$//' || echo "")
    fi

    # Run tests and capture output
    local test_output
    local test_exit=0
    test_output=$(eval "$TEST_COMMAND" 2>&1) || test_exit=$?

    # Try to parse as JSON (Makefile FORMAT=json output)
    local is_json=false
    local json_result=""
    if echo "$test_output" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
        is_json=true
        json_result="$test_output"
    fi

    if [[ "$is_json" == "true" ]]; then
        # Parse structured JSON output from Make targets
        local passed failed skipped success failures_json
        passed=$(echo "$json_result" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('overall',d).get('passed',0))" 2>/dev/null || echo "0")
        failed=$(echo "$json_result" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('overall',d).get('failed',0))" 2>/dev/null || echo "0")
        skipped=$(echo "$json_result" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('overall',d).get('skipped',0))" 2>/dev/null || echo "0")
        success=$(echo "$json_result" | python3 -c "import sys,json; d=json.load(sys.stdin); print(str(d.get('overall',d).get('success',True)).lower())" 2>/dev/null || echo "true")

        # Extract failures array for LLM
        failures_json=$(echo "$json_result" | python3 -c "
import sys,json
d=json.load(sys.stdin)
failures=d.get('failures',[])
print(json.dumps(failures[:20]))" 2>/dev/null || echo "[]")

        # Extract per-service breakdown if available
        local services_json
        services_json=$(echo "$json_result" | python3 -c "
import sys,json
d=json.load(sys.stdin)
services=d.get('services',{})
out={}
for name,svc in services.items():
    out[name]={'passed':svc.get('passed',0),'failed':svc.get('failed',0),'success':svc.get('success',True)}
print(json.dumps(out))" 2>/dev/null || echo "{}")

        if [[ "$success" == "true" ]] && [[ "$failed" -eq 0 ]]; then
            TEST_PASSED=true
            log "${GREEN}✓${NC} Tests passed (${passed} passed, ${skipped} skipped)"
        else
            TEST_PASSED=false
            log "${RED}✗${NC} Tests failed (${passed} passed, ${failed} failed)"

            if [[ "$SECTION" == "run-tests" ]]; then
                cat <<EOF
{
  "status": "intervention_needed",
  "next_action": "fix_error",
  "section": "run-tests",
  "message": "Tests failed - ${passed} passed, ${failed} failed",
  "test_command": "$TEST_COMMAND",
  "available_targets": "$available_targets",
  "passed": $passed,
  "failed": $failed,
  "skipped": $skipped,
  "failures": $failures_json,
  "services": $services_json,
  "next_steps": [
    "Read failures array to identify what broke",
    "Use narrowest make target to re-run: e.g. make test-backend",
    "Fix the failing tests",
    "Re-run: task-continue.sh --json --run-tests --task-id $INPUT_ARG"
  ],
  "timestamp": "$(date -Iseconds)"
}
EOF
                exit 1
            fi
        fi
    else
        # Non-JSON output — legacy fallback
        if [[ "$test_exit" -eq 0 ]]; then
            TEST_PASSED=true
            log "${GREEN}✓${NC} Tests passed"
        else
            TEST_PASSED=false
            log "${RED}✗${NC} Tests failed"

            local output_escaped
            output_escaped=$(echo "$test_output" | tail -50 | jq -Rs . 2>/dev/null || echo '""')

            if [[ "$SECTION" == "run-tests" ]]; then
                cat <<EOF
{
  "status": "intervention_needed",
  "next_action": "fix_error",
  "section": "run-tests",
  "message": "Tests failed - fix required before committing",
  "test_command": "$TEST_COMMAND",
  "available_targets": "$available_targets",
  "test_output": $output_escaped,
  "next_steps": [
    "Fix the failing tests",
    "Re-run: task-continue.sh --json --run-tests --task-id $INPUT_ARG"
  ],
  "timestamp": "$(date -Iseconds)"
}
EOF
                exit 1
            fi
        fi
    fi

    # Validate coverage if configured
    local coverage_command=""
    if [[ -f "PROJECT.yaml" ]]; then
        coverage_command=$(yaml_get '.testing.coverage_command' PROJECT.yaml)
    fi

    if [[ -n "$coverage_command" ]] && [[ "$coverage_command" != "null" ]]; then
        log "${BLUE}ℹ${NC} Checking test coverage..."

        if eval "$coverage_command" > /tmp/coverage.txt 2>&1; then
            COVERAGE_PERCENT=$(grep -oE '[0-9]+%' /tmp/coverage.txt | head -1 | sed 's/%//' || echo "0")
            log "${BLUE}ℹ${NC} Coverage: ${COVERAGE_PERCENT}%"

            if [[ "${COVERAGE_PERCENT}" -lt "${min_coverage}" ]]; then
                exit_with_json "intervention_needed" \
                    "Coverage ${COVERAGE_PERCENT}% is below minimum ${min_coverage}%" \
                    "Add more tests to increase coverage" \
                    "\"coverage_percent\":${COVERAGE_PERCENT},\"min_coverage\":${min_coverage}"
            fi

            log "${GREEN}✓${NC} Coverage meets minimum (${COVERAGE_PERCENT}% >= ${min_coverage}%)"
        else
            log "${YELLOW}⚠${NC} Coverage check failed (continuing anyway)"
        fi
    else
        log "${BLUE}ℹ${NC} No coverage command configured - skipping"
    fi

    if [[ "$SECTION" == "run-tests" ]]; then
        exit_with_json "success" "Tests passed" "" \
            "\"tests_passing\":true,\"coverage_percent\":${COVERAGE_PERCENT},\"test_command\":\"$TEST_COMMAND\",\"available_targets\":\"$available_targets\""
    fi
}

# Section 5: Gather work progress (non-interactive, from git + flags)
section_gather() {
    print_header "Gathering Progress"

    # Auto-extract from git history
    local recent_commits
    recent_commits=$(git log --oneline -10 2>/dev/null | sed 's/^/- /' || echo "- Work in progress")

    # Get changed files (staged + unstaged)
    CHANGED_FILES=$(git status --porcelain | head -20 || echo "")
    local changed_count
    changed_count=$(echo "$CHANGED_FILES" | grep -c . 2>/dev/null || true)
    [[ -z "$changed_count" ]] && changed_count=0

    # Get modified test files
    local test_files
    test_files=$(git diff --name-only HEAD~ 2>/dev/null | grep -E "test|spec" || true)
    if [[ -z "$test_files" ]]; then
        test_files=$(git status --porcelain | awk '{print $2}' | grep -E "test|spec" || true)
    fi

    log "${GREEN}✓${NC} Progress gathered: $changed_count files changed"

    if [[ "$SECTION" == "gather" ]]; then
        local test_files_json
        test_files_json=$(echo "$test_files" | jq -R 'select(length > 0)' | jq -s . 2>/dev/null || echo '[]')

        local json=$(cat <<EOF
{
  "status": "success",
  "next_action": "display_summary",
  "section": "gather",
  "message": "Progress gathered",
  "task_id": "$TASK_ID",
  "recent_commits": $(echo "$recent_commits" | jq -Rs . 2>/dev/null || echo '""'),
  "changed_files_count": $changed_count,
  "test_files": $test_files_json,
  "lessons_provided": $([ -n "$LESSONS" ] && echo "true" || echo "false"),
  "timestamp": "$(date -Iseconds)"
}
EOF
)
        log_json "$json"
        exit 0
    fi
}

# Check TDD compliance: if tdd_required is "yes" or "recommend", block commit
# when production files are staged without accompanying test files.
# "recommend" is treated as "yes" — plans should resolve this at planning time.
TDD_WARNING=""
check_tdd_compliance() {
    # Determine TDD requirement from completed tasks, not the next task.
    # If --completed-tasks was passed, look up those tasks' tdd_required in the plan.
    # Fall back to next_task_config only if no completed tasks specified.
    local tdd_req=""
    if [[ -n "$PLAN_DOC" ]] && [[ -f "$PLAN_DOC" ]]; then
        local plan_info
        plan_info=$("${SCRIPT_DIR}/plan-progress.sh" --json --file "$PLAN_DOC" 2>/dev/null || echo "null")

        if [[ -n "$COMPLETED_TASKS" ]]; then
            # Check TDD requirement of the tasks we just completed.
            # If ANY completed task had tdd_required: yes, enforce it.
            tdd_req="no"
            local plan_content
            plan_content=$(cat "$PLAN_DOC" 2>/dev/null || echo "")
            IFS=',' read -ra completed_arr <<< "$COMPLETED_TASKS"
            for ct in "${completed_arr[@]}"; do
                ct=$(echo "$ct" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                # Find the task block and check its TDD Required field
                local task_tdd
                task_tdd=$(echo "$plan_content" | \
                    sed -n "/^####.*Task ${ct}:/,/^####/p" | \
                    grep -i 'TDD Required' | head -1 | \
                    sed 's/.*\*\*:[[:space:]]*//' | tr -d '[:space:]')
                if [[ "$task_tdd" == "yes" ]]; then
                    tdd_req="yes"
                    break
                fi
            done
        else
            tdd_req=$(echo "$plan_info" | jq -r '.next_task_config.tdd_required // ""' 2>/dev/null || echo "")
        fi
    fi

    if [[ "$tdd_req" == "no" ]] || [[ -z "$tdd_req" ]]; then
        return 0
    fi

    local staged_files
    staged_files=$(git diff --cached --name-only 2>/dev/null || echo "")

    local prod_files=()
    local test_files=()
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        # Classify as test file
        if [[ "$f" == tests/* ]] || [[ "$f" == */tests/* ]] || [[ "$f" == test_* ]] || \
           [[ "$f" =~ _test\. ]] || [[ "$f" =~ \.test\. ]] || [[ "$f" =~ \.spec\. ]] || \
           [[ "$f" == *.bats ]] || [[ "$f" =~ ^test-.*\.(sh|bats|py|ts|js)$ ]]; then
            test_files+=("$f")
            continue
        fi
        # Skip non-production files (config, docs, infrastructure)
        if [[ "$f" == *.md ]] || [[ "$f" == *.yaml ]] || [[ "$f" == *.yml ]] || \
           [[ "$f" == *.json ]] || [[ "$f" == *.toml ]] || [[ "$f" == commands/* ]] || \
           [[ "$f" == docs/* ]] || [[ "$f" == .current-task ]] || \
           [[ "$f" == *Dockerfile* ]] || [[ "$f" == *.dockerignore ]] || \
           [[ "$f" == *.env* ]] || [[ "$f" == .gitignore ]]; then
            continue
        fi
        prod_files+=("$f")
    done <<< "$staged_files"

    if [[ ${#prod_files[@]} -gt 0 ]] && [[ ${#test_files[@]} -eq 0 ]]; then
        if [[ "$tdd_req" == "yes" ]] || [[ "$tdd_req" == "recommend" ]]; then
            local prod_list
            prod_list=$(printf '%s\n' "${prod_files[@]}" | jq -R . | jq -sc .)
            log_json "{\"status\":\"blocked\",\"next_action\":\"write_test_first\",\"message\":\"Production files staged without tests — write a failing test first\",\"production_files\":$prod_list}"
            exit 1
        fi
    fi
    return 0
}

# Section 6: Update plan, commit changes, update index
section_commit() {
    print_header "Committing Changes"

    # Update plan document if it exists and we have progress flags
    if [[ -n "$PLAN_DOC" ]] && [[ -f "$PLAN_DOC" ]]; then
        log "${BLUE}ℹ${NC} Updating plan document..."

        local progress_args=("--json")

        if [[ -n "$PLAN_DOC" ]]; then
            progress_args+=("--file" "$PLAN_DOC")
        fi

        if [[ -n "$COMPLETED_TASKS" ]]; then
            # Split on comma and add each as separate --mark-complete
            IFS=',' read -ra tasks <<< "$COMPLETED_TASKS"
            for task in "${tasks[@]}"; do
                progress_args+=("--mark-complete" "$(echo "$task" | xargs)")
            done
        fi

        if [[ -n "$ACTUAL_TIME" ]]; then
            progress_args+=("--actual-time" "$ACTUAL_TIME")
        fi

        if [[ -n "$PROGRESS_NOTE" ]]; then
            progress_args+=("--progress" "$PROGRESS_NOTE")
        fi

        if [[ -n "$LESSONS" ]]; then
            progress_args+=("--lessons" "$LESSONS")
        fi

        if [[ -n "$TASK_LABEL" ]]; then
            progress_args+=("--task-label" "$TASK_LABEL")
        fi

        if [[ -n "$WENT_WELL" ]]; then
            progress_args+=("--went-well" "$WENT_WELL")
        fi

        if [[ -n "$CHALLENGES_NOTE" ]]; then
            progress_args+=("--challenges" "$CHALLENGES_NOTE")
        fi

        if [[ -n "$DO_DIFFERENTLY" ]]; then
            progress_args+=("--differently" "$DO_DIFFERENTLY")
        fi

        if [[ -n "$PATTERNS" ]]; then
            progress_args+=("--patterns" "$PATTERNS")
        fi

        local pp_rc=0
        "${SCRIPT_DIR}/plan-progress.sh" "${progress_args[@]}" >/dev/null 2>&1 || pp_rc=$?
        if [[ $pp_rc -eq 0 ]]; then
            PLAN_UPDATED=true
            log "${GREEN}✓${NC} Plan updated"
        else
            # Don't abort — plan-progress.sh failing is usually benign (nothing
            # to advance, old format, etc.) and commits should still proceed.
            # But track the actual result so the output JSON doesn't falsely
            # claim plan_updated:true.
            PLAN_UPDATED=false
            log "${YELLOW}⚠${NC} plan-progress.sh returned $pp_rc — continuing without plan update"
        fi
    fi

    # Stage changed files. Previously this used
    #   git status --porcelain | awk '{print $2}' | xargs git add --
    # which mishandles renames ("R old -> new" parsed as two paths), filenames
    # with spaces (split on whitespace), and quoted paths. Use NUL-delimited
    # porcelain output plus xargs -0 so every path is unambiguous.
    if [[ -z "$(git status --porcelain)" ]]; then
        exit_with_json "success" "Nothing to commit - working tree clean"
    fi

    # Stage tracked modifications/deletions, then add untracked paths
    # individually so renames and spaces survive.
    git add -u
    git status -z --porcelain | awk -v RS='\0' '/^\?\? / { sub(/^\?\? /, ""); printf "%s\0", $0 }' \
        | xargs -0 -r git add --

    check_tdd_compliance

    # Get list of staged files for the commit message
    CHANGED_FILES=$(git diff --cached --name-only | head -20 || echo "")
    local changed_count
    changed_count=$(echo "$CHANGED_FILES" | grep -c . 2>/dev/null || true)
    [[ -z "$changed_count" ]] && changed_count=0

    # Build commit message
    local commit_subject
    if [[ -n "$PROGRESS_NOTE" ]]; then
        # Use progress note as basis for commit message (truncate to 72 chars)
        commit_subject=$(echo "$PROGRESS_NOTE" | head -1 | cut -c1-72)
    else
        commit_subject="feat(task-${TASK_ID}): continue work on ${TASK_TITLE}"
    fi

    local commit_body=""
    if [[ -n "$COMPLETED_TASKS" ]]; then
        commit_body="${commit_body}Completed: ${COMPLETED_TASKS}\n"
    fi
    if [[ -n "$LESSONS" ]]; then
        commit_body="${commit_body}Lessons: ${LESSONS}\n"
    fi
    commit_body="${commit_body}\nRefs #${TASK_ID}"

    if git commit -m "$(printf '%s\n\n%b' "$commit_subject" "$commit_body")" >/dev/null 2>&1; then
        COMMIT_HASH=$(git rev-parse --short HEAD)
        log "${GREEN}✓${NC} Changes committed: $COMMIT_HASH"
    else
        exit_with_json "error" "Failed to commit changes" "git commit failed"
    fi

    # Document index regeneration intentionally skipped during task-continue.
    # `update-docs.sh` walks the doc tree and is O(N) bash regex — on repos with
    # hundreds of docs it takes minutes per commit. The index files are
    # auto-regenerated bookkeeping and don't need to be current after every
    # task-continue commit. Regen runs at /task-close, or invoke explicitly:
    #   ~/.claude/scripts/update-docs.sh

    if [[ "$SECTION" == "commit" ]]; then
        local tdd_warning_field=""
        [[ -n "$TDD_WARNING" ]] && tdd_warning_field=",\"tdd_warning\":\"$TDD_WARNING\""
        exit_with_json "success" "Changes committed" "" \
            "\"commit_hash\":\"$COMMIT_HASH\",\"files_changed\":$changed_count,\"task_id\":\"$TASK_ID\",\"plan_updated\":$PLAN_UPDATED$tdd_warning_field"
    fi
}

#------------------------------------------------------------------------------
# Full Section: Return context for LLM to determine next work
#------------------------------------------------------------------------------

section_full() {
    # Gather context for the LLM to work with

    # Recent commits on this branch
    local recent_commits
    recent_commits=$(git log --oneline -5 2>/dev/null | jq -R . | jq -s . 2>/dev/null || echo '[]')

    # Changed files (uncommitted)
    local uncommitted_count
    uncommitted_count=$(git status --porcelain | wc -l | tr -d ' ')

    # Plan context
    local plan_info="null"
    if [[ -n "$PLAN_DOC" ]] && [[ -f "$PLAN_DOC" ]]; then
        # Use plan-progress.sh to get structured plan state
        plan_info=$("${SCRIPT_DIR}/plan-progress.sh" --json --file "$PLAN_DOC" 2>/dev/null || echo "null")
    fi

    # Testing info from PROJECT.yaml
    local has_tests=false
    local test_scope="task"
    if [[ -f "PROJECT.yaml" ]]; then
        local tc
        tc=$(yaml_get '.testing.command' PROJECT.yaml)
        if [[ -n "$tc" ]] && [[ "$tc" != "null" ]]; then
            has_tests=true
        fi
        local ts
        ts=$(yaml_get '.testing.scope' PROJECT.yaml)
        if [[ -n "$ts" ]] && [[ "$ts" != "null" ]]; then
            test_scope="$ts"
        fi
    fi

    # Work/test agent and review config from per-task config (falls back to doc-level)
    local work_agent="opus"
    local test_agent="sonnet"
    local review_type="single"
    local fresh_context="no"
    local auto_review="no"
    local tdd_required="no"

    # Per-task config from plan-progress.sh (always returns defaults even for old PLNs)
    if [[ "$plan_info" != "null" ]]; then
        local ntc_work ntc_test ntc_review ntc_fresh ntc_auto ntc_tdd
        read -r ntc_work ntc_test ntc_review ntc_fresh ntc_auto ntc_tdd < <(
            echo "$plan_info" | jq -r '[
                .next_task_config.work_model // "",
                .next_task_config.test_model // "",
                .next_task_config.review_type // "",
                .next_task_config.fresh_context // "",
                .next_task_config.auto_review // "",
                .next_task_config.tdd_required // ""
            ] | join(" ")' 2>/dev/null
        )
        [[ -n "$ntc_work" ]] && work_agent="$ntc_work"
        [[ -n "$ntc_test" && "$ntc_test" != "n/a" ]] && test_agent="$ntc_test"
        [[ -n "$ntc_review" ]] && review_type="$ntc_review"
        [[ -n "$ntc_fresh" ]] && fresh_context="$ntc_fresh"
        [[ -n "$ntc_auto" ]] && auto_review="$ntc_auto"
        [[ -n "$ntc_tdd" ]] && tdd_required="$ntc_tdd"
    fi

    # Last-resort fallback: doc-level ## Work Agent / ## Test Agent headers.
    # Only triggers when plan_info is null (no plan found) — plan-progress.sh
    # returns defaults (work_model=sonnet) even for old flat-checklist PLNs,
    # so these headers are bypassed when any plan exists.
    if [[ "$work_agent" == "opus" ]] && [[ -n "$PLAN_DOC" ]] && [[ -f "$PLAN_DOC" ]]; then
        local wa
        wa=$(grep -i "work.agent" "$PLAN_DOC" | head -1 | grep -oE '(haiku|sonnet|opus)' || echo "")
        if [[ -n "$wa" ]]; then work_agent="$wa"; fi
    fi
    if [[ "$test_agent" == "sonnet" ]] && [[ -n "$PLAN_DOC" ]] && [[ -f "$PLAN_DOC" ]]; then
        local ta
        ta=$(grep -i "test.agent" "$PLAN_DOC" | head -1 | grep -oE '(haiku|sonnet|opus)' || echo "")
        if [[ -n "$ta" ]]; then test_agent="$ta"; fi
    fi

    local json=$(cat <<EOF
{
  "status": "success",
  "next_action": "display_summary",
  "section": "full",
  "message": "Task context loaded - ready for work",
  "task_id": "$TASK_ID",
  "task_title": "$TASK_TITLE",
  "task_doc": "$TASK_DOC",
  "task_type": "$TASK_TYPE",
  "branch": "$CURRENT_BRANCH",
  "plan_doc": $([ -n "$PLAN_DOC" ] && echo "\"$PLAN_DOC\"" || echo "null"),
  "work_agent": "$work_agent",
  "test_agent": "$test_agent",
  "review_type": "$review_type",
  "fresh_context": "$fresh_context",
  "auto_review": "$auto_review",
  "tdd_required": "$tdd_required",
  "testing": {
    "has_tests": $has_tests,
    "scope": "$test_scope"
  },
  "recent_commits": $recent_commits,
  "uncommitted_changes": $uncommitted_count,
  "plan_context": $plan_info,
  "timestamp": "$(date -Iseconds)"
}
EOF
)
    log_json "$json"
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
            --identify) SECTION="identify"; shift ;;
            --verify-branch) SECTION="verify-branch"; shift ;;
            --run-tests) SECTION="run-tests"; shift ;;
            --gather) SECTION="gather"; shift ;;
            --commit) SECTION="commit"; shift ;;
            --full) SECTION="full"; shift ;;
            --completed-tasks) COMPLETED_TASKS="$2"; shift 2 ;;
            --actual-time) ACTUAL_TIME="$2"; shift 2 ;;
            --lessons) LESSONS="$2"; shift 2 ;;
            --progress-note) PROGRESS_NOTE="$2"; shift 2 ;;
            --task-label) TASK_LABEL="$2"; shift 2 ;;
            --went-well) WENT_WELL="$2"; shift 2 ;;
            --challenges) CHALLENGES_NOTE="$2"; shift 2 ;;
            --differently) DO_DIFFERENTLY="$2"; shift 2 ;;
            --patterns) PATTERNS="$2"; shift 2 ;;
            --task-id) INPUT_ARG="$2"; shift 2 ;;
            -h|--help)
                echo "Usage: $0 [--json|--raw] [--full|--section] [--task-id <id>]" >&2
                exit 0
                ;;
            *) echo "Unknown option: $1" >&2; exit 2 ;;
        esac
    done

    # Execute sections based on flag
    case "$SECTION" in
        identify)
            section_identify
            ;;
        verify-branch)
            section_identify
            section_verify_branch
            ;;
        run-tests)
            section_identify
            section_verify_branch
            section_run_tests
            ;;
        gather)
            section_identify
            section_verify_branch
            section_find_plan
            section_gather
            ;;
        commit)
            section_identify
            section_verify_branch
            section_find_plan
            section_commit
            ;;
        full)
            section_identify
            section_verify_branch
            section_find_plan
            section_full
            ;;
    esac
}

main "$@"
