---
command: understand-explore
group: knowledge-graph
backing_script: ~/.claude/scripts/understand-explore.sh
mutates: []
runtime: ~1s
destructive: false
requires_project_yaml: none
project_yaml_fields: []
requires_project_knowledge: none
project_knowledge_sections: []
---

# /understand-explore

Read-only queries over `.understand/graph.json` via five subcommands — `--search`, `--node`, `--tour`, `--for-task`, `--stats`. The script never writes; it locates the graph at the repo root, schema-validates it, and returns ranked results for the LLM to summarize.

> **Config:** none. Requires that `/understand-scan` has been run at least once so `.understand/graph.json` exists.

---

## When to use it

- Quickly locate a graph node by keyword (`--search "router middleware"`) before reading code
- Inspect one node's incoming/outgoing edges to understand how a file is wired (`--node`)
- Get a dependency-ordered tour of the codebase for onboarding (`--tour`)
- Ask "which files matter for task TSK-NNN?" (`--for-task`)
- Check graph freshness and layer distribution (`--stats`)

## Usage

```bash
/understand-explore --<subcommand> [args]
```

**Common invocations:**

```bash
/understand-explore --search "auth middleware"     # ranked keyword match
/understand-explore --node src/api/router.py       # node + 1-hop neighbors
/understand-explore --tour --limit 20              # leaves-first walk
/understand-explore --for-task 293A14              # nodes ranked by overlap with task docs
/understand-explore --stats                        # metadata, counts, staleness
```

## Arguments

| Argument / Flag | Required | Description |
|---|---|---|
| `--search <query>` | one-of | Ranked match against node `id`, `name`, `summary` |
| `--node <id>` | one-of | Look up a single node by id; returns 1-hop neighbors |
| `--tour` | one-of | Dependency-ordered walk (leaves first) |
| `--for-task <task_id>` | one-of | Rank nodes by keyword overlap with the task's TSK/PLN docs |
| `--stats` | one-of | Graph metadata, counts, layer distribution, `scanned_at` |
| `--limit <N>` | No | Caps `--tour` and `--for-task` result count |
| `--graph-file <path>` | No | Override default `.understand/graph.json` location |

## Dependencies

**External commands / packages** (must be on `PATH`):

| Dependency | Why it's needed | Install |
|---|---|---|
| `jq` | Parse script JSON output | `brew install jq` / `apt install jq` |

**Project files consumed:**

- `.understand/graph.json` — Required. Produced by `/understand-scan`.
- `~/.claude/schemas/understand-graph.schema.json` — Required for the script's internal schema-version check.

## Backing script

**Script**: `~/.claude/scripts/understand-explore.sh`

**Inputs:** one of `--search` / `--node` / `--tour` / `--for-task` / `--stats`; optional `--limit`, `--graph-file`.

**Outputs (structured JSON):** every response has `status` ∈ {`success`, `error`} and a subcommand-specific payload:

- `--search` → `results[]` of `{id, name, summary, score}`
- `--node` → `node`, `incoming_edges[]`, `outgoing_edges[]`
- `--tour` → ordered `nodes[]`, `truncated_at`
- `--for-task` → ranked `nodes[]` with `overlap_score`, plus `message` when no task docs found
- `--stats` → `node_count`, `edge_count`, `layer_count`, `scanned_at`, `layer_distribution`
- `error` → `message`, suggested `action`

**Invocation surface:**

```bash
~/.claude/scripts/understand-explore.sh --json --search "<query>"
~/.claude/scripts/understand-explore.sh --json --node "<id>"
~/.claude/scripts/understand-explore.sh --json --tour --limit 20
~/.claude/scripts/understand-explore.sh --json --for-task <TASK_ID>
~/.claude/scripts/understand-explore.sh --json --stats
~/.claude/scripts/understand-explore.sh --raw  --stats          # debug
```

## How it works

1. **Locate graph** — script walks up from `cwd` to find `.understand/graph.json`; errors with `action: "run /understand-scan"` if missing.
2. **Schema-version check** — confirms `meta.schema_version` matches the script's expected version; on mismatch, errors with `action: "re-run /understand-scan"`.
3. **Dispatch subcommand** — pure JSON read/filter; for `--for-task`, reads matching `TSK-*`/`PLN-*` docs from `docs/active/` and `docs/completed/` to build the keyword set.
4. **Return ranked JSON** — the LLM summarizes for the user. Node ids are quoted verbatim so the user can drill in via `/understand-explore --node <id>`.

## Example workflows

### Scenario: Find a node, drill in

```
/understand-explore --search "router middleware"
/understand-explore --node src/api/router.py
```

### Scenario: Task-focused exploration

```
/understand-explore --for-task 293A14
/understand-explore --node <top-hit>
```

```
Task 293A14 — top 5 matched nodes:
1. src/intake/parser.py            score 0.74
2. src/intake/validator.py         score 0.62
3. src/api/router.py:handle_order  score 0.51
4. tests/intake/test_parser.py     score 0.44
5. src/notify/email.py             score 0.31

Graph scanned: 2026-05-19 (3 days ago, current)
```

## Notes & gotchas

- **Read-only** — safe to run any number of times; no lock, no writes.
- **Stale graphs** — `--stats` reports `scanned_at`. If older than 30 days, rerun `/understand-scan`; otherwise `--for-task` and `--search` may miss recently added code.
- **`--for-task` requires task docs** — if neither `docs/active/<TASK_ID>-*.md` nor `docs/completed/<TASK_ID>-*.md` exist, the script returns success with an empty result set and a `message` field; the LLM surfaces that.
- **If it fails:** the most common cause is "graph not found" — run `/understand-scan` first. Debug with `~/.claude/scripts/understand-explore.sh --raw --stats`.
