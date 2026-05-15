#!/usr/bin/env bats

# Test suite for git-detect.sh (flag-based version)
# Covers: JSON output, --field mode, platform detection, error handling

load test_helper

setup() {
    common_setup
}

teardown() {
    common_teardown
}

# =============================================================================
# JSON output mode (default)
# =============================================================================

@test "git-detect: returns valid JSON with all fields for gitlab" {
    setup_mock_project "complete-gitlab"
    run "$SCRIPTS_DIR/git-detect.sh"
    [ "$status" -eq 0 ]
    assert_valid_json "$output"
    assert_json_field "$output" ".platform" "gitlab"
    assert_json_field "$output" ".instance" "git.example.com"
    assert_json_field "$output" ".repo" "docker/mcps"
}

@test "git-detect: returns valid JSON with all fields for github" {
    setup_mock_project "complete-github"
    run "$SCRIPTS_DIR/git-detect.sh"
    [ "$status" -eq 0 ]
    assert_valid_json "$output"
    assert_json_field "$output" ".platform" "github"
    assert_json_field "$output" ".instance" "github.com"
    assert_json_field "$output" ".repo" "myorg/myrepo"
}

@test "git-detect: gitlab api_url is correct" {
    setup_mock_project "complete-gitlab"
    run "$SCRIPTS_DIR/git-detect.sh"
    assert_json_field "$output" ".api_url" "https://git.example.com/api/v4"
}

@test "git-detect: github api_url is correct" {
    setup_mock_project "complete-github"
    run "$SCRIPTS_DIR/git-detect.sh"
    assert_json_field "$output" ".api_url" "https://api.github.com"
}

@test "git-detect: gitlab project_path is URL-encoded" {
    setup_mock_project "complete-gitlab"
    run "$SCRIPTS_DIR/git-detect.sh"
    assert_json_field "$output" ".project_path" "docker%2Fmcps"
}

@test "git-detect: github project_path is repo path" {
    setup_mock_project "complete-github"
    run "$SCRIPTS_DIR/git-detect.sh"
    assert_json_field "$output" ".project_path" "myorg/myrepo"
}

@test "git-detect: gitlab token_file points to ~/.gitlab-token" {
    setup_mock_project "complete-gitlab"
    run "$SCRIPTS_DIR/git-detect.sh"
    assert_json_field "$output" ".token_file" "${HOME}/.gitlab-token"
}

@test "git-detect: github token_file is empty" {
    setup_mock_project "complete-github"
    run "$SCRIPTS_DIR/git-detect.sh"
    assert_json_field "$output" ".token_file" ""
}

# =============================================================================
# --field mode (single value)
# =============================================================================

@test "git-detect: --field platform returns platform value" {
    setup_mock_project "complete-gitlab"
    run "$SCRIPTS_DIR/git-detect.sh" --field platform
    [ "$status" -eq 0 ]
    [ "$output" = "gitlab" ]
}

@test "git-detect: --field instance returns instance value" {
    setup_mock_project "complete-gitlab"
    run "$SCRIPTS_DIR/git-detect.sh" --field instance
    [ "$output" = "git.example.com" ]
}

@test "git-detect: --field repo returns repo value" {
    setup_mock_project "complete-gitlab"
    run "$SCRIPTS_DIR/git-detect.sh" --field repo
    [ "$output" = "docker/mcps" ]
}

@test "git-detect: --field api_url returns api_url" {
    setup_mock_project "complete-gitlab"
    run "$SCRIPTS_DIR/git-detect.sh" --field api_url
    [ "$output" = "https://git.example.com/api/v4" ]
}

@test "git-detect: --field project_path returns encoded path" {
    setup_mock_project "complete-gitlab"
    run "$SCRIPTS_DIR/git-detect.sh" --field project_path
    [ "$output" = "docker%2Fmcps" ]
}

@test "git-detect: --field token_file returns token file path" {
    setup_mock_project "complete-gitlab"
    run "$SCRIPTS_DIR/git-detect.sh" --field token_file
    [ "$output" = "${HOME}/.gitlab-token" ]
}

@test "git-detect: --field with invalid field name fails" {
    setup_mock_project "complete-gitlab"
    run "$SCRIPTS_DIR/git-detect.sh" --field invalid_field
    [ "$status" -ne 0 ]
}

# =============================================================================
# Error handling
# =============================================================================

@test "git-detect: missing PROJECT.yaml returns error JSON" {
    # TEST_DIR has no PROJECT.yaml
    run "$SCRIPTS_DIR/git-detect.sh"
    [ "$status" -ne 0 ]
    assert_valid_json "$output"
    assert_json_field "$output" ".status" "error"
    assert_json_field "$output" ".next_action" "fix_error"
}

@test "git-detect: missing PROJECT.yaml with --field exits with error" {
    run "$SCRIPTS_DIR/git-detect.sh" --field platform
    [ "$status" -ne 0 ]
}

@test "git-detect: PROJECT.yaml without git section returns error JSON" {
    setup_mock_project "minimal"
    run "$SCRIPTS_DIR/git-detect.sh"
    [ "$status" -ne 0 ]
    assert_valid_json "$output"
    assert_json_field "$output" ".status" "error"
}

@test "git-detect: unknown option fails" {
    setup_mock_project "complete-gitlab"
    run "$SCRIPTS_DIR/git-detect.sh" --unknown
    [ "$status" -ne 0 ]
}

@test "git-detect: --field without value fails" {
    setup_mock_project "complete-gitlab"
    run "$SCRIPTS_DIR/git-detect.sh" --field
    [ "$status" -ne 0 ]
}

@test "git-detect: no exports - output is pure data" {
    setup_mock_project "complete-gitlab"
    # Run in subshell and verify no env vars leak
    result=$(bash -c '"$1" && echo "GIT_PLATFORM=${GIT_PLATFORM:-unset}"' -- "$SCRIPTS_DIR/git-detect.sh")
    [[ "$result" == *"GIT_PLATFORM=unset"* ]]
}
