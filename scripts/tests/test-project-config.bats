#!/usr/bin/env bats

# Test suite for lib/project-config.sh
# Covers: get_config, get_app_name, get_secrets_backend, and helpers
#
# Note: yq v4 returns string values unquoted (e.g., test-app)
# and numeric/boolean values as-is (e.g., 80, true). The get_config
# function preserves this behavior.

setup() {
    # Create temp directory for tests
    TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR"

    # Copy fixtures
    FIXTURES_DIR="$BATS_TEST_DIRNAME/fixtures"

    # Source the library (functions only, not the whole script)
    source "$BATS_TEST_DIRNAME/../lib/project-config.sh"
}

teardown() {
    # Cleanup temp directory
    rm -rf "$TEST_DIR"
}

# =============================================================================
# get_config() - Basic functionality
# =============================================================================

@test "get_config: single value exists" {
    cp "$FIXTURES_DIR/complete.yaml" PROJECT.yaml

    result=$(get_config .name)

    [ "$result" = "test-app" ]
}

@test "get_config: multiple values via separate calls" {
    cp "$FIXTURES_DIR/complete.yaml" PROJECT.yaml

    app_name=$(get_config .name)
    backend=$(get_config .secrets.backend)
    host=$(get_config .deployment.staging.host)

    [ "$app_name" = "test-app" ]
    [ "$backend" = "aws" ]
    [ "$host" = "staging.example.com" ]
}

@test "get_config: nested path access" {
    cp "$FIXTURES_DIR/complete.yaml" PROJECT.yaml

    result=$(get_config .secrets.infisical.project_id)

    [ "$result" = "abc123" ]
}

# =============================================================================
# get_config() - Missing/blank/default handling
# =============================================================================

@test "get_config: returns default for non-existent path" {
    cp "$FIXTURES_DIR/minimal.yaml" PROJECT.yaml

    result=$(get_config .secrets.backend "fallback")

    [ "$result" = "fallback" ]
}

@test "get_config: returns empty for blank value with no default" {
    cp "$FIXTURES_DIR/blank-values.yaml" PROJECT.yaml

    result=$(get_config .name "")

    [ -z "$result" ]
}

@test "get_config: returns default for null value" {
    cp "$FIXTURES_DIR/blank-values.yaml" PROJECT.yaml

    result=$(get_config .version_file "def")

    [ "$result" = "def" ]
}

@test "get_config: returns default for non-existent deeply nested path" {
    cp "$FIXTURES_DIR/complete.yaml" PROJECT.yaml

    result=$(get_config .nonexistent.deeply.nested.path "my-default")

    [ "$result" = "my-default" ]
}

@test "get_config: mixed valid and missing values" {
    cp "$FIXTURES_DIR/minimal.yaml" PROJECT.yaml

    app_name=$(get_config .name "")
    backend=$(get_config .secrets.backend "infisical")
    invalid=$(get_config .completely.invalid "n/a")

    [ "$app_name" = "minimal-app" ]
    [ "$backend" = "infisical" ]
    [ "$invalid" = "n/a" ]
}

# =============================================================================
# get_config() - No PROJECT.yaml
# =============================================================================

@test "get_config: returns unquoted default when no PROJECT.yaml" {
    # No PROJECT.yaml in temp dir

    result=$(get_config .name "fallback-name")

    [ "$result" = "fallback-name" ]
}

@test "get_config: returns empty when no PROJECT.yaml and no default" {
    # No PROJECT.yaml in temp dir

    result=$(get_config .name "")

    [ -z "$result" ]
}

# =============================================================================
# get_config() - blank/null value behavior
# =============================================================================

@test "get_config: blank YAML string uses default via alternative operator" {
    cp "$FIXTURES_DIR/blank-values.yaml" PROJECT.yaml

    result=$(get_config .name "fallback-app")

    # yq v4 treats "" as falsy for the // operator, so default is used
    [ "$result" = "fallback-app" ]
}

@test "get_config: null YAML value with default returns default" {
    cp "$FIXTURES_DIR/blank-values.yaml" PROJECT.yaml

    result=$(get_config .version_file "some-default")

    [ "$result" = "some-default" ]
}

@test "get_config: existing value ignores default" {
    cp "$FIXTURES_DIR/complete.yaml" PROJECT.yaml

    result=$(get_config .name "ignored-default")

    [ "$result" = "test-app" ]
}

@test "get_config: empty string default returns empty for missing" {
    cp "$FIXTURES_DIR/minimal.yaml" PROJECT.yaml

    result=$(get_config .nonexistent "")

    [ -z "$result" ]
}

@test "get_config: no default argument returns empty for missing" {
    cp "$FIXTURES_DIR/minimal.yaml" PROJECT.yaml

    result=$(get_config .secrets.backend)

    [ -z "$result" ]
}

# =============================================================================
# Malformed paths
# =============================================================================

@test "get_config: returns unquoted default for malformed path syntax" {
    cp "$FIXTURES_DIR/complete.yaml" PROJECT.yaml

    result=$(get_config "..secrets" "safe-default")

    [ "$result" = "safe-default" ]
}

# =============================================================================
# get_config() - with defaults
# =============================================================================

@test "get_config: returns actual value when exists with default" {
    cp "$FIXTURES_DIR/complete.yaml" PROJECT.yaml

    result=$(get_config .name "default-app")

    [ "$result" = "test-app" ]
}

@test "get_config: returns default for missing key" {
    cp "$FIXTURES_DIR/minimal.yaml" PROJECT.yaml

    result=$(get_config .secrets.backend "infisical")

    [ "$result" = "infisical" ]
}

@test "get_config: blank value uses default via alternative operator" {
    cp "$FIXTURES_DIR/blank-values.yaml" PROJECT.yaml

    result=$(get_config .name "fallback-app")

    # yq v4 treats "" as falsy for the // operator, so default is used
    [ "$result" = "fallback-app" ]
}

@test "get_config: returns default for invalid path" {
    cp "$FIXTURES_DIR/complete.yaml" PROJECT.yaml

    result=$(get_config .invalid.path "default-value")

    [ "$result" = "default-value" ]
}

@test "get_config: returns empty when no default for missing" {
    cp "$FIXTURES_DIR/minimal.yaml" PROJECT.yaml

    result=$(get_config .secrets.backend)

    [ -z "$result" ]
}

# =============================================================================
# get_secrets_backend() - Helper function
# =============================================================================

@test "get_secrets_backend: returns backend from PROJECT.yaml" {
    cp "$FIXTURES_DIR/complete.yaml" PROJECT.yaml

    result=$(get_secrets_backend)

    [ "$result" = "aws" ]
}

@test "get_secrets_backend: auto-detects when backend missing in config" {
    cp "$FIXTURES_DIR/minimal.yaml" PROJECT.yaml

    # When secrets.backend is missing, get_config returns "" (empty)
    # which triggers auto-detect based on platform
    result=$(get_secrets_backend)

    if [[ "$(uname -s)" == "Darwin" ]]; then
        [ "$result" = "aws" ]
    else
        [ "$result" = "infisical" ]
    fi
}

@test "get_secrets_backend: auto-detects when no PROJECT.yaml on Linux" {
    # No PROJECT.yaml, so get_config falls back to "" (truly empty)
    # which triggers auto-detect

    result=$(get_secrets_backend)

    if [[ "$(uname -s)" == "Darwin" ]]; then
        [ "$result" = "aws" ]
    else
        [ "$result" = "infisical" ]
    fi
}

# =============================================================================
# get_app_name() - Helper function
# =============================================================================

@test "get_app_name: returns name from PROJECT.yaml" {
    cp "$FIXTURES_DIR/complete.yaml" PROJECT.yaml

    result=$(get_app_name)

    [ "$result" = "test-app" ]
}

@test "get_app_name: returns empty when name field removed" {
    cp "$FIXTURES_DIR/minimal.yaml" PROJECT.yaml
    grep -v '^name:' PROJECT.yaml > PROJECT.yaml.tmp && mv PROJECT.yaml.tmp PROJECT.yaml

    result=$(get_app_name)

    [ -z "$result" ]
}

@test "get_app_name: returns empty when name is blank string" {
    cp "$FIXTURES_DIR/blank-values.yaml" PROJECT.yaml

    result=$(get_app_name)

    [ -z "$result" ]
}

@test "get_app_name: returns empty when no PROJECT.yaml" {
    # No PROJECT.yaml at all

    result=$(get_app_name)

    [ -z "$result" ]
}

# =============================================================================
# Edge cases and error handling
# =============================================================================

@test "get_config: handles special characters in values" {
    cat > PROJECT.yaml << 'EOF'
name: app-with-dashes_and_underscores
secrets:
  backend: "value with spaces"
EOF

    app_name=$(get_config .name)
    backend=$(get_config .secrets.backend)

    [ "$app_name" = "app-with-dashes_and_underscores" ]
    [ "$backend" = "value with spaces" ]
}

@test "get_config: handles numeric values" {
    cat > PROJECT.yaml << 'EOF'
testing:
  min_coverage: 80
deployment:
  staging:
    port: 8000
EOF

    coverage=$(get_config .testing.min_coverage)
    port=$(get_config .deployment.staging.port)

    [ "$coverage" = "80" ]
    [ "$port" = "8000" ]
}

@test "get_config: handles boolean true values" {
    cat > PROJECT.yaml << 'EOF'
features:
  enabled: true
EOF

    result=$(get_config .features.enabled)

    [ "$result" = "true" ]
}
