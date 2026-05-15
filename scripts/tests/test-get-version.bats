#!/usr/bin/env bats

# Test suite for get-version.sh
# Covers: git tags, version file fallback, flag parsing, error handling

load test_helper

setup() {
    common_setup
}

teardown() {
    common_teardown
}

# =============================================================================
# Git tag strategy (primary)
# =============================================================================

@test "get-version: reads version from git tag" {
    setup_mock_git_repo
    git tag v1.2.3
    run "$SCRIPTS_DIR/get-version.sh" -q
    [ "$status" -eq 0 ]
    [ "$output" = "1.2.3" ]
}

@test "get-version: strips 'v' prefix from tag" {
    setup_mock_git_repo
    git tag v2.0.0
    run "$SCRIPTS_DIR/get-version.sh" -q
    [ "$output" = "2.0.0" ]
}

@test "get-version: uses latest tag by semver sort" {
    setup_mock_git_repo
    git tag v1.0.0
    echo "change" >> README.md && git add . && git commit -q -m "change"
    git tag v1.1.0
    run "$SCRIPTS_DIR/get-version.sh" -q
    [ "$output" = "1.1.0" ]
}

@test "get-version: --git-only succeeds with tags" {
    setup_mock_git_repo
    git tag v3.0.0
    run "$SCRIPTS_DIR/get-version.sh" --git-only --quiet
    [ "$status" -eq 0 ]
    [ "$output" = "3.0.0" ]
}

@test "get-version: --git-only fails without tags" {
    setup_mock_git_repo
    run "$SCRIPTS_DIR/get-version.sh" -g -q
    [ "$status" -ne 0 ]
}

# =============================================================================
# Version file fallback (legacy)
# =============================================================================

@test "get-version: reads plain VERSION file" {
    echo "1.5.0" > "$TEST_DIR/VERSION"
    run "$SCRIPTS_DIR/get-version.sh" -f VERSION -q
    [ "$status" -eq 0 ]
    [ "$output" = "1.5.0" ]
}

@test "get-version: reads version from package.json" {
    cat > "$TEST_DIR/package.json" <<'EOF'
{"name": "test", "version": "2.3.4"}
EOF
    run "$SCRIPTS_DIR/get-version.sh" -f package.json -q
    [ "$status" -eq 0 ]
    [ "$output" = "2.3.4" ]
}

@test "get-version: reads version from pyproject.toml [project] section" {
    cat > "$TEST_DIR/pyproject.toml" <<'EOF'
[project]
name = "test"
version = "1.0.5"
EOF
    run "$SCRIPTS_DIR/get-version.sh" -f pyproject.toml -q
    [ "$status" -eq 0 ]
    [ "$output" = "1.0.5" ]
}

@test "get-version: reads version from Cargo.toml" {
    cat > "$TEST_DIR/Cargo.toml" <<'EOF'
[package]
name = "test"
version = "0.9.1"
EOF
    run "$SCRIPTS_DIR/get-version.sh" -f Cargo.toml -q
    [ "$status" -eq 0 ]
    [ "$output" = "0.9.1" ]
}

@test "get-version: reads version from build.gradle" {
    cat > "$TEST_DIR/build.gradle" <<'EOF'
plugins {
    id 'java'
}
version = '3.2.1'
EOF
    run "$SCRIPTS_DIR/get-version.sh" -f build.gradle -q
    [ "$status" -eq 0 ]
    [ "$output" = "3.2.1" ]
}

# =============================================================================
# Error handling
# =============================================================================

@test "get-version: fails for nonexistent file" {
    run "$SCRIPTS_DIR/get-version.sh" -f nonexistent.txt -q
    [ "$status" -ne 0 ]
}

@test "get-version: fails with no git tags and no PROJECT.yaml" {
    setup_mock_git_repo
    run "$SCRIPTS_DIR/get-version.sh" -q
    [ "$status" -ne 0 ]
}

@test "get-version: help flag shows usage" {
    run "$SCRIPTS_DIR/get-version.sh" -h
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage"* ]]
}

@test "get-version: quiet flag suppresses warnings" {
    setup_mock_git_repo
    echo "1.0.0" > VERSION
    cp "$FIXTURES_DIR/complete.yaml" PROJECT.yaml
    run "$SCRIPTS_DIR/get-version.sh" -q
    # Should not contain "Warning:" in stderr (combined output)
    [[ "$output" != *"Warning:"* ]]
}

@test "get-version: git tag takes priority over version file" {
    setup_mock_git_repo
    git tag v5.0.0
    echo "1.0.0" > VERSION
    run "$SCRIPTS_DIR/get-version.sh" -q
    [ "$output" = "5.0.0" ]
}

@test "get-version: -f flag bypasses git tags" {
    setup_mock_git_repo
    git tag v5.0.0
    echo "1.0.0" > VERSION
    run "$SCRIPTS_DIR/get-version.sh" -f VERSION -q
    [ "$output" = "1.0.0" ]
}
