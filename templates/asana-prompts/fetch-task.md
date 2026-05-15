# Fetch Task from Asana

Use this pattern to fetch task details from Asana and create a local task document.

## MCP Tool

```
mcp__asana__get_task
```

**Parameters**:
- `task_gid` (required): The Asana task GID (numeric string)

**Returns**:
- Success: Task object with all fields
- Failure: Error message

## Task Object Structure

```json
{
  "gid": "1234567890",
  "name": "Implement user authentication",
  "notes": "We need to add user authentication...",
  "completed": false,
  "due_on": "2026-02-15",
  "assignee": {
    "gid": "9876543210",
    "name": "Eric Turner"
  },
  "projects": [
    {
      "gid": "1111111111",
      "name": "Engineering"
    }
  ],
  "workspace": {
    "gid": "2222222222",
    "name": "My Company"
  },
  "permalink_url": "https://app.asana.com/0/1111111111/1234567890"
}
```

## Usage Pattern

```markdown
## Fetch Task from Asana

1. **Parse input** to get task GID:
   - If URL: Extract GID from URL
   - If numeric: Use directly as GID

2. **Call MCP tool**:
   ```
   mcp__asana__get_task(
     task_gid: "<task_gid>"
   )
   ```

3. **Parse response** and extract:
   - Task name → Document title
   - Notes → Context/Requirements section
   - Due date → Timeline section
   - Assignee → Verify it's assigned to current user
   - Projects → Asana metadata
   - Workspace → Asana metadata

4. **Create local task document**:
   - Use `new-doc.sh --type TSK --description "<description>" --new`
   - Fill in template with Asana data
   - Store task GID in External Tracking section

5. **Report to user**:
   - Show task name, due date, project
   - Display task ID assigned
   - Provide next steps
```

## Mapping Asana Fields to Task Document

| Asana Field | Task Document Section | Notes |
|-------------|----------------------|-------|
| `name` | Summary | Brief task title |
| `notes` | Context > Background | Full description from Asana |
| `due_on` | Timeline > Target Completion | Deadline |
| `assignee.name` | Context > Source > Requested by | Who assigned |
| `projects[0].name` | External Tracking > Asana > Project | Primary project |
| `workspace.name` | External Tracking > Asana > Workspace | Workspace name |
| `permalink_url` | External Tracking > Asana > Task URL | Full URL |
| `gid` | External Tracking > Asana > Task GID | Numeric GID |

## Example: task-capture Integration

```markdown
## Capture Task from Asana

### Input Validation
1. Check if input is Asana URL or GID
2. Extract GID if URL
3. Validate GID is numeric

### Fetch from Asana
1. Call `mcp__asana__get_task(task_gid: "<gid>")`
2. If error: Display error and exit
3. If success: Parse task object

### Parse Task Details
Extract and format:
- Task name (for document description)
- Notes (for Context section)
- Due date (for Timeline)
- Project (for Asana metadata)
- Workspace (for Asana metadata)

### Create Local Document
1. Generate description slug from task name:
   ```bash
   DESCRIPTION=$(echo "${TASK_NAME}" | tr '[:upper:]' '[:lower:]' | \
                 sed 's/[^a-z0-9 -]//g' | tr ' ' '-' | cut -d'-' -f1-4)
   ```

2. Create document:
   ```bash
   ~/.claude/scripts/new-doc.sh --type TSK --description "${DESCRIPTION}" --new --status active
   ```

3. Fill in template:
   - Summary: Task name
   - Context > Background: Notes from Asana
   - Context > Source: "Asana task captured from..."
   - Timeline > Target Completion: Due date
   - External Tracking: All Asana metadata

### Store Asana Metadata
```markdown
## External Tracking

**Asana**:
- Task GID: <gid>
- Task URL: <permalink_url>
- Workspace: <workspace.name>
- Project: <projects[0].name>
- Last Synced: <current_timestamp>
```

### Report to User
```
✓ Captured Asana task: <task_name>
  Sequence: 0002
  Due: <due_date>
  Project: <project_name>

Next steps:
  /task-start 0002  # Start working

Document: docs/active/0000-0099/0002-<datetime>-TSK-<description>.md
```
```

## Handling Missing Fields

Not all Asana tasks have all fields populated. Handle gracefully:

```markdown
### Field Handling

- **No notes**: Use task name as brief description
- **No due date**: Leave Timeline > Target Completion empty
- **No assignee**: Note "Unassigned" in Context
- **Multiple projects**: Use first project, list others in notes
- **No projects**: Create with default_project from PROJECT.yaml
```

## Auto-Detection of Task Source

When capturing, detect if user is providing:
1. **Full URL**: `https://app.asana.com/0/PROJECT/TASK`
2. **Task GID only**: `1234567890`
3. **Task ID with #**: `#1234567890` (remove #)

```bash
INPUT="$1"

if [[ "$INPUT" =~ ^https?://app\.asana\.com ]]; then
  # URL format
  TASK_GID=$(echo "$INPUT" | sed -E 's|.*/([0-9]+)(/.*)?$|\1|')
elif [[ "$INPUT" =~ ^#?([0-9]+)$ ]]; then
  # GID format (with or without #)
  TASK_GID="${BASH_REMATCH[1]}"
else
  echo "Error: Invalid Asana reference. Use URL or numeric GID."
  exit 1
fi
```

## Error Handling

```markdown
### Common Errors

1. **Task not found** (404):
   - Error: "Asana task <gid> not found. Check GID and permissions."
   - Exit: Fail command

2. **No access** (403):
   - Error: "No access to Asana task <gid>. Check workspace permissions."
   - Exit: Fail command

3. **Invalid token** (401):
   - Error: "Asana authentication failed. Check ~/.asana-token"
   - Exit: Fail command

4. **Rate limited** (429):
   - MCP handles retry automatically
   - If still fails: "Asana API rate limit exceeded. Try again later."

5. **Network error**:
   - Error: "Failed to connect to Asana API. Check network."
   - Exit: Fail command
```

## Example Usage

```bash
# From URL
/task-capture https://app.asana.com/0/1234567890/9876543210

# From GID
/task-capture 9876543210

# From GID with #
/task-capture #9876543210
```

All formats should work and produce the same result.
