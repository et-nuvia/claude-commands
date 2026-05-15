# Docker Development Guide

Global reference for Docker standards. For environment-specific patterns (compose examples,
secrets integration, CI/CD), see:

- **[Docker — Work (macOS/GitHub/AWS)](docker-work.md)**
- **[Docker — Home (WSL/GitLab/Infisical)](docker-home.md)**

---

## Core Philosophy

### Docker-Only Development

**All development happens inside Docker containers.** Never run code natively on the host.

| Allowed | Not Allowed |
|---------|-------------|
| `docker compose run --rm backend pytest` | `pytest` |
| `docker compose run --rm frontend npm test` | `npm test` |
| `docker compose exec backend pip install package` | `pip install package` |
| `docker compose up` | `uvicorn main:app` |

### Compose V2 (Required)

```bash
# Correct (V2 plugin syntax)
docker compose up

# Wrong (deprecated V1)
docker-compose up
```

**Minimum version:** Docker Compose v2.24+ (required for `!reset` override syntax).

### BuildKit (Required)

All builds must use BuildKit. Enable globally:

```bash
export DOCKER_BUILDKIT=1
```

Or in `/etc/docker/daemon.json`:
```json
{
  "features": { "buildkit": true }
}
```

Every Dockerfile must start with the BuildKit syntax directive:
```dockerfile
# syntax=docker/dockerfile:1
```

BuildKit enables parallel stage builds, cache mounts, and better layer caching.

---

## Compose Architecture

### Base + Override Pattern

**Two compose files:** a clean base for staging/production, and an override for local development.
Docker Compose automatically merges `docker-compose.override.yml` on top of `docker-compose.yml`.

```
project/
├── docker-compose.yml          # Base: what runs on servers
├── docker-compose.override.yml # Override: local dev (Traefik, dev infra, credential mounts)
├── .env                        # Environment-specific (see work/home docs)
└── .env.example                # Template (committed to Git)
```

**The rule:** `docker-compose.yml` must work standalone on staging/production servers
where no override file exists. The override adds everything needed for local development.

| Goes in base (`docker-compose.yml`) | Goes in override (`docker-compose.override.yml`) |
|--------------------------------------|--------------------------------------------------|
| Application services (frontend, backend, workers) | Traefik network + labels on all services |
| Shared infrastructure that runs everywhere (redis) | Port reset on exposed services (Traefik routes instead) |
| Port mapping on frontend/admin only | Credential mounts (environment-specific) |
| `<project>-public` and `<project>-private` networks | Dev-only infrastructure (mysql, minio, emulators, mocks) |
| Security hardening (read_only, cap_drop, etc.) | Dev-only volumes (mysql data, etc.) |
| Health checks and resource limits | `depends_on` for dev infrastructure |
| Named volumes for writable dirs | Dev secret file path overrides |
| `depends_on` between app services (multi-service only) | |

**Note on `depends_on`:** In single-service base compose files, there are no dependencies to
declare. `depends_on` for dev-only infrastructure (databases, caches, mocks) belongs in the
override. In multi-service projects, app-to-app dependencies (e.g., frontend -> backend -> redis)
go in the base compose.

### Container Naming

All containers use `<project>-<service>` format:
- `intake-app`, `intake-redis`
- `medclear-frontend`, `medclear-backend`, `medclear-ai`, `medclear-redis`

### Network Segmentation

All projects use two networks to isolate public-facing services from backend infrastructure:

- **`<project>-public`** — Services that receive external traffic (frontend, admin)
- **`<project>-private`** — Services that must not be directly accessible (databases, caches, queues)

The **bridge service** — the one that joins both networks — depends on your architecture:

| Architecture | Bridge service | Why |
|-------------|---------------|-----|
| Frontend calls backend API directly | Backend/API | Frontend needs to reach backend on public network |
| Nginx/reverse proxy forwards to backend | Nginx | Nginx routes requests; backend stays private |
| Frontend is SSR (Next.js) with direct DB access | Frontend | Frontend needs private network for DB |

If the frontend proxies API requests through nginx (or another reverse proxy), the
backend does **not** need to be on the public network — it stays fully private alongside
the database and cache. Nginx bridges the two networks instead.

| Network | Who joins | Examples |
|---------|-----------|----------|
| `<project>-public` | Frontend, admin, bridge service | `intake-public`, `medclear-public` |
| `<project>-private` | Bridge service, backend, databases, redis, workers | `intake-private`, `medclear-private` |

**Why:** A compromised frontend container cannot reach the database directly. Only the
bridge service (which joins both networks) connects the two. This limits lateral movement.

### Restart Policy

**Default: `unless-stopped` for all services.** This applies to application services,
shared infrastructure, and dev-only infrastructure alike.

PROJECT.yaml can declare per-service overrides. The `/docker-audit` command verifies
that each service's restart policy matches what PROJECT.yaml specifies (defaulting to
`unless-stopped` when not explicitly configured).

```yaml
# PROJECT.yaml — optional per-service restart override
docker:
  services:
    - name: "my-project-worker"
      restart: "on-failure"    # Override default for this service
```

### Usage

```bash
# Local development (auto-merges override)
docker compose up

# On staging/production servers (no override file present)
docker compose up -d

# Verify merged config locally
docker compose config

# Test base-only config (what servers see)
docker compose -f docker-compose.yml config
```

---

## Secrets — Zero Exceptions

**100% of secrets and configuration come from the secrets manager.** There are no exceptions
to this rule — not for local development, not for dev databases, not for "non-sensitive" config.

### Application Containers

Application containers receive only environment identifiers via `environment:`. Everything
else (config, secrets, feature flags) is fetched from the secrets manager at container startup.

**Allowed in `environment:`:** Only `ENVIRONMENT` (all environments) and `REGION` (work only),
plus secrets manager bootstrap variables (home/Infisical only). Nothing else.

**Operational defaults** (e.g., `RUN_MIGRATIONS=false`) belong in the Dockerfile as `ENV`
directives, not in compose or `.env`. This keeps compose clean and allows `docker run -e`
to override when needed. The Dockerfile is the single source of truth for default behavior.

```dockerfile
# In Dockerfile — safe default, overridable via docker run -e RUN_MIGRATIONS=true
ENV RUN_MIGRATIONS=false
```

### Dev Infrastructure Containers (MySQL, PostgreSQL, Redis)

Dev databases live in the override file (dev-only). They **still** get credentials from
AWS Secrets Manager — the application loads them at startup, same as production.

**Pattern:** Dev databases use the same secrets-at-startup approach as production.
The application fetches database credentials from AWS Secrets Manager when it starts,
regardless of environment. No hardcoded credentials, no `_FILE` env var pattern.

```yaml
# In docker-compose.override.yml
services:
  my-project-db:
    image: mysql:8.4
    environment:
      MYSQL_ROOT_PASSWORD_FILE: /run/secrets/db_root_password
      MYSQL_DATABASE_FILE: /run/secrets/db_name
    secrets:
      - db_root_password
      - db_name
```

**Note:** The database container itself still needs credentials for initialization —
use Docker secrets with `_FILE` vars for the database image only. The **application**
containers never use `_FILE` — they fetch all credentials from AWS Secrets Manager
at startup.

**Bootstrapping local dev secrets:** Each environment has a script to fetch dev secrets
from the secrets manager and write them to `~/.secrets/<project>/`. See the
[work](docker-work.md) and [home](docker-home.md) docs for environment-specific details.

### Redis

Redis typically requires no initialization credentials. If authentication is needed,
configure it via a `redis.conf` mounted as a Docker secret. Application-level Redis
auth credentials are fetched from the secrets manager by the application at startup.

---

## Security Hardening (Required)

All application containers must be hardened. These are not optional.

### Required Security Settings

| Setting | Purpose | Implementation |
|---------|---------|----------------|
| Non-root user | Prevents privilege escalation | DHI runtime images: automatic; non-DHI: `USER app` (UID 1000, GID 1000) |
| Read-only filesystem | Prevents writing malicious files | `read_only: true` |
| No new privileges | Prevents escalation via setuid | `no-new-privileges:true` |
| Drop all capabilities | Removes kernel privileges | `cap_drop: [ALL]` |
| Resource limits | Prevents resource exhaustion | `deploy.resources.limits` |

**Read-only is enforced in ALL environments** including local development.
This ensures filesystem write issues are caught locally, not after deployment.

### Non-Root User — Consistent UID/GID

**DHI runtime images are non-root by default.** No `USER` directive or manual user
creation is needed in runtime stages (development or production) when using DHI images.

For non-DHI infrastructure images, or build stages (`-dev` images) that create files
to `COPY` into runtime stages, you may still need explicit user setup:

```dockerfile
# Debian/Ubuntu (non-DHI infrastructure images or build stages)
RUN groupadd -g 1000 app && useradd -u 1000 -g 1000 -s /bin/sh -m app
```

### Minimal Hardened Service Template

```yaml
services:
  my-app:
    restart: unless-stopped
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
    healthcheck:
      test: ["CMD", "node", "/app/healthcheck.cjs"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 30s
```

### Handling Read-Only Filesystems

When `read_only: true` is set, containers cannot write anywhere. Use `tmpfs` for
ephemeral data and named volumes for persistent data:

```yaml
services:
  my-app:
    read_only: true
    tmpfs:
      - /tmp:noexec,nosuid,size=64m           # Temp files
      - /app/.cache:noexec,nosuid,size=32m    # Application cache
    volumes:
      - app-data:/app/data                     # Persistent writable data
```

Common writable directories needed:
- `/tmp` — Temporary files
- `/var/run` — PID files, sockets
- `/app/.cache` — Application caches
- `/home/app/.local` — User-level caches

### Next.js Runtime Secret Injection

Next.js frontends that inject secrets at runtime (replacing `BAKED_*` placeholders
via `sed`) need special handling for `read_only: true`. The `.next` directory must
be writable for `sed`, but we still enforce a read-only root filesystem.

**Pattern: Baked build copy + tmpfs overlay**

1. **Dockerfile** — bake a pristine read-only copy at build time:
```dockerfile
COPY --from=builder /app/frontend/.next/standalone ./
COPY --from=builder /app/frontend/.next/static ./frontend/.next/static
COPY --from=builder /app/frontend/public ./frontend/public

# Pristine read-only copy for runtime secret injection
RUN cp -r /app/frontend/.next /app/frontend/.next-build

RUN mkdir -p /app/frontend/.next/cache /tmp && \
    chown -R 1000:1000 /app /tmp
```

2. **docker-compose.yml** — tmpfs overlay with matching uid/gid:
```yaml
services:
  my-project-frontend:
    read_only: true
    tmpfs:
      - /tmp:noexec,nosuid,size=64m
      - /app/frontend/.next:uid=1000,gid=1000,size=256m
```

3. **docker-entrypoint.sh** — copy from read-only build, then inject:
```sh
NEXT_DIR="/app/frontend/.next"
BUILD_DIR="/app/frontend/.next-build"

rm -rf "${NEXT_DIR:?}"/*
cp -r "$BUILD_DIR"/* "$NEXT_DIR/"

find "$NEXT_DIR" -type f -name "*.js" -exec sed -i \
  -e "s|BAKED_NEXT_PUBLIC_API_URL|${API_URL}|g" \
  {} \;

exec node /app/frontend/server.js
```

### Adding Back Capabilities

Only add capabilities when absolutely necessary:

```yaml
services:
  my-app:
    cap_drop:
      - ALL
    cap_add:
      - NET_BIND_SERVICE    # Only if binding to ports < 1024
```

### Resource Limits (Required)

Resource limits prevent runaway containers from exhausting host resources. They are
**required** but must be properly tested — undersized limits cause containers to crash
(OOMKilled) with no obvious error message.

**Profiling before setting limits:**

```bash
# Monitor real-time resource usage under normal load
docker stats my-project-backend

# Run a load test and watch peak usage
docker stats --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}" my-project-backend
```

**Setting limits with headroom:**

| Measured Peak | Recommended Limit | Rationale |
|---------------|-------------------|-----------|
| 200MB memory | 384M-512M | 1.5-2x headroom for spikes |
| 400MB memory | 512M-768M | Same ratio |
| 0.3 CPU | 0.5-1.0 | Allow burst capacity |

**Framework-specific considerations:**

| Framework | Watch For |
|-----------|-----------|
| Java/JVM | Heap (`-Xmx`) must be < container limit. Set `-XX:MaxRAMPercentage=75` |
| Node.js | Set `--max-old-space-size` to ~75% of container memory limit |
| Python | Generally well-behaved; watch for pandas/numpy large dataset operations |
| Next.js | Build step is memory-intensive; runtime is lighter |

**Testing resource limits:**

1. Set limits based on profiling with headroom
2. Deploy to staging with limits enabled
3. Run full E2E test suite and smoke tests under load
4. Monitor for `OOMKilled` events: `docker inspect --format='{{.State.OOMKilled}}' <container>`
5. Check container restarts: `docker compose ps` (restart count should be 0)
6. Adjust limits if containers are being killed

**Compose syntax:**

```yaml
deploy:
  resources:
    limits:
      memory: 512M
      cpus: '1.0'
    reservations:
      memory: 256M
      cpus: '0.25'
```

---

## Multi-Stage Builds

Use multi-stage builds to create small, secure production images. DHI `-dev` images
provide the build environment with compilers and dev tools; production runs on
the standard DHI runtime image (minimal, non-root by default).

### BuildKit Cache Mounts

Cache package manager stores across builds for faster rebuilds:

```dockerfile
# pip cache
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install --no-cache-dir --user -r requirements.txt

# npm cache
RUN --mount=type=cache,target=/root/.npm \
    npm ci
```

### DHI Image Pinning (Required)

Pin DHI images by SHA256 digest for reproducible, auditable builds.
The `/docker-audit` command checks if newer digests are available.

```dockerfile
# Pin by SHA256 digest (auditable, reproducible)
FROM dhi.io/python:3.14-debian13-dev@sha256:abc123... AS builder

# Also acceptable: pin by full tag (less strict but still deterministic)
FROM dhi.io/python:3.14-debian13-dev AS builder
```

**To find current digests:**
```bash
docker pull dhi.io/python:3.14-debian13-dev
docker inspect --format='{{index .RepoDigests 0}}' dhi.io/python:3.14-debian13-dev
```

### Python: DHI Build and Runtime

DHI `-dev` images provide the build environment (compilers, dev headers); the standard
DHI runtime image is used for both development and production (minimal, non-root by default).

```dockerfile
# syntax=docker/dockerfile:1

ARG APP_VERSION=development
ARG BUILD_DATE=unknown
ARG VCS_REF=unknown

# =============================================================================
# Stage 1: Build Environment (DHI -dev image)
# =============================================================================
FROM dhi.io/python:3.14-debian13-dev AS builder

WORKDIR /build

COPY requirements.txt .
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install --no-cache-dir --user -r requirements.txt

# =============================================================================
# Stage 2: Testing (inactive by default)
# =============================================================================
FROM builder AS testing

ARG RUN_TESTS=false

COPY . .

RUN if [ "$RUN_TESTS" = "true" ]; then \
      pip install --user pytest pytest-cov pytest-asyncio && \
      pytest --cov=app --cov-report=term-missing --cov-fail-under=80; \
    else \
      echo "Skipping tests (RUN_TESTS=$RUN_TESTS)"; \
    fi

# =============================================================================
# Stage 3: Development (same DHI runtime as production)
# =============================================================================
FROM dhi.io/python:3.14-debian13 AS development

WORKDIR /app

COPY --from=builder /root/.local /home/nonroot/.local
ENV PATH=/home/nonroot/.local/bin:$PATH

COPY . .

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000", "--reload"]

# =============================================================================
# Stage 4: Production (same DHI runtime as development)
# =============================================================================
FROM dhi.io/python:3.14-debian13 AS production

ARG APP_VERSION
ARG BUILD_DATE
ARG VCS_REF

LABEL org.opencontainers.image.version="${APP_VERSION}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.title="<project>-<service>"

WORKDIR /app

COPY --from=builder /root/.local /home/nonroot/.local
ENV PATH=/home/nonroot/.local/bin:$PATH
ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1

COPY . .

RUN echo "${APP_VERSION}" > /app/VERSION

HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
  CMD ["python", "/app/healthcheck.py"]

# Entrypoint should fetch secrets from the configured secrets manager
# (AWS Secrets Manager or Infisical, depending on PROJECT.yaml secrets.backend)
# before starting the application.

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
```

### Node.js: DHI Build and Runtime

DHI `-dev` images provide the build environment; the standard DHI runtime image is
used for both development and production. DHI runtime images have no shell — use
Node.js `.mjs` entrypoint scripts instead of shell scripts.

```dockerfile
# syntax=docker/dockerfile:1

ARG APP_VERSION=development
ARG BUILD_DATE=unknown
ARG VCS_REF=unknown

# =============================================================================
# Stage 1: Install Dependencies (DHI -dev image)
# =============================================================================
FROM dhi.io/node:24-debian13-dev AS deps

WORKDIR /build

COPY package.json package-lock.json ./
RUN --mount=type=cache,target=/root/.npm \
    npm ci

# =============================================================================
# Stage 2: Build
# =============================================================================
FROM deps AS builder

COPY . .
RUN npm run build

# =============================================================================
# Stage 3: Testing (inactive by default)
# =============================================================================
FROM builder AS testing

ARG RUN_TESTS=false

RUN if [ "$RUN_TESTS" = "true" ]; then \
      npm test && npm run lint && npm run typecheck; \
    else \
      echo "Skipping tests (RUN_TESTS=$RUN_TESTS)"; \
    fi

# =============================================================================
# Stage 4: Development (same DHI runtime as production)
# =============================================================================
FROM dhi.io/node:24-debian13 AS development

WORKDIR /app

COPY --from=deps /build/node_modules ./node_modules
COPY . .

CMD ["node", "--watch", "server.mjs"]

# =============================================================================
# Stage 5: Production (same DHI runtime as development)
# =============================================================================
FROM dhi.io/node:24-debian13 AS production

ARG APP_VERSION
ARG BUILD_DATE
ARG VCS_REF

LABEL org.opencontainers.image.version="${APP_VERSION}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.title="<project>-<service>"

WORKDIR /app

# Next.js standalone output (adjust for non-Next.js projects)
COPY --from=builder /build/.next/standalone ./
COPY --from=builder /build/.next/static ./.next/static
COPY --from=builder /build/public ./public

RUN echo "${APP_VERSION}" > /app/VERSION

HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
  CMD ["node", "/app/healthcheck.js"]

# Entrypoint should fetch secrets from the configured secrets manager
# (AWS Secrets Manager or Infisical, depending on PROJECT.yaml secrets.backend)
# before starting the application.
# Entrypoints must be .mjs files (not shell scripts) since DHI runtime has no
# shell. See the "Node.js Entrypoints" section above.

CMD ["node", "server.js"]
```

**For non-Next.js Node.js projects**, replace the production COPY lines:
```dockerfile
COPY --from=deps /build/node_modules ./node_modules
COPY --from=builder /build/dist ./dist
COPY --from=builder /build/package.json ./

CMD ["node", "dist/main.js"]
```

**Shell-free runtime:** DHI runtime images do not include a shell. Use Node.js `.mjs`
scripts for entrypoints that need logic (e.g., secrets fetching). Use
`@aws-sdk/client-secrets-manager` instead of aws-cli for runtime secrets access.

### nginx: DHI Reverse Proxy / Static Serving

DHI nginx runs as non-root on port 8080 (HTTPS on 8443). No shell or extra tooling needed.

```dockerfile
# syntax=docker/dockerfile:1
FROM dhi.io/nginx:1.27-debian13
COPY nginx.conf /etc/nginx/nginx.conf
EXPOSE 8080
```

Compose snippet:

```yaml
<project>-nginx:
  image: dhi.io/nginx:1.27-debian13
  ports:
    - "80:8080"
    - "443:8443"
  read_only: true
  security_opt:
    - no-new-privileges:true
  cap_drop:
    - ALL
  # No cap_add needed — port 8080 doesn't need NET_BIND_SERVICE
  tmpfs:
    - /tmp:noexec,nosuid,size=16m
    - /var/cache/nginx:size=64m
    - /var/run:size=1m
```

**Note:** DHI nginx runs on port 8080 (non-root). Host ports 80/443 map to container
8080/8443. No `NET_BIND_SERVICE` capability is needed since the container listens on
unprivileged ports.

### Build Arguments

| Argument | Default | Purpose |
|----------|---------|---------|
| `RUN_TESTS` | `false` | Enable test stage during build |
| `BUILD_TARGET` | `production` | Select final build stage |
| `APP_VERSION` | `development` | Semantic version baked into OCI label and `/app/VERSION` |
| `BUILD_DATE` | `unknown` | ISO 8601 build timestamp for OCI label |
| `VCS_REF` | `unknown` | Git commit SHA for OCI label |

### Build Commands

```bash
# Development build (no tests)
docker build --target development -t myapp:dev .

# Production build (no tests)
docker build --target production -t myapp:prod .

# Production build WITH tests (CI/CD pipeline)
docker build --target production --build-arg RUN_TESTS=true -t myapp:prod .

# Production build with OCI labels (CI/CD pipeline)
docker build --target production \
  --build-arg RUN_TESTS=true \
  --build-arg APP_VERSION="$(~/.claude/scripts/get-version.sh)" \
  --build-arg BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --build-arg VCS_REF="$(git rev-parse HEAD)" \
  -t myapp:prod .

# Run tests only
docker build --target testing --build-arg RUN_TESTS=true -t myapp:test .
```

### CI/CD Pipeline Integration

`RUN_TESTS` is passed as a build argument in the CI/CD pipeline, **not** in compose files.
Compose files are for runtime — test execution happens during image builds in the pipeline.

**Compose integration (optional, for projects that build locally):**
```yaml
services:
  backend:
    build:
      context: ./backend
      target: ${BUILD_TARGET:-development}
      args:
        RUN_TESTS: ${RUN_TESTS:-false}
```

See the [work](docker-work.md) and [home](docker-home.md) docs for CI/CD examples.

---

## Node.js Entrypoints (Shell-Free)

DHI runtime images have no shell. There is no `bash`, `sh`, `aws-cli`, `jq`, `sed`,
`find`, `cp`, or `netcat`. All entrypoints must be Node.js `.mjs` scripts that perform
startup logic (secrets fetching, file copying, placeholder replacement) using pure
Node.js APIs.

### Shell-to-Node.js Replacement Table

| Shell Tool | Node.js Replacement | Package |
|------------|---------------------|---------|
| `aws secretsmanager get-secret-value` | `GetSecretValueCommand` | `@aws-sdk/client-secrets-manager` |
| `infisical export` | `InfisicalClient.listSecrets()` | `@infisical/sdk` |
| `jq` | `JSON.parse()` | built-in |
| `sed -i 's/old/new/g'` | `String.replaceAll()` + `fs.writeFileSync()` | built-in |
| `find . -name '*.js'` | `fs.readdirSync(dir, { recursive: true })` | built-in |
| `cp -r src/ dst/` | `fs.cpSync(src, dst, { recursive: true })` | built-in |
| `nc -z host port` | `net.createConnection({ host, port })` | built-in |

### Secrets Manager Integration

The secrets manager client depends on what is configured in PROJECT.yaml:

| Environment | Package | Notes |
|-------------|---------|-------|
| Work (AWS) | `@aws-sdk/client-secrets-manager` | ~2 MB, IAM role auth |
| Home (Infisical) | `@infisical/sdk` | Token auth via Docker secrets |

The entrypoint fetches secrets at startup regardless of environment. This eliminates
the need for `aws-cli` (~100 MB+) in the runtime image entirely.

**Required npm dependency** (add to `package.json`):
```json
{
  "dependencies": {
    "@aws-sdk/client-secrets-manager": "^3.x"
  }
}
```

Or for Infisical:
```json
{
  "dependencies": {
    "@infisical/sdk": "^2.x"
  }
}
```

### Frontend Entrypoint Pattern

`docker-entrypoint.mjs` -- Fetch secrets, copy `.next-build` to `.next` (tmpfs),
replace `BAKED_*` placeholders, start server.

```javascript
import { readFileSync, writeFileSync, cpSync, readdirSync } from "node:fs";
import { join } from "node:path";
import {
  SecretsManagerClient,
  GetSecretValueCommand,
} from "@aws-sdk/client-secrets-manager";

const NEXT_DIR = "/app/frontend/.next";
const BUILD_DIR = "/app/frontend/.next-build";

// --- 1. Fetch secrets from secrets manager ---
const client = new SecretsManagerClient();
const { SecretString } = await client.send(
  new GetSecretValueCommand({
    SecretId: `${process.env.ENVIRONMENT}/frontend`,
  })
);
const secrets = JSON.parse(SecretString);

// --- 2. Copy pristine build to writable tmpfs ---
cpSync(BUILD_DIR, NEXT_DIR, { recursive: true });

// --- 3. Replace BAKED_* placeholders in JS files ---
const jsFiles = readdirSync(NEXT_DIR, { recursive: true, withFileTypes: true })
  .filter((entry) => entry.isFile() && entry.name.endsWith(".js"))
  .map((entry) => join(entry.parentPath, entry.name));

for (const file of jsFiles) {
  let content = readFileSync(file, "utf8");
  let changed = false;

  for (const [key, value] of Object.entries(secrets)) {
    const placeholder = `BAKED_${key}`;
    if (content.includes(placeholder)) {
      content = content.replaceAll(placeholder, value);
      changed = true;
    }
  }

  if (changed) writeFileSync(file, content);
}

// --- 4. Start Next.js server ---
await import("/app/frontend/server.js");
```

**How restart picks up new secrets:** Because the entrypoint copies `.next-build` to
`.next` fresh on every start and re-fetches secrets from the secrets manager, a
container restart (`docker compose restart frontend`) automatically picks up rotated
secrets. No rebuild needed.

### Backend Entrypoint Pattern

`docker-entrypoint.mjs` -- Fetch secrets, TCP port wait, run migrations if enabled,
start app.

```javascript
import { createConnection } from "node:net";
import { execFileSync } from "node:child_process";
import {
  SecretsManagerClient,
  GetSecretValueCommand,
} from "@aws-sdk/client-secrets-manager";

// --- 1. Fetch secrets from secrets manager ---
const client = new SecretsManagerClient();
const { SecretString } = await client.send(
  new GetSecretValueCommand({
    SecretId: `${process.env.ENVIRONMENT}/backend`,
  })
);
const secrets = JSON.parse(SecretString);

// Inject secrets as environment variables for the app process
for (const [key, value] of Object.entries(secrets)) {
  process.env[key] = value;
}

// --- 2. Wait for database port ---
async function waitForPort(host, port, timeoutMs = 30_000) {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    try {
      await new Promise((resolve, reject) => {
        const socket = createConnection({ host, port }, () => {
          socket.destroy();
          resolve();
        });
        socket.on("error", reject);
        socket.setTimeout(1000, () => {
          socket.destroy();
          reject(new Error("timeout"));
        });
      });
      return;
    } catch {
      await new Promise((r) => setTimeout(r, 1000));
    }
  }
  throw new Error(`Port ${host}:${port} not reachable after ${timeoutMs}ms`);
}

const dbHost = process.env.DATABASE_HOST ?? "localhost";
const dbPort = Number(process.env.DATABASE_PORT ?? 3306);
await waitForPort(dbHost, dbPort);

// --- 3. Run migrations if enabled ---
if (process.env.RUN_MIGRATIONS === "true") {
  execFileSync("node", ["node_modules/.bin/knex", "migrate:latest"], {
    stdio: "inherit",
    env: process.env,
  });
}

// --- 4. Start application ---
await import("/app/server.js");
```

### Dockerfile Impact

Using Node.js entrypoints with `@aws-sdk/client-secrets-manager` eliminates the
aws-tools build stage entirely:

| Approach | Image Size Impact |
|----------|-------------------|
| `aws-cli` in image | ~100 MB+ (Python runtime + CLI) |
| `@aws-sdk/client-secrets-manager` in `node_modules` | ~2 MB |

The DHI runtime image stays minimal -- no extra build stage, no shell, no Python runtime.

---

## Base Image Selection

### Version Pinning (Required)

**Always pin images to a specific version tag.** Never use `:latest` or floating tags.

**Rules:**
- **New containers**: Use the latest available pinned version at time of creation
- **Existing containers**: Update versions deliberately via dependency upgrade process
- **Pin strategy**: Use the most specific tag that provides automatic security patches
  - DHI images: Pin by SHA256 digest for maximum reproducibility, or by full tag (e.g., `dhi.io/python:3.14-debian13`)
  - Language runtimes: Pin to minor with distro (e.g., `dhi.io/python:3.14-debian13`, `dhi.io/node:24-debian13`)
  - Infrastructure: Pin to minor (e.g., `redis:7.4-bookworm`, `mysql:8.4`)
  - Cloud-mirrored infra: Pin to match the cloud version exactly (e.g., if RDS runs MySQL 8.0.39, use `mysql:8.0.39`)

### Docker Hardened Images (DHI) — Preferred

**Use Docker Hardened Images (DHI) from `dhi.io` as the preferred base images.**

DHI images provide:
- **95% smaller attack surface** — distroless philosophy, only essential runtime deps
- **Near-zero CVEs** maintained with 7-day SLA for Critical/High remediation
- **Compliance**: CIS, FIPS, STIG, ELS certifications
- **SLSA Build Level 3** supply chain security
- **Drop-in replacement** — compatible with standard Debian/Alpine workflows

**Registry**: `dhi.io/<image>` (free with a Docker Hub account; login strongly recommended for rate limits)
**Catalog**: https://hub.docker.com/hardened-images/catalog

**Never use Chainguard (`cgr.dev`)** — paid commercial product.

### Preferred Base Images

**Image priority** (highest to lowest preference):
1. **DHI** (`dhi.io/<image>`) — hardened, near-zero CVEs, compliance-ready
2. **Official slim/debian** — acceptable fallback when DHI unavailable

| Use Case | DHI Image | Fallback | Notes |
|----------|-----------|----------|-------|
| **Node.js (build)** | `dhi.io/node:24-debian13-dev` | `node:24-slim` | `-dev` for build stages only |
| **Node.js (runtime)** | `dhi.io/node:24-debian13` | `node:24-slim` | Non-root, no shell |
| **Python (build)** | `dhi.io/python:3.14-debian13-dev` | `python:3.14-slim` | `-dev` for build stages only |
| **Python (runtime)** | `dhi.io/python:3.14-debian13` | `python:3.14-slim` | Non-root, no shell |
| **Go (build)** | `dhi.io/golang:1.24-debian13-dev` | `golang:1.24-bookworm` | Use `dhi.io/static` or `scratch` for runtime |
| **Redis** | `dhi.io/redis:7.4-debian13` | `redis:7.4-bookworm` | Pin minor version |
| **MySQL** | `dhi.io/mysql:8.4-debian13` | `mysql:8.4` | Pin to match cloud (RDS) version |
| **PostgreSQL** | `dhi.io/postgresql:16-debian13` | `postgres:16.4-bookworm` | Pin to match cloud (RDS) version |
| **Nginx** | `dhi.io/nginx:1.27-debian13` | `nginx:1.27-bookworm-slim` | For reverse proxy / static serving |
| **Debian base** | `dhi.io/debian:13-slim` | `debian:bookworm-slim` | Default base when language-specific not needed |

### DHI Image Variants

| Suffix | Shell | Pkg Manager | Build Tools | User | Use For |
|--------|-------|-------------|-------------|------|---------|
| (none) | No | No | No | Non-root | Production runtime |
| `-dev` | Yes | Yes (apt) | Yes (gcc, make) | Root | Build stages, dependency installation |
| `-fips` | No | No | No | Non-root | FIPS compliance (Enterprise only) |
| `-stig` | No | No | No | Non-root | STIG compliance (Enterprise only) |

### Available DHI Images

| Image | Runtime Tag | Dev Tag |
|-------|-------------|---------|
| **Node.js** | `dhi.io/node:24-debian13` | `dhi.io/node:24-debian13-dev` |
| **Python** | `dhi.io/python:3.14-debian13` | `dhi.io/python:3.14-debian13-dev` |
| **nginx** | `dhi.io/nginx:1.29-debian13` | `dhi.io/nginx:1.29-debian13-dev` |
| **PHP** | `dhi.io/php:8.3-debian13` | `dhi.io/php:8.3-debian13-dev` |
| **Redis** | `dhi.io/redis:7-debian13` | — |
| **Postgres** | `dhi.io/postgres:17-debian13` | — |
| **Static** | `dhi.io/static:latest` | — |
| **uv** | `dhi.io/uv:latest` | — |
| **Composer** | `dhi.io/composer:latest` | — |

Full catalog: https://hub.docker.com/catalogs/dhi

### Avoid

- Full images (`python:3.14`, `node:24`) — too large, unnecessary tools
- Alpine images — musl libc compatibility issues, use DHI Debian-based images instead
- `:latest` tag — unpredictable, breaks reproducibility
- Floating major tags (`redis:7`) — minor version changes can break things
- NixOS (`nixos/nix`) — eliminated, use DHI `-dev` images for build stages instead
- Chainguard (`cgr.dev/*`) — commercial/paid, use DHI instead

---

## DHI Authentication & Rate Limits

### Is DHI Free?

**Yes.** Docker open-sourced all 1,000+ hardened images under **Apache 2.0** on December 17, 2025. Free to pull, including pre-built images.

| What | Free | Paid (Enterprise) |
|------|------|-------------------|
| All 1,000+ hardened images | Yes | Yes |
| Signed SBOMs + SLSA L3 provenance | Yes | Yes |
| VEX attestations (zero-CVE scan reports) | Yes | Yes |
| Pull limits | None documented | None |
| CVE patching | Yes, but no SLA on timeline | 7-day SLA for critical CVEs |
| FIPS 140-2 crypto variants | No | Yes |
| STIG/PCI compliance variants | No | Yes |
| Custom image builds | No | Yes |

**We do NOT need Enterprise.** Free tier covers everything we use.

### Authentication

DHI login is **strongly recommended** — gives you your own rate limit quota instead of sharing the anonymous pool. Uses a **free Docker Hub account** (no paid subscription required).

```bash
# One-time local login (uses Docker Hub credentials)
docker login dhi.io
# Credentials cached in ~/.docker/config.json
```

### CI/CD Pipeline Authentication

Every pipeline that builds images must authenticate to `dhi.io` before `docker build`.

**Required secrets:**
- `DOCKERHUB_USERNAME` — Docker Hub username
- `DOCKERHUB_TOKEN` — Docker Hub Personal Access Token (NOT your password)

Generate token at: https://hub.docker.com/settings/security (New Access Token, Read-only scope is sufficient)

**GitHub Actions:**
```yaml
- name: Login to DHI registry
  uses: docker/login-action@v3
  with:
    registry: dhi.io
    username: ${{ secrets.DOCKERHUB_USERNAME }}
    password: ${{ secrets.DOCKERHUB_TOKEN }}

- name: Login to Docker Hub
  uses: docker/login-action@v3
  with:
    username: ${{ secrets.DOCKERHUB_USERNAME }}
    password: ${{ secrets.DOCKERHUB_TOKEN }}

- name: Login to AWS ECR
  uses: aws-actions/amazon-ecr-login@v2

- name: Build and push
  uses: docker/build-push-action@v6
  with:
    context: .
    push: true
    tags: ${{ env.ECR_REGISTRY }}/${{ env.IMAGE_NAME }}:${{ env.IMAGE_TAG }}
```

**GitLab CI:**
```yaml
before_script:
  - echo "$DOCKERHUB_TOKEN" | docker login dhi.io -u "$DOCKERHUB_USERNAME" --password-stdin
```

### Rate Limits

#### DHI Registry (`dhi.io`)

**No documented rate limit.** The `dhi.io` registry runs on separate infrastructure (Google Cloud) from Docker Hub (AWS), has its own token endpoint, and does not return rate limit headers. DHI pulls do not count against Docker Hub quotas.

#### Docker Hub (`docker.io` — official images like redis, mysql)

| Account | Limit | Window |
|---------|-------|--------|
| **Unauthenticated** | 100 pulls | per 6 hours, shared per IP |
| **Personal (free, authenticated)** | 200 pulls | per 6 hours |
| **Pro / Team / Business** | Unlimited | — |

**What counts as a pull:**
- 1 manifest GET = 1 pull (`docker pull` or `FROM` in a Dockerfile)
- Multi-arch image = 1 pull per architecture
- HEAD requests (version checks) = free
- Layers within a pull = don't count separately
- Already-cached images = no pull, no count

**CI/CD implications:** Shared runners share IP addresses across all users. Unauthenticated pulls share the 100/6hr IP-based pool. Always authenticate — even for Docker Hub — to get your personal 200 quota.

### Risk Mitigation

1. **ECR mirroring** — CI/CD pushes built images to our own ECR. Downstream deployments pull from ECR, never from `dhi.io`. If Docker changes terms, deployed images are unaffected.

2. **Self-build option** — DHI build definitions are Apache 2.0 on GitHub at `docker-hardened-images/catalog`. Fork and build ourselves if needed.

3. **Exit to Debian slim** — change `FROM dhi.io/node:24-debian13` to `FROM node:24-bookworm-slim` and re-add manual hardening. Multi-stage build pattern stays identical.

**Key point:** Production servers never pull from `dhi.io` directly. Only CI/CD runners pull DHI base images during builds, then push the final image to ECR.

---

## Health Checks (Required — All Services)

**Every service must have a health check. No exceptions.** This includes application
services, workers, shared infrastructure, and dev-only infrastructure.

Health checks enable:
- `depends_on` with `condition: service_healthy` for proper startup ordering
- Docker's built-in health monitoring and restart policies
- Zero-downtime deployments (rolling recreate detects readiness)

### Tuning Guidelines

| Parameter | Value | Rationale |
|-----------|-------|-----------|
| `interval` | `10s` | Fast detection during rolling recreates |
| `timeout` | `5s` | Generous for slow health endpoints |
| `retries` | `5` | Allows transient failures during startup |
| `start_period` | Per-service | See table below |

### start_period Reference

| Service Type | `start_period` | Reason |
|-------------|----------------|--------|
| Frontend (Next.js) | `15s` | Fast start + entrypoint secret injection |
| Backend (FastAPI/NestJS) | `30-40s` | Cold start + DB connections + secrets |
| AI service | `20s` | FastAPI + model loading |
| Worker (Celery/Bull) | `20s` | Similar to backend |
| Redis | `10s` | Starts in ~1s |
| MySQL/PostgreSQL | `30s` | Schema init on first start |

### Health Check Examples

```yaml
services:
  # Application service (HTTP endpoint)
  backend:
    healthcheck:
      test: ["CMD", "node", "/app/healthcheck.cjs"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 40s

  # Worker (process check or custom script)
  worker:
    healthcheck:
      test: ["CMD-SHELL", "celery -A app.celery_app inspect ping --timeout 5"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 20s

  # PostgreSQL
  db:
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 30s

  # MySQL
  db:
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 30s

  # Redis
  redis:
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 10s
```

### Dependency Ordering

```yaml
services:
  backend:
    depends_on:
      db:
        condition: service_healthy
      redis:
        condition: service_healthy
```

### Compose vs Dockerfile Healthcheck Precedence

When both a Dockerfile `HEALTHCHECK` instruction and a compose `healthcheck:` block
are defined, the compose values take precedence. Use different defaults for each context:

| Context | interval | timeout | retries | start_period | When to use |
|---------|----------|---------|---------|--------------|-------------|
| Compose (runtime) | 10s | 5s | 5 | Per-service | Production/staging -- fast detection for rolling recreates |
| Dockerfile (fallback) | 30s | 10s | 3 | 30s | Default when compose does not define a healthcheck |

**Compose is authoritative.** The Dockerfile `HEALTHCHECK` serves as a safety net for
environments that run the image directly (`docker run`) without a compose file. Compose
deployments should always define their own `healthcheck:` block with the tighter 10s
interval for fast failure detection during rolling recreates.

---

## Networking

### Network Segmentation (Required)

Services are split across two networks: `<project>-public` for external-facing services
and `<project>-private` for backend infrastructure. One service bridges both — which one
depends on your architecture.

#### Pattern A: Frontend calls backend directly

```yaml
services:
  my-project-frontend:
    networks:
      - my-project-public
    ports:
      - "3000:3000"
    # Frontend CANNOT reach redis/database directly

  my-project-backend:
    networks:
      - my-project-public    # Receives requests from frontend
      - my-project-private   # Connects to database, redis, etc.
    # NO ports — frontend calls it on public network

  my-project-redis:
    networks:
      - my-project-private
    # Private only — unreachable from frontend

networks:
  my-project-public:
    driver: bridge
  my-project-private:
    driver: bridge
```

#### Pattern B: Nginx forwards API requests to backend

```yaml
services:
  my-project-nginx:
    networks:
      - my-project-public    # Receives external traffic
      - my-project-private   # Forwards to backend
    ports:
      - "80:80"

  my-project-frontend:
    networks:
      - my-project-public
    # Serves static assets, nginx proxies API calls

  my-project-backend:
    networks:
      - my-project-private   # Only reachable via nginx
    # NO public network — fully private

  my-project-redis:
    networks:
      - my-project-private

networks:
  my-project-public:
    driver: bridge
  my-project-private:
    driver: bridge
```

**Rules:**
- Frontend/admin services: `<project>-public` only
- Bridge service (backend or nginx): both `<project>-public` and `<project>-private`
- Databases, caches, queues, workers: `<project>-private` only
- If nginx forwards API requests, backend stays on `<project>-private` only
- No service should use Docker's default network or host networking

### Traefik (Local Development Only)

Traefik is **exclusively for local development** — it appears only in
`docker-compose.override.yml`, never in the base compose file.

Traefik is managed by the infrastructure project. Applications only declare labels:

```yaml
# In docker-compose.override.yml only
labels:
  - "traefik.enable=true"
  - "traefik.http.routers.<project>-<service>.rule=Host(`<subdomain>.localhost`)"
  - "traefik.http.services.<project>-<service>.loadbalancer.server.port=<port>"
  - "traefik.docker.network=traefik-public"
```

**URL conventions:**

| Service Type | URL Pattern | Example |
|-------------|-------------|---------|
| Frontend | `<project>.localhost` | `medclear.localhost` |
| Backend API | `api.<project>.localhost` | `api.medclear.localhost` |
| AI service | `ai.<project>.localhost` | `ai.medclear.localhost` |
| Admin panel | `admin.<project>.localhost` | `admin.intake.localhost` |

**Override adds the Traefik network and resets direct ports:**

```yaml
# In docker-compose.override.yml
services:
  my-project-frontend:
    ports: !reset []  # Traefik handles routing instead
    networks:
      - my-project-public
      - traefik-public

networks:
  traefik-public:
    external: true
    name: traefik-public
```

---

## Logging

**Logging configuration is REQUIRED on all services.** Every service in compose must
have explicit logging config to prevent unbounded log growth.

```yaml
services:
  backend:
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
```

Apply this to every service — application services, workers, dev infrastructure, and
shared infrastructure. No exceptions.

---

## Container Image Scanning

Scan built images for vulnerabilities before pushing to any registry. Use Trivy
(already required for dependency scanning).

```bash
# Scan a built image
trivy image myapp:prod

# Scan with severity filter (CI/CD — fail on HIGH/CRITICAL)
trivy image --severity HIGH,CRITICAL --exit-code 1 myapp:prod

# Scan ignoring unfixed vulnerabilities
trivy image --ignore-unfixed --severity HIGH,CRITICAL --exit-code 1 myapp:prod
```

Integrate into CI/CD pipelines after the build step but before pushing to the registry.
See the [work](docker-work.md) and [home](docker-home.md) docs for pipeline examples.

---

## Lambda and Serverless Dockerfiles

Lambda and serverless function Dockerfiles are a **special case** — they are packaging tools,
not runtime containers. Standard container hardening rules **do not apply**.

**What's different:**
- No multi-stage build requirement (Lambda runtime manages the environment)
- No `RUN_TESTS` build arg (tests run separately in CI, not during image build)
- No `USER` directive (Lambda manages execution user — e.g., `sbx_user1051`)
- No `read_only`, `cap_drop`, `no-new-privileges` (Lambda sandbox handles isolation)
- No health checks (Lambda runtime manages invocation lifecycle)
- Base image is the AWS Lambda runtime (e.g., `public.ecr.aws/lambda/python:3.12`)

**What still applies:**
- Version pinning on base images
- `.dockerignore` for build context
- No secrets baked into the image

**Convention:** Place Lambda Dockerfiles under a `lambda/` directory. The `/docker-audit`
command automatically skips Dockerfiles in `lambda/` and `serverless/` directories.

```dockerfile
# Lambda packaging — standard container rules do not apply
FROM public.ecr.aws/lambda/python:3.12 AS builder

WORKDIR /asset
COPY requirements.txt .
RUN pip install -r requirements.txt -t .
COPY index.py .

FROM public.ecr.aws/lambda/python:3.12
COPY --from=builder /asset ${LAMBDA_TASK_ROOT}
CMD ["index.handler"]
```

---

## .dockerignore Template

Every project must have a `.dockerignore` to minimize build context and prevent
leaking sensitive files into images:

```
# Version control
.git
.gitignore
.github
.gitlab

# Dependencies (rebuilt in container)
node_modules
.venv
__pycache__
*.pyc

# Build output (rebuilt in container)
.next
dist
build
coverage
.nyc_output

# Environment and secrets
.env
.env.*
!.env.example
secrets/

# Docker files (not needed in build context)
docker-compose*.yml
Dockerfile*
.dockerignore

# IDE and OS
.vscode
.idea
.DS_Store
*.swp

# Documentation (not needed in image)
*.md
!README.md
LICENSE

# Test and lint config
.pytest_cache
.mypy_cache
.ruff_cache
.eslintcache
```

---

## Audit Requirements

The `/docker-audit` command checks the following items. Each is scored as PASS, WARN, or FAIL.
Run this audit monthly against every project's Dockerfiles and docker-compose files.

### Dockerfile Audit

#### Base Images (D1-D5)

| # | Check | PASS | FAIL |
|---|-------|------|------|
| D1 | Build stages use `dhi.io/<runtime>:<version>-debian13-dev` | DHI -dev images | nixos/nix, node:alpine, or other non-DHI build bases |
| D2 | Runtime stages use `dhi.io/<runtime>:<version>-debian13` | DHI runtime images | Alpine, slim, or nix-based runtime |
| D3 | Infrastructure images pinned with SHA256 digest | `redis:7.4.8-alpine@sha256:...` | Unpinned or `:latest` tag |
| D4 | No `FROM nixos/nix` in any stage | Nix fully removed | Any nix reference |
| D5 | No Alpine images for Node.js or Python runtimes | Debian/DHI only | `node:*-alpine` or `python:*-alpine` in runtime |

#### Security (D6-D12)

| # | Check | PASS | FAIL |
|---|-------|------|------|
| D6 | No `apk add` or `apt-get` in production/runtime stage | All installs in -dev/build stages | Package manager used in runtime stage |
| D7 | No `USER` directive needed (DHI is non-root by default) | No `USER` or `adduser`/`useradd` | Manual user creation in runtime stage |
| D8 | No `su-exec` or `gosu` | Direct execution | Privilege dropping at runtime |
| D9 | No shell scripts that require bash/sh in runtime image | Node.js/Python entrypoints or compiled binary | `#!/bin/bash` entrypoint in DHI runtime (no shell) |
| D10 | Healthcheck uses native runtime | `CMD ["node", "healthcheck.js"]` or `CMD ["python", "healthcheck.py"]` | `curl`, `wget`, `CMD-SHELL` |
| D11 | No setuid/setgid stripping needed | DHI has none | `find ... -perm /6000 ... chmod a-s` present |
| D12 | HEALTHCHECK directive present in Dockerfile | Defined with interval/timeout/retries/start_period | Missing or incomplete |

#### Build Hygiene (D13-D20)

| # | Check | PASS | FAIL |
|---|-------|------|------|
| D13 | Multi-stage build with separate build and runtime | At least 2 stages | Single stage with build tools in production |
| D14 | `RUN_TESTS` build arg for optional test stage | Test stage with conditional execution | No test stage or tests always run |
| D15 | OCI labels present | version, created, revision at minimum | No labels |
| D16 | APP_VERSION build arg with VERSION file | `echo "${APP_VERSION}" > /app/VERSION` | No version tracking |
| D17 | BuildKit cache mounts for package managers | `--mount=type=cache,target=...` | No cache mounts |
| D18 | `.dockerignore` exists and excludes: node_modules, .git, .env, dist, coverage | All excluded | Missing or incomplete |
| D19 | No inline nix flake generation | Clean -dev stage | `cat > flake.nix` or `nix-env -iA` |
| D20 | COPY uses `--chown` where needed | Ownership set at copy time | `chown` RUN commands after COPY |

#### Entrypoint (D21-D23)

| # | Check | PASS | FAIL |
|---|-------|------|------|
| D21 | Entrypoint handles signals (exec form or tini/dumb-init) | `exec node ...` or signal-aware init | Missing exec, no signal handling |
| D22 | No runtime `chown` on startup | Permissions set at build time | `chown` in entrypoint script |
| D23 | Secret injection from AWS Secrets Manager | Fetches at startup, not baked in | Secrets in ENV, .env, or build args |

### Docker Compose Audit

#### Security (C1-C6)

| # | Check | PASS | FAIL |
|---|-------|------|------|
| C1 | `read_only: true` on all application services | All app services | Any app service missing read_only |
| C2 | `security_opt: [no-new-privileges:true]` on all services | All services | Any service missing |
| C3 | `cap_drop: [ALL]` on all services | All services | Missing cap_drop or partial drop |
| C4 | No `cap_add` except documented exceptions (see Known Exceptions) | No cap_add needed with DHI | Unnecessary capabilities added |
| C5 | No `privileged: true` anywhere | Never | Any privileged container |
| C6 | No hardcoded secrets/passwords in base compose | Only ENVIRONMENT and REGION | Passwords, API keys, tokens |

#### Resource Management (C7-C10)

| # | Check | PASS | FAIL |
|---|-------|------|------|
| C7 | `deploy.resources.limits` on all application services | CPU + memory limits set | Missing limits |
| C8 | `deploy.resources.reservations` on all application services | CPU + memory reservations set | Missing reservations |
| C9 | tmpfs mounts have size limits | `size=<limit>` on all tmpfs | Unlimited tmpfs |
| C10 | tmpfs mounts have `noexec,nosuid` flags | Flags present | Missing security flags |

#### Networking & Healthchecks (C11-C14b)

| # | Check | PASS | FAIL |
|---|-------|------|------|
| C11 | Network segmentation: `<project>-public` and `<project>-private` networks defined | Both networks present | Single network, default network, or host network |
| C11a | Frontend/admin services on `<project>-public` only | Not on private network | Frontend on private network (can reach DB directly) |
| C11b | Database/cache/queue services on `<project>-private` only | Not on public network | Database on public network (exposed to frontend) |
| C11c | Bridge service on both networks (backend if frontend calls it directly; nginx if it forwards API requests) | Bridges public and private | Bridge on only one network (breaks connectivity) |
| C12 | Healthcheck defined for every service | test, interval, timeout, retries, start_period | Missing healthcheck |
| C13 | Native healthcheck command (no curl/wget/CMD-SHELL) | `CMD ["node", ...]` or `CMD ["python", ...]` | Shell-based healthcheck |
| C14 | `depends_on` with `condition: service_healthy` | Health-gated startup ordering | No condition or `service_started` only |

#### Logging & Operations (C15-C17)

| # | Check | PASS | FAIL |
|---|-------|------|------|
| C15 | `logging` configured with rotation on all services | json-file with max-size and max-file | Missing logging config |
| C16 | No `:latest` tags in base compose | All images version-pinned | `:latest` in production compose |
| C17 | Image names use ECR variable pattern | `${ECR_REGISTRY:-}...` | Hardcoded registry URLs |

#### Compose Split (C18-C22)

| # | Check | PASS | FAIL |
|---|-------|------|------|
| C18 | No database containers in base compose | Databases in override only | MySQL/Postgres in base |
| C19 | No mock services in base compose | Mocks in override only | Mock APIs in base |
| C20 | No Traefik labels in base compose | Labels in override only | Traefik config in base |
| C21 | No AWS credential mounts in base compose | `~/.aws` mount in override only | Credential mounts in base |
| C22 | No hardcoded dev passwords in base compose | Passwords in override only | Dev credentials in base |

#### CI/CD & DHI Access (C23-C25)

| # | Check | PASS | FAIL |
|---|-------|------|------|
| C23 | `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN` configured in CI/CD secrets | Secrets exist and pipeline authenticates to `dhi.io` | Missing credentials or no DHI login step |
| C24 | DHI login step runs before `docker build` in pipeline | `docker/login-action` or equivalent before build | Build pulls from `dhi.io` without auth |
| C25 | Production deployments pull from ECR, not `dhi.io` | Deploy steps reference `${ECR_REGISTRY}` | Production pulls directly from `dhi.io` |

### Scoring Thresholds

| Score | Threshold | Action |
|-------|-----------|--------|
| **All PASS** | 100% | Compliant. No action needed. |
| **WARN** (1-3) | 90%+ | Document and schedule fix within 2 weeks. |
| **Any security FAIL** (D6-D12, C1-C6) | — | Fix immediately before next deployment. |

### Running the Audit

```bash
# 1. Check base images in all Dockerfiles
grep -rn "^FROM " */Dockerfile Dockerfile 2>/dev/null

# 2. Check for nix references
grep -rn "nixos\|nix-env\|nix develop\|flake.nix" */Dockerfile Dockerfile 2>/dev/null

# 3. Check for Alpine in runtime stages
grep -n "alpine" */Dockerfile Dockerfile 2>/dev/null

# 4. Check compose security
grep -n "read_only\|no-new-privileges\|cap_drop\|cap_add\|privileged" docker-compose.yml

# 5. Check for secrets/passwords in base compose
grep -n "PASSWORD\|SECRET\|TOKEN\|KEY\|password\|secret" docker-compose.yml

# 6. Check for resource limits
grep -n "resources\|limits\|reservations\|cpus\|memory" docker-compose.yml

# 7. Check for logging config
grep -n "logging\|max-size\|max-file" docker-compose.yml

# 8. Check for unpinned images
grep -n ":latest" docker-compose.yml docker-compose.override.yml

# 9. Scan for CVEs
trivy image --vex repo <your-image>

# 10. Verify non-root
docker compose run --rm <service> id
```

### Known Exceptions

Document any exceptions here. Each exception must have a reason and an expiry date.

| Exception | Reason | Project | Expires |
|-----------|--------|---------|---------|
| PHP uses `php:8.3-fpm-bookworm` not DHI | `docker-php-ext-install` required for extension management | (future PHP projects) | Re-evaluate when DHI PHP documents extension support |
| nginx `cap_add: NET_BIND_SERVICE` | Only if binding port 80/443 directly (not needed with DHI port 8080) | Legacy only | Remove when migrated to DHI nginx |

### Lambda / Serverless Exemption

Dockerfiles in `lambda/` or `serverless/` directories are **exempt** from container hardening
checks. Lambda runtime manages the execution environment — no multi-stage builds, no USER
directive, no read_only, no health checks required. Version pinning and `.dockerignore`
still apply. The `/docker-audit` command automatically skips these directories.

---

## Checklist

Before deploying any container:

### Required Files

| File | Purpose | Git |
|------|---------|-----|
| `Dockerfile` (or per-service) | Multi-stage build, non-root user, BuildKit, pinned base | Committed |
| `docker-compose.yml` | Base: app services, hardening, health checks, internal network | Committed |
| `docker-compose.override.yml` | Dev: Traefik, dev infra, credential mounts, secret path overrides | Committed |
| `.env.example` | Template showing required env vars | Committed |
| `.env` | Local env values (environment-specific) | Gitignored |
| `.dockerignore` | Excludes .git, node_modules, .env, etc. from build context | Committed |

### Global Checks

- [ ] Docker Compose v2.24+ (`docker compose version`)
- [ ] BuildKit enabled (`# syntax=docker/dockerfile:1` in all Dockerfiles)
- [ ] All images pinned to specific version (no `:latest`, no floating major tags)
- [ ] DHI `-dev` images used for build stages, DHI runtime images for dev/production
- [ ] Multi-stage Dockerfile with testing stage (`ARG RUN_TESTS=false`)
- [ ] Non-root user in all runtime stages (DHI: automatic; non-DHI: `USER app`, UID 1000, GID 1000)
- [ ] `read_only: true` on all application services — all environments
- [ ] `no-new-privileges:true` on all application services
- [ ] `cap_drop: [ALL]` on all application services
- [ ] `deploy.resources.limits` on all application services (tested under load)
- [ ] `restart: unless-stopped` on all services (or PROJECT.yaml override)
- [ ] Health check on **every** service (app, infra, dev-only)
- [ ] Health checks tuned: `interval: 10s`, `timeout: 5s`, `retries: 5`
- [ ] `start_period` set per service based on measured startup time
- [ ] Zero secrets in compose, .env, or Dockerfile — 100% from secrets manager
- [ ] Dev infrastructure uses Docker secrets with `_FILE` mechanism
- [ ] Container names follow `<project>-<service>` pattern
- [ ] Networks `<project>-public` and `<project>-private` defined
- [ ] Frontend/admin on public only, databases/caches on private only, backend on both
- [ ] `.dockerignore` present and comprehensive
- [ ] Container images scanned with Trivy before registry push

### Environment-Specific Checks

See [Docker — Work](docker-work.md) and [Docker — Home](docker-home.md) for
environment-specific checklists covering secrets integration, compose interpolation
variables, CI/CD pipeline configuration, and credential mounts.
