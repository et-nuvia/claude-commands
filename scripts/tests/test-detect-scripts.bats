#!/usr/bin/env bats

# Test suite for detect-environment.sh and detect-database.sh
# Covers: environment detection, database detection from compose files

load test_helper

setup() {
    common_setup
}

teardown() {
    common_teardown
}

# =============================================================================
# detect-environment.sh
# =============================================================================

@test "detect-environment: returns work or home" {
    run "$SCRIPTS_DIR/detect-environment.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"work"* ]] || [[ "$output" == *"home"* ]]
}

@test "detect-environment: Linux returns home" {
    # We're on Linux, so should return home
    if [[ "$(uname -s)" == "Linux" ]]; then
        run "$SCRIPTS_DIR/detect-environment.sh"
        [[ "$output" == *"home"* ]]
    else
        skip "Not on Linux"
    fi
}

# =============================================================================
# detect-database.sh
# =============================================================================

@test "detect-database: detects postgres from compose file" {
    cp "$FIXTURES_DIR/sample-docker-compose.yml" "$TEST_DIR/docker-compose.yml"
    run "$SCRIPTS_DIR/detect-database.sh" --compose-file "$TEST_DIR/docker-compose.yml"
    [ "$status" -eq 0 ]
    [[ "$output" == *"postgres"* ]]
}

@test "detect-database: --json returns valid JSON" {
    cp "$FIXTURES_DIR/sample-docker-compose.yml" "$TEST_DIR/docker-compose.yml"
    run "$SCRIPTS_DIR/detect-database.sh" --compose-file "$TEST_DIR/docker-compose.yml" --json
    [ "$status" -eq 0 ]
    assert_valid_json "$output"
}

@test "detect-database: handles missing compose file" {
    run "$SCRIPTS_DIR/detect-database.sh" --compose-file "/nonexistent/docker-compose.yml"
    [ "$status" -ne 0 ]
}

@test "detect-database: help flag works" {
    run "$SCRIPTS_DIR/detect-database.sh" -h
    [[ "$output" == *"Usage"* ]] || [[ "$output" == *"usage"* ]]
}

# =============================================================================
# detect-database.sh: compose file with multiple databases
# =============================================================================

@test "detect-database: detects database service name" {
    cp "$FIXTURES_DIR/sample-docker-compose.yml" "$TEST_DIR/docker-compose.yml"
    run "$SCRIPTS_DIR/detect-database.sh" --compose-file "$TEST_DIR/docker-compose.yml"
    [[ "$output" == *"db"* ]]
}

# =============================================================================
# detect-database.sh: compose file without databases
# =============================================================================

@test "detect-database: handles compose with no databases" {
    cat > "$TEST_DIR/docker-compose.yml" <<'EOF'
version: "3.8"
services:
  web:
    build: ./frontend
    ports:
      - "3000:3000"
EOF
    run "$SCRIPTS_DIR/detect-database.sh" --compose-file "$TEST_DIR/docker-compose.yml"
    # Should succeed but find no databases
    [ "$status" -eq 0 ] || [[ "$output" == *"No database"* ]] || [[ "$output" == *"no database"* ]]
}
