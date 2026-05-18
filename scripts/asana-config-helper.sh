#!/usr/bin/env bash
# Asana Configuration Helper
# Discovers workspace, project, section, and custom-field GIDs for
# PROJECT.yaml. Backend-aware: no-ops gracefully when the active task
# backend isn't Asana.
#
# Migrated to use scripts/lib/task-api.sh (issue #11). Bootstrap
# discovery calls go through the asana adapter's _asana_call helper
# rather than printing literal mcp__asana__* instructions for the
# operator to run by hand.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/yaml.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/task-api.sh"

if ! command -v jq >/dev/null 2>&1; then
    echo "Error: jq is required" >&2
    exit 1
fi

if ! load_task_adapter; then
    exit 1
fi

# Resolve the active backend the same way task-api.sh does so we can
# branch on it for backend-specific bootstrap behavior.
_active_backend() {
    local backend=""
    if [[ -n "${TASK_ADAPTER_OVERRIDE:-}" ]]; then
        backend="$TASK_ADAPTER_OVERRIDE"
    elif [[ -f PROJECT.yaml ]]; then
        backend=$(yaml_get '.task_management.backend' PROJECT.yaml 2>/dev/null || true)
    fi
    if [[ -z "$backend" || "$backend" == "null" ]]; then
        backend=$(profile_env_get .task_management.backend 2>/dev/null || true)
    fi
    case "$backend" in
        gitlab) echo "gitlab-tasks" ;;
        github) echo "github-tasks" ;;
        *)      echo "$backend" ;;
    esac
}

backend=$(_active_backend)

echo "Asana Configuration Helper"
echo ""

if [[ "$backend" != "asana" ]]; then
    echo "Active task backend is '${backend:-unset}', not 'asana'."
    echo "This helper only applies when PROJECT.yaml configures Asana."
    exit 0
fi

if [[ ! -f "PROJECT.yaml" ]]; then
    echo "Error: PROJECT.yaml not found" >&2
    exit 1
fi

if ! task_health >/dev/null 2>&1; then
    echo "Error: Asana adapter health check failed." >&2
    echo "Verify ~/.asana-token is present and valid, then retry." >&2
    exit 1
fi

# Discovery uses _asana_call from the loaded adapter. This is a
# bootstrap path — workspace/project/section/custom-field listing
# isn't part of the public task_* contract, so we reach into the
# adapter's REST helper directly rather than duplicating the auth
# and HTTP plumbing here.
configured_workspace=$(yaml_get '.task_management.asana.workspace_id' PROJECT.yaml 2>/dev/null || true)
configured_project=$(yaml_get '.task_management.asana.default_project' PROJECT.yaml 2>/dev/null || true)

echo "Configured: workspace_id=${configured_workspace:-<unset>}  default_project=${configured_project:-<unset>}"
echo ""

echo "Workspaces:"
_asana_call GET "/workspaces?opt_fields=gid,name" \
    | jq -r '.data[]? | "  \(.gid)  \(.name)"'
echo ""

if [[ -n "$configured_workspace" && "$configured_workspace" != "null" ]]; then
    echo "Projects in workspace ${configured_workspace}:"
    _asana_call GET "/workspaces/${configured_workspace}/projects?opt_fields=gid,name" \
        | jq -r '.data[]? | "  \(.gid)  \(.name)"'
    echo ""
fi

if [[ -n "$configured_project" && "$configured_project" != "null" ]]; then
    echo "Sections in project ${configured_project}:"
    _asana_call GET "/projects/${configured_project}/sections?opt_fields=gid,name" \
        | jq -r '.data[]? | "  \(.gid)  \(.name)"'
    echo ""

    echo "Custom fields in project ${configured_project}:"
    _asana_call GET "/projects/${configured_project}/custom_field_settings?opt_fields=custom_field.gid,custom_field.name,custom_field.resource_subtype" \
        | jq -r '.data[]? | "  \(.custom_field.gid)  \(.custom_field.name)  [\(.custom_field.resource_subtype)]"'
fi
