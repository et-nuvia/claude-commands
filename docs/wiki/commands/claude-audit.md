---
command: claude-audit
group: audit
backing_script: ~/.claude/scripts/claude-audit.sh
mutates: []
runtime: ~5s
destructive: false
requires_project_yaml: none
project_yaml_fields: []
requires_project_knowledge: none
project_knowledge_sections: []
---

# /claude-audit

Audits a `CLAUDE.md` memory file — global or project — for size,
structure, and token efficiency, since every line of it is paid for on
every turn of every session.

---

## When to use it

- A `CLAUDE.md` that has grown by accretion
- Before adding another section to one
- When sessions feel like they start heavy

## Usage

```bash
/claude-audit
```

## Arguments

| Argument / Flag | Required | Description |
|---|---|---|
| `$ARGUMENTS` | No | `--global`, `--file <path>`, or `--both`. |

## Backing script

**Script**: `~/.claude/scripts/claude-audit.sh`

```bash
~/.claude/scripts/claude-audit.sh            # project file
~/.claude/scripts/claude-audit.sh --global   # ~/.claude/CLAUDE.md
~/.claude/scripts/claude-audit.sh --file <path>
~/.claude/scripts/claude-audit.sh --both
```

## How it works

Measures size and token cost, checks structure against the conventions,
and reports what could be moved out — to a skill, a reference doc, or
nothing at all.

## Notes & gotchas

- The test for a `CLAUDE.md` line is whether it must be true on *every*
  turn. Anything needed only sometimes belongs in a skill, which loads on
  demand instead.
- Read-only; it reports, you edit.

---

**See also:** [Skills and Subagents](11-skills-and-subagents) · [`/init`](init.md)
