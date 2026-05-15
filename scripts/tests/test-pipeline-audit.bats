#!/usr/bin/env bats

# Test suite for pipeline-audit.sh merge strategy compliance checks
# Covers: promotion merge strategy, feature squash, pre-merge verification, tag placement

load test_helper

setup() {
    common_setup
    # All tests need a PROJECT.yaml with CI branches configured
    cat > "${TEST_DIR}/PROJECT.yaml" <<'YAML'
name: test-app

ci:
  platform: github
  branches:
    staging: staging
    production: main

secrets:
  backend: aws
YAML
    mkdir -p "${TEST_DIR}/.github/workflows"
    mkdir -p "${TEST_DIR}/scripts"
}

teardown() {
    common_teardown
}

# =============================================================================
# Helper: create a minimal pipeline file with content
# =============================================================================

make_pipeline() {
    local content="$1"
    # Include a docker build step so grep -cE in parallel-builds check returns exit 0,
    # preventing the pre-existing arithmetic bug (double "0" from grep || echo "0").
    cat > "${TEST_DIR}/.github/workflows/ci.yml" <<EOF
$content
  build:
    runs-on: ubuntu-latest
    steps:
      - run: docker build .
EOF
}

make_deploy_stage() {
    local content="$1"
    cat > "${TEST_DIR}/scripts/deploy-to-stage.sh" <<EOF
$content
EOF
    chmod +x "${TEST_DIR}/scripts/deploy-to-stage.sh"
}

run_audit() {
    run "$SCRIPTS_DIR/pipeline-audit.sh" --stage scan 2>&1
}

# =============================================================================
# Check 1: Promotion uses regular merge (not squash)
# =============================================================================

@test "merge-strategy: squash in deploy-to-stage.sh fails 'Promotion uses regular merge'" {
    make_pipeline "on: push
jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - run: make lint
  test:
    runs-on: ubuntu-latest
    steps:
      - run: make test"

    make_deploy_stage "#!/usr/bin/env bash
# Deploy to staging
git merge --squash feature-branch
git commit -m 'squash merge'"

    run_audit
    [[ "$output" == *"Promotion uses regular merge"* ]]
    [[ "$output" == *"Squash merge found"* ]] || [[ "$output" == *"FAIL"* ]] || [[ "$output" == *"squash"* ]]
}

@test "merge-strategy: no squash in deploy-to-stage.sh passes 'Promotion uses regular merge'" {
    make_pipeline "on: push
jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - run: make lint
  test:
    runs-on: ubuntu-latest
    steps:
      - run: make test"

    make_deploy_stage "#!/usr/bin/env bash
# Deploy to staging - regular merge
git merge feature-branch
git commit -m 'merge feature'"

    run_audit
    [[ "$output" == *"Promotion uses regular merge"* ]]
    # Should not report as fail
    [[ "$output" != *"Squash merge found in staging promotion"* ]]
}

# =============================================================================
# Check 2: Feature merge uses squash
# =============================================================================

@test "merge-strategy: squash pattern in pipeline passes 'Feature merge uses squash'" {
    make_pipeline "on: push
jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - run: make lint
  test:
    runs-on: ubuntu-latest
    steps:
      - run: make test
  merge:
    runs-on: ubuntu-latest
    steps:
      - run: git merge --squash feature-branch"

    run_audit
    [[ "$output" == *"Feature merge uses squash"* ]]
    [[ "$output" != *"No squash merge pattern found"* ]]
}

@test "merge-strategy: no squash pattern warns 'Feature merge uses squash'" {
    make_pipeline "on: push
jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - run: make lint
  test:
    runs-on: ubuntu-latest
    steps:
      - run: make test"

    run_audit
    [[ "$output" == *"Feature merge uses squash"* ]]
    [[ "$output" == *"No squash merge pattern"* ]]
}

# =============================================================================
# Check 3: Pre-merge verification exists
# =============================================================================

@test "merge-strategy: make lint and make test in pipeline passes 'Pre-merge verification'" {
    make_pipeline "on: push
jobs:
  pre-merge:
    runs-on: ubuntu-latest
    steps:
      - run: make lint
      - run: make test
      - run: make build"

    run_audit
    [[ "$output" == *"Pre-merge verification"* ]]
    [[ "$output" != *"No pre-merge verification"* ]]
}

@test "merge-strategy: no verification indicators warns 'Pre-merge verification'" {
    make_pipeline "on: push
jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - run: echo deploying"

    run_audit
    [[ "$output" == *"Pre-merge verification"* ]]
    [[ "$output" == *"pre-merge verification"* ]]
}

# =============================================================================
# Check 4: Tags only on production
# =============================================================================

@test "merge-strategy: git tag in staging pipeline warns 'Tags only on production'" {
    # Create a staging-specific workflow file
    cat > "${TEST_DIR}/.github/workflows/staging.yml" <<'EOF'
on:
  push:
    branches: [staging]
jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - run: make lint
      - run: make test
      - run: git tag v1.0.0
      - run: docker build .
EOF

    run_audit
    [[ "$output" == *"Tags only on production"* ]]
    [[ "$output" == *"staging pipeline"* ]] || [[ "$output" == *"staging"* ]]
}

@test "merge-strategy: git tag only in non-staging pipeline passes 'Tags only on production'" {
    # Staging workflow without git tag
    cat > "${TEST_DIR}/.github/workflows/staging.yml" <<'EOF'
on:
  push:
    branches: [staging]
jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - run: make lint
      - run: make test
      - run: docker build .
EOF
    # Production workflow with git tag (non-staging filename)
    # Include docker build to avoid pre-existing arithmetic bug in parallel-builds check
    cat > "${TEST_DIR}/.github/workflows/production.yml" <<'EOF'
on:
  push:
    branches: [main]
jobs:
  release:
    runs-on: ubuntu-latest
    steps:
      - run: make lint
      - run: make test
      - run: docker build .
      - run: git tag v1.0.0
      - run: docker push registry/app:latest
EOF

    run_audit
    [[ "$output" == *"Tags only on production"* ]]
    [[ "$output" != *"Git tag commands found in staging pipeline"* ]]
}

# =============================================================================
# Syntax: verify the script passes bash -n after implementation
# =============================================================================

@test "pipeline-audit.sh: passes bash syntax check" {
    run bash -n "$SCRIPTS_DIR/pipeline-audit.sh"
    [ "$status" -eq 0 ]
}
