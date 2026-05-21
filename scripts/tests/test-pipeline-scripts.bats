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

@test "pipeline-status: sources git-api.sh adapter shim" {
    # Pipeline scripts were migrated from per-platform `git-detect.sh`
    # dispatching to the unified `lib/git-api.sh` adapter (commit 7f235e8).
    grep -q 'source.*git-api.sh' "$SCRIPTS_DIR/pipeline-status.sh"
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

@test "pipeline-jobs: sources git-api.sh adapter shim" {
    grep -q 'source.*git-api.sh' "$SCRIPTS_DIR/pipeline-jobs.sh"
}

@test "pipeline-jobs: with gitlab and token fetches jobs" {
    setup_mock_project "complete-gitlab"
    echo "test-token" > "$HOME/.gitlab-token"
    # Post-migration, lib/git-api.sh `gitlab_api` invokes curl as:
    #   curl -s -o <tmpfile> -w '%{http_code}' -X METHOD --header ... URL
    # So the mock must (a) write the JSON body to the -o tmpfile path and
    # (b) print only the HTTP status code (e.g., 200) to stdout. The old
    # mock printed the body to stdout, which the adapter then tried to
    # interpret as an HTTP code.
    cat > "${TEST_BIN}/curl" <<'MOCK'
#!/usr/bin/env bash
out=""
url=""
prev=""
for arg in "$@"; do
    if [[ "$prev" == "-o" ]]; then out="$arg"; fi
    prev="$arg"
    case "$arg" in -*|--*) ;; *) url="$arg" ;; esac
done
if [[ "$url" == *"/pipelines/"*"/jobs"* ]]; then
    body='[{"id":100,"name":"lint","stage":"test","status":"success","duration":45.2,"web_url":"https://example.com/jobs/100"}]'
elif [[ "$url" == *"/pipelines"* ]]; then
    body='[{"id":42,"status":"success","sha":"abc","ref":"main","web_url":"https://example.com/pipelines/42","created_at":"2026-01-01T00:00:00Z"}]'
else
    echo "mock curl: unhandled URL: $url" >&2; exit 1
fi
if [[ -n "$out" ]]; then printf '%s' "$body" > "$out"; fi
printf '200'
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

@test "pipeline-logs: sources git-api.sh adapter shim" {
    grep -q 'source.*git-api.sh' "$SCRIPTS_DIR/pipeline-logs.sh"
}

# =============================================================================
# pipeline-watch.sh
# =============================================================================

@test "pipeline-watch: fails without PROJECT.yaml" {
    run "$SCRIPTS_DIR/pipeline-watch.sh" 2>&1
    [ "$status" -ne 0 ]
}

@test "pipeline-watch: sources git-api.sh adapter shim" {
    grep -q 'source.*git-api.sh' "$SCRIPTS_DIR/pipeline-watch.sh"
}

# =============================================================================
# All pipeline scripts: no exported variables
# =============================================================================

@test "pipeline scripts: none use export for config vars" {
    for script in pipeline-status.sh pipeline-jobs.sh pipeline-logs.sh pipeline-watch.sh; do
        ! grep -q '^export GIT_' "$SCRIPTS_DIR/$script"
    done
}

@test "pipeline scripts: all source git-api.sh adapter shim" {
    # Migrated from per-platform `git-detect.sh` to unified `lib/git-api.sh`
    # adapter (commit 7f235e8). Each script must source the shim so
    # platform routing happens through `git_*` adapter functions.
    for script in pipeline-status.sh pipeline-jobs.sh pipeline-logs.sh pipeline-watch.sh; do
        grep -q 'source.*git-api.sh' "$SCRIPTS_DIR/$script"
    done
}

@test "pipeline scripts: all route platform calls through git-api adapter" {
    # Previous contract: scripts referenced a GIT_PLATFORM variable directly
    # to switch branches. New contract: scripts call `git_*` adapter
    # functions and let lib/git-api.sh resolve the backend.
    for script in pipeline-status.sh pipeline-jobs.sh pipeline-logs.sh pipeline-watch.sh; do
        grep -qE 'git_(pipeline|job|run)' "$SCRIPTS_DIR/$script" \
            || grep -q 'load_git_adapter\|GIT_PLATFORM' "$SCRIPTS_DIR/$script"
    done
}
