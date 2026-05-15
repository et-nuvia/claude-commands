# Asana MCP Integration Guide

Complete guide to Asana integration in the task management system using Claude Code's MCP (Model Context Protocol) tools.

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Configuration](#configuration)
- [Command Integration](#command-integration)
- [MCP Tools Reference](#mcp-tools-reference)
- [Performance Optimization](#performance-optimization)
- [Troubleshooting](#troubleshooting)
- [Examples](#examples)

---

## Overview

### What is This?

Seamless bidirectional integration between local V4 task documents and Asana tasks, enabling:
- Automatic task creation in Asana from direct input
- Status synchronization (In progress, Hold, Done)
- Progress updates via comments
- Fast GID access via `.current-task` file
- Configuration-driven sync behavior

### Key Features

✅ **Zero manual login** - Uses MCP authentication
✅ **Fast GID access** - 20-40x faster via .current-task (5ms vs 100-200ms)
✅ **Graceful degradation** - Never blocks commands if Asana unavailable
✅ **Status management** - Proper status updates (not task completion)
✅ **Comment-based updates** - Preserves task descriptions
✅ **Configuration-driven** - PROJECT.yaml controls sync behavior
✅ **Fuzzy matching** - Workspace/project names, no GIDs needed

### Integration Points

| Command | Sync Operation | MCP Tools Used |
|---------|----------------|----------------|
| `task-capture` | Fetch from Asana OR create new task | `get_task`, `search_tasks`, `create_task` |
| `task-start` | Update status → "In progress" | `update_custom_field` |
| `task-update` | Post progress comment | `add_comment` |
| `task-hold` | Update status → "Hold" + comment | `update_custom_field`, `add_comment` |
| `task-close` | Update status → "Done" + comment | `update_custom_field`, `add_comment` |
| `task-continue` | No sync | - |
| `task-audit` | No sync | - |

---

## Architecture

### Components

```
┌─────────────────────────────────────────────────────────────────┐
│                        User Commands                             │
│  task-capture, task-start, task-update, task-hold, task-close  │
└────────────────────────────┬────────────────────────────────────┘
                             │
                             ▼
┌─────────────────────────────────────────────────────────────────┐
│                     Configuration Layer                          │
│         PROJECT.yaml (backend, sync_on_operations)              │
└────────────────────────────┬────────────────────────────────────┘
                             │
                             ▼
┌─────────────────────────────────────────────────────────────────┐
│                    Integration Layer                             │
│  • Check if Asana configured                                    │
│  • Check if operation should sync                               │
│  • Get GID from .current-task or task document                  │
└────────────────────────────┬────────────────────────────────────┘
                             │
                             ▼
┌─────────────────────────────────────────────────────────────────┐
│                       MCP Layer                                  │
│  Claude Code MCP Tools (13+ functions)                          │
│  • Authentication handled by MCP                                │
│  • Rate limiting handled by MCP                                 │
│  • Error handling by MCP                                        │
└────────────────────────────┬────────────────────────────────────┘
                             │
                             ▼
┌─────────────────────────────────────────────────────────────────┐
│                      Asana API                                   │
│              app.asana.com REST API v1.0                        │
└─────────────────────────────────────────────────────────────────┘
```

### Data Flow

**Task Start Example**:
1. User runs `/task-start 0002`
2. Command reads task document → extracts Asana GID
3. Command writes GID to `.current-task` file
4. Command checks PROJECT.yaml → Asana enabled? start in sync_on_operations?
5. If yes: Call `mcp__asana__update_custom_field(task_gid, "Status", "In progress")`
6. MCP handles auth, makes API call, returns result
7. Command updates "Last Synced" timestamp in task document
8. If error: Log warning, continue (best-effort sync)

### .current-task File

**Purpose**: Fast access to active task metadata without parsing full document.

**Format**:
```bash
sequence=0002
branch=task-0002-asana-integration-commands
asana_gid=1234567890123456
started=2026-02-10 19:45:00
```

**Benefits**:
- **Performance**: 5ms read vs 100-200ms document parsing (20-40x faster)
- **Simplicity**: One-line `grep | cut` vs complex markdown parsing
- **Reliability**: No regex failures or format changes

**Usage**:
```bash
# Fast read
ASANA_GID=$(grep "^asana_gid=" .current-task 2>/dev/null | cut -d= -f2)

# Write on task-start
cat > .current-task <<EOF
sequence=${SEQUENCE}
branch=${BRANCH_NAME}
asana_gid=${ASANA_GID}
started=$(date -u +"%Y-%m-%d %H:%M:%S")
EOF

# Remove on task-hold/task-close
rm -f .current-task
```

---

## Configuration

### PROJECT.yaml Schema

```yaml
task_management:
  backend: asana  # or "gitlab"

  asana:
    # Default locations for new tasks
    default_workspace: "nuviasmiles.com"          # Fuzzy matched
    default_project: "Med Clearance/NPPW"         # Fuzzy matched
    default_section: "NPPW"                       # Fuzzy matched (optional)

    # Which operations should sync with Asana
    sync_on_operations:
      - capture   # Create task in Asana for direct input
      - start     # Update status to "In progress"
      - update    # Post progress comments
      - hold      # Update status to "Hold" + comment
      - close     # Update status to "Done" + comment

    # Custom field configuration (optional - uses fuzzy matching by default)
    custom_fields:
      status:
        field_name: "Status"  # Field name (fuzzy matched)
        values:
          in_progress: "In progress"  # Value names (fuzzy matched)
          hold: "Hold"
          done: "Done"
```

### Configuration Discovery

Use the helper script to find your workspace/project/field GIDs:

```bash
~/.claude/scripts/asana-config-helper.sh
```

The script guides you through:
1. Listing workspaces → get workspace name/GID
2. Listing projects → get project name/GID
3. Listing sections → get section name/GID
4. Getting custom fields → get field names and enum values

### Minimal Configuration

**Required**:
```yaml
task_management:
  backend: asana
  asana:
    default_workspace: "Your Workspace"
    default_project: "Your Project"
    sync_on_operations:
      - capture
      - start
      - hold
      - close
```

**Optional** (recommended for better performance):
```yaml
    default_section: "Your Section"  # Organizes new tasks
    custom_fields:
      status:
        field_name: "Status"
```

### Environment Detection

The system auto-detects environment:
- **Work (macOS)**: Asana + GitHub (primary)
- **Home (WSL)**: GitLab + Asana (secondary)

Detection via:
```bash
if [[ "$(uname -s)" == "Darwin" ]]; then
  # Work environment - Asana primary
else
  # Home environment - GitLab primary
fi
```

---

## Command Integration

### task-capture

**Purpose**: Capture tasks from various sources including Asana.

**Asana Operations**:
1. **Fetch from Asana** (URL or GID provided):
   - Extract GID from URL: `https://app.asana.com/0/PROJECT_GID/TASK_GID`
   - Or use direct GID: `1234567890123456`
   - Call `mcp__asana__get_task(task_gid: GID)`
   - Populate task document from response
   - Store GID in External Tracking section

2. **Create in Asana** (direct input provided):
   - Check if `capture` in `sync_on_operations`
   - Call `mcp__asana__create_task(...)` with:
     - `name`: Task title
     - `notes`: Task description
     - `workspace`: From PROJECT.yaml
     - `projects`: [default_project]
     - `section`: default_section (optional)
     - `assignee`: "me"
   - Capture returned GID
   - Update task document External Tracking section

**Example**:
```bash
# Fetch from Asana URL
/task-capture https://app.asana.com/0/1211676392439164/1234567890123456

# Fetch from Asana GID
/task-capture 1234567890123456

# Create from direct input (creates in Asana if configured)
/task-capture "Add user authentication to dashboard"
```

**MCP Tools Used**:
- `mcp__asana__get_task` - Fetch task details
- `mcp__asana__search_tasks` - Search by name
- `mcp__asana__create_task` - Create new task

### task-start

**Purpose**: Start working on a task.

**Asana Operations**:
1. Extract Asana GID from task document External Tracking section
2. Write GID to `.current-task` file for fast access
3. Check if `start` in `sync_on_operations`
4. Update Status custom field to "In progress"
5. Update "Last Synced" timestamp in task document

**Implementation**:
```bash
# Extract GID from task document
ASANA_GID=$(grep -A 20 "^## External Tracking" "$TASK_DOC" | \
            grep "^- Task GID:" | \
            sed 's/.*\[\?\([0-9]*\)\]\?/\1/' | \
            tr -d '[]' | head -1)

# Write to .current-task
cat > .current-task <<EOF
sequence=${SEQUENCE}
branch=${BRANCH_NAME}
asana_gid=${ASANA_GID}
started=$(date -u +"%Y-%m-%d %H:%M:%S")
EOF

# Update status if configured
if [[ "$BACKEND" == "asana" && -n "$SYNC_ON_START" && -n "$ASANA_GID" ]]; then
  mcp__asana__update_custom_field(
    task_gid: "${ASANA_GID}",
    custom_field: "Status",
    value: "In progress"
  )
fi
```

**MCP Tools Used**:
- `mcp__asana__update_custom_field` - Set status to "In progress"

### task-update

**Purpose**: Update task plan with progress.

**Asana Operations**:
1. Read Asana GID from `.current-task` (fast - 5ms)
2. Check if `update` in `sync_on_operations`
3. Post brief progress comment (NOT description update)
4. Comment includes: % complete, status, next steps

**Implementation**:
```bash
# Get GID from .current-task
ASANA_GID=$(grep "^asana_gid=" .current-task 2>/dev/null | cut -d= -f2)

# Post progress comment if configured
if [[ "$BACKEND" == "asana" && -n "$SYNC_ON_UPDATE" && -n "$ASANA_GID" ]]; then
  COMMENT_TEXT="📝 Progress update

**Completed**: ${COMPLETED_COUNT} of ${TOTAL_OBJECTIVES} objectives (${PERCENT_COMPLETE}%)
**Status**: ${ON_TRACK_STATUS}

**Next Steps**:
${NEXT_STEPS}

See task ${SEQUENCE} for full details."

  mcp__asana__add_comment(
    task_gid: "${ASANA_GID}",
    text: "${COMMENT_TEXT}"
  )
fi
```

**Important**: Posts COMMENTS only. Task description managed by task-capture.

**MCP Tools Used**:
- `mcp__asana__add_comment` - Post progress comment

### task-hold

**Purpose**: Pause task while waiting for external dependency.

**Asana Operations**:
1. Read Asana GID from `.current-task` (fast path)
2. Check if `hold` in `sync_on_operations`
3. Update Status custom field to "Hold"
4. Post comment with hold reason
5. Update "Last Synced" timestamp

**Implementation**:
```bash
# Get GID from .current-task (fast - 5ms)
ASANA_GID=$(grep "^asana_gid=" .current-task 2>/dev/null | cut -d= -f2)

# Update status and post comment if configured
if [[ "$BACKEND" == "asana" && -n "$SYNC_ON_HOLD" && -n "$ASANA_GID" ]]; then
  # Update status to "Hold"
  mcp__asana__update_custom_field(
    task_gid: "${ASANA_GID}",
    custom_field: "Status",
    value: "Hold"
  )

  # Post hold comment
  mcp__asana__add_comment(
    task_gid: "${ASANA_GID}",
    text: "⏸️ On hold: ${HOLD_REASON}

Task paused until: ${RESUME_CONDITION}

Branch preserved: ${BRANCH_NAME}"
  )
fi
```

**MCP Tools Used**:
- `mcp__asana__update_custom_field` - Set status to "Hold"
- `mcp__asana__add_comment` - Post hold reason

### task-close

**Purpose**: Complete or defer task.

**Asana Operations**:
1. Read Asana GID from `.current-task` or task document
2. Check if `close` in `sync_on_operations`
3. Update Status custom field to "Done" (NOT task completion!)
4. Post completion summary comment
5. Update "Last Synced" timestamp

**Implementation**:
```bash
# Get GID (try .current-task first, fallback to document)
ASANA_GID=$(grep "^asana_gid=" .current-task 2>/dev/null | cut -d= -f2)
[[ -z "$ASANA_GID" ]] && ASANA_GID=$(grep -A 20 "^## External Tracking" "$TASK_DOC" | ...)

# Update status and post comment if configured
if [[ "$BACKEND" == "asana" && -n "$SYNC_ON_CLOSE" && -n "$ASANA_GID" ]]; then
  # Update status to "Done"
  mcp__asana__update_custom_field(
    task_gid: "${ASANA_GID}",
    custom_field: "Status",
    value: "Done"
  )

  # Post completion summary
  mcp__asana__add_comment(
    task_gid: "${ASANA_GID}",
    text: "✅ Task closed locally

**Branch**: ${BRANCH_NAME}
**Status**: ${STATUS} (complete/deferred)
${PR_URL:+**PR**: ${PR_URL}}

${PROGRESS_SUMMARY}"
  )
fi
```

**Important**: Sets status to "Done" but does NOT mark task completed. Task should only be marked complete after successful deployment.

**MCP Tools Used**:
- `mcp__asana__update_custom_field` - Set status to "Done"
- `mcp__asana__add_comment` - Post completion summary

### Commands That Don't Sync

**task-continue**: Internal work continuation, no external sync needed

**task-audit**: Internal audit report, results stay local

---

## MCP Tools Reference

Complete reference of Asana MCP functions available in Claude Code.

### Workspace & Project Tools

#### `mcp__asana__list_workspaces`

List all workspaces the authenticated user has access to.

**Parameters**: None

**Returns**: List of workspaces with GIDs and names

**Example**:
```python
mcp__asana__list_workspaces()
# Returns: [{"gid": "1162186193001399", "name": "nuviasmiles.com"}, ...]
```

#### `mcp__asana__list_projects`

List projects in a workspace.

**Parameters**:
- `workspace` (string, optional): Workspace name or GID (fuzzy matched). Uses default if not provided.
- `archived` (boolean, optional): Filter archived/non-archived projects

**Returns**: List of projects with GIDs and names

**Example**:
```python
mcp__asana__list_projects(
  workspace: "nuviasmiles.com"
)
# Returns: [{"gid": "1211676392439164", "name": "Med Clearance/NPPW"}, ...]
```

**Note**: Automatically caches projects for name resolution.

#### `mcp__asana__list_sections`

List sections within a project.

**Parameters**:
- `project` (string, required): Project name or GID (fuzzy matched)

**Returns**: List of sections with GIDs and names

**Example**:
```python
mcp__asana__list_sections(
  project: "Med Clearance/NPPW"
)
# Returns: [{"gid": "1234567890", "name": "NPPW"}, ...]
```

**Note**: Sections organize tasks within projects (like columns).

### Task Management Tools

#### `mcp__asana__list_tasks`

List tasks with filters.

**Parameters**:
- `assignee` (string, optional): User GID or "me" for current user
- `project` (string, optional): Project name or GID (fuzzy matched)
- `workspace` (string, optional): Workspace name or GID (fuzzy matched)
- `completed_since` (string, optional): ISO 8601 date filter
- `limit` (number, optional): Max tasks to return (default: 100)

**Returns**: List of tasks

**Example**:
```python
mcp__asana__list_tasks(
  assignee: "me",
  project: "Med Clearance",
  workspace: "nuviasmiles.com"
)
```

#### `mcp__asana__get_task`

Get detailed information about a specific task.

**Parameters**:
- `task_gid` (string, required): Asana task GID

**Returns**: Complete task object with all fields

**Example**:
```python
mcp__asana__get_task(
  task_gid: "1234567890123456"
)
# Returns: {
#   "gid": "1234567890123456",
#   "name": "Implement user authentication",
#   "notes": "Add OAuth 2.0 authentication...",
#   "assignee": {"name": "Eric Turner"},
#   "due_on": "2026-02-15",
#   "custom_fields": [...],
#   ...
# }
```

#### `mcp__asana__create_task`

Create a new task in Asana.

**Parameters**:
- `name` (string, required): Task name
- `notes` (string, optional): Task description
- `workspace` (string, optional): Workspace name or GID (fuzzy matched)
- `projects` (array, optional): Array of project names or GIDs
- `section` (string, optional): Section name or GID (fuzzy matched)
- `assignee` (string, optional): User GID or "me"
- `due_on` (string, optional): Due date (YYYY-MM-DD)
- `due_at` (string, optional): Due date with time (ISO 8601)
- `tags` (array, optional): Array of tag GIDs

**Returns**: Created task object with GID

**Example**:
```python
mcp__asana__create_task(
  name: "Implement user authentication",
  notes: "Add OAuth 2.0 authentication to dashboard",
  workspace: "nuviasmiles.com",
  projects: ["Med Clearance/NPPW"],
  section: "NPPW",
  assignee: "me",
  due_on: "2026-02-15"
)
# Returns: {"gid": "1234567890123456", "name": "Implement...", ...}
```

**Note**: MCP automatically resolves workspace/project/section names to GIDs using fuzzy matching.

#### `mcp__asana__update_task`

Update an existing task.

**Parameters**:
- `task_gid` (string, required): Task GID to update
- `name` (string, optional): New task name
- `notes` (string, optional): New description
- `assignee` (string, optional): User GID
- `due_on` (string, optional): New due date
- `completed` (boolean, optional): Mark completed/incomplete

**Returns**: Updated task object

**Example**:
```python
mcp__asana__update_task(
  task_gid: "1234567890123456",
  due_on: "2026-02-20"
)
```

#### `mcp__asana__complete_task`

Mark a task as completed.

**Parameters**:
- `task_gid` (string, required): Task GID to complete

**Returns**: Updated task object

**Example**:
```python
mcp__asana__complete_task(
  task_gid: "1234567890123456"
)
```

**Note**: Use this for deployment completion, NOT for local task closure (use status "Done" instead).

#### `mcp__asana__search_tasks`

Search for tasks with advanced filters.

**Parameters**:
- `workspace` (string, required): Workspace name or GID (fuzzy matched)
- `text` (string, optional): Search text in names/descriptions
- `assignee` (string, optional): User GID or "me"
- `projects` (array, optional): Array of project names or GIDs
- `completed` (boolean, optional): Filter by completion status

**Returns**: List of matching tasks

**Example**:
```python
mcp__asana__search_tasks(
  workspace: "nuviasmiles.com",
  text: "authentication",
  assignee: "me",
  projects: ["Med Clearance"]
)
```

### Custom Field Tools

#### `mcp__asana__get_custom_fields`

Get custom field definitions for a project.

**Parameters**:
- `project` (string, required): Project name or GID (fuzzy matched)

**Returns**: List of custom fields with GIDs, types, and enum values

**Example**:
```python
mcp__asana__get_custom_fields(
  project: "Med Clearance/NPPW"
)
# Returns: [
#   {
#     "gid": "1212989152117481",
#     "name": "Status",
#     "type": "enum",
#     "enum_options": [
#       {"gid": "1212989152117483", "name": "In progress"},
#       {"gid": "1212989159419735", "name": "Hold"},
#       {"gid": "1212989159419737", "name": "Done"}
#     ]
#   },
#   ...
# ]
```

**Note**: Automatically caches custom fields for field name resolution.

#### `mcp__asana__update_custom_field`

Update a custom field value on a task.

**Parameters**:
- `task_gid` (string, required): Task GID to update
- `custom_field` (string, required): Field name or GID (fuzzy matched)
- `value` (string/number, required): Value to set (fuzzy matched for enums)
- `project` (string, optional): Project name or GID (fuzzy matched)

**Returns**: Updated task object

**Example**:
```python
mcp__asana__update_custom_field(
  task_gid: "1234567890123456",
  custom_field: "Status",
  value: "In progress"
)

# Also works with partial matches:
mcp__asana__update_custom_field(
  task_gid: "1234567890123456",
  custom_field: "stat",  # Fuzzy matches "Status"
  value: "in prog"       # Fuzzy matches "In progress"
)
```

**Note**: Supports fuzzy matching for both field names and enum values.

### Section Tools

#### `mcp__asana__move_task_to_section`

Move a task to a different section within a project.

**Parameters**:
- `task_gid` (string, required): Task GID to move
- `section` (string, required): Section name or GID (fuzzy matched)
- `project` (string, optional): Project name or GID (fuzzy matched)

**Returns**: Updated task object

**Example**:
```python
mcp__asana__move_task_to_section(
  task_gid: "1234567890123456",
  section: "NPPW"
)

# Fuzzy matching works:
mcp__asana__move_task_to_section(
  task_gid: "1234567890123456",
  section: "bugs"  # Matches "Bugs" section
)
```

### Comment Tools

#### `mcp__asana__add_comment`

Add a comment (story) to a task.

**Parameters**:
- `task_gid` (string, required): Task GID
- `text` (string, required): Comment text (markdown supported)

**Returns**: Created comment object

**Example**:
```python
mcp__asana__add_comment(
  task_gid: "1234567890123456",
  text: "📝 Progress update

**Completed**: 3 of 5 objectives (60%)
**Status**: On track

See task 0002 for full details."
)
```

**Note**: Supports markdown formatting and emojis.

#### `mcp__asana__list_comments`

List all comments on a task.

**Parameters**:
- `task_gid` (string, required): Task GID

**Returns**: List of comments

**Example**:
```python
mcp__asana__list_comments(
  task_gid: "1234567890123456"
)
```

### User Tools

#### `mcp__asana__get_current_user`

Get information about the authenticated user.

**Parameters**: None

**Returns**: Current user object

**Example**:
```python
mcp__asana__get_current_user()
# Returns: {"gid": "1234567890", "name": "Eric Turner", "email": "eric@..."}
```

#### `mcp__asana__get_user`

Get information about a specific user.

**Parameters**:
- `user_gid` (string, required): User GID

**Returns**: User object

**Example**:
```python
mcp__asana__get_user(
  user_gid: "1234567890"
)
```

---

## Performance Optimization

### .current-task Fast Path

**Problem**: Reading Asana GID from task document requires parsing markdown (~100-200ms).

**Solution**: Store GID in `.current-task` file for instant access (~5ms).

**Performance Gain**: 20-40x faster! 🚀

**Implementation**:
```bash
# SLOW PATH (100-200ms) - Parse full document
ASANA_GID=$(grep -A 20 "^## External Tracking" "$TASK_DOC" | \
            grep "^- Task GID:" | \
            sed 's/.*\[\?\([0-9]*\)\]\?/\1/' | \
            tr -d '[]' | head -1)

# FAST PATH (5ms) - One line read
ASANA_GID=$(grep "^asana_gid=" .current-task | cut -d= -f2)
```

**When to Use**:
- ✅ Use fast path in: `task-update`, `task-hold`, `task-close`
- ✅ Use slow path fallback when `.current-task` missing
- ✅ Write to `.current-task` in: `task-start`
- ✅ Remove `.current-task` in: `task-hold`, `task-close`

### Fuzzy Matching Benefits

**Problem**: Hardcoding GIDs is brittle and hard to maintain.

**Solution**: MCP's fuzzy matching allows using human-readable names.

**Benefits**:
- ✅ Configuration is readable: `"Med Clearance/NPPW"` not `"1211676392439164"`
- ✅ Robust to project renames (partial match still works)
- ✅ Faster to configure (no GID lookup needed)
- ✅ Works across workspaces (same project name, different GIDs)

**Example**:
```python
# All of these work:
mcp__asana__update_custom_field(custom_field: "Status", value: "In progress")
mcp__asana__update_custom_field(custom_field: "stat", value: "in prog")
mcp__asana__update_custom_field(custom_field: "St", value: "In")
```

### Caching Strategy

MCP automatically caches:
- ✅ Project names → GIDs
- ✅ Section names → GIDs
- ✅ Custom field names → GIDs
- ✅ Enum value names → GIDs

**Result**: Subsequent calls are faster (no repeated API lookups).

---

## Troubleshooting

### Common Issues

#### "Asana not configured" - Command skips sync

**Cause**: `backend` not set to "asana" in PROJECT.yaml

**Fix**:
```yaml
task_management:
  backend: asana  # Add this line
  asana:
    ...
```

#### "Operation not in sync_on_operations" - Command skips sync

**Cause**: Operation not listed in `sync_on_operations`

**Fix**:
```yaml
task_management:
  asana:
    sync_on_operations:
      - capture
      - start
      - update  # Add operations you want to sync
      - hold
      - close
```

#### "Asana GID not found" - Can't update task

**Cause**: Task document missing External Tracking section or GID not populated

**Fix**:
1. Check task document has `## External Tracking` section
2. Verify `- Task GID: [1234567890123456]` is populated
3. If captured from direct input, ensure `capture` in `sync_on_operations`

#### MCP call fails with "Project not found"

**Cause**: Project name doesn't match (fuzzy matching failed)

**Fix**:
1. List projects: `mcp__asana__list_projects(workspace: "Your Workspace")`
2. Use exact name from list in PROJECT.yaml
3. Or use project GID directly

#### "Status field not found" - Can't update status

**Cause**: Project doesn't have Status custom field, or name doesn't match

**Fix**:
1. Get custom fields: `mcp__asana__get_custom_fields(project: "Your Project")`
2. Verify Status field exists
3. Update `custom_fields.status.field_name` in PROJECT.yaml to match actual name
4. Or create Status field in Asana project settings

#### .current-task missing asana_gid

**Cause**: Task started before .current-task enhancement implemented

**Fix**:
1. Stop current task: `/task-hold` or `/task-close`
2. Restart task: `/task-start TASK_ID`
3. New .current-task will include asana_gid

### Debug Tips

**Enable verbose logging**:
```bash
# In command, add debug output
echo "DEBUG: ASANA_GID=${ASANA_GID}"
echo "DEBUG: BACKEND=${BACKEND}"
echo "DEBUG: SYNC_ENABLED=${SYNC_ON_START}"
```

**Check MCP response**:
```python
# MCP returns result object
result = mcp__asana__update_custom_field(...)
# Check result for errors
```

**Validate PROJECT.yaml**:
```bash
# Check syntax
yq eval '.' PROJECT.yaml

# Check specific values
yq eval '.task_management.backend' PROJECT.yaml
yq eval '.task_management.asana.sync_on_operations' PROJECT.yaml
```

**Test GID extraction**:
```bash
# Test fast path
grep "^asana_gid=" .current-task | cut -d= -f2

# Test slow path
grep -A 20 "^## External Tracking" "$TASK_DOC" | grep "^- Task GID:"
```

---

## Examples

### Complete Workflow: Capture → Start → Update → Close

#### 1. Capture Task from Direct Input (Creates in Asana)

```bash
/task-capture "Implement user authentication for dashboard"
```

**What happens**:
1. Parse user input → extract requirements
2. Create local task document: `0003-2602101700-TSK-user-authentication.md`
3. Check PROJECT.yaml → `capture` in `sync_on_operations`?
4. Call `mcp__asana__create_task(...)` with default workspace/project
5. Receive GID: `1234567890123456`
6. Update task document External Tracking:
   ```markdown
   ## External Tracking

   **Asana**:
   - Task GID: [1234567890123456]
   - Task URL: [https://app.asana.com/0/1211676392439164/1234567890123456]
   - Workspace: nuviasmiles.com
   - Project: Med Clearance/NPPW
   - Section: NPPW
   - Status: Not Started
   - Last Synced: 2026-02-10 17:00:00
   ```

#### 2. Start Work on Task (Updates Status to "In progress")

```bash
/task-start 0003
```

**What happens**:
1. Extract GID from task document: `1234567890123456`
2. Create/checkout branch: `task-0003-user-authentication`
3. Write `.current-task`:
   ```bash
   sequence=0003
   branch=task-0003-user-authentication
   asana_gid=1234567890123456
   started=2026-02-10 17:05:00
   ```
4. Check PROJECT.yaml → `start` in `sync_on_operations`?
5. Call `mcp__asana__update_custom_field(task_gid: "1234567890123456", custom_field: "Status", value: "In progress")`
6. Update task document: `Last Synced: 2026-02-10 17:05:00`

#### 3. Update Progress (Posts Comment)

```bash
/task-update
```

**What happens**:
1. Read GID from `.current-task`: `1234567890123456` (5ms - fast!)
2. Update plan document with progress
3. Check PROJECT.yaml → `update` in `sync_on_operations`?
4. Call `mcp__asana__add_comment(task_gid: "1234567890123456", text: "📝 Progress update...")`
5. Comment includes:
   - % objectives complete
   - On track status
   - Next steps
   - Link to local task

#### 4. Close Task (Updates Status to "Done")

```bash
/task-close
```

**What happens**:
1. Read GID from `.current-task`: `1234567890123456` (5ms - fast!)
2. Move task document to `docs/completed/`
3. Archive branch
4. Check PROJECT.yaml → `close` in `sync_on_operations`?
5. Call `mcp__asana__update_custom_field(task_gid: "1234567890123456", custom_field: "Status", value: "Done")`
6. Call `mcp__asana__add_comment(...)` with completion summary
7. Update task document: `Last Synced: 2026-02-10 18:00:00`
8. Remove `.current-task`

**Note**: Status is "Done" but task NOT completed. Task marked complete after deployment.

### Capture from Asana URL

```bash
/task-capture https://app.asana.com/0/1211676392439164/1234567890123456
```

**What happens**:
1. Extract GID from URL: `1234567890123456`
2. Call `mcp__asana__get_task(task_gid: "1234567890123456")`
3. Map fields to task document:
   - `name` → Title
   - `notes` → Description
   - `due_on` → Target Completion
   - `custom_fields` → Priority (if present)
4. Create local task document
5. Store GID in External Tracking section

### Hold Task (Updates Status to "Hold")

```bash
/task-hold
```

**Prompt for hold reason**:
```
Hold Reason: Waiting for customer feedback on authentication requirements
Expected Resume: When customer responds (check email daily)
```

**What happens**:
1. Read GID from `.current-task`: `1234567890123456`
2. Update task document with hold reason
3. Archive branch (preserved for later)
4. Check PROJECT.yaml → `hold` in `sync_on_operations`?
5. Call `mcp__asana__update_custom_field(task_gid: "1234567890123456", custom_field: "Status", value: "Hold")`
6. Call `mcp__asana__add_comment(...)`:
   ```
   ⏸️ On hold: Waiting for customer feedback on authentication requirements

   Task paused until: When customer responds (check email daily)

   Branch preserved: task-0003-user-authentication
   ```
7. Remove `.current-task`

### Configuration Example: Med Clearance/NPPW

```yaml
task_management:
  backend: asana

  asana:
    # Default locations
    default_workspace: "nuviasmiles.com"
    default_project: "Med Clearance/NPPW"
    default_section: "NPPW"

    # Sync operations
    sync_on_operations:
      - capture   # Create in Asana for direct input
      - start     # Update status to "In progress"
      - update    # Post progress comments
      - hold      # Update status to "Hold"
      - close     # Update status to "Done"

    # Custom fields (optional - uses fuzzy matching)
    custom_fields:
      status:
        field_name: "Status"
        values:
          in_progress: "In progress"
          hold: "Hold"
          done: "Done"
```

**Project Configuration** (discovered via MCP):
- Workspace GID: `1162186193001399`
- Project GID: `1211676392439164`
- Status field GID: `1212989152117481`
  - In progress: `1212989152117483`
  - Hold: `1212989159419735`
  - Done: `1212989159419737`

---

## Related Documentation

- **V4 Documentation System**: `~/.claude/docs/reference/DOCUMENTATION-V4.md`
- **.current-task File**: `~/.claude/docs/reference/current-task-file.md`
- **Task Management Workflow**: `~/.claude/docs/task-management.md`
- **PROJECT.yaml Guide**: `~/.claude/docs/project-config.md`
- **Asana Prompt Patterns**: `~/.claude/templates/asana-prompts/README.md`

---

## Summary

### Key Takeaways

✅ **Zero Configuration Overhead** - Fuzzy matching eliminates GID management
✅ **Lightning Fast** - .current-task enables 5ms GID access (20-40x faster)
✅ **Never Blocks** - Graceful degradation, best-effort sync
✅ **Status Not Completion** - Proper status management preserves deployment workflow
✅ **Comment-Based Updates** - Task descriptions stay clean, managed by capture
✅ **Configuration-Driven** - PROJECT.yaml controls all sync behavior

### Integration Checklist

- [ ] Configure PROJECT.yaml with Asana settings
- [ ] Add `sync_on_operations` for desired commands
- [ ] Test with real task: capture → start → update → close
- [ ] Verify status updates in Asana
- [ ] Verify comments appear in Asana
- [ ] Test graceful degradation (remove config, verify commands still work)
- [ ] Add `.current-task` to `.gitignore`

### Need Help?

- **Configuration issues**: Run `~/.claude/scripts/asana-config-helper.sh`
- **MCP tool reference**: See "MCP Tools Reference" section above
- **Troubleshooting**: See "Troubleshooting" section above
- **Prompt patterns**: `~/.claude/templates/asana-prompts/README.md`
