---
command: session-end
group: project-config
backing_script: prompt-only
mutates: [files]
runtime: ~15s
destructive: false
requires_project_yaml: none
project_yaml_fields: []
requires_project_knowledge: none
project_knowledge_sections: []
---

# /session-end

Closes a work session: summarizes what was accomplished, what's still
pending, and why decisions were made, then writes it into `CLAUDE.md` as
handoff notes.

---

## When to use it

- Ending a session you or someone else will resume
- Before a `/clear`, so the summary outlives the context
- At a natural break, to bank what was learned

## Usage

```bash
/session-end
```

## Arguments

None — invoke with no input.

## Backing script

None — pure prompt command; all logic lives in the LLM.

## How it works

1. **Review** files created and modified during the session, plus git
   changes and commit history.
2. **Summarize** completed work, decisions and their rationale, pending
   items, and next steps.
3. **Write** it into the appropriate `CLAUDE.md`.

## Notes & gotchas

- The rationale is the part worth writing. What changed is recoverable
  from git; why it changed is not.
- Pending items become the next session's starting point — be specific
  enough that they're actionable cold.

---

**See also:** [`/session-start`](session-start.md) · [`/leftoff`](leftoff.md)
