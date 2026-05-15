#!/usr/bin/env bash
# task-audit.sh - Comprehensive task audit: progress, coverage, impacts
#
# STANDARD SCRIPT PATTERN: Section flags with --json/--raw output modes
#
# Usage:
#   ~/.claude/scripts/task-audit.sh [task_id] [--json|--raw] [--full|--section]
#
# Output Modes:
#   --json: Structured JSON output for LLM (default)
#   --raw:  Verbose debugging output when LLM needs more details
#
# Section Flags (run specific section only):
#   --load:        Load task and validate
#   --analyze:     Analyze work done (commits, files)
#   --test:        Run tests and check coverage
#   --impact:      Analyze project-wide impact
#   --remaining:   Check remaining work (criteria, TODOs)
#   --full:        Run all sections end-to-end (default)
#
# Workflow:
#   1. LLM calls: task-audit.sh --json --full
#   2. Returns comprehensive audit with scores and recommendations
#   3. If more details needed: task-audit.sh --raw --test

set -euo pipefail

# Global variables
OUTPUT_MODE="json"
SECTION="full"
TASK_ID_ARG=""
RE_VERIFY=false  # Set by --re-verify: include previous AUD doc path + prior scores in response

# Source utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/output-framework.sh"
source "${SCRIPT_DIR}/lib/yaml.sh"
source "${SCRIPT_DIR}/doc-utils.sh"
source "${SCRIPT_DIR}/get-default-branch.sh"

# Task data
TASK_ID=""
TASK_DOC=""
TASK_TITLE=""
CURRENT_BRANCH=""
DEFAULT_BRANCH=""

# Test results
TESTS_PASSING=false
TEST_FILE_COUNT=0
COVERAGE_PERCENT="unknown"
MIN_COVERAGE=80
TEST_RESULTS_JSON=""

# Counters
COMMIT_COUNT=0
FILES_COUNT=0
SOURCE_FILES=0
TEST_FILES=0
COVERED_COUNT=0
UNCOVERED_COUNT=0
TOTAL_SOURCE=0
TODO_COUNT=0
PATTERN_COUNT=0
PENDING_CRITERIA=0

# Scores
WORK_SCORE=100
TEST_SCORE=100
IMPACT_SCORE=100
COMPLETION_SCORE=100
OVERALL_SCORE=0

# Lists for JSON output
UNCOVERED_FILES_LIST=""
TODO_LIST=""
PATTERN_LIST=""

# Raw data for AUD document generation
COMMIT_LIST=""
CHANGED_FILES_STATUS=""
CODE_STATS=""
TEST_FILES_LIST_RAW=""

print_header() {
    log ""
    log "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    log "${BLUE}$1${NC}"
    log "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    log ""
}

print_section() {
    log ""
    log "${GREEN}$1${NC}"
    log "────────────────────────────────────────"
}

#------------------------------------------------------------------------------
# Section 1: Load Task
#------------------------------------------------------------------------------

section_load() {
    log "${BLUE}Loading Task${NC}"

    # Try .current-task first
    if [[ -z "$TASK_ID_ARG" ]] && load_current_task; then
        TASK_ID="$CT_TASK_ID"
        CURRENT_BRANCH="$CT_BRANCH"
        log "${GREEN}Found current task: $TASK_ID on branch: $CURRENT_BRANCH${NC}"
    elif [[ -n "$TASK_ID_ARG" ]]; then
        # Parse input as task ID
        if [[ "$TASK_ID_ARG" =~ ^[A-Fa-f0-9]{6}$ ]]; then
            TASK_ID=$(normalize_task_id "$TASK_ID_ARG")
        else
            exit_with_json "error" "Invalid task ID: $TASK_ID_ARG"
        fi
    else
        exit_with_json "error" "No task specified and no .current-task file" \
            "Provide task ID as argument"
    fi

    # Find task document
    TASK_DOC=$(find_primary "$TASK_ID")

    if [[ -z "$TASK_DOC" ]] || [[ ! -f "$TASK_DOC" ]]; then
        exit_with_json "error" "Task document not found for task ID $TASK_ID"
    fi

    # Extract task title
    TASK_TITLE=$(get_doc_title "$TASK_DOC")

    # Get branches
    CURRENT_BRANCH=${CURRENT_BRANCH:-$(git branch --show-current)}
    DEFAULT_BRANCH=$(get_default_branch)

    log ""
    log "${BLUE}Auditing: $TASK_TITLE${NC}"
    log "${BLUE}Task ID: $TASK_ID${NC}"
    log "${BLUE}Branch: $CURRENT_BRANCH${NC}"
    log "${BLUE}Comparing against: $DEFAULT_BRANCH${NC}"

    # If running only this section, return now
    if [[ "$SECTION" == "load" ]]; then
        exit_with_json "success" "Task loaded successfully" "" \
            "\"task_id\": \"$TASK_ID\"," \
            "\"task_title\": \"$TASK_TITLE\"," \
            "\"branch\": \"$CURRENT_BRANCH\""
    fi

    log "${GREEN}✓${NC} Task loaded"
}

#------------------------------------------------------------------------------
# Section 2: Analyze Work Done
#------------------------------------------------------------------------------

section_analyze() {
    print_header "WORK ANALYSIS"

    # Commit history
    print_section "Commits on this branch"
    local commits=$(git log --oneline "${DEFAULT_BRANCH}..${CURRENT_BRANCH}" 2>/dev/null || echo "")

    if [[ -n "$commits" ]]; then
        COMMIT_LIST="$commits"
        echo "$commits" | cat -n | while IFS= read -r line; do
            log "  $line"
        done
        COMMIT_COUNT=$(echo "$commits" | wc -l | tr -d ' ')
    else
        log "  No commits"
        COMMIT_COUNT=0
    fi

    log ""
    log "Total commits: $COMMIT_COUNT"

    # Files changed
    print_section "Files changed"

    local changed_files=$(git diff --name-status "${DEFAULT_BRANCH}...${CURRENT_BRANCH}" 2>/dev/null || echo "")

    if [[ -n "$changed_files" ]]; then
        CHANGED_FILES_STATUS="$changed_files"
        echo "$changed_files" | while IFS=$'\t' read -r status file; do
            case "$status" in
                A) log "  + Added: $file" ;;
                M) log "  ~ Modified: $file" ;;
                D) log "  - Deleted: $file" ;;
                R*) log "  → Renamed: $file" ;;
                *) log "  ? $status: $file" ;;
            esac
        done

        FILES_COUNT=$(echo "$changed_files" | wc -l | tr -d ' ')
        log ""
        log "Total files changed: $FILES_COUNT"

        # Categorize
        SOURCE_FILES=$(echo "$changed_files" | { grep -cE '\.(js|jsx|ts|tsx|py|go|java|rb|php|rs|c|cpp|h|cs|sh|bash|bats)$' || echo 0; })
        TEST_FILES=$(echo "$changed_files" | { grep -cE 'test|spec|__tests__|_test\.go' || echo 0; })
        local config_files=$(echo "$changed_files" | { grep -cE '\.(json|yaml|yml|toml|ini|conf|config)$' || echo 0; })
        local doc_files=$(echo "$changed_files" | { grep -cE '\.(md|txt|rst|adoc)$' || echo 0; })

        log ""
        log "Breakdown by type:"
        log "  Source code: $SOURCE_FILES"
        log "  Tests: $TEST_FILES"
        log "  Configuration: $config_files"
        log "  Documentation: $doc_files"
    else
        log "  No files changed"
    fi

    # Code statistics
    print_section "Code statistics"
    CODE_STATS=$(git diff --stat "${DEFAULT_BRANCH}...${CURRENT_BRANCH}" 2>/dev/null | tail -5 || echo "No changes")
    echo "$CODE_STATS" | while IFS= read -r line; do
        log "$line"
    done

    # If running only this section, return now
    if [[ "$SECTION" == "analyze" ]]; then
        exit_with_json "success" "Work analysis complete" "" \
            "\"commits\": $COMMIT_COUNT," \
            "\"files_changed\": $FILES_COUNT," \
            "\"source_files\": $SOURCE_FILES," \
            "\"test_files\": $TEST_FILES"
    fi

    log "${GREEN}✓${NC} Work analysis complete"
}

#------------------------------------------------------------------------------
# Section 3: Test Coverage Analysis
#------------------------------------------------------------------------------

section_test() {
    print_header "TEST COVERAGE ANALYSIS"

    # Test files modified
    print_section "Test files modified/added"

    local test_files_list=$(git diff --name-only "${DEFAULT_BRANCH}...${CURRENT_BRANCH}" 2>/dev/null | \
        grep -E "test|spec|__tests__|_test\.go" || echo "")

    if [[ -n "$test_files_list" ]]; then
        TEST_FILES_LIST_RAW="$test_files_list"
        echo "$test_files_list" | sed 's/^/  ✓ /' | while IFS= read -r line; do
            log "$line"
        done
        TEST_FILE_COUNT=$(echo "$test_files_list" | wc -l | tr -d ' ')
        log ""
        log "Total test files: $TEST_FILE_COUNT"
    else
        log "${YELLOW}⚠️  WARNING: No test files modified/added${NC}"
        TEST_FILE_COUNT=0
    fi

    # Get test command
    print_section "Running test suite"

    if [[ -f "PROJECT.yaml" ]]; then
        MIN_COVERAGE=$(yaml_get_default '.testing.min_coverage' '80' PROJECT.yaml)
    fi

    # Prefer structured JSON output if available
    if make -n test-unit-json &>/dev/null 2>&1; then
        log "Using: make test-unit-json (structured output)"
        log ""

        local json_output=""
        if json_output=$(make -s test-unit-json 2>/tmp/test-output.txt); then
            TESTS_PASSING=true
        else
            TESTS_PASSING=false
        fi

        # Parse the JSON array to extract totals
        if [[ -n "$json_output" ]] && echo "$json_output" | jq empty 2>/dev/null; then
            TEST_RESULTS_JSON="$json_output"

            # Sum totals across all suites
            local totals
            totals=$(echo "$json_output" | jq '{
                tests_total: ([.[] | .tests_total] | add // 0),
                tests_passed: ([.[] | .tests_passed] | add // 0),
                tests_failed: ([.[] | .tests_failed] | add // 0),
                tests_warned: ([.[] | .tests_warned] | add // 0),
                suites_total: ([.[] | .suites_total] | add // 0),
                suites_passed: ([.[] | .suites_passed] | add // 0),
                suites_failed: ([.[] | .suites_failed] | add // 0),
                failures: [.[] | .failures[]?],
                coverage_percent: ([.[] | .coverage_percent // empty] | first // null)
            }')

            local tests_failed
            tests_failed=$(echo "$totals" | jq '.tests_failed')
            if [[ "$tests_failed" -gt 0 ]]; then
                TESTS_PASSING=false
            fi

            local cov
            cov=$(echo "$totals" | jq -r '.coverage_percent // "unknown"')
            if [[ "$cov" != "null" ]] && [[ "$cov" != "unknown" ]]; then
                COVERAGE_PERCENT="$cov"
            fi

            log "Tests total: $(echo "$totals" | jq '.tests_total')"
            log "Tests passed: $(echo "$totals" | jq '.tests_passed')"
            log "Tests failed: $(echo "$totals" | jq '.tests_failed')"

            if [[ "$TESTS_PASSING" == "true" ]]; then
                log "${GREEN}✅ All tests passing${NC}"
            else
                log "${RED}❌ Tests failing${NC}"
                echo "$totals" | jq -r '.failures[] | "  ✗ \(.suite) > \(.test): \(.message)"' | while IFS= read -r line; do
                    log "$line"
                done
            fi
        else
            log "${YELLOW}⚠️  JSON parse failed, falling back to exit code only${NC}"
            if [[ "$OUTPUT_MODE" == "raw" ]]; then
                tail -20 /tmp/test-output.txt >&2
            fi
        fi
    else
        # Fallback: traditional test commands
        local test_command=""
        local coverage_command=""

        if [[ -f "PROJECT.yaml" ]]; then
            test_command=$(yaml_get '.testing.command' PROJECT.yaml)
            coverage_command=$(yaml_get '.testing.coverage_command' PROJECT.yaml)
        fi

        if [[ -z "$test_command" ]]; then
            if [[ -f "package.json" ]]; then
                test_command="npm test"
                coverage_command="npm run test:coverage"
            elif [[ -f "pyproject.toml" ]] || [[ -f "pytest.ini" ]]; then
                test_command="pytest"
                coverage_command="pytest --cov --cov-report=term-missing"
            elif [[ -f "go.mod" ]]; then
                test_command="go test ./..."
                coverage_command="go test -coverprofile=coverage.out ./... && go tool cover -func=coverage.out"
            elif [[ -f "Cargo.toml" ]]; then
                test_command="cargo test"
                coverage_command="cargo tarpaulin --out Stdout"
            else
                test_command="make test"
            fi
        fi

        log "Test command: $test_command"
        log ""

        if eval "$test_command" &>/tmp/test-output.txt; then
            log "${GREEN}✅ All tests passing${NC}"
            TESTS_PASSING=true
        else
            log "${RED}❌ Tests failing${NC}"
            if [[ "$OUTPUT_MODE" == "raw" ]]; then
                tail -20 /tmp/test-output.txt >&2
            fi
            TESTS_PASSING=false
        fi

        if [[ -n "$coverage_command" ]] && [[ "$TESTS_PASSING" == "true" ]]; then
            print_section "Gathering coverage data"

            if eval "$coverage_command" &>/tmp/coverage-output.txt; then
                if [[ "$OUTPUT_MODE" == "raw" ]]; then
                    cat /tmp/coverage-output.txt >&2
                fi

                COVERAGE_PERCENT=$(grep -oP '\d+(?=%)' /tmp/coverage-output.txt | head -1 || echo "unknown")

                if [[ "$COVERAGE_PERCENT" != "unknown" ]]; then
                    log ""
                    log "Overall project coverage: ${COVERAGE_PERCENT}%"

                    if [[ ${COVERAGE_PERCENT} -ge ${MIN_COVERAGE} ]]; then
                        log "${GREEN}✓ Coverage meets minimum requirement (${MIN_COVERAGE}%)${NC}"
                    else
                        log "${YELLOW}⚠️  Coverage below minimum requirement (${MIN_COVERAGE}%)${NC}"
                    fi
                fi
            fi
        fi
    fi

    # Check coverage for changed files
    print_section "Coverage for changed files"

    local source_files_changed=$(git diff --name-only "${DEFAULT_BRANCH}...${CURRENT_BRANCH}" 2>/dev/null | \
        grep -E '\.(js|jsx|ts|tsx|py|go|java|rb|php|rs|c|cpp|cs|sh|bash)$' | \
        grep -v -E 'test|spec|__tests__|_test\.go' | \
        grep -v -E '^alembic/|/migrations/' | \
        grep -v -E '/models/(enums|__init__)\.py$' | \
        grep -v -E '/models/[a-z_]+\.py$' | \
        grep -v -E '/schemas/[a-z_]+\.py$' | \
        grep -v -E '/router\.py$' | \
        grep -v -E '\.d\.ts$' || echo "")
    # Exclusions rationale:
    #   alembic/migrations — DDL scripts, tested via migration runner not unit tests
    #   models/enums.py, models/__init__.py — pure data definitions, tested indirectly
    #   models/*.py — ORM models, tested indirectly via CRUD/API tests
    #   schemas/*.py — Pydantic models, tested indirectly via API endpoint tests
    #   router.py — route registration, tested indirectly via endpoint tests
    #   .d.ts — TypeScript type declarations, no runtime code

    if [[ -n "$source_files_changed" ]]; then
        local uncovered_files=""

        # Build test file index once (covers all languages)
        local test_file_index
        test_file_index=$(find . -type f \( \
            -name "*.test.*" -o -name "*.spec.*" -o -name "*_test.*" \
            -o -name "*Test.php" -o -name "*Test.java" -o -name "*Tests.cs" \
            -o -name "*_spec.rb" -o -name "test_*.py" \
            -o -name "*.bats" \
            \) ! -path "*/node_modules/*" ! -path "*/.git/*" ! -path "*/vendor/*" \
            ! -path "*/.venv/*" 2>/dev/null || true)

        while IFS= read -r src_file; do
            if [[ -n "$src_file" ]]; then
                local base_name=$(basename "$src_file" | sed -E 's/\.[^.]+$//')

                # Stage A: Name-based regex match against index
                local has_test=false
                if [[ -n "$test_file_index" ]]; then
                    local base_re
                    base_re=$(printf '%s' "$base_name" | sed 's/[.[\*^$()+?{|\\]/\\&/g')
                    if echo "$test_file_index" | grep -qiE "/(test[-_.]?${base_re}|${base_re}[._-]?(test|spec)|${base_re}Test|${base_re}_spec)\."; then
                        has_test=true
                    fi
                fi

                # Stage B: Content-based grep fallback
                if [[ "$has_test" == "false" ]] && [[ -n "$test_file_index" ]]; then
                    local src_basename
                    src_basename=$(basename "$src_file")
                    if echo "$test_file_index" | tr '\n' '\0' | xargs -0 grep -lq "$src_basename" 2>/dev/null; then
                        has_test=true
                    fi
                fi

                if [[ "$has_test" == "true" ]]; then
                    log "  ✓ $src_file (has tests)"
                    COVERED_COUNT=$((COVERED_COUNT + 1))
                else
                    log "${YELLOW}⚠️  $src_file (no obvious test file)${NC}"
                    if [[ -z "$uncovered_files" ]]; then
                        uncovered_files="$src_file"
                    else
                        uncovered_files="${uncovered_files}
${src_file}"
                    fi
                    UNCOVERED_COUNT=$((UNCOVERED_COUNT + 1))
                fi
            fi
        done <<< "$source_files_changed"

        UNCOVERED_FILES_LIST="$uncovered_files"
        TOTAL_SOURCE=$(echo "$source_files_changed" | grep -c . || echo "0")

        log ""
        log "Coverage summary for changed files:"
        log "  Files with tests: $COVERED_COUNT / $TOTAL_SOURCE"
        log "  Files without obvious tests: $UNCOVERED_COUNT / $TOTAL_SOURCE"

        if [[ $UNCOVERED_COUNT -gt 0 ]]; then
            log ""
            log "${YELLOW}⚠️  Files that may need test coverage:${NC}"
            echo "$uncovered_files" | grep -v '^$' | sed 's/^/    - /' | while IFS= read -r line; do
                log "$line"
            done
        fi
    else
        log "  No source files changed"
    fi

    # If running only this section, return now
    if [[ "$SECTION" == "test" ]]; then
        local uncovered_json="[]"
        if [[ -n "$UNCOVERED_FILES_LIST" ]]; then
            uncovered_json=$(echo "$UNCOVERED_FILES_LIST" | jq -R . | jq -s .)
        fi

        local test_results_field=""
        if [[ -n "$TEST_RESULTS_JSON" ]]; then
            test_results_field="\"test_results\": $TEST_RESULTS_JSON,"
        fi

        exit_with_json "success" "Test coverage analysis complete" "" \
            "\"tests_passing\": $TESTS_PASSING," \
            "\"test_file_count\": $TEST_FILE_COUNT," \
            "\"coverage_percent\": \"$COVERAGE_PERCENT\"," \
            "${test_results_field}" \
            "\"covered_files\": $COVERED_COUNT," \
            "\"uncovered_files\": $UNCOVERED_COUNT," \
            "\"uncovered_files_list\": $uncovered_json"
    fi

    log "${GREEN}✓${NC} Test coverage analysis complete"
}

#------------------------------------------------------------------------------
# Section 4: Project-Wide Impact Analysis
#------------------------------------------------------------------------------

section_impact() {
    print_header "PROJECT-WIDE IMPACT ANALYSIS"

    print_section "Analyzing changed symbols"

    local source_files_changed=$(git diff --name-only "${DEFAULT_BRANCH}...${CURRENT_BRANCH}" 2>/dev/null | \
        grep -E '\.(js|jsx|ts|tsx|py|go)$' | \
        grep -v -E 'test|spec|__tests__|_test\.go' || echo "")

    if [[ -n "$source_files_changed" ]]; then
        while IFS= read -r src_file; do
            if [[ -n "$src_file" ]] && [[ -f "$src_file" ]]; then
                log ""
                log "  Analyzing: $src_file"

                # Extract symbols based on file type
                local symbols=""
                case "$src_file" in
                    *.js|*.jsx|*.ts|*.tsx)
                        symbols=$(git diff "${DEFAULT_BRANCH}...${CURRENT_BRANCH}" -- "$src_file" 2>/dev/null | \
                            grep -E '^\+.*(function|class|export )' | \
                            grep -oE '(function|class|const|let|var)\s+[a-zA-Z_][a-zA-Z0-9_]*' | \
                            awk '{print $2}' | sort -u || echo "")
                        ;;
                    *.py)
                        symbols=$(git diff "${DEFAULT_BRANCH}...${CURRENT_BRANCH}" -- "$src_file" 2>/dev/null | \
                            grep -E '^\+\s*(def|class)\s+[a-zA-Z_]' | \
                            sed -E 's/^\+\s*(def|class)\s+([a-zA-Z_][a-zA-Z0-9_]*).*/\2/' | sort -u || echo "")
                        ;;
                    *.go)
                        symbols=$(git diff "${DEFAULT_BRANCH}...${CURRENT_BRANCH}" -- "$src_file" 2>/dev/null | \
                            grep -E '^\+\s*(func|type)\s+[A-Z]' | \
                            sed -E 's/^\+\s*(func|type)\s+([A-Za-z_][A-Za-z0-9_]*).*/\2/' | sort -u || echo "")
                        ;;
                esac

                if [[ -n "$symbols" ]]; then
                    log "    Changed symbols:"
                    echo "$symbols" | sed 's/^/      - /' | while IFS= read -r line; do
                        log "$line"
                    done
                fi
            fi
        done <<< "$source_files_changed"
    fi

    # Check for modified exports
    print_section "Checking import/export consistency"

    local modified_exports=$(git diff "${DEFAULT_BRANCH}...${CURRENT_BRANCH}" 2>/dev/null | \
        grep -E '^\+.*export' | head -10 || echo "")

    if [[ -n "$modified_exports" ]]; then
        log "  Modified exports detected:"
        echo "$modified_exports" | sed 's/^/    /' | while IFS= read -r line; do
            log "$line"
        done
        log ""
        log "${YELLOW}  ⚠️  Verify all imports are updated across the project${NC}"
    else
        log "  No export changes detected"
    fi

    # If running only this section, return now
    if [[ "$SECTION" == "impact" ]]; then
        exit_with_json "success" "Impact analysis complete"
    fi

    log "${GREEN}✓${NC} Impact analysis complete"
}

#------------------------------------------------------------------------------
# Section 5: Check Remaining Work
#------------------------------------------------------------------------------

section_remaining() {
    print_header "REMAINING WORK ANALYSIS"

    # Acceptance criteria — prefer PLN completion if a plan exists
    print_section "Acceptance Criteria Status"

    # Check for PLN document associated with this task
    local pln_doc=""
    local pln_docs_list
    pln_docs_list=$(find_by_id "$TASK_ID" | grep -- "-PLN-" || true)
    if [[ -n "$pln_docs_list" ]]; then
        # Use the most recent PLN (last in sorted list)
        pln_doc=$(echo "$pln_docs_list" | tail -1)
    fi

    if [[ -n "$pln_doc" ]] && [[ -f "$pln_doc" ]]; then
        # PLN exists — use plan completion as the authority
        log "  Using PLN document for completion: $(basename "$pln_doc")"

        local pln_done pln_pending pln_total
        # Count both "- [x]" list items and "#### Task N: [x]" heading items
        pln_done=$(grep -cE '^\s*- \[x\]|^#{1,6}\s.*\[x\]' "$pln_doc" 2>/dev/null || echo "0")
        pln_pending=$(grep -cE '^\s*- \[ \]|^#{1,6}\s.*\[ \]' "$pln_doc" 2>/dev/null || echo "0")
        pln_done=${pln_done//[^0-9]/}
        pln_pending=${pln_pending//[^0-9]/}
        pln_done=${pln_done:-0}
        pln_pending=${pln_pending:-0}
        pln_total=$((pln_done + pln_pending))

        log ""
        log "Plan progress: $pln_done / $pln_total items completed"

        # Also check TSK criteria for informational purposes
        local tsk_criteria
        tsk_criteria=$(grep -A 50 "## Acceptance Criteria\|## Requirements" "$TASK_DOC" 2>/dev/null | \
            grep -E '^\s*-\s*\[[ x]\]' | head -20 || echo "")
        if [[ -n "$tsk_criteria" ]]; then
            local tsk_total tsk_completed
            tsk_total=$(echo "$tsk_criteria" | wc -l | tr -d '[:space:]')
            tsk_completed=$(echo "$tsk_criteria" | grep -c '\[x\]' 2>/dev/null || true)
            tsk_completed=${tsk_completed//[^0-9]/}
            tsk_completed=${tsk_completed:-0}
            tsk_total=${tsk_total:-0}
            log "TSK criteria: $tsk_completed / $tsk_total checked"
        fi

        # Use PLN pending count for scoring
        PENDING_CRITERIA=$pln_pending

        if [[ $pln_pending -gt 0 ]]; then
            log "${YELLOW}⚠️  $pln_pending plan items still pending${NC}"
        else
            log "${GREEN}✓ All plan items complete${NC}"
        fi
    else
        # No PLN — fall back to TSK acceptance criteria
        local criteria
        criteria=$(grep -A 50 "## Acceptance Criteria\|## Requirements" "$TASK_DOC" 2>/dev/null | \
            grep -E '^\s*-\s*\[[ x]\]' | head -20 || echo "")

        if [[ -n "$criteria" ]]; then
            echo "$criteria" | sed 's/^/  /' | while IFS= read -r line; do
                log "$line"
            done

            local total_criteria
            total_criteria=$(echo "$criteria" | wc -l | tr -d '[:space:]')
            local completed_criteria
            completed_criteria=$(echo "$criteria" | grep -c '\[x\]' 2>/dev/null || true)
            completed_criteria=${completed_criteria//[^0-9]/}
            completed_criteria=${completed_criteria:-0}
            total_criteria=${total_criteria:-0}
            PENDING_CRITERIA=$((total_criteria - completed_criteria))

            log ""
            log "Progress: $completed_criteria / $total_criteria criteria completed"

            if [[ $PENDING_CRITERIA -gt 0 ]]; then
                log "${YELLOW}⚠️  $PENDING_CRITERIA criteria still pending${NC}"
            else
                log "${GREEN}✓ All criteria marked as complete${NC}"
            fi
        else
            log "  No acceptance criteria found in task document"
        fi
    fi

    # TODOs
    print_section "TODOs in changed files"

    local todos_in_changes=$(git diff "${DEFAULT_BRANCH}...${CURRENT_BRANCH}" 2>/dev/null | \
        grep -E '^\+.*TODO|^\+.*FIXME|^\+.*XXX|^\+.*HACK' || echo "")

    if [[ -n "$todos_in_changes" ]]; then
        TODO_COUNT=$(echo "$todos_in_changes" | wc -l | tr -d ' ')
        TODO_LIST="$todos_in_changes"
        log "${YELLOW}  ⚠️  Found $TODO_COUNT TODO(s) in changes:${NC}"
        echo "$todos_in_changes" | sed 's/^/    /' | while IFS= read -r line; do
            log "$line"
        done
    else
        log "${GREEN}  ✓ No TODOs found in changes${NC}"
    fi

    # Incomplete patterns
    print_section "Checking for incomplete work patterns"

    local incomplete_patterns=$(git diff "${DEFAULT_BRANCH}...${CURRENT_BRANCH}" 2>/dev/null | \
        grep -E '^\+.*(^|\s|#|//|/\*)(WIP|TEMPORARY|PLACEHOLDER|NOT IMPLEMENTED)(\s|$|:|;|\*/)' || echo "")
    # Also catch "throw new Error" as incomplete work marker
    local throw_patterns=$(git diff "${DEFAULT_BRANCH}...${CURRENT_BRANCH}" 2>/dev/null | \
        grep -E '^\+.*throw new Error' || echo "")
    if [[ -n "$throw_patterns" ]]; then
        if [[ -n "$incomplete_patterns" ]]; then
            incomplete_patterns="${incomplete_patterns}
${throw_patterns}"
        else
            incomplete_patterns="$throw_patterns"
        fi
    fi

    if [[ -n "$incomplete_patterns" ]]; then
        PATTERN_COUNT=$(echo "$incomplete_patterns" | wc -l | tr -d ' ')
        PATTERN_LIST="$incomplete_patterns"
        log "${YELLOW}  ⚠️  Found $PATTERN_COUNT incomplete pattern(s):${NC}"
        echo "$incomplete_patterns" | sed 's/^/    /' | while IFS= read -r line; do
            log "$line"
        done
    else
        log "${GREEN}  ✓ No obvious incomplete patterns found${NC}"
    fi

    # If running only this section, return now
    if [[ "$SECTION" == "remaining" ]]; then
        exit_with_json "success" "Remaining work analysis complete" "" \
            "\"pending_criteria\": $PENDING_CRITERIA," \
            "\"todo_count\": $TODO_COUNT," \
            "\"incomplete_patterns\": $PATTERN_COUNT"
    fi

    log "${GREEN}✓${NC} Remaining work analysis complete"
}

#------------------------------------------------------------------------------
# Section 6: Verification (--verify) - 100-point plan-vs-implementation check
#------------------------------------------------------------------------------

section_verify() {
    print_header "IMPLEMENTATION VERIFICATION"

    # Find plan document
    local pln_doc=""
    local pln_docs_list
    pln_docs_list=$(find_by_id "$TASK_ID" | grep -- "-PLN-" || true)
    if [[ -n "$pln_docs_list" ]]; then
        pln_doc=$(echo "$pln_docs_list" | tail -1)
    fi

    if [[ -z "$pln_doc" ]] || [[ ! -f "$pln_doc" ]]; then
        exit_with_json "error" "No PLN document found for task $TASK_ID" \
            "Verification requires a plan document. Run /task-plan first."
    fi

    # Gather implementation data
    local changed_files=""
    changed_files=$(git diff --name-only "${DEFAULT_BRANCH}...${CURRENT_BRANCH}" 2>/dev/null || echo "")
    local commit_log=""
    commit_log=$(git log --oneline "${DEFAULT_BRANCH}..${CURRENT_BRANCH}" 2>/dev/null || echo "")

    # Get VRF document filepath + template
    local vrf_filepath=""
    local vrf_template=""
    local vrf_doc_json=""
    vrf_doc_json=$("${SCRIPT_DIR}/new-doc.sh" --type VRF --description "verification" --id "$TASK_ID" --json 2>/dev/null || true)
    if [[ -n "$vrf_doc_json" ]]; then
        vrf_filepath=$(echo "$vrf_doc_json" | jq -r '.filepath // empty')
        vrf_template=$(echo "$vrf_doc_json" | jq -r '.template // empty')
    fi

    # Return context for LLM to perform the 100-point verification
    local json=$(cat <<EOF
{
  "status": "ready_for_opus",
  "next_action": "verify_implementation",
  "section": "verify",
  "message": "Verification context gathered — LLM must perform 100-point scoring",
  "task_id": "$TASK_ID",
  "task_title": "$TASK_TITLE",
  "pln_doc": "$pln_doc",
  "task_doc": "$TASK_DOC",
  "branch": "$CURRENT_BRANCH",
  "changed_files": $(echo "$changed_files" | jq -Rs 'split("\n") | map(select(length > 0))'),
  "commit_log": $(echo "$commit_log" | jq -Rs 'split("\n") | map(select(length > 0))'),
  "tests_passing": $TESTS_PASSING,
  "coverage_percent": "$COVERAGE_PERCENT",
  "scoring_rubric": {
    "plan_completeness": {"max": 30, "description": "Each planned task implemented. 100%=30, 90%+=25, 80%+=20, <80%=FAIL"},
    "code_quality": {"max": 25, "description": "Conventions, DRY, error handling, codebase consistency"},
    "test_coverage": {"max": 25, "description": "TDD pattern, happy+error+edge cases. >=90%=25, >=80%=20, >=70%=15, <70%=FAIL"},
    "security": {"max": 10, "description": "No hardcoded secrets, input validation, injection prevention"},
    "performance": {"max": 5, "description": "No N+1 queries, missing indexes, O(n^2)"},
    "no_regressions": {"max": 5, "description": "All pre-existing tests pass"}
  },
  "vrf_filepath": $(printf '%s' "$vrf_filepath" | jq -Rs .),
  "vrf_template": $(echo "$vrf_template" | jq -Rs .),
  "next_steps": [
    "Read the PLN document to understand all planned tasks",
    "Read each changed file and verify against plan",
    "Score each of the 6 categories",
    "Generate VRF document at vrf_filepath",
    "Report score to user"
  ],
  "timestamp": "$(date -Iseconds)"
}
EOF
)

    log_json "$json"
    exit 0
}

#------------------------------------------------------------------------------
# Calculate Scores
#------------------------------------------------------------------------------

calculate_scores() {
    # Test score
    if [[ "$TESTS_PASSING" != "true" ]]; then
        TEST_SCORE=$((TEST_SCORE - 50))
    fi

    if [[ $TEST_FILE_COUNT -eq 0 ]]; then
        TEST_SCORE=$((TEST_SCORE - 30))
    fi

    if [[ $UNCOVERED_COUNT -gt 0 ]] && [[ $TOTAL_SOURCE -gt 0 ]]; then
        local uncovered_percent=$((UNCOVERED_COUNT * 100 / TOTAL_SOURCE))
        TEST_SCORE=$((TEST_SCORE - uncovered_percent / 2))
    fi

    # Completion score
    if [[ $TODO_COUNT -gt 0 ]]; then
        COMPLETION_SCORE=$((COMPLETION_SCORE - TODO_COUNT * 5))
    fi

    if [[ $PATTERN_COUNT -gt 0 ]]; then
        COMPLETION_SCORE=$((COMPLETION_SCORE - PATTERN_COUNT * 10))
    fi

    if [[ $PENDING_CRITERIA -gt 0 ]]; then
        COMPLETION_SCORE=$((COMPLETION_SCORE - PENDING_CRITERIA * 10))
    fi

    # Ensure scores don't go negative
    [[ $WORK_SCORE -lt 0 ]] && WORK_SCORE=0
    [[ $TEST_SCORE -lt 0 ]] && TEST_SCORE=0
    [[ $IMPACT_SCORE -lt 0 ]] && IMPACT_SCORE=0
    [[ $COMPLETION_SCORE -lt 0 ]] && COMPLETION_SCORE=0

    OVERALL_SCORE=$(( (WORK_SCORE + TEST_SCORE + IMPACT_SCORE + COMPLETION_SCORE) / 4 ))
}

#------------------------------------------------------------------------------
# Generate Recommendations
#------------------------------------------------------------------------------

generate_recommendations() {
    local recommendations_array="[]"

    if [[ "$TESTS_PASSING" != "true" ]]; then
        recommendations_array=$(echo "$recommendations_array" | jq '. + ["Fix failing tests before proceeding"]')
    fi

    if [[ $UNCOVERED_COUNT -gt 0 ]]; then
        recommendations_array=$(echo "$recommendations_array" | jq ". + [\"Add tests for $UNCOVERED_COUNT uncovered file(s)\"]")
    fi

    if [[ $TODO_COUNT -gt 0 ]]; then
        recommendations_array=$(echo "$recommendations_array" | jq ". + [\"Resolve $TODO_COUNT TODO(s) in changes\"]")
    fi

    if [[ $PATTERN_COUNT -gt 0 ]]; then
        recommendations_array=$(echo "$recommendations_array" | jq ". + [\"Complete $PATTERN_COUNT incomplete pattern(s)\"]")
    fi

    if [[ $PENDING_CRITERIA -gt 0 ]]; then
        recommendations_array=$(echo "$recommendations_array" | jq ". + [\"Complete $PENDING_CRITERIA remaining acceptance criteria\"]")
    fi

    echo "$recommendations_array"
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
            --identify|--load) SECTION="load"; shift ;;
            --analyze) SECTION="analyze"; shift ;;
            --test) SECTION="test"; shift ;;
            --impact) SECTION="impact"; shift ;;
            --remaining) SECTION="remaining"; shift ;;
            --verify) SECTION="verify"; shift ;;
            --re-verify) SECTION="full"; RE_VERIFY=true; shift ;;
            --full) SECTION="full"; shift ;;
            --task-id) TASK_ID_ARG="$2"; shift 2 ;;
            *) echo "Unknown option: $1" >&2; exit 2 ;;
        esac
    done

    # Execute sections based on flag
    case "$SECTION" in
        load)
            section_load
            ;;
        analyze)
            section_load
            section_analyze
            ;;
        test)
            section_load
            section_analyze
            section_test
            ;;
        impact)
            section_load
            section_analyze
            section_impact
            ;;
        remaining)
            section_load
            section_remaining
            ;;
        verify)
            section_load
            section_analyze
            section_test
            section_verify
            ;;
        full)
            section_load
            section_analyze
            section_test
            section_impact
            section_remaining

            # Calculate final scores
            calculate_scores

            # Generate recommendations
            local recommendations=$(generate_recommendations)

            # Build uncovered files array
            local uncovered_json="[]"
            if [[ -n "$UNCOVERED_FILES_LIST" ]]; then
                uncovered_json=$(echo "$UNCOVERED_FILES_LIST" | jq -R . | jq -s .)
            fi

            # Determine status
            local audit_status="needs_work"
            if [[ $OVERALL_SCORE -ge 90 ]]; then
                audit_status="excellent"
            elif [[ $OVERALL_SCORE -ge 70 ]]; then
                audit_status="good"
            elif [[ $OVERALL_SCORE -ge 50 ]]; then
                audit_status="fair"
            fi

            # Get AUD document filepath + template via new-doc.sh --json (no file written)
            local aud_filepath=""
            local aud_template=""
            local aud_doc_json=""
            aud_doc_json=$("${SCRIPT_DIR}/new-doc.sh" --type AUD --description "task-audit" --id "$TASK_ID" --json 2>/dev/null || true)
            if [[ -n "$aud_doc_json" ]]; then
                aud_filepath=$(echo "$aud_doc_json" | jq -r '.filepath // empty')
                aud_template=$(echo "$aud_doc_json" | jq -r '.template // empty')
            fi

            # If --re-verify: locate the most recent existing AUD doc for this task
            # so the LLM can diff prior vs current scores ("fixed X of Y issues").
            local prior_aud_path=""
            local prior_audit_status=""
            local prior_overall_score=""
            if [[ "$RE_VERIFY" == "true" ]]; then
                prior_aud_path=$(find docs/active docs/completed -type f -name "${TASK_ID}-*-AUD-*.md" 2>/dev/null | sort -r | head -1 || echo "")
                if [[ -n "$prior_aud_path" ]] && [[ -f "$prior_aud_path" ]]; then
                    prior_audit_status=$(grep -m1 "^\*\*Status\*\*:" "$prior_aud_path" 2>/dev/null | sed 's/.*: *//; s/"//g' | head -c 40 || echo "")
                    prior_overall_score=$(grep -m1 "^\*\*Overall Score\*\*:" "$prior_aud_path" 2>/dev/null | sed -E 's/[^0-9]*([0-9]+).*/\1/' | head -c 10 || echo "")
                fi
            fi

            # Build raw data for LLM document generation
            local commit_list_json="[]"
            if [[ -n "$COMMIT_LIST" ]]; then
                commit_list_json=$(echo "$COMMIT_LIST" | jq -R . | jq -s .)
            fi

            local changed_files_json="[]"
            if [[ -n "$CHANGED_FILES_STATUS" ]]; then
                changed_files_json=$(echo "$CHANGED_FILES_STATUS" | jq -R . | jq -s .)
            fi

            local test_files_json="[]"
            if [[ -n "$TEST_FILES_LIST_RAW" ]]; then
                test_files_json=$(echo "$TEST_FILES_LIST_RAW" | jq -R . | jq -s .)
            fi

            local todo_json="[]"
            if [[ -n "$TODO_LIST" ]]; then
                todo_json=$(echo "$TODO_LIST" | jq -R . | jq -s .)
            fi

            local pattern_json="[]"
            if [[ -n "$PATTERN_LIST" ]]; then
                pattern_json=$(echo "$PATTERN_LIST" | jq -R . | jq -s .)
            fi

            # Full success - return complete results
            local json=$(cat <<EOF
{
  "status": "success",
  "next_action": "generate_document",
  "message": "Task audit complete — generate AUD document",
  "audit_status": "$audit_status",
  "task_id": "$TASK_ID",
  "task_title": "$TASK_TITLE",
  "branch": "$CURRENT_BRANCH",
  "work": {
    "commits": $COMMIT_COUNT,
    "files_changed": $FILES_COUNT,
    "source_files": $SOURCE_FILES,
    "test_files": $TEST_FILES
  },
  "testing": {
    "tests_passing": $TESTS_PASSING,
    "test_file_count": $TEST_FILE_COUNT,
    "coverage_percent": "$COVERAGE_PERCENT",
    "covered_files": $COVERED_COUNT,
    "uncovered_files": $UNCOVERED_COUNT,
    "total_source_files": $TOTAL_SOURCE,
    "uncovered_files_list": $uncovered_json$(if [[ -n "$TEST_RESULTS_JSON" ]]; then echo ",
    \"test_results\": $TEST_RESULTS_JSON"; fi)
  },
  "completion": {
    "pending_criteria": $PENDING_CRITERIA,
    "todo_count": $TODO_COUNT,
    "incomplete_patterns": $PATTERN_COUNT
  },
  "scores": {
    "work": $WORK_SCORE,
    "test": $TEST_SCORE,
    "impact": $IMPACT_SCORE,
    "completion": $COMPLETION_SCORE,
    "overall": $OVERALL_SCORE
  },
  "recommendations": $recommendations,
  "raw_data": {
    "commits": $commit_list_json,
    "changed_files": $changed_files_json,
    "code_stats": $(echo "$CODE_STATS" | jq -Rs .),
    "test_files": $test_files_json,
    "todos": $todo_json,
    "incomplete_patterns": $pattern_json
  },
  "aud_filepath": $(printf '%s' "$aud_filepath" | jq -Rs .),
  "aud_template": $(echo "$aud_template" | jq -Rs .),
  "re_verify": $(if [[ "$RE_VERIFY" == "true" ]]; then echo "true"; else echo "false"; fi),
  "prior_aud_path": $(printf '%s' "$prior_aud_path" | jq -Rs .),
  "prior_audit_status": $(printf '%s' "$prior_audit_status" | jq -Rs .),
  "prior_overall_score": $(printf '%s' "$prior_overall_score" | jq -Rs .),
  "timestamp": "$(date -Iseconds)"
}
EOF
)
            log_json "$json"

            # Output summary in raw mode
            if [[ "$OUTPUT_MODE" == "raw" ]]; then
                print_header "AUDIT COMPLETE"
                log ""
                log "Audit Score: ${OVERALL_SCORE}/100"
                log ""
                if [[ $OVERALL_SCORE -ge 90 ]]; then
                    log "${GREEN}✓ EXCELLENT - Ready to proceed: /task-close ${TASK_ID}${NC}"
                elif [[ $OVERALL_SCORE -ge 70 ]]; then
                    log "${GREEN}✓ GOOD - Address minor items then proceed${NC}"
                elif [[ $OVERALL_SCORE -ge 50 ]]; then
                    log "${YELLOW}⚠️  FAIR - Address issues then re-audit${NC}"
                else
                    log "${RED}❌ NEEDS WORK - Fix critical issues${NC}"
                fi
                log ""
            fi

            exit 0
            ;;
    esac
}

# Run main function
main "$@"
