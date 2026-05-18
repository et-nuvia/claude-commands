---
command: task-start
group: task-lifecycle
backing_script: ~/.claude/scripts/task-start.sh
mutates: [git, files, docker, asana, gitlab]
runtime: ~30-90s
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

# /task-start

> Part of the [Task Lifecycle workflow](../08-workflows.md#task-lifecycle).

Prepares the environment to begin work on a task: loads task context from
Asana or GitLab, creates an isolated worktree (or a plain branch), syncs the
external tracker to "In Progress", and boots Docker services + migrations +
dependencies. Detects and reopens on-hold or completed tasks instead of
starting fresh.

> **Config:** PROJECT.yaml **required** — reads `task_management.backend`, plus either `task_management.asana.{workspace_id, default_project}` or `task_management.gitlab.project_id` depending on backend

---

## When to use it

- You picked a task from `/task-fetch` and want to start working
- You're resuming an on-hold task with a saved branch
- You want a clean worktree so the main checkout stays on `main`

## Usage

```bash
/task-start <TASK_ID>
```

**Common invocations:**

```bash
/task-start 23                                # default: worktree mode
/task-start 23 --no-worktree                  # plain branch on the main checkout
/task-start 23 --base-branch develop          # branch from develop, not main
```

## Arguments

| Argument / Flag | Required | Description |
|---|---|---|
| `TASK_ID` | Yes | Numeric ID matching a captured TSK doc |
| `--no-worktree` | No | Use a plain branch instead of `.worktrees/<task_id>` |
| `--base-branch <name>` | No | Branch from a non-default base. Prompted interactively when ambiguous. |

## Dependencies

**External commands:**

| Dependency | Why it's needed | Install |
|---|---|---|
| `git` (≥ 2.30) | Branch / worktree creation, pull | preinstalled |
| `docker` + `docker compose` (V2) | Boots dev services + DB | Docker Desktop / Engine |
| `jq` | Parse task metadata + script responses | `brew install jq` / `apt install jq` |
| Asana MCP (work) | Sync status to "In Progress" | `mcp__asana__*` tools registered |
| `gh` or `glab` | Fetch task context from issues | `brew install gh` / install `glab` |

**Project files consumed:**

- `PROJECT.yaml` (PY) — Yes. Required: `task_management.backend` and either
  `task_management.asana.*` or `task_management.gitlab.*`
- `PROJECT-KNOWLEDGE.md` (PK) — No
- `~/.asana-token` (work) or `~/.gitlab-token` (home) — required for tracker sync
- `.current-task` — written here; read by `/task-continue`, `/task-close`
- `.worktrees/` — created here; gitignored globally

## Backing script

**Script**: `~/.claude/scripts/task-start.sh`

**Inputs:** `--task-id <ID>`, optional `--no-worktree`,
`--base-branch <name>`. Reads PROJECT.yaml + auth tokens.

**Outputs (structured JSON):** `next_action` ∈ {`sync_external`,
`display_summary`, `confirm_action`, `fix_error`}, plus `asana_gid`,
`branch`, `worktree_path`, `worktree_mode`, `task_reopened`,
`assessment.recommendation` (`ready` | `needs_plan` | `needs_design`).

**Invocation surface:**

```bash
~/.claude/scripts/task-start.sh --full --task-id <ID>                 # main
~/.claude/scripts/task-start.sh --full --no-worktree --task-id <ID>
~/.claude/scripts/task-start.sh --setup-env --task-id <ID>            # resume after Asana sync
~/.claude/scripts/task-start.sh --resume-branch --task-id <ID>        # on-hold resume
~/.claude/scripts/task-start.sh --raw --<section> --task-id <ID>      # debug
```

Section flags for targeted resumption: `--identify`, `--verify`,
`--update-repo`, `--create-branch`, `--setup-env`, `--link-task`.

## How it works

1. **Identify** — load task metadata; detect on-hold tasks with preserved branches.
2. **Verify** — confirm the working tree is clean. Tracked-file modifications
   block; untracked files (e.g., a TSK doc you just wrote) do not.
3. **Update repo** — pull the latest from the default branch.
4. **Create branch / worktree** — worktree mode creates `.worktrees/<task_id>`
   and `cd`s into it; `--no-worktree` creates a normal branch. Writes
   `.current-task`.
5. **External sync gate** — if Asana sync is required, script returns
   `sync_external` and the LLM flips Asana **before** Docker boots. Saves a
   minute of env startup on misconfigured tasks.
6. **Setup env** — Docker services up, migrations run, deps install.
7. **Assess and route** — based on what docs exist, recommend the next
   command: `/task-plan`, `/task-design`, or `/task-continue`.

## Example workflows

### Scenario: Fresh task, full lifecycle

```
/task-capture #142          # capture → TSK doc
/task-start 142             # branch + env + Asana sync
/task-plan                  # build PLN doc
/task-continue              # implement
/git-commit                 # commit
/task-close                 # ship
```

### Scenario: Parallel tasks via worktrees

```
/task-start 100             # creates .worktrees/100
# manual: cd back to main repo, work on something else
/task-start 101             # creates .worktrees/101
```

Both tasks coexist without branch switching.

### Scenario: Display summary output

```
/task-start 142
```

```
✓ Task 142 started: "Add /me endpoint"
  Branch:   feat/142-me-endpoint
  Worktree: .worktrees/142
  Asana:    In Progress
  Docker:   api, db, redis healthy
  Deps:     installed (uv sync, 0 changes)

Switched into worktree at .worktrees/142. All subsequent commands run from here.

Task readiness: needs_plan
Next: /task-plan
```

## Notes & gotchas

- **Worktree `cd` does NOT persist across Bash tool calls.** After
  `display_summary`, every subsequent Bash invocation must `cd
  .worktrees/<task_id>` first or use absolute paths. Silent footgun: edits
  and commits otherwise land on the parent branch.
- Untracked files don't block — only tracked-file modifications do.
- Asana sync runs **before** env boot intentionally. If Asana is misconfigured,
  nothing has been booted and the local branch is safe.
- **If it fails:** uncommitted changes → stash or commit, rerun `--full`
  (idempotent). Other errors: debug with `~/.claude/scripts/task-start.sh
  --raw --<section> --task-id <ID>`.
