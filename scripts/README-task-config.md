# Task Configuration Scripts

Scripts for managing task management configuration in PROJECT.yaml.

## Scripts

### get-task-config.sh

Retrieves task management configuration from PROJECT.yaml.

**Usage:**
```bash
# Get specific values
get-task-config.sh backend           # asana or gitlab
get-task-config.sh asana-workspace   # Asana workspace GID
get-task-config.sh asana-project     # Asana project name/GID
get-task-config.sh asana-section     # Asana section name/GID
get-task-config.sh gitlab-project    # GitLab project ID
get-task-config.sh gitlab-labels     # GitLab labels (one per line)

# Get all config as JSON
get-task-config.sh all | jq .
```

**Features:**
- Auto-detects environment (work=macOS=Asana, home=Linux=GitLab)
- Returns structured data for easy parsing
- Works in both bash and zsh
- Exit code 2 if PROJECT.yaml not found
- Exit code 1 on configuration errors

**Example:**
```bash
# In a task command
BACKEND=$(~/.claude/scripts/get-task-config.sh backend)
if [[ "$BACKEND" == "asana" ]]; then
  WORKSPACE=$(~/.claude/scripts/get-task-config.sh asana-workspace)
  PROJECT=$(~/.claude/scripts/get-task-config.sh asana-project)
  SECTION=$(~/.claude/scripts/get-task-config.sh asana-section)
fi
```

### validate-project.py

Context-aware Python validator for PROJECT.yaml with intelligent required field detection.

**Usage:**
```bash
# Validate current directory
validate-project.py

# Validate specific file
validate-project.py --file path/to/PROJECT.yaml

# JSON output
validate-project.py --json

# Strict mode (warnings fail)
validate-project.py --strict

# Quiet mode (errors/warnings only)
validate-project.py --quiet
```

**Features:**
- Environment-aware validation (work vs home)
- Context-sensitive required fields
- Validates based on enabled features
- Colored terminal output
- JSON output for CI/CD integration
- Comprehensive error messages with suggestions

**Validations:**
- Core fields (name, testing, secrets)
- Testing configuration
- Secrets backend (AWS vs Infisical)
- Docker configuration
- Task management (Asana vs GitLab)
- Database configuration (two-user model)
- Deployment configuration
- CI/CD platform

**Exit Codes:**
- 0: Valid (no errors)
- 1: Invalid (has errors) or warnings in strict mode
- 2: File not found or YAML parse error

**Dependencies:**
```bash
# Create project venv
uv venv
uv pip install pyyaml

# Run with uv (automatically uses venv)
uv run python ~/.claude/scripts/validate-project.py

# Add to .gitignore
echo ".venv/" >> .gitignore
```

### validate-project-wrapper.sh

Bash wrapper for validate-project.py with dependency checking.

**Usage:**
```bash
validate-project-wrapper.sh [options]
```

Checks for Python 3 and PyYAML, provides installation instructions if missing.

## PROJECT.yaml Configuration

### Asana Configuration (Work Environment)

```yaml
task_management:
  backend: "asana"
  asana:
    workspace_id: "1234567890123456"   # Required: Your workspace GID
    project: "Engineering"              # Recommended: Default project
    section: "To Do"                    # Optional: Section within project
```

**How to find Asana IDs:**
- Workspace GID: `https://app.asana.com/api/1.0/workspaces`
- Project/Section GIDs: Can use names, script will look up IDs
- Or use numeric GIDs directly

### GitLab Configuration (Home Environment)

```yaml
task_management:
  backend: "gitlab"
  gitlab:
    project_id: "group/project"         # Required: Project path or ID
    default_labels:                     # Optional: Default issue labels
      - backend
      - task
```

## Integration

### In Task Commands

Use `get-task-config.sh` in task management commands:

```bash
# Get backend
BACKEND=$(~/.claude/scripts/get-task-config.sh backend)

# Get Asana config
if [[ "$BACKEND" == "asana" ]]; then
  WORKSPACE_ID=$(~/.claude/scripts/get-task-config.sh asana-workspace)
  PROJECT=$(~/.claude/scripts/get-task-config.sh asana-project)
  SECTION=$(~/.claude/scripts/get-task-config.sh asana-section)

  # Use in API calls
  curl -H "Authorization: Bearer ${ASANA_TOKEN}" \
    "https://app.asana.com/api/1.0/workspaces/${WORKSPACE_ID}/..."
fi
```

### In CI/CD Pipelines

Use `validate-project.py` in CI pipelines:

```yaml
# GitHub Actions
- name: Validate PROJECT.yaml
  run: |
    uv venv
    uv pip install pyyaml
    uv run python ~/.claude/scripts/validate-project.py --strict

# GitLab CI
validate:config:
  script:
    - uv venv
    - uv pip install pyyaml
    - uv run python ~/.claude/scripts/validate-project.py --json
```

## Library Functions

The `lib/project-config.sh` library provides reusable functions:

```bash
source ~/.claude/scripts/lib/project-config.sh

# Task management functions
BACKEND=$(get_task_backend)           # asana or gitlab
WORKSPACE=$(get_asana_workspace_id)   # Asana workspace GID
PROJECT=$(get_asana_project)          # Asana project name/GID
SECTION=$(get_asana_section)          # Asana section name/GID
GITLAB_ID=$(get_gitlab_project_id)    # GitLab project ID
LABELS=$(get_gitlab_default_labels)   # GitLab labels
```

## Examples

### Complete Task Creation Flow

```bash
#!/usr/bin/env bash
set -euo pipefail

# Get configuration
BACKEND=$(~/.claude/scripts/get-task-config.sh backend)

if [[ "$BACKEND" == "asana" ]]; then
  # Asana task creation
  WORKSPACE=$(~/.claude/scripts/get-task-config.sh asana-workspace)
  PROJECT=$(~/.claude/scripts/get-task-config.sh asana-project)
  SECTION=$(~/.claude/scripts/get-task-config.sh asana-section)

  # Create task
  TASK_DATA="{\"data\": {\"name\": \"${TITLE}\", \"workspace\": \"${WORKSPACE}\"}}"
  RESPONSE=$(curl -s -X POST \
    -H "Authorization: Bearer ${ASANA_TOKEN}" \
    -d "$TASK_DATA" \
    "https://app.asana.com/api/1.0/tasks")

  TASK_ID=$(echo "$RESPONSE" | jq -r '.data.gid')

  # Add to section if configured
  if [[ -n "$SECTION" ]]; then
    # Look up section ID and add task
    ...
  fi
fi
```

### Validation in Pre-commit Hook

```bash
#!/usr/bin/env bash
# .git/hooks/pre-commit

if [[ -f "PROJECT.yaml" ]]; then
  echo "Validating PROJECT.yaml..."
  ~/.claude/scripts/validate-project.py --quiet || exit 1
fi
```

## Testing

Test the scripts with sample configurations:

```bash
# Create test config
cat > /tmp/PROJECT.yaml << 'EOF'
name: "test-project"
testing:
  command: "pytest"
secrets:
  backend: "asana"
task_management:
  backend: "asana"
  asana:
    workspace_id: "1234567890"
    project: "Engineering"
    section: "To Do"
EOF

# Test retrieval
cd /tmp
~/.claude/scripts/get-task-config.sh all | jq .

# Test validation
~/.claude/scripts/validate-project.py
```

## See Also

- [Task Management Guidelines](../docs/task-management.md)
- [PROJECT.yaml Template](../templates/PROJECT.yaml)
- [PROJECT.yaml Example](../templates/PROJECT.yaml.example)
