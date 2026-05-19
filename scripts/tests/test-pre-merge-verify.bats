#!/usr/bin/env bats

# Test suite for pre-merge-verify.sh
# Covers: doc-only skip, no Makefile skip, service detection, rebase failure,
#         lint failure, all pass, --doc-only flag, PROJECT.yaml services, directory fallback

load test_helper

SCRIPT="pre-merge-verify.sh"

setup() {
    common_setup
    SCRIPT_PATH="${SCRIPTS_DIR}/${SCRIPT}"

    # Create a real git repo with a target branch and feature branch
    cd "$TEST_DIR"
    git init -q
    git config user.email "test@test.com"
    git config user.name "Test User"
    echo "init" > README.md
    git add README.md
    git commit -q -m "initial commit"
    git branch dev

    # Create feature branch with changes
    git checkout -q -b feature/test-feature
}

teardown() {
    common_teardown
}

# Helper: create a Makefile with specified targets
_create_makefile() {
    local targets=("$@")
    local content="# Mock Makefile\n.PHONY: ${targets[*]}\n"
    for t in "${targets[@]}"; do
        content+="${t}:\n\t@echo \"Running ${t}\"\n"
    done
    printf '%b' "$content" > "${TEST_DIR}/Makefile"

    # pre-merge-verify.sh requires PROJECT.yaml with docker: services
    # to advance past the "no docker services" auto-skip. Create a
    # minimal one alongside the Makefile so the tests reach the
    # service-detection / rebase / lint paths they're targeting.
    if [[ ! -f "${TEST_DIR}/PROJECT.yaml" ]]; then
        cat > "${TEST_DIR}/PROJECT.yaml" <<'YAML'
name: test-project
docker:
  services:
    - backend
    - frontend
YAML
    fi
}

# Helper: add a file on the feature branch and commit it
_add_changed_file() {
    local filepath="$1"
    local content="${2:-changed}"
    mkdir -p "$(dirname "${TEST_DIR}/${filepath}")"
    echo "$content" > "${TEST_DIR}/${filepath}"
    cd "$TEST_DIR"
    git add "$filepath"
    git commit -q -m "add ${filepath}"
}

# =============================================================================
# Test 1: Doc-only changes → skipped
# =============================================================================

@test "pre-merge-verify: doc-only changes return status=skipped" {
    _add_changed_file "docs/guide.md"
    _add_changed_file "README.md"
    _create_makefile "lint" "test" "build"

    run "$SCRIPT_PATH" --json --target-branch dev
    assert_valid_json "$output"
    assert_json_field "$output" ".status" "skipped"
    # skipped_reason should explain why
    local reason
    reason=$(echo "$output" | jq -r '.skipped_reason')
    [ "$reason" != "null" ] && [ -n "$reason" ]
}

# =============================================================================
# Test 2: No Makefile → skipped
# =============================================================================

@test "pre-merge-verify: no Makefile returns status=skipped" {
    _add_changed_file "backend/main.py"

    run "$SCRIPT_PATH" --json --target-branch dev
    assert_valid_json "$output"
    assert_json_field "$output" ".status" "skipped"
    local reason
    reason=$(echo "$output" | jq -r '.skipped_reason')
    [[ "$reason" == *"Makefile"* ]]
}

# =============================================================================
# Test 3: Affected services detected from git diff
# =============================================================================

@test "pre-merge-verify: detects affected services from changed file paths" {
    _add_changed_file "backend/main.py"
    _add_changed_file "frontend/index.tsx"
    _create_makefile "lint" "test" "build" "lint-backend" "test-backend" "lint-frontend" "test-frontend"

    run "$SCRIPT_PATH" --json --target-branch dev
    assert_valid_json "$output"

    # Check affected_services includes backend and frontend
    local services
    services=$(echo "$output" | jq -r '.affected_services | sort | join(",")')
    [[ "$services" == *"backend"* ]]
    [[ "$services" == *"frontend"* ]]
}

# =============================================================================
# Test 4: Rebase failure → fail with details
# =============================================================================

@test "pre-merge-verify: rebase failure returns status=fail" {
    # Create a conflict: modify same file on dev and feature
    cd "$TEST_DIR"
    git checkout -q dev
    echo "dev change" > conflicting.txt
    git add conflicting.txt
    git commit -q -m "dev: add conflicting"

    git checkout -q feature/test-feature
    echo "feature change" > conflicting.txt
    git add conflicting.txt
    git commit -q -m "feature: add conflicting"

    _create_makefile "lint" "test" "build"

    run "$SCRIPT_PATH" --json --target-branch dev
    assert_valid_json "$output"
    assert_json_field "$output" ".status" "fail"

    # Check rebase step failed
    local rebase_status
    rebase_status=$(echo "$output" | jq -r '.steps[] | select(.name == "rebase") | .status')
    [ "$rebase_status" = "fail" ]
}

# =============================================================================
# Test 5: Lint failure → fail, stops before test/build
# =============================================================================

@test "pre-merge-verify: lint failure stops before test and build" {
    _add_changed_file "backend/main.py"

    # Create Makefile where lint-backend fails. Output uses the
    # "N error(s)" form that pre-merge-verify._count_lint_errors
    # recognizes so the feature-vs-baseline comparison registers a
    # real regression (otherwise both sides count 0 and the failure
    # is treated as pre-existing).
    cat > "${TEST_DIR}/Makefile" <<'MAKEFILE'
.PHONY: lint-backend test-backend build
lint-backend:
	@echo "Found 1 error in foo.py" >&2; exit 1
test-backend:
	@echo "Running tests"
build:
	@echo "Building"
MAKEFILE

    # pre-merge-verify.sh requires PROJECT.yaml with docker: services
    cat > "${TEST_DIR}/PROJECT.yaml" <<'YAML'
name: test-project
docker:
  services:
    - backend
YAML

    # Commit Makefile + PROJECT.yaml so the rebase doesn't carry the
    # failing lint Makefile back to dev as untracked residual (which
    # would make the baseline lint also fail and the failure appear
    # pre-existing).
    git add Makefile PROJECT.yaml
    git commit -q -m "add failing lint Makefile + PROJECT.yaml on feature"

    run "$SCRIPT_PATH" --json --target-branch dev
    assert_valid_json "$output"
    assert_json_field "$output" ".status" "fail"

    # Lint step should be fail
    local lint_status
    lint_status=$(echo "$output" | jq -r '.steps[] | select(.name == "lint") | .status')
    [ "$lint_status" = "fail" ]

    # Test and build steps should not exist (stopped early)
    local test_step
    test_step=$(echo "$output" | jq -r '.steps[] | select(.name == "test") | .status // empty')
    [ -z "$test_step" ]
}

# =============================================================================
# Test 6: All steps pass → status: pass
# =============================================================================

@test "pre-merge-verify: all steps pass returns status=pass" {
    _add_changed_file "backend/main.py"
    _create_makefile "lint-backend" "test-backend" "build"

    run "$SCRIPT_PATH" --json --target-branch dev
    assert_valid_json "$output"
    assert_json_field "$output" ".status" "pass"

    # All steps should be pass
    local all_pass
    all_pass=$(echo "$output" | jq '[.steps[].status] | all(. == "pass")')
    [ "$all_pass" = "true" ]
}

# =============================================================================
# Test 7: --doc-only flag → skipped
# =============================================================================

@test "pre-merge-verify: --doc-only flag returns status=skipped" {
    _add_changed_file "backend/main.py"
    _create_makefile "lint" "test" "build"

    run "$SCRIPT_PATH" --json --target-branch dev --doc-only
    assert_valid_json "$output"
    assert_json_field "$output" ".status" "skipped"
    local reason
    reason=$(echo "$output" | jq -r '.skipped_reason')
    [[ "$reason" == *"doc-only"* ]]
}

# =============================================================================
# Test 8: SERVICE detection from PROJECT.yaml docker.services
# =============================================================================

@test "pre-merge-verify: detects services from PROJECT.yaml docker.services" {
    # Create PROJECT.yaml with docker services
    cat > "${TEST_DIR}/PROJECT.yaml" <<'YAML'
name: test-project
docker:
  services:
    - api
    - web
YAML

    # Add changes in api/ directory
    _add_changed_file "api/handler.py"
    _create_makefile "lint-api" "test-api" "build"

    run "$SCRIPT_PATH" --json --target-branch dev
    assert_valid_json "$output"

    local services
    services=$(echo "$output" | jq -r '.affected_services | join(",")')
    [[ "$services" == *"api"* ]]
}

# =============================================================================
# Test 9: Fallback to directory convention when no PROJECT.yaml
# =============================================================================

@test "pre-merge-verify: falls back to directory names without PROJECT.yaml" {
    # No PROJECT.yaml — should use top-level dirs from changed files
    _add_changed_file "services/auth/main.go"
    _add_changed_file "services/gateway/main.go"
    _create_makefile "lint" "test" "build"

    run "$SCRIPT_PATH" --json --target-branch dev
    assert_valid_json "$output"

    local services
    services=$(echo "$output" | jq -r '.affected_services | join(",")')
    [[ "$services" == *"services"* ]]
}

# =============================================================================
# Additional: JSON structure validation
# =============================================================================

@test "pre-merge-verify: output has required JSON structure" {
    _add_changed_file "backend/main.py"
    _create_makefile "lint-backend" "test-backend" "build"

    run "$SCRIPT_PATH" --json --target-branch dev
    assert_valid_json "$output"

    # Required top-level fields
    assert_json_field_present "$output" ".status"
    assert_json_field_present "$output" ".steps"
    assert_json_field_present "$output" ".affected_services"

    # skipped_reason should be present (null when not skipped)
    local has_skipped
    has_skipped=$(echo "$output" | jq 'has("skipped_reason")')
    [ "$has_skipped" = "true" ]
}

@test "pre-merge-verify: detect_services step shows services found" {
    _add_changed_file "backend/main.py"
    _create_makefile "lint-backend" "test-backend" "build"

    run "$SCRIPT_PATH" --json --target-branch dev
    assert_valid_json "$output"

    local svc_step_services
    svc_step_services=$(echo "$output" | jq -r '.steps[] | select(.name == "detect_services") | .services | join(",")')
    [[ "$svc_step_services" == *"backend"* ]]
}

@test "pre-merge-verify: missing --target-branch returns error" {
    run "$SCRIPT_PATH" --json
    [ "$status" -ne 0 ]
}

# =============================================================================
# Fallback make targets
# =============================================================================

@test "pre-merge-verify: falls back to make lint when lint-<service> missing" {
    _add_changed_file "backend/main.py"
    # Makefile has lint and test but NOT lint-backend or test-backend
    _create_makefile "lint" "test" "build"

    run "$SCRIPT_PATH" --json --target-branch dev
    assert_valid_json "$output"
    # Should still pass (uses fallback targets)
    assert_json_field "$output" ".status" "pass"
}

@test "pre-merge-verify: .github changes only → skipped" {
    _add_changed_file ".github/workflows/ci.yml"
    _create_makefile "lint" "test" "build"

    run "$SCRIPT_PATH" --json --target-branch dev
    assert_valid_json "$output"
    assert_json_field "$output" ".status" "skipped"
}
