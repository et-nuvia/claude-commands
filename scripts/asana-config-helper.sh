#!/usr/bin/env bash
# Asana Configuration Helper
# Discovers workspace, project, section, and custom field GIDs for PROJECT.yaml

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/yaml.sh"

echo "Asana Configuration Helper"
echo "This script shows you what MCP commands to run in Claude"
echo ""

if [[ ! -f "PROJECT.yaml" ]]; then
    echo "Error: PROJECT.yaml not found"
    exit 1
fi

WORKSPACE=$(yaml_get '.task_management.asana.workspace' PROJECT.yaml)
PROJECT=$(yaml_get '.task_management.asana.default_project' PROJECT.yaml)

echo "Current config: Workspace=$WORKSPACE, Project=$PROJECT"
echo ""
echo "Run these MCP commands in Claude to get GIDs:"
echo "1. mcp__asana__list_workspaces()"
echo "2. mcp__asana__list_projects(workspace: \"$WORKSPACE\")"
echo "3. mcp__asana__list_sections(project: \"$PROJECT\")"
echo "4. mcp__asana__get_custom_fields(project: \"$PROJECT\")"
