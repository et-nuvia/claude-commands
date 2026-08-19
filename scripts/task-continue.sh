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
#   --json: Structured output for LLM, default (TOON when the caller is an AI agent, JSON otherwise)
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
#   --actual-time "15m"                Set actual time; applied to every task in
#                                       --completed-tasks. Keyed form
#                                       ("1.1=45m,1.2=1h") still works for split values.
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
# Optional caller-supplied stage list (--files "a,b" or newline-separated). Empty =
# stage every changed path in the tree (the historical behaviour).
COMMIT_FILES=""
TASK_TYPE=""
ASANA_GID=""

# Test state
TEST_COMMAND=""
TEST_PASSED=false
COVERAGE_PERCENT="0"
TASK_COVERAGE_PERCENT="0"
MIN_COVERAGE="80"

# Targeted-test scope (mid-task validation runs the NARROWEST relevant tests;
# the full suite + coverage is deferred to /task-audit). Callers may pass these
# explicitly; otherwise the command is auto-derived from the changed files.
TEST_TARGET=""   # explicit make target, e.g. test-backend-unit
TEST_FILES=""    # forwarded as FILES="..."
TEST_FILTER=""   # forwarded as FILTER="..."

# Progress state
CHANGED_FILES=""
COMMIT_HASH=""

# Execution mode for --full: single | all | phase
# - single: do one next work item (default, legacy behavior)
# - all:    loop through every remaining item across all phases
# - phase:  loop through the remaining items in the current incomplete phase
EXECUTION_MODE="single"

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
    DEFAULT_BRANCH=$(get_default_branch_interactive)

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

    # Pull latest changes — only for the full context-load path. run-tests/
    # gather/commit call this section too but re-syncing with origin on every
    # one of those calls is unnecessary network I/O and can silently rewrite
    # the branch mid-loop; full load (start of a session) is the right place.
    if [[ "$SECTION" == "full" ]] || [[ "$SECTION" == "verify-branch" ]]; then
        git fetch origin >/dev/null 2>&1 || true
        git pull origin "$CURRENT_BRANCH" >/dev/null 2>&1 || true
    fi

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
    # newest_doc, not `head -1`: find_by_id emits paths in directory order, so a task
    # with two PLNs would load the OLDEST one — and --commit marks completions in
    # whatever this resolves to. See newest_doc in doc-utils.sh.
    PLAN_DOC=$(echo "$all_docs" | grep -- "-PLN-" | newest_doc || true)

    if [[ -z "$PLAN_DOC" ]]; then
        log "${YELLOW}⚠${NC} No plan document found for task ID $TASK_ID"
    else
        log "${GREEN}✓${NC} Plan: $(basename "$PLAN_DOC")"
    fi
}

# Section 4: Run tests and validate coverage
# Build a TARGETED test command for mid-task validation.
#
# Philosophy: /task-continue runs the NARROWEST relevant tests between work items
# so the edit→test→commit loop stays fast. The FULL suite (all services, e2e) and
# coverage validation are deferred to /task-audit at the end of the task. Running
# the whole suite after every subtask is the slowness this deliberately avoids.
#
# Priority:
#   1. Explicit --test-target (+ optional --test-files / --test-filter) from caller
#   2. Auto-derived per-service unit target(s) for the dir(s) that changed
#   3. Generic project-wide unit target (test-unit) if present
#   4. (caller falls back to the project/full command only as a last resort)
#
# Echoes the command on stdout, or empty string if nothing targeted could be derived.
build_targeted_test_command() {
    local available="$1"   # comma-separated make target names

    local files_filter=""
    [[ -n "$TEST_FILES" ]]  && files_filter+=" FILES=\"${TEST_FILES}\""
    [[ -n "$TEST_FILTER" ]] && files_filter+=" FILTER=\"${TEST_FILTER}\""

    # 1. Explicit caller-provided target
    if [[ -n "$TEST_TARGET" ]]; then
        echo "make ${TEST_TARGET} FORMAT=json${files_filter}"
        return 0
    fi

    [[ -f "Makefile" ]] || { echo ""; return 1; }

    # 2. Auto-derive from the top-level service dirs that have changed source files
    local changed_dirs
    changed_dirs=$( { git diff --name-only HEAD 2>/dev/null; \
                      git diff --name-only --cached 2>/dev/null; \
                      git ls-files --others --exclude-standard 2>/dev/null; } \
        | grep -E '\.(js|jsx|ts|tsx|py|go|rb|php|rs|java|c|cpp|h|cs)$' 2>/dev/null \
        | cut -d/ -f1 | sort -u || echo "" )

    local targets=""
    local dir
    for dir in $changed_dirs; do
        if [[ ",$available," == *",test-${dir}-unit,"* ]]; then
            targets+=" test-${dir}-unit"
        elif [[ ",$available," == *",test-${dir},"* ]]; then
            targets+=" test-${dir}"
        fi
    done
    targets=$(echo "$targets" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

    if [[ -n "$targets" ]]; then
        echo "make ${targets} FORMAT=json${files_filter}"
        return 0
    fi

    # 3. Generic project-wide unit target
    if [[ ",$available," == *",test-unit,"* ]]; then
        echo "make test-unit FORMAT=json${files_filter}"
        return 0
    fi

    echo ""
    return 1
}

section_run_tests() {
    print_header "Running Tests (targeted)"

    local min_coverage="80"
    local project_command=""

    # Load config from PROJECT.yaml if available. NOTE: testing.command is the
    # FULL-suite command — it is only a last-resort fallback here, NOT the primary
    # mid-task command. /task-audit is what runs testing.command + coverage.
    if [[ -f "PROJECT.yaml" ]]; then
        project_command=$(yaml_get '.testing.command' PROJECT.yaml)
        min_coverage=$(yaml_get_default '.testing.min_coverage' '80' PROJECT.yaml)
        [[ "$min_coverage" == "null" ]] && min_coverage="80"
    fi

    # Discover available Make test targets (also surfaced to the LLM)
    local available_targets=""
    if [[ -f "Makefile" ]]; then
        available_targets=$(grep -oE '^test[-a-zA-Z]*:' Makefile | sed 's/://' | tr '\n' ',' | sed 's/,$//' || echo "")
    fi

    # 1-3. Prefer a targeted command scoped to what changed
    local test_scope="targeted"
    TEST_COMMAND=$(build_targeted_test_command "$available_targets" || true)

    # If no targeted scope was derived, decide between skipping (nothing source-level
    # changed) and falling back to a broader command (source changed but unmapped).
    if [[ -z "$TEST_COMMAND" ]] || [[ "$TEST_COMMAND" == "null" ]]; then
        if [[ -z "$TEST_TARGET" ]]; then
            local changed_source_count
            changed_source_count=$( { git diff --name-only HEAD 2>/dev/null; \
                                      git diff --name-only --cached 2>/dev/null; \
                                      git ls-files --others --exclude-standard 2>/dev/null; } \
                | grep -cE '\.(js|jsx|ts|tsx|py|go|rb|php|rs|java|c|cpp|h|cs)$' 2>/dev/null || true )
            changed_source_count=${changed_source_count:-0}
            if [[ "$changed_source_count" -eq 0 ]]; then
                log "${BLUE}ℹ${NC} No source files changed — skipping tests (docs/config only)"
                TEST_PASSED=true
                if [[ "$SECTION" == "run-tests" ]]; then
                    exit_with_json "success" "No source changes - tests skipped" "" \
                        "\"tests_skipped\":true,\"reason\":\"no_source_changes\",\"test_scope\":\"skipped\""
                fi
                return
            fi
        fi
    fi

    # 4. Last-resort fallback (may be the full suite) when source changed but unmapped
    if [[ -z "$TEST_COMMAND" ]] || [[ "$TEST_COMMAND" == "null" ]]; then
        test_scope="fallback"
        if [[ -n "$project_command" ]] && [[ "$project_command" != "null" ]]; then
            TEST_COMMAND="$project_command"
        elif [[ -f "Makefile" ]] && grep -q "^test:" Makefile; then
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
        log "${YELLOW}ℹ${NC} No targeted scope derived — falling back to broader command"
    fi

    if [[ "$test_scope" == "targeted" ]]; then
        log "${BLUE}ℹ${NC} Targeted test command: $TEST_COMMAND"
    else
        log "${BLUE}ℹ${NC} Using test command: $TEST_COMMAND"
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
  "test_scope": "$test_scope",
  "available_targets": "$available_targets",
  "passed": $passed,
  "failed": $failed,
  "skipped": $skipped,
  "failures": $failures_json,
  "services": $services_json,
  "next_steps": [
    "Read failures array to identify what broke",
    "Re-run just the failing file/test: task-continue.sh --json --run-tests --test-target <target> --test-files \"<file>\" --task-id $INPUT_ARG",
    "Fix the failing tests",
    "Full suite + coverage run later via /task-audit — do NOT run it here"
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
  "test_scope": "$test_scope",
  "available_targets": "$available_targets",
  "test_output": $output_escaped,
  "next_steps": [
    "Fix the failing tests",
    "Re-run just the failing scope: task-continue.sh --json --run-tests --test-target <target> --task-id $INPUT_ARG"
  ],
  "timestamp": "$(date -Iseconds)"
}
EOF
                exit 1
            fi
        fi
    fi

    # Coverage validation is intentionally NOT run here. min_coverage is governed by
    # PROJECT.yaml (validated by the project-config schema) and enforced by /task-audit,
    # which runs the full suite + coverage_command at end of task. Running coverage after
    # every subtask is exactly the slowness this targeted path avoids.
    log "${BLUE}ℹ${NC} Coverage deferred to /task-audit (full-suite validation)"

    if [[ "$SECTION" == "run-tests" ]]; then
        exit_with_json "success" "Targeted tests passed" "" \
            "\"tests_passing\":true,\"test_scope\":\"${test_scope}\",\"test_command\":\"$TEST_COMMAND\",\"available_targets\":\"$available_targets\",\"coverage_note\":\"deferred to /task-audit\""
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
        # plan-progress.sh renders TOON for AI callers (CLAUDECODE set); convert to
        # JSON so the jq parsing below works regardless of the emitted format.
        plan_info=$("${SCRIPT_DIR}/plan-progress.sh" --json --file "$PLAN_DOC" 2>/dev/null | python3 "${SCRIPT_DIR}/lib/toon2json.py" 2>/dev/null || echo "null")

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
                progress_args+=("--mark-complete" "$(echo "$task" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')")
            done
        fi

        if [[ -n "$ACTUAL_TIME" ]]; then
            # plan-progress.sh expects keyed pairs ("1.1=15m,1.2=30m"). The /task-continue
            # contract accepts a bare value like "15m" — translate by attaching it to each
            # task listed in --completed-tasks. Already-keyed values pass through unchanged.
            local actual_time_arg="$ACTUAL_TIME"
            if [[ "$ACTUAL_TIME" != *"="* ]]; then
                if [[ -n "$COMPLETED_TASKS" ]]; then
                    local _at_keyed=""
                    IFS=',' read -ra _at_tasks <<< "$COMPLETED_TASKS"
                    for _at_task in "${_at_tasks[@]}"; do
                        _at_task=$(echo "$_at_task" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
                        [[ -z "$_at_task" ]] && continue
                        if [[ -z "$_at_keyed" ]]; then
                            _at_keyed="${_at_task}=${ACTUAL_TIME}"
                        else
                            _at_keyed="${_at_keyed},${_at_task}=${ACTUAL_TIME}"
                        fi
                    done
                    [[ -n "$_at_keyed" ]] && actual_time_arg="$_at_keyed"
                else
                    log "${YELLOW}⚠${NC} --actual-time given without --completed-tasks; PLN won't be updated"
                fi
            fi
            progress_args+=("--actual-time" "$actual_time_arg")
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

        # Do NOT silence this call. When it fails, the completed item never
        # gets marked in the PLN, so the next loop iteration re-loads the SAME
        # next_items[0] and re-does or re-verifies finished work. Failing loudly
        # here is what halts the loop instead of letting it spin.
        local plan_update_output plan_update_rc=0
        plan_update_output=$("${SCRIPT_DIR}/plan-progress.sh" "${progress_args[@]}" 2>&1) || plan_update_rc=$?
        if [[ $plan_update_rc -ne 0 ]]; then
            PLAN_UPDATED=false
            log "${RED}✗${NC} Plan update FAILED (exit ${plan_update_rc})"
            exit_with_json "error" \
                "Plan update failed — PLN not marked complete; commit aborted" \
                "plan-progress.sh exit ${plan_update_rc}: $(echo "$plan_update_output" | head -5 | tr '\n' ' ' | cut -c1-300)"
        fi
        PLAN_UPDATED=true
        log "${GREEN}✓${NC} Plan updated"
    fi

    # Stage changed files.
    #
    # NOTE ON SCOPE: with no --files, the list below is derived from the WHOLE
    # `git status --porcelain`, so this stages every changed path in the tree — it is
    # `git add -A` with extra steps, not a narrow stage. That breaks the one-commit-
    # per-subtask checkpoint the /task-continue loop relies on: after a parallel
    # dispatch, several finished subtasks coexist in the tree and the first commit
    # swallows all of them (it also sweeps in another session's concurrent edits when
    # two sessions share a checkout). Callers that know which paths belong to the
    # subtask should pass `--files "path1,path2"` to stage exactly those.
    #
    # Rename-aware: `git status --porcelain` renders a rename as
    #   "R  old -> new"  (or "RM old -> new")
    # The old naive `awk '{print $2}'` grabbed the OLD path; since `git mv`
    # already removed it from the worktree, `git add -- <old>` fatals with
    # "pathspec did not match" and aborts the commit. We strip the 3-char status
    # prefix and, for rename lines, keep ONLY the new (right) path — the old
    # path's deletion is already staged by `git mv`, so re-adding it is both
    # unnecessary and the source of the fatal. (A plain `mv` instead surfaces the
    # old path as its own " D old" line, which stays a valid `git add` target.)
    # `git add -A -- <paths>` then records the rename and handles deletions.
    local files_to_stage
    if [[ -n "$COMMIT_FILES" ]]; then
        # Caller named the paths: accept comma- or newline-separated, trim blanks.
        files_to_stage=$(echo "$COMMIT_FILES" | tr ',' '\n' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e '/^$/d')
        if [[ -z "$files_to_stage" ]]; then
            exit_with_json "error" "--files was passed but resolved to no paths" \
                "Supply comma- or newline-separated paths relative to the repo root"
        fi
        # Fail loudly on a path that has no change — a typo'd path would otherwise
        # commit silently without the work the caller believed they were recording.
        local _missing=""
        while IFS= read -r _cf; do
            [[ -n "$_cf" ]] || continue
            if ! git status --porcelain -- "$_cf" | grep -q .; then
                _missing="${_missing}${_cf} "
            fi
        done <<< "$files_to_stage"
        if [[ -n "$_missing" ]]; then
            exit_with_json "error" "--files named path(s) with no pending change" \
                "No git status entry for: ${_missing% }"
        fi
    else
        files_to_stage=$(git status --porcelain | sed -e 's/^...//' -e 's/^.* -> //')
    fi

    if [[ -z "$files_to_stage" ]]; then
        exit_with_json "success" "Nothing to commit - working tree clean"
    fi

    # Line-by-line into an array so paths with spaces survive (xargs split them).
    local -a stage_paths=()
    while IFS= read -r _stage_path; do
        [[ -n "$_stage_path" ]] && stage_paths+=("$_stage_path")
    done <<< "$files_to_stage"
    git add -A -- "${stage_paths[@]}"

    check_tdd_compliance

    # Full staged count — the old `| head -20` silently capped files_changed
    # at 20 for large commits.
    local changed_count
    changed_count=$(git diff --cached --name-only | grep -c . 2>/dev/null || true)
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

        # Return the POST-commit plan state so loop callers can take the next
        # item straight from this response instead of re-running --full — one
        # fewer script call and model round-trip per iteration. This satisfies
        # the "re-load the PLN fresh every iteration" rule: the state below is
        # parsed from the PLN as it exists after this commit mutated it.
        local next_plan_context="null"
        if [[ -n "$PLAN_DOC" ]] && [[ -f "$PLAN_DOC" ]]; then
            next_plan_context=$("${SCRIPT_DIR}/plan-progress.sh" --json --file "$PLAN_DOC" 2>/dev/null \
                | python3 "${SCRIPT_DIR}/lib/toon2json.py" 2>/dev/null || echo "null")
            [[ -z "$next_plan_context" ]] && next_plan_context="null"
        fi

        exit_with_json "success" "Changes committed" "" \
            "\"commit_hash\":\"$COMMIT_HASH\",\"files_changed\":$changed_count,\"task_id\":\"$TASK_ID\",\"plan_updated\":${PLAN_UPDATED:-false},\"plan_context\":$next_plan_context$tdd_warning_field"
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
        # plan-progress.sh renders TOON for AI callers (CLAUDECODE set); convert to
        # JSON so the jq parsing below works regardless of the emitted format.
        plan_info=$("${SCRIPT_DIR}/plan-progress.sh" --json --file "$PLAN_DOC" 2>/dev/null | python3 "${SCRIPT_DIR}/lib/toon2json.py" 2>/dev/null || echo "null")
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
    local work_agent="sonnet"
    local test_agent="sonnet"
    local review_type="single"
    local fresh_context="no"
    local auto_review="no"
    local tdd_required="no"
    # Tracks whether work_agent/test_agent were set from config (per-task or
    # doc-level) so the doc-level header fallback below only fires when
    # nothing has explicitly configured a model — distinguishing an explicit
    # "opus" from the untouched default.
    local work_agent_source="default"
    local test_agent_source="default"

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
        if [[ -n "$ntc_work" ]]; then work_agent="$ntc_work"; work_agent_source="config"; fi
        if [[ -n "$ntc_test" && "$ntc_test" != "n/a" ]]; then test_agent="$ntc_test"; test_agent_source="config"; fi
        [[ -n "$ntc_review" ]] && review_type="$ntc_review"
        [[ -n "$ntc_fresh" ]] && fresh_context="$ntc_fresh"
        [[ -n "$ntc_auto" ]] && auto_review="$ntc_auto"
        [[ -n "$ntc_tdd" ]] && tdd_required="$ntc_tdd"
    fi

    # Last-resort fallback: doc-level ## Work Agent / ## Test Agent headers.
    # Only triggers when no config (per-task or plan_info) already set the
    # model — plan_info returning a config value means it should win even if
    # that value happens to be "opus".
    if [[ "$work_agent_source" == "default" ]] && [[ -n "$PLAN_DOC" ]] && [[ -f "$PLAN_DOC" ]]; then
        local wa
        wa=$(grep -i "work.agent" "$PLAN_DOC" | head -1 | grep -oE '(haiku|sonnet|opus)' || echo "")
        if [[ -n "$wa" ]]; then work_agent="$wa"; fi
    fi
    if [[ "$test_agent_source" == "default" ]] && [[ -n "$PLAN_DOC" ]] && [[ -f "$PLAN_DOC" ]]; then
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
  "worktree_dir": "$(pwd)",
  "plan_doc": $([ -n "$PLAN_DOC" ] && echo "\"$PLAN_DOC\"" || echo "null"),
  "execution_mode": "$EXECUTION_MODE",
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
            --test-target) TEST_TARGET="$2"; shift 2 ;;
            --test-files) TEST_FILES="$2"; shift 2 ;;
            --test-filter) TEST_FILTER="$2"; shift 2 ;;
            --gather) SECTION="gather"; shift ;;
            --commit) SECTION="commit"; shift ;;
            --full) SECTION="full"; shift ;;
            --mode)
                case "$2" in
                    single|all|phase) EXECUTION_MODE="$2" ;;
                    *) EXECUTION_MODE="single" ;;
                esac
                shift 2 ;;
            --completed-tasks) COMPLETED_TASKS="$2"; shift 2 ;;
            --files) COMMIT_FILES="$2"; shift 2 ;;
            --actual-time) ACTUAL_TIME="$2"; shift 2 ;;
            --lessons) LESSONS="$2"; shift 2 ;;
            --progress-note) PROGRESS_NOTE="$2"; shift 2 ;;
            --task-label) TASK_LABEL="$2"; shift 2 ;;
            --went-well) WENT_WELL="$2"; shift 2 ;;
            --challenges) CHALLENGES_NOTE="$2"; shift 2 ;;
            --differently) DO_DIFFERENTLY="$2"; shift 2 ;;
            --patterns) PATTERNS="$2"; shift 2 ;;
            --task-id) INPUT_ARG="$2"; shift 2 ;;
            --dir) WORK_DIR="$2"; shift 2 ;;
            -h|--help)
                echo "Usage: $0 [--json|--raw] [--full|--section] [--task-id <id>] [--dir <worktree>] [--files <p1,p2>]" >&2
                exit 0
                ;;
            *) echo "Unknown option: $1" >&2; exit 2 ;;
        esac
    done

    # --dir makes every section cwd-independent: the caller never has to cd.
    # Transcript analysis found the same worktree being cd'd into 100+ times in
    # one session (the "cd exactly ONCE" rule decays as context compacts) —
    # each a wasted model round-trip. Passing --dir removes the need entirely.
    if [[ -n "${WORK_DIR:-}" ]]; then
        if [[ ! -d "$WORK_DIR" ]]; then
            exit_with_json "error" "Directory not found: $WORK_DIR" \
                "Pass --dir the worktree path from the --full response's worktree_dir field"
        fi
        cd "$WORK_DIR"
    fi

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
