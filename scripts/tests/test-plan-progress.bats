#!/usr/bin/env bats

# Test suite: plan-progress.sh comprehensive behavior
#
# Purpose: Lock down plan-progress.sh before refactoring.
# Tests: progress counting, mark-complete, phase detection, next items.

load test_helper

setup() {
    common_setup
    setup_mock_git_repo

    # Create PLN fixture
    mkdir -p docs/active/0000-0099

    cat > docs/active/0000-0099/0001-2602140923-PLN-test-task.md << 'PLNEOF'
# Plan: Test Task Implementation

## Work Agent
haiku

## Test Agent
sonnet

## Testing
- has_tests: true
- scope: task

## Subtasks

### Phase 1: Foundation
- [x] 1.1 Set up project structure
- [x] 1.2 Install dependencies
- [ ] 1.3 Create configuration files

### Phase 2: Core Implementation
- [ ] 2.1 Implement main module
- [ ] 2.2 Add error handling
- [ ] 2.3 Create API endpoints

### Phase 3: Testing & Docs
- [ ] 3.1 Write unit tests
- [ ] 3.2 Write integration tests
- [ ] 3.3 Add documentation

## Lessons Learned
- None yet
PLNEOF

    PLN_FILE="docs/active/0000-0099/0001-2602140923-PLN-test-task.md"

    # Also create TSK doc and .current-task for auto-detection
    cat > docs/active/0000-0099/0001-2602140922-TSK-test-task.md << 'TSKEOF'
# Test Task
## Status: in-progress
## Branch
`feature/0001-test-task`
TSKEOF

    echo '{"task_id":"0001","branch":"feature/0001-test-task","parent_branch":"main","task_doc":"docs/active/0000-0099/0001-2602140922-TSK-test-task.md","started":"2026-03-17T00:00:00Z","task_tracker":null}' > .current-task

    git add -A
    git commit -q -m "add task docs"
    git checkout -q -b feature/0001-test-task
}

teardown() {
    common_teardown
}

# =============================================================================
# Basic progress counting
# =============================================================================

@test "plan-progress: counts total subtasks" {
    run "$SCRIPTS_DIR/plan-progress.sh" --json --file "$PLN_FILE" 2>/dev/null
    assert_valid_json "$output"
    local total
    total=$(echo "$output" | jq -r '.progress.total')
    [ "$total" -eq 9 ]
}

@test "plan-progress: counts completed subtasks" {
    run "$SCRIPTS_DIR/plan-progress.sh" --json --file "$PLN_FILE" 2>/dev/null
    assert_valid_json "$output"
    local done
    done=$(echo "$output" | jq -r '.progress.done')
    [ "$done" -eq 2 ]
}

@test "plan-progress: calculates percentage" {
    run "$SCRIPTS_DIR/plan-progress.sh" --json --file "$PLN_FILE" 2>/dev/null
    assert_valid_json "$output"
    local percent
    percent=$(echo "$output" | jq -r '.progress.percent')
    [ "$percent" -eq 22 ]
}

@test "plan-progress: returns success status" {
    run "$SCRIPTS_DIR/plan-progress.sh" --json --file "$PLN_FILE" 2>/dev/null
    assert_json_field "$output" ".status" "success"
}

# =============================================================================
# Next items
# =============================================================================

@test "plan-progress: identifies next unchecked items" {
    run "$SCRIPTS_DIR/plan-progress.sh" --json --file "$PLN_FILE" 2>/dev/null
    assert_valid_json "$output"
    assert_json_field_present "$output" ".next_items"
    # First next item should be 1.3
    local first_next
    first_next=$(echo "$output" | jq -r '.next_items[0]')
    [[ "$first_next" == *"1.3"* ]]
}

# =============================================================================
# Mark complete
# =============================================================================

@test "plan-progress: mark-complete changes checkbox" {
    run "$SCRIPTS_DIR/plan-progress.sh" --json --file "$PLN_FILE" \
        --mark-complete "1.3 Create configuration files" 2>/dev/null
    assert_valid_json "$output"

    # Verify checkbox changed in file
    grep -q "\[x\] 1.3 Create configuration files" "$PLN_FILE"
}

@test "plan-progress: mark-complete updates counts" {
    run "$SCRIPTS_DIR/plan-progress.sh" --json --file "$PLN_FILE" \
        --mark-complete "1.3 Create configuration files" 2>/dev/null
    assert_valid_json "$output"
    local done
    done=$(echo "$output" | jq -r '.progress.done')
    [ "$done" -eq 3 ]
}

@test "plan-progress: mark-complete reports error for already-checked items" {
    run "$SCRIPTS_DIR/plan-progress.sh" --json --file "$PLN_FILE" \
        --mark-complete "1.1 Set up project structure" 2>/dev/null
    assert_valid_json "$output"
    # Already-checked items can't be found by mark-complete (it searches unchecked)
    assert_json_field "$output" ".status" "error"
}

# =============================================================================
# Work agent and test agent extraction
# =============================================================================

@test "plan-progress: extracts work_agent from plan" {
    run "$SCRIPTS_DIR/plan-progress.sh" --json --file "$PLN_FILE" 2>/dev/null
    assert_valid_json "$output"
    local work_agent
    work_agent=$(echo "$output" | jq -r '.work_agent // empty')
    if [[ -n "$work_agent" ]]; then
        [ "$work_agent" = "haiku" ]
    fi
}

@test "plan-progress: extracts test_agent from plan" {
    run "$SCRIPTS_DIR/plan-progress.sh" --json --file "$PLN_FILE" 2>/dev/null
    assert_valid_json "$output"
    local test_agent
    test_agent=$(echo "$output" | jq -r '.test_agent // empty')
    if [[ -n "$test_agent" ]]; then
        [ "$test_agent" = "sonnet" ]
    fi
}

# =============================================================================
# Testing config extraction
# =============================================================================

@test "plan-progress: extracts testing config" {
    run "$SCRIPTS_DIR/plan-progress.sh" --json --file "$PLN_FILE" 2>/dev/null
    assert_valid_json "$output"
    local has_tests
    has_tests=$(echo "$output" | jq -r '.testing.has_tests // empty')
    if [[ -n "$has_tests" ]]; then
        [ "$has_tests" = "true" ]
    fi
}

# =============================================================================
# Error handling
# =============================================================================

@test "plan-progress: errors on non-existent file" {
    run "$SCRIPTS_DIR/plan-progress.sh" --json --file "nonexistent.md" 2>/dev/null
    assert_valid_json "$output"
    assert_json_field "$output" ".status" "error"
}

@test "plan-progress: errors with no file specified and no .current-task" {
    rm -f .current-task
    # Remove all PLN files so script can't auto-discover
    find . -name "*-PLN-*" -delete 2>/dev/null || true
    git checkout -q main 2>/dev/null || git checkout -q master 2>/dev/null
    run "$SCRIPTS_DIR/plan-progress.sh" --json 2>/dev/null
    assert_valid_json "$output"
    assert_json_field "$output" ".status" "error"
}

# =============================================================================
# Phase detection
# =============================================================================

@test "plan-progress: identifies current phase" {
    run "$SCRIPTS_DIR/plan-progress.sh" --json --file "$PLN_FILE" 2>/dev/null
    assert_valid_json "$output"
    assert_json_field_present "$output" ".current_phase"
}

# =============================================================================
# All-complete scenario
# =============================================================================

@test "plan-progress: reports 100% when all done" {
    # Create a fully-complete plan
    cat > "${TEST_DIR}/done-plan.md" << 'EOF'
# Plan: Done

## Subtasks
### Phase 1
- [x] 1.1 Task A
- [x] 1.2 Task B
EOF

    run "$SCRIPTS_DIR/plan-progress.sh" --json --file "${TEST_DIR}/done-plan.md" 2>/dev/null
    assert_valid_json "$output"
    local percent
    percent=$(echo "$output" | jq -r '.progress.percent')
    [ "$percent" -eq 100 ]
}

# =============================================================================
# PLN template: Execution Config fields
# =============================================================================

@test "plan-progress: PLN template contains per-task TDD Required field" {
    local template="$HOME/.claude/templates/task-PLN.md"
    grep -q '\*\*TDD Required\*\*' "$template"
}

@test "plan-progress: PLN template contains per-task Auto Review field" {
    local template="$HOME/.claude/templates/task-PLN.md"
    grep -q '\*\*Auto Review\*\*' "$template"
}

@test "plan-progress: PLN template contains per-task Review Type field" {
    local template="$HOME/.claude/templates/task-PLN.md"
    grep -q '\*\*Review Type\*\*' "$template"
}

@test "plan-progress: PLN template contains per-task Fresh Context field" {
    local template="$HOME/.claude/templates/task-PLN.md"
    grep -q '\*\*Fresh Context\*\*' "$template"
}

# =============================================================================
# Backward compatibility: PLN without execution config fields
# =============================================================================

@test "plan-progress: works with PLN missing execution config fields" {
    # The existing PLN_FILE fixture has no execution config section
    # This test verifies plan-progress.sh doesn't fail on it
    run "$SCRIPTS_DIR/plan-progress.sh" --json --file "$PLN_FILE" 2>/dev/null
    assert_valid_json "$output"
    assert_json_field "$output" ".status" "success"
    local total
    total=$(echo "$output" | jq -r '.progress.total')
    [ "$total" -eq 9 ]
}

@test "plan-progress: works with PLN that has execution config fields" {
    # Add execution config section to the fixture
    local plan_with_config="${TEST_DIR}/plan-with-config.md"
    cat > "$plan_with_config" << 'EOF'
# Plan: Test With Config

## Execution Config

- **auto_review**: yes
- **tdd_required**: recommend
- **review_type**: single
- **fresh_context**: no

## Subtasks
### Phase 1
- [x] 1.1 Task A
- [ ] 1.2 Task B
EOF

    run "$SCRIPTS_DIR/plan-progress.sh" --json --file "$plan_with_config" 2>/dev/null
    assert_valid_json "$output"
    assert_json_field "$output" ".status" "success"
    local total
    total=$(echo "$output" | jq -r '.progress.total')
    [ "$total" -eq 2 ]
}

# =============================================================================
# Execution Config: command file contains default rules
# =============================================================================

@test "plan-progress: task-plan command contains per-task execution config rules" {
    # Read from the repo command file rather than the installed copy under
    # ~/.claude so the test works in CI / fresh clones / agent worktrees
    # where the install step may not have run.
    local cmd="${BATS_TEST_DIRNAME}/../../commands/task-plan.md"
    [ -f "$cmd" ] || cmd="$HOME/.claude/commands/task-plan.md"

    # Verify per-task field names are documented (human-readable form).
    grep -q '\*\*TDD Required\*\*' "$cmd"
    grep -q '\*\*Auto Review\*\*' "$cmd"
    grep -q '\*\*Review Type\*\*' "$cmd"
    grep -q '\*\*Fresh Context\*\*' "$cmd"

    # Verify complexity-based defaults are documented. The doc now uses the
    # display form `TDD Required: yes` / `TDD Required: no` (matches the
    # field label) rather than the snake_case key form `tdd_required:`.
    grep -qE 'TDD Required:\s*yes' "$cmd"
    grep -qE 'TDD Required:\s*no' "$cmd"
}

# =============================================================================
# next_task_config extraction from task blocks
# =============================================================================

@test "plan-progress: extracts all 6 execution config fields from next task" {
    cat > "${TEST_DIR}/plan-with-task-config.md" << 'EOF'
# Plan: Config Test

### Phase 1: Work
#### Task 1.1: [x] Done task
- **Work Model**: Opus
- **Test Model**: Sonnet
- **TDD Required**: yes
- **Auto Review**: yes
- **Review Type**: two-stage
- **Fresh Context**: yes

#### Task 1.2: [ ] Next task
- **Description**: Do the thing
- **Files**: `some/file.sh`
- **Work Model**: Haiku
- **Test Model**: Sonnet
- **Complexity**: S
- **Estimated Time**: 30m
- **TDD Required**: recommend
- **Auto Review**: yes
- **Review Type**: two-stage
- **Fresh Context**: yes
EOF

    run "$SCRIPTS_DIR/plan-progress.sh" --json --file "${TEST_DIR}/plan-with-task-config.md" 2>/dev/null
    assert_valid_json "$output"
    [ "$(echo "$output" | jq -r '.next_task_config.work_model')" = "haiku" ]
    [ "$(echo "$output" | jq -r '.next_task_config.test_model')" = "sonnet" ]
    [ "$(echo "$output" | jq -r '.next_task_config.tdd_required')" = "recommend" ]
    [ "$(echo "$output" | jq -r '.next_task_config.auto_review')" = "yes" ]
    [ "$(echo "$output" | jq -r '.next_task_config.review_type')" = "two-stage" ]
    [ "$(echo "$output" | jq -r '.next_task_config.fresh_context')" = "yes" ]
}

@test "plan-progress: defaults when execution config fields missing" {
    # The existing PLN_FILE fixture has no per-task execution config
    run "$SCRIPTS_DIR/plan-progress.sh" --json --file "$PLN_FILE" 2>/dev/null
    assert_valid_json "$output"
    [ "$(echo "$output" | jq -r '.next_task_config.work_model')" = "sonnet" ]
    [ "$(echo "$output" | jq -r '.next_task_config.test_model')" = "n/a" ]
    [ "$(echo "$output" | jq -r '.next_task_config.tdd_required')" = "no" ]
    [ "$(echo "$output" | jq -r '.next_task_config.auto_review')" = "no" ]
    [ "$(echo "$output" | jq -r '.next_task_config.review_type')" = "single" ]
    [ "$(echo "$output" | jq -r '.next_task_config.fresh_context')" = "no" ]
}

@test "plan-progress: invalid field values fall back to defaults" {
    cat > "${TEST_DIR}/plan-bad-values.md" << 'EOF'
# Plan: Bad Values

### Phase 1
#### Task 1.1: [ ] Bad config task
- **TDD Required**: maybe
- **Auto Review**: sometimes
- **Review Type**: triple-stage
- **Fresh Context**: perhaps
EOF

    run "$SCRIPTS_DIR/plan-progress.sh" --json --file "${TEST_DIR}/plan-bad-values.md" 2>/dev/null
    assert_valid_json "$output"
    [ "$(echo "$output" | jq -r '.next_task_config.tdd_required')" = "no" ]
    [ "$(echo "$output" | jq -r '.next_task_config.auto_review')" = "no" ]
    [ "$(echo "$output" | jq -r '.next_task_config.review_type')" = "single" ]
    [ "$(echo "$output" | jq -r '.next_task_config.fresh_context')" = "no" ]
}

@test "plan-progress: no next_task_config when all tasks complete" {
    cat > "${TEST_DIR}/done-plan.md" << 'EOF'
# Plan: Done
### Phase 1
- [x] 1.1 Task A
- [x] 1.2 Task B
EOF

    run "$SCRIPTS_DIR/plan-progress.sh" --json --file "${TEST_DIR}/done-plan.md" 2>/dev/null
    assert_valid_json "$output"
    [ "$(echo "$output" | jq -r '.next_task_config // "absent"')" = "absent" ]
}

@test "plan-progress: extracts config from first unchecked task only" {
    cat > "${TEST_DIR}/plan-multi-task.md" << 'EOF'
# Plan: Multi
### Phase 1
#### Task 1.1: [ ] First task
- **Work Model**: Haiku
- **Auto Review**: no
- **Fresh Context**: no

#### Task 1.2: [ ] Second task
- **Work Model**: Opus
- **Auto Review**: yes
- **Fresh Context**: yes
EOF

    run "$SCRIPTS_DIR/plan-progress.sh" --json --file "${TEST_DIR}/plan-multi-task.md" 2>/dev/null
    assert_valid_json "$output"
    # Should get config from Task 1.1, not 1.2
    [ "$(echo "$output" | jq -r '.next_task_config.work_model')" = "haiku" ]
    [ "$(echo "$output" | jq -r '.next_task_config.auto_review')" = "no" ]
    [ "$(echo "$output" | jq -r '.next_task_config.fresh_context')" = "no" ]
}
