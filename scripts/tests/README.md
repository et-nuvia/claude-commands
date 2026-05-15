# Project Config Test Suite

Comprehensive BATS test suite for `lib/project-config.sh` and related scripts.

## Prerequisites

Install BATS (Bash Automated Testing System):

```bash
# macOS
brew install bats-core

# Linux (npm)
npm install -g bats

# Linux (manual)
git clone https://github.com/bats-core/bats-core.git
cd bats-core
sudo ./install.sh /usr/local
```

Also requires:
- `jq` - JSON processor
- `yq` - YAML processor (Python yq, not Go yq)

## Running Tests

Run all tests:
```bash
./run-tests.sh
```

Run specific test file:
```bash
bats test-project-config.bats
bats test-analyze-config-usage.bats
```

Run with verbose output:
```bash
bats -t test-project-config.bats
```

## Test Coverage

### test-project-config.bats (35 tests)

Tests for `lib/project-config.sh`:

**Core Functions:**
- `get_project_config()` - Single and batch value retrieval
- `is_special_value()` - Special value detection
- `get_config_value()` - Single value with defaults

**Helper Functions:**
- `get_app_secrets_config()` - App name + secrets backend
- `get_app_name()` - App name with fallback

**Special Values:**
- `__BLANK__` - Empty or null values
- `__MISSING__` - Valid path but value not present
- `__INVALID__` - Invalid path according to schema

**Edge Cases:**
- No PROJECT.yaml file
- Missing dependencies (jq, yq)
- Special characters in values
- Numeric and boolean values
- Nested path access

### test-analyze-config-usage.bats (20 tests)

Tests for `analyze-config-usage.sh`:

**Duplicate Detection:**
- No duplicates (exit 0)
- Duplicates found (exit 1)
- Multiple duplicate patterns
- Pattern normalization (whitespace, ordering)

**Pattern Extraction:**
- Multiline get_project_config calls
- Alphabetic key sorting
- Directory exclusions (lib/, analyze script itself)

**Modes:**
- `--full` - Find duplicates
- `--verify` - Pre-commit check
- `--cache-only` - Return empty JSON

**Real-World Scenarios:**
- Detection of app_name + secrets_backend pattern
- Verification after helper migration

## Test Structure

```
tests/
├── README.md                          # This file
├── run-tests.sh                       # Test runner
├── test-project-config.bats          # Core library tests
├── test-analyze-config-usage.bats    # Duplicate detection tests
└── fixtures/                          # Test data
    ├── complete.yaml                  # Full PROJECT.yaml
    ├── minimal.yaml                   # Minimal config
    └── blank-values.yaml              # Empty/null values
```

## Fixtures

**complete.yaml** - Full configuration with all sections:
- name, version_file
- secrets.backend, secrets.infisical.project_id
- deployment.staging/production (host, port)
- infrastructure.staging.ip
- testing (command, coverage_command, min_coverage)

**minimal.yaml** - Minimal configuration:
- name only

**blank-values.yaml** - Empty and null values:
- Empty string for name
- Null for version_file
- Empty host in deployment.staging

## Writing New Tests

Follow BATS conventions:

```bash
@test "descriptive test name" {
    # Setup (if needed beyond global setup)
    cp "$FIXTURES_DIR/complete.yaml" PROJECT.yaml

    # Execute
    result=$(get_project_config app_name=.name)

    # Assert
    [ "$(echo "$result" | jq -r '.app_name')" = "test-app" ]
}
```

Use `run` for commands that might fail:

```bash
@test "error handling" {
    run get_project_config invalid=.path

    [ "$status" -eq 1 ]
    [[ "$output" =~ "error message" ]]
}
```

## Continuous Integration

These tests should run on every commit via pre-commit hook:

```bash
#!/usr/bin/env bash
# .git/hooks/pre-commit

cd ~/.claude/scripts/tests
./run-tests.sh || exit 1
```

Target: < 1 second execution time for fast pre-commit checks.

## Troubleshooting

**Tests fail with "command not found: jq"**
- Install jq: `brew install jq` or `apt install jq`

**Tests fail with "command not found: yq"**
- Install Python yq: `pip install yq` (NOT Go yq)
- Verify: `yq --version` should show Python-based yq

**Tests hang or timeout**
- Check for infinite loops in while/read constructs
- Ensure temp directories are cleaned up in teardown

**Spurious failures in CI**
- Check for race conditions
- Ensure tests are independent (no shared state)
- Verify temp directories are unique per test
