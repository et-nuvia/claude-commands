# Infisical Setup Guide - Machine Identity Pattern

**Last Updated:** 2026-01-01
**Security Model:** Maximize secrets manager usage, minimal hardcoding

---

## Overview

This guide shows how to use Infisical with Docker containers using the most secure pattern:
- **Only `ENVIRONMENT` in .env files**
- Bootstrap config (URL, CLIENT_ID, PROJECT_ID) defined once in docker-compose.yml using YAML anchors
- Bootstrap config injected into all services via anchor reference
- Client secret only as Docker secret file (never in compose)
- **All application secrets and configuration fetched from Infisical**

---

## Step 1: Create Machine Identities in Infisical

### 1.1 Access Infisical UI

Go to: `https://secrets.turnersrus.com/project/{your-project}/settings/machine-identities`

### 1.2 Create Identity for Each Environment

Create machine identities per environment (shared by all services):

```
bullbarn-staging    # Used by backend, frontend, celery in staging
bullbarn-production # Used by backend, frontend, celery in production
```

**Note:** All services in an environment share the same machine identity. Services fetch their own secrets from Infisical based on service name path.

### 1.3 Save Credentials

For each machine identity, Infisical generates:
- **Client ID** (e.g., `a1b2c3d4-e5f6-7890-abcd-ef1234567890`)
- **Client Secret** (e.g., `st.abc123.xyz789...`)

**Important:**
- Client ID: Will be in docker-compose.yml (YAML anchor, passed as env var to containers)
- Client Secret: Will be Docker secret file (from GitLab CI/CD variable for staging/production, local file for development)

### 1.4 Grant Permissions

For each machine identity:
1. Click "Grant Access to Project"
2. Select environment (dev, staging, or prod)
3. Set permissions:
   - Backend/Celery: Read secrets
   - Admin services: Read/Write (if needed)

---

## Step 2: Store Client Secrets in GitLab CI/CD

### 2.1 Add Variables to GitLab

Go to: `Settings → CI/CD → Variables`

Add these variables (mark as "Protected" and "Masked"):

```
INFISICAL_CLIENT_SECRET_STAGING=st.abc123...     # Shared by all services in staging
INFISICAL_CLIENT_SECRET_PRODUCTION=st.def456...  # Shared by all services in production
```

**Note:** One client secret per environment, shared by all services (backend, frontend, worker, etc.)

---

## Step 3: Create Entrypoint Script

Create `entrypoint.sh` in each service directory (backend, frontend, etc.):

### Backend Example (`backend/entrypoint.sh`)

```bash
#!/bin/sh
set -e

# =============================================================================
# Infisical Bootstrap - Fetch secrets at container startup
# =============================================================================

# Bootstrap config from environment variables (injected via YAML anchor in docker-compose.yml)
# INFISICAL_URL, INFISICAL_CLIENT_ID, INFISICAL_PROJECT_ID are set by docker-compose

# Read client secret from Docker secret file
CLIENT_SECRET=$(cat /run/secrets/infisical_client_secret)

# Get environment from env var
ENV_NAME="${ENVIRONMENT:-dev}"

# Verify all bootstrap credentials present
if [ -z "$INFISICAL_URL" ] || [ -z "$INFISICAL_CLIENT_ID" ] || \
   [ -z "$INFISICAL_PROJECT_ID" ] || [ -z "$CLIENT_SECRET" ]; then
    echo "ERROR: Missing Infisical bootstrap credentials" >&2
    exit 1
fi

# Exchange client secret for short-lived access token
echo "Authenticating with Infisical..."
ACCESS_TOKEN=$(curl -sf -X POST "${INFISICAL_URL}/api/v1/auth/universal-auth/login" \
  -H "Content-Type: application/json" \
  -d "{\"clientId\":\"${INFISICAL_CLIENT_ID}\",\"clientSecret\":\"${CLIENT_SECRET}\"}" \
  | jq -r '.accessToken')

if [ -z "$ACCESS_TOKEN" ] || [ "$ACCESS_TOKEN" = "null" ]; then
    echo "ERROR: Failed to authenticate with Infisical" >&2
    exit 1
fi

# Fetch secrets and export to environment
echo "Fetching secrets from environment: ${ENV_NAME}..."
eval $(curl -sf "${INFISICAL_URL}/api/v3/secrets/raw?environment=${ENV_NAME}&workspaceId=${INFISICAL_PROJECT_ID}" \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  | jq -r '.secrets[] | "export \(.secretKey)=\"\(.secretValue)\""')

# Verify critical secrets were loaded
if [ -z "$DATABASE_URL" ] || [ -z "$JWT_SECRET" ]; then
    echo "ERROR: Critical secrets not loaded from Infisical" >&2
    exit 1
fi

# Clear sensitive tokens from memory
unset CLIENT_SECRET ACCESS_TOKEN

echo "Secrets loaded successfully"

# Execute application with secrets in environment
exec "$@"
```

### Frontend Example (`frontend/entrypoint.sh`)

```bash
#!/bin/sh
set -e

# Bootstrap config from environment variables (same as backend)
# INFISICAL_URL, INFISICAL_CLIENT_ID, INFISICAL_PROJECT_ID from docker-compose.yml

CLIENT_SECRET=$(cat /run/secrets/infisical_client_secret)
ENV_NAME="${ENVIRONMENT:-dev}"

# Read client secret
if [ ! -f /run/secrets/infisical_client_secret ]; then
    echo "ERROR: /run/secrets/infisical_client_secret not found" >&2
    exit 1
fi
CLIENT_SECRET=$(cat /run/secrets/infisical_client_secret)

# Authenticate
ACCESS_TOKEN=$(curl -sf -X POST "${INFISICAL_URL}/api/v1/auth/universal-auth/login" \
  -H "Content-Type: application/json" \
  -d "{\"clientId\":\"${INFISICAL_CLIENT_ID}\",\"clientSecret\":\"${CLIENT_SECRET}\"}" \
  | jq -r '.accessToken')

if [ -z "$ACCESS_TOKEN" ] || [ "$ACCESS_TOKEN" = "null" ]; then
    echo "ERROR: Failed to authenticate with Infisical" >&2
    exit 1
fi

# Fetch secrets
echo "Fetching secrets from environment: ${ENV_NAME}..."
eval $(curl -sf "${INFISICAL_URL}/api/v3/secrets/raw?environment=${ENV_NAME}&workspaceId=${INFISICAL_PROJECT_ID}" \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  | jq -r '.secrets[] | "export \(.secretKey)=\"\(.secretValue)\""')

# Clear tokens
unset CLIENT_SECRET ACCESS_TOKEN

# Next.js needs secrets at build time for some features
# Export them to .env.local for the build/runtime
cat > /app/.env.local << EOF
INTERNAL_API_URL=${INTERNAL_API_URL}
# Add other runtime secrets as needed
EOF

echo "Secrets loaded successfully"

# Execute Next.js
exec "$@"
```

---

## Step 4: Update Dockerfile

Add entrypoint and ensure `curl` and `jq` are installed:

### Backend Dockerfile

```dockerfile
FROM python:3.13-slim

# Install dependencies including curl and jq for secrets fetching
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    jq \
    && rm -rf /var/lib/apt/lists/*

# Copy entrypoint
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Application code
WORKDIR /app
COPY . .

ENTRYPOINT ["/entrypoint.sh"]
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
```

### Frontend Dockerfile

```dockerfile
FROM node:22-alpine

# Install curl and jq
RUN apk add --no-cache curl jq

# Copy entrypoint
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

WORKDIR /app
COPY . .

ENTRYPOINT ["/entrypoint.sh"]
CMD ["npm", "run", "start"]
```

---

## Step 5: Docker Compose Configuration

### docker-compose.yml

```yaml
# Define bootstrap config ONCE at top (YAML anchor)
x-infisical-bootstrap: &infisical-bootstrap
  INFISICAL_URL: "https://secrets.turnersrus.com"
  INFISICAL_CLIENT_ID: "a1b2c3d4-e5f6-7890-abcd-ef1234567890"
  INFISICAL_PROJECT_ID: "4fc89a1a-cd59-46c5-809b-8997cc2353a2"

services:
  backend:
    build: ./backend
    environment:
      ENVIRONMENT: staging
      <<: *infisical-bootstrap  # Inject bootstrap config
    secrets:
      - infisical_client_secret
    networks:
      - app-network

  frontend:
    build: ./frontend
    environment:
      ENVIRONMENT: staging
      <<: *infisical-bootstrap  # Same config, no duplication
    secrets:
      - infisical_client_secret
    networks:
      - app-network

secrets:
  infisical_client_secret:
    file: ./secrets/infisical_client_secret  # Only sensitive value

networks:
  app-network:
```

### .env File

```bash
ENVIRONMENT=staging
```

**That's it. One line.**

**Bootstrap config in docker-compose.yml** (YAML anchor, defined once at top):
- `INFISICAL_URL`, `INFISICAL_CLIENT_ID`, `INFISICAL_PROJECT_ID`
- Written once, referenced by all services

**Client secret in file** (gitignored):
- `secrets/infisical_client_secret`

**All other configuration fetched from Infisical:**
- Application secrets (DATABASE_URL, JWT_SECRET, API_KEYS)
- Configuration (LOG_LEVEL, PORT, WORKERS, REDIS_HOST)

---

## Step 6: GitLab CI/CD Deployment

### .gitlab-ci.yml

```yaml
deploy:staging:
  stage: deploy
  script:
    - |
      ssh ${DEPLOY_USER}@${DEPLOY_HOST} "
        set -e
        cd ${DEPLOY_PATH}

        # Create secrets directory
        mkdir -p secrets
        chmod 700 secrets

        # Write client secret from CI variable
        echo '${INFISICAL_CLIENT_SECRET_STAGING}' > secrets/infisical_client_secret
        chmod 600 secrets/infisical_client_secret

        # Create minimal .env
        echo 'ENVIRONMENT=staging' > .env

        # Deploy (bootstrap config in docker-compose.yml)
        docker compose pull
        docker compose up -d
      "
```

---

## Step 7: All Services Share Same Bootstrap Credentials

**All services in an environment use the same machine identity:**

- Backend, frontend, worker all use same INFISICAL_CLIENT_ID/SECRET for staging
- Services fetch their own secrets from Infisical based on path (e.g., `/backend/*`, `/frontend/*`)
- One set of bootstrap credentials per environment, shared by all services
- Simplifies secret management - no per-service credentials needed

---

## Security Verification

### What's Visible (Safe)

```bash
# Environment variables - should only show ENVIRONMENT
docker exec backend env
# Expected: ENVIRONMENT=staging (plus secrets loaded by entrypoint)

# Docker secrets are NOT in environment
docker inspect backend | grep -i infisical
# Expected: no sensitive data, just mount point
```

### What's Hidden (Secure)

- Client secrets stored in `/run/secrets/` (tmpfs, cleared on stop)
- Not visible in `docker inspect`
- Not in Git history
- Not in docker-compose.yml
- Only in CI/CD variables and memory at runtime

---

## Troubleshooting

### Container fails to start

```bash
# Check logs
docker logs backend

# Common issues:
# 1. Secret file not mounted
docker exec backend ls -la /run/secrets/

# 2. Invalid client secret
# Verify in Infisical UI that machine identity is active

# 3. Wrong environment name
# Check ENVIRONMENT variable matches Infisical environment (dev/staging/prod)
```

### Secrets not loading

```bash
# Test authentication manually
CLIENT_SECRET=$(cat secrets/backend_client_secret)
curl -X POST "https://secrets.turnersrus.com/api/v1/auth/universal-auth/login" \
  -H "Content-Type: application/json" \
  -d "{\"clientId\":\"YOUR_CLIENT_ID\",\"clientSecret\":\"${CLIENT_SECRET}\"}"
```

---

## Code Examples

Language-specific Infisical implementation templates in [docs/code/](../code/):

- [Python + Infisical](../code/python/secrets-infisical.md)
- [Next.js + Infisical](../code/typescript/nextjs/secrets-infisical.md)
- [Node.js Backend + Infisical](../code/typescript/nodejs-backend/secrets-infisical.md)
- [React + Infisical](../code/typescript/react/secrets-infisical.md)

---

## Summary

**Allowed in config files:** `ENVIRONMENT` only
**Client secret:** Docker secret (tmpfs)
**Everything else:** Hardcoded in entrypoint.sh

This pattern minimizes attack surface and keeps configuration out of version control and environment variables.
