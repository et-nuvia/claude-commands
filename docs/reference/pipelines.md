# CI/CD Pipeline Guide

This guide ensures consistent pipeline behavior across GitLab CI (home) and GitHub Actions (work).

## Pipeline Philosophy

### Build Once, Deploy Many

**Never rebuild images between environments.** Images built for staging are promoted (re-tagged) to production.

### Branch Strategy (from PROJECT.yaml)

**Merge strategies**: See [Branch, Merge & Deploy SOP](../workflows/branch-merge-deploy-sop.md) for how code moves between branches (squash at feature→dev, regular merge for promotions).

**Branches are read from PROJECT.yaml**, not hardcoded:

```yaml
# PROJECT.yaml
ci:
  branches:
    staging: staging    # Branch that deploys to staging
    production: production  # Branch that deploys to production
```

| Branch | Actions | Environment |
|--------|---------|-------------|
| Staging branch | Lint, Test, Security, Build, Deploy, Smoke Test, E2E | Staging |
| Production branch | Promote images (no rebuild), Deploy, Smoke Test, Auto-rollback | Production |
| Other | Lint, Unit Tests only | None |

---

## Version Management

### Git Tags as Single Source of Truth

**No VERSION files.** Versions calculated from git tags + commits.

```bash
# Calculate version from git tags
LATEST_TAG=$(git describe --tags --abbrev=0 --match "v*" 2>/dev/null || echo "v0.0.0")
CURRENT_VERSION=${LATEST_TAG#v}

# Calculate next version based on commits
VERSION=$(~/.claude/scripts/version.sh calculate | tail -1)
```

### Conventional Commits

| Commit Type | Version Bump | Example |
|------------|--------------|---------|
| `BREAKING CHANGE:` or `!` | Major | `feat!: redesign API` → 1.0.0 → 2.0.0 |
| `feat:` | Minor | `feat: add OAuth` → 1.0.0 → 1.1.0 |
| `fix:` | Patch | `fix: handle null` → 1.0.0 → 1.0.1 |

**See also**: [Multi-Audience Release Notes Workflow](workflows/release-notes-guide.md) for complete PR template guidelines and release notes generation.

### Workflow

**Staging:**
- Calculate version from tags: `v0.52.3` + `feat:` = `0.53.0`
- Rotate tags: back up current `staging` → `staging-previous-1` (chain of 4)
- Build with VERSION=`0.53.0`
- Tag image: `backend:0.53.0-staging.1234` + `backend:staging`
- Deploy to staging
- **No git tag created**

**Production:**
- Use same version: `0.53.0`
- Promote image: `0.53.0-staging.1234` → `0.53.0`
- Deploy to production
- **On success:** Create git tag `v0.53.0`

---

## Secrets Management

### Infisical Pattern (Home)

**Only this env var allowed in compose/.env (Home/WSL):**
```bash
ENVIRONMENT=staging
```

**That's it. One line. Nothing else.**

**Client secret via Docker secret (tmpfs):**
- Machine identity client secret stored in `/run/secrets/infisical_client_secret`
- Mounted as Docker secret (tmpfs, memory-only)
- Never in environment variables

**Bootstrap credentials in docker-compose.yml (YAML anchor):**
```yaml
# docker-compose.yml - Define once
x-infisical-bootstrap: &infisical-bootstrap
  INFISICAL_URL: "https://secrets.example.com"
  INFISICAL_CLIENT_ID: "abc-123-def"
  INFISICAL_PROJECT_ID: "4fc89a1a..."

services:
  backend:
    environment:
      <<: *infisical-bootstrap  # Bootstrap config as env vars
    secrets:
      - infisical_client_secret  # Only sensitive value

# entrypoint.sh uses environment variables and reads secret
# INFISICAL_URL, INFISICAL_CLIENT_ID, INFISICAL_PROJECT_ID already set
CLIENT_SECRET=$(cat /run/secrets/infisical_client_secret)
```

**Everything else fetched from Infisical:**
- LOG_LEVEL, WORKERS, PORT - in Infisical
- DATABASE_URL, API_KEYS - in Infisical
- All configuration - in Infisical

**docker-compose.yml:**
```yaml
services:
  backend:
    image: registry/backend:0.53.0-staging.1234
    environment:
      - ENVIRONMENT=staging  # ONLY variable - nothing else
    secrets:
      - infisical_client_secret

secrets:
  infisical_client_secret:
    file: ./secrets/infisical_client_secret
```

**No LOG_LEVEL, WORKERS, PORT, REDIS_HOST, or any other config in environment section. All fetched from Infisical.**

### AWS Pattern (Work)

**Only these env vars allowed:**
```bash
ENVIRONMENT=production  # Required
REGION=us-east-1    # Required for work
```

**Nothing else. Two variables total.**

**Secrets and configuration fetched via IAM role** - no credentials needed in environment.

**Everything else from AWS Secrets Manager:**
```python
# config.py - fetch from secrets manager
LOG_LEVEL = secrets.get_secret('backend/log-level')
WORKERS = int(secrets.get_secret('backend/workers'))
PORT = int(secrets.get_secret('backend/port'))
DATABASE_POOL_SIZE = int(secrets.get_secret('backend/pool-size'))
REDIS_HOST = secrets.get_secret('backend/redis-host')
# All config from secrets manager - change without rebuild
```

---

## GitLab CI Pipeline (Complete Example)

```yaml
# .gitlab-ci.yml - Git Tag-Based Versioning with Infisical Secrets

stages:
  - lint
  - test
  - security
  - rotate-tags
  - build
  - deploy
  - smoke-test
  - rollback
  - cleanup
  - e2e-test
  - notify

variables:
  # Registry
  REGISTRY: "docker.example.com"
  REGISTRY_BASE: "${REGISTRY}/${CI_PROJECT_NAME}"
  
  # Image names
  BACKEND_IMAGE: "${REGISTRY_BASE}/backend"
  FRONTEND_IMAGE: "${REGISTRY_BASE}/frontend"
  
  # Version calculated dynamically from git tags
  VERSION: ""
  GIT_SHA: "${CI_COMMIT_SHA}"
  BUILD_NUMBER: "${CI_PIPELINE_ID}"

# =============================================================================
# Calculate Version (from git tags)
# =============================================================================

calculate-version:
  stage: .pre
  image: alpine:3.20
  before_script:
    - apk add --no-cache git bash yq
  script:
    - |
      # Read staging/production branches from PROJECT.yaml
      STAGING_BRANCH=$(yq eval '.ci.branches.staging' PROJECT.yaml)
      PRODUCTION_BRANCH=$(yq eval '.ci.branches.production' PROJECT.yaml)
      
      echo "Staging branch: ${STAGING_BRANCH}"
      echo "Production branch: ${PRODUCTION_BRANCH}"
      
      # Calculate version from git tags
      LATEST_TAG=$(git describe --tags --abbrev=0 --match "v*" 2>/dev/null || echo "v0.0.0")
      CURRENT_VERSION=${LATEST_TAG#v}
      
      # Get commits since last tag
      if [ "$LATEST_TAG" = "v0.0.0" ]; then
        COMMITS=$(git log --pretty=format:"%s")
      else
        COMMITS=$(git log ${LATEST_TAG}..HEAD --pretty=format:"%s")
      fi
      
      # Detect bump type
      if echo "$COMMITS" | grep -qiE "^[^:]+!:|BREAKING CHANGE:"; then
        BUMP="major"
      elif echo "$COMMITS" | grep -qiE "^feat(\(.+\))?:"; then
        BUMP="minor"
      else
        BUMP="patch"
      fi
      
      # Calculate new version
      IFS='.' read -r major minor patch <<< "$CURRENT_VERSION"
      case "$BUMP" in
        major) VERSION="$((major + 1)).0.0" ;;
        minor) VERSION="${major}.$((minor + 1)).0" ;;
        patch) VERSION="${major}.${minor}.$((patch + 1))" ;;
      esac
      
      echo "Current: ${CURRENT_VERSION}, Next: ${VERSION}, Bump: ${BUMP}"
      
      # Export for other jobs
      echo "VERSION=${VERSION}" >> version.env
      echo "STAGING_BRANCH=${STAGING_BRANCH}" >> version.env
      echo "PRODUCTION_BRANCH=${PRODUCTION_BRANCH}" >> version.env
  artifacts:
    reports:
      dotenv: version.env
  rules:
    - when: always

# =============================================================================
# Rotate Tags (staging branch only — backup before build overwrites :staging)
# =============================================================================

rotate-tags:
  stage: rotate-tags
  image: docker:27
  services:
    - docker:27-dind
  needs:
    - calculate-version
  before_script:
    - echo "$REGISTRY_PASSWORD" | docker login -u "$REGISTRY_USER" --password-stdin "$REGISTRY"
  script:
    - |
      echo "Backing up staging tags before build..."
      # Shift chain: staging → staging-previous-1, previous-1 → previous-2, etc.
      for IMAGE in ${BACKEND_IMAGE} ${FRONTEND_IMAGE}; do
        for i in 3 2 1; do
          FROM_TAG="staging-previous-${i}"
          TO_TAG="staging-previous-$((i + 1))"
          docker pull ${IMAGE}:${FROM_TAG} 2>/dev/null && \
            docker tag ${IMAGE}:${FROM_TAG} ${IMAGE}:${TO_TAG} && \
            docker push ${IMAGE}:${TO_TAG} || true
        done
        # Current staging → staging-previous-1
        docker pull ${IMAGE}:staging 2>/dev/null && \
          docker tag ${IMAGE}:staging ${IMAGE}:staging-previous-1 && \
          docker push ${IMAGE}:staging-previous-1 || echo "No existing staging tag (first deploy?)"
      done
      echo "Tag backup complete"
  rules:
    - if: $CI_COMMIT_BRANCH == $STAGING_BRANCH

# =============================================================================
# Build (staging branch only)
# =============================================================================

build:backend:
  stage: build
  image: docker:27
  services:
    - docker:27-dind
  needs:
    - calculate-version
    - rotate-tags
  before_script:
    - echo "$REGISTRY_PASSWORD" | docker login -u "$REGISTRY_USER" --password-stdin "$REGISTRY"
  script:
    - |
      echo "Building backend version ${VERSION}"
      cd backend
      
      # rotate-tags stage already backed up old ':staging' image
      docker build \
        --target prod \
        --build-arg VERSION="${VERSION}" \
        --build-arg GIT_SHA="${GIT_SHA}" \
        --build-arg BUILD_NUMBER="${BUILD_NUMBER}" \
        --build-arg BUILT_AT="$(date -Iseconds)" \
        -t ${BACKEND_IMAGE}:${VERSION}-staging.${BUILD_NUMBER} \
        -t ${BACKEND_IMAGE}:staging \
        .

      docker push ${BACKEND_IMAGE}:${VERSION}-staging.${BUILD_NUMBER}
      docker push ${BACKEND_IMAGE}:staging
  rules:
    - if: $CI_COMMIT_BRANCH == $STAGING_BRANCH

# =============================================================================
# Promote (production branch - re-tag only, no rebuild)
# =============================================================================

promote:images:
  stage: build
  image: docker:27
  services:
    - docker:27-dind
  needs:
    - calculate-version
  before_script:
    - echo "$REGISTRY_PASSWORD" | docker login -u "$REGISTRY_USER" --password-stdin "$REGISTRY"
  script:
    - |
      echo "Promoting version ${VERSION} to production"
      
      for IMAGE in ${BACKEND_IMAGE} ${FRONTEND_IMAGE}; do
        echo "Promoting ${IMAGE}..."
        docker pull ${IMAGE}:staging
        docker tag ${IMAGE}:staging ${IMAGE}:${VERSION}
        docker tag ${IMAGE}:staging ${IMAGE}:production
        docker push ${IMAGE}:${VERSION}
        docker push ${IMAGE}:production
      done
  rules:
    - if: $CI_COMMIT_BRANCH == $PRODUCTION_BRANCH

# =============================================================================
# Deploy (Infisical secrets pattern)
# =============================================================================

deploy:staging:
  stage: deploy
  image: alpine:3.20
  before_script:
    - apk add --no-cache openssh-client
    - mkdir -p ~/.ssh
    - printf '%s' "$SSH_KEY" | base64 -d > ~/.ssh/id_rsa
    - chmod 600 ~/.ssh/id_rsa
    - ssh-keyscan -H ${DEPLOY_HOST} >> ~/.ssh/known_hosts
  needs:
    - calculate-version
    - build:backend
  script:
    - |
      echo "Deploying version ${VERSION} to staging"

      scp docker-compose.yml ${DEPLOY_USER}@${DEPLOY_HOST}:${DEPLOY_PATH}/

      ssh ${DEPLOY_USER}@${DEPLOY_HOST} "
        set -e
        cd ${DEPLOY_PATH}

        # Setup secrets directory
        mkdir -p secrets
        chmod 700 secrets
        echo '${INFISICAL_CLIENT_SECRET_STAGING}' > secrets/infisical_client_secret
        chmod 600 secrets/infisical_client_secret

        # Create .env with ONLY ENVIRONMENT variable
        echo 'ENVIRONMENT=staging' > .env

        # rotate-tags job already backed up old :staging image
        # Build pushed new :staging tag — pull and recreate
        docker compose pull
        docker compose up -d --force-recreate

        echo 'Deployment complete: version ${VERSION}'
      "
  environment:
    name: staging
    url: https://staging.example.com
  rules:
    - if: $CI_COMMIT_BRANCH == $STAGING_BRANCH

# =============================================================================
# Create Git Tag (production only, after successful deployment)
# =============================================================================

create-git-tag:
  stage: notify
  image: alpine:3.20
  before_script:
    - apk add --no-cache git
  needs:
    - calculate-version
    - deploy:production
    # - smoke-test:production  # Uncomment when enabled
  script:
    - |
      echo "Creating git tag v${VERSION}"
      
      # Configure git
      git config user.name "GitLab CI"
      git config user.email "ci@example.com"
      
      # Check if tag exists
      if git rev-parse "v${VERSION}" >/dev/null 2>&1; then
        echo "Tag v${VERSION} already exists, skipping"
        exit 0
      fi
      
      # Create tag
      git tag -a "v${VERSION}" -m "Production release ${VERSION}

Pipeline: ${CI_PIPELINE_URL}
Commit: ${CI_COMMIT_SHA}
Deployed: $(date -Iseconds)"
      
      # Push tag
      git push https://oauth2:${CI_PUSH_TOKEN}@${CI_SERVER_HOST}/${CI_PROJECT_PATH}.git "v${VERSION}"
      
      echo "✓ Created git tag v${VERSION}"
  rules:
    - if: $CI_COMMIT_BRANCH == $PRODUCTION_BRANCH
      when: on_success  # Only if deployment succeeded
```

---

## GitHub Actions Pipeline (Work/macOS)

GitHub Actions workflows use reusable workflows, AWS OIDC authentication, and SSM-based deployment (no SSH keys).

### Workflow Architecture

```
.github/workflows/
├── docker-build.yml        # Reusable: builds 3 images in parallel
├── deploy-staging.yml      # Push to staging branch → build + deploy
└── deploy-production.yml   # Push to master → promote + deploy + release
```

### Reusable Docker Build Workflow

`docker-build.yml` builds frontend, backend, and AI images in parallel using a matrix strategy. Called only by the staging workflow — production promotes existing staging images (no rebuild).

**Key features:**
- Matrix strategy builds 3 services simultaneously
- Docker Buildx with GitHub Actions cache (layer reuse)
- Verifies `package-lock.json` sync for Node services before build
- OIDC role assumption for ECR (no static credentials)
- Conditional push: `--load` for local testing, `--push` for ECR

**Image tagging per environment:**

| Environment | Version String | Example |
|-------------|---------------|---------|
| Production | Clean version | `2.3.0` |
| Staging | `{version}-staging.{timestamp}` | `2.3.0-staging.1709723400` |
| Feature branch | `{version}-{branch}.{timestamp}` | `2.3.0-my-feature.1709723400` |

**Each image gets two tags:**
- Full version string (above)
- Static tag: `staging`, `production`, or `staging-{branch}` for feature branches

### Staging Pipeline

**Trigger**: Push to `staging` branch, or manual `workflow_dispatch` with ref override

```
prepare → rotate-tags → build → deploy → [e2e] → cleanup → summary
```

**Why separate jobs?** `rotate-tags` must complete before `build` starts (backup old `:staging` before build overwrites it). `build` uses a reusable workflow which runs as its own job. `cleanup` and `e2e` run as separate jobs so they can execute in parallel after deploy succeeds without blocking each other. Production uses separate jobs for rollback capability.

**Jobs:**

1. **prepare** — Resolve deploy ref, detect feature branches
   - Feature branches get tag `staging-{branch-name}` (don't overwrite `staging` tag)
   - Normal staging uses `staging` static tag

2. **rotate-tags** — Backup current staging ECR tags (skipped for feature branches)
   - Runs BEFORE build so the old `:staging` image is preserved before build overwrites it
   - Shifts chain: `staging` → `staging-previous-1` → `staging-previous-2` → etc.
   - Uses `ecr_rotate_staging_tags` from `scripts/deploy/lib/ecr.sh`

3. **build** — Calls `docker-build.yml` reusable workflow (or builds directly for single-service projects)
   - Pushes version tag + static tag (`:staging` or `staging-{branch}`)
   - Trivy image scan (warning-only, does not block deploy)

4. **deploy** — Runs `deploy.sh --env staging --tag staging --no-rotate`
   - `--no-rotate` because rotation already done by rotate-tags job
   - Phase 1: Pull images (old containers serving)
   - Phase 1.5: Run migrations
   - Phase 2: Compose change detection → rolling recreate or full restart + health polling
   - **Step: smoke tests** — Runs `smoke-test.sh --env staging` (config-driven from PROJECT.yaml)

5. **e2e** — End-to-end tests against staging (skipped for feature branches)
   - Playwright chromium against staging URL
   - Uploads test artifacts on failure

6. **cleanup** — ECR image cleanup (runs if deploy succeeded, regardless of e2e result)
   - Keeps 25 most recent images per repo
   - Deletes untagged images

7. **summary** — GitHub step summary with deployment metadata, E2E results, and cleanup status

### Production Pipeline

**Trigger**: Push to `master` branch, or manual `workflow_dispatch`

```
version-bump → deploy → smoke-test → [rollback] → cleanup → tag-release → sync-release-notes → summary
```

**Jobs:**

1. **version-bump** — Auto-calculate semantic version from git tags + conventional commits
   - Reads current version from latest `v*` git tag (no VERSION file)
   - Analyzes commits since last tag: `feat:` → minor, `fix:` → patch, `BREAKING CHANGE:` → major
   - Outputs calculated version — no file writes, no commits
   - Git tag created later by `tag-release` job (only after successful deployment)
   - Manual override available: `workflow_dispatch` with `version_bump` input

2. **deploy** — Promotes staging images to production
   - **No rebuild** — re-tags `staging` → `production` in ECR
   - Rotates ECR tags (production → production-previous-1, etc.)
   - Runs `deploy.sh --env production --tag staging --migrate`
   - Rolling recreate + health polling (120s timeout)

3. **smoke-test** — Full 6-stage smoke test (skippable via `workflow_dispatch`)
   - Service health, database, AI/ML, frontend rendering, API endpoints, container status

4. **rollback** — Runs only if deploy succeeded but smoke-test failed
   - Restores `production-previous-1` tag as `production`
   - Redeploys with `--no-rotate --skip-cleanup`
   - Fully automatic — no manual intervention

5. **cleanup** — ECR image cleanup (only if smoke-test passed)

6. **tag-release** — Create git tag + release notes
   - AI-generated release notes via Anthropic Claude API (with markdown fallback)
   - Filters technical commits, writes user-facing summaries
   - Creates annotated git tag `v{VERSION}`
   - Commits release notes to `docs/release_notes/v{VERSION}.md`

7. **sync-release-notes** — Distribute release notes
   - SSM: writes release notes file into running backend container
   - Git: cherry-picks release notes commit to staging and dev branches

8. **summary** — GitHub step summary with deployment metadata table

### Feature Branch Deploys

Feature branches can be deployed to staging without overwriting the main `staging` tag:

```bash
# Manual trigger with ref override
gh workflow run deploy-staging.yml -f deploy_ref=feature/my-branch
```

- Image tagged as `staging-feature-my-branch` (not `staging`)
- Main `staging` tag untouched — next production deploy unaffected
- Useful for QA testing before merge

### SSM Deployment Model

All deployment commands run via AWS Systems Manager Send-Command (no SSH):

```
GitHub Actions → aws ssm send-command → EC2 instance executes bash script
                                       → SSM agent returns stdout/stderr
                 ← poll every 10s ←    ← completion status
```

**Advantages over SSH:**
- No SSH key management or rotation
- Works through private subnets (VPC endpoint)
- Full audit trail in CloudTrail
- IAM-based access control (OIDC from GitHub)
- Works from any CI runner (no network access needed)

**Timeouts:**
- Pull phase: 600s (image downloads)
- Restart phase: 300s (recreate + health polling)
- Smoke tests: 120-300s (basic vs full)
- Migrations: 300s

### AWS OIDC Authentication

GitHub Actions authenticate to AWS using OIDC federation — no static credentials stored:

```yaml
- name: Configure AWS credentials
  uses: aws-actions/configure-aws-credentials@v4
  with:
    role-to-assume: ${{ vars.AWS_ROLE_ARN }}
    aws-region: us-west-1
```

The IAM role trust policy restricts to specific GitHub repository and branches.

---

## Required CI/CD Variables

### GitLab CI

**Registry:**
- `REGISTRY_USER` - Docker registry username
- `REGISTRY_PASSWORD` - Docker registry password

**Deployment:**
- `SSH_KEY` - Base64-encoded SSH private key
- `DEPLOY_HOST` - Deployment server hostname
- `DEPLOY_USER` - SSH user
- `DEPLOY_PATH` - Deployment directory path

**Secrets Manager (Infisical):**
- `INFISICAL_CLIENT_SECRET_STAGING` - Client secret for staging environment (shared by all services)
- `INFISICAL_CLIENT_SECRET_PRODUCTION` - Client secret for production environment (shared by all services)

**Note:** `INFISICAL_URL`, `INFISICAL_CLIENT_ID`, `INFISICAL_PROJECT_ID` are environment variables in `.env` (not CI/CD variables), mapped to Docker secrets

**Git:**
- `CI_PUSH_TOKEN` - Personal access token with write_repository scope

### GitHub Actions

**AWS (repository variables, not secrets):**
- `AWS_ROLE_ARN` - IAM role ARN for OIDC federation (`vars.AWS_ROLE_ARN`)
- `ECR_REGISTRY` - ECR registry URL (`vars.ECR_REGISTRY`)

**Deployment (repository variables):**
- `STAGING_INSTANCE_ID` - EC2 instance ID for staging (`vars.STAGING_INSTANCE_ID`)
- `PRODUCTION_INSTANCE_ID` - EC2 instance ID for production (`vars.PRODUCTION_INSTANCE_ID`)

**Release Notes:**
- `ANTHROPIC_API_KEY` - (Optional) For AI-generated release notes; falls back to markdown if absent

**Git:**
- `GITHUB_TOKEN` - Automatic; used for git tag creation and release notes commits

---

## Key Differences from Old Approach

| Aspect | Old (VERSION file) | New (Git tags) |
|--------|-------------------|----------------|
| **Version source** | VERSION file | Git tags + commits |
| **Staging deploys** | Commit version bump | No extra commits |
| **Production deploys** | Manual git tag | Automatic on success |
| **Failed deploys** | Orphaned versions | No git tags created |
| **Rollback** | Find version, checkout | `git checkout v1.2.3` |
| **Secrets** | May pass as env vars | Infisical/AWS at runtime |
| **Branch config** | Hardcoded `dev`/`prod` | Read from PROJECT.yaml |

---

## Platform Comparison

| Aspect | GitHub Actions (Work) | GitLab CI (Home) |
|--------|----------------------|------------------|
| **Auth to registry** | OIDC → IAM → ECR | Username/password → Harbor |
| **Auth to server** | OIDC → IAM → SSM | SSH key |
| **Deployment method** | AWS SSM Send-Command | SSH + shell commands |
| **Secrets backend** | AWS Secrets Manager | Infisical |
| **Rollback** | ECR tag rotation + auto-rollback | Manual re-deploy |
| **Release notes** | AI-generated (Claude API) | Manual or template |
| **Reusable workflows** | `workflow_call` | `include: template` |
| **Build cache** | GitHub Actions cache | Docker layer cache (DinD) |

---

## Zero-Downtime Deployment

Production deployments should minimize or eliminate downtime. The patterns below reduce per-service downtime from ~30-40 seconds (full stop/start) to ~3-5 seconds (rolling recreate) with no moment where all services are offline simultaneously.

### Strategy: Rolling Recreate

Instead of `docker compose down` followed by `docker compose up`, use a single command:

```bash
docker compose --profile ${ENVIRONMENT} up -d --force-recreate --quiet-pull
```

Docker Compose stops and restarts each service in dependency order. Infrastructure services (MySQL, Redis) stay running because their images haven't changed. Per-service gap is ~3-5 seconds (stop old container → start new container), but services are never all down at once.

**When to use rolling recreate** (compose file unchanged — ~95% of deploys):
- Same services, same networks, same volumes
- Only image tags changed (new code)

**When to fall back to full restart** (compose file changed — ~5% of deploys):
- Services added, removed, or renamed
- Network or volume configuration changed
- Use old compose to `down` (catches removed services), then new compose to `up`

### Detecting Compose Changes

Before any containers restart, compare the deployed compose file with the incoming one. Two patterns depending on deployment method:

**SSH-based deploys** (new compose file copied via `scp`):
```bash
# Hash existing before scp overwrites it
EXISTING_HASH=$(sha256sum docker-compose.yml | awk '{print $1}')
scp docker-compose.yml ${DEPLOY_USER}@${DEPLOY_HOST}:${DEPLOY_PATH}/docker-compose.yml.new
NEW_HASH=$(sha256sum docker-compose.yml.new | awk '{print $1}')

if [[ "$EXISTING_HASH" == "$NEW_HASH" ]]; then
  COMPOSE_CHANGED=false
  rm -f docker-compose.yml.new
else
  COMPOSE_CHANGED=true
  mv -f docker-compose.yml.new docker-compose.yml
fi
```

**SSM/Docker-image-based deploys** (compose file baked into image or already on server):
```bash
# Hash existing compose file before pull/recreate
EXISTING_HASH=$(sha256sum docker-compose.yml | awk '{print $1}')

# ... pull images, run migrations ...

# Hash again after any updates
NEW_HASH=$(sha256sum docker-compose.yml | awk '{print $1}')
if [[ "$EXISTING_HASH" != "$NEW_HASH" ]]; then
  COMPOSE_CHANGED=true
else
  COMPOSE_CHANGED=false
fi
```

The `COMPOSE_CHANGED` variable controls Phase 2 behavior: rolling recreate vs full restart.

### Deploy Phases

A zero-downtime deploy has three phases with old containers serving traffic as long as possible:

```
Phase 1: Pull images (old containers still serving traffic)
  ├── Login to registry
  ├── Prune unused images
  ├── Compare compose files (detect changes)
  ├── Pull new images: docker compose pull --quiet
  └── If compose changed: swap file, pull again for new services

Phase 1.5: Migrations (optional, old containers still serving)
  ├── Run migrations in temporary container
  └── Must be backward-compatible with running code

Phase 2: Recreate + health polling
  ├── If compose unchanged: docker compose up -d --force-recreate
  ├── If compose changed: down (old compose) → up (new compose)
  └── Poll health endpoints until all services respond (max 120s)
```

### Health Polling (Replaces sleep)

Never use `sleep N` after starting containers. Poll health endpoints instead — this gives deterministic confirmation and fails fast on errors:

```bash
HEALTH_TIMEOUT=120
HEALTH_INTERVAL=5
ELAPSED=0

while [[ $ELAPSED -lt $HEALTH_TIMEOUT ]]; do
  BACKEND_OK=false
  FRONTEND_OK=false
  AI_OK=false

  curl -fsS --max-time 5 http://127.0.0.1:3001/api/v1/health >/dev/null 2>&1 && BACKEND_OK=true
  curl -fsS --max-time 5 http://127.0.0.1:3000/ >/dev/null 2>&1 && FRONTEND_OK=true
  curl -fsS --max-time 5 http://127.0.0.1:5000/health >/dev/null 2>&1 && AI_OK=true

  if [[ "$BACKEND_OK" == "true" && "$FRONTEND_OK" == "true" && "$AI_OK" == "true" ]]; then
    echo "All services healthy after ${ELAPSED}s"
    break
  fi

  # Log per-service status each interval
  echo "[${ELAPSED}s] backend=$BACKEND_OK frontend=$FRONTEND_OK ai=$AI_OK"
  sleep $HEALTH_INTERVAL
  ELAPSED=$(( ELAPSED + HEALTH_INTERVAL ))
done

if [[ $ELAPSED -ge $HEALTH_TIMEOUT ]]; then
  echo "ERROR: Services did not become healthy within ${HEALTH_TIMEOUT}s"
  docker compose ps
  docker compose logs --tail=80
  exit 1  # Triggers rollback in CI
fi
```

**Key points:**
- Poll every 5 seconds, max 120 seconds
- Log per-service status each interval for observability
- On timeout: dump container status and logs, then `exit 1` (triggers rollback)
- Adapts to actual startup time rather than worst-case sleep

### Healthcheck Tuning

Tighter healthcheck intervals let Docker Compose detect readiness faster during rolling recreate. Tune based on actual service startup characteristics:

```yaml
# Frontend (Next.js) — starts fast, needs brief buffer for secret fetch
healthcheck:
  test: ["CMD", "node", "/app/healthcheck.js"]
  interval: 10s      # Check frequently (not 30s default)
  timeout: 5s        # Fail fast on unresponsive
  retries: 5         # More retries at shorter intervals
  start_period: 15s  # Buffer for entrypoint secret injection

# Backend (NestJS) — slower cold start, DB connection
healthcheck:
  test: ["CMD", "node", "/app/healthcheck.js"]
  interval: 10s
  timeout: 5s
  retries: 5
  start_period: 40s  # NestJS cold start ~15-20s + secrets ~3-5s

# AI Service (FastAPI) — fast startup
healthcheck:
  test: ["CMD", "python", "/app/healthcheck.py"]
  interval: 10s
  timeout: 5s
  retries: 5
  start_period: 20s  # FastAPI starts in ~3-5s + secrets
```

**Guidelines:**
- `interval`: 10s for all app services (faster detection without excessive polling)
- `timeout`: 5s (fail fast — if a service can't respond in 5s, it's not ready)
- `retries`: 5 (more attempts compensate for shorter intervals)
- `start_period`: Match actual startup time + small buffer — measure with `docker compose logs`
- Leave infrastructure services (MySQL, Redis) unchanged — they persist across deploys

### Smoke Tests

Use two tiers of smoke tests. Since the deploy script already confirms health via polling, smoke tests can reduce their stabilization sleeps:

**Basic smoke test** (staging — fast feedback):
```bash
sleep 2  # Brief pause, deploy.sh already confirmed health
# 3 health endpoint checks with 5 retries each
check "Backend"  "http://127.0.0.1:3001/api/v1/health"
check "Frontend" "http://127.0.0.1:3000/"
check "AI"       "http://127.0.0.1:5000/health"
```

**Full smoke test** (production — comprehensive):
```bash
sleep 3  # Brief pause, deploy.sh already confirmed health
# [1/6] Service Health — endpoint responses
# [2/6] Database Connectivity — parse backend health JSON
# [3/6] AI/ML Verification — AWS Bedrock connection
# [4/6] Frontend Rendering — login page content check
# [5/6] API Endpoints — public + protected (401/403)
# [6/6] Container Status — running count, no restart loops
```

**If deploy.sh health polling passes but smoke tests fail**: trigger automatic rollback (see below).

### Automatic Rollback

Production smoke test failures trigger automatic rollback via CI:

1. **Restore registry tags**: Re-tag the previous version as `production`
2. **Redeploy with `--no-rotate`**: Deploy restored tag without rotating history
3. **Skip cleanup**: Faster rollback, no image pruning

```bash
# CI rollback step (runs if deploy succeeded but smoke test failed)
# 1. Restore previous image tag
aws ecr batch-get-image --repository-name $REPO --image-ids imageTag=production-previous-1 ...
aws ecr put-image --repository-name $REPO --image-tag production ...

# 2. Redeploy
./scripts/deploy/deploy.sh --env production --tag production --no-rotate --skip-cleanup
```

### ECR Tag Rotation

Tag rotation enables single-command rollbacks. Tags are rotated **before** container restart so the previous version is always recoverable:

**Staging**: 5 tags (`staging`, `staging-previous-1` through `staging-previous-4`)

**Production**: 5 tags (`production`, `production-previous-1` through `production-previous-4`)

```
After each staging deploy (rotate-tags job runs BEFORE build):
  staging-previous-4  →  (discarded)
  staging-previous-3  →  staging-previous-4
  staging-previous-2  →  staging-previous-3
  staging-previous-1  →  staging-previous-2
  staging             →  staging-previous-1  (old image preserved)
  (build then pushes new image as :staging)

After each production deploy:
  production-previous-4  →  (discarded)
  production-previous-3  →  production-previous-4
  production-previous-2  →  production-previous-3
  production-previous-1  →  production-previous-2
  production             →  production-previous-1
  staging                →  production  (promoted)
```

**Rollback any generation**:
- Staging: `deploy.sh --env staging --tag staging-previous-2 --no-rotate`
- Production: `deploy.sh --env production --tag production-previous-2 --no-rotate`

**Important**: ECR tag backup must run BEFORE the build pushes the new `:staging` image. If the build overwrites `:staging` first, the old image is lost. The staging pipeline handles this with a dedicated `rotate-tags` job that runs between `prepare` and `build`.

### Expected Deployment Timeline

| Phase | Duration | Services Available |
|-------|----------|--------------------|
| Pull images | ~30s | All (old containers serving) |
| Migrations | ~10-30s | All (old containers serving) |
| Rolling recreate | ~15s total | Per-service gap 3-5s, never all down |
| Health polling | 5-30s | Confirms all services ready |
| Smoke tests | ~30-60s | All (verified healthy) |
| **Total** | **~2-3 min** | **Near-zero downtime** |

### Checklist for New Projects

When setting up zero-downtime deploys for a new project:

1. Add healthcheck endpoints to all services (return 200 when ready)
2. Tune `docker-compose.yml` healthcheck intervals (10s interval, 5s timeout, 5 retries)
3. Set `start_period` per service based on measured startup time
4. Deploy script: use `up -d --force-recreate` instead of `down` + `up`
5. Deploy script: detect compose changes (hash comparison) for full-restart fallback
6. Replace all `sleep N` with health polling loops (curl + timeout)
7. Smoke tests: reduce stabilization sleeps since deploy confirms health
8. CI: wire smoke test failure to automatic rollback
9. Registry: implement tag rotation for rollback capability
10. Migrations: run before container restart (must be backward-compatible)

---

## Best Practices

1. **Read branches from PROJECT.yaml** - Don't hardcode branch names
2. **Calculate version from git tags** - Use `~/.claude/scripts/version.sh`
3. **Build once, promote** - Same image for staging and production
4. **Git tags on success only** - Only create after successful production deployment
5. **Secrets at runtime** - Fetch from Infisical/AWS, not env vars
6. **Conventional commits** - Use `feat:`, `fix:`, `BREAKING CHANGE:` for auto-versioning
7. **Multi-audience release notes** - Follow PR template guidelines for comprehensive release documentation
8. **Rolling recreate over full restart** - Use `up -d --force-recreate` instead of `down` + `up`
9. **Health polling over sleep** - Poll endpoints deterministically, never use arbitrary `sleep`
10. **Tune healthcheck intervals** - 10s interval / 5s timeout / 5 retries for app services

---

## See Also

**Related Documentation**:
- **[Multi-Audience Release Notes Workflow](workflows/release-notes-guide.md)** - Complete guide to PR-based semantic versioning and release notes generation
- **[PR Guidelines](reference/pr-guidelines.md)** - Pull request and merge request best practices
- **[Version Management](reference/version-management.md)** - Semantic versioning and git tag strategies
- **[Deployment Scripts](../scripts/DEPLOYMENT_SCRIPTS.md)** - Reference for deployment automation scripts
- **[Task Management](task-management.md)** - Development workflow and task lifecycle

**Pipeline Configuration**:
- `/deploy-to-stage` - Staging deployment with version preview
- `/deploy-to-prod` - Production deployment with release notes generation
- `~/.claude/scripts/version.sh` - Version calculation script
- `~/.claude/scripts/generate-release-notes.py` - Multi-audience notes generator

---

See ~/.claude/docs/pipelines.md.backup for complete documentation
