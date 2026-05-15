# Task Management Adapters

This directory holds adapter shims for task-tracking backends (Asana,
GitLab Issues, GitHub Issues, and any future provider). Scripts that
need to read, list, create, comment on, or close tasks source
`scripts/lib/task-api.sh`, which dispatches to the adapter matching
`profile_env_get .task_management.backend` (with PROJECT.yaml override).

Same pattern as the git platform shims (`../git-platforms/`) and the
secrets manager shims (`../secrets-backends/`). Adding a new backend =
one new file in this directory + one case branch in the dispatcher.

## Usage from a calling script

```bash
source "${SCRIPT_DIR}/lib/task-api.sh"
load_task_adapter || exit 1

# Now the task_* functions are defined. Same call works for any backend.
task=$(task_get 42)
task_hold 42 "waiting on external review" "vendor"
```

## Asana special case (read this!)

Asana operations from **inside a Claude session** typically use MCP
tools (`mcp__asana__get_task`, etc.) — Claude has those directly
available. This adapter exists for **script-driven** code paths
(cron, CI, automation) where MCP isn't available. It uses Asana's
REST API at `https://app.asana.com/api/1.0/` with a personal access
token from `~/.asana-token`.

If you're writing code that will only run inside Claude sessions, you
can still use the MCP tools directly — the adapter is optional. If
your code might also run from a script context, prefer the adapter
so it works in both.

## Contract

Every adapter MUST implement every function below. All functions return
data on stdout when they have data, errors on stderr, and one of these
exit codes:

| Code | Meaning |
|---|---|
| `0` | Success |
| `1` | Error (network, auth, validation, unexpected state) |
| `2` | Not found (the requested task doesn't exist) |
| `3` | **Reserved.** Future contract additions not yet implemented on every adapter. |

### Read

| Function | Args | Returns |
|---|---|---|
| `task_get` | `<id>` | Normalized JSON (schema below) |
| `task_list` | `[--state open\|closed\|all] [--assignee me\|<user>]` | JSON array of normalized tasks |
| `task_search` | `<query>` | JSON array of normalized tasks |
| `task_url` | `<id>` | Web URL of the task |
| `task_health` | — | exit 0 if auth + network OK; exit 1 with stderr details |

### Write

| Function | Args | Returns |
|---|---|---|
| `task_create` | `<title> <body> [section]` | JSON `{id, url}` of new task |
| `task_update` | `<id> <field> <value>` | empty on success. Fields: `title`, `body`, `assignee`. Other fields adapter-specific. |
| `task_close` | `<id> [comment]` | empty on success |
| `task_hold` | `<id> <reason> <waiting_on>` | empty on success. Translates to label/section/custom-field by backend. |
| `task_resume` | `<id> [comment]` | empty on success. Reopens a closed task or un-holds a held one. |
| `task_comment` | `<id> <body>` | empty on success |

## Normalized task schema

All read functions return data in this shape. Backend-specific fields
live under `.raw`.

```json
{
  "id": "<backend-native id>",
  "title": "...",
  "status": "open|in_progress|on_hold|closed",
  "assignee": "<username or null>",
  "created_at": "<ISO-8601>",
  "updated_at": "<ISO-8601>",
  "url": "https://...",
  "raw": { /* backend-native fields, including platform-specific
              concepts like sections, milestones, custom_fields */ }
}
```

### Status mapping

| Adapter | Open | In Progress | On Hold | Closed |
|---|---|---|---|---|
| asana | not `completed` | section "In Progress" | label/section "On Hold" | `completed: true` |
| gitlab-tasks | state `opened`, no `in-progress` label | label `in-progress` | label `on-hold` | state `closed` |
| github-tasks | state `OPEN`, no `in-progress` label | label `in-progress` | label `on-hold` | state `CLOSED` |
| none | always `closed` | — | — | — |

Use the normalized values in your code. The raw value is always
available under `.raw.state` (or whatever the backend calls it) if you
need to branch on backend-specific states.

## Adding a new adapter (e.g., Linear)

1. Copy `gitlab-tasks.sh` as `<backend>.sh` — its REST+curl pattern is
   closer to most task-tracking APIs than the Asana adapter.
2. Implement every function in the contract. Map the platform's task
   model to the normalized schema. Be honest about gaps (return exit 3
   with a stderr message instead of pretending an operation worked).
3. Add a case branch to `load_task_adapter()` in `../task-api.sh`.
4. Add the `<backend>` value as a valid choice in
   `profiles/default.yaml.example` under
   `task_management.backend`.

## Special case: `none`

For users who don't track tasks externally, set
`task_management.backend: none` in the profile or PROJECT.yaml. The
dispatcher loads `none.sh`, which provides no-op stubs:

- Read functions return empty `[]` / exit 2
- Write functions return exit 3 (unsupported)
- `task_health` returns 0 — nothing to check

This lets scripts call `task_health` etc. without branching on backend
presence.

## Testing an adapter

```bash
# Force a specific adapter regardless of profile
TASK_ADAPTER_OVERRIDE=gitlab-tasks source scripts/lib/task-api.sh
load_task_adapter
task_health && echo OK || echo FAIL
```

## Relationship to git platform shims

Git issues are a kind of task, so there's natural overlap with
`git-platforms/gitlab.sh` / `github.sh` (which expose `git_issue_*`).
The task adapters reuse the low-level helpers from those files
(`gitlab_api`, `_gh`, `_gh_get`) — they don't duplicate the auth /
HTTP logic. What they ADD on top is task-lifecycle-specific
operations: `task_hold`, `task_resume`, status normalization across
backends, the normalized schema.

If a script only needs raw issue operations (close, comment), it can
keep using `git_issue_*` from the git-platforms shim. If it needs
backend-portable task lifecycle (which is most of what the V4 task
system does), use `task_*` here.
