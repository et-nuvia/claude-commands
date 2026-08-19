---
command: leftoff
group: task-lifecycle
backing_script: ~/.claude/scripts/leftoff.sh
mutates: []
runtime: ~3s
destructive: false
requires_project_yaml: optional
project_yaml_fields:
  - task_management.backend
requires_project_knowledge: none
project_knowledge_sections: []
---

# /leftoff

Reconstructs where you stopped: open tasks, recent conversations, branch
and working-tree state, and recent commits — then recommends the next
step. Read-only; it answers "what was I doing?" without you having to
reopen five things to find out.

> **Config:** PROJECT.yaml optional — used to resolve tasks from the
> configured tracker.

---

## When to use it

- Returning to a project after a day or more away
- Starting a session and not sure which task is actually in flight
- After a machine restart, before deciding what to pick up

## Usage

```bash
/leftoff
```

## Arguments

None — invoke with no input.

## Backing script

**Script**: `~/.claude/scripts/leftoff.sh`

**Invocation surface:**

```bash
~/.claude/scripts/leftoff.sh --json --full                  # everything
~/.claude/scripts/leftoff.sh --json --tasks                 # task snapshot only
~/.claude/scripts/leftoff.sh --json --project               # branch / commits / tree
~/.claude/scripts/leftoff.sh --json --history               # recent conversations
~/.claude/scripts/leftoff.sh --json --history --limit 10    # more conversations
```

The section flags exist so a caller that only needs one part doesn't pay
for the rest.

## How it works

1. **Tasks** — open work items from the configured tracker plus any local
   task documents.
2. **Conversations** — recent sessions in this project, most recent first.
3. **Project state** — current branch, recent commits, uncommitted changes.
4. **Recommendation** — a single concrete next step, not a menu.

## Example workflows

### Scenario: picking up on Monday

```
/leftoff
```

```
🧭 Where You Left Off — ~/projects/example

📋 Tasks
  28E853  In progress  Fix session timeout on refresh
  9A21C4  On hold      Migrate uploads to S3 (waiting: infra ticket)

📦 Recent Commits
  a1b2c3d  fix(auth): reject unverified issuer
  …

👉 Recommended Next Step
  /task-continue 28E853 — plan item 4 of 7 outstanding
```

## Notes & gotchas

- Read-only. It never switches branches or touches the tracker.
- The recommendation is a suggestion built from state, not a decision —
  if it points somewhere you don't want to go, ignore it.
- **If it fails:** `--raw --full` shows the unformatted output; a missing
  tracker config shows up there rather than as an empty task list.
