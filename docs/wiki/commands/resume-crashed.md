---
command: resume-crashed
group: outlier
backing_script: ~/.claude/scripts/session-registry.sh
mutates: []
runtime: ~5s
destructive: false
requires_project_yaml: none
project_yaml_fields: []
requires_project_knowledge: none
project_knowledge_sections: []
---

# /resume-crashed

Lists Claude Code sessions that ended without a clean exit — a crash, a
forced reboot — and restores the ones you choose.

---

## When to use it

- After a crash or forced restart
- When a session vanished mid-task
- To confirm whether anything was actually lost

## Usage

```bash
/resume-crashed
```

## Arguments

None — invoke with no input.

## Backing script

**Script**: `~/.claude/scripts/session-registry.sh`

The registry is crash-survivable: sessions are recorded as they start, so
a session that never exits cleanly is still on the list afterwards.

## How it works

1. **List** sessions with no clean-exit record.
2. **Choose** which to restore.
3. **Restore** the selected sessions.

## Notes & gotchas

- A session appearing here means it never exited cleanly — not
  necessarily that work was lost. Check the working tree before assuming.
- Committed work is safe regardless; this restores *conversation* context.

---

**See also:** [`/leftoff`](leftoff.md) · [`/task-continue`](task-continue.md)
