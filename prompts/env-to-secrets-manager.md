# Migrate Environment Variables to AWS Secrets Manager

Convert hardcoded environment variables and `.env` files to AWS Secrets Manager.

---

## Context

This prompt migrates secrets from environment variables and `.env` files to AWS Secrets Manager following the bucket pattern (grouped related secrets).

---

## Prerequisites

- AWS account with Secrets Manager access
- IAM roles configured for the application
- Understanding of which variables are actually secrets vs configuration

---

## Prompt

```
I want to migrate this project's environment variables and secrets to AWS Secrets Manager.

## Analysis Phase

First, analyze current secret usage:

1. **Find all environment variable sources:**
   - `.env` files (`.env`, `.env.local`, `.env.development`, etc.)
   - `docker-compose.yml` environment sections
   - Kubernetes manifests / Helm values
   - CI/CD variable configurations
   - Hardcoded in application code

2. **Categorize each variable:**

   **KEEP as environment variables** (minimal - ONLY these):
   - `ENVIRONMENT` (development, staging, production)
   - `REGION` (us-east-1, etc.) - **Work environment ONLY**

   **MIGRATE to Secrets Manager** (everything else):
   - Database credentials (host, user, password, database)
   - API keys (Stripe, SendGrid, etc.)
   - OAuth credentials (client_id, client_secret)
   - Encryption keys
   - JWT secrets
   - SMTP credentials
   - Third-party service tokens
   - Configuration values:
     - `LOG_LEVEL`
     - `PORT`
     - `WORKERS`
     - `NODE_ENV`
     - Feature flags
     - Timeout values
     - Pool sizes
     - Host names (internal services)

3. **Group into logical buckets:**
   - `database` - DB connection details
   - `redis` - Redis connection details
   - `smtp` - Email service credentials
   - `oauth/{provider}` - OAuth per provider
   - `api-keys` - Third-party API keys
   - `encryption` - Encryption keys and secrets

## Secret Structure

Use this path pattern:
```
{project}/{environment}/{bucket}
```

Example:
```
myapp/development/database
myapp/staging/database
myapp/production/database
```

Each bucket contains JSON with related values:
```json
{
  "host": "db.example.com",
  "port": "5432",
  "username": "app_user",
  "password": "secret123",
  "database": "myapp"
}
```

## Migration Steps

### Step 1: Create secrets in AWS

For each bucket and environment:

```bash
# Database credentials
aws secretsmanager create-secret \
  --name "myapp/development/database" \
  --description "Database credentials" \
  --secret-string '{
    "host": "localhost",
    "port": "5432",
    "username": "postgres",
    "password": "devpass",
    "database": "myapp_dev"
  }'

# Repeat for staging and production with appropriate values
```

### Step 2: Create secrets helper module

**Python:**
```python
# src/core/secrets.py
import boto3
import json
import os
from functools import lru_cache
from typing import Any

@lru_cache(maxsize=1)
def _get_client():
    return boto3.client('secretsmanager', region_name=os.environ['REGION'])

@lru_cache(maxsize=32)
def get_secret_bucket(bucket: str) -> dict[str, Any]:
    """Fetch a secret bucket from AWS Secrets Manager."""
    client = _get_client()
    project = "myapp"  # Or from config
    env = os.environ['ENVIRONMENT']

    response = client.get_secret_value(SecretId=f"{project}/{env}/{bucket}")
    return json.loads(response['SecretString'])

def get_secret(bucket: str, key: str) -> str:
    """Get a specific value from a secret bucket."""
    return get_secret_bucket(bucket)[key]
```

**Node.js/TypeScript:**
```typescript
// src/lib/secrets.ts
import { SecretsManagerClient, GetSecretValueCommand } from "@aws-sdk/client-secrets-manager";

const client = new SecretsManagerClient({ region: process.env.REGION });
const cache = new Map<string, Record<string, string>>();

export async function getSecretBucket(bucket: string): Promise<Record<string, string>> {
  if (cache.has(bucket)) {
    return cache.get(bucket)!;
  }

  const project = "myapp";
  const env = process.env.ENVIRONMENT!;

  const command = new GetSecretValueCommand({
    SecretId: `${project}/${env}/${bucket}`,
  });

  const response = await client.send(command);
  const secrets = JSON.parse(response.SecretString!);
  cache.set(bucket, secrets);
  return secrets;
}

export async function getSecret(bucket: string, key: string): Promise<string> {
  const secrets = await getSecretBucket(bucket);
  return secrets[key];
}
```

### Step 3: Update application code

Replace environment variable reads with secret fetches:

**Before:**
```python
DATABASE_URL = os.environ['DATABASE_URL']
```

**After:**
```python
db = get_secret_bucket('database')
DATABASE_URL = f"postgresql://{db['username']}:{db['password']}@{db['host']}:{db['port']}/{db['database']}"
```

### Step 4: Update docker-compose.yml

**Before:**
```yaml
services:
  app:
    environment:
      - DATABASE_URL=postgresql://user:pass@db:5432/myapp
      - STRIPE_API_KEY=sk_test_xxx
```

**After:**
```yaml
services:
  app:
    environment:
      - ENVIRONMENT=development
      - REGION=us-east-1
    volumes:
      - ~/.aws:/home/app/.aws:ro  # For local dev only
```

### Step 5: Update deployment configuration

Add IAM permissions for the application:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["secretsmanager:GetSecretValue"],
      "Resource": ["arn:aws:secretsmanager:*:*:secret:myapp/*"]
    }
  ]
}
```

### Step 6: Clean up

1. Remove secrets from `.env` files
2. Remove secrets from docker-compose.yml
3. Remove secrets from CI/CD variables
4. Add `.env` patterns to `.gitignore` if not already
5. Update documentation

## Validation

After migration:
- Application starts without `.env` file
- All features using secrets work correctly
- No secrets in environment variables (check `docker compose exec app env`)
- Secrets accessible in all environments
- CI/CD pipeline works

## Files to Update

- Application code (secret reads)
- `docker-compose.yml`
- `.env.example` (document non-secret vars only)
- Deployment manifests
- CI/CD configuration
- Documentation

Now analyze this project and migrate the secrets to AWS Secrets Manager.
```

---

## Rollback

If migration causes issues:
1. Restore `.env` files from git or backup
2. Revert application code changes
3. Restore docker-compose.yml environment section
