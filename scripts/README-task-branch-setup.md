# task-branch-setup.sh

Comprehensive task branch setup script that automates branch switching, stashing, and task branch creation.

## Purpose

This script handles the complex workflow of:
1. Checking current branch state
2. Calculating the correct task branch name from V4 documentation
3. Stashing uncommitted changes (with user confirmation)
4. Switching to the dev/default branch
5. Pulling latest changes
6. Creating or checking out the task branch
7. Restoring stashed changes

## Usage

```bash
# By task ID
~/.claude/scripts/task-branch-setup.sh --input 23

# By task document path
~/.claude/scripts/task-branch-setup.sh --input docs/active/0023-2602101430-TSK-multi-audience-release-notes.md
```

## Input

Accepts either:
- **Task ID**: `A3F2B9` (finds primary TSK/INC document)
- **Task document path**: Full path to any V4 task document

## Output

Returns JSON to stdout with:

### Success Response
```json
{
  "status": "success",
  "message": "Task branch setup complete",
  "original_branch": "main",
  "dev_branch": "dev",
  "task_branch": "feature/0023-multi-audience-release-notes",
  "branch_switched": true,
  "stash_created": true,
  "stash_name": "task-branch-setup: switching from main to feature/0023-... (2026-02-10_14:30:00)",
  "task": {
    "sequence": "0023",
    "type": "TSK",
    "branch_type": "feature",
    "issue_number": "0023",
    "slug": "multi-audience-release-notes",
    "document": "/path/to/docs/active/0023-2602101430-TSK-multi-audience-release-notes.md"
  },
  "actions": [
    "Found task document: 0023-2602101430-TSK-multi-audience-release-notes.md",
    "Calculated task branch: feature/0023-multi-audience-release-notes",
    "Current branch: main",
    "Stashed changes: task-branch-setup: switching from main to feature/0023-... (2026-02-10_14:30:00)",
    "Dev branch: dev",
    "Fetched from remote",
    "Checked out dev branch: dev",
    "Pulled latest changes from origin/dev",
    "Created new task branch: feature/0023-multi-audience-release-notes",
    "Restored stashed changes"
  ],
  "warnings": []
}
```

### Error Response
```json
{
  "status": "error",
  "message": "Failed to checkout dev branch: dev",
  "original_branch": "main",
  "dev_branch": "dev",
  "task_branch": "feature/0023-multi-audience-release-notes",
  "actions": [
    "Found task document: 0023-2602101430-TSK-multi-audience-release-notes.md",
    "Calculated task branch: feature/0023-multi-audience-release-notes",
    "Current branch: main"
  ],
  "errors": [
    "Failed to checkout dev branch: dev"
  ]
}
```

### Aborted Response
```json
{
  "status": "aborted",
  "message": "User aborted due to uncommitted changes",
  "original_branch": "main",
  "task_branch": "feature/0023-multi-audience-release-notes",
  "actions": [
    "Found task document: 0023-2602101430-TSK-multi-audience-release-notes.md",
    "Calculated task branch: feature/0023-multi-audience-release-notes",
    "Current branch: main"
  ],
  "warnings": []
}
```

## Exit Codes

- `0` - Success (task branch ready)
- `1` - Error (fatal error occurred)
- `2` - User action required (aborted or invalid input)

## Branch Naming Convention

Follows V4 documentation naming:
```
{type}/{issue_or_sequence}-{slug}
```

**Branch types** (inferred from document):
- `feature/` - New features (default for TSK)
- `fix/` - Bug fixes (INC or contains "bug"/"fix")
- `refactor/` - Code refactoring
- `test/` - Test additions
- `docs/` - Documentation

**Examples**:
- `feature/0023-multi-audience-release-notes`
- `fix/0042-contact-form-validation`
- `feature/123-add-user-authentication` (if GitHub issue #123 found in doc)

## Dev Branch Detection

Uses intelligent fallback strategy:

1. **Tier 1**: Call `get-default-branch.sh` (uses PROJECT.yaml or git remote HEAD)
2. **Tier 2**: Parse PROJECT.yaml directly with `yq`
3. **Tier 3**: Common defaults (`dev`, `develop`, `development`, `main`, `master`)
4. **Tier 4**: User prompt if all else fails

## User Prompts

Script prompts user for decisions in these cases:

### Uncommitted Changes
```
❓ Uncommitted changes detected. What would you like to do?

  1. stash
  2. abort

Choice [1-2]: _
```

### Stash Restore Conflicts
```
❓ Failed to restore stashed changes. Conflicts may exist.

  1. resolve_manually
  2. abort

Choice [1-2]: _
```

## Features

✅ **Deterministic** - Same input always produces same branch name
✅ **Idempotent** - Safe to run multiple times
✅ **State preservation** - Stashes and restores changes
✅ **Error recovery** - Attempts to restore original state on failure
✅ **JSON output** - Easy parsing by AI or scripts
✅ **Leverages existing scripts** - Uses `doc-utils.sh`, `get-default-branch.sh`
✅ **Smart branching** - Creates or checks out as needed
✅ **Remote sync** - Fetches and pulls latest changes

## Integration

Used by `/task-start` command:
```bash
BRANCH_RESULT=$(~/.claude/scripts/task-branch-setup.sh --input "$INPUT" 2>&1)
BRANCH_EXIT_CODE=$?

BRANCH_STATUS=$(echo "$BRANCH_RESULT" | jq -r '.status')
TASK_BRANCH=$(echo "$BRANCH_RESULT" | jq -r '.task_branch')
```

## Dependencies

- `bash` 4.0+
- `git`
- `jq` (for JSON output)
- `yq` (optional, for PROJECT.yaml parsing)
- `~/.claude/scripts/doc-utils.sh` (V4 document utilities)
- `~/.claude/scripts/get-default-branch.sh` (branch detection)

## Error Handling

All errors include:
- Clear message describing what went wrong
- List of actions taken before error
- Original state information for recovery

Script attempts to restore original state on error:
- Switches back to original branch
- Restores stash if created
- Provides recovery commands if needed

## Examples

### Simple case - clean working directory
```bash
$ ~/.claude/scripts/task-branch-setup.sh --input 23
# Switches from main -> dev -> feature/0023-slug
# No stash needed
```

### With uncommitted changes
```bash
$ ~/.claude/scripts/task-branch-setup.sh --input 23
# Prompts to stash
# Switches branches
# Restores stash
```

### Already on task branch
```bash
$ ~/.claude/scripts/task-branch-setup.sh --input 23
# Already on feature/0023-slug
# Returns success immediately
```

### Task branch exists remotely
```bash
$ ~/.claude/scripts/task-branch-setup.sh --input 23
# Fetches and checks out from remote
# No branch creation needed
```

## Testing

```bash
# Test with task ID
~/.claude/scripts/task-branch-setup.sh --input 3

# Test with document path
~/.claude/scripts/task-branch-setup.sh --input docs/active/0003-*.md

# Test JSON parsing
~/.claude/scripts/task-branch-setup.sh --input 3 | jq .

# Test already on branch
git checkout feature/0003-test
~/.claude/scripts/task-branch-setup.sh --input 3
```

## See Also

- `doc-utils.sh` - V4 document utility functions
- `get-default-branch.sh` - Dev/default branch detection
- `git-branch-check.sh` - Branch validation
- `/task-start` command - Main task startup workflow
