---
command: task-summary
group: task-lifecycle
backing_script: ~/.claude/scripts/task-summary.sh
mutates: [git, files]
runtime: ~15-30s
destructive: false
requires_project_yaml: none
project_yaml_fields: []
requires_project_knowledge: none
project_knowledge_sections: []
---

# /task-summary

> Part of the [Task Lifecycle workflow](../08-workflows.md#task-lifecycle).

Creates a SUM (executive summary) document for a task and commits it to the repo. The document is intended for stakeholders — it distills the task's outcome, key decisions, and impact into a concise, shareable format. Run it at task completion, after placing a task on hold, or after an incident.

---

## When to use it

- After completing a task, to produce a stakeholder-facing summary before `/task-close`
- When putting a task on hold and needing to communicate status to others
- After an incident, to document what happened and what was resolved

## Usage

```bash
/task-summary [TASK_ID]
```

**Common invocations:**

```bash
/task-summary                  # uses .current-task
/task-summary A3F2B9           # target a specific task by ID
```

## Arguments

| Argument / Flag | Required | Description |
|---|---|---|
| `TASK_ID` | No | Task ID to summarize. Defaults to the current task from `.current-task`. |

## Dependencies

**External commands / packages:**

| Dependency | Why it's needed | Install |
|---|---|---|
| `git` | Commit the generated SUM document | preinstalled |
| `jq` | Parse script JSON response | `brew install jq` / `apt install jq` |

**Project files consumed:**

- `PROJECT.yaml` (PY) — No
- `PROJECT-KNOWLEDGE.md` (PK) — No
- `.current-task` — read to identify the active task when no TASK_ID is provided
- `~/.claude/templates/task-SUM.md` — SUM document template
- `docs/active/<task_id>/` — source TSK + related docs read for content

## Backing script

**Script**: `~/.claude/scripts/task-summary.sh`

**Inputs:** `--full`, optional `--task-id <TASK_ID>`. Locates the task document and checks for existing summaries to avoid duplicates.

**Outputs (structured JSON):** `next_action` ∈ {`display_summary`, `get_task_id`, `fix_error`}, plus `task_title`, `task_doc`, `sum_filepath`, `sum_template`, and a flag for whether an existing SUM was found.

**Invocation surface:**

```bash
~/.claude/scripts/task-summary.sh --full                           # main (uses .current-task)
~/.claude/scripts/task-summary.sh --full --task-id TASK_ID        # target specific task
~/.claude/scripts/task-summary.sh --find --task-id TASK_ID        # locate task only
~/.claude/scripts/task-summary.sh --extract                        # extract metadata
~/.claude/scripts/task-summary.sh --generate                       # generate SUM document
~/.claude/scripts/task-summary.sh --raw --full                     # debug: bypass formatting
```

## How it works

1. **Find task** — script locates the task document from `.current-task` or the supplied `--task-id`. Checks for an existing SUM to avoid duplicates.
2. **Extract metadata** — reads the TSK document to pull title, status, dates, and related documents (PLN, DSN, etc.).
3. **LLM writes SUM** — LLM fills `sum_template` using the extracted data, writing a stakeholder-friendly narrative to `sum_filepath` with the Write tool.
4. **Commit** — the generated document is committed to the repo with a message referencing the task.
5. **Display** — confirms the file path and suggests sharing with stakeholders.

## Example workflows

### Scenario: Completion summary before close

```
/task-audit           # verify quality
/task-summary         # create stakeholder summary
/task-close           # ship
```

`/task-close` also auto-generates a SUM when configured, but running `/task-summary` explicitly lets you review the document before closing.

### Scenario: Hold status communication

```
/task-hold --hold-reason "Waiting on design approval" ...
/task-summary         # communicate current status to team
```

### Scenario: Summary output

```
/task-summary A3F2B9
```

```
✓ Summary created: docs/active/A3F2B9/A3F2B9-20260516-SUM-add-me-endpoint.md
  Task:   A3F2B9 — Add /me endpoint
  Status: Completed
  Commit: 8a3f1c2

Share with stakeholders or attach to the Asana task.
```

## Notes & gotchas

- The script checks for an existing SUM document and will warn rather than overwrite. If you need to regenerate, delete the existing SUM first.
- `/task-close` generates a SUM automatically as part of closeout — only run `/task-summary` manually when you want the document before closing or for an in-progress/on-hold task.
- **If it fails:** no `.current-task` → supply an explicit task ID with `--task-id`. Other errors: debug with `~/.claude/scripts/task-summary.sh --raw --full`.
