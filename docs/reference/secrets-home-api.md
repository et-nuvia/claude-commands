# Infisical API Guide

This guide documents how to interact with the Infisical API at `secrets.turnersrus.com` for programmatic secrets management.

## Authentication

### Machine Identity Setup

Machine Identities are used for programmatic API access. To set up:

1. **Create Machine Identity** in Infisical UI:
   - Go to Organization Settings → Machine Identities
   - Create new identity with descriptive name

2. **Enable Universal Auth**:
   - Click on the identity → Authentication Methods
   - Add Universal Auth
   - Configure TTL and trusted IPs as needed

3. **Generate Client Credentials**:
   - In Universal Auth settings, click "Add Client Secret"
   - Save both Client ID and Client Secret securely

### Authentication Flow

```bash
# Exchange credentials for access token
curl -X POST "https://secrets.turnersrus.com/api/v1/auth/universal-auth/login" \
  -H "Content-Type: application/json" \
  -d '{
    "clientId": "<client-id>",
    "clientSecret": "<client-secret>"
  }'

# Response
{
  "accessToken": "eyJhbGc...",
  "expiresIn": 2592000,
  "tokenType": "Bearer"
}
```

**Important**: The Client ID shown in the Infisical UI is what you need. Don't confuse it with the Identity ID (which is different).

### Token Usage

Include the access token in all subsequent API calls:

```bash
-H "Authorization: Bearer <access-token>"
```

---

## API Endpoints

### Projects (Workspaces)

#### Create Project

```bash
POST /api/v2/workspace
```

```bash
curl -X POST "https://secrets.turnersrus.com/api/v2/workspace" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "projectName": "my-project",
    "projectDescription": "Project description",
    "slug": "my-project",
    "type": "secret-manager",
    "shouldCreateDefaultEnvs": false
  }'
```

Response includes `project.id` needed for subsequent operations.

---

### Environments

#### Create Environment

```bash
POST /api/v1/projects/{projectId}/environments
```

```bash
curl -X POST "https://secrets.turnersrus.com/api/v1/projects/$PROJECT_ID/environments" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "Development",
    "slug": "dev",
    "position": 1
  }'
```

Standard environments to create:
| Position | Name | Slug |
|----------|------|------|
| 1 | Development | dev |
| 2 | Staging | staging |
| 3 | Production | prod |

---

### Secrets

#### Create Secret

```bash
POST /api/v3/secrets/raw/{secretName}
```

```bash
curl -X POST "https://secrets.turnersrus.com/api/v3/secrets/raw/DATABASE_URL" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "environment": "dev",
    "secretValue": "mongodb://localhost:27017",
    "workspaceId": "<project-id>",
    "secretPath": "/",
    "secretComment": "MongoDB connection string",
    "type": "shared"
  }'
```

#### Get Secret

```bash
GET /api/v3/secrets/raw/{secretName}?environment={env}&workspaceId={projectId}&secretPath=/
```

```bash
curl "https://secrets.turnersrus.com/api/v3/secrets/raw/DATABASE_URL?environment=dev&workspaceId=$PROJECT_ID&secretPath=/" \
  -H "Authorization: Bearer $TOKEN"
```

#### List All Secrets

```bash
GET /api/v3/secrets/raw?environment={env}&workspaceId={projectId}&secretPath=/
```

```bash
curl "https://secrets.turnersrus.com/api/v3/secrets/raw?environment=dev&workspaceId=$PROJECT_ID&secretPath=/" \
  -H "Authorization: Bearer $TOKEN"
```

---

### Project Members

#### Add User to Project

When a Machine Identity creates a project, human users need to be added separately.

```bash
POST /api/v2/workspace/{projectId}/memberships
```

```bash
curl -X POST "https://secrets.turnersrus.com/api/v2/workspace/$PROJECT_ID/memberships" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "emails": ["user@example.com"],
    "roles": ["admin"]
  }'
```

Available roles: `admin`, `member`, `viewer`, `no-access`

#### Add Machine Identity to Project

```bash
POST /api/v2/workspace/{projectId}/identity-memberships/{identityId}
```

```bash
curl -X POST "https://secrets.turnersrus.com/api/v2/workspace/$PROJECT_ID/identity-memberships/$IDENTITY_ID" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"role": "admin"}'
```

---

## Complete Setup Script

Here's a complete script to set up a new project with environments and secrets:

```bash
#!/bin/bash
set -euo pipefail

# Configuration
INFISICAL_URL="https://secrets.turnersrus.com"
CLIENT_ID="your-client-id"
CLIENT_SECRET="your-client-secret"
PROJECT_NAME="my-project"
USER_EMAIL="admin@example.com"

# Authenticate
echo "Authenticating..."
RESPONSE=$(curl -s -X POST "$INFISICAL_URL/api/v1/auth/universal-auth/login" \
  -H "Content-Type: application/json" \
  -d "{\"clientId\":\"$CLIENT_ID\",\"clientSecret\":\"$CLIENT_SECRET\"}")

TOKEN=$(echo "$RESPONSE" | jq -r '.accessToken')

if [ "$TOKEN" = "null" ]; then
  echo "Authentication failed: $RESPONSE"
  exit 1
fi

echo "Authenticated successfully"

# Create project
echo "Creating project..."
PROJECT_RESPONSE=$(curl -s -X POST "$INFISICAL_URL/api/v2/workspace" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "{
    \"projectName\": \"$PROJECT_NAME\",
    \"slug\": \"$PROJECT_NAME\",
    \"type\": \"secret-manager\",
    \"shouldCreateDefaultEnvs\": false
  }")

PROJECT_ID=$(echo "$PROJECT_RESPONSE" | jq -r '.project.id')
echo "Project created: $PROJECT_ID"

# Create environments
for env in "Development:dev:1" "Staging:staging:2" "Production:prod:3"; do
  IFS=':' read -r name slug position <<< "$env"
  echo "Creating environment: $name"
  curl -s -X POST "$INFISICAL_URL/api/v1/projects/$PROJECT_ID/environments" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"name\":\"$name\",\"slug\":\"$slug\",\"position\":$position}" > /dev/null
done

# Add user to project
echo "Adding user: $USER_EMAIL"
curl -s -X POST "$INFISICAL_URL/api/v2/workspace/$PROJECT_ID/memberships" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"emails\":[\"$USER_EMAIL\"],\"roles\":[\"admin\"]}" > /dev/null

# Create secrets function
create_secret() {
  local name=$1
  local value=$2
  local env=$3
  local comment=${4:-""}

  curl -s -X POST "$INFISICAL_URL/api/v3/secrets/raw/$name" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d "{
      \"environment\":\"$env\",
      \"secretValue\":\"$value\",
      \"workspaceId\":\"$PROJECT_ID\",
      \"secretPath\":\"/\",
      \"secretComment\":\"$comment\",
      \"type\":\"shared\"
    }" > /dev/null
}

# Create secrets for each environment
for env in dev staging prod; do
  echo "Creating secrets for $env..."
  create_secret "DATABASE_URL" "mongodb://mongodb:27017" "$env" "MongoDB connection"
  create_secret "API_KEY" "" "$env" "API key - set actual value"
done

echo "Setup complete!"
echo "Project ID: $PROJECT_ID"
```

---

## Troubleshooting

### "Invalid credentials" Error

- Verify Client ID matches what's shown in Infisical UI (not the Identity ID)
- Ensure Client Secret hasn't been rotated
- Check if IP whitelisting is blocking the request

### "Unable to access project" in UI

When a Machine Identity creates a project, human users aren't automatically added. Use the "Add User to Project" API to grant access.

### Token Expiration

Access tokens expire based on the TTL configured in Universal Auth settings (default: 30 days). Re-authenticate to get a new token.

### API Version Differences

Different endpoints use different API versions:
- `/api/v1/` - Auth, environments, project memberships
- `/api/v2/` - Workspaces (projects), user memberships
- `/api/v3/` - Secrets (raw)

Always use the correct version for each endpoint.

---

## Python Client Example

```python
import httpx
from functools import lru_cache

class InfisicalClient:
    """Client for Infisical API."""

    def __init__(self, url: str, client_id: str, client_secret: str):
        self.url = url.rstrip('/')
        self.client_id = client_id
        self.client_secret = client_secret
        self._token: str | None = None

    def _get_token(self) -> str:
        if self._token is None:
            response = httpx.post(
                f"{self.url}/api/v1/auth/universal-auth/login",
                json={"clientId": self.client_id, "clientSecret": self.client_secret}
            )
            response.raise_for_status()
            self._token = response.json()["accessToken"]
        return self._token

    def _headers(self) -> dict:
        return {"Authorization": f"Bearer {self._get_token()}"}

    def get_secret(self, key: str, project_id: str, environment: str) -> str:
        response = httpx.get(
            f"{self.url}/api/v3/secrets/raw/{key}",
            params={"workspaceId": project_id, "environment": environment, "secretPath": "/"},
            headers=self._headers()
        )
        response.raise_for_status()
        return response.json()["secret"]["secretValue"]

    def list_secrets(self, project_id: str, environment: str) -> dict[str, str]:
        response = httpx.get(
            f"{self.url}/api/v3/secrets/raw",
            params={"workspaceId": project_id, "environment": environment, "secretPath": "/"},
            headers=self._headers()
        )
        response.raise_for_status()
        return {s["secretKey"]: s["secretValue"] for s in response.json()["secrets"]}

    def create_secret(
        self, key: str, value: str, project_id: str, environment: str, comment: str = ""
    ) -> None:
        response = httpx.post(
            f"{self.url}/api/v3/secrets/raw/{key}",
            headers=self._headers(),
            json={
                "environment": environment,
                "secretValue": value,
                "workspaceId": project_id,
                "secretPath": "/",
                "secretComment": comment,
                "type": "shared"
            }
        )
        response.raise_for_status()
```

---

## References

- [Infisical API Documentation](https://infisical.com/docs/api-reference/overview/introduction)
- [Universal Auth Guide](https://infisical.com/docs/documentation/platform/identities/universal-auth)
- [Machine Identities](https://infisical.com/docs/documentation/platform/identities/machine-identities)
