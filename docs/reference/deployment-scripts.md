# Deployment Scripts Guide

**Philosophy**: All deployment logic lives in scripts that can be used by:
- AI agents (via `/deploy` skill)
- CI/CD pipelines (GitHub Actions, GitLab CI)
- Manual execution by developers

Scripts read configuration from `PROJECT.yaml` and handle environment differences (work vs home).

---

## Required Scripts

| Script | Purpose | Required |
|--------|---------|----------|
| `scripts/deploy-to-stage.sh` | Deploy to staging (standard pattern) | Yes |
| `scripts/deploy-to-prod.sh` | Deploy to production (standard pattern) | Yes |
| `scripts/deploy-risk.sh` | Deployment risk analysis | Yes |
| `scripts/deployment-config.sh` | Display/validate deployment config | Yes |
| `scripts/lib/deployment-config.sh` | Shared deployment config loader (sourced) | Yes |
| `scripts/rollback.sh` | Rollback failed deployment | Optional |
| `scripts/smoke-tests.sh` | Post-deployment smoke tests | Optional |

---

## Script Interface

All scripts must accept two arguments:

```bash
$1 = environment (staging | production)
$2 = env_type (work | home)
```

**Environment**: The deployment target (staging or production)
**Env Type**: The location (work=macOS, home=WSL)

---

## Template: deploy-staging.sh

```bash
#!/bin/bash
set -euo pipefail

# Accept arguments
ENVIRONMENT=${1:-staging}
ENV_TYPE=${2:-$([ "$(uname -s)" == "Darwin" ] && echo "work" || echo "home")}

echo "═══════════════════════════════════════"
echo "  Deploying to ${ENVIRONMENT} (${ENV_TYPE})"
echo "═══════════════════════════════════════"

# Read configuration from PROJECT.yaml
if [[ ! -f "PROJECT.yaml" ]]; then
    echo "Error: PROJECT.yaml not found"
    exit 1
fi

# Get version
VERSION=$(yq eval '.version_file' PROJECT.yaml | xargs cat 2>/dev/null || git rev-parse --short HEAD)
echo "Version: ${VERSION}"

# 1. Build Docker images (if needed)
echo ""
echo "Step 1: Building Docker images..."
if [[ -f "Makefile" ]] && grep -q "^build:" Makefile; then
    make build
else
    docker compose build
fi

# 2. Tag and push images to registry
echo ""
echo "Step 2: Tagging and pushing images..."

# Get registry from PROJECT.yaml based on environment
REGISTRY=$(yq eval ".docker.registries.${ENV_TYPE}.${ENVIRONMENT}" PROJECT.yaml)

if [[ "$REGISTRY" != "null" ]]; then
    for SERVICE in $(docker compose config --services); do
        IMAGE_NAME="${SERVICE}"
        FULL_IMAGE="${REGISTRY}/${IMAGE_NAME}:${VERSION}"
        LATEST_IMAGE="${REGISTRY}/${IMAGE_NAME}:latest"

        # Tag
        docker tag "${IMAGE_NAME}:latest" "${FULL_IMAGE}"
        docker tag "${IMAGE_NAME}:latest" "${LATEST_IMAGE}"

        # Push
        docker push "${FULL_IMAGE}"
        docker push "${LATEST_IMAGE}"

        echo "✓ Pushed ${FULL_IMAGE}"
    done
else
    echo "⚠️  No registry configured, skipping push"
fi

# 3. Deploy based on method
echo ""
echo "Step 3: Deploying to target..."

# Get deployment config from PROJECT.yaml
DEPLOY_METHOD=$(yq eval ".deployment.${ENV_TYPE}.${ENVIRONMENT}.method" PROJECT.yaml)

case "$DEPLOY_METHOD" in
    ssh)
        # SSH deployment
        HOST=$(yq eval ".deployment.${ENV_TYPE}.${ENVIRONMENT}.host" PROJECT.yaml)
        USER=$(yq eval ".deployment.${ENV_TYPE}.${ENVIRONMENT}.user" PROJECT.yaml)
        DEPLOY_PATH=$(yq eval ".deployment.${ENV_TYPE}.${ENVIRONMENT}.path" PROJECT.yaml)

        echo "Deploying via SSH to ${USER}@${HOST}:${DEPLOY_PATH}"

        # Copy compose file and configs
        rsync -avz \
            --exclude='.git' \
            --exclude='node_modules' \
            --exclude='__pycache__' \
            --exclude='.pytest_cache' \
            --exclude='.venv' \
            docker-compose.yml \
            scripts/ \
            "${USER}@${HOST}:${DEPLOY_PATH}/"

        # Deploy on remote
        ssh "${USER}@${HOST}" bash << EOF
            set -euo pipefail
            cd ${DEPLOY_PATH}

            # Create .env with ONLY ENVIRONMENT
            echo "ENVIRONMENT=${ENVIRONMENT}" > .env

            # Pull latest images
            docker compose pull

            # Run migrations (if applicable)
            if docker compose config --services | grep -q backend; then
                docker compose run --rm backend python -m alembic upgrade head || true
            fi

            # Restart services
            docker compose up -d

            # Wait for services
            sleep 10

            # Check services
            docker compose ps
EOF

        echo "✓ SSH deployment completed"
        ;;

    ssm)
        # AWS SSM deployment
        INSTANCE_ID=$(yq eval ".deployment.${ENV_TYPE}.${ENVIRONMENT}.instance_id" PROJECT.yaml)
        REGION=$(yq eval ".deployment.${ENV_TYPE}.${ENVIRONMENT}.region" PROJECT.yaml)

        echo "Deploying via AWS SSM to ${INSTANCE_ID} in ${REGION}"

        # Send commands via SSM
        COMMAND_ID=$(aws ssm send-command \
            --instance-ids "${INSTANCE_ID}" \
            --region "${REGION}" \
            --document-name "AWS-RunShellScript" \
            --parameters "commands=[
                'cd /opt/app',
                'docker compose pull',
                'docker compose run --rm backend python -m alembic upgrade head || true',
                'docker compose up -d',
                'sleep 10',
                'docker compose ps'
            ]" \
            --output text \
            --query 'Command.CommandId')

        echo "SSM Command ID: ${COMMAND_ID}"
        echo "Waiting for command to complete..."

        # Wait for command to finish
        aws ssm wait command-executed \
            --command-id "${COMMAND_ID}" \
            --instance-id "${INSTANCE_ID}" \
            --region "${REGION}"

        # Get output
        aws ssm get-command-invocation \
            --command-id "${COMMAND_ID}" \
            --instance-id "${INSTANCE_ID}" \
            --region "${REGION}" \
            --query 'StandardOutputContent' \
            --output text

        echo "✓ SSM deployment completed"
        ;;

    local)
        # Local deployment (for development)
        echo "Deploying locally..."

        docker compose pull
        docker compose up -d

        # Run migrations
        if docker compose config --services | grep -q backend; then
            docker compose run --rm backend python -m alembic upgrade head || true
        fi

        # Check services
        docker compose ps

        echo "✓ Local deployment completed"
        ;;

    *)
        echo "Error: Unknown deployment method: ${DEPLOY_METHOD}"
        exit 1
        ;;
esac

# 4. Wait for services to be ready
echo ""
echo "Step 4: Waiting for services to be ready..."
sleep 15

echo ""
echo "✓ Deployment to ${ENVIRONMENT} (${ENV_TYPE}) completed successfully"
```

---

## Template: deploy-production.sh

Production deployments have the same structure but with additional safety checks:

```bash
#!/bin/bash
set -euo pipefail

ENVIRONMENT=${1:-production}
ENV_TYPE=${2:-$([ "$(uname -s)" == "Darwin" ] && echo "work" || echo "home")}

echo "═══════════════════════════════════════"
echo "  ⚠️  PRODUCTION DEPLOYMENT (${ENV_TYPE})"
echo "═══════════════════════════════════════"

# Production safety checks
if [[ ! -f "docs/deployment-risks/$(date +%Y-%m-%d)-production-*.md" ]]; then
    echo "⚠️  Warning: No risk analysis found for today"
    echo "Run: /analyze-deployment-risk production"
    read -p "Continue anyway? (yes/no): " CONTINUE
    if [[ "$CONTINUE" != "yes" ]]; then
        exit 1
    fi
fi

# Check git status
if [[ -n "$(git status --porcelain)" ]]; then
    echo "Error: Uncommitted changes detected"
    exit 1
fi

# Confirm production deployment
read -p "Deploy to PRODUCTION? Type 'yes' to confirm: " CONFIRM
if [[ "$CONFIRM" != "yes" ]]; then
    echo "Deployment aborted"
    exit 1
fi

# Rest of deployment follows same pattern as staging
# ... (same steps as deploy-staging.sh)
```

---

## Template: rollback.sh

```bash
#!/bin/bash
set -euo pipefail

ENVIRONMENT=${1:-production}
ENV_TYPE=${2:-$([ "$(uname -s)" == "Darwin" ] && echo "work" || echo "home")}

echo "═══════════════════════════════════════"
echo "  ROLLING BACK ${ENVIRONMENT} (${ENV_TYPE})"
echo "═══════════════════════════════════════"

# Get previous version
CURRENT_VERSION=$(git describe --tags --abbrev=0 2>/dev/null || git rev-parse --short HEAD)
PREVIOUS_VERSION=$(git describe --tags --abbrev=0 HEAD^ 2>/dev/null || git rev-parse --short HEAD^)

echo "Current: ${CURRENT_VERSION}"
echo "Rolling back to: ${PREVIOUS_VERSION}"

# Confirm rollback
read -p "Confirm rollback to ${PREVIOUS_VERSION}? (yes/no): " CONFIRM
if [[ "$CONFIRM" != "yes" ]]; then
    echo "Rollback aborted"
    exit 1
fi

# Read deployment config
DEPLOY_METHOD=$(yq eval ".deployment.${ENV_TYPE}.${ENVIRONMENT}.method" PROJECT.yaml)

case "$DEPLOY_METHOD" in
    ssh)
        HOST=$(yq eval ".deployment.${ENV_TYPE}.${ENVIRONMENT}.host" PROJECT.yaml)
        USER=$(yq eval ".deployment.${ENV_TYPE}.${ENVIRONMENT}.user" PROJECT.yaml)
        DEPLOY_PATH=$(yq eval ".deployment.${ENV_TYPE}.${ENVIRONMENT}.path" PROJECT.yaml)

        echo "Rolling back via SSH..."

        ssh "${USER}@${HOST}" bash << EOF
            set -euo pipefail
            cd ${DEPLOY_PATH}

            # Checkout previous version (if git repo on remote)
            git fetch --tags
            git checkout ${PREVIOUS_VERSION}

            # Pull previous image versions
            docker compose pull

            # Restart services
            docker compose up -d

            # Wait and verify
            sleep 10
            docker compose ps
EOF

        echo "✓ SSH rollback completed"
        ;;

    ssm)
        INSTANCE_ID=$(yq eval ".deployment.${ENV_TYPE}.${ENVIRONMENT}.instance_id" PROJECT.yaml)
        REGION=$(yq eval ".deployment.${ENV_TYPE}.${ENVIRONMENT}.region" PROJECT.yaml)

        echo "Rolling back via AWS SSM..."

        COMMAND_ID=$(aws ssm send-command \
            --instance-ids "${INSTANCE_ID}" \
            --region "${REGION}" \
            --document-name "AWS-RunShellScript" \
            --parameters "commands=[
                'cd /opt/app',
                'git fetch --tags',
                'git checkout ${PREVIOUS_VERSION}',
                'docker compose pull',
                'docker compose up -d',
                'sleep 10',
                'docker compose ps'
            ]" \
            --output text \
            --query 'Command.CommandId')

        aws ssm wait command-executed \
            --command-id "${COMMAND_ID}" \
            --instance-id "${INSTANCE_ID}" \
            --region "${REGION}"

        echo "✓ SSM rollback completed"
        ;;

    local)
        echo "Rolling back locally..."

        git checkout "${PREVIOUS_VERSION}"
        docker compose pull
        docker compose up -d
        docker compose ps

        echo "✓ Local rollback completed"
        ;;

    *)
        echo "Error: Unknown deployment method: ${DEPLOY_METHOD}"
        exit 1
        ;;
esac

echo ""
echo "✓ Rollback to ${PREVIOUS_VERSION} completed"
echo ""
echo "Verify rollback:"
echo "  ./scripts/smoke-tests.sh"
```

---

## Template: pre-deploy-checks.sh

Custom pre-flight checks beyond the default:

```bash
#!/bin/bash
set -euo pipefail

ENVIRONMENT=$1
ENV_TYPE=$2

echo "Running pre-deployment checks..."

# 1. Check git status
if [[ -n "$(git status --porcelain)" ]]; then
    echo "✗ Uncommitted changes detected"
    exit 1
fi
echo "✓ No uncommitted changes"

# 2. Check CI/CD status
CI_PLATFORM=$(yq eval '.ci.platform' PROJECT.yaml)

if [[ "$CI_PLATFORM" == "github" ]]; then
    STATUS=$(gh run list --branch "$(git branch --show-current)" --limit 1 --json conclusion -q '.[0].conclusion')
    if [[ "$STATUS" != "success" ]]; then
        echo "✗ CI not passing: ${STATUS}"
        exit 1
    fi
elif [[ "$CI_PLATFORM" == "gitlab" ]]; then
    GITLAB_TOKEN=$(cat ~/.gitlab-token 2>/dev/null || echo "")
    if [[ -n "$GITLAB_TOKEN" ]]; then
        PROJECT_ID=$(git config --get remote.origin.url | grep -oP '(?<=:).*(?=\.git)')
        STATUS=$(curl -s --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
            "https://git.turnersrus.com/api/v4/projects/${PROJECT_ID}/pipelines?ref=$(git branch --show-current)" | \
            jq -r '.[0].status')
        if [[ "$STATUS" != "success" ]]; then
            echo "✗ Pipeline not passing: ${STATUS}"
            exit 1
        fi
    fi
fi
echo "✓ CI/CD checks passing"

# 3. Check required environment variables (example)
REQUIRED_VARS=("INFISICAL_SECRET" "ENVIRONMENT")
for VAR in "${REQUIRED_VARS[@]}"; do
    if [[ -z "${!VAR:-}" ]]; then
        echo "✗ Required environment variable not set: ${VAR}"
        exit 1
    fi
done
echo "✓ Required environment variables set"

# 4. Check Docker daemon
if ! docker info >/dev/null 2>&1; then
    echo "✗ Docker daemon not running"
    exit 1
fi
echo "✓ Docker daemon running"

# 5. Check disk space (if deploying remotely)
if [[ "$DEPLOY_METHOD" == "ssh" ]]; then
    HOST=$(yq eval ".deployment.${ENV_TYPE}.${ENVIRONMENT}.host" PROJECT.yaml)
    USER=$(yq eval ".deployment.${ENV_TYPE}.${ENVIRONMENT}.user" PROJECT.yaml)

    DISK_USAGE=$(ssh "${USER}@${HOST}" "df -h / | tail -1 | awk '{print \$5}' | sed 's/%//'")
    if [[ $DISK_USAGE -gt 85 ]]; then
        echo "✗ Low disk space on target: ${DISK_USAGE}%"
        exit 1
    fi
    echo "✓ Sufficient disk space on target: ${DISK_USAGE}%"
fi

echo ""
echo "✓ All pre-deployment checks passed"
```

---

## Template: post-deploy-verify.sh

Custom verification beyond smoke tests:

```bash
#!/bin/bash
set -euo pipefail

ENVIRONMENT=$1
ENV_TYPE=$2

echo "Running post-deployment verification..."

# Get base URL from PROJECT.yaml
BASE_URL=$(yq eval ".environments.${ENV_TYPE}.${ENVIRONMENT}.url" PROJECT.yaml)

if [[ "$BASE_URL" == "null" ]]; then
    echo "Warning: No URL configured in PROJECT.yaml, skipping health checks"
    BASE_URL="http://localhost:8000"
fi

# 1. Run smoke tests
if [[ -f "scripts/smoke-tests.sh" ]]; then
    echo "Running smoke tests..."
    export SMOKE_TEST_URL="$BASE_URL"
    ./scripts/smoke-tests.sh --output json
    echo "✓ Smoke tests passed"
else
    echo "⚠️  No smoke tests found"
fi

# 2. Check health endpoints
echo "Checking health endpoints..."

HEALTH_STATUS=$(curl -s -w "\n%{http_code}" "${BASE_URL}/health" | tail -1)
if [[ "$HEALTH_STATUS" == "200" ]]; then
    echo "✓ Health endpoint: OK"
else
    echo "✗ Health endpoint failed: ${HEALTH_STATUS}"
    exit 1
fi

# 3. Check secrets validation
SECRET_STATUS=$(curl -s "${BASE_URL}/status/secrets" | jq -r '.overall_status' 2>/dev/null || echo "error")
if [[ "$SECRET_STATUS" == "healthy" ]]; then
    echo "✓ Secrets: Healthy"
else
    echo "✗ Secrets validation failed: ${SECRET_STATUS}"
    exit 1
fi

# 4. Check critical endpoints (customize per project)
ENDPOINTS=(
    "/api/v1/status"
    "/api/v1/version"
)

for ENDPOINT in "${ENDPOINTS[@]}"; do
    STATUS=$(curl -s -w "\n%{http_code}" "${BASE_URL}${ENDPOINT}" | tail -1)
    if [[ "$STATUS" == "200" ]]; then
        echo "✓ ${ENDPOINT}: OK"
    else
        echo "✗ ${ENDPOINT} failed: ${STATUS}"
        exit 1
    fi
done

echo ""
echo "✓ All post-deployment verification checks passed"
```

---

## Using in CI/CD Pipelines

### GitHub Actions

```yaml
- name: Deploy to Staging
  run: |
    ./scripts/deploy-to-stage.sh --json --full

- name: Verify Deployment
  run: |
    ./scripts/post-deploy-verify.sh staging work
```

### GitLab CI

```yaml
deploy:staging:
  script:
    - ./scripts/deploy-to-stage.sh --json --full
    - ./scripts/post-deploy-verify.sh staging home
```

---

## Best Practices

1. **Test locally first**: Run scripts locally before committing to pipeline
2. **Handle errors**: Use `set -euo pipefail` in all scripts
3. **Environment detection**: Auto-detect work vs home when possible
4. **Configuration in PROJECT.yaml**: Never hardcode hosts, paths, or credentials
5. **Idempotent scripts**: Scripts should be safe to run multiple times
6. **Clear output**: Use echo to show progress and mark steps with ✓/✗
7. **Exit codes**: Return non-zero on failure for pipeline integration
8. **Dry-run mode**: Consider adding `--dry-run` flag for testing
9. **Logging**: Log all actions for audit trail
10. **Secrets**: Never expose secrets in script output

---

## See Also

- [PROJECT.yaml Guide](project-config.md) - Configuration file structure
- [Deployment Risk Analysis](deployment-risk.md) - Pre-deployment risk assessment
- [Smoke Testing](testing-smoke.md) - Post-deployment verification
- [CI/CD Pipelines](pipelines.md) - Pipeline integration
