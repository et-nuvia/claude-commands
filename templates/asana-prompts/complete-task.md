# Complete Task in Asana

Use this pattern to mark an Asana task as completed.

## MCP Tools

### Option 1: Complete Task (Convenience)
```
mcp__asana__complete_task
```

**Parameters**:
- `task_gid` (required): The Asana task GID

**Returns**:
- Success: Updated task object with `completed: true`
- Failure: Error message

### Option 2: Update Task (More Flexible)
```
mcp__asana__update_task
```

**Parameters**:
- `task_gid` (required): The Asana task GID
- `completed` (optional): Boolean to mark complete/incomplete
- `name` (optional): Update task name
- `notes` (optional): Update task notes
- `due_on` (optional): Update due date

**Returns**:
- Success: Updated task object
- Failure: Error message

## Usage Pattern

```markdown
## Complete Task in Asana

1. **Get task GID** from local document (see get-task-gid.md)

2. **Post completion comment** (recommended before marking complete):
   ```
   mcp__asana__add_comment(
     task_gid: "<task_gid>",
     text: "<completion_summary>"
   )
   ```

3. **Mark task complete**:
   ```
   mcp__asana__complete_task(
     task_gid: "<task_gid>"
   )
   ```

4. **Update local metadata**:
   - Set "Last Synced" timestamp
   - Note completion in Progress Log

5. **Handle errors**:
   - If MCP fails: Log warning, continue with local closeout
   - Don't fail task-close command if Asana sync fails
```

## Completion Comment Format

Before marking complete, post a comprehensive summary:

```
✅ Task completed

Summary:
- Implemented comprehensive Asana MCP integration
- Created shared prompt patterns for reusability
- Updated 8 task commands with Asana sync
- All tests passing, coverage at 87%

Deliverables:
- PR: https://github.com/owner/repo/pull/123
- Docs: docs/reference/asana-mcp-integration.md
- Test coverage: 87% (target: 80%)

Implementation Details:
- Files modified: 12
- Lines changed: +456 / -123
- Branch: task-0002-asana-integration
- Commits: 8

Testing:
✅ Unit tests: 45/45 passing
✅ Integration tests: 12/12 passing
✅ E2E tests: 5/5 passing
✅ Coverage above threshold

Deployed:
- Staging: 2026-02-10 17:30:00 UTC
- Production: 2026-02-10 18:00:00 UTC
- Status: Production ready ✅

Related Documents:
- TSK: docs/completed/0000-0099/0002-2602101602-TSK-asana-integration.md
- PLN: docs/completed/0000-0099/0002-2602101620-PLN-implementation-approach.md
- SUM: docs/completed/0000-0099/0002-2602101800-SUM-executive-summary.md
```

## When to Mark Complete

Mark Asana task complete when:
1. ✅ All requirements implemented
2. ✅ All tests passing
3. ✅ Code reviewed and approved
4. ✅ PR merged to main/master
5. ✅ Deployed to production
6. ✅ Smoke tests passing
7. ✅ Documentation updated

**Don't mark complete if**:
- Task is on hold (use task-hold instead)
- Work is deferred (note in comment, don't complete)
- Waiting for external dependency (use task-hold)

## Example: task-close Integration

```markdown
## Step: Complete Asana Task

### Prerequisites
1. Check if Asana sync enabled for "close" operation
2. Get task GID from local document
3. Ensure PR is created and merged (or note if no PR needed)

### Post Completion Summary
1. Format completion comment with:
   - Summary of work done
   - Deliverables (PR, docs, etc.)
   - Test results
   - Deployment status
   - Related documents

2. Call `mcp__asana__add_comment` with formatted summary

### Mark Complete
1. Call `mcp__asana__complete_task(task_gid: "<gid>")`
2. If error: Log warning but don't fail command
3. If success: Update "Last Synced" timestamp

### Update Local Document
1. Move document from active/ to completed/
2. Update Status field to "Completed"
3. Update Completed timestamp
4. Update Progress Log with final entry

### Report to User
```
✓ Task closed successfully

Local:
  - Sequence: 0002
  - Status: Completed
  - Document moved to: docs/completed/0000-0099/

Asana:
  ✓ Posted completion summary
  ✓ Marked task complete
  - Task URL: https://app.asana.com/0/PROJECT/TASK

Next steps:
  - Task artifacts archived
  - Ready for next task
```
```

## Handling Already Complete Tasks

If task is already complete in Asana:

```markdown
1. Call `mcp__asana__complete_task`
2. If MCP returns error: "Task already complete"
3. Log info: "Asana task already marked complete"
4. Continue with local closeout (not an error)
```

## Incomplete vs. Complete

If reopening a task (rare):

```markdown
## Reopen Task
Use `mcp__asana__update_task` with `completed: false`:

mcp__asana__update_task(
  task_gid: "<gid>",
  completed: false
)

Add comment explaining why reopened:
"🔄 Task reopened: [reason]"
```

## Error Handling

```markdown
### Common Errors

1. **Task already complete**:
   - Log: "Task already complete in Asana"
   - Action: Continue (not an error)

2. **Task not found** (404):
   - Error: "Asana task <gid> not found"
   - Action: Log warning, continue with local closeout

3. **No access** (403):
   - Error: "No permission to update Asana task"
   - Action: Log warning, continue with local closeout

4. **Network error**:
   - Error: "Failed to connect to Asana"
   - Action: Log warning, continue with local closeout

**Important**: Never fail task-close command because Asana sync fails.
Local closeout is more important than external sync.
```

## Completion Checklist

Before calling `complete_task`:

- [ ] All work committed and pushed
- [ ] PR created (if applicable)
- [ ] Tests passing
- [ ] Code reviewed
- [ ] PR merged
- [ ] Deployed to production (if applicable)
- [ ] Smoke tests passing
- [ ] Documentation updated
- [ ] Completion comment posted to Asana

## Example Usage

```bash
# In task-close command:

# 1. Post summary comment
mcp__asana__add_comment(
  task_gid: "1234567890",
  text: "✅ Task completed\n\nSummary: ...\nPR: ..."
)

# 2. Mark complete
mcp__asana__complete_task(
  task_gid: "1234567890"
)

# 3. Continue with local closeout regardless of Asana result
```
