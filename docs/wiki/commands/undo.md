---
command: undo
group: git
backing_script: prompt-only
mutates: [git, files]
runtime: ~10s
destructive: false
requires_project_yaml: none
project_yaml_fields: []
requires_project_knowledge: none
project_knowledge_sections: []
---

# /undo

Rolls back the last destructive operation a command performed, using git
state and any per-command backups. It shows you what changed and which
restore points are safe before touching anything.

---

## When to use it

- A command modified more than you expected
- You want the previous state back but aren't sure which commit is safe
- A bulk operation (`/remove-comments`, `/fix-imports`, `/make-it-pretty`) went wrong

## Usage

```bash
/undo
```

## Arguments

None — invoke with no input.

## Backing script

None — pure prompt command; all logic lives in the LLM.

## How it works

1. **Git-based recovery** — inspect uncommitted changes, review recent
   commits, identify safe restore points.
2. **Project backups** — look for `undo/backups/` and any
   operation-specific backup, and verify its integrity.
3. **Change analysis** — show exactly what was modified before restoring.
4. **Restore**, once you've chosen a point.

## Notes & gotchas

- It shows before it acts. Nothing is restored until you pick a point.
- Uncommitted work is the hardest case to recover — commit before running
  any bulk-modification command, and `/undo` has somewhere to return to.

---

**See also:** [`/git-commit`](git-commit.md)
