---
command: scaffold
group: generators
backing_script: prompt-only
mutates: [files]
runtime: varies
destructive: false
requires_project_yaml: optional
project_yaml_fields: []
requires_project_knowledge: none
project_knowledge_sections: []
---

# /scaffold

Generates a complete feature structure that matches the patterns already
in your project, rather than a generic template — and resumes across
sessions for large scaffolds.

---

## When to use it

- Adding a feature that should look like the ones already there
- Standing up a new module, component, or service
- Resuming an interrupted scaffold

## Usage

```bash
/scaffold <feature name>
```

## Arguments

| Argument / Flag | Required | Description |
|---|---|---|
| `$ARGUMENTS` | Yes | Feature or component name to scaffold. |

## Backing script

None — pure prompt command; all logic lives in the LLM.

## How it works

1. **Learn the existing patterns** — how this project structures a
   comparable feature: file layout, naming, tests, wiring.
2. **Generate** the structure to match.
3. **Report** what was created and what still needs hand-wiring.

Session state persists, so a large scaffold can resume rather than restart.

## Notes & gotchas

- The value is in matching *your* conventions. If the project has no
  comparable feature to learn from, the output is a generic guess — say so
  rather than treating it as house style.
- Run [`/test`](test.md) after; scaffolded tests usually need real assertions.

---

**See also:** [`/test-tdd`](test-tdd.md) · [`/makefile-init`](makefile-init.md)
