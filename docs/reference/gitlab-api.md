# GitLab API Guide

This guide documents how to interact with the GitLab API at `git.turnersrus.com` for programmatic project and CI/CD management.

## Authentication

### Token Storage

The GitLab API token is stored at:
```
~/.gitlab-token
```

This token has `api` scope and can be used for all GitLab API operations.

### Token Usage

```bash
GITLAB_TOKEN=$(cat ~/.gitlab-token)
curl -H "PRIVATE-TOKEN: $GITLAB_TOKEN" "https://git.turnersrus.com/api/v4/..."
```

---

## Common API Endpoints

### User Info

```bash
# Get current user
curl -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
  "https://git.turnersrus.com/api/v4/user"
```

### Projects

```bash
# List all projects you have access to
curl -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
  "https://git.turnersrus.com/api/v4/projects?membership=true"

# Search for a project
curl -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
  "https://git.turnersrus.com/api/v4/projects?search=projectname"

# Get project by ID
curl -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
  "https://git.turnersrus.com/api/v4/projects/106"
```

---

## CI/CD Variables

### List Project Variables

```bash
curl -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
  "https://git.turnersrus.com/api/v4/projects/$PROJECT_ID/variables"
```

### Create Variable

```bash
curl -X POST -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
  "https://git.turnersrus.com/api/v4/projects/$PROJECT_ID/variables" \
  --form "key=MY_VARIABLE" \
  --form "value=my-value" \
  --form "masked=true" \
  --form "protected=false"
```

### Update Variable

```bash
curl -X PUT -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
  "https://git.turnersrus.com/api/v4/projects/$PROJECT_ID/variables/MY_VARIABLE" \
  --form "value=new-value" \
  --form "masked=true"
```

### Delete Variable

```bash
curl -X DELETE -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
  "https://git.turnersrus.com/api/v4/projects/$PROJECT_ID/variables/MY_VARIABLE"
```

---

## Group-Level Variables

For variables shared across multiple projects in a group:

```bash
# List group variables
curl -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
  "https://git.turnersrus.com/api/v4/groups/$GROUP_ID/variables"

# Create group variable
curl -X POST -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
  "https://git.turnersrus.com/api/v4/groups/$GROUP_ID/variables" \
  --form "key=SHARED_VAR" \
  --form "value=shared-value"
```

---

## Pipeline Operations

### List Pipelines

```bash
curl -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
  "https://git.turnersrus.com/api/v4/projects/$PROJECT_ID/pipelines"
```

### Get Pipeline Details

```bash
curl -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
  "https://git.turnersrus.com/api/v4/projects/$PROJECT_ID/pipelines/$PIPELINE_ID"
```

### Trigger Pipeline

```bash
curl -X POST -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
  "https://git.turnersrus.com/api/v4/projects/$PROJECT_ID/pipeline" \
  --form "ref=main"
```

### Retry Failed Pipeline

```bash
curl -X POST -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
  "https://git.turnersrus.com/api/v4/projects/$PROJECT_ID/pipelines/$PIPELINE_ID/retry"
```

### Cancel Pipeline

```bash
curl -X POST -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
  "https://git.turnersrus.com/api/v4/projects/$PROJECT_ID/pipelines/$PIPELINE_ID/cancel"
```

---

## Job Operations

### List Jobs in Pipeline

```bash
curl -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
  "https://git.turnersrus.com/api/v4/projects/$PROJECT_ID/pipelines/$PIPELINE_ID/jobs"
```

### Get Job Log

```bash
curl -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
  "https://git.turnersrus.com/api/v4/projects/$PROJECT_ID/jobs/$JOB_ID/trace"
```

### Retry Job

```bash
curl -X POST -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
  "https://git.turnersrus.com/api/v4/projects/$PROJECT_ID/jobs/$JOB_ID/retry"
```

---

## Common Project IDs

| Project | ID | Path |
|---------|----|----|
| bullbarn | 106 | bullbarn/website |

---

## Python Client Example

```python
import httpx
from pathlib import Path

class GitLabClient:
    """Client for GitLab API."""

    def __init__(self, url: str = "https://git.turnersrus.com"):
        self.url = url.rstrip('/')
        self.token = Path("~/.gitlab-token").expanduser().read_text().strip()

    def _headers(self) -> dict:
        return {"PRIVATE-TOKEN": self.token}

    def get_project(self, project_id: int) -> dict:
        response = httpx.get(
            f"{self.url}/api/v4/projects/{project_id}",
            headers=self._headers()
        )
        response.raise_for_status()
        return response.json()

    def list_variables(self, project_id: int) -> list:
        response = httpx.get(
            f"{self.url}/api/v4/projects/{project_id}/variables",
            headers=self._headers()
        )
        response.raise_for_status()
        return response.json()

    def update_variable(self, project_id: int, key: str, value: str, masked: bool = True) -> dict:
        response = httpx.put(
            f"{self.url}/api/v4/projects/{project_id}/variables/{key}",
            headers=self._headers(),
            data={"value": value, "masked": str(masked).lower()}
        )
        response.raise_for_status()
        return response.json()

    def trigger_pipeline(self, project_id: int, ref: str = "main") -> dict:
        response = httpx.post(
            f"{self.url}/api/v4/projects/{project_id}/pipeline",
            headers=self._headers(),
            data={"ref": ref}
        )
        response.raise_for_status()
        return response.json()
```

---

## References

- [GitLab API Documentation](https://docs.gitlab.com/ee/api/)
- [CI/CD Variables API](https://docs.gitlab.com/ee/api/project_level_variables.html)
- [Pipelines API](https://docs.gitlab.com/ee/api/pipelines.html)
