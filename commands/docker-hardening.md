---
name: docker-hardening
description: Apply Docker security hardening to containers and compose files
user_invocable: true
---

## Tracking

As your **first action**, before any other work, run:
```bash
~/.claude/scripts/track-command.sh --command "docker-hardening" --event start
```

If the workflow encounters an unrecoverable error at any point, run:
```bash
~/.claude/scripts/track-command.sh --command "docker-hardening" --event error \\
  --model "MODEL_ID" \\
  --error-msg "brief description of what failed"
```
# Docker Security Hardening

Apply these settings to all docker-compose.yml services and Dockerfiles.

## Compose Service Hardening

```yaml
services:
  app:
    image: myapp:1.0.0
    user: "1000:1000"
    read_only: true
    tmpfs:
      - /tmp:noexec,nosuid,size=100m
      - /var/run:noexec,nosuid,size=10m
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    # Only add back what's strictly needed:
    # cap_add:
    #   - NET_BIND_SERVICE  # if binding ports < 1024
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

## Required Settings Checklist

### Non-Negotiable
- [ ] `user: "1000:1000"` - never run as root
- [ ] `read_only: true` - immutable filesystem
- [ ] `security_opt: [no-new-privileges:true]`
- [ ] `cap_drop: [ALL]`

### Strongly Recommended
- [ ] `tmpfs` for writable directories (tmp, run, cache)
- [ ] Resource limits (CPU, memory)
- [ ] Core dumps disabled (`ulimits.core: 0`)
- [ ] Health check defined

## Common tmpfs Mounts by Application Type

**Python/FastAPI:**
```yaml
tmpfs:
  - /tmp:noexec,nosuid,size=100m
```

**Node.js/Next.js:**
```yaml
tmpfs:
  - /tmp:noexec,nosuid,size=100m
  - /app/.next/cache:noexec,nosuid,size=500m
```

**With file uploads (temporary):**
```yaml
tmpfs:
  - /tmp:noexec,nosuid,size=500m
  - /var/uploads:noexec,nosuid,size=1g
```

## Capabilities Reference

Only add capabilities that are strictly required:

| Capability | When Needed |
|------------|-------------|
| `NET_BIND_SERVICE` | Binding ports below 1024 |
| `CHOWN` | Changing file ownership at runtime |
| `SETUID`/`SETGID` | Switching users at runtime |
| `DAC_OVERRIDE` | Bypassing file permissions (avoid!) |

## Network Hardening

```yaml
services:
  app:
    networks:
      - frontend
    # Don't expose ports directly, use reverse proxy
    expose:
      - "8000"

  db:
    networks:
      - backend
    # Database never on frontend network

networks:
  frontend:
  backend:
    internal: true  # No external access
```

## Secrets Handling

```yaml
services:
  app:
    secrets:
      - db_password
    environment:
      # Only ENVIRONMENT and REGION as env vars
      - ENVIRONMENT=${ENVIRONMENT}
      - REGION=${REGION}

secrets:
  db_password:
    external: true  # Managed by orchestrator/secrets manager
```

## Validation Commands

After writing compose file, verify:

```bash
# Check for security issues
docker compose config --quiet && echo "Syntax OK"

# Scan built image
docker build -t myapp:test .
trivy image myapp:test

# Verify non-root
docker compose run --rm app id
# Should show: uid=1000(app) gid=1000(app)

# Verify read-only
docker compose run --rm app touch /test 2>&1 | grep -q "Read-only" && echo "Read-only OK"
```

## Completion Tracking

When the workflow completes successfully, run:
```bash
~/.claude/scripts/track-command.sh --command "docker-hardening" --event complete \
  --model "MODEL_ID" \
  --complexity COMPLEXITY \
  --tokens TOKENS_ESTIMATED \
  --cost COST_ESTIMATED
```

Replace values before calling:
- `MODEL_ID` — the model currently in use (from system context, e.g., `claude-sonnet-4-6`)
- `COMPLEXITY` — 1-5 based on: 1=read-only analysis, 2=single-file/simple git, 3=multi-file feature,
  4=cross-system/staging deploy, 5=production/infrastructure/security
- `TOKENS_ESTIMATED` — rough estimate of context used (input + output tokens combined)
- `COST_ESTIMATED` — approximate cost in USD based on model pricing
