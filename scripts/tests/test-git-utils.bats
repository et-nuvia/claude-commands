#!/usr/bin/env bats

# Test suite for lib/git-utils.sh
# Covers: is_protected_branch

load test_helper

setup() {
    common_setup
    source "$SCRIPTS_DIR/lib/yaml.sh"
    source "$SCRIPTS_DIR/lib/git-utils.sh"
}

teardown() {
    common_teardown
}

# =============================================================================
# is_protected_branch
# =============================================================================

@test "is_protected_branch: returns true for configured dev branch" {
    cat > PROJECT.yaml <<'YAML'
ci:
  branches:
    dev: dev
    staging: staging
    production: production
YAML
    is_protected_branch "dev"
}

@test "is_protected_branch: returns true for configured staging branch" {
    cat > PROJECT.yaml <<'YAML'
ci:
  branches:
    dev: develop
    staging: staging
    production: main
YAML
    is_protected_branch "staging"
}

@test "is_protected_branch: returns true for configured production branch" {
    cat > PROJECT.yaml <<'YAML'
ci:
  branches:
    dev: dev
    staging: staging
    production: main
YAML
    is_protected_branch "main"
}

@test "is_protected_branch: returns false for feature branch" {
    cat > PROJECT.yaml <<'YAML'
ci:
  branches:
    dev: dev
    staging: staging
    production: main
YAML
    run is_protected_branch "feature/ABC123-my-task"
    [ "$status" -ne 0 ]
}

@test "is_protected_branch: returns false when PROJECT.yaml missing" {
    # No PROJECT.yaml in test dir
    run is_protected_branch "dev"
    [ "$status" -ne 0 ]
}

@test "is_protected_branch: returns false when ci.branches not configured" {
    cat > PROJECT.yaml <<'YAML'
name: my-project
YAML
    run is_protected_branch "dev"
    [ "$status" -ne 0 ]
}

@test "is_protected_branch: handles custom branch names" {
    cat > PROJECT.yaml <<'YAML'
ci:
  branches:
    dev: development
    staging: release-candidate
    production: prod
YAML
    is_protected_branch "development"
    is_protected_branch "release-candidate"
    is_protected_branch "prod"
    run is_protected_branch "main"
    [ "$status" -ne 0 ]
}
