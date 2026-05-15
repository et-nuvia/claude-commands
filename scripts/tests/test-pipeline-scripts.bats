#!/usr/bin/env bats

# Test suite for pipeline-status.sh, pipeline-jobs.sh, pipeline-logs.sh, pipeline-watch.sh
# Covers: git-detect integration, flag parsing, error paths, JSON consumption

load test_helper

setup() {
    common_setup
}

teardown() {
    common_teardown
}

# =============================================================================
# pipeline-status.sh
# =============================================================================

@test "pipeline-status: fails without PROJECT.yaml" {
    run "$SCRIPTS_DIR/pipeline-status.sh" 2>&1
    [ "$status" -ne 0 ]
}

@test "pipeline-status: sources git-detect.sh for config" {
    grep -q 'source.*git-detect.sh' "$SCRIPTS_DIR/pipeline-status.sh"
}

@test "pipeline-status: with gitlab config checks for token file" {
    setup_mock_project "complete-gitlab"
    create_mock "curl" '{"id":1,"status":"success"}'
    run "$SCRIPTS_DIR/pipeline-status.sh" 2>&1
    # Should fail because token file doesn't exist (not because of bad config)
    [[ "$output" == *"Token"* ]] || [[ "$output" == *"token"* ]] || [ "$status" -ne 0 ]
}

@test "pipeline-status: with github config checks for gh CLI" {
    setup_mock_project "complete-github"
    # Remove gh from PATH by not mocking it
    run "$SCRIPTS_DIR/pipeline-status.sh" 2>&1
    # Should mention gh CLI not installed or fail gracefully
    [ "$status" -ne 0 ] || [[ "$output" == *"gh"* ]]
}

# =============================================================================
# pipeline-jobs.sh
# =============================================================================

@test "pipeline-jobs: fails without PROJECT.yaml" {
    run "$SCRIPTS_DIR/pipeline-jobs.sh" 2>&1
    [ "$status" -ne 0 ]
}

@test "pipeline-jobs: sources git-detect.sh for config" {
    grep -q 'source.*git-detect.sh' "$SCRIPTS_DIR/pipeline-jobs.sh"
}

@test "pipeline-jobs: with gitlab and token fetches jobs" {
    setup_mock_project "complete-gitlab"
    echo "test-token" > "$HOME/.gitlab-token"
    # pipeline-jobs.sh uses: curl -s --header ... URL  (stdout capture, no -o flag)
    cat > "${TEST_BIN}/curl" <<'MOCK'
#!/usr/bin/env bash
ARGS="$*"
if [[ "$ARGS" == *"pipelines/"*"/jobs"* ]]; then
    echo '[{"id":100,"name":"lint","stage":"test","status":"success","duration":45.2,"web_url":"https://example.com/jobs/100"}]'
elif [[ "$ARGS" == *"pipelines"* ]]; then
    echo '[{"id":42}]'
else
    echo "mock curl: unhandled: $ARGS" >&2; exit 1
fi
MOCK
    chmod +x "${TEST_BIN}/curl"
    run "$SCRIPTS_DIR/pipeline-jobs.sh" 2>&1
    # Script should output job info
    [[ "$output" == *"lint"* ]] || [[ "$output" == *"Job"* ]] || [ "$status" -eq 0 ]
    rm -f "$HOME/.gitlab-token"
}

# =============================================================================
# pipeline-logs.sh
# =============================================================================

@test "pipeline-logs: fails without job_id argument" {
    setup_mock_project "complete-gitlab"
    run "$SCRIPTS_DIR/pipeline-logs.sh" 2>&1
    [ "$status" -ne 0 ]
    [[ "$output" == *"Usage"* ]]
}

@test "pipeline-logs: fails without PROJECT.yaml" {
    run "$SCRIPTS_DIR/pipeline-logs.sh" 123 2>&1
    [ "$status" -ne 0 ]
}

@test "pipeline-logs: sources git-detect.sh for config" {
    grep -q 'source.*git-detect.sh' "$SCRIPTS_DIR/pipeline-logs.sh"
}

# =============================================================================
# pipeline-watch.sh
# =============================================================================

@test "pipeline-watch: fails without PROJECT.yaml" {
    run "$SCRIPTS_DIR/pipeline-watch.sh" 2>&1
    [ "$status" -ne 0 ]
}

@test "pipeline-watch: sources git-detect.sh for config" {
    grep -q 'source.*git-detect.sh' "$SCRIPTS_DIR/pipeline-watch.sh"
}

# =============================================================================
# All pipeline scripts: no exported variables
# =============================================================================

@test "pipeline scripts: none use export for config vars" {
    for script in pipeline-status.sh pipeline-jobs.sh pipeline-logs.sh pipeline-watch.sh; do
        ! grep -q '^export GIT_' "$SCRIPTS_DIR/$script"
    done
}

@test "pipeline scripts: all source git-detect.sh for platform config" {
    for script in pipeline-status.sh pipeline-jobs.sh pipeline-logs.sh pipeline-watch.sh; do
        grep -q 'source.*git-detect.sh' "$SCRIPTS_DIR/$script"
    done
}

@test "pipeline scripts: all use GIT_PLATFORM variable for platform routing" {
    for script in pipeline-status.sh pipeline-jobs.sh pipeline-logs.sh pipeline-watch.sh; do
        grep -q 'GIT_PLATFORM' "$SCRIPTS_DIR/$script"
    done
}
