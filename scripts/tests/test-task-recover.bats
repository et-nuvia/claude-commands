#!/usr/bin/env bats

# Test suite for task-recover.sh
# Covers: branch parsing, TSK doc lookup, external tracker extraction, JSON output

load test_helper

setup() {
    common_setup
    SCRIPTS_DIR="${BATS_TEST_DIRNAME}/.."
    source "$SCRIPTS_DIR/common.sh"
    source "$SCRIPTS_DIR/doc-utils.sh"

    # Create mock git repo with 'main' as default branch
    cd "$TEST_DIR"
    git init -q -b main
    git config user.email "test@test.com"
    git config user.name "Test User"
    echo "init" > README.md
    git add README.md
    git commit -q -m "initial commit"
}

teardown() {
    common_teardown
}

# Helper: create a minimal TSK doc for a task ID
create_mock_tsk() {
    local task_id="$1"
    local tracker_section="${2:-}"
    mkdir -p docs/active/2026-03 docs/completed
    local filepath="docs/active/2026-03/${task_id}-2603170218-TSK-test-task.md"
    cat > "$filepath" <<TSKEOF
# Task: test-task

**Work Item**: ${task_id}
**Status**: Active

## External Tracking

${tracker_section}

## Requirements
TSKEOF
    echo "$filepath"
}

# =============================================================================
# Happy path: feature branch with TSK doc and Asana GID
# =============================================================================

@test "task-recover: recovers from feature branch with Asana tracker" {
    git checkout -q -b "feature/A3F2B9-test-task"
    create_mock_tsk "A3F2B9" "$(cat <<'TRACK'
**Asana**:
- Task GID: [1234567890123456]
- Task URL: [https://app.asana.com/0/0/1234567890123456]
TRACK
)"
    # Create PROJECT.yaml with asana backend
    cat > PROJECT.yaml <<'YAML'
task_management:
  backend: asana
YAML

    run bash "$SCRIPTS_DIR/task-recover.sh" --json
    [ "$status" -eq 0 ]
    assert_valid_json "$output"
    assert_json_field "$output" ".status" "success"

    # Verify .current-task was created as valid JSON
    [ -f ".current-task" ]
    [ "$(jq -r '.task_id' .current-task)" = "A3F2B9" ]
    [ "$(jq -r '.branch' .current-task)" = "feature/A3F2B9-test-task" ]
    [ "$(jq -r '.task_tracker.backend' .current-task)" = "asana" ]
    [ "$(jq -r '.task_tracker.id' .current-task)" = "1234567890123456" ]
}

# =============================================================================
# Feature branch with TSK doc but no external tracker
# =============================================================================

@test "task-recover: recovers with null tracker when no external tracking" {
    git checkout -q -b "feature/B4C5D6-no-tracker"
    create_mock_tsk "B4C5D6" "_No external tracker linked._"

    run bash "$SCRIPTS_DIR/task-recover.sh" --json
    [ "$status" -eq 0 ]
    assert_valid_json "$output"

    [ -f ".current-task" ]
    [ "$(jq -r '.task_id' .current-task)" = "B4C5D6" ]
    [ "$(jq -r '.task_tracker' .current-task)" = "null" ]
}

# =============================================================================
# Non-feature branch (default branch) should error
# =============================================================================

@test "task-recover: errors on default branch" {
    # Stay on main (default)
    run bash "$SCRIPTS_DIR/task-recover.sh" --json
    [ "$status" -ne 0 ]
    assert_valid_json "$output"
    assert_json_field "$output" ".status" "error"
}

# =============================================================================
# Feature branch but no TSK doc found
# =============================================================================

@test "task-recover: errors when no TSK doc found" {
    git checkout -q -b "feature/C5D6E7-missing-task"
    mkdir -p docs/active/2026-03 docs/completed

    run bash "$SCRIPTS_DIR/task-recover.sh" --json
    [ "$status" -ne 0 ]
    assert_valid_json "$output"
    assert_json_field "$output" ".status" "error"
}

# =============================================================================
# Different branch naming patterns
# =============================================================================

@test "task-recover: handles bugfix/ branch prefix" {
    git checkout -q -b "bugfix/D6E7F8-fix-something"
    create_mock_tsk "D6E7F8" ""

    run bash "$SCRIPTS_DIR/task-recover.sh" --json
    [ "$status" -eq 0 ]
    [ "$(jq -r '.task_id' .current-task)" = "D6E7F8" ]
}

@test "task-recover: extracts parent_branch as default branch" {
    git checkout -q -b "feature/E7F8A9-parent-test"
    create_mock_tsk "E7F8A9" ""

    run bash "$SCRIPTS_DIR/task-recover.sh" --json
    [ "$status" -eq 0 ]
    # parent_branch should be the default branch (main in test repo)
    [ "$(jq -r '.parent_branch' .current-task)" = "main" ]
}
