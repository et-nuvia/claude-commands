#!/usr/bin/env bash
set -euo pipefail

# macOS/BSD sed compatibility
if [[ "$(uname -s)" == "Darwin" ]]; then
    sedi() { sed -i '' "$@"; }
else
    sedi() { sed -i "$@"; }
fi

# pipeline-create.sh - Generate CI/CD pipeline configuration
#
# Generates optimized pipeline configurations for GitHub Actions or GitLab CI
# based on PROJECT.yaml settings with best practices including:
# - Git tag-based semantic versioning
# - Build once, deploy many (image promotion)
# - Auto-rollback on production smoke test failure
# - Release notes generation from conventional commits
# - Multi-service Docker builds
# - SSH-based deployment
#
# Usage:
#   pipeline-create.sh --json --full          # Full pipeline generation (interactive)
#   pipeline-create.sh --json --detect        # Platform detection only
#   pipeline-create.sh --json --gather        # Gather project info
#   pipeline-create.sh --json --preferences   # Gather pipeline preferences
#   pipeline-create.sh --json --generate      # Generate pipeline from stored info
#   pipeline-create.sh --raw --detect         # Debug: platform detection

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

map_status_to_action() {
    case "$1" in
        success) echo "display_summary" ;;
        intervention_needed) echo "confirm_action" ;;
        *) _default_map_status_to_action "$1" ;;
    esac
}
source "${SCRIPT_DIR}/lib/output-framework.sh"

# JSON output via framework
output_json() {
    local status="$1"
    local section="$2"
    local message="$3"
    shift 3

    local json="{\"status\":\"$status\",\"next_action\":\"$(map_status_to_action "$status")\",\"section\":\"$section\",\"message\":\"$message\",\"timestamp\":\"$(date -Iseconds)\""

    # Add optional fields
    while [[ $# -gt 0 ]]; do
        json+=",\"$1\":\"$2\""
        shift 2
    done

    json+="}"
    log_json "$json"
}

# Raw output mode
RAW_MODE=false
SECTION="--full"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --raw) RAW_MODE=true; shift ;;
    --json) RAW_MODE=false; shift ;;
    --full) SECTION="--full"; shift ;;
    --detect) SECTION="--detect"; shift ;;
    --gather) SECTION="--gather"; shift ;;
    --preferences) SECTION="--preferences"; shift ;;
    --generate) SECTION="--generate"; shift ;;
    -h|--help)
      echo "Usage: $0 [--json|--raw] [--full|--detect|--gather|--preferences|--generate]" >&2
      exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

source "${SCRIPT_DIR}/lib/yaml.sh"

# Platform detection section
detect_platform() {
    if [[ "$RAW_MODE" == "true" ]]; then
        echo "=== Platform Detection ===" >&2
        git remote -v 2>/dev/null || echo "No git remote configured" >&2
        echo "" >&2
    fi

    local platform=""

    # Auto-detect from git remote
    if git remote -v 2>/dev/null | grep -q "github.com"; then
        platform="github"
        if [[ "$RAW_MODE" == "true" ]]; then
            echo "Detected: GitHub Actions (from remote URL)" >&2
        fi
    elif git remote -v 2>/dev/null | grep -q "gitlab"; then
        platform="gitlab"
        if [[ "$RAW_MODE" == "true" ]]; then
            echo "Detected: GitLab CI (from remote URL)" >&2
        fi
    fi

    # Fall back to PROJECT.yaml if remote didn't match
    if [[ -z "$platform" && -f "PROJECT.yaml" ]]; then
        local yaml_platform=""
        yaml_platform=$(yaml_get '.ci.platform' PROJECT.yaml)
        if [[ -z "$yaml_platform" ]]; then
            yaml_platform=$(yaml_get '.git.platform' PROJECT.yaml)
        fi
        if [[ "$yaml_platform" == "github" || "$yaml_platform" == "gitlab" ]]; then
            platform="$yaml_platform"
            if [[ "$RAW_MODE" == "true" ]]; then
                echo "Detected: $platform (from PROJECT.yaml)" >&2
            fi
        fi
    fi

    if [[ -z "$platform" ]]; then
        if [[ "$RAW_MODE" == "false" ]]; then
            output_json "intervention_needed" "detect" "Could not auto-detect CI platform" \
                "options" "[\"github\",\"gitlab\"]" \
                "next_steps" "[\"Ask user which platform\",\"Store choice and resume with --gather\"]"
            exit 0
        else
            echo "Could not auto-detect platform" >&2
            exit 1
        fi
    fi

    echo "$platform" > /tmp/pipeline-create-platform.tmp

    if [[ "$RAW_MODE" == "false" ]]; then
        output_json "success" "detect" "Platform detected: $platform" \
            "platform" "$platform"
    fi
}

# Gather project information from PROJECT.yaml
gather_project_info() {
    local platform="${1:-$(cat /tmp/pipeline-create-platform.tmp 2>/dev/null || echo "")}"

    if [[ -z "$platform" ]]; then
        output_json "error" "gather" "Platform not set - run --detect first"
        exit 1
    fi

    if [[ "$RAW_MODE" == "true" ]]; then
        echo "=== Gathering Project Information ===" >&2
    fi

    if [[ ! -f "PROJECT.yaml" ]]; then
        if [[ "$RAW_MODE" == "false" ]]; then
            output_json "intervention_needed" "gather" "PROJECT.yaml not found" \
                "next_steps" "[\"Run /project-config init to create PROJECT.yaml\",\"Or provide project details manually\"]"
            exit 0
        else
            echo "PROJECT.yaml not found" >&2
            exit 1
        fi
    fi

    # Read project configuration
    local project_name=$(yaml_get_default '.name' "$(basename "$PWD")" PROJECT.yaml)
    local description=$(yaml_get_default '.description' "" PROJECT.yaml)

    # Languages and components
    local languages=$(yaml_get_default '.languages' "" PROJECT.yaml)
    local components=$(yaml_get_default '.components' "" PROJECT.yaml)

    # Docker services
    local docker_services=$(yaml_get_default '.docker.services' "" PROJECT.yaml)

    # CI branches
    local branch_dev=$(yaml_get_default '.ci.branches.development' "dev" PROJECT.yaml)
    local branch_staging=$(yaml_get_default '.ci.branches.staging' "staging" PROJECT.yaml)
    local branch_prod=$(yaml_get_default '.ci.branches.production' "prod" PROJECT.yaml)

    # Testing
    local test_command=$(yaml_get_default '.testing.command' "make test" PROJECT.yaml)
    local test_coverage=$(yaml_get_default '.testing.coverage_command' "make test-cov" PROJECT.yaml)
    local min_coverage=$(yaml_get_default '.testing.min_coverage' "80" PROJECT.yaml)

    # Databases
    local db_type=$(yaml_get_default '.databases' "" PROJECT.yaml)
    local has_migrations="false"
    if python3 -c "
import yaml
with open('PROJECT.yaml') as f:
    c = yaml.safe_load(f)
dbs = c.get('databases', [])
if isinstance(dbs, list):
    for db in dbs:
        if isinstance(db, dict) and db.get('migrations', {}).get('enabled'):
            print('true')
            break
" 2>/dev/null | grep -q "true"; then
        has_migrations="true"
    fi

    local migration_tool=$(python3 -c "
import yaml
with open('PROJECT.yaml') as f:
    c = yaml.safe_load(f)
dbs = c.get('databases', [])
if isinstance(dbs, list):
    for db in dbs:
        if isinstance(db, dict):
            m = db.get('migrations', {})
            if m.get('enabled') and m.get('tool'):
                print(m['tool'])
                break
" 2>/dev/null || echo "")

    # Secrets backend
    local secrets_backend=$(yaml_get_default '.secrets.backend' "" PROJECT.yaml)

    if [[ "$RAW_MODE" == "true" ]]; then
        echo "Project: $project_name" >&2
        echo "Languages: $languages" >&2
        echo "Components: $components" >&2
        echo "Docker services: $docker_services" >&2
        echo "Branches: dev=$branch_dev staging=$branch_staging prod=$branch_prod" >&2
        echo "Testing: $test_command (min coverage: $min_coverage%)" >&2
        echo "Migrations: $has_migrations ($migration_tool)" >&2
        echo "Secrets: $secrets_backend" >&2
    fi

    # Store project info as JSON
    cat > /tmp/pipeline-create-info.json <<EOF
{
  "platform": "$platform",
  "project_name": "$project_name",
  "description": "$description",
  "languages": "$languages",
  "components": "$components",
  "docker_services": "$docker_services",
  "branch_dev": "$branch_dev",
  "branch_staging": "$branch_staging",
  "branch_prod": "$branch_prod",
  "test_command": "$test_command",
  "test_coverage_command": "$test_coverage",
  "min_coverage": "$min_coverage",
  "has_migrations": $has_migrations,
  "migration_tool": "$migration_tool",
  "secrets_backend": "$secrets_backend"
}
EOF

    if [[ "$RAW_MODE" == "false" ]]; then
        output_json "success" "gather" "Project information loaded from PROJECT.yaml" \
            "platform" "$platform" \
            "project_name" "$project_name" \
            "branch_dev" "$branch_dev" \
            "branch_staging" "$branch_staging" \
            "branch_prod" "$branch_prod" \
            "docker_services" "$docker_services" \
            "has_migrations" "$has_migrations" \
            "secrets_backend" "$secrets_backend"
    fi
}

# Gather pipeline preferences - returns intervention_needed for LLM to ask user
gather_pipeline_preferences() {
    if [[ "$RAW_MODE" == "true" ]]; then
        echo "=== Gathering Pipeline Preferences ===" >&2
    fi

    # Check if preferences file already exists (set by LLM after asking user)
    if [[ -f /tmp/pipeline-create-prefs.json ]]; then
        if [[ "$RAW_MODE" == "true" ]]; then
            echo "Using stored preferences:" >&2
            cat /tmp/pipeline-create-prefs.json | python3 -m json.tool 2>/dev/null >&2 || true
        fi
        if [[ "$RAW_MODE" == "false" ]]; then
            output_json "success" "preferences" "Using stored pipeline preferences"
        fi
        return
    fi

    # Return intervention_needed so LLM asks user about pipeline features
    if [[ "$RAW_MODE" == "false" ]]; then
        SECTION="preferences"
        exit_with_json "intervention_needed" "Pipeline preferences needed" "" \
            "\"questions\": [\"version_management\",\"auto_rollback\",\"release_notes\",\"e2e_tests\"]," \
            "\"defaults\": {\"version_management\":true,\"auto_rollback\":true,\"release_notes\":true,\"e2e_tests\":true}"
    else
        echo "Pipeline preferences needed. Questions:" >&2
        echo "  1. Enable git tag-based version management? (recommended)" >&2
        echo "  2. Enable auto-rollback on production smoke failure? (recommended)" >&2
        echo "  3. Enable release notes generation on production deploy? (recommended)" >&2
        echo "  4. Include E2E tests in staging pipeline?" >&2
        exit 1
    fi
}

# Generate supporting files
generate_supporting_files() {
    local preferences="$1"
    local files_created=()

    # Create .dockerignore if it doesn't exist
    if [[ ! -f ".dockerignore" ]]; then
        cat > .dockerignore << 'DOCKERIGNOREEOF'
.git
.github
.gitlab-ci.yml
.gitignore
README.md
.env*
__pycache__
*.pyc
node_modules
.pytest_cache
.coverage
*.log
docs/
tests/
web/test-results/
DOCKERIGNOREEOF
        files_created+=(".dockerignore")
    fi

    # Return files as JSON array
    local files_json="["
    for file in "${files_created[@]}"; do
        files_json+="\"$file\","
    done
    files_json="${files_json%,}]"
    echo "$files_json"
}

# Generate GitLab CI pipeline
generate_gitlab_pipeline() {
    local project_info="$1"
    local preferences="$2"

    local project_name=$(echo "$project_info" | jq -r '.project_name')
    local branch_dev=$(echo "$project_info" | jq -r '.branch_dev')
    local branch_staging=$(echo "$project_info" | jq -r '.branch_staging')
    local branch_prod=$(echo "$project_info" | jq -r '.branch_prod')
    local docker_services=$(echo "$project_info" | jq -r '.docker_services')
    local has_migrations=$(echo "$project_info" | jq -r '.has_migrations')
    local migration_tool=$(echo "$project_info" | jq -r '.migration_tool')
    local min_coverage=$(echo "$project_info" | jq -r '.min_coverage')

    local enable_versioning=$(echo "$preferences" | jq -r '.version_management // true')
    local enable_rollback=$(echo "$preferences" | jq -r '.auto_rollback // true')
    local enable_release_notes=$(echo "$preferences" | jq -r '.release_notes // true')
    local enable_e2e=$(echo "$preferences" | jq -r '.e2e_tests // true')

    if [[ "$RAW_MODE" == "true" ]]; then
        echo "=== Generating GitLab CI Pipeline ===" >&2
        echo "  Versioning: $enable_versioning" >&2
        echo "  Rollback: $enable_rollback" >&2
        echo "  Release notes: $enable_release_notes" >&2
        echo "  E2E tests: $enable_e2e" >&2
    fi

    local pipeline_file=".gitlab-ci.yml"

    # Build stages list
    local stages="stages:"
    if [[ "$enable_versioning" == "true" ]]; then
        stages+=$'\n  - version'
    fi
    stages+=$'\n  - lint'
    stages+=$'\n  - test'
    stages+=$'\n  - security'
    stages+=$'\n  - build'
    stages+=$'\n  - deploy'
    stages+=$'\n  - smoke'
    if [[ "$enable_rollback" == "true" ]]; then
        stages+=$'\n  - rollback'
    fi
    if [[ "$enable_e2e" == "true" ]]; then
        stages+=$'\n  - e2e'
    fi
    stages+=$'\n  - cleanup'
    if [[ "$enable_release_notes" == "true" ]]; then
        stages+=$'\n  - release'
    fi
    stages+=$'\n  - notify'

    # Determine Docker services to build
    # Filter to buildable services (skip db, redis, etc.)
    local buildable_services=()
    IFS=',' read -ra ALL_SERVICES <<< "$docker_services"
    for svc in "${ALL_SERVICES[@]}"; do
        svc=$(echo "$svc" | xargs) # trim whitespace
        case "$svc" in
            db|redis|postgres|postgresql|mysql|mongo|mongodb|minio|elasticsearch|rabbitmq|memcached)
                ;; # Skip infrastructure services
            *)
                buildable_services+=("$svc")
                ;;
        esac
    done

    # Start writing pipeline
    cat > "$pipeline_file" << EOF
variables:
  REGISTRY: docker.turnersrus.com
  IMAGE_PREFIX: \${REGISTRY}/${project_name}
  UV_CACHE_DIR: .cache/uv
  PIP_CACHE_DIR: .cache/pip

${stages}

# ------------------------------------------------------------------------------
# Reusable configurations
# ------------------------------------------------------------------------------

.python_base:
  image: python:3.14-slim
  before_script:
    - pip install uv --quiet
  cache:
    key: python-\${CI_COMMIT_REF_SLUG}
    paths:
      - \${UV_CACHE_DIR}
      - .venv/

.docker_base:
  image: docker:24
  services:
    - docker:24-dind
  variables:
    DOCKER_TLS_CERTDIR: ""
  before_script:
    - docker login -u \${REGISTRY_USER} -p \${REGISTRY_PASSWORD} \${REGISTRY}

.ssh_base:
  image: alpine:latest
  before_script:
    - apk add --no-cache openssh-client
    - eval \$(ssh-agent -s)
    - echo "\$SSH_PRIVATE_KEY" | ssh-add -
    - mkdir -p ~/.ssh && chmod 700 ~/.ssh
    - echo "\$SSH_KNOWN_HOSTS" >> ~/.ssh/known_hosts

.only_mr:
  rules:
    - if: \$CI_PIPELINE_SOURCE == "merge_request_event"

.only_dev:
  rules:
    - if: \$CI_COMMIT_BRANCH == "${branch_dev}"

.only_staging:
  rules:
    - if: \$CI_COMMIT_BRANCH == "${branch_staging}"

.only_prod:
  rules:
    - if: \$CI_COMMIT_BRANCH == "${branch_prod}"

.only_mr_or_dev:
  rules:
    - if: \$CI_PIPELINE_SOURCE == "merge_request_event"
    - if: \$CI_COMMIT_BRANCH == "${branch_dev}"

.only_staging_or_prod:
  rules:
    - if: \$CI_COMMIT_BRANCH == "${branch_staging}"
    - if: \$CI_COMMIT_BRANCH == "${branch_prod}"
EOF

    # Version calculation stage
    if [[ "$enable_versioning" == "true" ]]; then
        cat >> "$pipeline_file" << 'VERSIONEOF'

# ------------------------------------------------------------------------------
# Version calculation (staging + prod)
# ------------------------------------------------------------------------------

calculate-version:
  stage: version
  extends: .only_staging_or_prod
  image: alpine:3.20
  before_script:
    - apk add --no-cache git bash
  script:
    - |
      # Get latest semantic version tag (repo-wide, not branch-ancestry)
      LATEST_TAG=$(git tag -l "v*.*.*" --sort=-v:refname | head -1)
      if [ -z "$LATEST_TAG" ]; then
        LATEST_TAG="v0.0.0"
      fi
      CURRENT_VERSION=${LATEST_TAG#v}

      # Get commits since last tag (subjects + bodies for semantic analysis)
      if [ "$LATEST_TAG" = "v0.0.0" ]; then
        COMMITS=$(git log --pretty=format:"%s%n%b%n---")
      else
        COMMITS=$(git log ${LATEST_TAG}..HEAD --pretty=format:"%s%n%b%n---")
      fi

      # Check for explicit Version-Bump trailer
      OVERRIDE=$(echo "$COMMITS" | grep -oE "^Version-Bump: *(major|minor|patch)" | head -1 | awk '{print $2}' || true)

      if [ -n "$OVERRIDE" ]; then
        BUMP="$OVERRIDE"
      elif echo "$COMMITS" | grep -qiE "^[^:]+!:|BREAKING CHANGE:"; then
        BUMP="major"
      elif echo "$COMMITS" | grep -qiE "^feat(\(.+\))?:"; then
        BUMP="minor"
      else
        BUMP="patch"
      fi

      # Calculate next version
      IFS='.' read -r major minor patch <<< "$CURRENT_VERSION"
      case "$BUMP" in
        major) VERSION="$((major + 1)).0.0" ;;
        minor) VERSION="${major}.$((minor + 1)).0" ;;
        patch) VERSION="${major}.${minor}.$((patch + 1))" ;;
      esac

      echo "Current: ${CURRENT_VERSION} (${LATEST_TAG})"
      echo "Bump: ${BUMP}"
      echo "Next: ${VERSION}"

      # Export for downstream jobs
      echo "VERSION=${VERSION}" >> version.env
      echo "PREVIOUS_TAG=${LATEST_TAG}" >> version.env
      echo "BUMP_TYPE=${BUMP}" >> version.env
  artifacts:
    reports:
      dotenv: version.env
VERSIONEOF
    fi

    # Lint stage
    cat >> "$pipeline_file" << 'LINTEOF'

# ------------------------------------------------------------------------------
# Lint (MR + dev)
# ------------------------------------------------------------------------------

lint:python:
  extends: [.python_base, .only_mr_or_dev]
  stage: lint
  script:
    - uv venv && uv pip install ruff pyright
    - uv run ruff check taskforge tests
    - uv run ruff format --check taskforge tests

lint:typecheck:
  extends: [.python_base, .only_mr_or_dev]
  stage: lint
  script:
    - uv venv && uv pip install -e ".[dev]"
    - uv run pyright taskforge
LINTEOF

    # Test stage
    cat >> "$pipeline_file" << EOF

# ------------------------------------------------------------------------------
# Test (MR + dev)
# ------------------------------------------------------------------------------

test:unit:
  extends: [.python_base, .only_mr_or_dev]
  stage: test
  script:
    - uv venv && uv pip install -e ".[dev]"
    - uv run pytest --cov=taskforge --cov-report=xml --cov-report=term-missing --cov-fail-under=${min_coverage} -p no:cacheprovider
  coverage: '/TOTAL.*\s(\d+(?:\.\d+)?)%/'
  artifacts:
    reports:
      coverage_report:
        coverage_format: cobertura
        path: coverage.xml
    when: always
EOF

    # Security stage
    cat >> "$pipeline_file" << 'SECURITYEOF'

# ------------------------------------------------------------------------------
# Security (MR + dev)
# ------------------------------------------------------------------------------

security:trivy:
  extends: .only_mr_or_dev
  stage: security
  image: aquasec/trivy:latest
  script:
    - trivy fs --exit-code 1 --severity CRITICAL .
    - trivy fs --exit-code 0 --severity HIGH .
    - trivy fs --format json --output trivy-report.json .
  artifacts:
    paths:
      - trivy-report.json
    when: always
  allow_failure: false
SECURITYEOF

    # Build stage - generate per-service build and promote jobs
    cat >> "$pipeline_file" << 'BUILDEOF'

# ------------------------------------------------------------------------------
# Build (staging only - build once, deploy many)
# ------------------------------------------------------------------------------

.build_image:
  extends: .docker_base
  stage: build
BUILDEOF

    if [[ "$enable_versioning" == "true" ]]; then
        cat >> "$pipeline_file" << 'BUILDEOF'
  needs: ["calculate-version"]
  script:
    - |
      echo "Building ${SERVICE} version ${VERSION}"
      docker build \
        --build-arg RUN_TESTS=true \
        --build-arg VERSION="${VERSION}" \
        --build-arg GIT_SHA="${CI_COMMIT_SHA}" \
        --build-arg BUILD_NUMBER="${CI_PIPELINE_ID}" \
        --build-arg BUILT_AT="$(date -Iseconds)" \
        --cache-from ${IMAGE_PREFIX}/${SERVICE}:staging \
        -f docker/${DOCKERFILE} \
        -t ${IMAGE_PREFIX}/${SERVICE}:${VERSION}-staging.${CI_PIPELINE_ID} \
        -t ${IMAGE_PREFIX}/${SERVICE}:staging \
        .
    - docker push ${IMAGE_PREFIX}/${SERVICE}:${VERSION}-staging.${CI_PIPELINE_ID}
    - docker push ${IMAGE_PREFIX}/${SERVICE}:staging
BUILDEOF
    else
        cat >> "$pipeline_file" << 'BUILDEOF'
  script:
    - |
      docker build \
        --build-arg RUN_TESTS=true \
        --cache-from ${IMAGE_PREFIX}/${SERVICE}:staging \
        -f docker/${DOCKERFILE} \
        -t ${IMAGE_PREFIX}/${SERVICE}:${CI_COMMIT_SHORT_SHA} \
        -t ${IMAGE_PREFIX}/${SERVICE}:staging \
        .
    - docker push ${IMAGE_PREFIX}/${SERVICE}:${CI_COMMIT_SHORT_SHA}
    - docker push ${IMAGE_PREFIX}/${SERVICE}:staging
BUILDEOF
    fi

    # Per-service build jobs
    for svc in "${buildable_services[@]}"; do
        cat >> "$pipeline_file" << EOF

build:${svc}:
  extends: [.build_image, .only_staging]
  variables:
    SERVICE: ${svc}
    DOCKERFILE: ${svc}.Dockerfile
EOF
    done

    # Promote jobs (production)
    cat >> "$pipeline_file" << 'PROMOTEEOF'

# Production: promote staging images (no rebuild)
.promote_image:
  extends: .docker_base
  stage: build
PROMOTEEOF

    if [[ "$enable_versioning" == "true" ]]; then
        cat >> "$pipeline_file" << 'PROMOTEEOF'
  needs: ["calculate-version"]
  script:
    - |
      echo "Promoting ${SERVICE} to production (version ${VERSION})"
      docker pull ${IMAGE_PREFIX}/${SERVICE}:staging
      docker tag ${IMAGE_PREFIX}/${SERVICE}:staging ${IMAGE_PREFIX}/${SERVICE}:${VERSION}
      docker tag ${IMAGE_PREFIX}/${SERVICE}:staging ${IMAGE_PREFIX}/${SERVICE}:prod
      docker push ${IMAGE_PREFIX}/${SERVICE}:${VERSION}
      docker push ${IMAGE_PREFIX}/${SERVICE}:prod
PROMOTEEOF
    else
        cat >> "$pipeline_file" << 'PROMOTEEOF'
  script:
    - |
      docker pull ${IMAGE_PREFIX}/${SERVICE}:staging
      docker tag ${IMAGE_PREFIX}/${SERVICE}:staging ${IMAGE_PREFIX}/${SERVICE}:prod
      docker tag ${IMAGE_PREFIX}/${SERVICE}:staging ${IMAGE_PREFIX}/${SERVICE}:${CI_COMMIT_SHORT_SHA}
      docker push ${IMAGE_PREFIX}/${SERVICE}:prod
      docker push ${IMAGE_PREFIX}/${SERVICE}:${CI_COMMIT_SHORT_SHA}
PROMOTEEOF
    fi

    for svc in "${buildable_services[@]}"; do
        cat >> "$pipeline_file" << EOF

promote:${svc}:
  extends: [.promote_image, .only_prod]
  variables:
    SERVICE: ${svc}
EOF
    done

    # Deploy stage
    local build_needs=""
    local promote_needs=""
    for svc in "${buildable_services[@]}"; do
        build_needs+="    - build:${svc}"$'\n'
        promote_needs+="    - promote:${svc}"$'\n'
    done

    local migration_cmd=""
    if [[ "$has_migrations" == "true" ]]; then
        if [[ "$migration_tool" == "alembic" ]]; then
            migration_cmd="        docker compose exec -T api uv run alembic upgrade head"
        elif [[ "$migration_tool" == "prisma" ]]; then
            migration_cmd="        docker compose exec -T api npx prisma migrate deploy"
        else
            migration_cmd="        # Run migrations here"
        fi
    fi

    cat >> "$pipeline_file" << EOF

# ------------------------------------------------------------------------------
# Deploy (staging + prod)
# ------------------------------------------------------------------------------

deploy:staging:
  extends: [.ssh_base, .only_staging]
  stage: deploy
  needs:
EOF
    if [[ "$enable_versioning" == "true" ]]; then
        echo "    - calculate-version" >> "$pipeline_file"
    fi
    echo -n "$build_needs" >> "$pipeline_file"

    cat >> "$pipeline_file" << EOF
  script:
    - |
      ssh \${STAGING_USER}@\${STAGING_HOST} << DEPLOY
        set -e
        cd \${STAGING_PATH}
        docker compose pull
        docker compose up -d
EOF
    if [[ -n "$migration_cmd" ]]; then
        echo "$migration_cmd" >> "$pipeline_file"
    fi
    cat >> "$pipeline_file" << EOF
      DEPLOY
  environment:
    name: staging
    url: \${STAGING_URL}

deploy:production:
  extends: [.ssh_base, .only_prod]
  stage: deploy
  needs:
EOF
    if [[ "$enable_versioning" == "true" ]]; then
        echo "    - calculate-version" >> "$pipeline_file"
    fi
    echo -n "$promote_needs" >> "$pipeline_file"

    cat >> "$pipeline_file" << EOF
  script:
    - |
      ssh \${PROD_USER}@\${PROD_HOST} << DEPLOY
        set -e
        cd \${PROD_PATH}
        docker compose pull
        docker compose up -d
EOF
    if [[ -n "$migration_cmd" ]]; then
        echo "$migration_cmd" >> "$pipeline_file"
    fi
    cat >> "$pipeline_file" << EOF
      DEPLOY
  environment:
    name: production
    url: \${PROD_URL}
EOF

    # Smoke tests
    cat >> "$pipeline_file" << 'SMOKEEOF'

# ------------------------------------------------------------------------------
# Smoke tests (staging + prod)
# ------------------------------------------------------------------------------

smoke:staging:
  extends: .only_staging
  stage: smoke
  image: alpine:latest
  before_script:
    - apk add --no-cache curl jq
  script:
    - |
      for i in $(seq 1 30); do
        STATUS=$(curl -sf "${STAGING_URL}/health" | jq -r '.status' 2>/dev/null || echo "unreachable")
        if [ "$STATUS" = "healthy" ]; then
          echo "Health check passed"
          exit 0
        fi
        echo "Attempt $i: status=$STATUS, retrying..."
        sleep 5
      done
      echo "Health check failed after 30 attempts"
      exit 1
  needs: ["deploy:staging"]

smoke:production:
  extends: .only_prod
  stage: smoke
  image: alpine:latest
  before_script:
    - apk add --no-cache curl jq
  script:
    - |
      for i in $(seq 1 30); do
        RESPONSE=$(curl -sf "${PROD_URL}/health" 2>/dev/null || echo '{}')
        STATUS=$(echo "$RESPONSE" | jq -r '.status' 2>/dev/null || echo "unreachable")
        if [ "$STATUS" = "healthy" ]; then
          echo "Health check passed"
          DEPLOYED_VERSION=$(echo "$RESPONSE" | jq -r '.version' 2>/dev/null || echo "unknown")
          echo "Deployed version: ${DEPLOYED_VERSION}"
          exit 0
        fi
        echo "Attempt $i: status=$STATUS, retrying..."
        sleep 5
      done
      echo "Health check failed after 30 attempts"
      exit 1
  needs: ["deploy:production"]
SMOKEEOF

    # Rollback stage
    if [[ "$enable_rollback" == "true" ]]; then
        cat >> "$pipeline_file" << 'ROLLBACKEOF'

# ------------------------------------------------------------------------------
# Rollback (production only - triggered on smoke failure)
# ------------------------------------------------------------------------------

rollback:production:
  extends: [.ssh_base, .only_prod]
  stage: rollback
  needs:
    - job: smoke:production
      artifacts: false
ROLLBACKEOF

        if [[ "$enable_versioning" == "true" ]]; then
            cat >> "$pipeline_file" << 'ROLLBACKEOF'
    - job: calculate-version
      artifacts: true
  script:
    - |
      echo "ROLLING BACK production (version ${VERSION} failed smoke test)"
      PREV_TAG="${PREVIOUS_TAG#v}"

      ssh ${PROD_USER}@${PROD_HOST} << ROLLBACK
        set -e
        cd \${PROD_PATH}
        echo "Rolling back to previous images..."
        for SERVICE in SERVICES_PLACEHOLDER; do
          docker pull ${IMAGE_PREFIX}/\${SERVICE}:${PREV_TAG} 2>/dev/null || \
            echo "Warning: Could not pull previous version for \${SERVICE}"
        done
        docker compose up -d
        echo "Rollback complete"
      ROLLBACK
ROLLBACKEOF
        else
            cat >> "$pipeline_file" << 'ROLLBACKEOF'
  script:
    - |
      echo "ROLLING BACK production deployment"

      ssh ${PROD_USER}@${PROD_HOST} << ROLLBACK
        set -e
        cd \${PROD_PATH}
        echo "Rolling back to previous images..."
        docker compose up -d
        echo "Rollback complete"
      ROLLBACK
ROLLBACKEOF
        fi

        # Replace services placeholder
        local services_list=""
        for svc in "${buildable_services[@]}"; do
            services_list+="$svc "
        done
        sedi "s/SERVICES_PLACEHOLDER/${services_list}/" "$pipeline_file"

        cat >> "$pipeline_file" << 'ROLLBACKEOF'

      # Verify rollback health
      echo "Verifying rollback health..."
      for i in $(seq 1 20); do
        STATUS=$(curl -sf "${PROD_URL}/health" | jq -r '.status' 2>/dev/null || echo "unreachable")
        if [ "$STATUS" = "healthy" ]; then
          echo "Rollback verified - service is healthy"
          exit 0
        fi
        echo "Rollback health check attempt $i: status=$STATUS"
        sleep 5
      done
      echo "WARNING: Rollback health check failed - manual intervention required"
      exit 1
  when: on_failure
  environment:
    name: production
    action: stop
ROLLBACKEOF
    fi

    # E2E tests
    if [[ "$enable_e2e" == "true" ]]; then
        cat >> "$pipeline_file" << 'E2EEOF'

# ------------------------------------------------------------------------------
# E2E tests (staging only)
# ------------------------------------------------------------------------------

e2e:staging:
  extends: .only_staging
  stage: e2e
  image: mcr.microsoft.com/playwright:v1.51.0-noble
  script:
    - cd web
    - npm ci
    - TASKFORGE_API_URL=${STAGING_URL} npx playwright test
  artifacts:
    paths:
      - web/test-results/
    when: on_failure
  needs: ["smoke:staging"]
E2EEOF
    fi

    # Cleanup
    cat >> "$pipeline_file" << 'CLEANUPEOF'

# ------------------------------------------------------------------------------
# Cleanup (staging - remove old images)
# ------------------------------------------------------------------------------

cleanup:staging:
  extends: [.docker_base, .only_staging]
  stage: cleanup
  script:
    - |
      echo "Pruning old images..."
      docker image prune -f 2>/dev/null || true
  allow_failure: true
  needs: ["smoke:staging"]
CLEANUPEOF

    # Release stage
    if [[ "$enable_release_notes" == "true" && "$enable_versioning" == "true" ]]; then
        cat >> "$pipeline_file" << 'RELEASEEOF'

# ------------------------------------------------------------------------------
# Release (production only - git tag + release notes + GitLab release)
# ------------------------------------------------------------------------------

create-release:
  extends: .only_prod
  stage: release
  image: alpine:3.20
  needs:
    - job: calculate-version
      artifacts: true
    - job: smoke:production
      artifacts: false
  before_script:
    - apk add --no-cache git bash curl jq
  script:
    - |
      echo "Creating release v${VERSION}"

      # Configure git
      git config user.name "GitLab CI"
      git config user.email "ci@${CI_SERVER_HOST}"

      # Check if tag already exists
      if git rev-parse "v${VERSION}" >/dev/null 2>&1; then
        echo "Tag v${VERSION} already exists, skipping"
        exit 0
      fi

      # Collect commits since last tag with full bodies for release notes
      if [ "${PREVIOUS_TAG}" = "v0.0.0" ]; then
        COMMIT_LOG=$(git log --pretty=format:"- **%s**%n  %b" | sed '/^$/d')
      else
        COMMIT_LOG=$(git log ${PREVIOUS_TAG}..HEAD --pretty=format:"- **%s**%n  %b" | sed '/^$/d')
      fi

      # Build release notes
      NOTES="## Release v${VERSION}\n\n"
      NOTES="${NOTES}**Released**: $(date -Iseconds)\n"
      NOTES="${NOTES}**Bump type**: ${BUMP_TYPE}\n"
      NOTES="${NOTES}**Previous**: ${PREVIOUS_TAG}\n\n"
      NOTES="${NOTES}### Changes\n\n${COMMIT_LOG}\n\n"
      NOTES="${NOTES}---\n\n"
      NOTES="${NOTES}**Pipeline**: ${CI_PIPELINE_URL}\n"
      NOTES="${NOTES}**Commit**: ${CI_COMMIT_SHA}\n"

      # Create annotated git tag
      git tag -a "v${VERSION}" -m "chore(release): production v${VERSION}

      Pipeline: ${CI_PIPELINE_URL}
      Commit: ${CI_COMMIT_SHA}
      Deployed: $(date -Iseconds)"

      # Push tag
      git push "https://oauth2:${CI_PUSH_TOKEN}@${CI_SERVER_HOST}/${CI_PROJECT_PATH}.git" "v${VERSION}"
      echo "Created and pushed git tag v${VERSION}"

      # Create GitLab release via API
      RELEASE_BODY=$(printf '%s' "${NOTES}" | sed 's/"/\\"/g')

      curl --fail --header "PRIVATE-TOKEN: ${CI_PUSH_TOKEN}" \
        --header "Content-Type: application/json" \
        --data "{
          \"tag_name\": \"v${VERSION}\",
          \"name\": \"Release v${VERSION}\",
          \"description\": \"${RELEASE_BODY}\"
        }" \
        "https://${CI_SERVER_HOST}/api/v4/projects/${CI_PROJECT_ID}/releases" \
        || echo "Warning: GitLab release creation failed (tag was still created)"

      echo "Release v${VERSION} created successfully"
  when: on_success
RELEASEEOF
    fi

    if [[ "$RAW_MODE" == "true" ]]; then
        echo "Created: $pipeline_file" >&2
    fi

    echo "$pipeline_file"
}

# Generate GitHub Actions pipeline (placeholder - to be expanded)
generate_github_pipeline() {
    local project_info="$1"
    local preferences="$2"

    if [[ "$RAW_MODE" == "true" ]]; then
        echo "=== GitHub Actions generation not yet updated ===" >&2
        echo "Use the GitLab generator as reference and adapt" >&2
    fi

    output_json "error" "generate" "GitHub Actions generator not yet updated for new features. Write the pipeline manually following ~/.claude/docs/reference/pipelines.md"
    exit 1
}

# Main workflow
main() {
    case "$SECTION" in
        --detect)
            detect_platform
            ;;

        --gather)
            local platform=""
            gather_project_info "$platform"
            ;;

        --preferences)
            gather_pipeline_preferences
            ;;

        --generate)
            if [[ ! -f /tmp/pipeline-create-info.json ]]; then
                output_json "error" "generate" "Project info not gathered - run --gather first"
                exit 1
            fi

            if [[ ! -f /tmp/pipeline-create-prefs.json ]]; then
                output_json "error" "generate" "Preferences not set - run --preferences first"
                exit 1
            fi

            local project_info=$(cat /tmp/pipeline-create-info.json)
            local preferences=$(cat /tmp/pipeline-create-prefs.json)
            local platform=$(echo "$project_info" | jq -r '.platform')

            local pipeline_file=""
            if [[ "$platform" == "github" ]]; then
                pipeline_file=$(generate_github_pipeline "$project_info" "$preferences")
            elif [[ "$platform" == "gitlab" ]]; then
                pipeline_file=$(generate_gitlab_pipeline "$project_info" "$preferences")
            else
                output_json "error" "generate" "Invalid platform: $platform"
                exit 1
            fi

            local supporting_files=$(generate_supporting_files "$preferences")

            if [[ "$RAW_MODE" == "false" ]]; then
                output_json "success" "generate" "Pipeline generated successfully" \
                    "platform" "$platform" \
                    "pipeline_file" "$pipeline_file"
            fi

            rm -f /tmp/pipeline-create-*.tmp /tmp/pipeline-create-*.json
            ;;

        --full)
            detect_platform

            if [[ -f /tmp/pipeline-create-platform.tmp ]]; then
                local platform=$(cat /tmp/pipeline-create-platform.tmp)
                gather_project_info "$platform"

                if [[ -f /tmp/pipeline-create-info.json ]]; then
                    gather_pipeline_preferences

                    # If intervention_needed was returned, the LLM handles it
                    # If prefs file exists, continue to generate
                    if [[ -f /tmp/pipeline-create-prefs.json ]]; then
                        local project_info=$(cat /tmp/pipeline-create-info.json)
                        local preferences=$(cat /tmp/pipeline-create-prefs.json)

                        local pipeline_file=""
                        if [[ "$platform" == "github" ]]; then
                            pipeline_file=$(generate_github_pipeline "$project_info" "$preferences")
                        elif [[ "$platform" == "gitlab" ]]; then
                            pipeline_file=$(generate_gitlab_pipeline "$project_info" "$preferences")
                        fi

                        local supporting_files=$(generate_supporting_files "$preferences")

                        if [[ "$RAW_MODE" == "false" ]]; then
                            output_json "success" "full" "Pipeline generated successfully" \
                                "platform" "$platform" \
                                "pipeline_file" "$pipeline_file"
                        fi

                        rm -f /tmp/pipeline-create-*.tmp /tmp/pipeline-create-*.json
                    fi
                fi
            fi
            ;;

        *)
            output_json "error" "unknown" "Unknown section: $SECTION" \
                "valid_sections" "[\"--detect\",\"--gather\",\"--preferences\",\"--generate\",\"--full\"]"
            exit 1
            ;;
    esac
}

main
