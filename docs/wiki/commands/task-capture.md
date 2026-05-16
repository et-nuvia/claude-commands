---
command: task-capture
group: task-lifecycle
backing_script: ~/.claude/scripts/task-capture.sh
mutates: [files, asana, gitlab]
runtime: ~20-60s
destructive: false
requires_project_yaml: optional
project_yaml_fields:
  - task_management.backend
  - task_management.asana.workspace_id
  - task_management.asana.default_project
  - task_management.gitlab.project_id
  - git.repo
requires_project_knowledge: optional
project_knowledge_sections:
  - Domain workflows
  - Entity relationships
  - Service maps
  - Integration flows
  - Business rules
---

# /task-capture

Turns any task input — an Asana URL, a GitLab issue, an email, an SMS, or plain text — into a structured TSK document and optionally creates a matching record in the external tracker. Uses Opus for parsing to extract explicit requirements and infer implied ones. The result is a single document that `/task-start` and `/task-plan` can immediately consume.

> **Config:** PROJECT.yaml **optional** — reads `task_management.backend` (and matching subfields) to create external tracking records. Without it, only the local TSK document is written. PROJECT-KNOWLEDGE.md **optional** — reads domain workflows, entity relationships, service maps, integration flows, and business rules to improve task classification and requirement inference.

---

## When to use it

- Received a request via email, SMS, chat, or voice and need to log it as a formal task
- Pasting an Asana or GitLab URL to pull structured task data into a local TSK document
- Starting any new task — always capture before you start, even for small work

## Usage

```bash
/task-capture [input]
```

**Common invocations:**

```bash
/task-capture                              # paste or type input interactively
/task-capture #142                         # Asana GID or GitLab issue number
/task-capture https://app.asana.com/...    # Asana URL
/task-capture "Fix the null user crash when /me is called on first login"
```

## Arguments

| Argument / Flag | Required | Description |
|---|---|---|
| `$ARGUMENTS` | No | Free-form input: Asana/GitLab URL, issue number, email body, SMS text, or direct description. Prompted interactively when omitted. |

## Dependencies

**External commands / packages:**

| Dependency | Why it's needed | Install |
|---|---|---|
| `jq` | Parse script JSON responses | `brew install jq` / `apt install jq` |
| Asana MCP (work) | Fetch Asana task data and create new tasks | `mcp__asana__*` tools registered |
| `glab` (home) | Fetch and create GitLab issues | install per platform |

**Project files consumed:**

- `PROJECT.yaml` (PY) — Optional. Required fields when external sync is configured: `task_management.backend`, matching `task_management.asana.*` or `task_management.gitlab.*`
- `PROJECT-KNOWLEDGE.md` (PK) — Optional. Read at Step 0 to improve classification and requirement inference.
- `~/.asana-token` (work) or `~/.gitlab-token` (home) — required when backend is configured
- `~/.claude/templates/external-notes.md` — Asana description format template
- `docs/active/` — TSK document written here

## Backing script

**Script**: `~/.claude/scripts/task-capture.sh`

**Inputs:** `--detect --input <text>`, `--create-doc --title <title> --description <desc>`, `--sync-external --task-id <ID>`. Reads PROJECT.yaml for backend when present.

**Outputs (structured JSON):** `next_action` ∈ {`fetch_asana`, `fetch_gitlab`, `parse_content`, `write_document`, `skipped`, `needs_llm`, `fix_error`}, plus `task_id`, `filepath`, `template` when reserving a document path.

**Invocation surface:**

```bash
~/.claude/scripts/task-capture.sh --detect --input "${INPUT}"           # detect source type
~/.claude/scripts/task-capture.sh --parse --input "${INPUT}"            # parse content
~/.claude/scripts/task-capture.sh --create-doc --title "..." --description "..."  # reserve TSK path
~/.claude/scripts/task-capture.sh --sync-external --task-id "${TASK_ID}"          # check sync need
~/.claude/scripts/task-capture.sh --raw --detect --input "${INPUT}"     # debug: bypass formatting
```

## How it works

1. **Detect source** — script identifies the input type: Asana URL/GID, GitLab issue number, or free-form text. Returns `next_action` indicating how to proceed.
2. **Fetch content** — if source is Asana or GitLab, the LLM calls the relevant MCP/API to retrieve the full task details. Free-form input proceeds directly.
3. **Parse with Opus** — Opus analyzes the content to extract what, why, when, priority, type, and requirements (explicit and implied). Detects whether the task is `direct` (clear solution) or `investigation-driven` (needs research before implementation).
4. **Reserve TSK path** — script allocates a `task_id`, `filepath`, and `template` without writing the file yet.
5. **Create external record first** — if backend is configured, the LLM creates the Asana task or GitLab issue (capturing the GID/number) before writing the local file. This ensures the external ID is baked into the TSK on the single write, preventing orphaned local state.
6. **Write TSK document** — a single Write call fills the template with all parsed content and external tracking links. Investigation-driven tasks keep the Research Findings section with a placeholder; direct tasks remove it.
7. **Present summary** — reports task ID, title, priority, source, and file path. Suggests `/task-start <id>` as next step.

## Example workflows

### Scenario: From email to task

```
/task-capture [paste email body]
/task-start 142
/task-plan
```

Common for customer-reported issues or internal requests — capture preserves the original context, plan breaks it into implementable steps.

### Scenario: From Asana link

```
/task-capture https://app.asana.com/0/1234567890/9876543210
/task-start 143
```

Asana task is fetched, local TSK written with the Asana GID linked for bi-directional status sync.

### Scenario: Capture output

```
/task-capture "Add rate limiting to the API — customers are hammering /search"
```

```
✓ Task captured: A3F2B9 — Add rate limiting to /search endpoint
  Priority:  High (inferred from "hammering")
  Type:      Feature
  Source:    Direct text
  File:      docs/active/A3F2B9/A3F2B9-20260516-TSK-add-rate-limiting.md
  Asana:     Created (GID: 1207891234567890)

Next: /task-start A3F2B9
```

## Notes & gotchas

- **External sync is atomic**: the TSK is not written until the external record is created. If external sync fails, capture aborts rather than producing an orphaned local document.
- Investigation-driven tasks (type Research, unknown-cause bugs) produce a TSK with a Research Findings placeholder. The correct downstream flow is `/task-design` → `/task-plan` → `/task-continue` (Phase 1 = investigation).
- Opus is required for parsing — if you're running in a context where Opus isn't available, complex input may be under-parsed.
- **If it fails:** detection failures → debug with `~/.claude/scripts/task-capture.sh --raw --detect --input "${INPUT}"`. External sync failures → fix the MCP/token issue and retry `--sync-external`.
