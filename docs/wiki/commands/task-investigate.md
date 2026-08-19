---
command: task-investigate
group: task-lifecycle
backing_script: ~/.claude/scripts/task-investigate.sh
mutates: [files, git]
runtime: ~5s script, minutes of LLM investigation
destructive: false
requires_project_yaml: optional
project_yaml_fields:
  - task_management.backend
  - deployment.environments
requires_project_knowledge: optional
project_knowledge_sections:
  - Domain Workflows
  - Entity Relationships
  - Service Map
  - Integration Flows
---

# /task-investigate

Investigates the root cause of the current task's issue by tracing the
actual code path — and checking production when the evidence has to come
from a live system. It produces an **INV (investigation report)** document
and an updated Research Findings section in the TSK. The bar is evidence,
not plausibility.

> **Config:** PROJECT.yaml optional — reads the task backend to resolve the
> task, and `deployment.environments` to report which environments exist.
> PROJECT-KNOWLEDGE.md optional — domain workflows and service maps narrow
> where to look. The project `CLAUDE.md` is read as the source of truth for
> *how* to reach production (health endpoints, read-only DB access, secrets).

---

## When to use it

- A bug task where nobody can yet say *why* the system behaves this way
- `/task-start` flagged the task as investigation-driven
- A plan is about to be written on top of a hypothesis nobody has verified

## Usage

```bash
/task-investigate
```

**Common invocations:**

```bash
/task-investigate                # investigate the current task
/task-investigate 28E853         # investigate a specific task without switching to it
```

## Arguments

| Argument / Flag | Required | Description |
|---|---|---|
| `$ARGUMENTS` | No | A Task ID. Investigates that task without making it the active one. Falls back to `.current-task`. |

## Dependencies

**Project files consumed:**

- `PROJECT.yaml` (PY) — optional, for task resolution and environment list
- `PROJECT-KNOWLEDGE.md` (PK) — optional, read from
  `docs/architecture/PROJECT-KNOWLEDGE.md` when present
- `CLAUDE.md` — optional, read for production-access instructions
- The task's TSK document — the problem statement and any existing hypothesis

## Backing script

**Script**: `~/.claude/scripts/task-investigate.sh`

**Inputs:** `--task-id` (optional), the `.current-task` file, the TSK
document, `PROJECT.yaml`.

**Outputs:** a structured document (TOON for LLM callers, JSON for tests)
carrying task identity, the extracted problem statement, existing
hypothesis, mined candidate `file:line` references, whether production
access is documented and which environments exist, the resolved INV
document path and template, and `next_action: investigate`.

**Invocation surface:**

```bash
~/.claude/scripts/task-investigate.sh --full
~/.claude/scripts/task-investigate.sh --full --task-id 28E853
```

The script **does not investigate**. It assembles the ground truth and
hands the work back — the tracing is the LLM's job.

## How it works

1. **Ground in what's known** — read PROJECT-KNOWLEDGE.md if present, then
   the project `CLAUDE.md` for production access. Both are optional and
   skipped silently.
2. **Script pass** — identifies the task, extracts the problem statement and
   any prior hypothesis from the TSK, mines candidate code references, and
   reports whether live evidence is reachable.
3. **Investigate** — trace the actual code path from the candidate
   references outward. Reach for production evidence only when the code
   alone cannot settle the question.
4. **Classify every finding** — each one is either `CONFIRMED` (proven by
   code or by production evidence) or `THEORY` (plausible, unproven).
   Nothing is promoted for reading well.
5. **Write the INV** and update the TSK's Research Findings section.

## Example workflows

### Scenario: bug task with no known cause

```
/task-capture           # TSK describing the symptom
/task-investigate       # INV: what's actually happening, and what isn't
/task-plan              # plan built only on CONFIRMED findings
```

The normal path for any bug where the first question is "why", not "how".

### Scenario: the valid null result

```
/task-investigate
```

```
INV-…: 3 findings
  CONFIRMED  Reported timeout is client-side; server p99 is 240ms
  THEORY     Retry storm could amplify under load — not observed
  CONFIRMED  No defect found in the payment path
next_action: display_summary
```

**"No defect found" is a valid, expected outcome.** An investigation that
always finds a defect isn't investigating.

## Notes & gotchas

- Read the `CONFIRMED` / `THEORY` column before planning. A plan built on a
  `THEORY` is a plan built on sand — this classification is the entire
  point of the command.
- Production access is reported, not assumed. If your `CLAUDE.md` doesn't
  document how to reach an environment, the investigation stays code-only.
- Feeds `/task-design` and `/task-plan`. Run it before them, not after.
- **If it fails:** re-run with `--raw --full` to see the unformatted script
  output and confirm the task resolved.
