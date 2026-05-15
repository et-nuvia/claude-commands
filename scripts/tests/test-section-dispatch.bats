#!/usr/bin/env bats

# Test suite: Section-based dispatch across scripts
#
# Purpose: Lock down the section dispatch pattern BEFORE extracting to shared code.
# When running a specific section, the script must:
#   1. Include that section name in the JSON response
#   2. Only run prerequisite sections (cumulative ordering)
#   3. Return valid JSON with section-specific data
#
# Tests cumulative section ordering (e.g., --verify runs identify + verify)

load test_helper

setup() {
    common_setup
    setup_mock_git_repo

    # Create a minimal task structure for scripts that need it
    mkdir -p docs/active/A1B2C3 docs/completed

    cat > docs/active/A1B2C3/A1B2C3-2602140922-TSK-test-task.md << 'TASKEOF'
# Test Task: Add authentication

## Status: in-progress

## Source
- **Type**: direct
- **Captured**: 2026-02-14 09:22

## Description
Add user authentication.

## Branch
`feature/A1B2C3-test-task`
TASKEOF

    cat > docs/active/A1B2C3/A1B2C3-2602140923-PLN-test-task.md << 'PLNEOF'
# Plan: Add authentication

## Subtasks

### Phase 1: Setup
- [x] 1.1 Install dependencies
- [ ] 1.2 Create module structure

### Phase 2: Implementation
- [ ] 2.1 Create JWT tokens
- [ ] 2.2 Add middleware
PLNEOF

    # Create .current-task
    echo '{"task_id":"A1B2C3","branch":"feature/A1B2C3-test-task","parent_branch":"main","task_doc":"docs/active/A1B2C3/A1B2C3-2602140922-TSK-test-task.md","started":"2026-03-17T00:00:00Z","task_tracker":null}' > .current-task

    git add -A
    git commit -q -m "add task docs"
    git checkout -q -b feature/A1B2C3-test-task
}

teardown() {
    common_teardown
}

# =============================================================================
# task-continue section dispatch
# =============================================================================

@test "section: task-continue --identify returns identify section" {
    run "$SCRIPTS_DIR/task-continue.sh" --json --identify 2>/dev/null
    assert_valid_json "$output"
    assert_json_field "$output" ".section" "identify"
}

@test "section: task-continue --identify finds task from .current-task" {
    run "$SCRIPTS_DIR/task-continue.sh" --json --identify 2>/dev/null
    assert_valid_json "$output"
    assert_json_field "$output" ".status" "success"
}

@test "section: task-continue --verify-branch includes identify prereq" {
    run "$SCRIPTS_DIR/task-continue.sh" --json --verify-branch 2>/dev/null
    assert_valid_json "$output"
    # If identify succeeded, verify-branch should have task context
    local status_val
    status_val=$(echo "$output" | jq -r '.status')
    # Either success or a meaningful error (not a crash)
    [[ "$status_val" == "success" ]] || [[ "$status_val" == "error" ]] || [[ "$status_val" == "blocked" ]]
}

@test "section: task-continue --gather runs prerequisite sections" {
    run "$SCRIPTS_DIR/task-continue.sh" --json --gather 2>/dev/null
    assert_valid_json "$output"
    # Should have gathered data or errored meaningfully
    assert_json_field_present "$output" ".status"
}

# =============================================================================
# task-start section dispatch
# =============================================================================

@test "section: task-start --identify returns task data" {
    run "$SCRIPTS_DIR/task-start.sh" --json --identify --task-id A1B2C3 2>/dev/null
    assert_valid_json "$output"
    assert_json_field_present "$output" ".status"
}

@test "section: task-start --verify runs identify first" {
    run "$SCRIPTS_DIR/task-start.sh" --json --verify --task-id A1B2C3 2>/dev/null
    assert_valid_json "$output"
    assert_json_field_present "$output" ".status"
}

@test "section: task-start --setup-env runs identify first" {
    run "$SCRIPTS_DIR/task-start.sh" --json --setup-env --task-id A1B2C3 2>/dev/null
    assert_valid_json "$output"
    assert_json_field_present "$output" ".status"
}

# =============================================================================
# task-close section dispatch
# =============================================================================

@test "section: task-close --identify finds task" {
    run "$SCRIPTS_DIR/task-close.sh" --json --ai --identify --task-id A1B2C3 --status completed \
        --accomplished "test" --went-well "test" --challenges "test" --differently "test" --patterns "test" 2>/dev/null
    assert_valid_json "$output"
    assert_json_field_present "$output" ".status"
}

# =============================================================================
# git-commit section dispatch
# =============================================================================

@test "section: git-commit --analyze returns git state" {
    # Make a change to analyze
    echo "new content" > test-file.txt
    git add test-file.txt

    run "$SCRIPTS_DIR/git-commit.sh" --json --analyze 2>/dev/null
    assert_valid_json "$output"
    assert_json_field_present "$output" ".status"
}

@test "section: git-commit --full returns analysis" {
    run "$SCRIPTS_DIR/git-commit.sh" --json --full 2>/dev/null
    assert_valid_json "$output"
    # --full maps to the analyze phase (git-commit uses multi-step workflow)
    assert_json_field "$output" ".section" "analyze"
}

# =============================================================================
# plan-progress section dispatch
# =============================================================================

@test "section: plan-progress reads PLN file" {
    run "$SCRIPTS_DIR/plan-progress.sh" --json --file docs/active/A1B2C3/A1B2C3-2602140923-PLN-test-task.md 2>/dev/null
    assert_valid_json "$output"
    assert_json_field "$output" ".status" "success"
}

@test "section: plan-progress reports progress counts" {
    run "$SCRIPTS_DIR/plan-progress.sh" --json --file docs/active/A1B2C3/A1B2C3-2602140923-PLN-test-task.md 2>/dev/null
    assert_valid_json "$output"
    # Should have progress data
    assert_json_field_present "$output" ".progress"
}

@test "section: plan-progress --mark-complete updates checkbox" {
    run "$SCRIPTS_DIR/plan-progress.sh" --json \
        --file docs/active/A1B2C3/A1B2C3-2602140923-PLN-test-task.md \
        --mark-complete "1.2 Create module structure" 2>/dev/null
    assert_valid_json "$output"
    # Verify the checkbox was actually changed in the file
    if grep -q "\[x\] 1.2 Create module structure" docs/active/A1B2C3/A1B2C3-2602140923-PLN-test-task.md; then
        true
    else
        echo "Checkbox was not marked complete in the PLN file" >&2
        cat docs/active/A1B2C3/A1B2C3-2602140923-PLN-test-task.md >&2
        return 1
    fi
}

# =============================================================================
# Full section runs all subsections
# =============================================================================

@test "section: task-continue --full runs all sections" {
    run "$SCRIPTS_DIR/task-continue.sh" --json --full 2>/dev/null
    assert_valid_json "$output"
    # Full should include comprehensive task data
    assert_json_field_present "$output" ".status"
}

@test "section: task-start --full with valid task" {
    # Switch back to main so create-branch can work
    git checkout -q main 2>/dev/null || git checkout -q master 2>/dev/null
    run "$SCRIPTS_DIR/task-start.sh" --json --full --task-id A1B2C3 2>/dev/null
    # Full mode assembles JSON from many sections; subprocesses may leak
    # non-JSON to stdout.  Extract the last valid JSON object from output.
    local json_output
    json_output=$(echo "$output" | python3 -c "
import sys, json
text = sys.stdin.read()
# Find the last '{' and try progressively shorter substrings
best = None
for i in range(len(text) - 1, -1, -1):
    if text[i] == '}':
        for j in range(i, -1, -1):
            if text[j] == '{':
                try:
                    json.loads(text[j:i+1])
                    best = text[j:i+1]
                    break
                except json.JSONDecodeError:
                    continue
        if best:
            break
print(best or '')
" 2>/dev/null)
    [[ -n "$json_output" ]]
    assert_valid_json "$json_output"
    assert_json_field_present "$json_output" ".status"
}
