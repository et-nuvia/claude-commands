#!/usr/bin/env bats

# Test suite for get-default-branch.sh
# Covers: override, PROJECT.yaml config, auto-detect, common defaults

load test_helper

setup() {
    common_setup
    source "$SCRIPTS_DIR/get-default-branch.sh"
}

teardown() {
    common_teardown
}

# =============================================================================
# Tier 1: Override
# =============================================================================

@test "get-default-branch: uses override when branch exists" {
    setup_mock_git_repo
    # Get whatever the default branch is (master or main depending on git config)
    local current_branch
    current_branch=$(git rev-parse --abbrev-ref HEAD)
    result=$(get_default_branch "$current_branch")
    [ "$result" = "$current_branch" ]
}

@test "get-default-branch: override fails for nonexistent branch" {
    setup_mock_git_repo
    run get_default_branch "nonexistent-branch"
    [ "$status" -ne 0 ]
}

# =============================================================================
# Tier 4: Common defaults
# =============================================================================

@test "get-default-branch: finds 'main' branch" {
    setup_mock_git_repo
    # Default branch from setup_mock_git_repo is 'main' or 'master'
    result=$(get_default_branch)
    [[ "$result" =~ ^(main|master)$ ]]
}

@test "get-default-branch: finds 'master' branch when no main" {
    cd "$TEST_DIR"
    git init -q -b master
    git config user.email "test@test.com"
    git config user.name "Test User"
    echo "init" > README.md
    git add README.md
    git commit -q -m "initial commit"
    result=$(get_default_branch)
    [ "$result" = "master" ]
}

@test "get-default-branch: finds 'develop' branch when no main/master" {
    cd "$TEST_DIR"
    git init -q -b develop
    git config user.email "test@test.com"
    git config user.name "Test User"
    echo "init" > README.md
    git add README.md
    git commit -q -m "initial commit"
    result=$(get_default_branch)
    [ "$result" = "develop" ]
}

# =============================================================================
# Tier 2: PROJECT.yaml config
# =============================================================================

@test "get-default-branch: reads from PROJECT.yaml ci.branches.dev" {
    setup_mock_git_repo
    local current_branch
    current_branch=$(git rev-parse --abbrev-ref HEAD)
    cat > PROJECT.yaml <<EOF
ci:
  branches:
    dev: ${current_branch}
EOF
    result=$(get_default_branch)
    [ "$result" = "$current_branch" ]
}
