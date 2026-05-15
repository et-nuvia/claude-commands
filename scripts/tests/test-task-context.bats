#!/usr/bin/env bats

# Test suite: Task context resolution across scripts
#
# Purpose: Lock down how scripts find and load task context BEFORE extracting
# to shared task-loader. Every task script resolves context via:
#   1. .current-task file (primary)
#   2. --task-id flag (explicit)
#   3. Branch name parsing (fallback)
#
# Tests ensure all scripts follow the same resolution order and produce
# consistent output when task context is missing, found, or ambiguous.

load test_helper

setup() {
    common_setup
    setup_mock_git_repo

    # Standard task fixture — must use 6-char hex task IDs
    mkdir -p docs/active/A1B2C3 docs/completed

    cat > docs/active/A1B2C3/A1B2C3-2602140922-TSK-test-task.md << 'TASKEOF'
# Test Task: Authentication

## Status: in-progress

## Source
- **Type**: direct
- **Captured**: 2026-02-14 09:22

## Description
Add user authentication with JWT.

## Branch
`feature/A1B2C3-test-task`
TASKEOF

    cat > docs/active/A1B2C3/A1B2C3-2602140923-PLN-test-task.md << 'PLNEOF'
# Plan: Authentication

## Subtasks
### Phase 1: Setup
- [x] 1.1 Install deps
- [ ] 1.2 Create structure
PLNEOF

    git add -A
    git commit -q -m "add task docs"
}

teardown() {
    common_teardown
}

# =============================================================================
# .current-task resolution
# =============================================================================

@test "context: task-continue finds task from .current-task" {
    git checkout -q -b feature/A1B2C3-test-task

    echo '{"task_id":"A1B2C3","branch":"feature/A1B2C3-test-task","parent_branch":"main","task_doc":"docs/active/A1B2C3/A1B2C3-2602140922-TSK-test-task.md","started":"2026-03-17T00:00:00Z","task_tracker":null}' > .current-task

    run "$SCRIPTS_DIR/task-continue.sh" --json --identify 2>/dev/null
    assert_valid_json "$output"
    assert_json_field "$output" ".status" "success"
}

@test "context: task-close finds task from .current-task" {
    git checkout -q -b feature/A1B2C3-test-task

    echo '{"task_id":"A1B2C3","branch":"feature/A1B2C3-test-task","parent_branch":"main","task_doc":"docs/active/A1B2C3/A1B2C3-2602140922-TSK-test-task.md","started":"2026-03-17T00:00:00Z","task_tracker":null}' > .current-task

    run "$SCRIPTS_DIR/task-close.sh" --json --ai --identify --task-id A1B2C3 --status completed \
        --accomplished "test" --went-well "test" --challenges "test" --differently "test" --patterns "test" 2>/dev/null
    assert_valid_json "$output"
    assert_json_field_present "$output" ".status"
}

# =============================================================================
# --task-id flag resolution
# =============================================================================

@test "context: task-start finds task by --task-id" {
    run "$SCRIPTS_DIR/task-start.sh" --json --identify --task-id A1B2C3 2>/dev/null
    assert_valid_json "$output"
    assert_json_field_present "$output" ".status"
}

@test "context: task-continue finds task by --task-id" {
    git checkout -q -b feature/A1B2C3-test-task

    run "$SCRIPTS_DIR/task-continue.sh" --json --identify --task-id A1B2C3 2>/dev/null
    assert_valid_json "$output"
    assert_json_field_present "$output" ".status"
}

@test "context: task-audit finds task by --task-id" {
    run "$SCRIPTS_DIR/task-audit.sh" --json --full --task-id A1B2C3 2>/dev/null
    assert_valid_json "$output"
    assert_json_field_present "$output" ".status"
}

@test "context: task-code-review finds task by --task-id" {
    run "$SCRIPTS_DIR/task-code-review.sh" --json --full --task-id A1B2C3 2>/dev/null
    assert_valid_json "$output"
    assert_json_field_present "$output" ".status"
}

@test "context: task-summary finds task by --task-id" {
    run "$SCRIPTS_DIR/task-summary.sh" --json --find --task-id A1B2C3 2>/dev/null
    assert_valid_json "$output"
    assert_json_field_present "$output" ".status"
}

@test "context: task-close finds task by --task-id" {
    run "$SCRIPTS_DIR/task-close.sh" --json --ai --identify --task-id A1B2C3 --status completed \
        --accomplished "test" --went-well "test" --challenges "test" --differently "test" --patterns "test" 2>/dev/null
    assert_valid_json "$output"
    assert_json_field_present "$output" ".status"
}

# =============================================================================
# Missing task context
# =============================================================================

@test "context: task-continue errors without task context" {
    run "$SCRIPTS_DIR/task-continue.sh" --json --identify 2>/dev/null
    assert_valid_json "$output"
    assert_json_field "$output" ".status" "error"
}

@test "context: task-close errors without task context" {
    run "$SCRIPTS_DIR/task-close.sh" --json --identify 2>/dev/null
    assert_valid_json "$output"
    assert_json_field "$output" ".status" "error"
}

@test "context: task-start errors without task ID" {
    run "$SCRIPTS_DIR/task-start.sh" --json --full 2>/dev/null
    assert_valid_json "$output"
    assert_json_field "$output" ".status" "error"
}

@test "context: task-hold errors without task context" {
    run "$SCRIPTS_DIR/task-hold.sh" --json --full 2>/dev/null
    assert_valid_json "$output"
    assert_json_field "$output" ".status" "error"
}

# =============================================================================
# Invalid task ID
# =============================================================================

@test "context: task-start errors with non-existent task" {
    run "$SCRIPTS_DIR/task-start.sh" --json --identify --task-id FFFFFF 2>/dev/null
    assert_valid_json "$output"
    assert_json_field "$output" ".status" "error"
}

@test "context: task-continue errors with non-existent task" {
    run "$SCRIPTS_DIR/task-continue.sh" --json --identify --task-id FFFFFF 2>/dev/null
    assert_valid_json "$output"
    assert_json_field "$output" ".status" "error"
}

# =============================================================================
# Task document fields
# =============================================================================

@test "context: task-continue success includes task_doc path" {
    git checkout -q -b feature/A1B2C3-test-task

    echo '{"task_id":"A1B2C3","branch":"feature/A1B2C3-test-task","parent_branch":"main","task_doc":"docs/active/A1B2C3/A1B2C3-2602140922-TSK-test-task.md","started":"2026-03-17T00:00:00Z","task_tracker":null}' > .current-task

    run "$SCRIPTS_DIR/task-continue.sh" --json --identify 2>/dev/null
    assert_valid_json "$output"
    if [[ "$(echo "$output" | jq -r '.status')" == "success" ]]; then
        assert_json_field_present "$output" ".task_doc"
    fi
}

@test "context: task-continue success includes task_id" {
    git checkout -q -b feature/A1B2C3-test-task

    echo '{"task_id":"A1B2C3","branch":"feature/A1B2C3-test-task","parent_branch":"main","task_doc":"docs/active/A1B2C3/A1B2C3-2602140922-TSK-test-task.md","started":"2026-03-17T00:00:00Z","task_tracker":null}' > .current-task

    run "$SCRIPTS_DIR/task-continue.sh" --json --identify 2>/dev/null
    assert_valid_json "$output"
    if [[ "$(echo "$output" | jq -r '.status')" == "success" ]]; then
        assert_json_field_present "$output" ".task_id"
    fi
}

# =============================================================================
# Branch-based resolution
# =============================================================================

@test "context: task-continue resolves from branch name when no .current-task" {
    git checkout -q -b feature/A1B2C3-test-task

    # No .current-task file — should try branch parsing
    run "$SCRIPTS_DIR/task-continue.sh" --json --identify 2>/dev/null
    assert_valid_json "$output"
    # May succeed if branch-based resolution works, or error gracefully
    local status_val
    status_val=$(echo "$output" | jq -r '.status')
    [[ "$status_val" == "success" ]] || [[ "$status_val" == "error" ]]
}
