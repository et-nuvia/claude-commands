# Add Secret

## Tracking

As your **first action**, before any other work, run:
```bash
~/.claude/scripts/track-command.sh --command "add-secret" --event start
```

If the workflow encounters an unrecoverable error at any point, run:
```bash
~/.claude/scripts/track-command.sh --command "add-secret" --event error \\
  --model "MODEL_ID" \\
  --error-msg "brief description of what failed"
```
Add secrets to the appropriate backend based on environment. Both backends use identical structure.

## Prerequisites

**Requires PROJECT.yaml** - If not present, run `/project-config init` first.

```bash
# Check for PROJECT.yaml
if [[ ! -f "PROJECT.yaml" ]]; then
  echo "Error: PROJECT.yaml not found. Run /project-config init first."
  exit 1
fi
```

---

## Unified Secret Structure

Both AWS Secrets Manager and Infisical use the same path and structure:

### Path Pattern
```
{app}/{environment}/{bucket}
```

Example paths:
```
myapp/development/database
myapp/staging/database
myapp/production/database
```

### Bucket Contents (JSON)
Each bucket contains related secrets as a JSON object:

```json
{
  "host": "db.dev.example.com",
  "port": "5432",
  "username": "app_user",
  "password": "secret123",
  "database": "myapp_dev"
}
```

---

## Environment Detection

```bash
# From PROJECT.yaml
APP_NAME=$(yq '.name' PROJECT.yaml)
SECRETS_BACKEND=$(yq '.secrets.backend // ""' PROJECT.yaml)

# Auto-detect if not specified using centralized detection
if [[ -z "$SECRETS_BACKEND" || "$SECRETS_BACKEND" == "null" ]]; then
  SECRETS_BACKEND=$("${HOME}/.claude/scripts/detect-environment.sh" secrets-backend)
fi
```

---

## AWS Secrets Manager (Work)

### Create Secret Bucket
```bash
APP_NAME=$(yq '.name' PROJECT.yaml)
BUCKET="database"
ENV="development"  # development, staging, production

aws secretsmanager create-secret \
  --name "${APP_NAME}/${ENV}/${BUCKET}" \
  --description "${BUCKET} credentials for ${APP_NAME}" \
  --secret-string '{
    "host": "db.dev.example.com",
    "port": "5432",
    "username": "app_user",
    "password": "dev_password",
    "database": "myapp_dev"
  }'
```

### Add/Update Value in Bucket
```bash
# Get current values
CURRENT=$(aws secretsmanager get-secret-value \
  --secret-id "${APP_NAME}/${ENV}/${BUCKET}" \
  --query SecretString --output text)

# Add new value
UPDATED=$(echo "$CURRENT" | jq '. + {"ssl_mode": "require"}')

# Update secret
aws secretsmanager update-secret \
  --secret-id "${APP_NAME}/${ENV}/${BUCKET}" \
  --secret-string "$UPDATED"
```

### Grant IAM Access
```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": ["secretsmanager:GetSecretValue"],
    "Resource": ["arn:aws:secretsmanager:*:*:secret:myapp/*"]
  }]
}
```

---

## Infisical (Home)

Instance: `secrets.turnersrus.com`

Infisical stores secrets as key-value pairs. To match the AWS JSON structure, we store the entire bucket as a single secret with JSON value.

### Create Secret Bucket
```bash
APP_NAME=$(yq '.name' PROJECT.yaml)
BUCKET="database"
ENV="development"  # development, staging, production

# Store as single JSON secret matching AWS structure
infisical secrets set \
  --projectId "${INFISICAL_PROJECT_ID}" \
  --env "${ENV}" \
  --path "/${APP_NAME}/${BUCKET}" \
  --type shared \
  DATA='{
    "host": "db.dev.example.com",
    "port": "5432",
    "username": "app_user",
    "password": "dev_password",
    "database": "myapp_dev"
  }'
```

### Add/Update Value in Bucket
```bash
# Get current value
CURRENT=$(infisical secrets get DATA \
  --projectId "${INFISICAL_PROJECT_ID}" \
  --env "${ENV}" \
  --path "/${APP_NAME}/${BUCKET}" \
  --plain)

# Add new value
UPDATED=$(echo "$CURRENT" | jq '. + {"ssl_mode": "require"}')

# Update secret
infisical secrets set \
  --projectId "${INFISICAL_PROJECT_ID}" \
  --env "${ENV}" \
  --path "/${APP_NAME}/${BUCKET}" \
  DATA="$UPDATED"
```

### Web UI Structure
In Infisical web UI at secrets.turnersrus.com:
```
Project: myapp
├── Development
│   ├── /myapp/database     → DATA: {"host": "...", "port": "...", ...}
│   ├── /myapp/redis        → DATA: {"host": "...", "port": "...", ...}
│   └── /myapp/smtp         → DATA: {"host": "...", ...}
├── Staging
│   └── ...
└── Production
    └── ...
```

---

## Application Code

### Python - Unified Interface
```python
import os
import json
import platform
from functools import lru_cache
from pathlib import Path
import yaml

def load_project_config() -> dict:
    """Load PROJECT.yaml configuration."""
    project_file = Path("PROJECT.yaml")
    if not project_file.exists():
        raise FileNotFoundError("PROJECT.yaml not found. Run /project-config init")
    return yaml.safe_load(project_file.read_text())

def get_secrets_backend() -> str:
    """Detect secrets backend from PROJECT.yaml or environment."""
    config = load_project_config()
    backend = config.get("secrets", {}).get("backend")
    if backend:
        return backend
    # Auto-detect
    return "aws" if platform.system() == "Darwin" else "infisical"

def get_app_name() -> str:
    """Get app name from PROJECT.yaml."""
    config = load_project_config()
    return config["name"]

@lru_cache(maxsize=32)
def get_secret_bucket(bucket: str) -> dict[str, str]:
    """
    Fetch secrets from {app}/{env}/{bucket}.
    Returns JSON object with secret values.
    """
    backend = get_secrets_backend()
    app = get_app_name()
    env = os.environ["ENVIRONMENT"]

    if backend == "aws":
        return _get_aws_secret(f"{app}/{env}/{bucket}")
    else:
        return _get_infisical_secret(app, env, bucket)

def _get_aws_secret(secret_id: str) -> dict[str, str]:
    """Fetch from AWS Secrets Manager."""
    import boto3
    client = boto3.client("secretsmanager", region_name=os.environ["REGION"])
    response = client.get_secret_value(SecretId=secret_id)
    return json.loads(response["SecretString"])

def _get_infisical_secret(app: str, env: str, bucket: str) -> dict[str, str]:
    """Fetch from Infisical - same structure as AWS."""
    from infisical_client import ClientSettings, InfisicalClient

    client = InfisicalClient(ClientSettings(
        client_id=os.environ.get("INFISICAL_CLIENT_ID"),
        client_secret=os.environ["INFISICAL_SECRET"],
        site_url="https://secrets.turnersrus.com"
    ))

    # Get the DATA secret which contains the JSON bucket
    secret = client.getSecret(
        project_id=os.environ["INFISICAL_PROJECT_ID"],
        environment=env,
        path=f"/{app}/{bucket}",
        secret_name="DATA"
    )
    return json.loads(secret.secret_value)

# Usage - identical regardless of backend
db = get_secret_bucket("database")
DATABASE_URL = f"postgresql://{db['username']}:{db['password']}@{db['host']}:{db['port']}/{db['database']}"
```

### Node.js - Unified Interface
```typescript
import { platform } from "os";
import { readFileSync, existsSync } from "fs";
import { parse } from "yaml";

interface ProjectConfig {
  name: string;
  secrets?: { backend?: "aws" | "infisical" };
}

function loadProjectConfig(): ProjectConfig {
  if (!existsSync("PROJECT.yaml")) {
    throw new Error("PROJECT.yaml not found. Run /project-config init");
  }
  return parse(readFileSync("PROJECT.yaml", "utf-8"));
}

function getSecretsBackend(): "aws" | "infisical" {
  const config = loadProjectConfig();
  if (config.secrets?.backend) return config.secrets.backend;
  return platform() === "darwin" ? "aws" : "infisical";
}

function getAppName(): string {
  return loadProjectConfig().name;
}

const secretCache = new Map<string, Record<string, string>>();

async function getSecretBucket(bucket: string): Promise<Record<string, string>> {
  if (secretCache.has(bucket)) return secretCache.get(bucket)!;

  const backend = getSecretsBackend();
  const app = getAppName();
  const env = process.env.ENVIRONMENT!;

  let secrets: Record<string, string>;

  if (backend === "aws") {
    secrets = await getAwsSecret(`${app}/${env}/${bucket}`);
  } else {
    secrets = await getInfisicalSecret(app, env, bucket);
  }

  secretCache.set(bucket, secrets);
  return secrets;
}

async function getAwsSecret(secretId: string): Promise<Record<string, string>> {
  const { SecretsManagerClient, GetSecretValueCommand } = await import(
    "@aws-sdk/client-secrets-manager"
  );
  const client = new SecretsManagerClient({ region: process.env.REGION });
  const response = await client.send(new GetSecretValueCommand({ SecretId: secretId }));
  return JSON.parse(response.SecretString!);
}

async function getInfisicalSecret(
  app: string,
  env: string,
  bucket: string
): Promise<Record<string, string>> {
  const { InfisicalClient } = await import("@infisical/sdk");
  const client = new InfisicalClient({
    clientId: process.env.INFISICAL_CLIENT_ID,
    clientSecret: process.env.INFISICAL_SECRET!,
    siteUrl: "https://secrets.turnersrus.com",
  });

  // Get the DATA secret which contains the JSON bucket
  const secret = await client.getSecret({
    projectId: process.env.INFISICAL_PROJECT_ID!,
    environment: env,
    path: `/${app}/${bucket}`,
    secretName: "DATA",
  });

  return JSON.parse(secret.secretValue);
}

// Usage - identical regardless of backend
const db = await getSecretBucket("database");
const connectionString = `postgresql://${db.username}:${db.password}@${db.host}:${db.port}/${db.database}`;
```

---

## Docker Compose Environment

### Work (macOS/AWS)
```yaml
environment:
  - ENVIRONMENT=development
  - REGION=us-east-1
```

### Home (WSL/Infisical)
```yaml
environment:
  - ENVIRONMENT=development
  - INFISICAL_SECRET=${INFISICAL_SECRET}
  - INFISICAL_PROJECT_ID=${INFISICAL_PROJECT_ID}
```

---

## Common Buckets

| Bucket | Keys |
|--------|------|
| `database` | host, port, username, password, database, ssl_mode |
| `redis` | host, port, password |
| `smtp` | host, port, username, password, from_address |
| `oauth/{provider}` | client_id, client_secret, redirect_uri |
| `api-keys` | key names as keys, values as values |

---

## PROJECT.yaml Secrets Section

```yaml
secrets:
  backend: ""  # "aws" or "infisical" - auto-detected if empty
  required:
    - database
    - redis
    - smtp

  refresh:
    enabled: true
    interval_seconds: 300  # 5 minutes

    strategies:
      python:
        type: "inline"
      nestjs:
        type: "inline"
      nextjs:
        type: "file"
        template_dir: ".secrets-templates"
        target_files:
          - ".env.local"
        restart_command: "pm2 restart nextjs"
```

---

## Secret Refresh Strategies

Different frameworks require different approaches for refreshing secrets at runtime.

### Python (Inline Refresh)

Secrets are refreshed in-memory using a background task:

```python
import asyncio
import json
from pathlib import Path
import yaml

_secret_cache: dict[str, dict] = {}
_cache_lock = asyncio.Lock()

def load_refresh_config() -> dict:
    """Load refresh config from PROJECT.yaml."""
    config = yaml.safe_load(Path("PROJECT.yaml").read_text())
    return config.get("secrets", {}).get("refresh", {})

async def refresh_secrets_loop():
    """Background task to refresh secrets periodically."""
    config = load_refresh_config()
    if not config.get("enabled", False):
        return

    interval = config.get("interval_seconds", 300)

    while True:
        await asyncio.sleep(interval)
        async with _cache_lock:
            # Clear cache to force re-fetch on next access
            _secret_cache.clear()
            print(f"Secret cache cleared, will refresh on next access")

@lru_cache(maxsize=32)
def get_secret_bucket(bucket: str) -> dict[str, str]:
    """Fetch secrets - cache is cleared by refresh loop."""
    # ... existing implementation ...
    pass

# Start refresh loop in your app startup
# asyncio.create_task(refresh_secrets_loop())
```

### Node.js Backend (Inline Refresh)

For Express, Fastify, or plain Node.js backends using `node-cron`:

```typescript
// secrets.ts
import cron from 'node-cron';
import { readFileSync, existsSync } from 'fs';
import { parse } from 'yaml';

interface ProjectConfig {
  name: string;
  secrets?: {
    backend?: 'aws' | 'infisical';
    refresh?: {
      enabled?: boolean;
      interval_seconds?: number;
    };
  };
}

let config: ProjectConfig;
const secretCache = new Map<string, Record<string, string>>();

function loadConfig(): ProjectConfig {
  if (!existsSync('PROJECT.yaml')) {
    throw new Error('PROJECT.yaml not found. Run /project-config init');
  }
  return parse(readFileSync('PROJECT.yaml', 'utf-8'));
}

function getSecretsBackend(): 'aws' | 'infisical' {
  if (!config) config = loadConfig();
  if (config.secrets?.backend) return config.secrets.backend;
  return process.platform === 'darwin' ? 'aws' : 'infisical';
}

export async function getSecretBucket(bucket: string): Promise<Record<string, string>> {
  if (secretCache.has(bucket)) {
    return secretCache.get(bucket)!;
  }

  if (!config) config = loadConfig();
  const app = config.name;
  const env = process.env.ENVIRONMENT!;
  const backend = getSecretsBackend();

  let secrets: Record<string, string>;
  if (backend === 'aws') {
    secrets = await fetchFromAws(`${app}/${env}/${bucket}`);
  } else {
    secrets = await fetchFromInfisical(app, env, bucket);
  }

  secretCache.set(bucket, secrets);
  return secrets;
}

async function fetchFromAws(secretId: string): Promise<Record<string, string>> {
  const { SecretsManagerClient, GetSecretValueCommand } = await import('@aws-sdk/client-secrets-manager');
  const client = new SecretsManagerClient({ region: process.env.REGION });
  const response = await client.send(new GetSecretValueCommand({ SecretId: secretId }));
  return JSON.parse(response.SecretString!);
}

async function fetchFromInfisical(app: string, env: string, bucket: string): Promise<Record<string, string>> {
  const { InfisicalClient } = await import('@infisical/sdk');
  const client = new InfisicalClient({
    clientId: process.env.INFISICAL_CLIENT_ID,
    clientSecret: process.env.INFISICAL_SECRET!,
    siteUrl: 'https://secrets.turnersrus.com',
  });
  const secret = await client.getSecret({
    projectId: process.env.INFISICAL_PROJECT_ID!,
    environment: env,
    path: `/${app}/${bucket}`,
    secretName: 'DATA',
  });
  return JSON.parse(secret.secretValue);
}

// Initialize refresh on app startup
export function initSecretRefresh(): void {
  config = loadConfig();
  const refreshConfig = config.secrets?.refresh;

  if (!refreshConfig?.enabled) {
    console.log('Secret refresh disabled');
    return;
  }

  const intervalSec = refreshConfig.interval_seconds || 300;
  const cronExpr = `*/${Math.ceil(intervalSec / 60)} * * * *`; // Convert to minutes

  cron.schedule(cronExpr, () => {
    console.log(`[${new Date().toISOString()}] Clearing secret cache...`);
    secretCache.clear();
  });

  console.log(`Secret refresh scheduled every ${intervalSec} seconds`);
}

// Usage in app.ts:
// import { initSecretRefresh, getSecretBucket } from './secrets';
// initSecretRefresh();
// const db = await getSecretBucket('database');
```

### NestJS (Inline Refresh)

Uses `@nestjs/schedule` for periodic refresh:

```typescript
// secrets.service.ts
import { Injectable, OnModuleInit } from '@nestjs/common';
import { Cron, CronExpression } from '@nestjs/schedule';
import { readFileSync, existsSync } from 'fs';
import { parse } from 'yaml';

interface ProjectConfig {
  secrets?: {
    refresh?: {
      enabled?: boolean;
      interval_seconds?: number;
    };
  };
}

@Injectable()
export class SecretsService implements OnModuleInit {
  private cache = new Map<string, Record<string, string>>();
  private refreshEnabled = false;
  private refreshInterval = 300;

  onModuleInit() {
    if (existsSync('PROJECT.yaml')) {
      const config: ProjectConfig = parse(readFileSync('PROJECT.yaml', 'utf-8'));
      this.refreshEnabled = config.secrets?.refresh?.enabled ?? false;
      this.refreshInterval = config.secrets?.refresh?.interval_seconds ?? 300;
    }
  }

  // Run every 5 minutes (adjust based on PROJECT.yaml config)
  @Cron(CronExpression.EVERY_5_MINUTES)
  async handleSecretRefresh() {
    if (!this.refreshEnabled) return;

    console.log('Refreshing secret cache...');
    this.cache.clear();
  }

  async getSecretBucket(bucket: string): Promise<Record<string, string>> {
    if (this.cache.has(bucket)) {
      return this.cache.get(bucket)!;
    }

    const secrets = await this.fetchFromBackend(bucket);
    this.cache.set(bucket, secrets);
    return secrets;
  }

  private async fetchFromBackend(bucket: string): Promise<Record<string, string>> {
    // ... fetch from AWS or Infisical ...
  }
}
```

### Next.js (File-based Refresh)

Next.js bakes environment variables at build time. To refresh secrets:

1. **Create template files** with placeholders
2. **Run cron job** to fetch secrets and replace placeholders
3. **Restart** the Next.js process

#### Step 1: Create Template Directory

```bash
mkdir -p .secrets-templates
cp .env.local .secrets-templates/.env.local.template
```

Edit the template to use placeholders:
```bash
# .secrets-templates/.env.local.template
DATABASE_URL=__SECRET_DATABASE_URL__
REDIS_URL=__SECRET_REDIS_URL__
API_KEY=__SECRET_API_KEY__
```

#### Step 2: Create Refresh Script

```bash
#!/bin/bash
# scripts/refresh-nextjs-secrets.sh

set -euo pipefail

source "$(dirname "$0")/lib/project-config.sh"
require_project_config

APP_NAME=$(get_app_name)
ENV="${ENVIRONMENT:-development}"
TEMPLATE_DIR=$(yq '.secrets.refresh.strategies.nextjs.template_dir // ".secrets-templates"' PROJECT.yaml)
RESTART_CMD=$(yq '.secrets.refresh.strategies.nextjs.restart_command // ""' PROJECT.yaml)

echo "Refreshing Next.js secrets for ${APP_NAME}/${ENV}..."

# Fetch all required buckets
BUCKETS=$(yq '.secrets.required[]' PROJECT.yaml)

# Build sed replacement commands
SED_ARGS=""
for bucket in $BUCKETS; do
    # Fetch bucket JSON
    if [[ "$(get_secrets_backend)" == "aws" ]]; then
        SECRETS=$(aws secretsmanager get-secret-value \
            --secret-id "${APP_NAME}/${ENV}/${bucket}" \
            --query SecretString --output text)
    else
        SECRETS=$(infisical secrets get DATA \
            --projectId "${INFISICAL_PROJECT_ID}" \
            --env "${ENV}" \
            --path "/${APP_NAME}/${bucket}" \
            --plain)
    fi

    # Parse each key from the bucket JSON
    for key in $(echo "$SECRETS" | jq -r 'keys[]'); do
        value=$(echo "$SECRETS" | jq -r ".${key}")
        placeholder="__SECRET_${bucket^^}_${key^^}__"
        SED_ARGS="${SED_ARGS} -e 's|${placeholder}|${value}|g'"
    done
done

# Process each target file
TARGET_FILES=$(yq '.secrets.refresh.strategies.nextjs.target_files[]' PROJECT.yaml)
for target in $TARGET_FILES; do
    template="${TEMPLATE_DIR}/${target}.template"
    if [[ -f "$template" ]]; then
        echo "Updating ${target} from template..."
        eval "sed ${SED_ARGS} '${template}'" > "${target}"
    fi
done

# Restart if configured
if [[ -n "$RESTART_CMD" ]]; then
    echo "Restarting Next.js: ${RESTART_CMD}"
    eval "$RESTART_CMD"
fi

echo "Secret refresh complete!"
```

#### Step 3: Add Cron Job

```bash
# Add to crontab (refresh every 5 minutes)
*/5 * * * * cd /opt/myapp && ./scripts/refresh-nextjs-secrets.sh >> /var/log/secret-refresh.log 2>&1
```

#### Step 4: Docker Setup

For containerized Next.js, add to your entrypoint:

```dockerfile
# Dockerfile
COPY scripts/refresh-nextjs-secrets.sh /usr/local/bin/
COPY .secrets-templates /app/.secrets-templates

# Install cron
RUN apt-get update && apt-get install -y cron

# Add cron job
RUN echo "*/5 * * * * /usr/local/bin/refresh-nextjs-secrets.sh >> /var/log/cron.log 2>&1" | crontab -

# Entrypoint runs initial refresh then starts app
COPY docker-entrypoint.sh /
ENTRYPOINT ["/docker-entrypoint.sh"]
```

```bash
#!/bin/bash
# docker-entrypoint.sh
set -e

# Initial secret refresh
/usr/local/bin/refresh-nextjs-secrets.sh

# Start cron in background
cron

# Start Next.js
exec "$@"
```

### Node.js Frontend (File-based Refresh)

For bundled frontends (Vite, Webpack, Create React App), secrets are baked at build time.
Use the same file-based approach as Next.js:

```bash
# .secrets-templates/.env.template
VITE_API_URL=__SECRET_API_URL__
VITE_ANALYTICS_KEY=__SECRET_ANALYTICS_KEY__
```

The refresh script rebuilds the bundle:

```yaml
# PROJECT.yaml
secrets:
  refresh:
    strategies:
      nodejs_frontend:
        type: "file"
        template_dir: ".secrets-templates"
        target_files:
          - ".env"
        rebuild_command: "npm run build"
```

**Note**: For SPAs, consider fetching non-sensitive config from an API endpoint instead
of baking into the bundle. Only use file-based refresh for truly static deployments.

### PHP (Inline Refresh)

PHP backends use Laravel's Cache facade for automatic refresh:

```php
<?php
// app/Services/SecretsService.php

namespace App\Services;

use Illuminate\Support\Facades\Cache;
use Aws\SecretsManager\SecretsManagerClient;
use Symfony\Component\Yaml\Yaml;

class SecretsService
{
    private array $config;
    private string $backend;
    private string $appName;
    private int $ttl;

    public function __construct()
    {
        $this->loadConfig();
    }

    private function loadConfig(): void
    {
        $projectFile = base_path('PROJECT.yaml');
        if (!file_exists($projectFile)) {
            throw new \RuntimeException('PROJECT.yaml not found. Run /project-config init');
        }

        $this->config = Yaml::parseFile($projectFile);
        $this->appName = $this->config['name'];
        $this->backend = $this->config['secrets']['backend']
            ?? (PHP_OS === 'Darwin' ? 'aws' : 'infisical');
        $this->ttl = $this->config['secrets']['refresh']['interval_seconds'] ?? 300;
    }

    /**
     * Get secrets from {app}/{env}/{bucket}.
     * Cached for TTL seconds, then auto-refreshed.
     */
    public function getSecretBucket(string $bucket): array
    {
        $env = env('ENVIRONMENT', 'development');
        $cacheKey = "secrets.{$this->appName}.{$env}.{$bucket}";

        return Cache::remember($cacheKey, $this->ttl, function () use ($bucket, $env) {
            if ($this->backend === 'aws') {
                return $this->fetchFromAws("{$this->appName}/{$env}/{$bucket}");
            } else {
                return $this->fetchFromInfisical($env, $bucket);
            }
        });
    }

    /**
     * Force refresh a specific bucket (useful for webhooks/manual refresh).
     */
    public function refreshBucket(string $bucket): array
    {
        $env = env('ENVIRONMENT', 'development');
        $cacheKey = "secrets.{$this->appName}.{$env}.{$bucket}";
        Cache::forget($cacheKey);
        return $this->getSecretBucket($bucket);
    }

    private function fetchFromAws(string $secretId): array
    {
        $client = new SecretsManagerClient([
            'region' => env('REGION', 'us-east-1'),
            'version' => 'latest',
        ]);

        $result = $client->getSecretValue(['SecretId' => $secretId]);
        return json_decode($result['SecretString'], true);
    }

    private function fetchFromInfisical(string $env, string $bucket): array
    {
        $client = new \GuzzleHttp\Client();
        $response = $client->get("https://secrets.turnersrus.com/api/v3/secrets", [
            'headers' => [
                'Authorization' => 'Bearer ' . env('INFISICAL_TOKEN'),
            ],
            'query' => [
                'workspaceId' => env('INFISICAL_PROJECT_ID'),
                'environment' => $env,
                'path' => "/{$this->appName}/{$bucket}",
            ],
        ]);

        $secrets = json_decode($response->getBody(), true);
        foreach ($secrets['secrets'] as $secret) {
            if ($secret['secretKey'] === 'DATA') {
                return json_decode($secret['secretValue'], true);
            }
        }
        return [];
    }
}
```

Register as singleton in `AppServiceProvider`:

```php
// app/Providers/AppServiceProvider.php
public function register(): void
{
    $this->app->singleton(SecretsService::class);
}
```

Usage:
```php
// In any controller or service
$secrets = app(SecretsService::class);
$db = $secrets->getSecretBucket('database');
$connectionString = sprintf(
    'pgsql://%s:%s@%s:%s/%s',
    $db['username'], $db['password'], $db['host'], $db['port'], $db['database']
);
```

### React (File-based Refresh)

React apps (Create React App, Vite) bake environment variables at build time.
Use the same approach as Next.js with template files.

#### Step 1: Create Templates

```bash
mkdir -p .secrets-templates
cp .env .secrets-templates/.env.template
```

Edit template with placeholders:
```bash
# .secrets-templates/.env.template
REACT_APP_API_URL=__SECRET_API_URL__
REACT_APP_ANALYTICS_KEY=__SECRET_ANALYTICS_KEY__
VITE_API_URL=__SECRET_API_URL__
VITE_STRIPE_PUBLIC_KEY=__SECRET_STRIPE_PUBLIC_KEY__
```

#### Step 2: PROJECT.yaml Config

```yaml
secrets:
  refresh:
    enabled: true
    interval_seconds: 300
    strategies:
      react:
        type: "file"
        template_dir: ".secrets-templates"
        target_files:
          - ".env"
          - ".env.production"
        rebuild_command: "npm run build"
```

#### Step 3: Refresh Script

Use the same `refresh-nextjs-secrets.sh` script - it works for any file-based refresh.

```bash
# Link or copy the script
cp ~/.claude/scripts/refresh-nextjs-secrets.sh ./scripts/refresh-secrets.sh
chmod +x ./scripts/refresh-secrets.sh
```

#### Step 4: CI/CD Integration

For React apps, typically refresh happens at deploy time (not via cron):

```yaml
# .gitlab-ci.yml
deploy:
  script:
    - ./scripts/refresh-secrets.sh
    - npm run build
    - # deploy built files...
```

**Important**: For SPAs, avoid putting sensitive secrets in frontend builds.
Use API endpoints for sensitive data. Only put public keys (Stripe publishable key,
analytics IDs, API URLs) in frontend env vars.

---

## Checklist

- [ ] PROJECT.yaml exists with `name` field
- [ ] Secret bucket created: `{app}/{env}/{bucket}`
- [ ] Bucket contains JSON with all required keys
- [ ] All environments have the bucket (dev, staging, prod)
- [ ] Application uses unified `get_secret_bucket()` interface
- [ ] Values cached in memory (not fetched on every use)
- [ ] No secrets in docker-compose.yml or .env
- [ ] Only ENVIRONMENT + (REGION or INFISICAL_SECRET) in .env
- [ ] Updated PROJECT.yaml `secrets.required` list

---

## Completion Tracking

When the workflow completes successfully, run:
```bash
~/.claude/scripts/track-command.sh --command "add-secret" --event complete \
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