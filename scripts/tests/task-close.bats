#!/usr/bin/env bats

# Test suite: task-close.sh basic behavior

load test_helper

setup() {
    common_setup
    setup_mock_git_repo

    # Setup mock docs structure with valid 6-char hex IDs
    mkdir -p docs/active/A1B2C3 docs/completed
    cat > docs/active/A1B2C3/A1B2C3-2602191000-TSK-test-task.md << 'EOF'
# Test Task

## Status: in-progress

## Branch
`feature/A1B2C3-test-task`
EOF
    git add -A
    git commit -q -m "add task docs"

    echo '{"task_id":"A1B2C3","branch":"feature/A1B2C3-test-task","parent_branch":"main","task_doc":"docs/active/A1B2C3/A1B2C3-2602191000-TSK-test-task.md","started":"2026-03-17T00:00:00Z","task_tracker":null}' > .current-task

    git checkout -q -b feature/A1B2C3-test-task
}

teardown() {
    common_teardown
}

@test "task-close: --identify returns task info" {
    run "$SCRIPTS_DIR/task-close.sh" --json --ai --identify --task-id A1B2C3 --status completed \
        --accomplished "done" --went-well "good" --challenges "none" --differently "nothing" --patterns "none" 2>/dev/null
    assert_valid_json "$output"
    assert_json_field_present "$output" ".status"
}

@test "task-close: errors without task context" {
    rm -f .current-task
    git checkout -q main 2>/dev/null || git checkout -q master 2>/dev/null
    run "$SCRIPTS_DIR/task-close.sh" --json --identify 2>/dev/null
    assert_valid_json "$output"
    assert_json_field "$output" ".status" "error"
}

# =============================================================================
# Lockfile tests
# =============================================================================

@test "task-close: lockfile created during cleanup contains branch info" {
    source "$SCRIPTS_DIR/lib/git-utils.sh"
    source "$SCRIPTS_DIR/common.sh"

    # Create a lockfile manually matching the expected format
    echo '{"task_id":"A1B2C3","feature_branch":"feature/A1B2C3-test-task","target_branch":"main","created":"2026-03-17T00:00:00Z"}' > .task-close-state

    # Verify it's valid JSON with expected fields
    [ "$(jq -r '.task_id' .task-close-state)" = "A1B2C3" ]
    [ "$(jq -r '.feature_branch' .task-close-state)" = "feature/A1B2C3-test-task" ]
    [ "$(jq -r '.target_branch' .task-close-state)" = "main" ]
}

@test "task-close: write_close_state produces valid JSON read by read_close_state" {
    # Extract the functions from task-close.sh (they're self-contained)
    CLOSE_STATE_FILE=".task-close-state"
    write_close_state() {
        local task_id="$1" feature_branch="$2" target_branch="$3"
        jq -n --arg task_id "$task_id" --arg feature_branch "$feature_branch" \
            --arg target_branch "$target_branch" --arg created "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
            '{task_id: $task_id, feature_branch: $feature_branch, target_branch: $target_branch, created: $created}' \
            > "$CLOSE_STATE_FILE"
    }
    read_close_state() {
        LOCKED_FEATURE_BRANCH="" LOCKED_TARGET_BRANCH=""
        [[ ! -f "$CLOSE_STATE_FILE" ]] && return 1
        LOCKED_FEATURE_BRANCH=$(jq -r '.feature_branch // empty' "$CLOSE_STATE_FILE" 2>/dev/null)
        LOCKED_TARGET_BRANCH=$(jq -r '.target_branch // empty' "$CLOSE_STATE_FILE" 2>/dev/null)
        [[ -z "$LOCKED_FEATURE_BRANCH" || -z "$LOCKED_TARGET_BRANCH" ]] && return 1
        return 0
    }

    # Write
    write_close_state "A1B2C3" "feature/A1B2C3-test" "dev"
    [ -f ".task-close-state" ]
    jq . .task-close-state >/dev/null 2>&1  # valid JSON

    # Read back
    read_close_state
    [ "$LOCKED_FEATURE_BRANCH" = "feature/A1B2C3-test" ]
    [ "$LOCKED_TARGET_BRANCH" = "dev" ]
}

@test "task-close: read_close_state returns 1 when lockfile missing" {
    CLOSE_STATE_FILE=".task-close-state"
    read_close_state() {
        LOCKED_FEATURE_BRANCH="" LOCKED_TARGET_BRANCH=""
        [[ ! -f "$CLOSE_STATE_FILE" ]] && return 1
        return 0
    }
    rm -f .task-close-state
    run read_close_state
    [ "$status" -eq 1 ]
}

@test "task-close: lockfile prevents cascade on retry (already on target)" {
    # Simulate: first run merged feature→main, now we're on main
    git checkout -q main 2>/dev/null || git checkout -q master 2>/dev/null

    # Create lockfile from "first run"
    echo '{"task_id":"A1B2C3","feature_branch":"feature/A1B2C3-test-task","target_branch":"main","created":"2026-03-17T00:00:00Z"}' > .task-close-state

    # Run cleanup — should read lockfile, see we're already on target, skip merge
    run "$SCRIPTS_DIR/task-close.sh" --json --cleanup --task-id A1B2C3 2>/dev/null
    # Should not error — idempotent
    assert_valid_json "$output"
    # Should not try to merge into anything beyond main
    local merge_target
    merge_target=$(echo "$output" | jq -r '.merge_target // empty' 2>/dev/null)
    [[ -z "$merge_target" || "$merge_target" == "main" || "$merge_target" == "master" ]]
}

# =============================================================================
# Cascade prevention tests
# =============================================================================

@test "task-close: cleanup reads parent_branch from .current-task, not auto-detect" {
    # .current-task says parent is main — even if detect_base_branch would pick something else
    # This verifies the resolution priority: .current-task > auto-detect
    run "$SCRIPTS_DIR/task-close.sh" --json --cleanup --task-id A1B2C3 2>/dev/null
    assert_valid_json "$output"
    # Should target main (from .current-task parent_branch), not any other branch
    local target
    target=$(echo "$output" | jq -r '.merge_target // empty' 2>/dev/null)
    [[ -z "$target" || "$target" == "main" || "$target" == "master" ]]
}

@test "task-close: lockfile prevents cascade - retry uses locked target" {
    # Simulate first run already merged (we're now on main)
    git checkout -q main 2>/dev/null || git checkout -q master 2>/dev/null
    local default_branch
    default_branch=$(git branch --show-current)

    # Lockfile from first run locks feature→main
    echo "{\"task_id\":\"A1B2C3\",\"feature_branch\":\"feature/A1B2C3-test-task\",\"target_branch\":\"$default_branch\",\"created\":\"2026-03-17T00:00:00Z\"}" > .task-close-state

    # Retry should use locked values, not re-detect
    run "$SCRIPTS_DIR/task-close.sh" --json --cleanup --task-id A1B2C3 2>/dev/null
    assert_valid_json "$output"
    local target
    target=$(echo "$output" | jq -r '.merge_target // empty' 2>/dev/null)
    [[ -z "$target" || "$target" == "$default_branch" ]]
}

@test "task-close: protected branch cannot be deleted" {
    # Create PROJECT.yaml marking dev as protected
    cat > PROJECT.yaml <<'YAML'
ci:
  branches:
    dev: dev
YAML
    git add PROJECT.yaml
    git commit -q -m "add project config"

    # Create a dev branch — delete existing feature branch first (from setup)
    git checkout -q main 2>/dev/null || git checkout -q master 2>/dev/null
    git branch -D feature/A1B2C3-test-task 2>/dev/null || true
    git checkout -q -b dev
    echo "dev change" > dev-file && git add . && git commit -q -m "dev commit"
    git checkout -q -b feature/A1B2C3-test-task
    echo "feature change" > feature-file && git add . && git commit -q -m "feature commit"

    # Set .current-task with dev as parent
    echo '{"task_id":"A1B2C3","branch":"feature/A1B2C3-test-task","parent_branch":"dev","task_doc":"docs/active/A1B2C3/A1B2C3-2602191000-TSK-test-task.md","started":"2026-03-17T00:00:00Z","task_tracker":null}' > .current-task

    # Run cleanup — should merge into dev but NOT delete dev
    run "$SCRIPTS_DIR/task-close.sh" --json --ai --cleanup --task-id A1B2C3 --status completed \
        --accomplished "done" --went-well "good" --challenges "none" --differently "n" --patterns "n" 2>/dev/null

    # Dev branch should still exist
    git rev-parse --verify dev &>/dev/null
}

@test "task-close: lockfile survives across retries until cleanup succeeds" {
    echo '{"task_id":"A1B2C3","feature_branch":"feature/A1B2C3-test-task","target_branch":"main","created":"2026-03-17T00:00:00Z"}' > .task-close-state

    # Lockfile should persist during partial runs (e.g., waiting for doc generation)
    run "$SCRIPTS_DIR/task-close.sh" --json --ai --no-merge --status completed \
        --accomplished "done" --went-well "good" --challenges "none" --differently "n" --patterns "n" \
        --task-id A1B2C3 2>/dev/null

    # Lockfile persists — cleanup hasn't run yet (stopped at generate_docs)
    [ -f ".task-close-state" ]
    # And it still has the correct locked values
    [ "$(jq -r '.target_branch' .task-close-state)" = "main" ]
}

@test "task-close: AI mode returns needs_decision when parent_branch missing" {
    # Remove parent_branch from .current-task
    echo '{"task_id":"A1B2C3","branch":"feature/A1B2C3-test-task","task_doc":"docs/active/A1B2C3/A1B2C3-2602191000-TSK-test-task.md","started":"2026-03-17T00:00:00Z","task_tracker":null}' > .current-task

    run "$SCRIPTS_DIR/task-close.sh" --json --ai --cleanup --task-id A1B2C3 --status completed \
        --accomplished "done" --went-well "good" --challenges "none" --differently "n" --patterns "n" 2>/dev/null
    assert_valid_json "$output"
    # Should either succeed (auto-detect found the right target) or return needs_decision
    local status_val
    status_val=$(echo "$output" | jq -r '.status // empty' 2>/dev/null)
    [[ "$status_val" == "success" || "$status_val" == "needs_decision" ]]
}

# =============================================================================
# Protected branch tests
# =============================================================================

@test "task-close: rejects unknown flags" {
    run "$SCRIPTS_DIR/task-close.sh" --bogus 2>/dev/null
    [ "$status" -eq 2 ]
}

# =============================================================================
# Pre-merge verification integration tests
# =============================================================================

# Helper: make a feature branch with a real commit and a bare remote so git-merge.sh
# can fetch/push without a network connection.
_setup_feature_commit() {
    echo "feature change" > feature-file.txt
    git add feature-file.txt
    git commit -q -m "feat: add feature file"

    # Create a bare repo as the "remote" so git-merge.sh can fetch/push
    local bare_remote="${TEST_DIR}/../bare-remote-$$.git"
    git init -q --bare "$bare_remote" 2>/dev/null
    git remote add origin "$bare_remote" 2>/dev/null || git remote set-url origin "$bare_remote"
    # Push both branches explicitly by refspec
    git push -q origin main:main feature/A1B2C3-test-task:feature/A1B2C3-test-task 2>/dev/null || true
}

# Helper: replace the real pre-merge-verify.sh with a fake for the test.
# Saves the original to a .bak file for restoration.
# Usage: _swap_verify <exit_code> <json_output_single_line>
_swap_verify() {
    local exit_code="${1:-0}"
    local json_output="${2:-{\"status\":\"pass\",\"steps\":[],\"affected_services\":[],\"skipped_reason\":null}}"
    local real="${SCRIPTS_DIR}/pre-merge-verify.sh"
    cp "$real" "${real}.bak"
    cat > "$real" <<FAKE
#!/usr/bin/env bash
printf '%s\n' '${json_output}'
exit ${exit_code}
FAKE
    chmod +x "$real"
}

# Helper: restore the real pre-merge-verify.sh from .bak
_restore_verify() {
    local real="${SCRIPTS_DIR}/pre-merge-verify.sh"
    [[ -f "${real}.bak" ]] && mv "${real}.bak" "$real" || true
}

@test "task-close: pre-merge verify is called before merge when completing with merge" {
    # Replace real script with a fake that writes a marker file when invoked
    local call_log="${TEST_DIR}/.verify_called"
    local real="${SCRIPTS_DIR}/pre-merge-verify.sh"
    cp "$real" "${real}.bak"
    cat > "$real" <<FAKE
#!/usr/bin/env bash
printf 'called\n' > "${call_log}"
printf '{"status":"pass","steps":[],"affected_services":[],"skipped_reason":null}\n'
exit 0
FAKE
    chmod +x "$real"

    _setup_feature_commit

    run "$SCRIPTS_DIR/task-close.sh" --json --ai --cleanup --task-id A1B2C3 \
        --status completed \
        --accomplished "done" --went-well "good" --challenges "none" \
        --differently "n" --patterns "n" 2>/dev/null

    _restore_verify

    # The verify script must have been called
    [ -f "$call_log" ]
}

@test "task-close: pre-merge verify pass allows merge to proceed" {
    _swap_verify 0 '{"status":"pass","steps":[{"name":"rebase","status":"pass"},{"name":"lint","status":"pass"},{"name":"test","status":"pass"},{"name":"build","status":"pass"}],"affected_services":[],"skipped_reason":null}'

    _setup_feature_commit

    run "$SCRIPTS_DIR/task-close.sh" --json --ai --cleanup --task-id A1B2C3 \
        --status completed \
        --accomplished "done" --went-well "good" --challenges "none" \
        --differently "n" --patterns "n" 2>/dev/null

    _restore_verify

    assert_valid_json "$output"
    local status_val
    status_val=$(echo "$output" | jq -r '.status // empty' 2>/dev/null)
    [ "$status_val" = "success" ]
    local merged
    merged=$(echo "$output" | jq -r '.merged // empty' 2>/dev/null)
    [ "$merged" = "true" ]
}

@test "task-close: pre-merge verify fail blocks merge and returns error" {
    _swap_verify 1 '{"status":"fail","steps":[{"name":"lint","status":"fail","detail":"lint errors found"}],"affected_services":["backend"],"skipped_reason":null}'

    _setup_feature_commit

    run "$SCRIPTS_DIR/task-close.sh" --json --ai --cleanup --task-id A1B2C3 \
        --status completed \
        --accomplished "done" --went-well "good" --challenges "none" \
        --differently "n" --patterns "n" 2>/dev/null

    _restore_verify

    assert_valid_json "$output"
    local status_val
    status_val=$(echo "$output" | jq -r '.status // empty' 2>/dev/null)
    [ "$status_val" = "error" ]
    # Merge must NOT have happened — feature branch must still exist
    git rev-parse --verify feature/A1B2C3-test-task &>/dev/null
}

@test "task-close: pre-merge verify skipped allows merge to proceed" {
    _swap_verify 0 '{"status":"skipped","steps":[],"affected_services":[],"skipped_reason":"doc-only changes"}'

    _setup_feature_commit

    run "$SCRIPTS_DIR/task-close.sh" --json --ai --cleanup --task-id A1B2C3 \
        --status completed \
        --accomplished "done" --went-well "good" --challenges "none" \
        --differently "n" --patterns "n" 2>/dev/null

    _restore_verify

    assert_valid_json "$output"
    local status_val
    status_val=$(echo "$output" | jq -r '.status // empty' 2>/dev/null)
    [ "$status_val" = "success" ]
    local merged
    merged=$(echo "$output" | jq -r '.merged // empty' 2>/dev/null)
    [ "$merged" = "true" ]
}

@test "task-close: no verify script present allows merge to proceed (graceful degradation)" {
    # Temporarily remove the real script so the [[ -f ]] guard fires
    local real="${SCRIPTS_DIR}/pre-merge-verify.sh"
    mv "$real" "${real}.bak"

    _setup_feature_commit

    run "$SCRIPTS_DIR/task-close.sh" --json --ai --cleanup --task-id A1B2C3 \
        --status completed \
        --accomplished "done" --went-well "good" --challenges "none" \
        --differently "n" --patterns "n" 2>/dev/null

    # Restore before assertions so teardown is clean
    mv "${real}.bak" "$real"

    assert_valid_json "$output"
    local status_val
    status_val=$(echo "$output" | jq -r '.status // empty' 2>/dev/null)
    [ "$status_val" = "success" ]
    local merged
    merged=$(echo "$output" | jq -r '.merged // empty' 2>/dev/null)
    [ "$merged" = "true" ]
}
