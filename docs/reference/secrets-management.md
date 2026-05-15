# Secrets Management Guide - Universal Principles

**Last Updated:** 2026-03-17
**Audience:** All projects, all environments
**Purpose:** Backend-agnostic principles for secure secrets management

Global reference for secrets management. For environment-specific implementation, see:
- **[Secrets — Work (macOS/GitHub/AWS)](secrets-work.md)**
- **[Secrets — Home (WSL/GitLab/Infisical)](secrets-home.md)**

---

## Philosophy

**Secrets are NEVER stored in version control, docker-compose files, .env files, or environment variables.**

This is a **security requirement**, not a convenience preference.

---

## Core Principles

### 1. **Secret VALUES vs Bootstrap METADATA**

| Type | Examples | Storage | Why |
|------|----------|---------|-----|
| **Secret VALUES** | Database passwords, API keys, JWT signing keys, OAuth client secrets | Secrets manager only | Grants access, must be protected |
| **Bootstrap FILES** | Secrets manager URL, client ID, project ID, client secret | Docker secret files (`.secrets/`) | Needed before secrets manager access, mounted at `/run/secrets/` |
| **Configuration** | LOG_LEVEL, PORT, WORKERS, timeouts, pool sizes, API URLs | Secrets manager | Centralized management, change without rebuild |

### 2. **Minimal Environment Variables**

**THE RULE: Only `ENVIRONMENT` (+ `REGION` for work/AWS)**

**Home (WSL) .env:**
```bash
ENVIRONMENT=dev
```

**Work (macOS) .env:**
```bash
ENVIRONMENT=production
REGION=us-east-1
```

**That's it. Nothing else.**

### 3. **File-Based Bootstrap Pattern**

All Infisical bootstrap values are Docker secret files, NOT environment variables:

```
.secrets/                          # Local dev (gitignored)
├── infisical_url                  # https://secrets.turnersrus.com
├── infisical_client_id            # Machine identity client ID
├── infisical_client_secret        # Machine identity client secret
├── infisical_project_id           # Infisical project UUID
└── mysql_root_password            # (or other infrastructure secrets)
```

**docker-compose.yml:**
```yaml
secrets:
  infisical_url:
    file: ${SECRETS_PATH:-.secrets}/infisical_url
  infisical_client_id:
    file: ${SECRETS_PATH:-.secrets}/infisical_client_id
  infisical_client_secret:
    file: ${SECRETS_PATH:-.secrets}/infisical_client_secret
  infisical_project_id:
    file: ${SECRETS_PATH:-.secrets}/infisical_project_id

services:
  backend:
    environment:
      ENVIRONMENT: "${ENVIRONMENT:-production}"
    secrets:
      - infisical_url
      - infisical_client_id
      - infisical_client_secret
      - infisical_project_id
```

**Dev:** `SECRETS_PATH` defaults to `.secrets/` (local directory).
**Prod:** `SECRETS_PATH` set in `.env` by CI deploy job to absolute path on host.

### 4. **Containers Read from `/run/secrets/`**

All bootstrap values read from Docker secret files inside the container:

```bash
# entrypoint.sh or application code
INFISICAL_URL=$(cat /run/secrets/infisical_url)
INFISICAL_CLIENT_ID=$(cat /run/secrets/infisical_client_id)
INFISICAL_CLIENT_SECRET=$(cat /run/secrets/infisical_client_secret)
INFISICAL_PROJECT_ID=$(cat /run/secrets/infisical_project_id)
```

### 5. **Secrets Organized by Logical Domain**

Infisical folders group secrets by domain, not by service:

```
Project: my-app
├── /database
│   ├── host
│   ├── port
│   ├── app_username
│   ├── app_password
│   ├── migration_username
│   ├── migration_password
│   └── name
├── /authentik
│   ├── client_id
│   ├── client_secret
│   ├── issuer_url
│   ├── nextauth_url
│   └── nextauth_secret
├── /admin
│   └── session_secret
└── /config
    └── api_url
```

Each service loads only the folders/keys it needs. Backend loads `/database`, `/authentik`, `/admin`. Frontend loads `/authentik`, `/config`.

### 6. **Fail Fast on Missing Secrets**

**Never use fallback values or defaults.**

```bash
# WRONG - Silent fallback
DATABASE_URL="${DATABASE_URL:-postgresql://localhost/dev}"

# RIGHT - Explicit failure
if [ -z "$value" ] || [ "$value" = "null" ]; then
    echo "FATAL: Secret '${key}' not found at path '/${path}'"
    exit 1
fi
```

### 7. **No Hardcoded Credentials Anywhere**

Database init scripts, CI pipelines, docker-compose files -- nothing gets hardcoded credentials. Everything fetches from the secrets manager at runtime.

---

## Architecture Patterns

### Pattern 1: Entrypoint Bootstrap (Shell Scripts)

**Used by:** Frontend services, database init scripts, any service using shell entrypoints

```
Container starts
  ↓
Read bootstrap from /run/secrets/ files
  ↓
Authenticate with Infisical API (curl + jq)
  ↓
Fetch required secrets by folder/key
  ↓
Export to environment or use directly
  ↓
exec application
```

### Pattern 2: SDK Bootstrap (Application Code)

**Used by:** Backend services with native SDK support (NestJS, FastAPI)

```
Application starts
  ↓
Read bootstrap from /run/secrets/ files (fs.readFileSync)
  ↓
Initialize SDK client with bootstrap values
  ↓
Fetch secrets by folder/key into config object
  ↓
Hold in application memory
  ↓
Support runtime reload via API endpoint
```

### Pattern 3: Database Init Bootstrap

**Used by:** Database containers that need to create users on first start

```
Container starts (first boot only)
  ↓
Init script installs curl + jq (if not available)
  ↓
Read bootstrap from /run/secrets/ files
  ↓
Authenticate with Infisical API
  ↓
Fetch database credentials
  ↓
Create users with fetched credentials
```

---

## Secret Rotation

### Application Secrets

**Backend (API reload):**
1. Update secret in Infisical
2. POST to `/api/admin/reload-config`
3. Service re-fetches from Infisical without restart

**Frontend (container restart):**
1. Update secret in Infisical
2. Restart container
3. Entrypoint restores `.next` from template, re-runs sed with new values

### Bootstrap Secrets

1. Create new machine identity credentials in Infisical
2. Update CI/CD variables with new bootstrap values
3. Update `.secrets/` files locally
4. Redeploy

---

## Container Hardening

```yaml
services:
  backend:
    user: "1000:1000"
    read_only: true
    tmpfs:
      - /tmp
    cap_drop:
      - ALL
    security_opt:
      - no-new-privileges:true
    deploy:
      resources:
        limits:
          memory: 512M
          cpus: '1.0'
```

---

## GitLab CI Deployment Pattern

Deploy jobs write `.secrets/` files on the remote host from CI variables:

```yaml
deploy:
  script:
    - |
      ssh deploy@${DEPLOY_HOST} << DEPLOY_SCRIPT
        set -euo pipefail
        cd ${DEPLOY_PATH}

        # Write secrets files from CI variables
        mkdir -p ${DEPLOY_PATH}/.secrets
        echo -n '${INFISICAL_URL}' > ${DEPLOY_PATH}/.secrets/infisical_url
        echo -n '${INFISICAL_CLIENT_ID}' > ${DEPLOY_PATH}/.secrets/infisical_client_id
        echo -n '${INFISICAL_CLIENT_SECRET}' > ${DEPLOY_PATH}/.secrets/infisical_client_secret
        echo -n '${INFISICAL_PROJECT_ID}' > ${DEPLOY_PATH}/.secrets/infisical_project_id
        chmod 444 ${DEPLOY_PATH}/.secrets/*

        # Write .env
        echo "ENVIRONMENT=production" > ${DEPLOY_PATH}/.env
        echo "SECRETS_PATH=${DEPLOY_PATH}/.secrets" >> ${DEPLOY_PATH}/.env

        docker compose up -d
      DEPLOY_SCRIPT
```

---

## Security Verification

```bash
# 1. .env has ONLY ENVIRONMENT
cat .env
# Expected: ENVIRONMENT=dev

# 2. No secrets in docker-compose environment section
docker compose config | grep -A 5 "environment:"
# Expected: ONLY ENVIRONMENT

# 3. No secrets in git
git log -p | grep -i "password\|secret\|key" || echo "Clean"

# 4. Docker inspect shows no secret values
docker inspect backend | grep -iE "(password|secret|key)"
# Expected: Only mount points, not values
```

---

## Implementation Guides

- **Infisical (Home/WSL):** [Secrets — Home](secrets-home.md)
- **AWS Secrets Manager (Work/macOS):** [Secrets — Work](secrets-work.md)

---

## Code Examples

Language-specific implementation templates in [docs/code/](../code/):

**Python:**
- [Python + AWS Secrets Manager](../code/python/secrets-aws.md)
- [Python + Infisical](../code/python/secrets-infisical.md)

**TypeScript / Next.js:**
- [Next.js + AWS](../code/typescript/nextjs/secrets-aws.md)
- [Next.js + Infisical](../code/typescript/nextjs/secrets-infisical.md)

**TypeScript / Node.js Backend:**
- [Node.js Backend + AWS](../code/typescript/nodejs-backend/secrets-aws.md)
- [Node.js Backend + Infisical](../code/typescript/nodejs-backend/secrets-infisical.md)

**TypeScript / React:**
- [React + AWS](../code/typescript/react/secrets-aws.md)
- [React + Infisical](../code/typescript/react/secrets-infisical.md)

---

## Summary

1. ALL bootstrap values as Docker secret FILES (not env vars)
2. `.secrets/` directory with `${SECRETS_PATH:-.secrets}/` pattern
3. Only `ENVIRONMENT` (+ `REGION` for work) in `.env`
4. Secrets organized by logical domain in Infisical folders
5. Individual keys per folder (not JSON blobs)
6. Containers read bootstrap from `/run/secrets/` files
7. Fail fast on missing secrets -- no defaults, no fallbacks
8. DB init scripts fetch credentials from Infisical dynamically
9. Harden containers: read-only, non-root, no-new-privileges
