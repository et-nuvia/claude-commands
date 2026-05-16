---
command: project-context
group: project-config
backing_script: ~/.claude/scripts/project-context.sh
mutates: []
runtime: ~5-15s
destructive: false
requires_project_yaml: optional
project_yaml_fields:
  - stack.components
  - stack.languages
  - stack.frameworks
requires_project_knowledge: none
project_knowledge_sections: []
---

# /project-context

Generates a compact structural summary of the current project — services,
routes, frontend pages, and data models — and loads it into the LLM's context
for the session. Run it once at the start of implementation work so the model
never has to re-read `docker-compose.yml`, `main.py`, `router.py`, or
`App.tsx` for structural orientation.

---

## When to use it

- Starting a new implementation session and needing a codebase map
- A tool call re-reads a structural file for the third time — stop and run this instead
- Onboarding to an unfamiliar project before making changes

## Usage

```bash
/project-context [--section]
```

**Common invocations:**

```bash
/project-context                    # default: full summary (--full)
/project-context --services         # only Docker services and ports
/project-context --routes           # only API route definitions
/project-context --frontend         # only frontend pages and components
/project-context --models           # only data model class definitions
```

## Arguments

| Argument / Flag | Required | Description |
|---|---|---|
| `--full` | No | Full summary across all sections (default) |
| `--services` | No | Docker Compose services: names, ports, build paths |
| `--routes` | No | API routes: file, line number, endpoint path |
| `--frontend` | No | Frontend pages and components |
| `--models` | No | Data model class definitions |

## Dependencies

**External commands:**

| Dependency | Why it's needed | Install |
|---|---|---|
| `jq` | Build and consume the result JSON | `brew install jq` / `apt install jq` |
| `yq` | Parse docker-compose.yml and YAML configs | `brew install yq` |

**Project files consumed:**

- `PROJECT.yaml` (PY) — Optional. Helps identify stack and service paths when present.
- `docker-compose.yml` — parsed for service definitions
- Source files (`*.py`, `*.ts`, `*.tsx`, etc.) — scanned for routes and models

## Backing script

**Script**: `~/.claude/scripts/project-context.sh`

**Inputs:** section flag (`--full`, `--services`, `--routes`, `--frontend`,
`--models`). Reads from the current working directory.

**Outputs (structured JSON on stdout):**

- `next_action` ∈ {`display_summary`, `fix_error`}
- `context` — object with one or more sections:
  - `services[]` — `{name, ports[], build_path, image}`
  - `routes[]` — `{file, line, method, path, handler}`
  - `frontend[]` — `{page, path, components[]}`
  - `models[]` — `{name, file, line, fields[]}`

**Invocation surface:**

```bash
~/.claude/scripts/project-context.sh --full
~/.claude/scripts/project-context.sh --services
~/.claude/scripts/project-context.sh --routes
~/.claude/scripts/project-context.sh --frontend
~/.claude/scripts/project-context.sh --models
```

## How it works

1. **Scan** — script discovers source files based on common patterns and any
   stack hints from PROJECT.yaml. Scans docker-compose.yml for services,
   route decorator patterns for endpoints, class definitions for models, and
   file-system layout for frontend pages.
2. **Compile JSON** — structured data is assembled into the `context` object
   with file paths and line numbers for every entry.
3. **Display** — LLM renders the summary organized by section. The structured
   data is retained for the session so subsequent questions about "what port
   does the api service use?" can be answered from memory, not from re-reading
   files.

## Example workflows

### Scenario: Start of an implementation session

```
/project-context            # load structural map
/task-continue              # implement with full context in memory
```

Run once; the LLM holds the summary for the rest of the session.

### Scenario: Targeted lookup

```
/project-context --routes
```

Faster than `--full` when you only need the API surface before adding an
endpoint.

### Scenario: Full summary output

```
/project-context
```

```
Project: nuvia-api

Services (docker-compose.yml):
  api   → localhost:8000   build: ./backend
  db    → localhost:5432   image: postgres:16
  redis → localhost:6379   image: redis:7

Routes (backend/app/routers/):
  users.py:14   POST /users
  users.py:28   GET  /users/{id}
  auth.py:11    POST /auth/login
  …

Models (backend/app/models/):
  User    → models/user.py:8
  Session → models/session.py:6
  …
```

## Notes & gotchas

- Read-only — makes no changes to any file.
- Context is held in the LLM's session window; it is NOT written to disk. If
  the session is compacted or a new conversation starts, re-run the command.
- **Re-read budget**: if you find yourself re-reading `docker-compose.yml` or
  a router file for the third time in a session, run `/project-context` instead.
- **If it fails:** `fix_error` typically means no recognizable source files
  were found (wrong working directory) or `yq`/`jq` is not on PATH.
