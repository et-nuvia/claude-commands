#!/usr/bin/env bash
# pipeline-audit.sh - Deterministic CI/CD pipeline implementation audit
# Usage: ./pipeline-audit.sh --stage <stage> [--quick]
# Stages: scan, score, report, all (default)
#
# Reads configuration from PROJECT.yaml (no environment variables).
# Outputs structured JSON to stdout, status messages to stderr.

set -euo pipefail

# Source shared libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"
source "${LIB_DIR}/common.sh"
source "${LIB_DIR}/project-config.sh"
source "${LIB_DIR}/yaml.sh"
source "${LIB_DIR}/output-framework.sh"  # log_json: TOON for AI callers

# Configuration
STAGE="all"
QUICK_MODE=false
OUTPUT_FILE="/tmp/pipeline-audit-result.json"
EMIT_SPEC=false

# ---------------------------------------------------------------------------
# Scoring weights — SINGLE SOURCE OF TRUTH
#
# These drive both the overall-score arithmetic below AND the scoring tables
# published in the wiki and ~/.claude/docs/reference/pipelines.md, which are
# generated from `--emit-spec` by ~/.claude/scripts/audit-spec-sync.sh.
# Change a weight here and regenerate; never hand-edit the markdown tables.
#
# Each variant must total 100. `blue_green` applies when
# PROJECT.yaml sets deployment.strategy: blue-green — the Blue-Green category
# takes 8% out of the project-standards pool, leaving industry weights intact.
# ---------------------------------------------------------------------------
# Project Standards (60%)          default  blue-green
W_BUILD_DEFAULT=12;         W_BUILD_BG=10
W_SAFETY_DEFAULT=12;        W_SAFETY_BG=10
W_SECRETS_DEFAULT=10;       W_SECRETS_BG=10
W_ZERO_DOWNTIME_DEFAULT=10; W_ZERO_DOWNTIME_BG=8
W_BRANCH_DEFAULT=8;         W_BRANCH_BG=8
W_VERSION_DEFAULT=8;        W_VERSION_BG=6
W_BLUE_GREEN_DEFAULT=0;     W_BLUE_GREEN_BG=8
# Industry Standards (40%) — identical across variants
W_SUPPLY_CHAIN_DEFAULT=12;  W_SUPPLY_CHAIN_BG=12
W_SECURITY_SCAN_DEFAULT=12; W_SECURITY_SCAN_BG=12
W_DORA_DEFAULT=8;           W_DORA_BG=8
W_HARDENING_DEFAULT=8;      W_HARDENING_BG=8

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --stage)
      STAGE="$2"
      shift 2
      ;;
    --quick)
      QUICK_MODE=true
      shift
      ;;
    --output)
      OUTPUT_FILE="$2"
      shift 2
      ;;
    --emit-spec)
      EMIT_SPEC=true
      shift
      ;;
    *)
      print_error "Unknown argument: $1"
      echo "Usage: pipeline-audit.sh --stage <scan|score|report|all> [--quick] [--output FILE] [--emit-spec]"
      exit 2
      ;;
  esac
done

# Emit the machine-readable scoring spec. Pure metadata, so it runs before the
# PROJECT.yaml requirement — the docs generator calls this outside any project.
emit_spec() {
  cat <<SPEC
{
  "spec_version": 1,
  "audit": "pipeline",
  "command": "/pipeline-audit",
  "generated_by": "pipeline-audit.sh --emit-spec",
  "variants": [
    { "id": "default", "label": "Default", "condition": "no blue-green deployment" },
    { "id": "blue_green", "label": "With Blue-Green", "condition": "PROJECT.yaml \`deployment.strategy: blue-green\`" }
  ],
  "groups": [
    { "id": "project", "label": "Project Standards", "total": 60 },
    { "id": "industry", "label": "Industry Standards", "total": 40 }
  ],
  "categories": [
    { "id": "build", "group": "project", "label": "Build & Deploy", "framework": "",
      "checks": "Build once/promote, RUN_TESTS, security scan, tag rotation + ordering + depth, image tag format, cleanup as dedicated job, feature-branch deploys, manual trigger",
      "weights": { "default": ${W_BUILD_DEFAULT}, "blue_green": ${W_BUILD_BG} } },
    { "id": "safety", "group": "project", "label": "Safety & Rollback", "framework": "",
      "checks": "Smoke test tiers, E2E in staging only, auto-rollback on smoke failure, rollback mechanics, no DNS flips, release notes + sync-back, conditional cleanup, notifications, reusable workflows",
      "weights": { "default": ${W_SAFETY_DEFAULT}, "blue_green": ${W_SAFETY_BG} } },
    { "id": "secrets", "group": "project", "label": "Secrets Management", "framework": "",
      "checks": "No hardcoded secrets, CI variables defined per platform, OIDC (GitHub), secrets manager at runtime, minimal .env",
      "weights": { "default": ${W_SECRETS_DEFAULT}, "blue_green": ${W_SECRETS_BG} } },
    { "id": "zero_downtime", "group": "project", "label": "Zero-Downtime", "framework": "",
      "checks": "Rolling recreate, compose change detection + clean-recreate, deploy phase ordering, health polling params, no arbitrary sleeps, backward-compatible migrations",
      "weights": { "default": ${W_ZERO_DOWNTIME_DEFAULT}, "blue_green": ${W_ZERO_DOWNTIME_BG} } },
    { "id": "branch", "group": "project", "label": "Branch Strategy", "framework": "",
      "checks": "Pipeline files exist, branches from PROJECT.yaml (not hardcoded), lint + test stages, merge strategy per branch",
      "weights": { "default": ${W_BRANCH_DEFAULT}, "blue_green": ${W_BRANCH_BG} } },
    { "id": "version", "group": "project", "label": "Version Management", "framework": "",
      "checks": "Git tag versioning, conventional commits, tag on production success only, version calculated once, manual override",
      "weights": { "default": ${W_VERSION_DEFAULT}, "blue_green": ${W_VERSION_BG} } },
    { "id": "blue_green", "group": "project", "label": "Blue-Green Deploy", "framework": "",
      "checks": "Active color resolved from DNS, per-color instance IDs + domains, manual color override, instance startup check, rollback targets correct color, manual cutover discipline, strategy validation",
      "weights": { "default": ${W_BLUE_GREEN_DEFAULT}, "blue_green": ${W_BLUE_GREEN_BG} } },
    { "id": "supply_chain", "group": "industry", "label": "Supply Chain Security", "framework": "SLSA",
      "checks": "Pinned actions/images, SBOM, artifact signing, build provenance, dependency lockfiles",
      "weights": { "default": ${W_SUPPLY_CHAIN_DEFAULT}, "blue_green": ${W_SUPPLY_CHAIN_BG} } },
    { "id": "security_scan", "group": "industry", "label": "Security Scanning", "framework": "OWASP DSOMM",
      "checks": "SAST, dependency scanning (SCA), secret detection, container image scanning, DAST, license compliance",
      "weights": { "default": ${W_SECURITY_SCAN_DEFAULT}, "blue_green": ${W_SECURITY_SCAN_BG} } },
    { "id": "dora", "group": "industry", "label": "DORA Readiness", "framework": "DORA",
      "checks": "Auto-deploy frequency, lead time metadata, change failure detection, MTTR support",
      "weights": { "default": ${W_DORA_DEFAULT}, "blue_green": ${W_DORA_BG} } },
    { "id": "hardening", "group": "industry", "label": "Pipeline Hardening", "framework": "CIS",
      "checks": "Least-privilege permissions, job timeouts, concurrency controls, artifact retention, PR/MR gates",
      "weights": { "default": ${W_HARDENING_DEFAULT}, "blue_green": ${W_HARDENING_BG} } }
  ],
  "rating_scale": [
    { "min": 90, "rating": "EXCELLENT", "action": "Production ready, industry best practices" },
    { "min": 70, "rating": "GOOD", "action": "Minor improvements, schedule within 2 weeks" },
    { "min": 50, "rating": "FAIR", "action": "Several issues, fix before next release" },
    { "min": 0, "rating": "NEEDS WORK", "action": "Blocks deployment" }
  ],
  "maturity_levels": [
    { "level": 4, "name": "Optimized", "min": 85, "characteristics": "Signed artifacts, DAST, full compliance, proactive security" },
    { "level": 3, "name": "Defined", "min": 65, "characteristics": "SBOM, provenance, DORA tracking, hardened pipeline" },
    { "level": 2, "name": "Managed", "min": 40, "characteristics": "Testing, basic scanning, rollback capability" },
    { "level": 1, "name": "Basic", "min": 0, "characteristics": "Automated build/deploy exists" }
  ],
  "maturity_basis": "Average of the four industry category scores",
  "blocking_rule": "Any P0 finding (missing rollback, hardcoded secrets, no test stage, production rebuilds, no SCA, pipeline flips DNS, rotate-tags after build, tag created before deploy succeeds) blocks deployment."
}
SPEC
}

if [[ "$EMIT_SPEC" == "true" ]]; then
  emit_spec
  exit 0
fi

# Require PROJECT.yaml
require_project_config

# Global state
APP_NAME=$(get_app_name)
CI_PLATFORM=$(get_ci_platform)
STAGING_BRANCH=$(get_staging_branch)
PRODUCTION_BRANCH=$(get_production_branch)

# Pipeline files
GITLAB_CI_FILE=".gitlab-ci.yml"
GITHUB_WORKFLOWS_DIR=".github/workflows"

# Scan results
TOTAL_CHECKS=0
PASSED_CHECKS=0
FAILED_CHECKS=0
WARNINGS=0

# Category scores - Project Standards
SCORE_BRANCH=0
SCORE_VERSION=0
SCORE_BUILD=0
SCORE_SECRETS=0
SCORE_ZERO_DOWNTIME=0
SCORE_SAFETY=0
SCORE_BLUE_GREEN=0      # Blue-green deployment (conditional)

# Category scores - Industry Standards
SCORE_SUPPLY_CHAIN=0    # SLSA-inspired
SCORE_SECURITY_SCAN=0   # OWASP DSOMM-inspired
SCORE_DORA_READINESS=0  # DORA metrics readiness
SCORE_HARDENING=0       # CIS benchmark-inspired

# Deployment strategy (read from PROJECT.yaml)
DEPLOY_STRATEGY=""

OVERALL_SCORE=0
MATURITY_LEVEL=""

# Findings
FINDINGS_PASS=""
FINDINGS_FAIL=""
FINDINGS_WARN=""
FINDINGS_SKIP=""

# Detected pipeline files
PIPELINE_FILES=()

# Deploy scripts and Dockerfiles (checked for zero-downtime, secrets, build patterns)
DEPLOY_FILES=()

#============================================================================
# Check Helpers
#============================================================================

record_check() {
  local category="$1"
  local name="$2"
  local result="$3"
  local detail="$4"

  TOTAL_CHECKS=$((TOTAL_CHECKS + 1))

  local entry="${category}|${name}|${result}|${detail}"

  case "$result" in
    pass)
      PASSED_CHECKS=$((PASSED_CHECKS + 1))
      FINDINGS_PASS="${FINDINGS_PASS}${entry}\n"
      print_success "$name" ;;
    fail)
      FAILED_CHECKS=$((FAILED_CHECKS + 1))
      FINDINGS_FAIL="${FINDINGS_FAIL}${entry}\n"
      print_error "$name: $detail" ;;
    warn)
      WARNINGS=$((WARNINGS + 1))
      FINDINGS_WARN="${FINDINGS_WARN}${entry}\n"
      print_warning "$name: $detail" ;;
    skip)
      FINDINGS_SKIP="${FINDINGS_SKIP}${entry}\n"
      print_info "$name: $detail (skipped)" ;;
  esac
}

# Search all pipeline files for a pattern (case insensitive)
pipeline_grep() {
  local pattern="$1"
  for f in "${PIPELINE_FILES[@]}"; do
    grep -ilE "$pattern" "$f" 2>/dev/null && return 0
  done
  return 1
}

# Search all pipeline files and return matching lines
pipeline_grep_lines() {
  local pattern="$1"
  for f in "${PIPELINE_FILES[@]}"; do
    grep -nE "$pattern" "$f" 2>/dev/null || true
  done
}

# Search deploy scripts, Dockerfiles, and entrypoints for a pattern
deploy_grep() {
  local pattern="$1"
  for f in "${DEPLOY_FILES[@]}"; do
    grep -ilE "$pattern" "$f" 2>/dev/null && return 0
  done
  return 1
}

# Search both pipeline files AND deploy files
all_grep() {
  local pattern="$1"
  pipeline_grep "$pattern" >/dev/null 2>&1 && return 0
  deploy_grep "$pattern" >/dev/null 2>&1 && return 0
  return 1
}

#============================================================================
# Stage: Scan - Discover and check pipeline configuration
#============================================================================

scan_stage() {
  print_info "Stage: Scanning pipeline implementation for ${APP_NAME} (${CI_PLATFORM})..."

  # ------------------------------------------------------------------
  # Discover pipeline files
  # ------------------------------------------------------------------
  if [[ "$CI_PLATFORM" == "gitlab" ]]; then
    if [[ -f "$GITLAB_CI_FILE" ]]; then
      PIPELINE_FILES+=("$GITLAB_CI_FILE")
      # Include any local includes
      local includes
      includes=$(yaml_get '.include[].local // ""' "$GITLAB_CI_FILE")
      while IFS= read -r inc; do
        [[ -n "$inc" && -f "$inc" ]] && PIPELINE_FILES+=("$inc")
      done <<< "$includes"
    fi
  elif [[ "$CI_PLATFORM" == "github" ]]; then
    if [[ -d "$GITHUB_WORKFLOWS_DIR" ]]; then
      while IFS= read -r f; do
        [[ -n "$f" ]] && PIPELINE_FILES+=("$f")
      done < <(find "$GITHUB_WORKFLOWS_DIR" -name "*.yml" -o -name "*.yaml" 2>/dev/null | sort)
    fi
  fi

  # Discover deploy scripts, Dockerfiles, and entrypoints
  while IFS= read -r f; do
    [[ -n "$f" ]] && DEPLOY_FILES+=("$f")
  done < <(find scripts/deploy -name "*.sh" 2>/dev/null | sort)
  [[ -f "Dockerfile" ]] && DEPLOY_FILES+=("Dockerfile")
  [[ -f "docker-entrypoint.sh" ]] && DEPLOY_FILES+=("docker-entrypoint.sh")
  [[ -f "docker-compose.yml" ]] && DEPLOY_FILES+=("docker-compose.yml")

  if [[ ${#PIPELINE_FILES[@]} -eq 0 ]]; then
    record_check "branch" "Pipeline files exist" "fail" "No CI/CD pipeline files found"
    print_error "No pipeline files found. Cannot proceed with audit."
    return 1
  fi
  record_check "branch" "Pipeline files exist" "pass" "Found ${#PIPELINE_FILES[@]} pipeline file(s), ${#DEPLOY_FILES[@]} deploy file(s)"

  # ------------------------------------------------------------------
  # Category 1: Branch Strategy (max 15 pts)
  # ------------------------------------------------------------------
  print_info "--- Branch Strategy Checks ---"

  # PROJECT.yaml branch config
  local py_staging py_prod
  py_staging=$(get_config ".ci.branches.staging" "")
  py_prod=$(get_config ".ci.branches.production" "")

  if [[ -n "$py_staging" && "$py_staging" != "null" ]]; then
    record_check "branch" "Staging branch in PROJECT.yaml" "pass" "staging: $py_staging"
  else
    record_check "branch" "Staging branch in PROJECT.yaml" "fail" "No staging branch configured"
  fi

  if [[ -n "$py_prod" && "$py_prod" != "null" ]]; then
    record_check "branch" "Production branch in PROJECT.yaml" "pass" "production: $py_prod"
  else
    record_check "branch" "Production branch in PROJECT.yaml" "fail" "No production branch configured"
  fi

  # Check that pipeline references branches from config (not hardcoded)
  local hardcoded_branches=false
  for f in "${PIPELINE_FILES[@]}"; do
    # Look for hardcoded branch names like 'main', 'master', 'dev' in branch conditions
    if grep -qE "(== \"main\"|== \"master\"|== 'main'|== 'master'|branches:.*main)" "$f" 2>/dev/null; then
      # Check if it's reading from PROJECT.yaml or has dynamic reference
      if ! grep -qE "PROJECT.yaml|STAGING_BRANCH|PRODUCTION_BRANCH|env\." "$f" 2>/dev/null; then
        hardcoded_branches=true
      fi
    fi
  done
  if [[ "$hardcoded_branches" == "true" ]]; then
    record_check "branch" "Branches from config (not hardcoded)" "warn" "Possible hardcoded branch names found"
  else
    record_check "branch" "Branches from config (not hardcoded)" "pass" "Branch names appear configurable"
  fi

  # Stage flow: other branches should only lint+test
  # Staging should have full pipeline
  # Production should promote (no rebuild)
  if pipeline_grep "lint|eslint|ruff|flake8" >/dev/null 2>&1; then
    record_check "branch" "Lint stage exists" "pass" "Lint stage found"
  else
    record_check "branch" "Lint stage exists" "warn" "No lint stage detected"
  fi

  if pipeline_grep "test|pytest|jest|vitest" >/dev/null 2>&1; then
    record_check "branch" "Test stage exists" "pass" "Test stage found"
  else
    record_check "branch" "Test stage exists" "fail" "No test stage detected"
  fi

  # ------------------------------------------------------------------
  # Category 2: Version Management (max 15 pts)
  # ------------------------------------------------------------------
  print_info "--- Version Management Checks ---"

  # Git tags as version source
  if pipeline_grep "git describe|git tag|LATEST_TAG|version.*tag" >/dev/null 2>&1; then
    record_check "version" "Git tag versioning" "pass" "Version derived from git tags"
  elif pipeline_grep "VERSION.*file|cat.*VERSION|version_file" >/dev/null 2>&1; then
    record_check "version" "Git tag versioning" "warn" "Using VERSION file (git tags preferred)"
  else
    record_check "version" "Git tag versioning" "warn" "No clear version strategy detected"
  fi

  # Conventional commits detection
  if pipeline_grep "conventional|feat:|fix:|BREAKING.CHANGE|bump.*type|minor|patch|major" >/dev/null 2>&1; then
    record_check "version" "Conventional commit versioning" "pass" "Commit-based version bumps detected"
  else
    record_check "version" "Conventional commit versioning" "warn" "No conventional commit versioning found"
  fi

  # Git tag creation on production success
  if pipeline_grep "git tag.*v|create.*tag|tag-release|create-git-tag" >/dev/null 2>&1; then
    record_check "version" "Tag on production success" "pass" "Git tag creation found"
  else
    record_check "version" "Tag on production success" "warn" "No automatic git tag creation detected"
  fi

  # ------------------------------------------------------------------
  # Category 3: Build & Deploy (max 20 pts)
  # ------------------------------------------------------------------
  print_info "--- Build & Deploy Checks ---"

  # Build once, deploy many (promote images, no rebuild for prod)
  if pipeline_grep "promote|re-tag|retag|docker tag.*production|push.*production" >/dev/null 2>&1; then
    record_check "build" "Build once, deploy many" "pass" "Image promotion detected (no prod rebuild)"
  else
    # Check if prod also has a docker build step
    if pipeline_grep "docker build.*production|build.*production" >/dev/null 2>&1; then
      record_check "build" "Build once, deploy many" "fail" "Production appears to rebuild (should promote staging)"
    else
      record_check "build" "Build once, deploy many" "warn" "Could not verify image promotion pattern"
    fi
  fi

  # Docker build with tests (check pipeline for build-arg AND Dockerfile for test stage)
  if pipeline_grep "RUN_TESTS.*true|build-arg.*RUN_TESTS" >/dev/null 2>&1; then
    record_check "build" "Tests in Docker build" "pass" "RUN_TESTS=true in pipeline build"
  elif deploy_grep "ARG RUN_TESTS" >/dev/null 2>&1; then
    record_check "build" "Tests in Docker build" "warn" "Dockerfile has RUN_TESTS stage but pipeline doesn't pass RUN_TESTS=true"
  else
    record_check "build" "Tests in Docker build" "warn" "No RUN_TESTS build arg in pipeline or Dockerfile"
  fi

  # Security scanning (Trivy, Snyk, etc.)
  if pipeline_grep "trivy|snyk|grype|security.*scan|vulnerability" >/dev/null 2>&1; then
    record_check "build" "Security scanning" "pass" "Security scan step found"
  else
    record_check "build" "Security scanning" "warn" "No security scanning detected"
  fi

  # Tag rotation for rollback capability
  if pipeline_grep "rotate.*tag|previous-1|staging-previous|production-previous" >/dev/null 2>&1; then
    record_check "build" "Tag rotation" "pass" "Registry tag rotation for rollback"
  else
    record_check "build" "Tag rotation" "warn" "No tag rotation detected (limits rollback)"
  fi

  # Image cleanup
  if pipeline_grep "cleanup|prune|delete.*image|ecr.*delete|untagged" >/dev/null 2>&1; then
    record_check "build" "Image cleanup" "pass" "Registry cleanup step found"
  else
    record_check "build" "Image cleanup" "warn" "No image cleanup detected"
  fi

  # Parallel builds (matrix strategy, parallel jobs, or reusable workflow with matrix)
  if [[ "$CI_PLATFORM" == "github" ]]; then
    local parallel_indicators=0
    local parallel_details=""
    for f in "${PIPELINE_FILES[@]}"; do
      # Matrix strategy for builds (e.g., build multiple services concurrently)
      if grep -qE "matrix:" "$f" 2>/dev/null; then
        # Check if matrix is used in build/lint/test context
        if grep -qE "strategy:" "$f" 2>/dev/null; then
          parallel_indicators=$((parallel_indicators + 1))
          parallel_details="${parallel_details}matrix strategy, "
        fi
      fi
      # Multiple build jobs without sequential needs (parallel by default in GH Actions)
      # Jobs at the same depth with no needs: on each other run in parallel
    done
    # Check fail-fast setting: true (or default) is preferred for build/deploy
    # so failures cancel remaining jobs and you can fix and redeploy faster
    if pipeline_grep "fail-fast.*false" >/dev/null 2>&1; then
      record_check "build" "Fail-fast on build errors" "warn" "fail-fast: false in build pipeline (slows feedback — consider true for deploy pipelines)"
    else
      record_check "build" "Fail-fast on build errors" "pass" "Build uses fail-fast (default or explicit)"
    fi
    # Check for parallel service builds (multiple docker build or build jobs)
    local build_job_count=0
    for f in "${PIPELINE_FILES[@]}"; do
      local _bc=0
      _bc=$(grep -cE "docker build|docker.*buildx|build.*image" "$f" 2>/dev/null) || _bc=0
      build_job_count=$((build_job_count + _bc))
    done
    if [[ $build_job_count -gt 1 ]]; then
      parallel_indicators=$((parallel_indicators + 1))
      parallel_details="${parallel_details}${build_job_count} build steps, "
    fi
    # Verdict
    parallel_details="${parallel_details%, }"
    if [[ $parallel_indicators -ge 2 ]]; then
      record_check "build" "Parallel builds" "pass" "Build parallelism detected (${parallel_details})"
    elif [[ $parallel_indicators -ge 1 ]]; then
      record_check "build" "Parallel builds" "warn" "Some parallelism (${parallel_details}) but could be improved"
    else
      record_check "build" "Parallel builds" "warn" "No build parallelism detected (use matrix strategy or parallel jobs)"
    fi
  elif [[ "$CI_PLATFORM" == "gitlab" ]]; then
    # GitLab: jobs in the same stage run in parallel by default
    # Check for parallel: keyword or multiple jobs in build/test stages
    local gl_parallel=false
    if pipeline_grep "parallel:|parallel :" >/dev/null 2>&1; then
      gl_parallel=true
    fi
    # Count jobs that appear to be builds
    local gl_build_jobs=0
    for f in "${PIPELINE_FILES[@]}"; do
      local _gc=0
      _gc=$(grep -cE "stage:\s*(build|test)" "$f" 2>/dev/null) || _gc=0
      gl_build_jobs=$((gl_build_jobs + _gc))
    done
    if [[ "$gl_parallel" == "true" || $gl_build_jobs -gt 1 ]]; then
      record_check "build" "Parallel builds" "pass" "Build parallelism detected (${gl_build_jobs} build/test jobs)"
    else
      record_check "build" "Parallel builds" "warn" "Limited build parallelism (use same stage or parallel: keyword)"
    fi
  fi

  # Deploy script or deploy step
  if pipeline_grep "deploy|scp.*compose|ssm.*send-command|ansible" >/dev/null 2>&1; then
    record_check "build" "Deploy step exists" "pass" "Deployment step found"
  else
    record_check "build" "Deploy step exists" "fail" "No deployment step found"
  fi

  # ------------------------------------------------------------------
  # Category 4: Secrets Management (max 15 pts)
  # ------------------------------------------------------------------
  print_info "--- Secrets Management Checks ---"

  # Check for hardcoded secrets in pipeline
  local secret_leak=false
  for f in "${PIPELINE_FILES[@]}"; do
    # Look for actual values (not variable references)
    if grep -qE "(password|secret|token|api.key)\s*[:=]\s*['\"][^$]" "$f" 2>/dev/null; then
      secret_leak=true
      record_check "secrets" "No hardcoded secrets ($f)" "fail" "Possible hardcoded secret in pipeline"
    fi
  done
  if [[ "$secret_leak" != "true" ]]; then
    record_check "secrets" "No hardcoded secrets" "pass" "No obvious hardcoded secrets in pipeline files"
  fi

  # CI/CD variables used properly
  if [[ "$CI_PLATFORM" == "github" ]]; then
    if pipeline_grep 'secrets\.|vars\.' >/dev/null 2>&1; then
      record_check "secrets" "CI variables used" "pass" "GitHub secrets/vars referenced"
    else
      record_check "secrets" "CI variables used" "warn" "No GitHub secrets/vars references found"
    fi

    # OIDC authentication (no static credentials)
    if pipeline_grep "aws-actions/configure-aws-credentials|oidc|role-to-assume" >/dev/null 2>&1; then
      record_check "secrets" "OIDC authentication" "pass" "OIDC federation for AWS auth"
    else
      record_check "secrets" "OIDC authentication" "warn" "No OIDC auth detected (may use static credentials)"
    fi
  elif [[ "$CI_PLATFORM" == "gitlab" ]]; then
    if pipeline_grep '\$CI_|REGISTRY_PASSWORD|SSH_KEY' >/dev/null 2>&1; then
      record_check "secrets" "CI variables used" "pass" "GitLab CI variables referenced"
    else
      record_check "secrets" "CI variables used" "warn" "No GitLab CI variable references found"
    fi
  fi

  # Secrets manager integration (may be in pipeline, deploy scripts, or app entrypoint)
  if all_grep "infisical|aws.*secrets.*manager|vault|INFISICAL|SECRET_MANAGER|SecretsManager|secrets\.loader|secrets\.manager" >/dev/null 2>&1; then
    record_check "secrets" "Secrets manager integration" "pass" "Secrets manager integration found"
  else
    record_check "secrets" "Secrets manager integration" "warn" "No secrets manager integration detected"
  fi

  # Minimal .env on deploy (only ENVIRONMENT/REGION)
  local deploy_lines
  deploy_lines=$(pipeline_grep_lines "echo.*ENVIRONMENT|\.env|ENVIRONMENT=")
  if [[ -n "$deploy_lines" ]]; then
    if echo "$deploy_lines" | grep -qE "LOG_LEVEL|DATABASE|API_KEY|PORT=|WORKERS"; then
      record_check "secrets" "Minimal .env on deploy" "fail" "Config values written to .env (should be in secrets manager)"
    else
      record_check "secrets" "Minimal .env on deploy" "pass" "Only environment identifiers in .env"
    fi
  else
    record_check "secrets" "Minimal .env on deploy" "skip" "Could not verify .env contents"
  fi

  # ------------------------------------------------------------------
  # Category 5: Zero-Downtime Deployment (max 15 pts)
  # ------------------------------------------------------------------
  print_info "--- Zero-Downtime Checks ---"

  # Rolling recreate (force-recreate instead of down+up) — check pipeline and deploy scripts
  if all_grep "force-recreate|rolling|up -d" >/dev/null 2>&1; then
    record_check "zero_downtime" "Rolling recreate" "pass" "Uses force-recreate or rolling strategy"
  else
    record_check "zero_downtime" "Rolling recreate" "warn" "No rolling recreate pattern detected"
  fi

  # Compose change detection — check pipeline and deploy scripts
  if all_grep "sha256sum|COMPOSE_CHANGED|compose.*hash|diff.*compose" >/dev/null 2>&1; then
    record_check "zero_downtime" "Compose change detection" "pass" "Detects compose file changes"
  else
    record_check "zero_downtime" "Compose change detection" "warn" "No compose change detection"
  fi

  # Health polling (not sleep) — check pipeline and deploy scripts
  if all_grep "health.*poll|curl.*health|check.*health|health.*check|HEALTH_TIMEOUT" >/dev/null 2>&1; then
    record_check "zero_downtime" "Health polling" "pass" "Health polling after deploy"
  else
    record_check "zero_downtime" "Health polling" "warn" "No health polling detected"
  fi

  # Arbitrary sleep check
  local sleep_lines
  sleep_lines=$(pipeline_grep_lines "sleep [0-9]" | grep -v "# " || echo "")
  if [[ -n "$sleep_lines" ]]; then
    local sleep_count
    sleep_count=$(echo "$sleep_lines" | wc -l | tr -d ' ')
    if [[ $sleep_count -gt 2 ]]; then
      record_check "zero_downtime" "No arbitrary sleeps" "fail" "Found $sleep_count sleep commands (use health polling)"
    else
      record_check "zero_downtime" "No arbitrary sleeps" "warn" "$sleep_count sleep command(s) found"
    fi
  else
    record_check "zero_downtime" "No arbitrary sleeps" "pass" "No arbitrary sleep commands"
  fi

  # Migrations before restart — check pipeline and deploy scripts
  if all_grep "migrat|alembic|prisma.*migrate|knex.*migrate|run-migrations" >/dev/null 2>&1; then
    record_check "zero_downtime" "Migrations supported" "pass" "Migration step found"
  else
    record_check "zero_downtime" "Migrations supported" "skip" "No migration step (may not be needed)"
  fi

  # ------------------------------------------------------------------
  # Category 6: Safety & Rollback (max 20 pts)
  # ------------------------------------------------------------------
  print_info "--- Safety & Rollback Checks ---"

  # Smoke tests
  if pipeline_grep "smoke.test|smoke-test|smoke_test" >/dev/null 2>&1; then
    record_check "safety" "Smoke tests" "pass" "Smoke test step found"
  else
    record_check "safety" "Smoke tests" "warn" "No smoke tests detected"
  fi

  # E2E tests
  if pipeline_grep "e2e|playwright|cypress|selenium|end.to.end" >/dev/null 2>&1; then
    record_check "safety" "E2E tests" "pass" "E2E test step found"
  else
    record_check "safety" "E2E tests" "warn" "No E2E tests detected"
  fi

  # Auto-rollback on failure
  if pipeline_grep "rollback|roll.back|revert|restore.*previous|production-previous" >/dev/null 2>&1; then
    record_check "safety" "Auto-rollback" "pass" "Rollback mechanism found"
  else
    record_check "safety" "Auto-rollback" "warn" "No automatic rollback detected"
  fi

  # Notification step
  if pipeline_grep "notify|slack|email|webhook|summary" >/dev/null 2>&1; then
    record_check "safety" "Notifications" "pass" "Notification/summary step found"
  else
    record_check "safety" "Notifications" "warn" "No notification step detected"
  fi

  # Reusable workflows/templates
  if [[ "$CI_PLATFORM" == "github" ]]; then
    if pipeline_grep "workflow_call|uses:.*\.github/workflows" >/dev/null 2>&1; then
      record_check "safety" "Reusable workflows" "pass" "Reusable workflow pattern found"
    else
      record_check "safety" "Reusable workflows" "warn" "No reusable workflows detected"
    fi
  elif [[ "$CI_PLATFORM" == "gitlab" ]]; then
    if pipeline_grep "include:|template:|extends:" >/dev/null 2>&1; then
      record_check "safety" "Reusable templates" "pass" "GitLab templates/includes found"
    else
      record_check "safety" "Reusable templates" "warn" "No reusable templates detected"
    fi
  fi

  # Manual approval gates for production
  if pipeline_grep "environment.*production|when:.*manual|workflow_dispatch|approval" >/dev/null 2>&1; then
    record_check "safety" "Production safeguards" "pass" "Production deployment safeguards found"
  else
    record_check "safety" "Production safeguards" "warn" "No production deployment safeguards detected"
  fi

  # ------------------------------------------------------------------
  # Category 7: Supply Chain Security - SLSA (max weight)
  # ------------------------------------------------------------------
  print_info "--- Supply Chain Security (SLSA) Checks ---"

  # Pinned action/image versions (SHA not just tags)
  if [[ "$CI_PLATFORM" == "github" ]]; then
    local unpinned_actions=0
    local total_actions=0
    for f in "${PIPELINE_FILES[@]}"; do
      # Count uses: lines (exclude local workflow refs like ./.github/workflows/*)
      local action_lines
      action_lines=$(grep -E "^\s*uses:" "$f" 2>/dev/null | grep -vcE "^\s*uses:\s*\./" 2>/dev/null || true)
      action_lines=${action_lines:-0}
      total_actions=$((total_actions + action_lines))
      # Count unpinned (no @sha256 or @commit-hash pattern), excluding local refs
      local unpinned
      unpinned=$(grep -E "^\s*uses:" "$f" 2>/dev/null | grep -vE "^\s*uses:\s*\./" | grep -vcE "@[a-f0-9]{40}|@sha256:" 2>/dev/null || true)
      unpinned=${unpinned:-0}
      unpinned_actions=$((unpinned_actions + unpinned))
    done
    if [[ $total_actions -gt 0 && $unpinned_actions -eq 0 ]]; then
      record_check "supply_chain" "Pinned action versions" "pass" "All $total_actions actions pinned to SHA"
    elif [[ $total_actions -gt 0 ]]; then
      record_check "supply_chain" "Pinned action versions" "warn" "$unpinned_actions of $total_actions actions not pinned to SHA"
    else
      record_check "supply_chain" "Pinned action versions" "skip" "No actions found"
    fi
  elif [[ "$CI_PLATFORM" == "gitlab" ]]; then
    # Check for pinned image tags (not :latest)
    local latest_images=0
    for f in "${PIPELINE_FILES[@]}"; do
      local _lc=0
      _lc=$(grep -cE "image:.*:latest" "$f" 2>/dev/null) || _lc=0
      latest_images=$((latest_images + _lc))
    done
    if [[ $latest_images -eq 0 ]]; then
      record_check "supply_chain" "Pinned image versions" "pass" "No :latest image tags in pipeline"
    else
      record_check "supply_chain" "Pinned image versions" "warn" "$latest_images image(s) using :latest tag"
    fi
  fi

  # SBOM generation
  if pipeline_grep "sbom|syft|cyclonedx|spdx|software.bill" >/dev/null 2>&1; then
    record_check "supply_chain" "SBOM generation" "pass" "Software Bill of Materials generation found"
  else
    record_check "supply_chain" "SBOM generation" "warn" "No SBOM generation detected (SLSA L2+)"
  fi

  # Image/artifact signing
  if pipeline_grep "cosign|notation|sigstore|sign.*image|image.*sign|attest" >/dev/null 2>&1; then
    record_check "supply_chain" "Artifact signing" "pass" "Image/artifact signing detected"
  else
    record_check "supply_chain" "Artifact signing" "warn" "No artifact signing detected (SLSA L2+)"
  fi

  # Provenance attestation
  if pipeline_grep "provenance|slsa|in-toto|attestation|buildinfo" >/dev/null 2>&1; then
    record_check "supply_chain" "Build provenance" "pass" "Build provenance/attestation found"
  else
    record_check "supply_chain" "Build provenance" "warn" "No build provenance detected (SLSA L3+)"
  fi

  # Dependency lockfiles referenced in build
  if all_grep "lock|\.lock|package-lock|yarn\.lock|uv\.lock|Cargo\.lock|requirements.*\.txt" >/dev/null 2>&1; then
    record_check "supply_chain" "Dependency lockfiles" "pass" "Lockfile references found in build"
  else
    record_check "supply_chain" "Dependency lockfiles" "warn" "No lockfile references in build pipeline"
  fi

  # ------------------------------------------------------------------
  # Category 8: Security Scanning Maturity - OWASP DSOMM
  # ------------------------------------------------------------------
  print_info "--- Security Scanning (DSOMM) Checks ---"

  # SAST (Static Application Security Testing)
  if pipeline_grep "semgrep|codeql|sonar|bandit|brakeman|gosec|eslint-plugin-security|sast" >/dev/null 2>&1; then
    record_check "security_scan" "SAST" "pass" "Static analysis security testing found"
  else
    record_check "security_scan" "SAST" "warn" "No SAST tool detected (DSOMM Level 2+)"
  fi

  # Dependency/SCA scanning (beyond basic Trivy)
  if pipeline_grep "trivy|snyk|grype|dependabot|renovate|dependency.check|audit|safety" >/dev/null 2>&1; then
    record_check "security_scan" "Dependency scanning (SCA)" "pass" "Dependency vulnerability scanning found"
  else
    record_check "security_scan" "Dependency scanning (SCA)" "fail" "No dependency scanning detected"
  fi

  # Secret detection in pipeline
  if pipeline_grep "gitleaks|trufflehog|detect-secrets|secret.*scan|git-secrets" >/dev/null 2>&1; then
    record_check "security_scan" "Secret detection" "pass" "Secret detection scanning found"
  else
    record_check "security_scan" "Secret detection" "warn" "No secret detection scanning in pipeline (DSOMM Level 2+)"
  fi

  # Container image scanning
  if pipeline_grep "trivy.*image|grype.*image|snyk.*container|docker.*scan|container.*scan|image.*scan" >/dev/null 2>&1; then
    record_check "security_scan" "Container image scanning" "pass" "Container image scanning found"
  else
    record_check "security_scan" "Container image scanning" "warn" "No container image scanning detected"
  fi

  # DAST (Dynamic Application Security Testing)
  if pipeline_grep "zap|dast|nuclei|nikto|burp|dynamic.*security" >/dev/null 2>&1; then
    record_check "security_scan" "DAST" "pass" "Dynamic security testing found"
  else
    record_check "security_scan" "DAST" "warn" "No DAST tool detected (DSOMM Level 3+)"
  fi

  # License compliance
  if pipeline_grep "license.*check|license.*scan|licensee|fossa|license-finder|trivy.*license" >/dev/null 2>&1; then
    record_check "security_scan" "License compliance" "pass" "License compliance scanning found"
  else
    record_check "security_scan" "License compliance" "warn" "No license compliance scanning detected"
  fi

  # ------------------------------------------------------------------
  # Category 9: DORA Metrics Readiness
  # ------------------------------------------------------------------
  print_info "--- DORA Metrics Readiness Checks ---"

  # Deployment frequency: auto-deploy on merge (not manual-only)
  local auto_deploy=false
  if pipeline_grep "push.*${STAGING_BRANCH}|on:.*push|${STAGING_BRANCH}.*deploy" >/dev/null 2>&1; then
    auto_deploy=true
  fi
  if [[ "$CI_PLATFORM" == "gitlab" ]]; then
    if pipeline_grep "rules:.*if.*CI_COMMIT_BRANCH" >/dev/null 2>&1; then
      auto_deploy=true
    fi
  fi
  if [[ "$auto_deploy" == "true" ]]; then
    record_check "dora" "Deployment frequency (auto-deploy)" "pass" "Automatic deployment on branch push"
  else
    record_check "dora" "Deployment frequency (auto-deploy)" "warn" "No automatic deployment trigger found"
  fi

  # Lead time: pipeline has build metadata (timestamps, commit SHA, pipeline ID)
  if pipeline_grep "BUILT_AT|BUILD_NUMBER|CI_PIPELINE_ID|GITHUB_RUN_ID|timestamp|GIT_SHA|CI_COMMIT_SHA" >/dev/null 2>&1; then
    record_check "dora" "Lead time tracking (build metadata)" "pass" "Build metadata for lead time calculation"
  else
    record_check "dora" "Lead time tracking (build metadata)" "warn" "No build metadata for lead time tracking"
  fi

  # Change failure rate: rollback + smoke tests = ability to detect and recover
  local cfr_indicators=0
  pipeline_grep "smoke.test|smoke-test" >/dev/null 2>&1 && cfr_indicators=$((cfr_indicators + 1))
  pipeline_grep "rollback|roll.back|revert" >/dev/null 2>&1 && cfr_indicators=$((cfr_indicators + 1))
  pipeline_grep "e2e|playwright|cypress" >/dev/null 2>&1 && cfr_indicators=$((cfr_indicators + 1))
  if [[ $cfr_indicators -ge 2 ]]; then
    record_check "dora" "Change failure rate (detection)" "pass" "Multiple failure detection mechanisms ($cfr_indicators/3)"
  elif [[ $cfr_indicators -ge 1 ]]; then
    record_check "dora" "Change failure rate (detection)" "warn" "Limited failure detection ($cfr_indicators/3 indicators)"
  else
    record_check "dora" "Change failure rate (detection)" "fail" "No failure detection mechanisms"
  fi

  # MTTR: auto-rollback + health polling + notifications = fast recovery
  local mttr_indicators=0
  pipeline_grep "rollback|auto.*rollback|roll.back" >/dev/null 2>&1 && mttr_indicators=$((mttr_indicators + 1))
  all_grep "health.*poll|health.*check|HEALTH_TIMEOUT" >/dev/null 2>&1 && mttr_indicators=$((mttr_indicators + 1))
  pipeline_grep "notify|slack|email|webhook" >/dev/null 2>&1 && mttr_indicators=$((mttr_indicators + 1))
  if [[ $mttr_indicators -ge 2 ]]; then
    record_check "dora" "MTTR support (recovery speed)" "pass" "Fast recovery mechanisms ($mttr_indicators/3)"
  elif [[ $mttr_indicators -ge 1 ]]; then
    record_check "dora" "MTTR support (recovery speed)" "warn" "Limited recovery support ($mttr_indicators/3 indicators)"
  else
    record_check "dora" "MTTR support (recovery speed)" "fail" "No automated recovery mechanisms"
  fi

  # ------------------------------------------------------------------
  # Category 10: Pipeline Hardening - CIS Benchmark
  # ------------------------------------------------------------------
  print_info "--- Pipeline Hardening (CIS) Checks ---"

  # Least-privilege permissions
  if [[ "$CI_PLATFORM" == "github" ]]; then
    local has_permissions=false
    for f in "${PIPELINE_FILES[@]}"; do
      if grep -qE "^permissions:" "$f" 2>/dev/null; then
        has_permissions=true
        break
      fi
    done
    if [[ "$has_permissions" == "true" ]]; then
      record_check "hardening" "Least-privilege permissions" "pass" "Explicit permissions block found"
    else
      record_check "hardening" "Least-privilege permissions" "warn" "No permissions block (defaults to read-write-all)"
    fi
  elif [[ "$CI_PLATFORM" == "gitlab" ]]; then
    # Check for protected variables / restricted runners
    if pipeline_grep "protected.*true|tags:.*protected|only.*protected" >/dev/null 2>&1; then
      record_check "hardening" "Protected pipeline config" "pass" "Protected variables/runners found"
    else
      record_check "hardening" "Protected pipeline config" "warn" "No protected pipeline configuration detected"
    fi
  fi

  # Timeout limits
  if pipeline_grep "timeout|timeout-minutes|time_limit" >/dev/null 2>&1; then
    record_check "hardening" "Job timeouts" "pass" "Timeout limits configured"
  else
    record_check "hardening" "Job timeouts" "warn" "No explicit job timeouts (CIS: limit execution time)"
  fi

  # Concurrency controls (prevent parallel deploys)
  if [[ "$CI_PLATFORM" == "github" ]]; then
    if pipeline_grep "concurrency:" >/dev/null 2>&1; then
      record_check "hardening" "Concurrency controls" "pass" "Concurrency limits configured"
    else
      record_check "hardening" "Concurrency controls" "warn" "No concurrency controls (risk of parallel deploys)"
    fi
  elif [[ "$CI_PLATFORM" == "gitlab" ]]; then
    if pipeline_grep "resource_group:|interruptible:" >/dev/null 2>&1; then
      record_check "hardening" "Concurrency controls" "pass" "Resource groups or interruptible jobs found"
    else
      record_check "hardening" "Concurrency controls" "warn" "No concurrency controls (risk of parallel deploys)"
    fi
  fi

  # Immutable artifacts / cache integrity
  if pipeline_grep "artifacts:|upload-artifact|cache.*key.*hash" >/dev/null 2>&1; then
    record_check "hardening" "Artifact management" "pass" "Pipeline artifacts configured"
  else
    record_check "hardening" "Artifact management" "warn" "No artifact management detected"
  fi

  # Branch protection enforcement (checks if pipeline enforces status checks)
  if [[ "$CI_PLATFORM" == "github" ]]; then
    if pipeline_grep "pull_request|required.*status|check.*suite" >/dev/null 2>&1; then
      record_check "hardening" "PR status checks" "pass" "Pull request checks configured"
    else
      record_check "hardening" "PR status checks" "warn" "No PR status check triggers (CIS: enforce review gates)"
    fi
  elif [[ "$CI_PLATFORM" == "gitlab" ]]; then
    if pipeline_grep "merge_request|only.*merge" >/dev/null 2>&1; then
      record_check "hardening" "MR pipeline triggers" "pass" "Merge request pipeline configured"
    else
      record_check "hardening" "MR pipeline triggers" "warn" "No merge request pipeline triggers"
    fi
  fi

  # ------------------------------------------------------------------
  # Category 11: Branch-Specific Stage Flow
  # ------------------------------------------------------------------
  print_info "--- Branch Stage Flow Checks ---"

  # PR/dev branches: should have lint + test + security, should NOT build/deploy
  if [[ "$CI_PLATFORM" == "github" ]]; then
    local pr_has_lint=false pr_has_test=false pr_has_security=false pr_has_deploy=false
    local pr_parallel=false
    for f in "${PIPELINE_FILES[@]}"; do
      if grep -qE "pull_request" "$f" 2>/dev/null; then
        grep -qE "lint|eslint|ruff|flake8" "$f" 2>/dev/null && pr_has_lint=true
        grep -qE "test|pytest|jest|vitest" "$f" 2>/dev/null && pr_has_test=true
        grep -qE "trivy|snyk|security|grype|semgrep|codeql" "$f" 2>/dev/null && pr_has_security=true
        grep -qE "docker build|docker push|deploy|ssm.*send-command|ecr" "$f" 2>/dev/null && pr_has_deploy=true
        # Check if lint/test/security have no needs: dependency on each other (parallel)
        # If multiple jobs exist without sequential needs chains, they run in parallel
        if grep -qE "strategy:|matrix:" "$f" 2>/dev/null || ! grep -qE "needs:.*\[.*lint.*test\|needs:.*\[.*test.*lint" "$f" 2>/dev/null; then
          pr_parallel=true
        fi
      fi
    done

    # PR has validation stages
    local pr_stages=0
    [[ "$pr_has_lint" == "true" ]] && pr_stages=$((pr_stages + 1))
    [[ "$pr_has_test" == "true" ]] && pr_stages=$((pr_stages + 1))
    [[ "$pr_has_security" == "true" ]] && pr_stages=$((pr_stages + 1))
    if [[ $pr_stages -ge 3 ]]; then
      record_check "branch" "PR has lint+test+security" "pass" "PR workflow has all 3 validation stages"
    elif [[ $pr_stages -ge 2 ]]; then
      record_check "branch" "PR has lint+test+security" "warn" "PR workflow has ${pr_stages}/3 stages (lint=$pr_has_lint test=$pr_has_test security=$pr_has_security)"
    elif [[ $pr_stages -ge 1 ]]; then
      record_check "branch" "PR has lint+test+security" "warn" "PR workflow has only ${pr_stages}/3 stages"
    else
      record_check "branch" "PR has lint+test+security" "fail" "No PR validation workflow found"
    fi

    # PR stages run in parallel
    if [[ $pr_stages -ge 2 && "$pr_parallel" == "true" ]]; then
      record_check "branch" "PR stages run in parallel" "pass" "PR validation stages can run concurrently"
    elif [[ $pr_stages -ge 2 ]]; then
      record_check "branch" "PR stages run in parallel" "warn" "PR stages may run sequentially (lint+test+security can be parallel)"
    else
      record_check "branch" "PR stages run in parallel" "skip" "Not enough PR stages to evaluate parallelism"
    fi

    # PR does not build/deploy
    if [[ "$pr_has_deploy" == "true" ]]; then
      record_check "branch" "PR branches no build/deploy" "warn" "PR workflow may include build/deploy steps (should be lint+test+security only)"
    else
      record_check "branch" "PR branches no build/deploy" "pass" "PR workflows do not include build/deploy steps"
    fi

  elif [[ "$CI_PLATFORM" == "gitlab" ]]; then
    local mr_has_lint=false mr_has_test=false mr_has_security=false mr_has_deploy=false
    for f in "${PIPELINE_FILES[@]}"; do
      if grep -qE "merge_request" "$f" 2>/dev/null; then
        grep -qE "lint|eslint|ruff|flake8" "$f" 2>/dev/null && mr_has_lint=true
        grep -qE "test|pytest|jest|vitest" "$f" 2>/dev/null && mr_has_test=true
        grep -qE "trivy|snyk|security|grype|semgrep" "$f" 2>/dev/null && mr_has_security=true
        grep -qE "deploy|ssh.*deploy|ssm.*send-command" "$f" 2>/dev/null && mr_has_deploy=true
      fi
    done

    local mr_stages=0
    [[ "$mr_has_lint" == "true" ]] && mr_stages=$((mr_stages + 1))
    [[ "$mr_has_test" == "true" ]] && mr_stages=$((mr_stages + 1))
    [[ "$mr_has_security" == "true" ]] && mr_stages=$((mr_stages + 1))
    if [[ $mr_stages -ge 3 ]]; then
      record_check "branch" "MR has lint+test+security" "pass" "MR pipeline has all 3 validation stages"
    elif [[ $mr_stages -ge 2 ]]; then
      record_check "branch" "MR has lint+test+security" "warn" "MR pipeline has ${mr_stages}/3 stages (lint=$mr_has_lint test=$mr_has_test security=$mr_has_security)"
    elif [[ $mr_stages -ge 1 ]]; then
      record_check "branch" "MR has lint+test+security" "warn" "MR pipeline has only ${mr_stages}/3 stages"
    else
      record_check "branch" "MR has lint+test+security" "fail" "No MR validation pipeline found"
    fi

    # GitLab stages in the same stage: block run in parallel by default
    local mr_parallel=false
    for f in "${PIPELINE_FILES[@]}"; do
      if grep -qE "merge_request" "$f" 2>/dev/null; then
        # In GitLab, jobs in the same stage run in parallel by default
        # Check if lint/test/security are in the same stage or have no dependencies
        if grep -qE "^stages:" "$f" 2>/dev/null; then
          mr_parallel=true
        fi
      fi
    done
    if [[ $mr_stages -ge 2 && "$mr_parallel" == "true" ]]; then
      record_check "branch" "MR stages run in parallel" "pass" "MR validation stages can run concurrently"
    elif [[ $mr_stages -ge 2 ]]; then
      record_check "branch" "MR stages run in parallel" "warn" "MR stages may not run in parallel"
    else
      record_check "branch" "MR stages run in parallel" "skip" "Not enough MR stages to evaluate parallelism"
    fi

    if [[ "$mr_has_deploy" == "true" ]]; then
      record_check "branch" "MR branches no build/deploy" "warn" "MR pipeline may include deploy steps (should be lint+test+security only)"
    else
      record_check "branch" "MR branches no build/deploy" "pass" "MR pipelines do not include deploy steps"
    fi
  fi

  # Staging branch should have full pipeline (build + deploy + smoke)
  local staging_has_build=false staging_has_deploy=false staging_has_smoke=false
  for f in "${PIPELINE_FILES[@]}"; do
    if grep -qE "${STAGING_BRANCH}|staging" "$f" 2>/dev/null; then
      grep -qE "docker build|docker push|ecr|build.*image" "$f" 2>/dev/null && staging_has_build=true
      grep -qE "deploy|ssm.*send-command|ssh.*deploy" "$f" 2>/dev/null && staging_has_deploy=true
      grep -qE "smoke.test|smoke-test|smoke_test" "$f" 2>/dev/null && staging_has_smoke=true
    fi
  done
  local staging_stages=0
  [[ "$staging_has_build" == "true" ]] && staging_stages=$((staging_stages + 1))
  [[ "$staging_has_deploy" == "true" ]] && staging_stages=$((staging_stages + 1))
  [[ "$staging_has_smoke" == "true" ]] && staging_stages=$((staging_stages + 1))
  if [[ $staging_stages -ge 3 ]]; then
    record_check "branch" "Staging full pipeline" "pass" "Staging has build + deploy + smoke test"
  elif [[ $staging_stages -ge 2 ]]; then
    record_check "branch" "Staging full pipeline" "warn" "Staging missing some stages (${staging_stages}/3: build+deploy+smoke)"
  else
    record_check "branch" "Staging full pipeline" "warn" "Staging pipeline incomplete (${staging_stages}/3 stages found)"
  fi

  # Production branch should promote (not rebuild)
  local prod_has_rebuild=false prod_has_promote=false
  for f in "${PIPELINE_FILES[@]}"; do
    if grep -qE "${PRODUCTION_BRANCH}|production|master|main" "$f" 2>/dev/null; then
      grep -qE "docker build.*production|build.*production.*image" "$f" 2>/dev/null && prod_has_rebuild=true
      grep -qE "promote|re-tag|retag|docker tag|ecr.*put-image" "$f" 2>/dev/null && prod_has_promote=true
    fi
  done
  if [[ "$prod_has_promote" == "true" && "$prod_has_rebuild" != "true" ]]; then
    record_check "branch" "Production promotes (no rebuild)" "pass" "Production promotes images instead of rebuilding"
  elif [[ "$prod_has_promote" == "true" && "$prod_has_rebuild" == "true" ]]; then
    record_check "branch" "Production promotes (no rebuild)" "warn" "Production has both promote and build patterns"
  elif [[ "$prod_has_rebuild" == "true" ]]; then
    record_check "branch" "Production promotes (no rebuild)" "fail" "Production rebuilds images (should promote from staging)"
  else
    record_check "branch" "Production promotes (no rebuild)" "warn" "Could not verify production promotion pattern"
  fi

  # Merge strategy: promotions must use regular merge (not squash)
  local squash_in_promotion=false
  for f in "${PIPELINE_FILES[@]}" "${DEPLOY_FILES[@]}"; do
    # Look for --squash in deploy-to-stage or staging promotion context
    if echo "$f" | grep -qE "deploy.*stag|stag.*deploy" 2>/dev/null; then
      if grep -qE "\-\-squash" "$f" 2>/dev/null; then
        squash_in_promotion=true
      fi
    fi
  done
  # Also check deploy scripts directly
  if [[ -f "scripts/deploy-to-stage.sh" ]]; then
    if grep -qE "\-\-squash" "scripts/deploy-to-stage.sh" 2>/dev/null; then
      squash_in_promotion=true
    fi
  fi
  if [[ "$squash_in_promotion" == "true" ]]; then
    record_check "branch" "Promotion uses regular merge" "fail" "Squash merge found in staging promotion (SOP requires regular merge)"
  else
    record_check "branch" "Promotion uses regular merge" "pass" "Staging promotion uses regular merge"
  fi

  # Merge strategy: feature→dev should use squash merge
  if all_grep "squash.*merge|merge.*squash|\-\-squash" >/dev/null 2>&1; then
    record_check "branch" "Feature merge uses squash" "pass" "Squash merge found for feature merges"
  else
    record_check "branch" "Feature merge uses squash" "warn" "No squash merge pattern found for feature→dev merges"
  fi

  # Pre-merge verification: rebase + lint + test + build before merge
  local verify_indicators=0
  all_grep "pre.merge.verify|rebase.*merge|lint.*merge|test.*merge" >/dev/null 2>&1 && verify_indicators=$((verify_indicators + 1))
  all_grep "make lint|make test" >/dev/null 2>&1 && verify_indicators=$((verify_indicators + 1))
  all_grep "make build" >/dev/null 2>&1 && verify_indicators=$((verify_indicators + 1))
  if [[ $verify_indicators -ge 2 ]]; then
    record_check "branch" "Pre-merge verification" "pass" "Pre-merge verification steps detected ($verify_indicators/3)"
  elif [[ $verify_indicators -ge 1 ]]; then
    record_check "branch" "Pre-merge verification" "warn" "Partial pre-merge verification ($verify_indicators/3 indicators)"
  else
    record_check "branch" "Pre-merge verification" "warn" "No pre-merge verification detected"
  fi

  # Tags: git tag should only appear in production pipeline
  local tag_in_staging=false
  for f in "${PIPELINE_FILES[@]}"; do
    if echo "$f" | grep -qiE "stag" 2>/dev/null; then
      if grep -qE "git tag|create.*tag|tag-release" "$f" 2>/dev/null; then
        tag_in_staging=true
      fi
    fi
  done
  if [[ "$tag_in_staging" == "true" ]]; then
    record_check "branch" "Tags only on production" "warn" "Git tag commands found in staging pipeline (should be production only)"
  else
    record_check "branch" "Tags only on production" "pass" "Tags created only in production pipeline"
  fi

  # ------------------------------------------------------------------
  # Category 12: Blue-Green Deployment (conditional — strategy=blue-green)
  # ------------------------------------------------------------------
  DEPLOY_STRATEGY=$(get_config ".deployment.strategy" "")

  if [[ "$DEPLOY_STRATEGY" == "blue-green" ]]; then
    print_info "--- Blue-Green Deployment Checks ---"

    # Active color configured in PROJECT.yaml
    local active_color
    active_color=$(get_config ".deployment.active" "")
    if [[ -n "$active_color" && ("$active_color" == "blue" || "$active_color" == "green") ]]; then
      record_check "blue_green" "Active color in PROJECT.yaml" "pass" "Active color: $active_color"
    else
      record_check "blue_green" "Active color in PROJECT.yaml" "fail" "deployment.active not set (must be blue or green)"
    fi

    # Instance IDs for both colors in each environment
    local bg_config_ok=true
    for env in staging production; do
      for color in blue green; do
        local iid
        iid=$(get_config ".deployment.${env}.${color}.instance_id" "")
        if [[ -n "$iid" && "$iid" != "null" ]]; then
          record_check "blue_green" "${env^} ${color} instance ID" "pass" "${env}.${color}.instance_id configured"
        else
          record_check "blue_green" "${env^} ${color} instance ID" "fail" "deployment.${env}.${color}.instance_id missing"
          bg_config_ok=false
        fi
      done
    done

    # Target color resolution in pipeline (resolve active/inactive → instance ID)
    if pipeline_grep "resolve.*target|inactive.*color|active.*color|blue.*green.*resolve|target_color" >/dev/null 2>&1; then
      record_check "blue_green" "Color resolution in pipeline" "pass" "Target color resolution logic found"
    else
      record_check "blue_green" "Color resolution in pipeline" "fail" "No color resolution logic (pipeline must resolve active/inactive to instance)"
    fi

    # Manual color override via workflow_dispatch
    if pipeline_grep "target_color|deploy_color|server.*color" >/dev/null 2>&1; then
      if pipeline_grep "inactive|blue|green" >/dev/null 2>&1; then
        record_check "blue_green" "Manual color override" "pass" "Color override available (inactive/blue/green)"
      else
        record_check "blue_green" "Manual color override" "warn" "Color input found but no inactive/blue/green options"
      fi
    else
      record_check "blue_green" "Manual color override" "warn" "No manual color override input (useful for targeted deploys)"
    fi

    # Ensure instance running before deploy
    if pipeline_grep "ensure.instance|start.instance|instance.*running|ec2.*start|wait.*instance" >/dev/null 2>&1 \
       || all_grep "ensure.instance|start.instance|ec2.*start-instances" >/dev/null 2>&1; then
      record_check "blue_green" "Instance startup before deploy" "pass" "Pre-deploy instance readiness check found"
    else
      record_check "blue_green" "Instance startup before deploy" "warn" "No instance startup check (inactive server may be stopped)"
    fi

    # Color/instance passed to deploy step
    if pipeline_grep "color.*deploy|instance.*deploy|--color|--instance-id|DEPLOYMENT_COLOR|INSTANCE_ID" >/dev/null 2>&1; then
      record_check "blue_green" "Color context passed to deploy" "pass" "Deploy step receives color/instance context"
    else
      record_check "blue_green" "Color context passed to deploy" "fail" "Deploy step does not receive color or instance ID"
    fi

    # Rollback uses resolved instance (not hardcoded)
    if pipeline_grep "rollback|roll.back" >/dev/null 2>&1; then
      if pipeline_grep "rollback.*instance|rollback.*color|resolve.*target.*rollback|needs.*resolve.*target" >/dev/null 2>&1 \
         || pipeline_grep "INSTANCE_ID.*rollback|rollback.*INSTANCE_ID" >/dev/null 2>&1; then
        record_check "blue_green" "Rollback uses resolved instance" "pass" "Rollback targets the same resolved instance"
      else
        # Check if rollback job references resolve-target outputs
        local rollback_uses_target=false
        for f in "${PIPELINE_FILES[@]}"; do
          if grep -qE "rollback" "$f" 2>/dev/null; then
            if grep -qE "resolve-target|needs\..*resolve" "$f" 2>/dev/null; then
              rollback_uses_target=true
            fi
          fi
        done
        if [[ "$rollback_uses_target" == "true" ]]; then
          record_check "blue_green" "Rollback uses resolved instance" "pass" "Rollback references resolve-target outputs"
        else
          record_check "blue_green" "Rollback uses resolved instance" "warn" "Rollback may not target the correct blue/green instance"
        fi
      fi
    else
      record_check "blue_green" "Rollback uses resolved instance" "warn" "No rollback mechanism found"
    fi

    # Strategy validation in pipeline (fail-fast if not blue-green)
    if pipeline_grep "strategy.*blue.green|blue.green.*strategy|expected.*blue.green" >/dev/null 2>&1; then
      record_check "blue_green" "Strategy validation" "pass" "Pipeline validates blue-green strategy from config"
    else
      record_check "blue_green" "Strategy validation" "warn" "Pipeline does not validate deployment strategy from PROJECT.yaml"
    fi
  fi

  # ------------------------------------------------------------------
  # Category 13: Additional Maturity Checks (extracted from gateway pipeline)
  # ------------------------------------------------------------------
  print_info "--- Additional Maturity Checks ---"

  # 13.1 Conventional commits enforced as a PR gate (not just version-bump signal)
  local cc_gate=false
  for f in "${PIPELINE_FILES[@]}"; do
    if grep -qE "pull_request|merge_request" "$f" 2>/dev/null; then
      if grep -qE "commitlint|conventional.*commit|\[a-z\]\+\(\\\\\(|commit.*regex|validate.*commit|lint.*commit" "$f" 2>/dev/null; then
        cc_gate=true
        break
      fi
    fi
  done
  if [[ "$cc_gate" == "true" ]]; then
    record_check "branch" "Conventional commits enforced as PR gate" "pass" "PR workflow validates commit message format"
  else
    record_check "branch" "Conventional commits enforced as PR gate" "warn" "No commit-format enforcement in PR workflow (gateway pattern: regex check on PR commit range)"
  fi

  # 13.2 Aggregate "required status check" job (single check for branch protection)
  local agg_gate=false
  for f in "${PIPELINE_FILES[@]}"; do
    if grep -qE "pull_request|merge_request" "$f" 2>/dev/null; then
      # Look for a job with both `if: always()` and `needs:` referencing >=2 other jobs
      if grep -qE "if:\s*always\(\)" "$f" 2>/dev/null && grep -qE "needs:\s*\[" "$f" 2>/dev/null; then
        agg_gate=true
        break
      fi
    fi
  done
  if [[ "$agg_gate" == "true" ]]; then
    record_check "branch" "Aggregate required-status job" "pass" "PR workflow has aggregator job (single status check for branch protection)"
  else
    record_check "branch" "Aggregate required-status job" "warn" "No aggregator job with 'needs: [...] / if: always()' (branch protection must track each job individually)"
  fi

  # 13.3 Coverage threshold enforcement + coverage artifact upload
  local cov_threshold=false cov_artifact=false
  if all_grep "coverageThreshold|--cov-fail-under|--coverage|coverage:.*threshold|min.*coverage|fail_under" >/dev/null 2>&1; then
    cov_threshold=true
  fi
  if pipeline_grep "upload-artifact.*coverage|coverage.*artifact|artifacts:.*coverage|coverage:\s*$" >/dev/null 2>&1; then
    cov_artifact=true
  fi
  if [[ "$cov_threshold" == "true" && "$cov_artifact" == "true" ]]; then
    record_check "safety" "Coverage threshold + artifact" "pass" "Coverage threshold enforced and coverage artifact uploaded"
  elif [[ "$cov_threshold" == "true" ]]; then
    record_check "safety" "Coverage threshold + artifact" "warn" "Coverage enforced but no coverage artifact upload"
  elif [[ "$cov_artifact" == "true" ]]; then
    record_check "safety" "Coverage threshold + artifact" "warn" "Coverage artifact uploaded but no threshold gate"
  else
    record_check "safety" "Coverage threshold + artifact" "warn" "No coverage threshold gate or artifact upload"
  fi

  # 13.4 OCI image labels for DORA lead-time tracking
  if pipeline_grep "org\.opencontainers\.image|opencontainers/image-spec" >/dev/null 2>&1 \
     || deploy_grep "org\.opencontainers\.image|LABEL\s+org\.opencontainers" >/dev/null 2>&1; then
    record_check "dora" "OCI image labels (lead-time metadata)" "pass" "OCI standard image labels set on build"
  else
    record_check "dora" "OCI image labels (lead-time metadata)" "warn" "No org.opencontainers.image.* labels (best practice: created/version/revision/source)"
  fi

  # 13.5 Lockfile existence assertion (not just reference)
  local lock_assert=false
  for f in "${PIPELINE_FILES[@]}" "${DEPLOY_FILES[@]}"; do
    [[ -f "$f" ]] || continue
    # Look for explicit existence check on lockfiles that fails the build
    if grep -qE "test -f.*lock|\[\[ ! -f.*lock|\[ ! -f.*lock|Verify.*lockfile|lockfile.*required|lockfile.*missing|exit 1.*lock" "$f" 2>/dev/null; then
      lock_assert=true
      break
    fi
  done
  if [[ "$lock_assert" == "true" ]]; then
    record_check "supply_chain" "Lockfile existence assertion" "pass" "Build fails fast if lockfile is missing"
  else
    record_check "supply_chain" "Lockfile existence assertion" "warn" "No explicit lockfile-existence assertion at build time (gateway pattern: 'Verify lockfile present' step)"
  fi

  # 13.6 Ephemeral credential lifecycle for DAST / integration tests
  # Pattern: mint with TTL + ::add-mask:: + revoke in if: always() cleanup
  local ephem_mint=false ephem_mask=false ephem_revoke=false
  if pipeline_grep "mint.*key|create.*api.*key|generate.*token|provision.*credential|TTL|expires_at" >/dev/null 2>&1; then
    ephem_mint=true
  fi
  if pipeline_grep "::add-mask::|add-mask" >/dev/null 2>&1; then
    ephem_mask=true
  fi
  if pipeline_grep "revoke.*key|delete.*key|cleanup.*key|cleanup.*credential|revoke.*token" >/dev/null 2>&1; then
    ephem_revoke=true
  fi
  local ephem_count=0
  [[ "$ephem_mint" == "true" ]] && ephem_count=$((ephem_count + 1))
  [[ "$ephem_mask" == "true" ]] && ephem_count=$((ephem_count + 1))
  [[ "$ephem_revoke" == "true" ]] && ephem_count=$((ephem_count + 1))
  if [[ $ephem_count -ge 3 ]]; then
    record_check "security_scan" "Ephemeral credential lifecycle" "pass" "Mint + mask + revoke pattern found for test credentials"
  elif [[ $ephem_count -ge 1 ]]; then
    record_check "security_scan" "Ephemeral credential lifecycle" "warn" "Partial ephemeral-credential pattern ($ephem_count/3: mint=$ephem_mint mask=$ephem_mask revoke=$ephem_revoke)"
  else
    record_check "security_scan" "Ephemeral credential lifecycle" "skip" "No DAST/integration credentials detected (may not apply)"
  fi

  # 13.7 Release notes artifact + GitHub Release + cross-branch sync
  local rn_artifact=false rn_release=false rn_sync=false
  if pipeline_grep "release.notes|release-notes|RELEASE_NOTES|CHANGELOG" >/dev/null 2>&1; then
    rn_artifact=true
  fi
  if pipeline_grep "gh release create|softprops/action-gh-release|create.*github.*release|releases/v[0-9]" >/dev/null 2>&1; then
    rn_release=true
  fi
  if pipeline_grep "cherry.pick|sync.*branch|sync.*notes.*to|propagate.*release" >/dev/null 2>&1; then
    rn_sync=true
  fi
  local rn_count=0
  [[ "$rn_artifact" == "true" ]] && rn_count=$((rn_count + 1))
  [[ "$rn_release" == "true" ]] && rn_count=$((rn_count + 1))
  [[ "$rn_sync" == "true" ]] && rn_count=$((rn_count + 1))
  if [[ $rn_count -ge 2 ]]; then
    record_check "version" "Release notes pipeline" "pass" "Release notes generated/published ($rn_count/3 indicators)"
  elif [[ $rn_count -ge 1 ]]; then
    record_check "version" "Release notes pipeline" "warn" "Partial release-notes pipeline ($rn_count/3: artifact=$rn_artifact release=$rn_release sync=$rn_sync)"
  else
    record_check "version" "Release notes pipeline" "warn" "No release notes generation / GitHub Release / cross-branch sync detected"
  fi

  # 13.8 Tag rotation guarded against feature-branch builds
  local rotate_guarded=false rotate_found=false
  for f in "${PIPELINE_FILES[@]}"; do
    if grep -qE "rotate.*tag|tag.*rotate|previous.*tag|retag.*previous" "$f" 2>/dev/null; then
      rotate_found=true
      # Look for a guard near the rotate job — feature_branch or is_feature_branch or ref != feature/*
      if grep -qE "is_feature_branch|feature_branch|!=\s*'feature|!=\s*\"feature|not.*feature/" "$f" 2>/dev/null; then
        rotate_guarded=true
        break
      fi
    fi
  done
  if [[ "$rotate_found" == "true" && "$rotate_guarded" == "true" ]]; then
    record_check "build" "Tag rotation guarded against feature branches" "pass" "Tag rotation skipped for feature-branch deploys"
  elif [[ "$rotate_found" == "true" ]]; then
    record_check "build" "Tag rotation guarded against feature branches" "warn" "Tag rotation exists but no feature-branch guard (risk: feature builds pollute rollback chain)"
  else
    record_check "build" "Tag rotation guarded against feature branches" "skip" "No tag rotation present"
  fi
}

#============================================================================
# Stage: Score - Calculate category and overall scores
#============================================================================

score_stage() {
  print_info "Stage: Calculating scores..."

  for category in branch version build secrets zero_downtime safety blue_green supply_chain security_scan dora hardening; do
    local full_pass=0 half_pass=0 total_cat=0

    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      [[ "${line%%|*}" == "$category" ]] && { full_pass=$((full_pass + 1)); total_cat=$((total_cat + 1)); }
    done <<< "$(echo -e "$FINDINGS_PASS")"

    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      [[ "${line%%|*}" == "$category" ]] && { half_pass=$((half_pass + 1)); total_cat=$((total_cat + 1)); }
    done <<< "$(echo -e "$FINDINGS_WARN")"

    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      [[ "${line%%|*}" == "$category" ]] && total_cat=$((total_cat + 1))
    done <<< "$(echo -e "$FINDINGS_FAIL")"

    local score=0
    if [[ $total_cat -gt 0 ]]; then
      score=$(( (full_pass * 2 + half_pass) * 100 / (total_cat * 2) ))
    fi

    case "$category" in
      branch)        SCORE_BRANCH=$score ;;
      version)       SCORE_VERSION=$score ;;
      build)         SCORE_BUILD=$score ;;
      secrets)       SCORE_SECRETS=$score ;;
      zero_downtime) SCORE_ZERO_DOWNTIME=$score ;;
      safety)        SCORE_SAFETY=$score ;;
      supply_chain)  SCORE_SUPPLY_CHAIN=$score ;;
      security_scan) SCORE_SECURITY_SCAN=$score ;;
      dora)          SCORE_DORA_READINESS=$score ;;
      hardening)     SCORE_HARDENING=$score ;;
      blue_green)    SCORE_BLUE_GREEN=$score ;;
    esac
  done

  # Weighted overall score. Weights come from the W_*_DEFAULT / W_*_BG variables
  # declared at the top of this script — the same values `--emit-spec` publishes,
  # so the score and the documented tables cannot drift apart.
  if [[ "$DEPLOY_STRATEGY" == "blue-green" ]]; then
    OVERALL_SCORE=$(( \
      (SCORE_BUILD * W_BUILD_BG + SCORE_SAFETY * W_SAFETY_BG + SCORE_SECRETS * W_SECRETS_BG \
      + SCORE_ZERO_DOWNTIME * W_ZERO_DOWNTIME_BG + SCORE_BRANCH * W_BRANCH_BG \
      + SCORE_VERSION * W_VERSION_BG + SCORE_BLUE_GREEN * W_BLUE_GREEN_BG \
      + SCORE_SUPPLY_CHAIN * W_SUPPLY_CHAIN_BG + SCORE_SECURITY_SCAN * W_SECURITY_SCAN_BG \
      + SCORE_DORA_READINESS * W_DORA_BG + SCORE_HARDENING * W_HARDENING_BG) / 100 ))
  else
    OVERALL_SCORE=$(( \
      (SCORE_BUILD * W_BUILD_DEFAULT + SCORE_SAFETY * W_SAFETY_DEFAULT + SCORE_SECRETS * W_SECRETS_DEFAULT \
      + SCORE_ZERO_DOWNTIME * W_ZERO_DOWNTIME_DEFAULT + SCORE_BRANCH * W_BRANCH_DEFAULT \
      + SCORE_VERSION * W_VERSION_DEFAULT + SCORE_BLUE_GREEN * W_BLUE_GREEN_DEFAULT \
      + SCORE_SUPPLY_CHAIN * W_SUPPLY_CHAIN_DEFAULT + SCORE_SECURITY_SCAN * W_SECURITY_SCAN_DEFAULT \
      + SCORE_DORA_READINESS * W_DORA_DEFAULT + SCORE_HARDENING * W_HARDENING_DEFAULT) / 100 ))
  fi

  # Calculate industry maturity level (based on industry category scores)
  local industry_avg=$(( (SCORE_SUPPLY_CHAIN + SCORE_SECURITY_SCAN + SCORE_DORA_READINESS + SCORE_HARDENING) / 4 ))
  if [[ $industry_avg -ge 85 ]]; then
    MATURITY_LEVEL="Level 4 - Optimized (signed artifacts, DAST, full compliance, proactive)"
  elif [[ $industry_avg -ge 65 ]]; then
    MATURITY_LEVEL="Level 3 - Defined (SBOM, provenance, DORA tracking, hardened)"
  elif [[ $industry_avg -ge 40 ]]; then
    MATURITY_LEVEL="Level 2 - Managed (testing, basic scanning, rollback)"
  else
    MATURITY_LEVEL="Level 1 - Basic (automated build/deploy exists)"
  fi

  print_info "Scores calculated"
  print_info ""
  print_info "  Project Standards:"
  if [[ "$DEPLOY_STRATEGY" == "blue-green" ]]; then
    print_info "    Branch Strategy:    ${SCORE_BRANCH}/100     (weight: ${W_BRANCH_BG}%)"
    print_info "    Version Mgmt:       ${SCORE_VERSION}/100     (weight: ${W_VERSION_BG}%)"
    print_info "    Build & Deploy:     ${SCORE_BUILD}/100     (weight: ${W_BUILD_BG}%)"
    print_info "    Secrets:            ${SCORE_SECRETS}/100     (weight: ${W_SECRETS_BG}%)"
    print_info "    Zero-Downtime:      ${SCORE_ZERO_DOWNTIME}/100     (weight: ${W_ZERO_DOWNTIME_BG}%)"
    print_info "    Safety & Rollback:  ${SCORE_SAFETY}/100     (weight: ${W_SAFETY_BG}%)"
    print_info "    Blue-Green Deploy:  ${SCORE_BLUE_GREEN}/100     (weight: ${W_BLUE_GREEN_BG}%)"
  else
    print_info "    Branch Strategy:    ${SCORE_BRANCH}/100     (weight: ${W_BRANCH_DEFAULT}%)"
    print_info "    Version Mgmt:       ${SCORE_VERSION}/100     (weight: ${W_VERSION_DEFAULT}%)"
    print_info "    Build & Deploy:     ${SCORE_BUILD}/100     (weight: ${W_BUILD_DEFAULT}%)"
    print_info "    Secrets:            ${SCORE_SECRETS}/100     (weight: ${W_SECRETS_DEFAULT}%)"
    print_info "    Zero-Downtime:      ${SCORE_ZERO_DOWNTIME}/100     (weight: ${W_ZERO_DOWNTIME_DEFAULT}%)"
    print_info "    Safety & Rollback:  ${SCORE_SAFETY}/100     (weight: ${W_SAFETY_DEFAULT}%)"
  fi
  print_info ""
  print_info "  Industry Standards:"
  print_info "    Supply Chain (SLSA):     ${SCORE_SUPPLY_CHAIN}/100     (weight: ${W_SUPPLY_CHAIN_DEFAULT}%)"
  print_info "    Security Scanning (DSOMM): ${SCORE_SECURITY_SCAN}/100     (weight: ${W_SECURITY_SCAN_DEFAULT}%)"
  print_info "    DORA Readiness:          ${SCORE_DORA_READINESS}/100     (weight: ${W_DORA_DEFAULT}%)"
  print_info "    Pipeline Hardening (CIS): ${SCORE_HARDENING}/100     (weight: ${W_HARDENING_DEFAULT}%)"
  print_info ""
  print_info "  Maturity: ${MATURITY_LEVEL}"
  print_info "  Overall:  ${OVERALL_SCORE}/100"
}

#============================================================================
# Stage: Report - Output structured JSON
#============================================================================

findings_to_json() {
  local findings="$1"
  local json="["
  local first=true

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    local cat name result detail
    IFS='|' read -r cat name result detail <<< "$line"
    [[ -z "$cat" ]] && continue

    if [[ "$first" == "true" ]]; then
      first=false
    else
      json="${json},"
    fi
    detail="${detail//\"/\\\"}"
    name="${name//\"/\\\"}"
    json="${json}{\"category\":\"${cat}\",\"check\":\"${name}\",\"result\":\"${result}\",\"detail\":\"${detail}\"}"
  done <<< "$(echo -e "$findings")"

  json="${json}]"
  echo "$json"
}

report_stage() {
  print_info "Stage: Generating audit report..."

  local status
  if [[ $OVERALL_SCORE -ge 90 ]]; then
    status="EXCELLENT"
  elif [[ $OVERALL_SCORE -ge 70 ]]; then
    status="GOOD"
  elif [[ $OVERALL_SCORE -ge 50 ]]; then
    status="FAIR"
  else
    status="NEEDS_WORK"
  fi

  local pass_json fail_json warn_json skip_json
  pass_json=$(findings_to_json "$FINDINGS_PASS")
  fail_json=$(findings_to_json "$FINDINGS_FAIL")
  warn_json=$(findings_to_json "$FINDINGS_WARN")
  skip_json=$(findings_to_json "$FINDINGS_SKIP")

  # Build pipeline files list
  local files_json="["
  local first=true
  for f in "${PIPELINE_FILES[@]}"; do
    if [[ "$first" == "true" ]]; then first=false; else files_json="${files_json},"; fi
    files_json="${files_json}\"${f}\""
  done
  files_json="${files_json}]"

  # Publish the weights actually used, so consumers render the real numbers
  # instead of assuming a variant.
  local weight_variant w_branch w_version w_build w_secrets w_zero_downtime
  local w_safety w_blue_green w_supply_chain w_security_scan w_dora w_hardening
  if [[ "$DEPLOY_STRATEGY" == "blue-green" ]]; then
    weight_variant="blue_green"
    w_branch=$W_BRANCH_BG; w_version=$W_VERSION_BG; w_build=$W_BUILD_BG
    w_secrets=$W_SECRETS_BG; w_zero_downtime=$W_ZERO_DOWNTIME_BG
    w_safety=$W_SAFETY_BG; w_blue_green=$W_BLUE_GREEN_BG
    w_supply_chain=$W_SUPPLY_CHAIN_BG; w_security_scan=$W_SECURITY_SCAN_BG
    w_dora=$W_DORA_BG; w_hardening=$W_HARDENING_BG
  else
    weight_variant="default"
    w_branch=$W_BRANCH_DEFAULT; w_version=$W_VERSION_DEFAULT; w_build=$W_BUILD_DEFAULT
    w_secrets=$W_SECRETS_DEFAULT; w_zero_downtime=$W_ZERO_DOWNTIME_DEFAULT
    w_safety=$W_SAFETY_DEFAULT; w_blue_green=$W_BLUE_GREEN_DEFAULT
    w_supply_chain=$W_SUPPLY_CHAIN_DEFAULT; w_security_scan=$W_SECURITY_SCAN_DEFAULT
    w_dora=$W_DORA_DEFAULT; w_hardening=$W_HARDENING_DEFAULT
  fi

  local result
  result=$(cat <<EOF
{
  "audit_type": "pipeline",
  "project": "${APP_NAME}",
  "ci_platform": "${CI_PLATFORM}",
  "timestamp": "$(date -Iseconds)",
  "quick_mode": ${QUICK_MODE},
  "status": "${status}",
  "maturity_level": "${MATURITY_LEVEL}",
  "scores": {
    "overall": ${OVERALL_SCORE},
    "project_standards": {
      "branch_strategy": ${SCORE_BRANCH},
      "version_management": ${SCORE_VERSION},
      "build_deploy": ${SCORE_BUILD},
      "secrets_management": ${SCORE_SECRETS},
      "zero_downtime": ${SCORE_ZERO_DOWNTIME},
      "safety_rollback": ${SCORE_SAFETY},
      "blue_green": ${SCORE_BLUE_GREEN}
    },
    "industry_standards": {
      "supply_chain_slsa": ${SCORE_SUPPLY_CHAIN},
      "security_scanning_dsomm": ${SCORE_SECURITY_SCAN},
      "dora_readiness": ${SCORE_DORA_READINESS},
      "pipeline_hardening_cis": ${SCORE_HARDENING}
    }
  },
  "weights": {
    "variant": "${weight_variant}",
    "branch_strategy": ${w_branch},
    "version_management": ${w_version},
    "build_deploy": ${w_build},
    "secrets_management": ${w_secrets},
    "zero_downtime": ${w_zero_downtime},
    "safety_rollback": ${w_safety},
    "blue_green": ${w_blue_green},
    "supply_chain_slsa": ${w_supply_chain},
    "security_scanning_dsomm": ${w_security_scan},
    "dora_readiness": ${w_dora},
    "pipeline_hardening_cis": ${w_hardening}
  },
  "summary": {
    "total_checks": ${TOTAL_CHECKS},
    "passed": ${PASSED_CHECKS},
    "failed": ${FAILED_CHECKS},
    "warnings": ${WARNINGS}
  },
  "config": {
    "staging_branch": "${STAGING_BRANCH}",
    "production_branch": "${PRODUCTION_BRANCH}",
    "deploy_strategy": "${DEPLOY_STRATEGY}"
  },
  "findings": {
    "pass": ${pass_json},
    "fail": ${fail_json},
    "warn": ${warn_json},
    "skip": ${skip_json}
  },
  "files_scanned": ${files_json}
}
EOF
)

  echo "$result" > "$OUTPUT_FILE"   # file stays JSON for programmatic consumers
  log_json "$result"                # stdout = TOON in AI context, JSON otherwise

  print_info "Report written to: $OUTPUT_FILE"
}

#============================================================================
# Main
#============================================================================

main() {
  case "$STAGE" in
    scan)
      scan_stage
      ;;
    score)
      scan_stage
      score_stage
      ;;
    report)
      scan_stage
      score_stage
      report_stage
      ;;
    all)
      scan_stage
      score_stage
      report_stage
      ;;
    *)
      print_error "Invalid stage: $STAGE"
      echo "Valid stages: scan, score, report, all"
      exit 2
      ;;
  esac
}

main
