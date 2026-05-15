# Smoke Testing Pattern

**Purpose**: Quick validation that critical system functionality works after deployment, rotation, or infrastructure changes.

Smoke tests verify the **bare minimum** - if these fail, the system is broken and should be rolled back immediately.

## What Are Smoke Tests?

**Smoke tests** are shallow, fast tests that verify critical paths work:
- System starts and responds
- Critical endpoints return expected responses
- Database connectivity works
- External services are reachable
- Authentication mechanisms function

**NOT smoke tests** (these are integration/E2E tests):
- Business logic validation
- Edge case handling
- Multi-step workflows
- Performance testing
- Data consistency checks

**Rule of thumb**: Smoke tests should complete in < 30 seconds.

## Standard Project Structure

```
project/
├── smoke-tests/
│   ├── 00-health-check.sh       # Service health endpoints
│   ├── 10-database.sh            # Database connectivity
│   ├── 20-auth.sh                # Authentication works
│   ├── 30-critical-endpoints.sh  # Core API endpoints
│   └── 90-external-services.sh   # Third-party service connectivity
├── scripts/
│   └── smoke-tests.sh            # Runner script (executes all tests)
└── PROJECT.yaml                  # Test configuration
```

## PROJECT.yaml Configuration

```yaml
smoke_tests:
  enabled: true
  timeout_seconds: 30
  parallel: false  # Run sequentially by default

  # Service endpoints to test
  services:
    backend:
      url: "http://localhost:8000"
      health_endpoint: "/health"

    frontend:
      url: "http://localhost:3000"
      health_endpoint: "/"

  # Critical endpoints (application-specific)
  critical_endpoints:
    - method: GET
      path: /api/users/me
      auth_required: true
      expected_status: 200

    - method: POST
      path: /api/orders
      auth_required: true
      expected_status: 201
      body: '{"product_id": "test"}'

  # Database checks
  database:
    enabled: true
    query: "SELECT 1"

  # External services
  external_services:
    - name: stripe
      type: api_key_validation
    - name: sendgrid
      type: api_key_validation
```

## Individual Test Structure

Each test script follows this pattern:

```bash
#!/usr/bin/env bash
set -euo pipefail

# Source test helpers
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../scripts/lib/test-helpers.sh"

TEST_NAME="Database Connectivity"

# Test implementation
test_database_connectivity() {
    log_test_start "$TEST_NAME"

    # Get database credentials from secrets endpoint
    DB_STATUS=$(curl -s http://localhost:8000/status/secrets | jq -r '.checks.database.status')

    if [[ "$DB_STATUS" == "healthy" ]]; then
        log_test_pass "$TEST_NAME" "Database connection successful"
        return 0
    else
        log_test_fail "$TEST_NAME" "Database connection failed: ${DB_STATUS}"
        return 1
    fi
}

# Run test
test_database_connectivity
```

## Runner Script Pattern

**Location**: `scripts/smoke-tests.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${SCRIPT_DIR}/lib/project-config.sh"
source "${SCRIPT_DIR}/lib/colors.sh"

# Parse arguments
PARALLEL=false
VERBOSE=false
OUTPUT_FORMAT="human"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --parallel) PARALLEL=true; shift ;;
        --verbose) VERBOSE=true; shift ;;
        --output) OUTPUT_FORMAT="$2"; shift 2 ;;
        --help)
            cat <<EOF
Smoke Test Runner

Usage: ./scripts/smoke-tests.sh [OPTIONS]

Options:
  --parallel     Run tests in parallel
  --verbose      Show detailed output
  --output       Output format (human|json)
  --help         Show this help

Exit codes:
  0  All tests passed
  1  One or more tests failed
  2  Configuration error
EOF
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 2
            ;;
    esac
done

require_project_config

# Check if smoke tests enabled
SMOKE_ENABLED=$(get_config "smoke_tests.enabled" "true")
if [[ "$SMOKE_ENABLED" != "true" ]]; then
    echo "Smoke tests disabled in PROJECT.yaml"
    exit 0
fi

TIMEOUT=$(get_config "smoke_tests.timeout_seconds" "30")
SMOKE_DIR="${PROJECT_ROOT}/smoke-tests"

if [[ ! -d "$SMOKE_DIR" ]]; then
    echo "Error: smoke-tests/ directory not found"
    exit 2
fi

# Header
if [[ "$OUTPUT_FORMAT" == "json" ]]; then
    echo '{"action":"smoke_tests","status":"started","timestamp":"'$(date -Iseconds)'"}'
else
    echo "${BLUE}═══════════════════════════════════════════════════════${NC}"
    echo "${BLUE}  SMOKE TESTS${NC}"
    echo "${BLUE}═══════════════════════════════════════════════════════${NC}"
    echo ""
fi

# Find all test scripts
TEST_SCRIPTS=()
while IFS= read -r -d '' script; do
    TEST_SCRIPTS+=("$script")
done < <(find "$SMOKE_DIR" -name "*.sh" -type f -print0 | sort -z)

if [[ ${#TEST_SCRIPTS[@]} -eq 0 ]]; then
    echo "No test scripts found in smoke-tests/"
    exit 2
fi

# Run tests
FAILED_TESTS=()
PASSED_TESTS=()
START_TIME=$(date +%s)

run_test() {
    local script="$1"
    local test_name=$(basename "$script" .sh)

    if timeout "$TIMEOUT" bash "$script"; then
        PASSED_TESTS+=("$test_name")
        return 0
    else
        FAILED_TESTS+=("$test_name")
        return 1
    fi
}

if [[ "$PARALLEL" == "true" ]]; then
    # Run in parallel
    for script in "${TEST_SCRIPTS[@]}"; do
        run_test "$script" &
    done
    wait
else
    # Run sequentially
    for script in "${TEST_SCRIPTS[@]}"; do
        run_test "$script" || true
    done
fi

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

# Results
TOTAL_TESTS=${#TEST_SCRIPTS[@]}
PASSED_COUNT=${#PASSED_TESTS[@]}
FAILED_COUNT=${#FAILED_TESTS[@]}

if [[ "$OUTPUT_FORMAT" == "json" ]]; then
    cat <<EOF
{
  "action": "smoke_tests_complete",
  "status": "$([ "$FAILED_COUNT" -eq 0 ] && echo "success" || echo "failure")",
  "total_tests": $TOTAL_TESTS,
  "passed": $PASSED_COUNT,
  "failed": $FAILED_COUNT,
  "duration_seconds": $DURATION,
  "failed_tests": $(printf '%s\n' "${FAILED_TESTS[@]}" | jq -R . | jq -s .),
  "timestamp": "$(date -Iseconds)"
}
EOF
else
    echo ""
    if [[ $FAILED_COUNT -eq 0 ]]; then
        echo "${GREEN}═══════════════════════════════════════════════════════${NC}"
        echo "${GREEN}  All Smoke Tests Passed! (${PASSED_COUNT}/${TOTAL_TESTS})${NC}"
        echo "${GREEN}═══════════════════════════════════════════════════════${NC}"
    else
        echo "${RED}═══════════════════════════════════════════════════════${NC}"
        echo "${RED}  Smoke Tests Failed (${FAILED_COUNT}/${TOTAL_TESTS})${NC}"
        echo "${RED}═══════════════════════════════════════════════════════${NC}"
        echo ""
        echo "${RED}Failed tests:${NC}"
        for test in "${FAILED_TESTS[@]}"; do
            echo "  ${RED}✗${NC} $test"
        done
    fi
    echo ""
    echo "Duration: ${CYAN}${DURATION}s${NC}"
fi

exit $([ "$FAILED_COUNT" -eq 0 ] && echo 0 || echo 1)
```

## Test Helper Library

**Location**: `scripts/lib/test-helpers.sh`

```bash
#!/usr/bin/env bash

# Source colors
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/colors.sh"

log_test_start() {
    echo "${BLUE}▸${NC} Running: $1"
}

log_test_pass() {
    echo "${GREEN}✓${NC} $1: $2"
}

log_test_fail() {
    echo "${RED}✗${NC} $1: $2" >&2
}

log_test_skip() {
    echo "${YELLOW}○${NC} $1: $2"
}

# HTTP request helper
http_get() {
    local url="$1"
    local expected_status="${2:-200}"

    response=$(curl -s -w "\n%{http_code}" "$url" 2>/dev/null || echo -e "\n000")
    http_code="${response##*$'\n'}"
    body="${response%$'\n'*}"

    if [[ "$http_code" == "$expected_status" ]]; then
        echo "$body"
        return 0
    else
        echo "HTTP $http_code (expected $expected_status)" >&2
        return 1
    fi
}

http_post() {
    local url="$1"
    local data="$2"
    local expected_status="${3:-200}"

    response=$(curl -s -w "\n%{http_code}" -X POST -H "Content-Type: application/json" -d "$data" "$url" 2>/dev/null || echo -e "\n000")
    http_code="${response##*$'\n'}"
    body="${response%$'\n'*}"

    if [[ "$http_code" == "$expected_status" ]]; then
        echo "$body"
        return 0
    else
        echo "HTTP $http_code (expected $expected_status)" >&2
        return 1
    fi
}

# Wait for service to be ready
wait_for_service() {
    local url="$1"
    local timeout="${2:-30}"
    local interval="${3:-1}"
    local elapsed=0

    while [[ $elapsed -lt $timeout ]]; do
        if curl -s -f "$url" >/dev/null 2>&1; then
            return 0
        fi
        sleep "$interval"
        elapsed=$((elapsed + interval))
    done

    return 1
}

# Get test token (if auth required)
get_test_token() {
    local auth_url="${1:-http://localhost:8000/auth/login}"

    response=$(http_post "$auth_url" '{"username":"test","password":"test"}' 200)
    echo "$response" | jq -r '.token // .access_token // ""'
}
```

## Example Test Scripts

### 00-health-check.sh

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../scripts/lib/test-helpers.sh"
source "${SCRIPT_DIR}/../scripts/lib/project-config.sh"

TEST_NAME="Health Check"

test_health_endpoints() {
    log_test_start "$TEST_NAME"

    # Get service URLs from PROJECT.yaml
    BACKEND_URL=$(get_config "smoke_tests.services.backend.url" "http://localhost:8000")
    HEALTH_PATH=$(get_config "smoke_tests.services.backend.health_endpoint" "/health")

    # Test health endpoint
    if http_get "${BACKEND_URL}${HEALTH_PATH}" 200 >/dev/null; then
        log_test_pass "$TEST_NAME" "Backend health endpoint responsive"
        return 0
    else
        log_test_fail "$TEST_NAME" "Backend health endpoint failed"
        return 1
    fi
}

test_health_endpoints
```

### 10-database.sh

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../scripts/lib/test-helpers.sh"
source "${SCRIPT_DIR}/../scripts/lib/project-config.sh"

TEST_NAME="Database Connectivity"

test_database() {
    log_test_start "$TEST_NAME"

    DB_ENABLED=$(get_config "smoke_tests.database.enabled" "true")
    if [[ "$DB_ENABLED" != "true" ]]; then
        log_test_skip "$TEST_NAME" "Database tests disabled"
        return 0
    fi

    # Test via status endpoint
    BACKEND_URL=$(get_config "smoke_tests.services.backend.url" "http://localhost:8000")
    STATUS=$(http_get "${BACKEND_URL}/status/secrets" 200)

    DB_STATUS=$(echo "$STATUS" | jq -r '.checks.database.status // "unknown"')

    if [[ "$DB_STATUS" == "healthy" ]]; then
        DB_USER=$(echo "$STATUS" | jq -r '.checks.database.user // "unknown"')
        log_test_pass "$TEST_NAME" "Database healthy (user: ${DB_USER})"
        return 0
    else
        log_test_fail "$TEST_NAME" "Database unhealthy: ${DB_STATUS}"
        return 1
    fi
}

test_database
```

### 20-auth.sh

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../scripts/lib/test-helpers.sh"
source "${SCRIPT_DIR}/../scripts/lib/project-config.sh"

TEST_NAME="Authentication"

test_auth() {
    log_test_start "$TEST_NAME"

    BACKEND_URL=$(get_config "smoke_tests.services.backend.url" "http://localhost:8000")

    # Test login endpoint
    response=$(http_post "${BACKEND_URL}/auth/login" '{"username":"test","password":"test"}' 200)

    TOKEN=$(echo "$response" | jq -r '.token // .access_token // ""')

    if [[ -n "$TOKEN" && "$TOKEN" != "null" ]]; then
        log_test_pass "$TEST_NAME" "Authentication successful"
        return 0
    else
        log_test_fail "$TEST_NAME" "No token received"
        return 1
    fi
}

test_auth
```

### 30-critical-endpoints.sh

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../scripts/lib/test-helpers.sh"
source "${SCRIPT_DIR}/../scripts/lib/project-config.sh"

TEST_NAME="Critical Endpoints"

test_critical_endpoints() {
    log_test_start "$TEST_NAME"

    BACKEND_URL=$(get_config "smoke_tests.services.backend.url" "http://localhost:8000")

    # Get test token if auth required
    TOKEN=$(get_test_token "${BACKEND_URL}/auth/login")

    # Test each critical endpoint from PROJECT.yaml
    local all_passed=true
    local endpoints_count=0

    while read -r endpoint; do
        if [[ -z "$endpoint" || "$endpoint" == "null" ]]; then
            continue
        fi

        endpoints_count=$((endpoints_count + 1))

        method=$(echo "$endpoint" | jq -r '.method')
        path=$(echo "$endpoint" | jq -r '.path')
        expected=$(echo "$endpoint" | jq -r '.expected_status')

        response=$(curl -s -w "\n%{http_code}" \
            -X "$method" \
            -H "Authorization: Bearer $TOKEN" \
            "${BACKEND_URL}${path}" 2>/dev/null || echo -e "\n000")

        http_code="${response##*$'\n'}"

        if [[ "$http_code" == "$expected" ]]; then
            log_test_pass "$TEST_NAME" "$method $path → $http_code"
        else
            log_test_fail "$TEST_NAME" "$method $path → $http_code (expected $expected)"
            all_passed=false
        fi
    done < <(get_config "smoke_tests.critical_endpoints" "[]" | jq -c '.[]')

    if [[ $endpoints_count -eq 0 ]]; then
        log_test_skip "$TEST_NAME" "No critical endpoints defined"
        return 0
    fi

    if [[ "$all_passed" == "true" ]]; then
        log_test_pass "$TEST_NAME" "All critical endpoints passed ($endpoints_count)"
        return 0
    else
        log_test_fail "$TEST_NAME" "Some critical endpoints failed"
        return 1
    fi
}

test_critical_endpoints
```

## When to Run Smoke Tests

### Automatically (Required)
- After deployment to any environment
- After secret rotation (via verify-rotation.sh)
- After infrastructure changes
- In CI/CD pipelines before promoting builds

### Manually (As Needed)
- After configuration changes
- When debugging deployment issues
- Before running full integration tests

## Integration with Other Systems

### Secret Rotation Verification

The `scripts/verify-rotation.sh` script runs smoke tests after waiting 1 minute:

```bash
# Step 4: Run smoke tests after 1 minute
log_step "smoke_tests" "Waiting 1 minute before running smoke tests"
sleep 60

if [[ -n "$SMOKE_TEST_SCRIPT" && -x "$SMOKE_TEST_SCRIPT" ]]; then
    log_step "smoke_tests" "Running smoke tests: ${SMOKE_TEST_SCRIPT}"

    SMOKE_OUTPUT=$("$SMOKE_TEST_SCRIPT" 2>&1)
    SMOKE_EXIT_CODE=$?

    if [[ $SMOKE_EXIT_CODE -eq 0 ]]; then
        log_success "smoke_tests" "Smoke tests passed"
    else
        log_error "smoke_tests" "Smoke tests failed (exit code: ${SMOKE_EXIT_CODE})"
        echo "$SMOKE_OUTPUT" | tail -20
        exit 1
    fi
fi
```

### CI/CD Pipelines

```yaml
# .gitlab-ci.yml
smoke-test:
  stage: test
  script:
    - make up
    - ./scripts/smoke-tests.sh --output json
  artifacts:
    reports:
      junit: smoke-test-results.xml
```

### Docker Compose

```yaml
# docker-compose.yml
services:
  smoke-tests:
    image: curlimages/curl:latest
    depends_on:
      - backend
      - frontend
    volumes:
      - ./smoke-tests:/smoke-tests:ro
      - ./scripts:/scripts:ro
    command: /scripts/smoke-tests.sh
    profiles:
      - test
```

Run with: `docker compose --profile test up smoke-tests`

## Makefile Integration

```makefile
# Makefile
.PHONY: smoke-test
smoke-test:
	@./scripts/smoke-tests.sh

.PHONY: smoke-test-parallel
smoke-test-parallel:
	@./scripts/smoke-tests.sh --parallel

.PHONY: smoke-test-json
smoke-test-json:
	@./scripts/smoke-tests.sh --output json

.PHONY: ci-smoke-test
ci-smoke-test:
	@./scripts/smoke-tests.sh --output json --parallel
```

## Best Practices

### DO
- Keep tests fast (< 30 seconds total)
- Test critical paths only
- Use real endpoints (not mocks)
- Output JSON for CI/CD consumption
- Make tests idempotent
- Number test files for execution order
- Fail fast on critical failures

### DON'T
- Test business logic (use integration tests)
- Test edge cases (use unit tests)
- Make external API calls (test connectivity only)
- Create test data (use dedicated fixtures)
- Test performance (use load tests)
- Run tests in production (unless read-only)

## Smoke Test Coverage Guidelines

### Minimum (All Projects)
- Service health endpoints respond
- Database connectivity works
- Authentication mechanism functions

### Standard (Most Projects)
- Critical API endpoints return expected status codes
- External service API keys are valid
- Cache/Redis connectivity (if used)

### Advanced (Complex Projects)
- Message queue connectivity (RabbitMQ, Kafka)
- Storage bucket accessibility (S3, GCS)
- WebSocket/SSE connections establish
- Background job workers respond

## Troubleshooting

### Tests Timeout
- Increase `smoke_tests.timeout_seconds` in PROJECT.yaml
- Check if services are actually running
- Verify network connectivity between containers

### Intermittent Failures
- Add wait_for_service() calls before tests
- Increase service startup grace period
- Check for race conditions in test execution

### All Tests Fail
- Verify services are running: `docker compose ps`
- Check service logs: `docker compose logs`
- Test endpoints manually: `curl http://localhost:8000/health`

## See Also

- [Testing Best Practices](testing.md)
- [Secret Rotation Patterns](patterns/secret-rotation.md)
- [CI/CD Pipeline Guide](pipelines.md)
- [Makefile Best Practices](makefile.md)
