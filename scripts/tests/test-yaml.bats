#!/usr/bin/env bats

# Test suite for lib/yaml.sh
# Covers: yaml_get, yaml_get_default, yq variant detection

load test_helper

setup() {
    common_setup
    source "$SCRIPTS_DIR/lib/yaml.sh"
    # Reset cached variant so detection runs fresh each test
    _YQ_VARIANT=""
}

teardown() {
    common_teardown
}

# =============================================================================
# yaml_get
# =============================================================================

@test "yaml_get: reads simple value" {
    cat > test.yaml <<'YAML'
name: my-project
YAML
    result=$(yaml_get '.name' test.yaml)
    [ "$result" = "my-project" ]
}

@test "yaml_get: reads nested value" {
    cat > test.yaml <<'YAML'
git:
  platform: gitlab
  instance: git.example.com
YAML
    result=$(yaml_get '.git.platform' test.yaml)
    [ "$result" = "gitlab" ]
}

@test "yaml_get: returns empty for missing key" {
    cat > test.yaml <<'YAML'
name: my-project
YAML
    result=$(yaml_get '.nonexistent' test.yaml)
    [ -z "$result" ]
}

@test "yaml_get: returns empty for null value" {
    cat > test.yaml <<'YAML'
name: null
YAML
    result=$(yaml_get '.name' test.yaml)
    [ -z "$result" ]
}

@test "yaml_get: returns empty for missing file" {
    result=$(yaml_get '.name' nonexistent.yaml)
    [ -z "$result" ]
}

@test "yaml_get: handles jq alternative operator" {
    cat > test.yaml <<'YAML'
name: my-project
YAML
    result=$(yaml_get '.missing // "fallback"' test.yaml)
    [ "$result" = "fallback" ]
}

@test "yaml_get: reads array element" {
    cat > test.yaml <<'YAML'
items:
  - first
  - second
YAML
    result=$(yaml_get '.items[0]' test.yaml)
    [ "$result" = "first" ]
}

@test "yaml_get: defaults to PROJECT.yaml" {
    cat > PROJECT.yaml <<'YAML'
name: default-project
YAML
    result=$(yaml_get '.name')
    [ "$result" = "default-project" ]
}

# =============================================================================
# yaml_get_default
# =============================================================================

@test "yaml_get_default: returns value when exists" {
    cat > test.yaml <<'YAML'
name: my-project
YAML
    result=$(yaml_get_default '.name' 'fallback' test.yaml)
    [ "$result" = "my-project" ]
}

@test "yaml_get_default: returns default when missing" {
    cat > test.yaml <<'YAML'
name: my-project
YAML
    result=$(yaml_get_default '.nonexistent' 'fallback' test.yaml)
    [ "$result" = "fallback" ]
}

@test "yaml_get_default: returns default for null" {
    cat > test.yaml <<'YAML'
value: null
YAML
    result=$(yaml_get_default '.value' 'fallback' test.yaml)
    [ "$result" = "fallback" ]
}

@test "yaml_get_default: returns empty string default" {
    cat > test.yaml <<'YAML'
name: exists
YAML
    result=$(yaml_get_default '.missing' '' test.yaml)
    [ -z "$result" ]
}

# =============================================================================
# yq variant detection
# =============================================================================

@test "yaml_get: detects yq variant and caches it" {
    cat > test.yaml <<'YAML'
test: value
YAML
    yaml_get '.test' test.yaml
    [ -n "$_YQ_VARIANT" ]
    # Should be either "go" or "python"
    [[ "$_YQ_VARIANT" == "go" || "$_YQ_VARIANT" == "python" ]]
}
