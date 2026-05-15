# Implementation Guide: [Brief Description]

**Work Item**: [TASK_ID]
**Folder**: [FOLDER]
**Created**: [YYYY-MM-DD HH:MM]
**Type**: Implementation Guide
**Related To**: [TSK TASK_ID]
**Author**: [Author Name/Team]
**Status**: [Draft/Review/Final]

---

## Purpose

[Brief description of what this implementation guide covers and who it's for]

---

## CRITICAL GUIDELINES (MUST FOLLOW)

**Before implementing, review these non-negotiable requirements**:

### 🔐 Secrets Management
- **ALL secrets AND config** go in secrets manager (AWS Secrets Manager or Infisical)
- **ONLY** `ENVIRONMENT` and `REGION` (work) or `ENVIRONMENT` (home) in `.env`
- **Fetch at container startup**, hold in memory only
- **NEVER commit** secrets, API keys, passwords, or connection strings
- **Examples of what goes in secrets manager**: DATABASE_URL, LOG_LEVEL, PORT, WORKERS, API_KEYS, JWT_SECRET, feature flags

### 🐳 Docker-Only Development
- **NEVER install** dependencies on host (no `npm install`, `pip install` on host)
- **NEVER run** code on host (everything in Docker)
- **ALWAYS use** `docker compose` (V2), NEVER `docker-compose`
- **All development** happens in containers

### 🔒 Security Hardening (Required for All Containers)
- **Run as non-root**: `user: "1000:1000"`
- **Read-only filesystem**: `read_only: true` with tmpfs for writable paths
- **Drop capabilities**: `cap_drop: ALL`, only add back what's needed
- **No new privileges**: `security_opt: no-new-privileges:true`
- **Resource limits**: Set CPU and memory limits
- **Health checks**: Required for all services

### 🏗️ Multi-Stage Builds
- **Testing stage** controlled by `RUN_TESTS` build arg
- **Tests disabled by default** in local builds
- **CI/CD builds with** `--build-arg RUN_TESTS=true`
- **Nix flakes** for reproducible builds (unless project specifies different base)

### 📝 Environment Detection
- **Work (macOS)**: GitHub Actions, AWS Secrets Manager, IAM roles
- **Home (WSL)**: GitLab CI, Infisical, Docker secrets
- **Detect via**: `uname -s` (Darwin = work, Linux = home)

### 🚫 License Restrictions
- **No copyleft licenses**: GPL, LGPL, AGPL not allowed
- **Security scan required**: Run Trivy before adding dependencies
- **Pin all versions**: For reproducibility

### ✅ Testing Requirements
- **All tests must pass** - No exceptions
- **No skipped tests** - Fix or remove, never skip
- **Coverage >= 80%** - Configured in PROJECT.yaml
- **TDD approach** preferred

### 🔄 Version Management
- **Git tags** with conventional commits (RECOMMENDED)
- **Automatic calculation**: `feat:` = minor, `fix:` = patch, `BREAKING CHANGE:` = major
- **Version script**: `~/.claude/scripts/get-version.sh`

**See Full Guidelines**: `~/.claude/CLAUDE.md`

---

## Overview

**What This Guide Covers**:
- [Topic 1]
- [Topic 2]
- [Topic 3]

**Target Audience**:
- [Audience 1 - e.g., Backend developers]
- [Audience 2 - e.g., DevOps engineers]
- [Audience 3 - e.g., New team members]

**Prerequisites**:
- [Prerequisite 1]
- [Prerequisite 2]
- [Prerequisite 3]

**Estimated Implementation Time**: [X hours/days]

---

## Architecture Overview

**System Components**:
```
[High-level architecture diagram or description]

Example:
Frontend (Next.js) → API Gateway → Backend (FastAPI) → Database (PostgreSQL)
                         ↓
                   Auth Service (JWT)
```

**Key Technologies**:
- **Frontend**: [Technology and version]
- **Backend**: [Technology and version]
- **Database**: [Technology and version]
- **Infrastructure**: [Technology and version]

**Design Patterns Used**:
- [Pattern 1 - e.g., Repository pattern]
- [Pattern 2 - e.g., Factory pattern]
- [Pattern 3 - e.g., Dependency injection]

---

## Prerequisites & Setup

### Required Tools

**CRITICAL: Docker-Only Development**
- ⚠️ **NEVER** install dependencies or run code on host
- ⚠️ **ALWAYS** use Docker containers for all development
- ⚠️ **ALWAYS** use `docker compose` (V2), NEVER `docker-compose`

**Required Software**:
```bash
# Only these are installed on host
- Docker 27+ (with Docker Compose V2)
- Make (for Makefile targets)
- Git

# Everything else runs in containers
# - Node.js, Python, databases, etc.
```

### Environment Configuration

**CRITICAL: Secrets Management Rules**

**Allowed in .env** (detect environment, platform):
```bash
# Work (macOS) - ONLY these two variables
ENVIRONMENT=development  # or staging, production
REGION=us-east-1        # AWS region

# Home (WSL) - ONLY this one variable
ENVIRONMENT=development  # or staging, production
```

**Bootstrap Config** (Home/Infisical only - in docker-compose.yml):
```yaml
# Define ONCE using YAML anchors in docker-compose.yml
x-infisical-bootstrap: &infisical-bootstrap
  INFISICAL_URL: "https://secrets.turnersrus.com"
  INFISICAL_CLIENT_ID: "abc-123-def"
  INFISICAL_PROJECT_ID: "4fc89a1a..."

services:
  app:
    environment:
      <<: *infisical-bootstrap  # Reference anchor
    secrets:
      - infisical_client_secret  # From Docker secret file
```

**Everything Else** (fetched from secrets manager at container startup):
- ✅ Application secrets (DATABASE_URL, JWT_SECRET, API_KEYS)
- ✅ Configuration (LOG_LEVEL, PORT, WORKERS, REDIS_HOST)
- ✅ Third-party credentials
- ✅ Service endpoints
- ✅ Feature flags

**Secrets Fetch Pattern**:
```python
# Example: Python with Infisical
from infisical import InfisicalClient

def load_secrets():
    """Fetch all secrets at startup, hold in memory only."""
    client = InfisicalClient(
        url=os.environ["INFISICAL_URL"],
        client_id=os.environ["INFISICAL_CLIENT_ID"],
        client_secret=read_docker_secret("infisical_client_secret"),
        project_id=os.environ["INFISICAL_PROJECT_ID"]
    )

    # Fetch all secrets
    secrets = client.get_all_secrets(environment=os.environ["ENVIRONMENT"])

    # Return as dict (held in memory, never written to disk)
    return {s.key: s.value for s in secrets}

# Load once at startup
config = load_secrets()

# Use throughout application
DATABASE_URL = config["DATABASE_URL"]
LOG_LEVEL = config["LOG_LEVEL"]
```

**Configuration Files**:
- `docker-compose.yml` - Container orchestration (V2 syntax)
- `Dockerfile` - Multi-stage build with security hardening
- `Makefile` - Standard targets (up, down, test, migrate)
- `.env.example` - Template showing ONLY allowed variables
- `secrets/` - Docker secret files (gitignored)

### Initial Setup

**CRITICAL: All operations in Docker**

```bash
# Clone repository
git clone <repository-url>
cd <project-name>

# Verify Docker Compose V2
docker compose version  # Should show "Docker Compose version v2.x"

# Create .env with ONLY allowed variables
cat > .env << 'EOF'
# Work (macOS)
ENVIRONMENT=development
REGION=us-east-1

# Home (WSL) - Remove REGION line
ENVIRONMENT=development
EOF

# Setup secrets (Home/Infisical)
# Create Docker secret file for Infisical client secret
mkdir -p secrets
echo "your-infisical-client-secret" > secrets/infisical_client_secret
chmod 600 secrets/infisical_client_secret

# Start all services (pulls images, builds containers)
make up
# or
docker compose up -d

# Wait for services to be healthy
docker compose ps

# Run database migrations (in container)
make migrate
# or
docker compose exec app ./scripts/migrate.sh

# View logs
make logs
# or
docker compose logs -f app

# Access application
curl http://localhost:8000/health
```

**Development Workflow**:
```bash
# Start services
make up

# Watch logs
make logs

# Run tests (in container)
make test

# Access database (in container)
make db-shell
# or
docker compose exec postgres psql -U myapp

# Stop services
make down

# Rebuild after dependency changes
make rebuild
# or
docker compose up -d --build
```

---

## Implementation Steps

### Phase 1: Core Foundation

**Step 1.1: Database Schema**

**Objective**: Create database tables and relationships

**Files to Create/Modify**:
- `migrations/001_create_users_table.sql`
- `models/user.py` or `models/user.ts`

**Implementation**:
```sql
-- Example migration
CREATE TABLE users (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    email VARCHAR(255) UNIQUE NOT NULL,
    password_hash VARCHAR(255) NOT NULL,
    created_at TIMESTAMP DEFAULT NOW(),
    updated_at TIMESTAMP DEFAULT NOW()
);

CREATE INDEX idx_users_email ON users(email);
```

**Validation**:
```bash
# Run migration
make migrate

# Verify schema
psql $DATABASE_URL -c "\d users"

# Expected output: Table with id, email, password_hash, timestamps
```

**Step 1.2: [Next Core Step]**

[Continue with implementation steps...]

---

### Phase 2: Business Logic

**Step 2.1: [Implementation Step]**

**Objective**: [What this step accomplishes]

**Files to Create/Modify**:
- `[file1.ext]`
- `[file2.ext]`

**Implementation**:
```python
# Example implementation
class UserService:
    def __init__(self, db: Database):
        self.db = db

    async def create_user(self, email: str, password: str) -> User:
        """Create a new user with hashed password."""
        password_hash = hash_password(password)
        user = await self.db.users.create(
            email=email,
            password_hash=password_hash
        )
        return user
```

**Why This Approach**:
- [Reason 1]
- [Reason 2]

**Alternative Approaches Considered**:
- **Approach A**: [Description] - Rejected because [reason]
- **Approach B**: [Description] - Rejected because [reason]

**Validation**:
```bash
# Test the implementation
pytest tests/test_user_service.py -v

# Manual testing
curl -X POST http://localhost:8000/users \
  -H "Content-Type: application/json" \
  -d '{"email": "test@example.com", "password": "secure123"}'
```

---

### Phase 3: API Layer

**Step 3.1: [API Implementation]**

[Continue with API implementation steps...]

---

### Phase 4: Testing

**Step 4.1: Unit Tests**

**Test Coverage Requirements**: >= 80%

**Files to Create**:
- `tests/unit/test_user_service.py`
- `tests/unit/test_auth.py`

**Implementation**:
```python
import pytest
from app.services.user_service import UserService

@pytest.fixture
def user_service(mock_db):
    return UserService(mock_db)

def test_create_user(user_service):
    """Test user creation with valid data."""
    user = await user_service.create_user(
        email="test@example.com",
        password="secure123"
    )
    assert user.email == "test@example.com"
    assert user.password_hash != "secure123"  # Should be hashed
```

**Running Tests**:
```bash
# Run all tests
pytest

# Run with coverage
pytest --cov=app --cov-report=term-missing

# Run specific test file
pytest tests/unit/test_user_service.py -v
```

**Step 4.2: Integration Tests**

[Continue with integration testing steps...]

**Step 4.3: E2E Tests**

[Continue with E2E testing steps...]

---

## Configuration

### Application Configuration

**File**: `config/app.yaml`

```yaml
app:
  name: "My Application"
  version: "1.0.0"

server:
  port: 8000
  host: "0.0.0.0"

logging:
  level: "info"
  format: "json"

database:
  pool_size: 20
  max_overflow: 10
  echo: false

auth:
  token_expiry: 3600  # 1 hour
  refresh_expiry: 2592000  # 30 days
```

### Docker Configuration

**File**: `docker-compose.yml` (V2 syntax with security hardening)

```yaml
# Bootstrap config (Infisical - Home/WSL only)
x-infisical-bootstrap: &infisical-bootstrap
  INFISICAL_URL: "https://secrets.turnersrus.com"
  INFISICAL_CLIENT_ID: "abc-123-def"
  INFISICAL_PROJECT_ID: "4fc89a1a..."

services:
  app:
    build:
      context: .
      args:
        # Enable tests in build (CI/CD should set to true)
        RUN_TESTS: "false"
    image: myapp:latest
    ports:
      - "8000:8000"
    user: "1000:1000"  # Run as non-root
    read_only: true    # Read-only filesystem
    tmpfs:
      - /tmp
      - /app/.cache
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    cap_add:
      - NET_BIND_SERVICE  # Only if needed for ports < 1024
    environment:
      <<: *infisical-bootstrap  # Bootstrap config (Home only)
      ENVIRONMENT: ${ENVIRONMENT:-development}
      REGION: ${REGION:-}  # Work only
    secrets:
      - infisical_client_secret  # Home only
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8000/health"]
      interval: 10s
      timeout: 5s
      retries: 3
      start_period: 30s
    restart: unless-stopped
    networks:
      - app-network

  postgres:
    image: postgres:17-alpine
    user: postgres
    read_only: true
    tmpfs:
      - /tmp
      - /var/run/postgresql
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    cap_add:
      - CHOWN
      - FOWNER
      - SETUID
      - SETGID
    environment:
      POSTGRES_DB: myapp
      POSTGRES_USER: myapp
      # For dev only - production uses secrets
      POSTGRES_PASSWORD: devpassword
    ports:
      - "5432:5432"
    volumes:
      - postgres_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U myapp"]
      interval: 5s
      timeout: 3s
      retries: 5
    restart: unless-stopped
    networks:
      - app-network

  redis:
    image: redis:7-alpine
    user: redis
    read_only: true
    tmpfs:
      - /tmp
      - /var/lib/redis
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    command: redis-server --save 60 1 --loglevel warning
    ports:
      - "6379:6379"
    volumes:
      - redis_data:/data
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 5s
      timeout: 3s
      retries: 5
    restart: unless-stopped
    networks:
      - app-network

volumes:
  postgres_data:
    driver: local
  redis_data:
    driver: local

secrets:
  # Home/Infisical only
  infisical_client_secret:
    file: ./secrets/infisical_client_secret

networks:
  app-network:
    driver: bridge
```

**File**: `Dockerfile` (multi-stage with Nix flakes)

```dockerfile
# Build stage (Nix-based)
FROM nixos/nix:latest AS builder

# Enable flakes
RUN echo "experimental-features = nix-command flakes" >> /etc/nix/nix.conf

WORKDIR /build

# Copy flake files
COPY flake.nix flake.lock ./

# Build dependencies
RUN nix build .#app --out-link result

# Copy source
COPY . .

# Build application
RUN nix build .#app

# Testing stage (optional, controlled by build arg)
FROM builder AS tester
ARG RUN_TESTS=false

RUN if [ "$RUN_TESTS" = "true" ]; then \
      nix develop -c pytest --cov=app --cov-report=term-missing; \
    fi

# Runtime stage (minimal, hardened)
FROM debian:bookworm-slim

# Create non-root user
RUN groupadd -r app -g 1000 && \
    useradd -r -g app -u 1000 -m -s /bin/bash app

# Install runtime dependencies only
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      ca-certificates \
      curl && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy built application from builder
COPY --from=builder --chown=app:app /build/result /app/

# Copy startup script
COPY --chown=app:app scripts/entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

# Switch to non-root user
USER app

# Health check
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD curl -f http://localhost:8000/health || exit 1

EXPOSE 8000

ENTRYPOINT ["/app/entrypoint.sh"]
CMD ["./app"]
```

**File**: `scripts/entrypoint.sh` (fetches secrets at startup)

```bash
#!/bin/bash
set -euo pipefail

# Detect environment
if [[ "$(uname -s)" == "Darwin" ]]; then
    # Work (macOS) - AWS Secrets Manager
    echo "Fetching secrets from AWS Secrets Manager..."

    # Use IAM role (no credentials needed)
    export AWS_REGION="${REGION}"

    # Fetch all secrets and export as environment variables
    SECRET_JSON=$(aws secretsmanager get-secret-value \
        --secret-id "myapp/${ENVIRONMENT}" \
        --query SecretString \
        --output text)

    # Export each secret as environment variable
    while IFS="=" read -r key value; do
        export "$key=$value"
    done < <(echo "$SECRET_JSON" | jq -r 'to_entries[] | "\(.key)=\(.value)"')

else
    # Home (WSL) - Infisical
    echo "Fetching secrets from Infisical..."

    # Read client secret from Docker secret
    INFISICAL_CLIENT_SECRET=$(cat /run/secrets/infisical_client_secret)

    # Fetch all secrets and export as environment variables
    # (Using infisical-cli or SDK)
    infisical export --format=dotenv \
        --url="$INFISICAL_URL" \
        --client-id="$INFISICAL_CLIENT_ID" \
        --client-secret="$INFISICAL_CLIENT_SECRET" \
        --project-id="$INFISICAL_PROJECT_ID" \
        --env="$ENVIRONMENT" | \
    while IFS="=" read -r key value; do
        export "$key=$value"
    done
fi

echo "Secrets loaded successfully"

# Run migrations if needed
if [[ "${RUN_MIGRATIONS:-false}" == "true" ]]; then
    echo "Running database migrations..."
    ./scripts/migrate.sh
fi

# Start application
echo "Starting application..."
exec "$@"
```

---

## Deployment

### Build Process

**Building the Application**:
```bash
# Build Docker image
docker build -t myapp:latest .

# Tag for registry
docker tag myapp:latest registry.example.com/myapp:1.0.0

# Push to registry
docker push registry.example.com/myapp:1.0.0
```

### Deployment Steps

**To Staging**:
```bash
# Deploy to staging
make deploy-staging

# Or manually
./scripts/deploy.sh staging

# Verify deployment
curl https://staging.example.com/health
```

**To Production**:
```bash
# Deploy to production
make deploy-prod

# Or manually
./scripts/deploy.sh production

# Run smoke tests
make smoke-test

# Monitor deployment
./scripts/monitor-deployment.sh
```

### Post-Deployment Verification

**Health Checks**:
```bash
# Check application health
curl https://api.example.com/health

# Expected response
{
  "status": "healthy",
  "version": "1.0.0",
  "database": "connected",
  "redis": "connected"
}
```

**Smoke Tests**:
```bash
# Run smoke tests
make smoke-test

# Or use script
./scripts/smoke-tests.sh production
```

---

## Troubleshooting

### Common Issues

**Issue 1: Database Connection Fails**

**Symptoms**:
- Error: "Could not connect to database"
- Application fails to start

**Diagnosis**:
```bash
# Check database status
docker compose ps postgres

# Check logs
docker compose logs postgres

# Test connection
psql $DATABASE_URL -c "SELECT 1"
```

**Solutions**:
1. Verify database is running: `docker compose up -d postgres`
2. Check DATABASE_URL is correct
3. Verify network connectivity
4. Check database credentials

**Issue 2: [Another Common Issue]**

[Continue with troubleshooting guide...]

---

## Testing

### Running Tests

**Unit Tests**:
```bash
# Run all unit tests
pytest tests/unit/

# With coverage
pytest tests/unit/ --cov=app
```

**Integration Tests**:
```bash
# Run integration tests
pytest tests/integration/

# Requires Docker
docker compose up -d postgres redis
pytest tests/integration/
```

**E2E Tests**:
```bash
# Run E2E tests
npm run test:e2e
# or
pytest tests/e2e/
```

### Test Coverage Requirements

- **Unit Tests**: >= 80% coverage
- **Integration Tests**: All API endpoints covered
- **E2E Tests**: All critical user flows covered

---

## Security Considerations

### Authentication & Authorization

**Implementation**:
- JWT tokens for authentication
- Role-based access control (RBAC)
- Token expiration: 1 hour
- Refresh token expiration: 30 days

**Best Practices**:
- ✅ Passwords hashed with bcrypt (cost factor: 12)
- ✅ HTTPS only in production
- ✅ CORS configured with whitelist
- ✅ Rate limiting on auth endpoints
- ✅ Input validation on all endpoints

### Secrets Management

**CRITICAL: ALL Secrets AND Config in Secrets Manager**

**What Goes in Secrets Manager**:
- ✅ **Application Secrets**: DATABASE_URL, JWT_SECRET, API_KEYS, REDIS_PASSWORD
- ✅ **Configuration**: LOG_LEVEL, PORT, WORKERS, POOL_SIZE, TIMEOUT_SECONDS
- ✅ **Third-party Credentials**: STRIPE_KEY, SENDGRID_KEY, AWS_ACCESS_KEY
- ✅ **Service Endpoints**: REDIS_HOST, ELASTIC_URL, S3_BUCKET
- ✅ **Feature Flags**: ENABLE_FEATURE_X, DEBUG_MODE

**What Goes in .env**:
```bash
# Work (macOS) - ONLY these
ENVIRONMENT=development
REGION=us-east-1

# Home (WSL) - ONLY this
ENVIRONMENT=development
```

**What Goes in docker-compose.yml** (Home/Infisical only):
```yaml
# Bootstrap config (defined ONCE with YAML anchor)
x-infisical-bootstrap: &infisical-bootstrap
  INFISICAL_URL: "https://secrets.turnersrus.com"
  INFISICAL_CLIENT_ID: "abc-123-def"
  INFISICAL_PROJECT_ID: "4fc89a1a..."

# Never Commit:
# - Client secret goes in Docker secret file: secrets/infisical_client_secret
```

**Secrets Lifecycle**:
1. **Store** in secrets manager (Infisical UI or AWS Console)
2. **Fetch** at container startup (entrypoint.sh)
3. **Hold** in memory only (never write to disk)
4. **Use** via environment variables in application
5. **Never log** secrets (sanitize logs)
6. **Rotate** regularly (quarterly or after exposure)

**Adding New Secrets**:
```bash
# Home (Infisical)
# Add via Infisical UI: https://secrets.turnersrus.com
# Select project, environment, add key-value pair

# Work (AWS)
# Add via AWS Console or CLI
aws secretsmanager update-secret \
    --secret-id "myapp/development" \
    --secret-string '{"NEW_KEY": "value", "DATABASE_URL": "..."}'

# Restart containers to pick up new secrets
docker compose restart app
```

**Never Commit to Git**:
- ❌ API keys, passwords, tokens
- ❌ Database connection strings
- ❌ JWT secrets, encryption keys
- ❌ Third-party credentials
- ❌ `.env` files with secrets (only `.env.example` with placeholders)

**Secrets Rotation**:
- Rotate quarterly (every 3 months)
- Rotate immediately after:
  - Employee departure
  - Security incident
  - Suspected compromise
- Use `/rotate-secret` command for rotation workflow

### Data Protection

**At Rest**:
- Database encryption enabled (PostgreSQL with pgcrypto)
- Sensitive fields encrypted (PII, credit cards)
- Backups encrypted (AES-256)
- Secrets stored encrypted (secrets manager handles this)

**In Transit**:
- HTTPS/TLS 1.3 only (no TLS 1.0/1.1/1.2)
- Certificate pinning (mobile apps)
- Secure WebSocket connections (wss://)
- Internal service communication over encrypted channels

**In Memory**:
- Secrets held in memory only (never written to disk)
- Sanitize logs (never log secrets)
- Clear sensitive data after use
- No core dumps of sensitive processes

---

## Performance Optimization

### Database Optimization

**Indexes**:
```sql
-- Add indexes for frequently queried fields
CREATE INDEX idx_users_email ON users(email);
CREATE INDEX idx_orders_user_id ON orders(user_id);
CREATE INDEX idx_orders_created_at ON orders(created_at);
```

**Query Optimization**:
- Use connection pooling (pool size: 20)
- Implement caching for frequent queries
- Use database query analysis tools

### Caching Strategy

**Redis Caching**:
```python
# Cache frequently accessed data
@cache(ttl=300)  # 5 minutes
async def get_user_profile(user_id: str) -> UserProfile:
    return await db.users.get(user_id)
```

**Cache Invalidation**:
- Invalidate on user update
- TTL-based expiration
- Manual cache clear on critical updates

### Application Performance

**Async Operations**:
- Use async/await for I/O operations
- Parallel API calls when possible
- Background job processing for heavy tasks

**Resource Limits**:
- Connection pool size: 20
- Max concurrent requests: 100
- Request timeout: 30 seconds

---

## Monitoring & Observability

### Logging

**Structured Logging**:
```python
logger.info("User created", extra={
    "user_id": user.id,
    "email": user.email,
    "timestamp": datetime.now().isoformat()
})
```

**Log Levels**:
- **ERROR**: Application errors, exceptions
- **WARN**: Degraded performance, recoverable errors
- **INFO**: User actions, API requests
- **DEBUG**: Detailed execution flow (dev only)

### Metrics

**Application Metrics**:
- Request rate (requests/second)
- Response time (p50, p95, p99)
- Error rate (%)
- Database connection pool usage

**Business Metrics**:
- User registrations
- Active sessions
- API usage by endpoint

### Alerts

**Critical Alerts**:
- Error rate > 5%
- Response time > 2 seconds (p95)
- Database connection failures
- Disk usage > 90%

---

## Maintenance

### Regular Tasks

**Daily**:
- Monitor error logs
- Check system health
- Review performance metrics

**Weekly**:
- Review and optimize slow queries
- Update dependencies (security patches)
- Check backup integrity

**Monthly**:
- Security audit
- Performance review
- Capacity planning

### Database Maintenance

**Backups**:
```bash
# Manual backup
pg_dump $DATABASE_URL > backup_$(date +%Y%m%d).sql

# Verify backup
pg_restore --list backup_$(date +%Y%m%d).sql
```

**Migrations**:
```bash
# Create new migration
./scripts/create-migration.sh "add_user_preferences"

# Run migrations
./scripts/migrate.sh

# Rollback if needed
./scripts/migrate.sh --rollback
```

---

## Code Style & Standards

### Code Formatting

**Python**:
- Formatter: Ruff
- Type checking: Pyright
- Line length: 100 characters

**TypeScript/JavaScript**:
- Formatter: Prettier
- Linter: ESLint
- Type checking: TypeScript strict mode

### Naming Conventions

**Variables & Functions**:
- Python: `snake_case`
- TypeScript: `camelCase`
- Constants: `UPPER_SNAKE_CASE`

**Files & Directories**:
- `kebab-case` for filenames
- Lowercase for directories

### Documentation

**Code Comments**:
- Explain WHY, not WHAT
- Document complex algorithms
- Add docstrings to all functions

**API Documentation**:
- OpenAPI/Swagger for REST APIs
- GraphQL schema documentation
- Include examples for all endpoints

---

## Docker Security Hardening (REQUIRED)

**All containers must follow these security requirements**:

### Non-Root User
```yaml
services:
  app:
    user: "1000:1000"  # Run as non-root
```

```dockerfile
# In Dockerfile
RUN groupadd -r app -g 1000 && \
    useradd -r -g app -u 1000 -m -s /bin/bash app
USER app
```

### Read-Only Filesystem
```yaml
services:
  app:
    read_only: true  # Root filesystem read-only
    tmpfs:           # Writable temp directories
      - /tmp
      - /app/.cache
      - /var/log
```

### Drop Capabilities
```yaml
services:
  app:
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    cap_add:
      - NET_BIND_SERVICE  # Only add what's absolutely needed
```

### Resource Limits
```yaml
services:
  app:
    deploy:
      resources:
        limits:
          cpus: '1.0'
          memory: 512M
        reservations:
          cpus: '0.5'
          memory: 256M
    ulimits:
      nofile:
        soft: 65536
        hard: 65536
      nproc:
        soft: 1024
        hard: 1024
      core: 0  # Disable core dumps
```

### Health Checks
```yaml
services:
  app:
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8000/health"]
      interval: 10s
      timeout: 5s
      retries: 3
      start_period: 30s
```

### Restart Policy
```yaml
services:
  app:
    restart: unless-stopped  # or "on-failure:3"
```

### Network Isolation
```yaml
services:
  app:
    networks:
      - app-network  # Isolated network

networks:
  app-network:
    driver: bridge
    internal: false  # Set to true for fully isolated internal services
```

---

## Best Practices

### Development Workflow

**CRITICAL: Docker-Only Development**
1. **Setup**: Clone repo, start containers (`make up`)
2. **Feature Branch**: Create branch from main
3. **Implementation**: Write code, run in Docker
4. **Tests**: Write tests (TDD preferred), run in Docker (`make test`)
5. **Local Validation**: All tests and linting in Docker
6. **Code Review**: Create PR/MR for review
7. **CI/CD**: Automated checks pass (tests run with RUN_TESTS=true)
8. **Merge**: Squash merge to main
9. **Deploy**: Deploy through CI/CD pipeline

**Never on Host**:
- ❌ Don't run `npm install` or `pip install` on host
- ❌ Don't run application on host
- ❌ Don't run tests on host
- ✅ Everything runs in Docker containers

### Git Commit Messages

**Format**: `type(scope): description`

**Types**:
- `feat`: New feature
- `fix`: Bug fix
- `docs`: Documentation
- `refactor`: Code refactoring
- `test`: Add/update tests
- `chore`: Maintenance

**Example**:
```
feat(auth): add password reset functionality

- Add password reset endpoint
- Send reset email with token
- Add token validation
- Add tests for reset flow
```

### Code Review Checklist

**Before Requesting Review**:
- [ ] All tests passing
- [ ] Code coverage >= 80%
- [ ] No linting errors
- [ ] Documentation updated
- [ ] Self-review completed

**For Reviewers**:
- [ ] Code follows style guide
- [ ] Logic is sound and efficient
- [ ] Edge cases handled
- [ ] Tests are comprehensive
- [ ] Security considerations addressed

---

## Reference Materials

### Documentation

**Internal**:
- Architecture Decision Records (ADRs): `docs/adr/`
- API Documentation: `docs/api/`
- Database Schema: `docs/database/`

**External**:
- [Technology Documentation Links]
- [Third-party Service Docs]
- [Best Practices Guides]

### Related Documents

**For This Work Item** ([TASK_ID]):
- TSK: [TASK_ID-DATETIME-TSK-description.md] - Original task
- PLN: [TASK_ID-DATETIME-PLN-description.md] - Implementation plan
- RSC: [TASK_ID-DATETIME-RSC-description.md] - Research findings

### Key Reference Documentation

**Development Guidelines**:
- `~/.claude/CLAUDE.md` - Complete development guidelines (READ FIRST)
- `~/.claude/docs/docker.md` - Docker development guide
- `~/.claude/docs/secrets-management.md` - Secrets management principles
- `~/.claude/docs/testing.md` - Testing best practices
- `~/.claude/docs/python.md` - Python-specific guidelines
- `~/.claude/docs/nextjs.md` - Next.js-specific guidelines

**Secrets Management**:
- `~/.claude/docs/reference/secrets-home.md` - Infisical setup (Home/WSL)
- `~/.claude/docs/reference/secrets-work.md` - AWS Secrets setup (Work/macOS)

**CI/CD & Deployment**:
- `~/.claude/docs/pipelines.md` - CI/CD pipeline guide
- `~/.claude/docs/version-management.md` - Version management guide
- `~/.claude/scripts/DEPLOYMENT_SCRIPTS.md` - Deployment scripts documentation

**Commands & Skills**:
- `/dockerfile-build` - Create new Dockerfile with security hardening
- `/docker-hardening` - Audit and improve Docker security
- `/add-secret` - Add new secret to secrets manager
- `/rotate-secret` - Rotate existing secret
- `/add-dependency` - Add dependency with license and security checks

---

## Appendix

### Glossary

- **[Term 1]**: [Definition]
- **[Term 2]**: [Definition]
- **[Term 3]**: [Definition]

### Code Examples Repository

**Full Examples**: See `examples/` directory in repository

**Quick Reference**:
```bash
# Clone examples
git clone <repository-url>
cd examples/

# Run example
./run-example.sh authentication
```

### Tools & Resources

**Development Tools**:
- IDE: VS Code with recommended extensions
- Database Client: DBeaver or TablePlus
- API Testing: Postman or Insomnia
- Docker Desktop for container management

**Useful Commands**:
```bash
# View logs
make logs

# Database shell
make db-shell

# Run linting
make lint

# Format code
make format

# Full test suite
make test-all
```

---

**Implementation Guide Completed**: [YYYY-MM-DD HH:MM]
**Status**: ✓ Ready for Implementation
