# Docker — Work (macOS / GitHub / AWS)

Work environment specifics for Docker development. For global standards (security hardening,
multi-stage builds, health checks, base images), see the [Docker Development Guide](docker.md).

**Environment:** macOS, GitHub Actions, AWS staging/production

---

## Environment Variables

### Container Environment Variables

Passed into running containers via the `environment:` key. **Only these are allowed:**

| Variable | Purpose |
|----------|---------|
| `ENVIRONMENT` | Environment identifier (`development`, `staging`, `production`) |
| `REGION` | AWS region (`us-west-1`, etc.) |

**Nothing else goes in `environment:`.** All config and secrets are fetched from
AWS Secrets Manager at container startup via IAM role (servers) or `~/.aws` (local dev).

### Compose Interpolation Variables

Used by Docker Compose to resolve `image:` references. **Not passed to containers.**

| Variable | Purpose | Local `.env` | Server `.env` |
|----------|---------|--------------|---------------|
| `ENVIRONMENT` | Environment identifier | Yes | Yes |
| `REGION` | AWS region | Yes | Yes |
| `ECR_REGISTRY` | AWS ECR registry URL | No | Yes |
| `ECR_REPO` | Image repository (single-service) | No | Yes |
| `ECR_PROJECT` | Image repository prefix (multi-service) | No | Yes |
| `IMAGE_TAG` | Image version tag | No | Yes |

**`ECR_REPO` vs `ECR_PROJECT`:**
- **Single-service** projects: `ECR_REPO` holds the full repo path (e.g., `my-org/my-project`)
- **Multi-service** projects: `ECR_PROJECT` holds the prefix; each service appends its name
  (e.g., `my-org/my-project` becomes `my-org/my-project/frontend`, `my-org/my-project/backend`)

---

## .env Files

**Local `.env`:**
```bash
ENVIRONMENT=development
REGION=us-west-1
```

**Server `.env` (written by deploy script):**
```bash
ENVIRONMENT=staging
REGION=us-west-1
ECR_REGISTRY=123456.dkr.ecr.us-west-1.amazonaws.com
IMAGE_TAG=0.53.0-staging.1234
```

`ECR_REGISTRY` and `IMAGE_TAG` appear on servers because they're needed for
`docker compose pull` to resolve the `image:` field. They are compose-interpolation
variables, not container environment variables.

---

## Secrets Integration (AWS Secrets Manager)

**Servers:** Containers authenticate via IAM role. No credentials in compose or .env.

**Local dev:** Override mounts `~/.aws` for AWS CLI/SDK access:

```yaml
# In docker-compose.override.yml
services:
  my-project-app:
    volumes:
      - ~/.aws:/home/app/.aws:ro
```

### Dev Infrastructure Secrets

Dev databases get credentials via Docker secrets. Fetch values from AWS Secrets Manager
to local files, then reference them in the override.

**Bootstrap local dev secrets:**
```bash
# Fetch dev secrets from AWS Secrets Manager to local files
mkdir -p ~/.secrets/my-project
aws secretsmanager get-secret-value --secret-id my-project/dev/db-root-password \
  --query SecretString --output text > ~/.secrets/my-project/db-root-password
aws secretsmanager get-secret-value --secret-id my-project/dev/db-name \
  --query SecretString --output text > ~/.secrets/my-project/db-name
```

**Override references local secret files:**
```yaml
# In docker-compose.override.yml
secrets:
  db_root_password:
    file: ~/.secrets/my-project/db-root-password
  db_name:
    file: ~/.secrets/my-project/db-name

services:
  my-project-db:
    environment:
      MYSQL_ROOT_PASSWORD_FILE: /run/secrets/db_root_password
      MYSQL_DATABASE_FILE: /run/secrets/db_name
    secrets:
      - db_root_password
      - db_name
```

---

## Compose Patterns

### Image Tag Pattern

**Single-service:**
```yaml
image: ${ECR_REGISTRY:-}${ECR_REGISTRY:+/}${ECR_REPO:-my-org/my-project}:${IMAGE_TAG:-dev}
```
- Local: resolves to `my-org/my-project:dev` (builds locally)
- Server: resolves to `123456.dkr.ecr.us-west-1.amazonaws.com/my-org/my-project:0.53.0-staging.1234`

**Multi-service:**
```yaml
image: ${ECR_REGISTRY:-}${ECR_REGISTRY:+/}${ECR_PROJECT:-my-org/my-project}/frontend:${IMAGE_TAG:-dev}
```
- Local: resolves to `my-org/my-project/frontend:dev`
- Server: resolves to `123456.dkr.ecr.us-west-1.amazonaws.com/my-org/my-project/frontend:0.53.0-staging.1234`

### Single-Service Project

**Base (`docker-compose.yml`):**

```yaml
name: my-project

networks:
  my-project-public:
    driver: bridge
  my-project-private:
    driver: bridge

volumes:
  app-data:

services:
  my-project-app:
    image: ${ECR_REGISTRY:-}${ECR_REGISTRY:+/}${ECR_REPO:-my-org/my-project}:${IMAGE_TAG:-dev}
    build:
      context: .
      dockerfile: Dockerfile
      target: production
    container_name: my-project-app
    restart: unless-stopped
    networks:
      - my-project-public
      - my-project-private
    ports:
      - "3001:3001"

    # Security hardening
    read_only: true
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    deploy:
      resources:
        limits:
          memory: 512M
          cpus: '1.0'
        reservations:
          memory: 256M
          cpus: '0.25'
    tmpfs:
      - /tmp:noexec,nosuid,size=64m
    volumes:
      - app-data:/app/data

    environment:
      - ENVIRONMENT=${ENVIRONMENT:-development}
      - REGION=${REGION:-us-west-1}

    healthcheck:
      test: ["CMD", "node", "/app/healthcheck.cjs"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 30s
```

**Override (`docker-compose.override.yml`):**

```yaml
# Local Development Overrides — Work Environment (macOS / AWS)
# Automatically merged by docker compose. NOT deployed to servers.

networks:
  traefik-public:
    external: true
    name: traefik-public

volumes:
  my-db-data:

secrets:
  db_root_password:
    file: ~/.secrets/my-project/db-root-password
  db_name:
    file: ~/.secrets/my-project/db-name

services:
  my-project-app:
    ports: !reset []
    networks:
      - my-project-public
      - my-project-private
      - traefik-public
    volumes:
      - app-data:/app/data
      - ~/.aws:/home/app/.aws:ro
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.my-project.rule=Host(`my-project.localhost`)"
      - "traefik.http.services.my-project.loadbalancer.server.port=3001"
      - "traefik.docker.network=traefik-public"
    depends_on:
      my-project-db:
        condition: service_healthy

  # Dev-only infrastructure
  my-project-db:
    image: mysql:8.4
    container_name: my-project-db
    restart: unless-stopped
    networks:
      - my-project-private
    volumes:
      - my-db-data:/var/lib/mysql
    environment:
      MYSQL_ROOT_PASSWORD_FILE: /run/secrets/db_root_password
      MYSQL_DATABASE_FILE: /run/secrets/db_name
    secrets:
      - db_root_password
      - db_name
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 30s
```

### Multi-Service Project

**Base (`docker-compose.yml`):**

```yaml
name: my-project

networks:
  my-project-public:
    driver: bridge
  my-project-private:
    driver: bridge

volumes:
  redis-data:

services:
  # --- Application Services ---

  my-project-frontend:
    image: ${ECR_REGISTRY:-}${ECR_REGISTRY:+/}${ECR_PROJECT:-my-org/my-project}/frontend:${IMAGE_TAG:-dev}
    container_name: my-project-frontend
    restart: unless-stopped
    networks:
      - my-project-public
    ports:
      - "3000:3000"  # Exposed for nginx/LB on server

    read_only: true
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    deploy:
      resources:
        limits:
          memory: 512M
          cpus: '1.0'
        reservations:
          memory: 256M
          cpus: '0.25'
    tmpfs:
      - /tmp:noexec,nosuid,size=64m
      - /app/frontend/.next:uid=1000,gid=1000,size=256m

    environment:
      - ENVIRONMENT=${ENVIRONMENT:-development}
      - REGION=${REGION:-us-west-1}

    healthcheck:
      test: ["CMD", "node", "/app/healthcheck.cjs"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 15s

    depends_on:
      my-project-backend:
        condition: service_healthy

  my-project-backend:
    image: ${ECR_REGISTRY:-}${ECR_REGISTRY:+/}${ECR_PROJECT:-my-org/my-project}/backend:${IMAGE_TAG:-dev}
    container_name: my-project-backend
    restart: unless-stopped
    networks:
      - my-project-public
      - my-project-private
    # NO ports — internal only, frontend proxies to it

    read_only: true
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    deploy:
      resources:
        limits:
          memory: 512M
          cpus: '1.0'
        reservations:
          memory: 256M
          cpus: '0.25'
    tmpfs:
      - /tmp:noexec,nosuid,size=64m

    environment:
      - ENVIRONMENT=${ENVIRONMENT:-development}
      - REGION=${REGION:-us-west-1}

    healthcheck:
      test: ["CMD", "python", "-c", "import urllib.request; urllib.request.urlopen('http://localhost:8000/health')"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 40s

    depends_on:
      my-project-redis:
        condition: service_healthy

  my-project-worker:
    image: ${ECR_REGISTRY:-}${ECR_REGISTRY:+/}${ECR_PROJECT:-my-org/my-project}/backend:${IMAGE_TAG:-dev}
    container_name: my-project-worker
    restart: unless-stopped
    command: ["python", "-m", "celery", "-A", "app.celery_app", "worker"]
    networks:
      - my-project-private
    # NO ports — background worker

    read_only: true
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    deploy:
      resources:
        limits:
          memory: 768M
          cpus: '1.0'
        reservations:
          memory: 384M
          cpus: '0.25'
    tmpfs:
      - /tmp:noexec,nosuid,size=64m

    environment:
      - ENVIRONMENT=${ENVIRONMENT:-development}
      - REGION=${REGION:-us-west-1}

    healthcheck:
      test: ["CMD-SHELL", "celery -A app.celery_app inspect ping --timeout 5"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 20s

    depends_on:
      my-project-backend:
        condition: service_healthy
      my-project-redis:
        condition: service_healthy

  # --- Shared Infrastructure (runs in all environments) ---

  my-project-redis:
    image: redis:7.4-alpine
    container_name: my-project-redis
    restart: unless-stopped
    networks:
      - my-project-private
    # NO ports — private only
    volumes:
      - redis-data:/data

    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 10s
```

**Override (`docker-compose.override.yml`):**

```yaml
# Local Development Overrides — Work Environment (macOS / AWS)
# Automatically merged by docker compose. NOT deployed to servers.

networks:
  traefik-public:
    external: true
    name: traefik-public

volumes:
  mysql-data:

secrets:
  db_root_password:
    file: ~/.secrets/my-project/db-root-password
  db_name:
    file: ~/.secrets/my-project/db-name

services:
  # --- Traefik + AWS creds on all app services ---

  my-project-frontend:
    ports: !reset []
    networks:
      - my-project-public
      - traefik-public
    volumes:
      - ~/.aws:/home/app/.aws:ro
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.my-project-frontend.rule=Host(`my-project.localhost`)"
      - "traefik.http.services.my-project-frontend.loadbalancer.server.port=3000"
      - "traefik.docker.network=traefik-public"
    depends_on:
      my-project-db:
        condition: service_healthy

  my-project-backend:
    networks:
      - my-project-public
      - my-project-private
      - traefik-public
    volumes:
      - ~/.aws:/home/app/.aws:ro
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.my-project-backend.rule=Host(`api.my-project.localhost`)"
      - "traefik.http.services.my-project-backend.loadbalancer.server.port=8000"
      - "traefik.docker.network=traefik-public"
    depends_on:
      my-project-db:
        condition: service_healthy

  my-project-worker:
    volumes:
      - ~/.aws:/home/app/.aws:ro

  # --- Dev-only infrastructure ---

  my-project-db:
    image: mysql:8.4
    container_name: my-project-db
    restart: unless-stopped
    networks:
      - my-project-private
    volumes:
      - mysql-data:/var/lib/mysql
    environment:
      MYSQL_ROOT_PASSWORD_FILE: /run/secrets/db_root_password
      MYSQL_DATABASE_FILE: /run/secrets/db_name
    secrets:
      - db_root_password
      - db_name
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 30s
```

---

## CI/CD (GitHub Actions)

### Build and Push

```yaml
- name: Build and push Docker image
  uses: docker/build-push-action@v5
  with:
    context: .
    push: true
    build-args: |
      RUN_TESTS=true
      BUILD_VERSION=${{ steps.version.outputs.next }}
    cache-from: type=gha
    cache-to: type=gha,mode=max
```

### Image Scanning

```yaml
- name: Scan image for vulnerabilities
  uses: aquasecurity/trivy-action@master
  with:
    image-ref: ${{ steps.build.outputs.image }}
    severity: HIGH,CRITICAL
    exit-code: 1
    ignore-unfixed: true
```

---

## Checklist (Work-Specific)

In addition to the [global checklist](docker.md#checklist):

### Compose — Base
- [ ] `ENVIRONMENT` and `REGION` in container `environment:` with defaults
- [ ] Image tags use `ECR_REGISTRY`/`ECR_REPO` (single) or `ECR_PROJECT` (multi) interpolation
- [ ] No AWS credentials, IAM references, or secret values in base compose
- [ ] No Infisical references (wrong environment)

### Compose — Override
- [ ] `~/.aws:/home/app/.aws:ro` volume mount on all app services
- [ ] Dev database credentials via Docker secrets (`_FILE` mechanism)
- [ ] Secret files sourced from `~/.secrets/<project>/`
- [ ] No hardcoded credentials anywhere

### CI/CD
- [ ] GitHub Actions uses `docker/build-push-action` with BuildKit cache (`type=gha`)
- [ ] `RUN_TESTS=true` passed as build arg
- [ ] Trivy image scan before registry push
- [ ] ECR login step before push

### .env Files
- [ ] Local `.env`: `ENVIRONMENT=development`, `REGION=us-west-1` (and nothing else)
- [ ] `.env.example` committed to git with same structure
- [ ] Server `.env` pattern documented for deploy scripts
