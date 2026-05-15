# Post Comment to Asana Task

Use this pattern to add a comment (story) to an Asana task.

## MCP Tool

```
mcp__asana__add_comment
```

**Parameters**:
- `task_gid` (required): The Asana task GID (numeric string)
- `text` (required): The comment text (supports Markdown)

**Returns**:
- Success: Comment object with GID and created timestamp
- Failure: Error message

## Usage Pattern

```markdown
## Post Comment to Asana

1. **Get task GID** from local document (see get-task-gid.md)
2. **Format comment text** with appropriate emoji and context
3. **Call MCP tool**:
   ```
   mcp__asana__add_comment(
     task_gid: "<task_gid>",
     text: "<formatted_comment>"
   )
   ```
4. **Update metadata**: Set "Last Synced" timestamp in local doc
5. **Handle errors**: If MCP fails, log warning but don't fail command
```

## Comment Formatting

Use consistent emoji and formatting for different operations:

### Work Started
```
🚀 Work started on sequence 0002

Branch: task-0002-description
Environment: Development
Started: 2026-02-10 16:30:00 UTC
```

### Progress Update
```
📝 Progress update

Completed:
- Created asana-api.sh with core functions
- Integrated MCP tools into task-start

In Progress:
- Adding MCP support to task-continue

Blockers:
- None

Next Steps:
- Complete remaining commands
- Test end-to-end workflow
```

### Task on Hold
```
⏸️ Task on hold

Reason: Waiting for customer response on API requirements

Summary:
- Completed initial research
- Identified 3 integration approaches
- Created comparison document (0002-2602101630-FND-api-integration-options.md)

Expected Resume: 2026-02-11 (pending customer feedback)
```

### Audit Findings
```
🔍 Task audit complete

Test Coverage: 85% (target: 80%) ✅
Files Modified: 12 files
Lines Changed: +456 / -123

Key Findings:
✅ All tests passing
✅ Coverage above threshold
⚠️ 2 TODO comments added (documented in task-audit output)

Branch: task-0002-description
```

### Task Completion
```
✅ Task completed

Summary:
- Implemented comprehensive Asana MCP integration
- Created shared prompt patterns for reusability
- Updated 8 task commands with Asana sync
- All tests passing, coverage at 87%

Deliverables:
- PR: https://github.com/owner/repo/pull/123
- Documentation: docs/reference/asana-mcp-integration.md
- Test coverage: 87% (target: 80%)

Deployed: 2026-02-10 18:00:00 UTC
Status: Production ready ✅
```

## Update Last Synced Timestamp

After successfully posting a comment, update the document:

```bash
# Update Last Synced timestamp
TIMESTAMP=$(date -u +"%Y-%m-%d %H:%M:%S")
sed -i '' "s/- Last Synced: \[.*\]/- Last Synced: ${TIMESTAMP}/" "$TASK_DOC"
```

## Error Handling

```markdown
## Error Handling for MCP Comment

1. Call `mcp__asana__add_comment` with task_gid and text
2. If MCP returns error:
   - Log warning: "Failed to post Asana comment: <error>"
   - Do NOT fail the task command
   - Continue with local operations
3. If MCP succeeds:
   - Update "Last Synced" timestamp
   - Log success: "✓ Posted comment to Asana task <task_gid>"
```

## Example: Full Integration in task-start

```markdown
## Step 5: Update Asana (if configured)

### Check Configuration
1. Read PROJECT.yaml
2. Check if backend is "asana"
3. Check if "start" in sync_on_operations
4. If not configured: Skip Asana sync

### Get Task GID
1. Read task document: docs/active/<range>/<task_id>-*-TSK-*.md
2. Extract Asana Task GID from External Tracking section
3. If no GID: Skip Asana sync (not linked)

### Post Comment
1. Format comment:
   ```
   🚀 Work started on task <task_id>

   Branch: <branch_name>
   Environment: Development
   Started: <timestamp>
   ```

2. Call MCP:
   ```
   mcp__asana__add_comment(
     task_gid: "<task_gid>",
     text: "<formatted_comment>"
   )
   ```

3. Update Last Synced timestamp in document

4. Report to user:
   - Success: "✓ Notified Asana task <task_gid>"
   - Failure: "⚠️ Failed to update Asana (local work continues)"
```

## Markdown Support

Asana supports limited Markdown in comments:
- **Bold**: `**text**`
- *Italic*: `*text*`
- Lists: `- item` or `* item`
- Links: `[text](url)`
- Code: `` `code` ``
- Emoji: 🚀 ✅ ⚠️ 📝 🔍 ⏸️

**Not supported**: Headers, tables, images

## Rate Limiting

MCP handles rate limiting automatically, but be aware:
- Asana limit: 150 requests/minute
- MCP retries transient failures
- If rate limited, MCP will retry after delay

## Example Usage in Task Commands

| Command | Comment Type | When Posted |
|---------|--------------|-------------|
| `/task-start` | Work Started | After branch created, before code changes |
| `/task-continue` | Progress Update | After commit, before returning to user |
| `/task-hold` | On Hold | After creating summary document |
| `/task-audit` | Audit Findings | After test coverage analysis complete |
| `/task-close` | Completion | After PR created and final commit |
