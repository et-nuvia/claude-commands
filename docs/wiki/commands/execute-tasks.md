---
command: execute-tasks
group: task-lifecycle
backing_script: prompt-only
mutates: [files, git]
runtime: varies
destructive: false
requires_project_yaml: none
project_yaml_fields: []
requires_project_knowledge: none
project_knowledge_sections: []
---

# /execute-tasks

Executes the next task from an Agent OS task plan, in sequence.

> **External dependency:** this command defers to
> `~/.agent-os/instructions/core/execute-tasks.md`, which ships with
> [Agent OS](https://buildermethods.com/agent-os), not with this repo.
> Without Agent OS installed the command has nothing to read.

---

## When to use it

- Working through an Agent OS task plan
- Only if your project uses Agent OS — the native equivalent is
  [`/task-continue`](task-continue.md)

## Usage

```bash
/execute-tasks
```

## Arguments

None — invoke with no input.

## Backing script

None — pure prompt command; all logic lives in the LLM.

## How it works

Reads the Agent OS instruction file and executes the next task in the
plan, in order.

## Notes & gotchas

- **This is not part of the task lifecycle in this repo.** If you are
  using TSK/PLN documents, [`/task-continue`](task-continue.md) is the
  command you want; the two track progress in different places and
  running both against one piece of work will disagree.

---

**See also:** [`/task-continue`](task-continue.md) · [`/plan-product`](plan-product.md)
