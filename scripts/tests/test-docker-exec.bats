#!/usr/bin/env bats

# Test suite for docker-exec.sh
# Covers: flag parsing, container resolution, auto-start, error handling

load test_helper

setup() {
    common_setup
    # Copy sample docker-compose.yml
    cp "$FIXTURES_DIR/sample-docker-compose.yml" "$TEST_DIR/docker-compose.yml"
}

teardown() {
    common_teardown
}

# =============================================================================
# Flag parsing
# =============================================================================

@test "docker-exec: -s flag is required" {
    run "$SCRIPTS_DIR/docker-exec.sh" -- echo hello
    [ "$status" -ne 0 ]
    [[ "$output" == *"required"* ]]
}

@test "docker-exec: requires command after --" {
    run "$SCRIPTS_DIR/docker-exec.sh" -s api
    [ "$status" -ne 0 ]
    [[ "$output" == *"no command"* ]] || [[ "$output" == *"Usage"* ]]
}

@test "docker-exec: --help shows usage" {
    run "$SCRIPTS_DIR/docker-exec.sh" --help
    [ "$status" -ne 0 ]
    [[ "$output" == *"Usage"* ]]
}

@test "docker-exec: unknown option fails" {
    run "$SCRIPTS_DIR/docker-exec.sh" --bad-flag -s api -- echo
    [ "$status" -ne 0 ]
}

@test "docker-exec: requires docker-compose.yml" {
    rm "$TEST_DIR/docker-compose.yml"
    create_mock "docker" ""
    run "$SCRIPTS_DIR/docker-exec.sh" -s api -- echo hello
    [ "$status" -ne 0 ]
    [[ "$output" == *"docker-compose.yml not found"* ]]
}

# =============================================================================
# Container resolution with explicit container_name
# =============================================================================

@test "docker-exec: uses explicit container_name from compose file" {
    # Mock docker inspect to say container is running
    create_smart_mock "docker" \
        "inspect|||true" \
        "exec|||command output"
    run "$SCRIPTS_DIR/docker-exec.sh" -s api -- echo hello
    [ "$status" -eq 0 ]
}

# =============================================================================
# Auto-start behavior
# =============================================================================

@test "docker-exec: starts service if not running" {
    # Mock tracks whether "up -d" has been called via a state file.
    # Before up: inspect fails so resolve_container fails, triggering auto-start.
    # After up: inspect succeeds so resolve_container returns the container name.
    local state_file="${TEST_DIR}/.docker_started"
    cat > "${TEST_BIN}/docker" <<MOCK
#!/usr/bin/env bash
case "\$*" in
    *"up -d"*) touch "${state_file}"; exit 0 ;;
    *inspect*)
        if [[ -f "${state_file}" ]]; then
            echo "true"; exit 0
        else
            echo "false"; exit 1
        fi ;;
    *compose*ps*) echo ""; exit 0 ;;
    *exec*) echo "exec output"; exit 0 ;;
    *) exit 1 ;;
esac
MOCK
    chmod +x "${TEST_BIN}/docker"

    run "$SCRIPTS_DIR/docker-exec.sh" -s api -- echo hello
    [ "$status" -eq 0 ]
    [[ "$output" == *"exec output"* ]]
}

# =============================================================================
# -d flag (project directory)
# =============================================================================

@test "docker-exec: -d flag sets project directory" {
    mkdir -p "$TEST_DIR/myproject"
    cp "$FIXTURES_DIR/sample-docker-compose.yml" "$TEST_DIR/myproject/docker-compose.yml"
    create_smart_mock "docker" \
        "inspect|||true" \
        "exec|||output"
    run "$SCRIPTS_DIR/docker-exec.sh" -s api -d "$TEST_DIR/myproject" -- echo hello
    [ "$status" -eq 0 ]
}

# =============================================================================
# Order of operations
# =============================================================================

@test "docker-exec: checks compose file BEFORE trying docker" {
    rm "$TEST_DIR/docker-compose.yml"
    create_recording_mock "docker"
    run "$SCRIPTS_DIR/docker-exec.sh" -s api -- echo hello
    [ "$status" -ne 0 ]
    # Docker should NOT have been called if compose file doesn't exist
    assert_mock_call_count "docker" 0
}
