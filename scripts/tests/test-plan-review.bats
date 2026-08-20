#!/usr/bin/env bats

# Test suite: task-plan.sh --review section
#
# Purpose: Validate PLN document quality checks — subtask sizing,
# acceptance criteria, dependency ordering, execution config fields.

load test_helper

setup() {
    common_setup
    setup_mock_git_repo

    mkdir -p docs/active/0000-0099

    # Valid PLN — all checks should pass
    cat > docs/active/0000-0099/VALID-PLN.md << 'EOF'
# Plan: Valid Test Plan

## Approach

### Phase 1: Setup
**Objective**: Set things up.

#### Task 1.1: [ ] [AC1] Create config file
- **Description**: Create the config file.
- **Files**: `config.yaml`
- **Dependencies**: none
- **Work Model**: Haiku
- **Test Model**: n/a
- **Complexity**: XS
- **Estimated Time**: 10m
- **TDD Required**: no
- **Auto Review**: no
- **Review Type**: single
- **Fresh Context**: no

#### Task 1.2: [ ] [AC2] Implement feature
- **Description**: Build the feature.
- **Files**: `src/feature.sh`
- **Dependencies**: Task 1.1
- **Work Model**: Sonnet
- **Test Model**: haiku
- **Complexity**: S
- **Estimated Time**: 30m
- **TDD Required**: yes
- **Auto Review**: yes
- **Review Type**: single
- **Fresh Context**: no

## Success Metrics
- [ ] Feature works
EOF

    VALID_PLN="docs/active/0000-0099/VALID-PLN.md"

    # PLN with oversized subtask. The size-check now scales by complexity:
    # XS/default=30m, S=120m, M=240m, L=480m, XL=960m. To trigger
    # subtask_size, we use complexity XS (defaults to 30m ceiling) with a
    # 45m estimate — clearly over the XS budget.
    cat > docs/active/0000-0099/OVERSIZED-PLN.md << 'EOF'
# Plan: Oversized Task

## Approach

### Phase 1: Work

#### Task 1.1: [ ] [AC1] Big task
- **Description**: Too much work.
- **Files**: `src/big.sh`
- **Work Model**: Sonnet
- **Test Model**: n/a
- **Complexity**: XS
- **Estimated Time**: 45m
- **TDD Required**: no
- **Auto Review**: no
- **Review Type**: single
- **Fresh Context**: no
EOF

    OVERSIZED_PLN="docs/active/0000-0099/OVERSIZED-PLN.md"

    # PLN with missing AC tags
    cat > docs/active/0000-0099/NO-AC-PLN.md << 'EOF'
# Plan: Missing AC Tags

## Approach

### Phase 1: Work

#### Task 1.1: [ ] Do something without AC tags
- **Description**: No AC tag on this task.
- **Files**: `src/thing.sh`
- **Work Model**: Haiku
- **Test Model**: n/a
- **Complexity**: XS
- **Estimated Time**: 10m
- **TDD Required**: no
- **Auto Review**: no
- **Review Type**: single
- **Fresh Context**: no
EOF

    NO_AC_PLN="docs/active/0000-0099/NO-AC-PLN.md"

    # PLN with forward dependency
    cat > docs/active/0000-0099/FWD-DEP-PLN.md << 'EOF'
# Plan: Forward Dependency

## Approach

### Phase 1: Work

#### Task 1.1: [ ] [AC1] First task
- **Description**: First.
- **Files**: `src/a.sh`
- **Dependencies**: Task 1.2
- **Work Model**: Haiku
- **Test Model**: n/a
- **Complexity**: XS
- **Estimated Time**: 10m
- **TDD Required**: no
- **Auto Review**: no
- **Review Type**: single
- **Fresh Context**: no

#### Task 1.2: [ ] [AC2] Second task
- **Description**: Second.
- **Files**: `src/b.sh`
- **Work Model**: Haiku
- **Test Model**: n/a
- **Complexity**: XS
- **Estimated Time**: 15m
- **TDD Required**: no
- **Auto Review**: no
- **Review Type**: single
- **Fresh Context**: no
EOF

    FWD_DEP_PLN="docs/active/0000-0099/FWD-DEP-PLN.md"

    # PLN with missing execution config fields
    cat > docs/active/0000-0099/NO-CONFIG-PLN.md << 'EOF'
# Plan: Missing Config

## Approach

### Phase 1: Work

#### Task 1.1: [ ] [AC1] Task with missing config
- **Description**: Missing fields.
- **Files**: `src/thing.sh`
- **Work Model**: Haiku
- **Test Model**: n/a
- **Complexity**: XS
- **Estimated Time**: 10m
EOF

    NO_CONFIG_PLN="docs/active/0000-0099/NO-CONFIG-PLN.md"

    # PLN with multiple issues. Sized-by-complexity check needs Task 1.2 to
    # exceed its limit: complexity XS defaults to 30m, so 45m is oversized.
    # (Previous fixture used S=120m, which 45m did not exceed.)
    cat > docs/active/0000-0099/MULTI-ISSUE-PLN.md << 'EOF'
# Plan: Multiple Issues

## Approach

### Phase 1: Work

#### Task 1.1: [ ] Big task no AC no config
- **Description**: Everything wrong.
- **Files**: `src/bad.sh`
- **Dependencies**: Task 1.2
- **Work Model**: Sonnet
- **Test Model**: n/a
- **Complexity**: M
- **Estimated Time**: 5h

#### Task 1.2: [ ] [AC1] Second task
- **Description**: This one is OK except it's oversized.
- **Files**: `src/ok.sh`
- **Work Model**: Haiku
- **Test Model**: n/a
- **Complexity**: XS
- **Estimated Time**: 45m
- **TDD Required**: no
- **Auto Review**: no
- **Review Type**: single
- **Fresh Context**: no
EOF

    MULTI_ISSUE_PLN="docs/active/0000-0099/MULTI-ISSUE-PLN.md"
}

teardown() {
    common_teardown
}

# --- Pass scenarios ---

@test "review: valid plan passes all checks" {
    run "$SCRIPTS_DIR/task-plan.sh" --json --review --source "$VALID_PLN" 2>/dev/null
    assert_valid_json "$output"
    assert_json_field "$output" ".status" "review_passed"
    assert_json_field "$output" ".next_action" "continue"
    assert_json_field "$output" ".issues_found" "0"
}

# --- Fail scenarios ---

@test "review: detects oversized subtask (>30m)" {
    run "$SCRIPTS_DIR/task-plan.sh" --json --review --source "$OVERSIZED_PLN" 2>/dev/null
    assert_valid_json "$output"
    assert_json_field "$output" ".status" "review_failed"
    assert_json_field "$output" ".next_action" "fix_plan"

    local check
    check=$(echo "$output" | jq -r '.issues[0].check')
    [ "$check" = "subtask_size" ]

    local task
    task=$(echo "$output" | jq -r '.issues[0].task')
    [ "$task" = "Task 1.1" ]
}

@test "review: detects missing AC tags" {
    run "$SCRIPTS_DIR/task-plan.sh" --json --review --source "$NO_AC_PLN" 2>/dev/null
    assert_valid_json "$output"
    assert_json_field "$output" ".status" "review_failed"

    local check
    check=$(echo "$output" | jq -r '.issues[0].check')
    [ "$check" = "acceptance_criteria" ]
}

@test "review: detects forward dependency reference" {
    run "$SCRIPTS_DIR/task-plan.sh" --json --review --source "$FWD_DEP_PLN" 2>/dev/null
    assert_valid_json "$output"
    assert_json_field "$output" ".status" "review_failed"

    local check
    check=$(echo "$output" | jq -r '.issues[0].check')
    [ "$check" = "dependency_order" ]

    local msg
    msg=$(echo "$output" | jq -r '.issues[0].message')
    [[ "$msg" == *"Task 1.2"* ]]
}

@test "review: detects missing execution config fields" {
    run "$SCRIPTS_DIR/task-plan.sh" --json --review --source "$NO_CONFIG_PLN" 2>/dev/null
    assert_valid_json "$output"
    assert_json_field "$output" ".status" "review_failed"

    local check
    check=$(echo "$output" | jq -r '.issues[0].check')
    [ "$check" = "execution_config" ]

    local msg
    msg=$(echo "$output" | jq -r '.issues[0].message')
    [[ "$msg" == *"TDD Required"* ]]
    [[ "$msg" == *"Auto Review"* ]]
    [[ "$msg" == *"Review Type"* ]]
    [[ "$msg" == *"Fresh Context"* ]]
}

@test "review: reports multiple issues in single response" {
    run "$SCRIPTS_DIR/task-plan.sh" --json --review --source "$MULTI_ISSUE_PLN" 2>/dev/null
    assert_valid_json "$output"
    assert_json_field "$output" ".status" "review_failed"

    local count
    count=$(echo "$output" | jq '.issues_found')
    [ "$count" -ge 3 ]

    # Should have at least: missing AC, subtask_size, execution_config
    local checks
    checks=$(echo "$output" | jq -r '[.issues[].check] | unique | sort | join(",")')
    [[ "$checks" == *"acceptance_criteria"* ]]
    [[ "$checks" == *"subtask_size"* ]]
    [[ "$checks" == *"execution_config"* ]]
}

# --- Skip review ---

@test "review: --skip-review bypasses all checks" {
    run "$SCRIPTS_DIR/task-plan.sh" --json --review --skip-review --source "$MULTI_ISSUE_PLN" 2>/dev/null
    assert_valid_json "$output"
    assert_json_field "$output" ".status" "review_passed"
    assert_json_field "$output" ".next_action" "continue"

    # Should NOT have issues array
    local has_issues
    has_issues=$(echo "$output" | jq 'has("issues")')
    [ "$has_issues" = "false" ]
}

# --- Error scenarios ---

@test "review: errors when no PLN file found" {
    run "$SCRIPTS_DIR/task-plan.sh" --json --review --source "/nonexistent/file.md" 2>/dev/null
    assert_valid_json "$output"
    assert_json_field "$output" ".status" "error"
    assert_json_field "$output" ".next_action" "fix_error"
}
