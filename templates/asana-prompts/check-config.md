# Asana Configuration Check

Use this pattern to check if Asana integration is enabled for a specific operation.

## Logic

```bash
# 1. Check if PROJECT.yaml exists in current directory
if [[ ! -f "PROJECT.yaml" ]]; then
  # No project config - skip Asana operations
  exit 0
fi

# 2. Check if backend is asana
BACKEND=$(yq eval '.task_management.backend' PROJECT.yaml 2>/dev/null)
if [[ "$BACKEND" != "asana" ]]; then
  # Backend is not Asana (might be gitlab) - skip
  exit 0
fi

# 3. Check if this operation should sync to Asana
OPERATION="start"  # or "capture", "continue", "hold", "audit", "close"
SYNC_OPS=$(yq eval '.task_management.asana.sync_on_operations[]' PROJECT.yaml 2>/dev/null)
if ! echo "$SYNC_OPS" | grep -q "^${OPERATION}$"; then
  # This operation not in sync list - skip
  exit 0
fi

# If we get here, Asana is enabled for this operation
ASANA_ENABLED=true
```

## MCP Integration Pattern

For task commands, use this check before calling MCP tools:

```markdown
## Check Asana Configuration

1. Read PROJECT.yaml from current directory
2. Check if `task_management.backend == "asana"`
3. Check if current operation in `task_management.asana.sync_on_operations[]`
4. If not configured or not in sync list: Skip Asana operations gracefully (no error)
5. If configured: Proceed with MCP tool calls

**Graceful Degradation**: If Asana not configured, command should work normally without Asana sync.
```

## Configuration Reference

**Required in PROJECT.yaml**:
```yaml
task_management:
  backend: asana  # Must be "asana" (not "gitlab")
  asana:
    workspace: "My Company"          # Workspace name (fuzzy matched by MCP)
    default_project: "Engineering"   # Default project name
    sync_on_operations:              # List of operations that sync
      - capture   # Fetch task from Asana when capturing
      - start     # Post "work started" comment
      - continue  # Post progress updates
      - hold      # Update status and post summary
      - audit     # Post audit findings as comment
      - close     # Mark complete with final summary
```

## Operations

| Operation | When It Runs | What It Does |
|-----------|--------------|--------------|
| `capture` | `/task-capture <asana-url>` | Fetch task details from Asana, create local doc |
| `start` | `/task-start <seq>` | Post "🚀 Work started" comment to Asana |
| `continue` | `/task-continue` | Post progress update to Asana |
| `hold` | `/task-hold` | Post hold reason + summary to Asana |
| `audit` | `/task-audit` | Post audit findings to Asana |
| `close` | `/task-close` | Post completion summary + mark complete |

## Example Usage in Task Commands

```markdown
Before performing Asana operations:

1. **Check configuration** using pattern above
2. If Asana enabled: Extract task GID from local document
3. If task GID exists: Call appropriate MCP tool
4. If any step fails: Continue with local operations (don't break command)
```
