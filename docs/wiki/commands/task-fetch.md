---
command: task-fetch
group: task-lifecycle
backing_script: ~/.claude/scripts/task-fetch.sh
mutates: []
runtime: ~5-15s
destructive: false
requires_project_yaml: required
project_yaml_fields:
  - task_management.backend
  - task_management.asana.workspace_id
  - task_management.asana.default_project
  - task_management.gitlab.project_id
requires_project_knowledge: none
project_knowledge_sections: []
---

# /task-fetch

Retrieves open tasks assigned to the current user from Asana or GitLab and presents a unified task list. Auto-detects the backend from PROJECT.yaml and credentials from the appropriate auth file. Use this to discover what to work on next before running `/task-start`.

> **Config:** PROJECT.yaml **required** — reads `task_management.backend`, plus either `task_management.asana.{workspace_id, default_project}` or `task_management.gitlab.project_id` depending on backend

---

## When to use it

- Start of a work session to see what's assigned to you
- After closing a task, to pick the next one
- To check which tasks are active across projects before starting something new

## Usage

```bash
/task-fetch [status] [project filter]
```

**Common invocations:**

```bash
/task-fetch                          # default: open tasks
/task-fetch --status all             # include closed tasks
/task-fetch --project "Engineering"  # filter by project name
```

## Arguments

| Argument / Flag | Required | Description |
|---|---|---|
| `--status <open\|closed\|all>` | No | Which tasks to return. Defaults to `open`. |
| `--project <name>` | No | Filter results to a named project. |
| `--format <text\|json\|markdown>` | No | Override output format. Default is auto-detected. |

## Dependencies

**External commands / packages:**

| Dependency | Why it's needed | Install |
|---|---|---|
| `jq` | Parse JSON response from script | `brew install jq` / `apt install jq` |
| Asana MCP (work) | Fetch tasks from Asana | `mcp__asana__*` tools registered |
| `glab` (home) | Fetch issues from GitLab | install per platform |

**Project files consumed:**

- `PROJECT.yaml` (PY) — Yes. Required: `task_management.backend` and either `task_management.asana.*` or `task_management.gitlab.*`
- `PROJECT-KNOWLEDGE.md` (PK) — No
- `~/.asana-token` (work) or `~/.gitlab-token` (home) — required for authentication

## Backing script

**Script**: `~/.claude/scripts/task-fetch.sh`

**Inputs:** `--full`, optional `--status <open|closed|all>`, `--project <name>`, `--format <text|json|markdown>`. Reads PROJECT.yaml for backend selection and auth token files.

**Outputs (structured JSON):** `next_action` ∈ {`display_summary`, `fix_error`}, plus `tasks[]` array with `id`, `title`, `due_date`, `project`, `status` per task.

**Invocation surface:**

```bash
~/.claude/scripts/task-fetch.sh --full                       # main
~/.claude/scripts/task-fetch.sh --full --status all
~/.claude/scripts/task-fetch.sh --full --project "Engineering"
~/.claude/scripts/task-fetch.sh --raw --full                 # debug: bypass formatting
```

## How it works

1. **Read config** — script reads PROJECT.yaml to determine backend (Asana or GitLab) and loads the matching auth token (`~/.asana-token` or `~/.gitlab-token`).
2. **Fetch tasks** — queries the backend for tasks assigned to the current user matching the status filter and optional project filter.
3. **Normalize** — results are mapped to a unified format regardless of backend, so the LLM response handling is identical on work and home.
4. **Return and display** — `next_action: display_summary` returns the task list; LLM presents task ID, title, due date, and project, then suggests `/task-start <id>` for any task.

## Example workflows

### Scenario: Start of day

```
/task-fetch           # see assigned tasks
/task-start 23        # start working on the top priority
```

Typical morning workflow — check assignments, then open a task environment.

### Scenario: List output

```
/task-fetch
```

```
Tasks assigned to you (3 open):

  ID     Title                           Due         Project
  ─────  ──────────────────────────────  ──────────  ──────────────
  #142   Add /me endpoint                2026-05-20  Backend
  #139   Fix null user crash             2026-05-17  Backend
  #131   Update API docs                 —           Engineering

Next: /task-start <id>
```

## Notes & gotchas

- Read-only — makes no changes to tasks, branches, or documents.
- On home (WSL), backend is typically GitLab; on work (macOS), Asana. The script auto-detects from PROJECT.yaml — no flag needed.
- **If it fails:** missing token → create `~/.asana-token` or `~/.gitlab-token` with a valid personal access token. Other errors: debug with `~/.claude/scripts/task-fetch.sh --raw --full` to see unformatted script output.
