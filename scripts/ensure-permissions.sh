#!/usr/bin/env bash
set -euo pipefail

# ensure-permissions.sh — SessionStart hook
# Ensures project-level .claude/settings.local.json has permissions for:
#   1. Make targets derived from PROJECT.yaml
#   2. agent-browser MCP tools
#   3. Read/Edit/Write access to ~/.claude/ and subdirectories
#
# Note: ~/.claude/scripts/ invocations are auto-allowed by the
# PreToolUse hook at ~/.claude/hooks/allow-claude-scripts.sh, so we
# no longer enumerate them here.

# ── Configuration ──────────────────────────────────────────────────────────────

CLAUDE_HOME="${HOME}/.claude"
PROJECT_DIR="${PWD}"
PROJECT_SETTINGS_DIR="${PROJECT_DIR}/.claude"
PROJECT_SETTINGS_FILE="${PROJECT_SETTINGS_DIR}/settings.local.json"
PROJECT_YAML="${PROJECT_DIR}/PROJECT.yaml"

# Standard make targets (from makefile.md reference)
STANDARD_TARGETS=(
  help up down status logs
  test lint format typecheck
  migrate build clean
)

# ── Functions ──────────────────────────────────────────────────────────────────

log() {
  # Silent by default — set ENSURE_PERMISSIONS_DEBUG=1 to see output
  if [[ "${ENSURE_PERMISSIONS_DEBUG:-}" == "1" ]]; then
    echo "[ensure-permissions] $*" >&2
  fi
}

# Collect make target permissions from PROJECT.yaml
collect_make_permissions() {
  local permissions=()

  # Always add standard targets
  for target in "${STANDARD_TARGETS[@]}"; do
    permissions+=("Bash(make ${target}:*)")
  done

  # Parse PROJECT.yaml for service-specific targets if it exists
  if [[ -f "${PROJECT_YAML}" ]]; then
    # Extract docker.services entries (simple YAML parsing)
    local services=()
    while IFS= read -r service; do
      service="$(echo "${service}" | sed 's/^[[:space:]]*-[[:space:]]*//' | sed 's/[[:space:]]*$//' | tr -d '"' | tr -d "'")"
      if [[ -n "${service}" ]]; then
        services+=("${service}")
      fi
    done < <(python3 -c "
import yaml, sys
try:
    with open('${PROJECT_YAML}') as f:
        data = yaml.safe_load(f)
    services = (data or {}).get('docker', {}).get('services', [])
    if isinstance(services, list):
        for s in services:
            print(s)
except Exception:
    pass
" 2>/dev/null || true)

    # Also detect component directories (directories with their own Makefile)
    local components=()
    for dir in "${PROJECT_DIR}"/*/; do
      if [[ -f "${dir}Makefile" ]]; then
        local name
        name="$(basename "${dir}")"
        components+=("${name}")
      fi
    done

    # Merge services and components (unique)
    local all_services=()
    declare -A seen
    for s in "${services[@]}" "${components[@]}"; do
      if [[ -z "${seen[${s}]:-}" ]]; then
        seen["${s}"]=1
        all_services+=("${s}")
      fi
    done

    # Add per-service targets
    for service in "${all_services[@]}"; do
      permissions+=("Bash(make test-${service}:*)")
      permissions+=("Bash(make lint-${service}:*)")
      permissions+=("Bash(make format-${service}:*)")
      permissions+=("Bash(make typecheck-${service}:*)")
      permissions+=("Bash(make build-${service}:*)")
    done

    # Extract testing commands that might indicate additional make targets
    # e.g., e2e_command, smoke_command
    local has_e2e has_smoke
    has_e2e="$(python3 -c "
import yaml
with open('${PROJECT_YAML}') as f:
    data = yaml.safe_load(f)
e2e = (data or {}).get('testing', {}).get('e2e_command', '')
print('yes' if e2e else 'no')
" 2>/dev/null || echo "no")"
    has_smoke="$(python3 -c "
import yaml
with open('${PROJECT_YAML}') as f:
    data = yaml.safe_load(f)
smoke = (data or {}).get('testing', {}).get('smoke_command', '')
print('yes' if smoke else 'no')
" 2>/dev/null || echo "no")"

    if [[ "${has_e2e}" == "yes" ]]; then
      permissions+=("Bash(make test-e2e:*)")
    fi
    if [[ "${has_smoke}" == "yes" ]]; then
      permissions+=("Bash(make test-smoke:*)")
    fi
  fi

  printf '%s\n' "${permissions[@]}"
}

# Collect common non-destructive development commands
collect_common_commands() {
  local permissions=()

  # ── Filesystem (read-only) ──
  permissions+=(
    "Bash(ls:*)"
    "Bash(find:*)"
    "Bash(grep:*)"
    "Bash(cat:*)"
    "Bash(head:*)"
    "Bash(tail:*)"
    "Bash(wc:*)"
    "Bash(sort:*)"
    "Bash(echo:*)"
    "Bash(printf:*)"
    "Bash(test:*)"
    "Bash(tee:*)"
  )

  # ── Data processing ──
  permissions+=(
    "Bash(jq:*)"
    "Bash(yq:*)"
    "Bash(awk:*)"
    "Bash(xargs:*)"
  )

  # ── Git (all standard operations) ──
  permissions+=(
    "Bash(git add:*)"
    "Bash(git branch:*)"
    "Bash(git check-ignore:*)"
    "Bash(git checkout:*)"
    "Bash(git cherry-pick:*)"
    "Bash(git commit:*)"
    "Bash(git diff:*)"
    "Bash(git fetch:*)"
    "Bash(git log:*)"
    "Bash(git ls-files:*)"
    "Bash(git ls-tree:*)"
    "Bash(git merge:*)"
    "Bash(git merge-base:*)"
    "Bash(git mv:*)"
    "Bash(git pull:*)"
    "Bash(git push:*)"
    "Bash(git rebase:*)"
    "Bash(git reset:*)"
    "Bash(git rev-list:*)"
    "Bash(git rm:*)"
    "Bash(git stash:*)"
    "Bash(git status:*)"
    "Bash(git symbolic-ref:*)"
    "Bash(git tag:*)"
  )

  # ── GitHub CLI ──
  permissions+=(
    "Bash(gh api:*)"
    "Bash(gh auth status:*)"
    "Bash(gh pr create:*)"
    "Bash(gh pr diff:*)"
    "Bash(gh pr list:*)"
    "Bash(gh pr view:*)"
    "Bash(gh repo view:*)"
    "Bash(gh run cancel:*)"
    "Bash(gh run list:*)"
    "Bash(gh run view:*)"
    "Bash(gh run watch:*)"
    "Bash(gh variable:*)"
    "Bash(gh workflow list:*)"
    "Bash(gh workflow run:*)"
    "Bash(gh workflow view:*)"
  )

  # ── Docker ──
  permissions+=(
    "Bash(docker build:*)"
    "Bash(docker buildx:*)"
    "Bash(docker builder prune:*)"
    "Bash(docker compose:*)"
    "Bash(docker cp:*)"
    "Bash(docker exec:*)"
    "Bash(docker image rm:*)"
    "Bash(docker images:*)"
    "Bash(docker info:*)"
    "Bash(docker inspect:*)"
    "Bash(docker login:*)"
    "Bash(docker logs:*)"
    "Bash(docker manifest:*)"
    "Bash(docker network:*)"
    "Bash(docker port:*)"
    "Bash(docker ps:*)"
    "Bash(docker pull:*)"
    "Bash(docker push:*)"
    "Bash(docker restart:*)"
    "Bash(docker rm:*)"
    "Bash(docker rmi:*)"
    "Bash(docker run:*)"
    "Bash(docker save:*)"
    "Bash(docker stop:*)"
    "Bash(docker system df:*)"
    "Bash(docker system prune:*)"
    "Bash(docker tag:*)"
    "Bash(docker version:*)"
    "Bash(docker volume rm:*)"
    "Bash(colima start:*)"
    "Bash(colima status:*)"
    "Bash(colima stop:*)"
    "Bash(colima version:*)"
    "Bash(colima ssh:*)"
    "Bash(colima list:*)"
  )

  # ── Node / NPM ──
  permissions+=(
    "Bash(node:*)"
    "Bash(node -e:*)"
    "Bash(npm audit:*)"
    "Bash(npm ci:*)"
    "Bash(npm dedupe:*)"
    "Bash(npm install:*)"
    "Bash(npm ls:*)"
    "Bash(npm run:*)"
    "Bash(npm test:*)"
    "Bash(npm view:*)"
    "Bash(npx:*)"
  )

  # ── Python ──
  permissions+=(
    "Bash(python3:*)"
    "Bash(uv run:*)"
    "Bash(uv pip:*)"
    "Bash(uv venv:*)"
    "Bash(poetry run:*)"
    "Bash(poetry lock:*)"
  )

  # ── AWS CLI ──
  permissions+=(
    "Bash(aws cloudwatch:*)"
    "Bash(aws configure get:*)"
    "Bash(aws ec2:*)"
    "Bash(aws ecr:*)"
    "Bash(aws iam:*)"
    "Bash(aws rds:*)"
    "Bash(aws s3:*)"
    "Bash(aws s3api:*)"
    "Bash(aws secretsmanager:*)"
    "Bash(aws ssm:*)"
    "Bash(aws sts:*)"
  )

  # ── Build / test tools ──
  permissions+=(
    "Bash(make:*)"
    "Bash(bats:*)"
    "Bash(trivy:*)"
    "Bash(terraform init:*)"
    "Bash(terraform fmt:*)"
    "Bash(terraform plan:*)"
    "Bash(terraform validate:*)"
    "Bash(nix:*)"
  )

  # ── Network / diagnostics ──
  permissions+=(
    "Bash(curl:*)"
    "Bash(dig:*)"
    "Bash(host:*)"
    "Bash(nc:*)"
    "Bash(nslookup:*)"
    "Bash(ssh:*)"
    "Bash(scp:*)"
    "Bash(mysql:*)"
    "Bash(sqlite3:*)"
    "Bash(openssl:*)"
  )

  # ── System / utility ──
  permissions+=(
    "Bash(chmod:*)"
    "Bash(ln:*)"
    "Bash(lsof:*)"
    "Bash(pgrep:*)"
    "Bash(ps:*)"
    "Bash(tar:*)"
    "Bash(gzip:*)"
    "Bash(unzip:*)"
    "Bash(time:*)"
    "Bash(open:*)"
    "Bash(source:*)"
    "Bash(bash -n:*)"
    "Bash(bash -x:*)"
  )

  # ── Web access ──
  permissions+=(
    "WebSearch"
    "WebFetch(domain:github.com)"
    "WebFetch(domain:raw.githubusercontent.com)"
  )

  printf '%s\n' "${permissions[@]}"
}

# Collect MCP permissions
collect_mcp_permissions() {
  echo "mcp__agent-browser__*"
  echo "mcp__ide__getDiagnostics"
  echo "mcp__codebase-memory-mcp__get_architecture"
  echo "mcp__codebase-memory-mcp__index_repository"
  echo "mcp__codebase-memory-mcp__manage_adr"
  echo "mcp__codebase-memory-mcp__search_code"
  echo "mcp__codebase-memory-mcp__search_graph"
  echo "mcp__codebase-memory-mcp__query_graph"
  echo "mcp__asana__list_workspaces"
  echo "mcp__asana__list_projects"
  echo "mcp__asana__list_sections"
  echo "mcp__asana__list_tasks"
  echo "mcp__asana__get_task"
  echo "mcp__asana__get_custom_fields"
  echo "mcp__asana__create_task"
  echo "mcp__asana__update_task"
  echo "mcp__asana__update_custom_field"
  echo "mcp__asana__add_comment"
  echo "mcp__asana__search_tasks"
  echo "mcp__asana__move_task_to_section"
  echo "mcp__asana__complete_task"
}

# Collect file access permissions for ~/.claude/ and /tmp/
collect_file_permissions() {
  echo "Read(${CLAUDE_HOME}/**)"
  echo "Edit(${CLAUDE_HOME}/**)"
  echo "Write(${CLAUDE_HOME}/**)"
  echo "Read(/tmp/**)"
  echo "Edit(/tmp/**)"
  echo "Write(/tmp/**)"
}

# Read existing permissions from project settings.local.json
read_existing_permissions() {
  if [[ -f "${PROJECT_SETTINGS_FILE}" ]]; then
    python3 -c "
import json, sys
try:
    with open('${PROJECT_SETTINGS_FILE}') as f:
        data = json.load(f)
    perms = data.get('permissions', {}).get('allow', [])
    for p in perms:
        print(p)
except Exception:
    pass
" 2>/dev/null || true
  fi
}

# Merge permissions and write to project settings.local.json
merge_and_write() {
  local -a new_permissions=()
  local -A existing_set=()

  # Read existing permissions
  while IFS= read -r perm; do
    if [[ -n "${perm}" ]]; then
      existing_set["${perm}"]=1
    fi
  done < <(read_existing_permissions)

  # Collect all desired permissions
  local -a desired=()
  while IFS= read -r perm; do
    [[ -n "${perm}" ]] && desired+=("${perm}")
  done < <(collect_common_commands)
  while IFS= read -r perm; do
    [[ -n "${perm}" ]] && desired+=("${perm}")
  done < <(collect_make_permissions)
  while IFS= read -r perm; do
    [[ -n "${perm}" ]] && desired+=("${perm}")
  done < <(collect_mcp_permissions)
  while IFS= read -r perm; do
    [[ -n "${perm}" ]] && desired+=("${perm}")
  done < <(collect_file_permissions)

  # Find missing permissions
  for perm in "${desired[@]}"; do
    if [[ -z "${existing_set[${perm}]:-}" ]]; then
      new_permissions+=("${perm}")
    fi
  done

  if [[ ${#new_permissions[@]} -eq 0 ]]; then
    log "All permissions already present — no changes needed"
    return 0
  fi

  log "Adding ${#new_permissions[@]} missing permissions"

  # Ensure .claude directory exists in project
  mkdir -p "${PROJECT_SETTINGS_DIR}"

  # Read existing file or create new structure
  python3 -c "
import json, sys, os

settings_file = '${PROJECT_SETTINGS_FILE}'
new_perms = []
for line in sys.stdin:
    line = line.strip()
    if line:
        new_perms.append(line)

# Read existing settings or create empty
if os.path.exists(settings_file):
    with open(settings_file) as f:
        data = json.load(f)
else:
    data = {}

# Ensure structure
if 'permissions' not in data:
    data['permissions'] = {}
if 'allow' not in data['permissions']:
    data['permissions']['allow'] = []

# Add new permissions
existing = set(data['permissions']['allow'])
for perm in new_perms:
    if perm not in existing:
        data['permissions']['allow'].append(perm)

# Sort for readability
data['permissions']['allow'].sort()

# Write back
with open(settings_file, 'w') as f:
    json.dump(data, f, indent=2)
    f.write('\n')

print(f'Added {len(new_perms)} permissions to {settings_file}', file=sys.stderr)
" <<< "$(printf '%s\n' "${new_permissions[@]}")" 2>&1 | while IFS= read -r line; do
    log "${line}"
  done
}

# ── Main ───────────────────────────────────────────────────────────────────────

# Skip if we're inside ~/.claude itself (no need to self-permission)
if [[ "${PROJECT_DIR}" == "${CLAUDE_HOME}" || "${PROJECT_DIR}" == "${CLAUDE_HOME}/"* ]]; then
  log "Inside ~/.claude — skipping"
  exit 0
fi

merge_and_write
