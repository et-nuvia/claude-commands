# Upgrade Docker Compose V1 to V2

Migrate docker-compose files from V1 syntax to V2/V3 with security hardening.

---

## Context

Docker Compose V1 (`docker-compose`) is deprecated. This prompt migrates to V2 (`docker compose`) with modern syntax and security best practices.

---

## Prerequisites

- Docker Compose V2 installed (`docker compose version`)
- Existing docker-compose.yml files

---

## Prompt

```
I want to upgrade this project's Docker Compose configuration from V1 to V2 syntax with security hardening.

## Analysis Phase

1. **Find all compose files:**
   - `docker-compose.yml`
   - `docker-compose.override.yml`
   - `docker-compose.dev.yml`
   - `docker-compose.prod.yml`
   - `docker-compose.test.yml`

2. **Identify V1 patterns to update:**
   - `version: "2"` or `version: "3.x"` (remove entirely in V2)
   - `links:` (deprecated, use networks)
   - `volumes_from:` (deprecated)
   - `extends:` (use YAML anchors or multiple files)
   - `container_name:` (often unnecessary)
   - `expose:` vs `ports:` usage

3. **Check for security issues:**
   - Services running as root
   - No resource limits
   - Privileged containers
   - Sensitive data in environment
   - Writable root filesystem

## Migration Steps

### Step 1: Remove version field

**Before:**
```yaml
version: "3.8"
services:
  app:
    ...
```

**After:**
```yaml
services:
  app:
    ...
```

### Step 2: Replace deprecated features

**links → networks:**
```yaml
# Before
services:
  app:
    links:
      - db

# After
services:
  app:
    networks:
      - backend
  db:
    networks:
      - backend

networks:
  backend:
```

**volumes_from → named volumes:**
```yaml
# Before
services:
  app:
    volumes_from:
      - data

# After
services:
  app:
    volumes:
      - app-data:/data

volumes:
  app-data:
```

### Step 3: Add security hardening

For EVERY service, add these security settings:

```yaml
services:
  app:
    image: myapp:1.0.0
    user: "1000:1000"
    read_only: true
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    # Only add capabilities that are strictly needed
    # cap_add:
    #   - NET_BIND_SERVICE
    tmpfs:
      - /tmp:noexec,nosuid,size=100m
    deploy:
      resources:
        limits:
          cpus: '1.0'
          memory: 512M
        reservations:
          cpus: '0.25'
          memory: 128M
    ulimits:
      core:
        soft: 0
        hard: 0
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8000/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s
```

### Step 4: Update environment variables

Move secrets out of compose file:

**Before:**
```yaml
services:
  app:
    environment:
      - DATABASE_URL=postgresql://user:password@db:5432/myapp
      - API_KEY=secret123
```

**After:**
```yaml
services:
  app:
    environment:
      - ENVIRONMENT=${ENVIRONMENT:-development}
      - REGION=${REGION:-us-east-1}
    # Secrets fetched from AWS Secrets Manager in application
```

### Step 5: Use healthchecks instead of depends_on conditions

**Before:**
```yaml
services:
  app:
    depends_on:
      db:
        condition: service_healthy
```

**After (V2 supports this but prefer startup scripts):**
```yaml
services:
  app:
    depends_on:
      - db
    # Use wait-for-it.sh or similar in entrypoint
    command: ["./scripts/wait-for-it.sh", "db:5432", "--", "python", "main.py"]
```

### Step 6: Network isolation

```yaml
services:
  app:
    networks:
      - frontend
      - backend

  db:
    networks:
      - backend  # Not accessible from frontend

  nginx:
    networks:
      - frontend
    ports:
      - "80:80"

networks:
  frontend:
  backend:
    internal: true  # No external access
```

### Step 7: Update all scripts and documentation

Replace `docker-compose` with `docker compose`:

```bash
# Before
docker-compose up -d
docker-compose exec app bash

# After
docker compose up -d
docker compose exec app bash
```

Update:
- Makefile
- CI/CD pipelines
- README.md
- Any shell scripts

## Full Example

**Before (V1):**
```yaml
version: "3.7"

services:
  app:
    build: .
    container_name: myapp
    links:
      - db
      - redis
    environment:
      - DATABASE_URL=postgresql://user:pass@db:5432/myapp
      - REDIS_URL=redis://redis:6379
    ports:
      - "8000:8000"
    volumes:
      - .:/app

  db:
    image: postgres:15
    environment:
      - POSTGRES_PASSWORD=pass

  redis:
    image: redis:7
```

**After (V2 with hardening):**
```yaml
services:
  app:
    build:
      context: .
      args:
        RUN_TESTS: "false"
    user: "1000:1000"
    read_only: true
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    tmpfs:
      - /tmp:noexec,nosuid,size=100m
    environment:
      - ENVIRONMENT=${ENVIRONMENT:-development}
      - REGION=${REGION:-us-east-1}
    expose:
      - "8000"
    networks:
      - frontend
      - backend
    depends_on:
      - db
      - redis
    deploy:
      resources:
        limits:
          cpus: '1.0'
          memory: 512M
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8000/health"]
      interval: 30s
      timeout: 10s
      retries: 3

  db:
    image: postgres:15-alpine
    user: "999:999"
    read_only: true
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    tmpfs:
      - /tmp:noexec,nosuid
      - /run/postgresql:noexec,nosuid
    volumes:
      - postgres-data:/var/lib/postgresql/data
    networks:
      - backend
    deploy:
      resources:
        limits:
          cpus: '0.5'
          memory: 256M
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 10s
      timeout: 5s
      retries: 5

  redis:
    image: redis:7-alpine
    user: "999:999"
    read_only: true
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    tmpfs:
      - /data:noexec,nosuid,size=100m
    networks:
      - backend
    deploy:
      resources:
        limits:
          cpus: '0.25'
          memory: 128M
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5

  nginx:
    image: nginx:alpine
    user: "101:101"
    read_only: true
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    cap_add:
      - NET_BIND_SERVICE
    tmpfs:
      - /tmp:noexec,nosuid
      - /var/cache/nginx:noexec,nosuid
      - /run:noexec,nosuid
    ports:
      - "80:80"
    networks:
      - frontend
    depends_on:
      - app

networks:
  frontend:
  backend:
    internal: true

volumes:
  postgres-data:
```

## Validation

After migration:
- `docker compose up -d` starts all services
- `docker compose ps` shows all healthy
- Application works correctly
- `docker compose exec app id` shows non-root user
- No secrets in `docker compose config` output

Now analyze this project and upgrade to Docker Compose V2 with security hardening.
```

---

## Rollback

If migration causes issues:
1. `git checkout -- docker-compose*.yml`
2. Revert script changes
