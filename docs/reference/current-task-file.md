# .current-task File Format

The `.current-task` file tracks the currently active task in a project. It is created by `task-start` and removed by `task-close`. If the file is missing or corrupt, run `task-recover.sh` on a feature branch to rebuild it.

## Purpose

- Track which task is currently being worked on
- Provide quick access to task metadata without reading full task document
- Enable external tracker integration (Asana, GitLab, GitHub) via `task_tracker` object
- Record `parent_branch` for merge-back target
- Support task context switching and resumption

## Location

```
<project-root>/.current-task
```

## Format

JSON object with defined schema:

```json
{
  "task_id": "A3F2B9",
  "branch": "feature/A3F2B9-convert-current-task",
  "parent_branch": "main",
  "task_doc": "docs/active/2026-03/A3F2B9-2603170218-TSK-convert-current-task-to.md",
  "started": "2026-03-17T02:18:00Z",
  "task_tracker": {
    "backend": "asana",
    "id": "1234567890123456",
    "url": "https://app.asana.com/0/0/1234567890123456"
  }
}
```

When no external tracker is configured:

```json
{
  "task_id": "A3F2B9",
  "branch": "feature/A3F2B9-convert-current-task",
  "parent_branch": "main",
  "task_doc": "docs/active/2026-03/A3F2B9-2603170218-TSK-convert-current-task-to.md",
  "started": "2026-03-17T02:18:00Z",
  "task_tracker": null
}
```

## Fields

| Field | Required | Description | Example |
|-------|----------|-------------|---------|
| `task_id` | Yes | Task ID (6 hex chars, uppercase) | `A3F2B9` |
| `branch` | Yes | Git branch name for this task | `feature/A3F2B9-description` |
| `parent_branch` | Yes | Branch this was created from (merge-back target) | `main` |
| `task_doc` | Yes | Path to primary TSK/INC document | `docs/active/2026-03/A3F2B9-TSK-desc.md` |
| `started` | Yes | UTC ISO 8601 timestamp when work started | `2026-03-17T02:18:00Z` |
| `task_tracker` | Yes | External tracker object, or `null` | See below |

### task_tracker Object

| Field | Description | Example |
|-------|-------------|---------|
| `backend` | Tracker type: `asana`, `gitlab`, or `github` | `asana` |
| `id` | External ID (Asana GID, issue number) | `1234567890123456` |
| `url` | Auto-generated URL to the external task | `https://app.asana.com/0/0/1234567890123456` |

**URL generation patterns** (hardcoded per backend):
- **Asana**: `https://app.asana.com/0/0/{id}`
- **GitLab**: `https://{git.instance}/{git.repo}/-/issues/{id}` (from PROJECT.yaml)
- **GitHub**: `https://github.com/{git.repo}/issues/{id}` (from PROJECT.yaml)

## Reading .current-task

Use `load_current_task()` from `scripts/common.sh`:

```bash
source ~/.claude/scripts/common.sh

if load_current_task; then
    echo "Task: $CT_TASK_ID"
    echo "Branch: $CT_BRANCH"
    echo "Parent: $CT_PARENT_BRANCH"
    echo "Doc: $CT_TASK_DOC"
    echo "Started: $CT_STARTED"
    echo "Tracker: $CT_TRACKER_BACKEND / $CT_TRACKER_ID"
    echo "URL: $CT_TRACKER_URL"
    echo "Asana GID: $CT_ASANA_GID"  # alias when backend is asana
fi
```

**Variables set by `load_current_task()`**:

| Variable | Description |
|----------|-------------|
| `CT_TASK_ID` | Task ID (uppercase) |
| `CT_BRANCH` | Branch name |
| `CT_PARENT_BRANCH` | Parent branch (merge-back target) |
| `CT_TASK_DOC` | Task document path |
| `CT_STARTED` | Start timestamp |
| `CT_TRACKER_BACKEND` | Tracker backend (asana/gitlab/github, or empty) |
| `CT_TRACKER_ID` | External tracker ID (or empty) |
| `CT_TRACKER_URL` | External tracker URL (or empty) |
| `CT_ASANA_GID` | Backwards-compatible alias — set to `CT_TRACKER_ID` when backend is `asana` |

## Writing .current-task

Use `write_current_task()` from `scripts/common.sh`:

```bash
write_current_task "A3F2B9" "feature/A3F2B9-task" "main" "docs/TSK.md" "asana" "1234567890"
#                  task_id   branch                parent  task_doc       backend  tracker_id
```

URL is auto-generated. Pass empty strings for `backend` and `tracker_id` when no external tracker.

## Recovery

If `.current-task` is missing or corrupt while on a feature branch:

```bash
~/.claude/scripts/task-recover.sh --json
```

The script:
1. Extracts task ID from branch name (e.g., `feature/A3F2B9-desc` → `A3F2B9`)
2. Finds the TSK document via `find_primary`
3. Parses External Tracking section for tracker ID
4. Resolves parent branch (defaults to default branch)
5. Writes `.current-task` in JSON format

## Integration with Task Commands

| Command | Reads | Writes | Removes |
|---------|-------|--------|---------|
| `task-start` | — | Creates with `write_current_task()` | — |
| `task-resume` | — | Recreates with `write_current_task()` | — |
| `task-continue` | `load_current_task()` | — | — |
| `task-update` | `load_current_task()` | — | — |
| `task-hold` | `load_current_task()` | — | — |
| `task-close` | `load_current_task()` + cleanup | — | Removes file |
| `task-recover` | — | Rebuilds from branch context | — |

## Related File: `.task-close-state`

During `task-close`, a lockfile `.task-close-state` is written alongside `.current-task`. It locks the `feature_branch → target_branch` relationship to prevent cascade merges on retry. Cleaned up as the last step of successful cleanup.

```json
{
  "task_id": "A3F2B9",
  "feature_branch": "feature/A3F2B9-task",
  "target_branch": "main",
  "created": "2026-03-17T02:18:00Z"
}
```

## Git Ignore

Automatically added to `.gitignore` by `task-start`. Never committed.

```gitignore
.current-task
.task-close-state
```

## Related Documentation

- Task management workflow: `docs/task-management.md`
- External tracking: `docs/reference/asana-mcp-integration.md`
- Task document template: `templates/task-TSK.md`
