# Docker — Home (WSL / GitLab / Infisical)

Home environment specifics for Docker development. For global standards (security hardening,
multi-stage builds, health checks, base images), see the [Docker Development Guide](docker.md).

**Environment:** WSL, GitLab CI, Unraid staging, Unraid/Proxmox/GCP production

---

## Environment Variables

### Container Environment Variables

Passed into running containers via the `environment:` key. **Only these are allowed:**

| Variable | Purpose |
|----------|---------|
| `ENVIRONMENT` | Environment identifier (`development`, `staging`, `production`) |

Plus Infisical bootstrap variables (defined once via YAML anchor, referenced by all services):

| Variable | Purpose |
|----------|---------|
| `INFISICAL_URL` | Infisical server URL |
| `INFISICAL_CLIENT_ID` | Machine identity client ID |
| `INFISICAL_PROJECT_ID` | Infisical project identifier |

**Nothing else goes in `environment:`.** All config and secrets are fetched from
Infisical at container startup.

### Compose Interpolation Variables

Used by Docker Compose to resolve `image:` references. **Not passed to containers.**

| Variable | Purpose | Local `.env` | Server `.env` |
|----------|---------|--------------|---------------|
| `ENVIRONMENT` | Environment identifier | Yes | Yes |
| `REGISTRY` | Docker registry URL | No | Yes |
| `IMAGE_REPO` | Image repository (single-service) | No | Yes |
| `IMAGE_PROJECT` | Image repository prefix (multi-service) | No | Yes |
| `IMAGE_TAG` | Image version tag | No | Yes |

**`IMAGE_REPO` vs `IMAGE_PROJECT`:**
- **Single-service** projects: `IMAGE_REPO` holds the full repo path (e.g., `my-project`)
- **Multi-service** projects: `IMAGE_PROJECT` holds the prefix; each service appends its name
  (e.g., `my-project` becomes `my-project/frontend`, `my-project/backend`)

---

## .env Files

**Local `.env`:**
```bash
ENVIRONMENT=development
```

**Server `.env` (written by deploy script):**
```bash
ENVIRONMENT=staging
REGISTRY=docker.example.com
IMAGE_TAG=0.53.0-staging.1234
```

`REGISTRY` and `IMAGE_TAG` appear on servers because they're needed for
`docker compose pull` to resolve the `image:` field. They are compose-interpolation
variables, not container environment variables.

---

## Secrets Integration (Infisical)

### Bootstrap Configuration

Infisical bootstrap config is defined **once** in `docker-compose.yml` using a YAML anchor
and referenced by all application services. This is the only config in compose beyond
`ENVIRONMENT`.

```yaml
# In docker-compose.yml
x-infisical-bootstrap: &infisical-bootstrap
  INFISICAL_URL: "https://secrets.example.com"
  INFISICAL_CLIENT_ID: "abc-123-def"
  INFISICAL_PROJECT_ID: "4fc89a1a..."
```

### Docker Secrets for Client Secret

The Infisical client secret is **never** in compose as plain text. It's loaded via
Docker secrets mechanism.

**Server path** (deploy script creates this):
```yaml
# In docker-compose.yml
secrets:
  infisical_client_secret:
    file: ./secrets/infisical_client_secret
```

**Local dev path** (override changes the path):
```yaml
# In docker-compose.override.yml
secrets:
  infisical_client_secret:
    file: ~/.infisical/client-secret
```

### Service Integration

Every application service references the anchor and the secret:

```yaml
services:
  my-app:
    environment:
      - ENVIRONMENT=${ENVIRONMENT:-development}
      <<: *infisical-bootstrap
    secrets:
      - infisical_client_secret
```

### Dev Infrastructure Secrets

Dev databases get credentials via Docker secrets. Fetch values from Infisical
to local files, then reference them in the override.

**Bootstrap local dev secrets:**
```bash
# Fetch dev secrets from Infisical to local files
mkdir -p ~/.secrets/my-project
infisical export --env=dev --path=/my-project \
  --format=dotenv | grep DB_ROOT_PASSWORD | cut -d= -f2 > ~/.secrets/my-project/db-root-password
infisical export --env=dev --path=/my-project \
  --format=dotenv | grep DB_NAME | cut -d= -f2 > ~/.secrets/my-project/db-name
```

**Override references local secret files:**
```yaml
# In docker-compose.override.yml
secrets:
  infisical_client_secret:
    file: ~/.infisical/client-secret
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
image: ${REGISTRY:-}${REGISTRY:+/}${IMAGE_REPO:-my-project}:${IMAGE_TAG:-dev}
```
- Local: resolves to `my-project:dev` (builds locally)
- Server: resolves to `docker.example.com/my-project:0.53.0-staging.1234`

**Multi-service:**
```yaml
image: ${REGISTRY:-}${REGISTRY:+/}${IMAGE_PROJECT:-my-project}/frontend:${IMAGE_TAG:-dev}
```
- Local: resolves to `my-project/frontend:dev`
- Server: resolves to `docker.example.com/my-project/frontend:0.53.0-staging.1234`

### Single-Service Project

**Base (`docker-compose.yml`):**

```yaml
name: my-project

x-infisical-bootstrap: &infisical-bootstrap
  INFISICAL_URL: "https://secrets.example.com"
  INFISICAL_CLIENT_ID: "abc-123-def"
  INFISICAL_PROJECT_ID: "4fc89a1a..."

networks:
  my-project-public:
    driver: bridge
  my-project-private:
    driver: bridge

volumes:
  app-data:

secrets:
  infisical_client_secret:
    file: ./secrets/infisical_client_secret

services:
  my-project-app:
    image: ${REGISTRY:-}${REGISTRY:+/}${IMAGE_REPO:-my-project}:${IMAGE_TAG:-dev}
    build:
      context: .
      dockerfile: Dockerfile
      target: production
    container_name: my-project-app
    restart: unless-stopped
    networks:
      - my-project-public
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
      <<: *infisical-bootstrap
    secrets:
      - infisical_client_secret

    healthcheck:
      test: ["CMD", "node", "/app/healthcheck.cjs"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 30s
```

**Override (`docker-compose.override.yml`):**

```yaml
# Local Development Overrides — Home Environment (WSL / Infisical)
# Automatically merged by docker compose. NOT deployed to servers.

networks:
  traefik-public:
    external: true
    name: traefik-public

volumes:
  my-db-data:

# Override secret paths for local development
secrets:
  infisical_client_secret:
    file: ~/.infisical/client-secret
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

x-infisical-bootstrap: &infisical-bootstrap
  INFISICAL_URL: "https://secrets.example.com"
  INFISICAL_CLIENT_ID: "abc-123-def"
  INFISICAL_PROJECT_ID: "4fc89a1a..."

networks:
  my-project-public:
    driver: bridge
  my-project-private:
    driver: bridge

volumes:
  redis-data:

secrets:
  infisical_client_secret:
    file: ./secrets/infisical_client_secret

services:
  # --- Application Services ---

  my-project-frontend:
    image: ${REGISTRY:-}${REGISTRY:+/}${IMAGE_PROJECT:-my-project}/frontend:${IMAGE_TAG:-dev}
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
      <<: *infisical-bootstrap
    secrets:
      - infisical_client_secret

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
    image: ${REGISTRY:-}${REGISTRY:+/}${IMAGE_PROJECT:-my-project}/backend:${IMAGE_TAG:-dev}
    container_name: my-project-backend
    restart: unless-stopped
    networks:
      - my-project-public
      - my-project-private
    # NO ports — frontend calls it on public network, connects to DB on private

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
      <<: *infisical-bootstrap
    secrets:
      - infisical_client_secret

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
    image: ${REGISTRY:-}${REGISTRY:+/}${IMAGE_PROJECT:-my-project}/backend:${IMAGE_TAG:-dev}
    container_name: my-project-worker
    restart: unless-stopped
    command: ["python", "-m", "celery", "-A", "app.celery_app", "worker"]
    networks:
      - my-project-private
    # NO ports — background worker, private only

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
      <<: *infisical-bootstrap
    secrets:
      - infisical_client_secret

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
# Local Development Overrides — Home Environment (WSL / Infisical)
# Automatically merged by docker compose. NOT deployed to servers.

networks:
  traefik-public:
    external: true
    name: traefik-public

volumes:
  mysql-data:

# Override secret paths for local development
secrets:
  infisical_client_secret:
    file: ~/.infisical/client-secret
  db_root_password:
    file: ~/.secrets/my-project/db-root-password
  db_name:
    file: ~/.secrets/my-project/db-name

services:
  # --- Traefik labels on all app services ---

  my-project-frontend:
    ports: !reset []
    networks:
      - my-project-public
      - traefik-public
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
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.my-project-backend.rule=Host(`api.my-project.localhost`)"
      - "traefik.http.services.my-project-backend.loadbalancer.server.port=8000"
      - "traefik.docker.network=traefik-public"
    depends_on:
      my-project-db:
        condition: service_healthy

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

## CI/CD (GitLab CI)

### Build and Push

```yaml
build:
  stage: build
  script:
    - docker build
        --build-arg RUN_TESTS=true
        --build-arg BUILD_VERSION=$VERSION
        -t $REGISTRY/$IMAGE_REPO:$IMAGE_TAG .
    - trivy image --severity HIGH,CRITICAL --exit-code 1 --ignore-unfixed
        $REGISTRY/$IMAGE_REPO:$IMAGE_TAG
    - docker push $REGISTRY/$IMAGE_REPO:$IMAGE_TAG
```

---

## Checklist (Home-Specific)

In addition to the [global checklist](docker.md#checklist):

### Compose — Base
- [ ] `ENVIRONMENT` in container `environment:` with default (no `REGION`)
- [ ] Infisical bootstrap anchor (`x-infisical-bootstrap`) defined once
- [ ] All app services reference `<<: *infisical-bootstrap` and `infisical_client_secret` secret
- [ ] `secrets:` block with server path (`./secrets/infisical_client_secret`)
- [ ] Image tags use `REGISTRY`/`IMAGE_REPO` (single) or `IMAGE_PROJECT` (multi) interpolation
- [ ] No AWS references (wrong environment)

### Compose — Override
- [ ] Infisical client secret path overridden to `~/.infisical/client-secret`
- [ ] Dev database credentials via Docker secrets (`_FILE` mechanism)
- [ ] Secret files sourced from `~/.secrets/<project>/`
- [ ] No hardcoded credentials anywhere

### CI/CD
- [ ] GitLab CI uses `docker build` with `--build-arg RUN_TESTS=true`
- [ ] Trivy image scan before registry push
- [ ] Registry login step before push (`docker.example.com`)

### .env Files
- [ ] Local `.env`: `ENVIRONMENT=development` (and nothing else)
- [ ] `.env.example` committed to git with same structure
- [ ] Server `.env` pattern documented for deploy scripts
