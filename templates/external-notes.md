# External Task Notes Template

This template is used by `/task-capture` and `/task-create` to format the description/notes field in external task management systems (Asana, GitLab).

**Used by**: `~/.claude/commands/task-capture.md`, `~/.claude/commands/task-create.md`

---

## Template

```
## Summary
[1-2 sentence description of what needs to be done]

## Local Reference
- **Task ID**: [TASK_ID]
- **Document**: [TASK_ID]-[DATETIME]-TSK-[description].md
- **Path**: docs/active/[RANGE]/[FILENAME]

## Context
[Why this is needed - business reason, user need, or problem being solved]

<!-- CONDITIONAL: Include only if research/findings exist at capture time. Remove entirely if not. -->
## Findings
[Brief summary of what was discovered during investigation]
- **Current behavior**: [How the system works now in the relevant area]
- **Key code**: `path/to/file.ext:line` - [What it does]
- **Conclusion**: [What this means for implementation]

<!-- CONDITIONAL: Include only if implementation approach is known. Remove entirely if not. -->
## Approach
[Known implementation approach, key changes needed]

<!-- CONDITIONAL: Include only if specific files are identified. Remove entirely if not. -->
## Files
- `path/to/file.ext` - [What changes here]
```

---

## Rules

1. **Always include**: Summary, Local Reference, Context
2. **Findings**: Include ONLY if research/investigation was done (codebase analysis, debugging, root cause). Remove the entire section if no findings exist.
3. **Approach**: Include ONLY if the implementation approach is known at capture time. Remove entirely if not.
4. **Files**: Include ONLY if specific files have been identified. Remove entirely if not.
5. **Keep concise**: Asana/GitLab descriptions should be scannable. The detailed version lives in the local TSK document.
6. **Local Reference is mandatory**: Every external task MUST link back to its local TSK document task ID and filename so there is a clear connection between the two.
