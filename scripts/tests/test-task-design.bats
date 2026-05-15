#!/usr/bin/env bats

# Test suite: task-design.sh and DSN document integration
#
# Tests:
# - task-design.sh --identify returns task context
# - task-design.sh --identify detects existing DSN
# - task-design.sh --create-doc returns DSN template
# - task-plan.sh discovers DSN doc when present
# - task-plan.sh falls back to TSK when no DSN

load test_helper

TASK_ID="A1B2C3"
TASK_BRANCH="feature/A1B2C3-test-design"

setup() {
    common_setup
    setup_mock_git_repo
    git checkout -q -b "$TASK_BRANCH"

    # Mock yq to return null for PROJECT.yaml queries
    create_mock "yq" "null"

    # Create docs structure
    mkdir -p docs/active/A1B2C3

    # Create TSK document
    cat > docs/active/A1B2C3/A1B2C3-2603120001-TSK-test-design.md << 'EOF'
# Test Design Task
## Status: in-progress
## Branch
`feature/A1B2C3-test-design`
EOF

    # Commit docs so git is clean
    git add -A
    git commit -q -m "add task docs"

    # Write .current-task after commit
    echo '{"task_id":"A1B2C3","branch":"feature/A1B2C3-test-design","parent_branch":"main","task_doc":"docs/active/A1B2C3/A1B2C3-2603120001-TSK-test-design.md","started":"2026-03-17T00:00:00Z","task_tracker":null}' > .current-task
}

teardown() {
    common_teardown
}

# =============================================================================
# Group 1: task-design.sh --identify
# =============================================================================

@test "task-design identify: returns task context with correct fields" {
    run "$SCRIPTS_DIR/task-design.sh" --json --identify --task-id A1B2C3 2>/dev/null
    assert_valid_json "$output"
    assert_json_field "$output" ".status" "success"
    assert_json_field "$output" ".task_id" "A1B2C3"
    assert_json_field "$output" ".next_action" "create_design"
}

@test "task-design identify: detects existing DSN document" {
    # Create a DSN document
    cat > docs/active/A1B2C3/A1B2C3-2603120002-DSN-test-design.md << 'EOF'
# Design: Test Design
## Design Decisions
1. Use approach A
EOF
    git add -A && git commit -q -m "add dsn"

    run "$SCRIPTS_DIR/task-design.sh" --json --identify --task-id A1B2C3 2>/dev/null
    assert_valid_json "$output"
    assert_json_field "$output" ".next_action" "resume_design"
    assert_json_field_present "$output" ".existing_dsn"
}

@test "task-design identify: no DSN returns null existing_dsn" {
    run "$SCRIPTS_DIR/task-design.sh" --json --identify --task-id A1B2C3 2>/dev/null
    assert_valid_json "$output"
    assert_json_field "$output" ".next_action" "create_design"

    # existing_dsn should be null
    local dsn_val
    dsn_val=$(echo "$output" | jq -r '.existing_dsn // "null"')
    [ "$dsn_val" = "null" ]
}

# =============================================================================
# Group 2: task-design.sh --full
# =============================================================================

@test "task-design full: returns task context for brainstorming" {
    run "$SCRIPTS_DIR/task-design.sh" --json --full --task-id A1B2C3 2>/dev/null
    assert_valid_json "$output"
    assert_json_field "$output" ".status" "success"
    assert_json_field "$output" ".task_id" "A1B2C3"
    assert_json_field_present "$output" ".task_doc"
    assert_json_field_present "$output" ".branch"
}

# =============================================================================
# Group 3: task-design.sh --create-doc
# =============================================================================

@test "task-design create-doc: returns DSN template and filepath" {
    run "$SCRIPTS_DIR/task-design.sh" --json --create-doc --task-id A1B2C3 2>/dev/null
    assert_valid_json "$output"
    assert_json_field "$output" ".status" "success"
    assert_json_field "$output" ".next_action" "fill_document"
    assert_json_field_present "$output" ".dsn_path"
    assert_json_field_present "$output" ".template"

    # Verify DSN path contains expected components
    local dsn_path
    dsn_path=$(echo "$output" | jq -r '.dsn_path // ""')
    echo "$dsn_path" | grep -q "DSN"
    echo "$dsn_path" | grep -q "A1B2C3"
}

# =============================================================================
# Group 4: task-plan.sh DSN integration
# =============================================================================

@test "task-plan: discovers DSN doc when present" {
    # Create a DSN document for the task
    cat > docs/active/A1B2C3/A1B2C3-2603120002-DSN-test-design.md << 'EOF'
# Design: Test Design
## Design Decisions
1. Use REST API over GraphQL
EOF
    git add -A && git commit -q -m "add dsn"

    local task_doc="docs/active/A1B2C3/A1B2C3-2603120001-TSK-test-design.md"
    run "$SCRIPTS_DIR/task-plan.sh" --json --load --source "$task_doc" 2>/dev/null
    assert_valid_json "$output"
    assert_json_field "$output" ".status" "success"

    # Verify DSN doc path is in requirements
    local dsn_doc
    dsn_doc=$(echo "$output" | jq -r '.requirements.dsn_doc // "null"')
    [ "$dsn_doc" != "null" ]

    # Verify DSN data contains the design content
    local dsn_data
    dsn_data=$(echo "$output" | jq -r '.requirements.dsn_data // ""')
    echo "$dsn_data" | grep -q "REST API over GraphQL"
}

@test "task-plan: falls back to TSK when no DSN exists" {
    local task_doc="docs/active/A1B2C3/A1B2C3-2603120001-TSK-test-design.md"
    run "$SCRIPTS_DIR/task-plan.sh" --json --load --source "$task_doc" 2>/dev/null
    assert_valid_json "$output"
    assert_json_field "$output" ".status" "success"

    # Verify DSN doc is null when not present
    local dsn_doc
    dsn_doc=$(echo "$output" | jq -r '.requirements.dsn_doc // "null"')
    [ "$dsn_doc" = "null" ]
}

@test "task-plan: DSN data is null when no DSN exists" {
    local task_doc="docs/active/A1B2C3/A1B2C3-2603120001-TSK-test-design.md"
    run "$SCRIPTS_DIR/task-plan.sh" --json --load --source "$task_doc" 2>/dev/null
    assert_valid_json "$output"

    local dsn_data
    dsn_data=$(echo "$output" | jq -r '.requirements.dsn_data // "null"')
    [ "$dsn_data" = "null" ]
}

# =============================================================================
# Group 5: new-doc.sh DSN type
# =============================================================================

@test "new-doc: DSN type creates document with correct naming" {
    run "$SCRIPTS_DIR/new-doc.sh" --type DSN --description "test-design" --id A1B2C3 --json 2>/dev/null
    assert_valid_json "$output"
    assert_json_field "$output" ".status" "success"

    # Verify filepath contains DSN in the name
    local filepath
    filepath=$(echo "$output" | jq -r '.filepath // ""')
    echo "$filepath" | grep -q "DSN"
    echo "$filepath" | grep -q "A1B2C3"
}
