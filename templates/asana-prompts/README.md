# Asana MCP Prompt Patterns

Reusable prompt patterns for integrating Asana MCP tools into task management commands.

## Overview

These patterns provide consistent, tested approaches for common Asana operations. Use them in task commands (`task-capture`, `task-start`, `task-close`, etc.) to ensure reliable Asana integration.

## Available Patterns

| Pattern | Purpose | Used By |
|---------|---------|---------|
| `check-config.md` | Validate PROJECT.yaml Asana configuration | All task commands |
| `get-task-gid.md` | Extract Asana task GID from local document | All commands (except capture) |
| `fetch-task.md` | Fetch task details from Asana, create local doc | `task-capture` |
| `post-comment.md` | Add comment/story to Asana task | `task-start`, `task-continue`, `task-hold`, `task-audit`, `task-close` |
| `complete-task.md` | Mark task as completed in Asana | `task-close` |

## Quick Reference

### Check if Asana Enabled

```markdown
1. Read PROJECT.yaml
2. Check: `task_management.backend == "asana"`
3. Check: operation in `task_management.asana.sync_on_operations[]`
4. If not enabled: Skip Asana operations gracefully
```

### Get Task GID

```markdown
1. Read task document
2. Extract from: `External Tracking > Asana > Task GID`
3. If not found: Skip Asana operations
```

### Post Comment

```markdown
1. Get task GID
2. Format comment with emoji and context
3. Call: `mcp__asana__add_comment(task_gid, text)`
4. Update "Last Synced" timestamp
```

### Complete Task

```markdown
1. Get task GID
2. Post completion summary comment
3. Call: `mcp__asana__complete_task(task_gid)`
4. Update local metadata
```

## Usage in Task Commands

### task-capture

```markdown
Input: Asana URL or GID
Process:
  1. Extract GID from input
  2. Fetch task: `mcp__asana__get_task(task_gid)`
  3. Parse response
  4. Create local document with metadata
Output: Local task document with Asana link
```

### task-start

```markdown
Prerequisites: Task captured, GID in document
Process:
  1. Check Asana config (if "start" in sync_on_operations)
  2. Get task GID from document
  3. Post comment: "🚀 Work started on sequence XXXX"
Output: Comment posted to Asana
```

### task-continue

```markdown
Prerequisites: Work in progress
Process:
  1. Check Asana config (if "continue" in sync_on_operations)
  2. Get task GID from document
  3. Format progress update
  4. Post comment: "📝 Progress update: ..."
Output: Progress comment posted
```

### task-hold

```markdown
Prerequisites: Task in progress
Process:
  1. Check Asana config (if "hold" in sync_on_operations)
  2. Get task GID from document
  3. Format hold reason and summary
  4. Post comment: "⏸️ On hold: ..."
Output: Hold comment posted
```

### task-audit

```markdown
Prerequisites: Audit complete
Process:
  1. Check Asana config (if "audit" in sync_on_operations)
  2. Get task GID from document
  3. Format audit findings
  4. Post comment: "🔍 Audit findings: ..."
Output: Audit results posted
```

### task-close

```markdown
Prerequisites: Work complete
Process:
  1. Check Asana config (if "close" in sync_on_operations)
  2. Get task GID from document
  3. Post completion summary
  4. Mark complete: `mcp__asana__complete_task(task_gid)`
Output: Task marked complete in Asana
```

## Available MCP Tools

### Core Operations
- `mcp__asana__get_task` - Fetch task details by GID
- `mcp__asana__create_task` - Create new task
- `mcp__asana__update_task` - Update task fields
- `mcp__asana__complete_task` - Mark complete
- `mcp__asana__add_comment` - Post comment
- `mcp__asana__list_comments` - Get all comments

### Discovery
- `mcp__asana__list_workspaces` - List accessible workspaces
- `mcp__asana__list_projects` - List projects (with fuzzy matching!)
- `mcp__asana__list_tasks` - List tasks with filters
- `mcp__asana__list_sections` - List sections in project
- `mcp__asana__search_tasks` - Advanced search

### User Info
- `mcp__asana__get_current_user` - Get current user info
- `mcp__asana__get_user` - Get user by GID

## Configuration

### PROJECT.yaml

```yaml
task_management:
  backend: asana
  asana:
    workspace: "My Company"          # Fuzzy matched by MCP
    default_project: "Engineering"   # Fuzzy matched by MCP
    default_section: "In Progress"   # Optional
    sync_on_operations:
      - capture   # Fetch from Asana when capturing
      - start     # Post "work started" comment
      - continue  # Post progress updates
      - hold      # Post hold reason
      - audit     # Post audit findings
      - close     # Post summary and mark complete
```

### Authentication

MCP automatically reads from:
```
~/.asana-token
```

No manual token handling needed!

## Emoji Guide

Use consistent emoji for different operations:

| Operation | Emoji | Example |
|-----------|-------|---------|
| Work Started | 🚀 | "🚀 Work started on sequence 0002" |
| Progress Update | 📝 | "📝 Progress update: Completed Phase 1" |
| On Hold | ⏸️ | "⏸️ On hold: Waiting for customer" |
| Audit Complete | 🔍 | "🔍 Audit findings: Coverage at 87%" |
| Task Complete | ✅ | "✅ Task completed - deployed to prod" |
| Warning | ⚠️ | "⚠️ TODO items remain (documented)" |

## Error Handling

**Golden Rule**: Never fail a task command because Asana sync fails.

```markdown
For all Asana operations:
  1. Try MCP call
  2. If error:
     - Log warning: "⚠️ Failed to sync with Asana: <error>"
     - Continue with local operations
     - Don't fail command
  3. If success:
     - Update "Last Synced" timestamp
     - Log success: "✓ Synced with Asana"
```

## Testing

Test patterns with:
1. Valid Asana workspace (happy path)
2. Missing PROJECT.yaml (skip gracefully)
3. Invalid token (fail gracefully)
4. Task not linked (skip gracefully)
5. Network error (fail gracefully)

## Examples

See individual pattern files for detailed examples and usage.

## Contributing

When adding new patterns:
1. Document MCP tools used
2. Show example usage
3. Include error handling
4. Add to this README
