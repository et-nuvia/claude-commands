#!/usr/bin/env bats

# Test suite: task-continue.sh review config passthrough
#
# Verifies that section_full() correctly extracts next_task_config fields from
# plan-progress.sh output and promotes them to top-level JSON fields.

load test_helper

TASK_ID="A1B2C3"
TASK_BRANCH="feature/A1B2C3-test-task"

setup() {
    common_setup
    setup_mock_git_repo
    git checkout -q -b "$TASK_BRANCH"

    # Mock yq to return null for PROJECT.yaml queries (no test config)
    create_mock "yq" "null"

    # Create docs structure
    mkdir -p docs/active/A1B2C3

    # Create TSK document
    cat > docs/active/A1B2C3/A1B2C3-2603120001-TSK-test-task.md << 'EOF'
# Test Task
## Status: in-progress
## Branch
`feature/A1B2C3-test-task`
EOF

    # Commit docs so git is clean
    git add -A
    git commit -q -m "add task docs"

    # Write .current-task after commit (it's gitignored in real use)
    echo '{"task_id":"A1B2C3","branch":"feature/A1B2C3-test-task","parent_branch":"main","task_doc":"docs/active/A1B2C3/A1B2C3-2603120001-TSK-test-task.md","started":"2026-03-17T00:00:00Z","task_tracker":null}' > .current-task
}

teardown() {
    common_teardown
}

# =============================================================================
# Group 1: All execution config fields present in PLN
# =============================================================================

@test "review config: all fields from per-task config pass through to output" {
    cat > docs/active/A1B2C3/A1B2C3-2603120002-PLN-test-task.md << 'EOF'
# Plan: Test

## Subtasks

### Phase 1: Work
#### Task 1.1: [x] Done task
- **Work Model**: Opus
- **TDD Required**: yes

#### Task 1.2: [ ] Next task
- **Work Model**: Haiku
- **Test Model**: Sonnet
- **TDD Required**: recommend
- **Auto Review**: yes
- **Review Type**: two-stage
- **Fresh Context**: yes

## Progress & Lessons Learned

EOF

    git add -A && git commit -q -m "add plan"

    run "$SCRIPTS_DIR/task-continue.sh" --json --full --task-id A1B2C3 2>/dev/null
    assert_valid_json "$output"
    assert_json_field "$output" ".status" "success"
    assert_json_field "$output" ".review_type" "two-stage"
    assert_json_field "$output" ".fresh_context" "yes"
    assert_json_field "$output" ".auto_review" "yes"
}

@test "review config: work_agent and test_agent from per-task config" {
    cat > docs/active/A1B2C3/A1B2C3-2603120002-PLN-test-task.md << 'EOF'
# Plan: Test

## Subtasks

### Phase 1: Work
#### Task 1.1: [x] Done task

#### Task 1.2: [ ] Next task
- **Work Model**: Haiku
- **Test Model**: Sonnet

## Progress & Lessons Learned

EOF

    git add -A && git commit -q -m "add plan"

    run "$SCRIPTS_DIR/task-continue.sh" --json --full --task-id A1B2C3 2>/dev/null
    assert_valid_json "$output"
    assert_json_field "$output" ".work_agent" "haiku"
    assert_json_field "$output" ".test_agent" "sonnet"
}

# =============================================================================
# Group 2: Missing fields default correctly
# =============================================================================

@test "review config: missing fields default to single/no/no" {
    # Simple flat checklist — no per-task config blocks
    cat > docs/active/A1B2C3/A1B2C3-2603120002-PLN-test-task.md << 'EOF'
# Plan: Test

## Subtasks

### Phase 1: Work
- [x] 1.1 Done item
- [ ] 1.2 Next item

## Progress & Lessons Learned

EOF

    git add -A && git commit -q -m "add plan"

    run "$SCRIPTS_DIR/task-continue.sh" --json --full --task-id A1B2C3 2>/dev/null
    assert_valid_json "$output"
    assert_json_field "$output" ".review_type" "single"
    assert_json_field "$output" ".fresh_context" "no"
    assert_json_field "$output" ".auto_review" "no"
}

@test "review config: output is valid JSON with all top-level fields present" {
    cat > docs/active/A1B2C3/A1B2C3-2603120002-PLN-test-task.md << 'EOF'
# Plan: Test

## Subtasks

### Phase 1: Work
- [ ] 1.1 Only item

## Progress & Lessons Learned

EOF

    git add -A && git commit -q -m "add plan"

    run "$SCRIPTS_DIR/task-continue.sh" --json --full --task-id A1B2C3 2>/dev/null
    assert_valid_json "$output"
    assert_json_field_present "$output" ".review_type"
    assert_json_field_present "$output" ".fresh_context"
    assert_json_field_present "$output" ".auto_review"
    assert_json_field_present "$output" ".work_agent"
    assert_json_field_present "$output" ".test_agent"
}

# =============================================================================
# Group 3: Backward compatible with old doc-level Work Agent / Test Agent headers
# =============================================================================

@test "review config: old format PLN uses plan-progress defaults for work_agent" {
    # Old-format PLNs (flat checklists, no per-task config blocks) get
    # plan-progress.sh defaults (work_model=sonnet), not doc-level headers
    cat > docs/active/A1B2C3/A1B2C3-2603120002-PLN-test-task.md << 'EOF'
# Plan: Test

## Work Agent
haiku

## Test Agent
sonnet

## Subtasks
### Phase 1
- [x] 1.1 Done
- [ ] 1.2 Next item

## Progress & Lessons Learned

EOF

    git add -A && git commit -q -m "add plan"

    run "$SCRIPTS_DIR/task-continue.sh" --json --full --task-id A1B2C3 2>/dev/null
    assert_valid_json "$output"
    # plan-progress.sh default work_model=sonnet takes priority over doc-level header
    assert_json_field "$output" ".work_agent" "sonnet"
}

@test "review config: old format PLN review fields default correctly" {
    cat > docs/active/A1B2C3/A1B2C3-2603120002-PLN-test-task.md << 'EOF'
# Plan: Test

## Work Agent
haiku

## Test Agent
sonnet

## Subtasks
### Phase 1
- [x] 1.1 Done
- [ ] 1.2 Next item

## Progress & Lessons Learned

EOF

    git add -A && git commit -q -m "add plan"

    run "$SCRIPTS_DIR/task-continue.sh" --json --full --task-id A1B2C3 2>/dev/null
    assert_valid_json "$output"
    assert_json_field "$output" ".review_type" "single"
    assert_json_field "$output" ".fresh_context" "no"
    assert_json_field "$output" ".auto_review" "no"
}

@test "review config: per-task config overrides doc-level headers" {
    # When per-task config exists, it takes full priority
    cat > docs/active/A1B2C3/A1B2C3-2603120002-PLN-test-task.md << 'EOF'
# Plan: Test

## Work Agent
opus

## Test Agent
sonnet

## Subtasks

### Phase 1: Work
#### Task 1.1: [x] Done task

#### Task 1.2: [ ] Next task
- **Work Model**: Haiku
- **Test Model**: Haiku

## Progress & Lessons Learned

EOF

    git add -A && git commit -q -m "add plan"

    run "$SCRIPTS_DIR/task-continue.sh" --json --full --task-id A1B2C3 2>/dev/null
    assert_valid_json "$output"
    assert_json_field "$output" ".work_agent" "haiku"
    assert_json_field "$output" ".test_agent" "haiku"
}

# =============================================================================
# Group 4: Auto review gate behavior (AC-mapped)
# =============================================================================

@test "auto review gate: auto_review yes triggers review gate" {
    # AC1: auto_review=yes in per-task config is passed through to output,
    # which is what the command layer uses to decide whether to invoke the gate
    cat > docs/active/A1B2C3/A1B2C3-2603120002-PLN-test-task.md << 'EOF'
# Plan: Test

## Subtasks

### Phase 1: Work
#### Task 1.1: [x] Done task

#### Task 1.2: [ ] Next task
- **Auto Review**: yes

## Progress & Lessons Learned

EOF

    git add -A && git commit -q -m "add plan"

    run "$SCRIPTS_DIR/task-continue.sh" --json --full --task-id A1B2C3 2>/dev/null
    assert_valid_json "$output"
    assert_json_field "$output" ".auto_review" "yes"
}

@test "auto review gate: auto_review no skips review gate" {
    # AC2: auto_review=no in per-task config is passed through to output,
    # signalling the command layer to skip the review gate entirely
    cat > docs/active/A1B2C3/A1B2C3-2603120002-PLN-test-task.md << 'EOF'
# Plan: Test

## Subtasks

### Phase 1: Work
#### Task 1.1: [x] Done task

#### Task 1.2: [ ] Next task
- **Auto Review**: no

## Progress & Lessons Learned

EOF

    git add -A && git commit -q -m "add plan"

    run "$SCRIPTS_DIR/task-continue.sh" --json --full --task-id A1B2C3 2>/dev/null
    assert_valid_json "$output"
    assert_json_field "$output" ".auto_review" "no"
}

@test "auto review gate: missing auto_review defaults to skip" {
    # AC3: when no per-task config exists at all, auto_review defaults to "no"
    # so the review gate is skipped unless explicitly opted in
    cat > docs/active/A1B2C3/A1B2C3-2603120002-PLN-test-task.md << 'EOF'
# Plan: Test

## Subtasks

### Phase 1: Work
- [x] 1.1 Done item
- [ ] 1.2 Next item

## Progress & Lessons Learned

EOF

    git add -A && git commit -q -m "add plan"

    run "$SCRIPTS_DIR/task-continue.sh" --json --full --task-id A1B2C3 2>/dev/null
    assert_valid_json "$output"
    assert_json_field "$output" ".auto_review" "no"
}

# =============================================================================
# Group 5: TDD Enforcement
# =============================================================================

@test "tdd enforcement: tdd_required yes appears in full output" {
    cat > docs/active/A1B2C3/A1B2C3-2603120002-PLN-test-task.md << 'EOF'
# Plan: Test

## Subtasks

### Phase 1: Work
#### Task 1.1: [x] Done task

#### Task 1.2: [ ] Next task
- **TDD Required**: yes

## Progress & Lessons Learned

EOF

    git add -A && git commit -q -m "add plan"

    run "$SCRIPTS_DIR/task-continue.sh" --json --full --task-id A1B2C3 2>/dev/null
    assert_valid_json "$output"
    assert_json_field "$output" ".tdd_required" "yes"
}

@test "tdd enforcement: tdd_required no appears in full output" {
    cat > docs/active/A1B2C3/A1B2C3-2603120002-PLN-test-task.md << 'EOF'
# Plan: Test

## Subtasks

### Phase 1: Work
#### Task 1.1: [x] Done task

#### Task 1.2: [ ] Next task
- **TDD Required**: no

## Progress & Lessons Learned

EOF

    git add -A && git commit -q -m "add plan"

    run "$SCRIPTS_DIR/task-continue.sh" --json --full --task-id A1B2C3 2>/dev/null
    assert_valid_json "$output"
    assert_json_field "$output" ".tdd_required" "no"
}

@test "tdd enforcement: missing tdd_required defaults to no in full output" {
    cat > docs/active/A1B2C3/A1B2C3-2603120002-PLN-test-task.md << 'EOF'
# Plan: Test

## Subtasks

### Phase 1: Work
#### Task 1.1: [x] Done task

#### Task 1.2: [ ] Next task
- **Work Model**: Sonnet

## Progress & Lessons Learned

EOF

    git add -A && git commit -q -m "add plan"

    run "$SCRIPTS_DIR/task-continue.sh" --json --full --task-id A1B2C3 2>/dev/null
    assert_valid_json "$output"
    assert_json_field "$output" ".tdd_required" "no"
}

@test "tdd enforcement: tdd_required yes blocks commit with production-only files" {
    cat > docs/active/A1B2C3/A1B2C3-2603120002-PLN-test-task.md << 'EOF'
# Plan: Test

## Subtasks

### Phase 1: Work
#### Task 1.1: [x] Done task

#### Task 1.2: [ ] Next task
- **TDD Required**: yes

## Progress & Lessons Learned

EOF

    git add -A && git commit -q -m "add plan"

    # Create a production file (not a test file, not docs/yaml/json/md)
    mkdir -p scripts
    echo "#!/usr/bin/env bash" > scripts/my-feature.sh

    run "$SCRIPTS_DIR/task-continue.sh" --json --commit --task-id A1B2C3 --progress-note "test commit" 2>/dev/null
    assert_json_field "$output" ".status" "blocked"
    assert_json_field "$output" ".next_action" "write_test_first"
}

@test "tdd enforcement: tdd_required yes allows commit when test file is present" {
    cat > docs/active/A1B2C3/A1B2C3-2603120002-PLN-test-task.md << 'EOF'
# Plan: Test

## Subtasks

### Phase 1: Work
#### Task 1.1: [x] Done task

#### Task 1.2: [ ] Next task
- **TDD Required**: yes

## Progress & Lessons Learned

EOF

    git add -A && git commit -q -m "add plan"

    # Create both a production file and a test file
    mkdir -p scripts/tests
    echo "#!/usr/bin/env bash" > scripts/my-feature.sh
    echo "# bats test file" > scripts/tests/test-my-feature.bats

    run "$SCRIPTS_DIR/task-continue.sh" --json --commit --task-id A1B2C3 --progress-note "test commit" 2>/dev/null
    assert_json_field "$output" ".status" "success"
}

@test "tdd enforcement: tdd_required recommend blocks commit without tests" {
    cat > docs/active/A1B2C3/A1B2C3-2603120002-PLN-test-task.md << 'EOF'
# Plan: Test

## Subtasks

### Phase 1: Work
#### Task 1.1: [x] Done task

#### Task 1.2: [ ] Next task
- **TDD Required**: recommend

## Progress & Lessons Learned

EOF

    git add -A && git commit -q -m "add plan"

    # Create only a production file (no test file)
    mkdir -p scripts
    echo "#!/usr/bin/env bash" > scripts/my-feature.sh

    run "$SCRIPTS_DIR/task-continue.sh" --json --commit --task-id A1B2C3 --progress-note "test commit" 2>/dev/null
    # "recommend" is treated the same as "yes" — blocks commit without tests
    assert_json_field "$output" ".status" "blocked"
    assert_json_field "$output" ".next_action" "write_test_first"
}

@test "tdd enforcement: tdd_required no skips check and omits tdd_warning" {
    cat > docs/active/A1B2C3/A1B2C3-2603120002-PLN-test-task.md << 'EOF'
# Plan: Test

## Subtasks

### Phase 1: Work
#### Task 1.1: [x] Done task

#### Task 1.2: [ ] Next task
- **TDD Required**: no

## Progress & Lessons Learned

EOF

    git add -A && git commit -q -m "add plan"

    # Create only a production file (no test file)
    mkdir -p scripts
    echo "#!/usr/bin/env bash" > scripts/my-feature.sh

    run "$SCRIPTS_DIR/task-continue.sh" --json --commit --task-id A1B2C3 --progress-note "test commit" 2>/dev/null
    assert_json_field "$output" ".status" "success"
    # Should NOT include a tdd_warning field
    run bash -c "echo '$output' | jq -e '.tdd_warning' 2>/dev/null"
    [ "$status" -ne 0 ]
}
