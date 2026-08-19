---
command: plan-product
group: project-config
backing_script: prompt-only
mutates: [files]
runtime: varies
destructive: false
requires_project_yaml: none
project_yaml_fields: []
requires_project_knowledge: none
project_knowledge_sections: []
---

# /plan-product

Plans a product using the Agent OS product-planning instructions.

> **External dependency:** this command defers to
> `~/.agent-os/instructions/core/plan-product.md`, which ships with
> [Agent OS](https://buildermethods.com/agent-os), not with this repo.
> Without Agent OS installed the command has nothing to read.

---

## When to use it

- Product-level planning in a project that uses Agent OS
- Not for task-level planning — that's [`/task-plan`](task-plan.md)

## Usage

```bash
/plan-product
```

## Arguments

None — invoke with no input.

## Backing script

None — pure prompt command; all logic lives in the LLM.

## How it works

Reads the Agent OS instruction file and follows its product-planning
workflow.

## Notes & gotchas

- Sits outside this repo's TSK/PLN document model. Adopt one or the
  other per project rather than mixing them.

---

**See also:** [`/execute-tasks`](execute-tasks.md) · [`/task-plan`](task-plan.md)
