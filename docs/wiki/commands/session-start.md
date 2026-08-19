---
command: session-start
group: project-config
backing_script: prompt-only
mutates: [files]
runtime: ~5s
destructive: false
requires_project_yaml: none
project_yaml_fields: []
requires_project_knowledge: none
project_knowledge_sections: []
---

# /session-start

Opens a documented work session, recording goals and current state into
the project's `CLAUDE.md` so the context survives beyond this
conversation.

---

## When to use it

- Beginning a stretch of work you'll want to resume later
- Handing context to a teammate who'll pick it up
- Any session where "what were we trying to do?" would be expensive to reconstruct

## Usage

```bash
/session-start
```

## Arguments

None — invoke with no input. The command asks what you're working on.

## Backing script

None — pure prompt command; all logic lives in the LLM.

## How it works

1. **Ask** what you're working on, what the goals are, and what context matters.
2. **Read** existing memory files — project `./CLAUDE.md` for team-shared
   context, user `~/.claude/CLAUDE.md` for personal tracking.
3. **Record** the session timestamp, git state and branch, and the stated goals.

## Notes & gotchas

- Writes into the native memory system rather than a parallel one, so the
  context is visible to every later session in this project.
- Pairs with [`/session-end`](session-end.md). Starting without ending
  leaves a session open in the file.

---

**See also:** [`/session-end`](session-end.md) · [`/leftoff`](leftoff.md)
