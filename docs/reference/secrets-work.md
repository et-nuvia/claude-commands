# AWS Secrets Manager Implementation Guide

**Last Updated:** 2026-01-01
**Environment:** Work (macOS)
**Secrets Backend:** AWS Secrets Manager
**Bootstrap Method:** IAM roles (no secrets needed)

---

## Overview

AWS Secrets Manager with IAM roles provides the most secure bootstrap pattern - no bootstrap secret is needed at all. The IAM role attached to your compute resource (EC2, ECS, Lambda) provides authentication.

---

## Allowed Environment Variables

```bash
ENVIRONMENT=production  # Required
REGION=us-east-1    # Required for work environment
```

**That's it. Two variables. Nothing else.**

No LOG_LEVEL, no WORKERS, no PORT, no DATABASE_HOST, no credentials, no secret IDs.

**Everything else fetched from AWS Secrets Manager:**
- Application secrets (DATABASE_URL, JWT_SECRET, API_KEYS)
- Configuration (LOG_LEVEL, PORT, WORKERS, REDIS_HOST)
- All environment-specific settings

**No hardcoding needed** - IAM role provides authentication to fetch secrets.

---

## How It Works

### Authentication Flow

```
Container/Lambda starts
  ↓
Application uses AWS SDK
  ↓
SDK uses default credential chain:
  1. Environment variables (none in our case)
  2. Container credentials (ECS task role)
  3. Instance profile (EC2 IAM role)
  4. Lambda execution role
  ↓
AWS Secrets Manager API call (authenticated by IAM role)
  ↓
Secrets returned and cached in application memory
```

**Key advantage:** No bootstrap secret to manage. IAM role IS the authentication.

---

## IAM Role Configuration

### Required IAM Policy

Attach this policy to your ECS task role, EC2 instance profile, or Lambda execution role:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowSecretsAccess",
      "Effect": "Allow",
      "Action": [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret"
      ],
      "Resource": [
        "arn:aws:secretsmanager:us-east-1:ACCOUNT_ID:secret:prod/*",
        "arn:aws:secretsmanager:us-east-1:ACCOUNT_ID:secret:staging/*"
      ]
    }
  ]
}
```

**Best practices:**
- Use least privilege - only allow secrets for this environment
- Use resource tags for fine-grained access control
- Separate roles for staging vs production

---

## Secret Naming Convention

```
{environment}/{service}/{secret-name}

Examples:
prod/backend/database-url
prod/backend/jwt-secret
staging/backend/database-url
staging/backend/jwt-secret
```

**Benefits:**
- Clear ownership and environment separation
- Easy to apply IAM policies by prefix
- Audit trail by service

---

## Implementation Patterns

### Pattern 1: Fetch at Application Startup (Python)

```python
# app/core/secrets.py
import os
import boto3
from functools import lru_cache
from botocore.exceptions import ClientError

class AWSSecretsClient:
    """Fetch secrets from AWS Secrets Manager using IAM role."""

    def __init__(self, region: str, environment: str):
        self.client = boto3.client('secretsmanager', region_name=region)
        self.environment = environment
        self._cache = {}

    def get_secret(self, secret_name: str) -> str:
        """
        Fetch secret by name. Adds environment prefix automatically.

        Example:
            get_secret('backend/database-url')
            -> Fetches 'prod/backend/database-url'
        """
        if secret_name not in self._cache:
            full_name = f"{self.environment}/{secret_name}"
            try:
                response = self.client.get_secret_value(SecretId=full_name)
                self._cache[secret_name] = response['SecretString']
            except ClientError as e:
                error_code = e.response['Error']['Code']
                if error_code == 'ResourceNotFoundException':
                    raise ValueError(f"Secret not found: {full_name}")
                elif error_code == 'AccessDeniedException':
                    raise ValueError(f"Access denied to secret: {full_name}. Check IAM role permissions.")
                else:
                    raise
        return self._cache[secret_name]

    def get_secrets_batch(self, secret_names: list[str]) -> dict[str, str]:
        """Fetch multiple secrets at once."""
        return {name: self.get_secret(name) for name in secret_names}


@lru_cache
def get_secrets_client() -> AWSSecretsClient:
    """Get singleton secrets client."""
    region = os.environ.get('REGION', 'us-east-1')
    environment = os.environ.get('ENVIRONMENT', 'production')
    return AWSSecretsClient(region, environment)
```

### Application Settings

```python
# app/core/config.py
import os
from functools import lru_cache
from app.core.secrets import get_secrets_client

secrets = get_secrets_client()

class Settings:
    """Application settings with secrets from AWS Secrets Manager."""

    # Environment (from env var - ONLY allowed variable)
    ENVIRONMENT: str = os.environ.get('ENVIRONMENT', 'production')
    REGION: str = os.environ.get('REGION', 'us-east-1')

    # Secrets and configuration (ALL from AWS Secrets Manager)
    DATABASE_URL: str = secrets.get_secret('backend/database-url')
    JWT_SECRET: str = secrets.get_secret('backend/jwt-secret')
    REDIS_URL: str = secrets.get_secret('backend/redis-url')
    API_KEY: str = secrets.get_secret('backend/api-key')

    # Configuration values also from secrets manager
    LOG_LEVEL: str = secrets.get_secret('backend/log-level')
    WORKERS: int = int(secrets.get_secret('backend/workers'))
    PORT: int = int(secrets.get_secret('backend/port'))

    # Change these in AWS Secrets Manager, restart to apply - no rebuild needed


@lru_cache
def get_settings() -> Settings:
    """Get singleton settings instance."""
    return Settings()
```

### Startup Validation

```python
# app/main.py
from fastapi import FastAPI
from app.core.config import get_settings

app = FastAPI()

@app.on_event("startup")
async def startup_event():
    """Validate all secrets loaded on startup."""
    settings = get_settings()

    # Access all secrets to trigger loading and validation
    required_secrets = [
        settings.DATABASE_URL,
        settings.JWT_SECRET,
        settings.REDIS_URL,
    ]

    print(f"✓ All secrets loaded successfully for {settings.ENVIRONMENT}")
```

---

## Docker Configuration

### Dockerfile (No Changes Needed)

```dockerfile
FROM python:3.13-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

# No entrypoint.sh needed - application fetches secrets directly
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
```

### .env File (Work Environment)

```bash
ENVIRONMENT=production
REGION=us-east-1
```

**Two lines. Nothing else.**

### docker-compose.yml (Local Testing with LocalStack)

```yaml
services:
  backend:
    build: ./backend
    environment:
      - ENVIRONMENT=development  # ONLY allowed variables
      - REGION=us-east-1
    depends_on:
      - localstack

  localstack:
    image: localstack/localstack:latest
    environment:
      - SERVICES=secretsmanager
    ports:
      - "4566:4566"
```

**Note:** For LocalStack, AWS SDK will use fake credentials automatically. Don't put them in .env.

---

## ECS Task Definition

```json
{
  "family": "backend",
  "taskRoleArn": "arn:aws:iam::ACCOUNT_ID:role/backend-task-role",
  "executionRoleArn": "arn:aws:iam::ACCOUNT_ID:role/ecs-execution-role",
  "networkMode": "awsvpc",
  "containerDefinitions": [
    {
      "name": "backend",
      "image": "ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com/backend:1.2.3",
      "environment": [
        {
          "name": "ENVIRONMENT",
          "value": "production"
        },
        {
          "name": "REGION",
          "value": "us-east-1"
        }
      ],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "/ecs/backend",
          "awslogs-region": "us-east-1",
          "awslogs-stream-prefix": "backend"
        }
      }
    }
  ]
}
```

**Note:** `taskRoleArn` provides IAM permissions to fetch secrets. No credentials in config!

---

## Lambda Function Configuration

### lambda_function.py

```python
import os
import json
from app.core.secrets import get_secrets_client

# Initialize secrets client (cached across Lambda invocations)
secrets = get_secrets_client()

def handler(event, context):
    """Lambda handler with secrets from AWS Secrets Manager."""

    # Secrets fetched on first access, cached for subsequent invocations
    database_url = secrets.get_secret('backend/database-url')
    api_key = secrets.get_secret('backend/api-key')

    # Your application logic here
    return {
        'statusCode': 200,
        'body': json.dumps('Success')
    }
```

### Lambda Configuration (Terraform)

```hcl
resource "aws_lambda_function" "backend" {
  filename      = "backend.zip"
  function_name = "backend-production"
  role          = aws_iam_role.lambda_role.arn
  handler       = "lambda_function.handler"
  runtime       = "python3.13"

  environment {
    variables = {
      ENVIRONMENT = "production"
      REGION  = "us-east-1"
    }
  }

  # Lambda execution role has permissions to fetch secrets
}

resource "aws_iam_role_policy" "lambda_secrets" {
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue"
        ]
        Resource = [
          "arn:aws:secretsmanager:us-east-1:*:secret:prod/*"
        ]
      }
    ]
  })
}
```

---

## Secret Rotation

### Rotate Application Secret (No Code Changes)

```bash
# 1. Update secret in AWS Secrets Manager
aws secretsmanager update-secret \
  --secret-id prod/backend/database-url \
  --secret-string "postgresql://new-password@..."

# 2. Restart ECS tasks or Lambda (fetch new value)
aws ecs update-service \
  --cluster production \
  --service backend \
  --force-new-deployment
```

### Automatic Rotation (AWS Feature)

```bash
# Enable automatic rotation for RDS credentials
aws secretsmanager rotate-secret \
  --secret-id prod/backend/database-url \
  --rotation-lambda-arn arn:aws:lambda:us-east-1:ACCOUNT:function:SecretsManagerRDSPostgreSQLRotation \
  --rotation-rules AutomaticallyAfterDays=30
```

---

## Security Best Practices

### 1. Use Resource-Based Policies

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::ACCOUNT_ID:role/backend-task-role"
      },
      "Action": "secretsmanager:GetSecretValue",
      "Resource": "*",
      "Condition": {
        "StringEquals": {
          "secretsmanager:ResourceTag/Environment": "production",
          "secretsmanager:ResourceTag/Service": "backend"
        }
      }
    }
  ]
}
```

### 2. Enable Secret Versioning

All secrets in AWS Secrets Manager are versioned automatically. Use versions for rollback:

```python
# Get specific version
response = client.get_secret_value(
    SecretId='prod/backend/database-url',
    VersionId='EXAMPLE-VERSION-ID'
)
```

### 3. Enable CloudTrail Logging

Monitor all secrets access:

```bash
aws cloudtrail lookup-events \
  --lookup-attributes AttributeKey=ResourceType,AttributeValue=AWS::SecretsManager::Secret
```

---

## Troubleshooting

### AccessDeniedException

**Error:** `User: arn:aws:sts::ACCOUNT:assumed-role/ROLE is not authorized to perform: secretsmanager:GetSecretValue`

**Fix:**
```bash
# 1. Verify IAM role policy
aws iam get-role-policy --role-name backend-task-role --policy-name secrets-access

# 2. Check secret ARN matches policy resource
aws secretsmanager describe-secret --secret-id prod/backend/database-url

# 3. Verify task role is attached (ECS)
aws ecs describe-task-definition --task-definition backend | jq '.taskDefinition.taskRoleArn'
```

### ResourceNotFoundException

**Error:** `Secrets Manager can't find the specified secret`

**Fix:**
```bash
# List all secrets with prefix
aws secretsmanager list-secrets --filters Key=name,Values=prod/backend/

# Verify secret name matches exactly (case-sensitive)
```

### Credentials Not Found

**Error:** `Unable to locate credentials`

**Fix:**
```bash
# 1. Verify instance profile attached (EC2)
aws ec2 describe-instances --instance-ids i-xxx | jq '.Reservations[].Instances[].IamInstanceProfile'

# 2. Test credentials from within container
aws sts get-caller-identity

# 3. Check execution role (ECS)
aws ecs describe-tasks --cluster production --tasks TASK_ID | jq '.tasks[].containers[].lastStatus'
```

---

## Local Development

### Option 1: LocalStack (Recommended)

```yaml
# docker-compose.yml
services:
  backend:
    environment:
      - ENVIRONMENT=development
      - REGION=us-east-1
      - AWS_ENDPOINT_URL=http://localstack:4566
      - AWS_ACCESS_KEY_ID=test
      - AWS_SECRET_ACCESS_KEY=test

  localstack:
    image: localstack/localstack:latest
    environment:
      - SERVICES=secretsmanager
    volumes:
      - ./localstack-init.sh:/etc/localstack/init/ready.d/init.sh
```

```bash
# localstack-init.sh - Create secrets on startup
#!/bin/bash
awslocal secretsmanager create-secret \
  --name dev/backend/database-url \
  --secret-string "postgresql://localhost/dev"
```

### Option 2: Override for Local Development

```python
# app/core/config.py
import os
from app.core.secrets import get_secrets_client

secrets = get_secrets_client()

class Settings:
    ENVIRONMENT = os.environ.get('ENVIRONMENT', 'production')
    REGION = os.environ.get('REGION', 'us-east-1')

    # Override for local development (hardcoded, not from .env)
    if ENVIRONMENT == 'development':
        DATABASE_URL = "postgresql://localhost/dev"
        JWT_SECRET = "dev-secret-not-secure"
    else:
        DATABASE_URL = secrets.get_secret('backend/database-url')
        JWT_SECRET = secrets.get_secret('backend/jwt-secret')
```

**No .env file with multiple variables. Override in code if needed.**

---

## Migration from Infisical

If migrating from Infisical to AWS Secrets Manager:

```python
# 1. Export secrets from Infisical
# (Use Infisical API or CLI)

# 2. Import to AWS Secrets Manager
import boto3
import json

client = boto3.client('secretsmanager', region_name='us-east-1')

secrets_to_migrate = {
    'prod/backend/database-url': 'postgresql://...',
    'prod/backend/jwt-secret': 'secret-key',
    # ...
}

for secret_name, secret_value in secrets_to_migrate.items():
    client.create_secret(
        Name=secret_name,
        SecretString=secret_value,
        Tags=[
            {'Key': 'Environment', 'Value': 'production'},
            {'Key': 'MigratedFrom', 'Value': 'Infisical'},
        ]
    )
```

---

## Summary

**AWS Secrets Manager with IAM roles provides:**
- No bootstrap secret needed (IAM role IS the authentication)
- Automatic credential rotation
- Audit logging via CloudTrail
- Fine-grained access control
- Version history for rollback

**Allowed environment variables:**
- `ENVIRONMENT`
- `REGION`

**Everything else fetched from AWS Secrets Manager at runtime.**

---

## Code Examples

Language-specific AWS Secrets Manager implementation templates in [docs/code/](../code/):

- [Python + AWS](../code/python/secrets-aws.md)
- [Next.js + AWS](../code/typescript/nextjs/secrets-aws.md)
- [Node.js Backend + AWS](../code/typescript/nodejs-backend/secrets-aws.md)
- [React + AWS](../code/typescript/react/secrets-aws.md)
