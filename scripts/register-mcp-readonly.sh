#!/usr/bin/env bash
set -euo pipefail

# Auto-approve read-only MCP operations for specified services
# This allows safe read operations without prompts

CLAUDE_SETTINGS="${HOME}/.claude/settings.json"

echo "🔍 Configuring auto-approve for read-only MCP operations..."

# Check if settings file exists
if [[ ! -f "${CLAUDE_SETTINGS}" ]]; then
  echo "❌ Claude settings file not found at ${CLAUDE_SETTINGS}"
  exit 1
fi


# Check for jq
if ! command -v jq &> /dev/null; then
  echo "❌ jq is required but not installed"
  exit 1
fi

# Define read-only MCP operations
# These are safe operations that only retrieve data, never modify
READ_ONLY_TOOLS=(
  # Secrets - Read operations
  "mcp__secrets__get_secrets"
  "mcp__secrets__get_secret_value"

  # Invoice Ninja - Read operations
  "mcp__invoice-ninja__list_invoices"
  "mcp__invoice-ninja__get_invoice"
  "mcp__invoice-ninja__list_clients"
  "mcp__invoice-ninja__get_client"
  "mcp__invoice-ninja__list_products"
  "mcp__invoice-ninja__get_settings"
  "mcp__invoice-ninja__download_invoice"

  # Asana - Read operations
  "mcp__asana__list_workspaces"
  "mcp__asana__list_projects"
  "mcp__asana__list_tasks"
  "mcp__asana__get_task"
  "mcp__asana__get_current_user"
  "mcp__asana__get_user"
  "mcp__asana__search_tasks"
  "mcp__asana__list_comments"

  # Bitwarden - Read operations (if MCP exists)
  "mcp__bitwarden__list_items"
  "mcp__bitwarden__get_item"
  "mcp__bitwarden__search_items"

  # CI Pipeline - Read operations (if MCP exists)
  "mcp__ci-pipeline__get_pipeline"
  "mcp__ci-pipeline__list_pipelines"
  "mcp__ci-pipeline__get_job"
  "mcp__ci-pipeline__list_jobs"
  "mcp__ci-pipeline__get_logs"
)

# Build JSON array of tools
TOOLS_JSON="["
for tool in "${READ_ONLY_TOOLS[@]}"; do
  ESCAPED=$(printf '%s' "${tool}" | jq -R .)
  TOOLS_JSON="${TOOLS_JSON}${ESCAPED},"
done
# Remove trailing comma and close array
TOOLS_JSON="${TOOLS_JSON%,}]"

# Update settings.json with MCP auto-approve
jq --argjson tools "${TOOLS_JSON}" '
  .autoApprove = (.autoApprove // {}) |
  .autoApprove.mcp = ($tools | unique)
' "${CLAUDE_SETTINGS}" > "${CLAUDE_SETTINGS}.tmp"

mv "${CLAUDE_SETTINGS}.tmp" "${CLAUDE_SETTINGS}"

echo ""
echo "✅ Successfully configured auto-approve for read-only MCP operations"
echo ""
echo "📋 Auto-approved MCP tools (${#READ_ONLY_TOOLS[@]} total):"
printf '   - %s\n' "${READ_ONLY_TOOLS[@]}"
echo ""
echo "🔒 Write operations (create, update, delete) still require approval"
echo "💡 To undo, restore from: ${BACKUP}"
