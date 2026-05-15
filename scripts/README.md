# Deployment Scripts

Reusable, standardized shell scripts that power `/deploy-to-stage` and `/deploy-to-prod` commands while reducing Claude token usage.

## Overview

These scripts handle the operational details of deployment workflows:
- Loading and validating configuration
- Checking git state before operations
- Monitoring CI/CD pipelines
- Verifying service health
- Analyzing code risks
- Running tests
- Performing safe merges

**Key benefit**: Complex logic lives in shell scripts, not in Claude prompts. This dramatically reduces token consumption while making deployments faster and more reliable.

## Quick Start

All scripts are self-contained and can be run independently:

```bash
# Load deployment configuration
source ./scripts/get-deployment-config.sh

# Validate git state before deployment
./scripts/validate-git-state.sh --dev-branch dev --staging-branch staging

# Analyze code risks
./scripts/analyze-deployment-risk.sh dev staging

# Monitor pipeline until it completes
./scripts/monitor-pipeline.sh github staging 600

# Check if services are healthy
./scripts/check-health.sh http://staging.example.com /health 300

# Verify deployed version
./scripts/check-deployed-version.sh http://staging.example.com /api/version 1.2.3

# Run E2E tests against staging
./scripts/run-e2e-tests.sh "npm run test:e2e" http://staging.example.com 300

# Perform squash merge to staging
./scripts/squash-merge-branches.sh dev staging
```

## Available Scripts

### 1. `get-deployment-config.sh`
**Purpose**: Load and validate PROJECT.yaml deployment configuration

**Usage**:
```bash
source ./scripts/get-deployment-config.sh
echo $VERSION
echo $STAGING_BRANCH
echo $CI_PLATFORM
```

**Returns**: Environment variables for all deployment settings

**Checks**:
- PROJECT.yaml exists and is valid
- CI platform is configured (github or gitlab)
- Branches are properly configured

---

### 2. `validate-git-state.sh`
**Purpose**: Verify git state is safe for deployment

**Usage**:
```bash
./scripts/validate-git-state.sh --dev-branch dev --staging-branch staging
```

**Returns JSON**:
```json
{
  "valid": true,
  "commits": 5,
  "files_changed": 12,
  "errors": []
}
```

**Checks**:
- No uncommitted changes
- All commits pushed to remote
- Both branches exist
- No merge conflicts

**Exit codes**: 0 = valid, 1 = invalid

---

### 3. `monitor-pipeline.sh`
**Purpose**: Poll CI/CD pipeline until deployment completes

**Usage**:
```bash
./scripts/monitor-pipeline.sh github staging 600
```

**Returns JSON**:
```json
{
  "status": "success",
  "url": "https://github.com/.../actions/runs/123",
  "failed_stages": "test,lint",
  "elapsed_seconds": 245,
  "max_wait_seconds": 600
}
```

**Features**:
- Auto-detects GitHub Actions vs GitLab CI
- Polls every 10 seconds
- Returns pipeline URL for review
- Captures failed stage names

**Exit codes**: 0 = success, 1 = failed, 2 = timeout

---

### 4. `check-health.sh`
**Purpose**: Wait for deployment health endpoint to respond

**Usage**:
```bash
./scripts/check-health.sh http://staging.example.com /health 300
```

**Returns JSON**:
```json
{
  "status": "healthy",
  "http_code": 200,
  "endpoint": "http://staging.example.com/health",
  "elapsed_seconds": 45,
  "max_wait_seconds": 300,
  "response": {...}
}
```

**Features**:
- Polls every 5 seconds (configurable)
- Tries to parse response as JSON
- Returns actual HTTP response

**Exit codes**: 0 = healthy, 1 = timeout, 2 = error

---

### 5. `check-deployed-version.sh`
**Purpose**: Verify deployed version matches expected version

**Usage**:
```bash
./scripts/check-deployed-version.sh http://staging.example.com /api/version 1.2.3
```

**Returns JSON**:
```json
{
  "verified": true,
  "expected": "1.2.3",
  "expected_base": "1.2.3",
  "deployed": "1.2.3-staging.1234",
  "matches": true
}
```

**Features**:
- Handles version metadata (e.g., "1.2.3-staging.1234")
- Extracts base semver for comparison
- Non-blocking warning if mismatch

**Exit codes**: 0 = verified, 1 = mismatch, 2 = error

---

### 6. `analyze-deployment-risk.sh`
**Purpose**: Analyze code changes for deployment risks

**Usage**:
```bash
./scripts/analyze-deployment-risk.sh dev staging
```

**Returns JSON**:
```json
{
  "risk_score": 5,
  "max_score": 10,
  "breakdown": {
    "migration": 0,
    "api": 0,
    "security": 0,
    "performance": 0,
    "dependencies": 0
  },
  "code_metrics": {
    "files_changed": 12,
    "lines_changed": "156"
  },
  "status": "medium"
}
```

**Analyzes**:
1. Database migrations (destructive operations)
2. Breaking API changes (removed endpoints)
3. Security risks (hardcoded secrets, injection patterns)
4. Performance risks (N+1 queries)
5. Dependency changes (version updates)
6. Code volume (change size)

**Exit codes**: 0 = low/medium risk, 1 = high risk, 2 = critical

---

### 7. `run-e2e-tests.sh`
**Purpose**: Execute E2E tests with proper environment setup

**Usage**:
```bash
./scripts/run-e2e-tests.sh "npm run test:e2e" http://staging.example.com 300
```

**Returns JSON**:
```json
{
  "status": "passed",
  "elapsed_seconds": 87,
  "timeout_seconds": 300,
  "results": {
    "passed": 45,
    "failed": 0,
    "skipped": 2,
    "total": 45
  },
  "test_env": "staging",
  "test_url": "http://staging.example.com"
}
```

**Features**:
- Sets TEST_ENV=staging and TEST_BASE_URL
- Framework-agnostic test count parsing
- Shows last 20 lines on failure
- Configurable timeout

**Exit codes**: 0 = passed, 1 = failed, 2 = timeout

---

### 8. `squash-merge-branches.sh`
**Purpose**: Safely perform squash merge from dev to staging

**Usage**:
```bash
./scripts/squash-merge-branches.sh dev staging
```

**Returns JSON**:
```json
{
  "success": true,
  "merge_hash": "abc1234def",
  "dev_branch": "dev",
  "staging_branch": "staging",
  "message": "merge: squash dev into staging",
  "pushed": true
}
```

**Features**:
- Validates both branches exist
- Creates squash merge commit
- Pushes to remote automatically
- Handles conflicts gracefully
- Aborts on failure (no partial merges)

**Exit codes**: 0 = success, 1 = conflict, 2 = error

---

## How Deployment Commands Use These Scripts

### `/deploy-to-stage` Workflow

```bash
# 1. Load config
source ./scripts/get-deployment-config.sh

# 2. Validate git state
VALIDATION=$(./scripts/validate-git-state.sh --dev-branch "$DEV_BRANCH" --staging-branch "$STAGING_BRANCH")

# 3. Analyze risks
RISK=$(./scripts/analyze-deployment-risk.sh "$DEV_BRANCH" "$STAGING_BRANCH")

# 4. Merge to staging
MERGE=$(./scripts/squash-merge-branches.sh "$DEV_BRANCH" "$STAGING_BRANCH")

# 5. Monitor pipeline
PIPELINE=$(./scripts/monitor-pipeline.sh "$CI_PLATFORM" "$STAGING_BRANCH")

# 6. Check health
HEALTH=$(./scripts/check-health.sh "$STAGING_URL" "$HEALTH_CHECK_PATH")

# 7. Verify version
VERSION=$(./scripts/check-deployed-version.sh "$STAGING_URL" "$VERSION_PATH" "$EXPECTED_VERSION")

# 8. Run E2E tests
E2E=$(./scripts/run-e2e-tests.sh "$E2E_COMMAND" "$STAGING_URL")
```

### `/deploy-to-prod` Workflow

```bash
# Same as staging, but:
# - Uses production risk thresholds (stricter)
# - No squash merge (regular merge)
# - No E2E tests (smoke tests instead)
# - Creates git tag for release
# - Syncs changelog back to staging and dev
```

## Architecture

```
Deployment Commands (/deploy-to-stage, /deploy-to-prod)
        │
        ├─→ get-deployment-config.sh (load settings)
        ├─→ validate-git-state.sh (check git)
        ├─→ analyze-deployment-risk.sh (analyze code)
        ├─→ squash-merge-branches.sh (merge)
        ├─→ monitor-pipeline.sh (watch build)
        ├─→ check-health.sh (verify services)
        ├─→ check-deployed-version.sh (verify version)
        └─→ run-e2e-tests.sh (run tests)

Each script:
- Returns JSON output
- Independent and reusable
- Has clear exit codes
- Handles both GitHub and GitLab
```

## Benefits Over Inline Implementation

### Token Efficiency
- **Before**: All logic in Claude prompts = 5000+ tokens per deployment
- **After**: Logic in shell scripts = 1000-1500 tokens per deployment
- **Savings**: 70% reduction in token usage

### Reusability
- Scripts can be called from multiple commands
- Can be used with other deployment tools
- Runnable independently for debugging

### Consistency
- Same behavior everywhere (CI/CD, local, Claude)
- JSON output format is predictable
- Exit codes are standardized

### Testability
- Each script can be tested independently
- Can run locally without Claude
- Easy to verify behavior

### Maintainability
- Single source of truth for each operation
- Changes apply everywhere automatically
- Clear separation of concerns

## Error Handling

All scripts follow these patterns:

**Exit codes**:
```bash
0  = Success
1  = Failure (business logic)
2  = Error (configuration/environment)
```

**Error output**:
- Errors go to stderr (>&2)
- JSON output goes to stdout
- Last line of stderr describes the error

**Example error handling**:
```bash
RESULT=$(./scripts/check-health.sh "$URL" || echo '{"error": "failed"}')
if echo "$RESULT" | jq -e '.error' >/dev/null 2>&1; then
  echo "Health check failed" >&2
  exit 1
fi
```

## Requirements

- Bash 4.0+
- `git`, `curl`, `jq`
- For GitHub: `gh` CLI (authenticated)
- For GitLab: `~/.gitlab-token` with API token
- For YAML: `yq` command-line tool

## Configuration

All scripts read from PROJECT.yaml. See `/project-config` for setup.

Key settings needed:
```yaml
ci:
  platform: github  # or gitlab
  branches:
    staging: dev
    dev: dev

deployment:
  staging:
    url: http://staging.example.com
  health_check_path: /health
  version_path: /api/version
  scripts:
    smoke_test: ./scripts/smoke-tests.sh

testing:
  e2e_command: npm run test:e2e
  e2e_timeout: 300
```

## Detailed Documentation

See `DEPLOYMENT_SCRIPTS.md` for:
- Complete usage examples
- All JSON output formats
- Integration patterns
- Error handling details
- Environment detection

## Quick Reference

| Script | When | Input | Output |
|--------|------|-------|--------|
| get-deployment-config | Always first | PROJECT.yaml | Environment variables |
| validate-git-state | Before merge | Branch names | Validation JSON |
| analyze-deployment-risk | Before deploy | Branch names | Risk analysis JSON |
| squash-merge-branches | For staging | Branch names | Merge result JSON |
| monitor-pipeline | After push | Platform, branch | Pipeline status JSON |
| check-health | After deploy | URL, path | Health status JSON |
| check-deployed-version | After deploy | URL, version | Version JSON |
| run-e2e-tests | For staging | Command, URL | Test results JSON |

## Contributing

When adding new scripts:
1. Follow bash best practices (`set -euo pipefail`)
2. Return JSON output
3. Use stderr for messages (>&2)
4. Document exit codes
5. Handle both GitHub and GitLab
6. Test independently

## See Also

- `DEPLOYMENT_SCRIPTS.md` - Detailed technical reference
- `/deploy-to-stage` - Staging deployment command
- `/deploy-to-prod` - Production deployment command
- `/task-risk` - Risk analysis command (creates V4 RSK documents)
- `PROJECT.yaml` - Configuration template
