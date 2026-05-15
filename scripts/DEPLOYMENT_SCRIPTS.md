# Deployment Support Scripts

These scripts provide reusable, standardized functionality for the `/deploy-to-stage` command and other deployment operations. They reduce token usage by moving complex logic into executable shell scripts and return structured JSON output for easy parsing.

## Scripts Overview

### 1. `get-deployment-config.sh`
Load and validate PROJECT.yaml deployment configuration.

**Usage:**
```bash
source ./scripts/get-deployment-config.sh
```

**Exports these variables:**
- `ENV_TYPE` - Environment: "work" (macOS) or "home" (Linux)
- `DEV_BRANCH` - Development branch name (auto-detected if not in PROJECT.yaml)
- `STAGING_BRANCH` - Staging branch name (auto-detected if not in PROJECT.yaml)
- `PRODUCTION_BRANCH` - Production branch name (auto-detected if not in PROJECT.yaml)
- `CI_PLATFORM` - CI platform: "github" or "gitlab" (auto-detected from git remote)
- `DEPLOYMENT_METHOD` - Method: "pipeline", "script", "ssh", or "ssm"
- `HEALTH_CHECK_PATH` - Health endpoint path (default: "/health")
- `VERSION_PATH` - Version endpoint path (default: "/api/version")
- `E2E_COMMAND` - E2E test command
- `E2E_TIMEOUT` - E2E test timeout in seconds (default: 300)
- `STAGING_URL` - Staging deployment URL
- `PRODUCTION_URL` - Production deployment URL
- `VERSION` - Current version (from git tags or version_file)

**New in v2.0: Intelligent Defaults**
- Works without PROJECT.yaml (uses auto-detection with warnings)
- Auto-detects branches from git (dev/develop/development, staging/stage, production/prod/main)
- Auto-detects CI platform from git remote URL (github.com → github, git.* → gitlab)
- Suggests running `/project-config init` when PROJECT.yaml is missing

**Exit codes:**
- 0: Success (even with defaults)
- 1: Validation failed

---

### 2. `validate-git-state.sh`
Validate git state before deployment (branches exist, no uncommitted changes, no merge conflicts).

**Usage:**
```bash
./scripts/validate-git-state.sh --dev-branch <dev_branch> --staging-branch <staging_branch>
```

**Note:** Branches are now optional and will be auto-detected if not provided.

**Returns JSON:**
```json
{
  "valid": true/false,
  "commits": 5,
  "files_changed": 12,
  "errors": ["error message 1", "error message 2"]
}
```

**Checks:**
- No uncommitted changes in working directory
- All commits on dev branch are pushed
- Both branches exist on remote
- No merge conflicts between branches

**Exit codes:**
- 0: Git state valid
- 1: Validation failed

---

### 3. `monitor-pipeline.sh`
Monitor CI/CD pipeline status (GitHub Actions or GitLab CI).

**Usage:**
```bash
./scripts/monitor-pipeline.sh [ci_platform] <branch> [max_wait_seconds]
```

**Note:** CI platform is now optional and will be auto-detected from git remote URL if not provided.

**Returns JSON:**
```json
{
  "status": "success|failure|timeout|cancelled",
  "url": "https://...",
  "failed_stages": "stage1,stage2",
  "elapsed_seconds": 125,
  "max_wait_seconds": 600
}
```

**Features:**
- Automatic platform detection (GitHub Actions vs GitLab CI)
- Polls every 10 seconds, max 10 minutes (configurable)
- Returns pipeline URL for review
- Captures failed stage names

**Exit codes:**
- 0: Pipeline succeeded
- 1: Pipeline failed
- 2: Pipeline monitoring timeout

---

### 4. `check-health.sh`
Check deployment health endpoint until services are ready.

**Usage:**
```bash
./scripts/check-health.sh <url> [health_path] [max_wait_seconds]
```

**Returns JSON:**
```json
{
  "status": "healthy|timeout|skipped",
  "http_code": 200,
  "endpoint": "http://staging.example.com/health",
  "elapsed_seconds": 45,
  "max_wait_seconds": 300,
  "response": {...}
}
```

**Features:**
- Polls every 5 seconds, max 5 minutes (configurable)
- Returns HTTP response if available
- Tries to parse response as JSON
- **New:** Returns status "skipped" when URL is not provided (allows deployments without health checks)

**Exit codes:**
- 0: Service is healthy (HTTP 200) OR skipped (no URL provided)
- 1: Service timeout

---

### 5. `check-deployed-version.sh`
Verify deployed version matches expected version.

**Usage:**
```bash
./scripts/check-deployed-version.sh <url> <version_path> <expected_version>
```

**Returns JSON:**
```json
{
  "verified": true/false,
  "expected": "1.2.3",
  "expected_base": "1.2.3",
  "deployed": "1.2.3-staging.1234",
  "matches": true/false,
  "status": "verified|unknown|skipped"
}
```

**Features:**
- Handles version metadata (e.g., "1.2.3-staging.1234")
- Extracts base semver for comparison
- Queries /api/version endpoint
- **New:** Returns status "skipped" when URL is not provided (allows deployments without version checks)

**Exit codes:**
- 0: Version verified OR skipped (no URL provided)
- 1: Version mismatch

---

### 6. `analyze-deployment-risk.sh`
Perform code-aware deployment risk analysis.

**Usage:**
```bash
./scripts/analyze-deployment-risk.sh <dev_branch> <staging_branch>
```

**Returns JSON:**
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
  "status": "low|low-medium|medium|high|critical"
}
```

**Analyzes:**
1. **Database Migrations** - Destructive operations (DROP, DELETE, ALTER TYPE)
2. **Breaking API Changes** - Removed/changed endpoints
3. **Security Risks** - Hardcoded secrets, code injection, SQL injection
4. **Performance Risks** - N+1 query patterns
5. **Dependency Changes** - Significant version updates
6. **Code Volume** - Overall change size

**Exit codes:**
- 0: Low/medium risk (score < 7)
- 1: High risk (score 7-8)
- 2: Critical risk (score 9+)

---

### 7. `run-e2e-tests.sh`
Execute E2E tests with proper environment configuration.

**Usage:**
```bash
./scripts/run-e2e-tests.sh <e2e_command> <staging_url> [timeout_seconds]
```

**Returns JSON:**
```json
{
  "status": "passed|failed|timeout",
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

**Features:**
- Sets TEST_ENV=staging and TEST_BASE_URL
- Parses test output for counts (framework-agnostic)
- 5-minute default timeout (configurable)
- Shows last 20 lines on failure

**Exit codes:**
- 0: All tests passed
- 1: Tests failed
- 2: Tests timeout

---

### 8. `git-merge.sh` ⭐ NEW
Centralized git merge operations supporting both squash and regular merges.

**Usage:**
```bash
./scripts/git-merge.sh <source> <target> [--squash] [--message "msg"]
```

**Returns JSON:**
```json
{
  "success": true,
  "merge_type": "squash|regular",
  "merge_hash": "abc1234def",
  "source_branch": "dev",
  "target_branch": "staging",
  "message": "chore(deploy): squash dev to staging",
  "pushed": true
}
```

**Features:**
- **Supports both squash and regular merges** (use `--squash` flag for squash)
- Custom commit messages via `--message` flag
- Validates both branches exist
- Pushes to remote automatically
- Handles merge conflicts gracefully
- Returns detailed JSON with conflict information
- Aborts on failure (no partial merges)

**Exit codes:**
- 0: Merge successful and pushed
- 1: Merge conflict (branches not modified)
- 2: Error

**Replaces:** `squash-merge-branches.sh` (which is now deprecated)

---

### 9. `deployment-rollback.sh` ⭐ NEW
Proper deployment rollback mechanism with automated git revert.

**Usage:**
```bash
./scripts/deployment-rollback.sh <branch> <reason> [--force]
```

**Returns JSON:**
```json
{
  "success": true,
  "branch": "production",
  "original_hash": "abc1234",
  "revert_hash": "def5678",
  "reason": "health check failure",
  "message": "revert: rollback deployment due to health check failure",
  "pushed": true
}
```

**Features:**
- Creates revert commit for last deployment
- Pushes rollback automatically
- Includes reason in commit message
- Returns both original and revert hashes
- Safe abort on failure

**Exit codes:**
- 0: Rollback successful
- 1: Revert failed
- 2: Error

---

### 10. `smoke-tests.sh` ⭐ NEW
Production-specific smoke tests for deployment verification.

**Usage:**
```bash
./scripts/smoke-tests.sh <base_url> [--critical-only]
```

**Returns JSON:**
```json
{
  "status": "passed|failed|critical_failure",
  "tests_run": 10,
  "tests_passed": 10,
  "tests_failed": 0,
  "critical_failures": 0,
  "elapsed_seconds": 5,
  "base_url": "https://production.example.com",
  "critical_only": false,
  "results": [...]
}
```

**Critical Tests (always run):**
- Health endpoint (/)
- Version endpoint (/api/version)
- Root endpoint (/)
- Response time check (<2s)

**Extended Tests (unless --critical-only):**
- API docs endpoint
- Metrics endpoint
- Static assets
- HTTPS redirect
- Security headers
- CORS headers

**Exit codes:**
- 0: All tests passed
- 1: One or more tests failed

---

### 11. `git-branch-check.sh` ⭐ NEW
Validate git branch state for deployment readiness.

**Usage:**
```bash
./scripts/git-branch-check.sh --branch <branch> [--exists] [--clean] [--synced]
```

**Returns JSON:**
```json
{
  "status": "valid|invalid",
  "branch": "staging",
  "checks_run": 3,
  "checks_passed": 3,
  "checks_failed": 0,
  "checks": [...],
  "errors": [],
  "warnings": []
}
```

**Checks:**
- `--exists`: Branch exists locally and/or remotely
- `--clean`: Working directory has no uncommitted changes
- `--synced`: Local and remote branches are in sync

**Exit codes:**
- 0: All checks passed
- 1: One or more checks failed

---

## Integration with Deployment Commands

These scripts are designed to be called by `/deploy-to-stage` and `/deploy-to-prod` to reduce token overhead:

### Staging Deployment Flow
```bash
# Load configuration (with auto-detection)
source ~/.claude/scripts/get-deployment-config.sh

# Validate state
VALIDATION=$(~/.claude/scripts/validate-git-state.sh --dev-branch "$DEV_BRANCH" --staging-branch "$STAGING_BRANCH")
VALID=$(echo "$VALIDATION" | jq -r '.valid')

# Analyze risks
RISK=$(~/.claude/scripts/analyze-deployment-risk.sh "$DEV_BRANCH" "$STAGING_BRANCH")
RISK_SCORE=$(echo "$RISK" | jq -r '.risk_score')

# Perform squash merge (NEW: using git-merge.sh)
MERGE=$(~/.claude/scripts/git-merge.sh "$DEV_BRANCH" "$STAGING_BRANCH" --squash)
MERGE_SUCCESS=$(echo "$MERGE" | jq -r '.success')

# Monitor pipeline (auto-detects platform)
PIPELINE=$(~/.claude/scripts/monitor-pipeline.sh "$CI_PLATFORM" "$STAGING_BRANCH")
PIPELINE_STATUS=$(echo "$PIPELINE" | jq -r '.status')

# Check health (gracefully skips if URL not configured)
HEALTH=$(~/.claude/scripts/check-health.sh "$STAGING_URL" "$HEALTH_CHECK_PATH")
HEALTH_STATUS=$(echo "$HEALTH" | jq -r '.status')

# Run E2E tests
E2E=$(~/.claude/scripts/run-e2e-tests.sh "$E2E_COMMAND" "$STAGING_URL")
```

### Production Deployment Flow
```bash
# Load configuration
source ~/.claude/scripts/get-deployment-config.sh

# Perform regular merge (NEW: preserves history)
MERGE=$(~/.claude/scripts/git-merge.sh "$STAGING_BRANCH" "$PRODUCTION_BRANCH")

# Monitor pipeline
PIPELINE=$(~/.claude/scripts/monitor-pipeline.sh "$CI_PLATFORM" "$PRODUCTION_BRANCH")

# If pipeline fails, rollback (NEW: using deployment-rollback.sh)
if [[ "$PIPELINE_STATUS" != "success" ]]; then
  ROLLBACK=$(~/.claude/scripts/deployment-rollback.sh "$PRODUCTION_BRANCH" "pipeline failure")
fi

# Run smoke tests (NEW: quick production verification)
SMOKE=$(~/.claude/scripts/smoke-tests.sh "$PRODUCTION_URL" --critical-only)
```

## Benefits

1. **Reduced Token Usage** - Complex logic in shell, Claude only orchestrates
2. **Reusability** - Scripts can be called from other commands/tools
3. **Standardization** - JSON output makes parsing consistent
4. **Debugging** - Can run individual scripts to diagnose issues
5. **Testability** - Each script can be tested independently
6. **Offline Capable** - Scripts work without AI/Claude when appropriate
7. **Intelligent Defaults** ⭐ NEW - Works without PROJECT.yaml using auto-detection
8. **Graceful Degradation** ⭐ NEW - Skips optional checks (health, version) when not configured

## Requirements

- Bash 4.0+
- `git`, `curl`, `jq`
- For GitHub: `gh` CLI installed and authenticated
- For GitLab: `~/.gitlab-token` with API token
- For deployment config: `yq` for YAML parsing

## Error Handling

All scripts:
- Use `set -euo pipefail` for safety
- Return non-zero exit codes on failure
- Output structured JSON for programmatic parsing
- Handle edge cases gracefully

Example error handling:
```bash
RESULT=$(./scripts/check-health.sh "$URL" || echo '{"error": "failed"}')
if echo "$RESULT" | jq -e '.error' >/dev/null 2>&1; then
  echo "Health check failed"
  exit 1
fi
```

## What's New in v2.0

### Critical Fixes
1. **Production Deployment Now Works Correctly**
   - Fixed: `/deploy-to-prod` now deploys to production branch (not staging)
   - Fixed: Production uses production URL for health checks (not staging URL)
   - Fixed: Branch sync direction corrected (production → staging/dev, not staging → everywhere)

2. **Centralized Git Operations**
   - NEW: `git-merge.sh` - Handles both squash and regular merges
   - NEW: `deployment-rollback.sh` - Proper rollback mechanism
   - Commands no longer duplicate git logic inline

### Intelligent Defaults
3. **Works Without PROJECT.yaml**
   - Auto-detects branches from git repository
   - Auto-detects CI platform from git remote URL
   - Clear warnings guide users to proper configuration
   - Suggests running `/project-config init`

4. **Graceful Degradation**
   - Health checks return "skipped" status when URL not configured
   - Version checks return "unknown" status when URL not configured
   - Deployments can proceed without optional verification

### New Scripts
5. **Production Smoke Tests** (`smoke-tests.sh`)
   - Critical: health, version, root, response time
   - Extended: docs, metrics, HTTPS, security headers, CORS

6. **Branch Validation** (`git-branch-check.sh`)
   - Check if branch exists (local/remote)
   - Check working directory is clean
   - Check branch is synced with remote

### Migration Guide

#### From squash-merge-branches.sh to git-merge.sh
**Before:**
```bash
./scripts/squash-merge-branches.sh "$DEV_BRANCH" "$STAGING_BRANCH"
```

**After:**
```bash
./scripts/git-merge.sh "$DEV_BRANCH" "$STAGING_BRANCH" --squash
```

#### From Inline Git Operations
**Before (in commands):**
```bash
git fetch origin "$STAGING_BRANCH"
git checkout "$STAGING_BRANCH"
git merge --squash "origin/$DEV_BRANCH"
git commit -m "message"
git push origin "$STAGING_BRANCH"
```

**After:**
```bash
MERGE=$(~/.claude/scripts/git-merge.sh "$DEV_BRANCH" "$STAGING_BRANCH" --squash)
MERGE_SUCCESS=$(echo "$MERGE" | jq -r '.success')
```

#### From Inline Rollback
**Before (in commands):**
```bash
git revert -n HEAD
git commit -m "revert: rollback due to failure"
git push origin "$BRANCH"
```

**After:**
```bash
ROLLBACK=$(~/.claude/scripts/deployment-rollback.sh "$BRANCH" "failure reason")
ROLLBACK_SUCCESS=$(echo "$ROLLBACK" | jq -r '.success')
```

#### Production Deployment Branch
**Before (BROKEN):**
```bash
# This was deploying to staging branch!
git push origin "$STAGING_BRANCH"
```

**After (FIXED):**
```bash
# Now correctly deploys to production branch
git push origin "$PRODUCTION_BRANCH"
```

### Backward Compatibility

**No Breaking Changes:**
- Projects with only staging config continue to work
- Production defaults to "main" branch if not specified
- Missing URLs skip health checks with warnings
- All existing scripts maintain same interface

**Deprecated (but still functional):**
- `squash-merge-branches.sh` - Use `git-merge.sh` instead
- Inline git operations in commands - Use centralized scripts
- Combined staging/production URLs - Use separate URLs
- Hard-coded branch names - Use config or detection

### Troubleshooting

#### "⚠️ PROJECT.yaml not found"
This is a **warning**, not an error. Scripts will auto-detect configuration.
- **To continue with defaults**: No action needed, deployment proceeds
- **To create proper config**: Run `/project-config init`

#### Health checks skipped
If you see "⚠️ No URL provided - skipping health check":
- Add `deployment.staging.url` or `deployment.production.url` to PROJECT.yaml
- Or accept that health checks are skipped (deployment continues)

#### Version verification unknown
If you see "⚠️ No URL provided - skipping version verification":
- Add deployment URLs to PROJECT.yaml
- Or accept that version verification is skipped (deployment continues)

#### Branch not detected correctly
If auto-detection picks wrong branch:
- Add explicit branch names to PROJECT.yaml under `ci.branches`
- Or pass branch names explicitly to scripts

#### CI platform not detected correctly
If auto-detection picks wrong platform:
- Add `ci.platform: "github"` or `"gitlab"` to PROJECT.yaml
- Or pass platform explicitly to `monitor-pipeline.sh`

### Testing Your Deployment Scripts

```bash
# Test configuration loading (should work without PROJECT.yaml)
source ~/.claude/scripts/get-deployment-config.sh
echo "Dev: $DEV_BRANCH, Staging: $STAGING_BRANCH, Prod: $PRODUCTION_BRANCH"

# Test git merge (dry run by checking branches first)
~/.claude/scripts/git-branch-check.sh --branch "$DEV_BRANCH"

# Test health check (should skip gracefully if no URL)
~/.claude/scripts/check-health.sh "" "/health"  # Empty URL
# Expected: status: "skipped", exit code 0

# Test smoke tests
~/.claude/scripts/smoke-tests.sh "https://example.com" --critical-only

# Test branch validation
~/.claude/scripts/git-branch-check.sh --branch "main" --exists --synced
```
