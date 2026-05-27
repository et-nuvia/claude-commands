---
command: understand-scan
group: knowledge-graph
backing_script: ~/.claude/scripts/understand-scan.sh
mutates: [files]
runtime: ~3-15min
destructive: false
requires_project_yaml: none
project_yaml_fields: []
requires_project_knowledge: optional
project_knowledge_sections:
  - "(first ~2KB used as scanner excerpt)"
---

# /understand-scan

Builds or refreshes the per-project understanding graph at `.understand/graph.json` via a 4-stage subagent pipeline (project-scanner → file-analyzer → architecture-analyzer → assemble-reviewer). The script does deterministic file enumeration, hashing, and ajv schema validation; the LLM dispatches the subagent stages and feeds outputs back for validation and atomic write.

> **Config:** PROJECT-KNOWLEDGE.md **optional** — first ~2KB is passed to the project-scanner and file-analyzer subagents as architectural context.

---

## When to use it

- First time setting up the graph in a repo, before any `/understand-explore` or `/understand-impact` call
- After significant structural change (new service, large refactor, rename of layers)
- When `--stats` reports the graph is stale (> 30 days, > 20 commits, > 10% files changed)

## Usage

```bash
/understand-scan
```

**Common invocations:**

```bash
/understand-scan                 # default: full or incremental based on graph state
```

## Arguments

None — invoke with no input. Mode (full vs incremental) is chosen by the script based on whether `.understand/graph.json` already exists and validates.

## Dependencies

**External commands / packages** (must be on `PATH`):

| Dependency | Why it's needed | Install |
|---|---|---|
| `git` | Resolve `commit_sha` for the graph `meta` block | preinstalled |
| `jq` | Parse script JSON output | `brew install jq` / `apt install jq` |
| `ajv` (Node) | Schema-validate the assembled graph | `npm i -g ajv-cli` |
| `flock` | Single-writer lock on `.understand/scan.lock` | preinstalled on Linux; on macOS via `brew install flock` |

**Project files consumed:**

- `PROJECT.yaml` (PY) — No
- `PROJECT-KNOWLEDGE.md` (PK) — Optional. First ~2KB is passed to subagents as `project_knowledge_excerpt`.
- `.understand/config.json` — Optional. Keys: `cost_ceiling_usd` (default `5`), `max_file_size_kb`, `exclude_globs`.
- `~/.claude/schemas/understand-graph.schema.json` — Required. Single source of truth for the graph shape.
- `~/.claude/prompts/understand/understand-{project-scanner,file-analyzer,architecture-analyzer,assemble-reviewer}.md` — Required. The four subagent prompts.

## Backing script

**Script**: `~/.claude/scripts/understand-scan.sh`

**Inputs:** CLI stage flags; optional `--results-file <path>` for the assemble stage; reads `.understand/graph.json` (for incremental mode) and `.understand/config.json`.

**Outputs (structured JSON):**

- `--full` → `next_action: "dispatch_file_analyzers"`, `plan` (with `mode`, repo metadata)
- `--scan` / `--incremental` → `file_list[]` (path + hash + tier), `count`, `mode`
- `--assemble --results-file <path>` → `next_action` ∈ {`display_summary`, `retry_assemble`, `fix_error`}; on retry, `ajv_error`
- All modes return `status` and (on failure) `message`

**Invocation surface:**

```bash
~/.claude/scripts/understand-scan.sh --json --full                                 # entrypoint
~/.claude/scripts/understand-scan.sh --json --scan                                 # full enumeration
~/.claude/scripts/understand-scan.sh --json --incremental                          # diff vs prior file_hashes
~/.claude/scripts/understand-scan.sh --json --assemble --results-file <staging>    # validate + persist
~/.claude/scripts/understand-scan.sh --raw  --full                                 # debug: bypass formatting
~/.claude/scripts/understand-scan.sh --raw  --validate                             # validate-only against schema
```

## How it works

1. **Lock + plan (`--full`)** — acquires `flock` on `.understand/scan.lock` (refuses to run if another scan holds it), reads `.understand/config.json`, decides full vs incremental mode, returns the plan.
2. **Enumerate (`--scan` or `--incremental`)** — walks the repo, hashes files, classifies each into `tier1` / `tier2` / `tier3`. Incremental mode diffs against `meta.file_hashes` in the existing graph; if `count == 0`, the LLM stops and reports "no changes since last scan".
3. **Project scanner subagent** (1×, **model: sonnet**) — receives `cwd`, `commit_sha`, the PROJECT-KNOWLEDGE excerpt, and the `file_list`; returns `layers[]`, `file_roles[]`, `stack_notes`.
4. **File-analyzer subagents** (N×, **model: sonnet**, batches of 5-10) — one per `tier1`/`tier2` file, returning per-file `nodes[]` + `edges[]`. `tier3` files contribute hashes only.
5. **Architecture-analyzer subagent** (1×, **model: opus**) — folds all nodes/edges + scanner output into finalized `layers[]` (with colors) and `layer_overrides[]`.
6. **Assemble-reviewer subagent** (1×, **model: opus**) — emits one complete graph JSON document; LLM writes it to `.understand/graph.staging.json`.
7. **Validate + persist (`--assemble`)** — script runs ajv against `schemas/understand-graph.schema.json`. Success → atomically renames staging to `.understand/graph.json` and returns `display_summary`. Failure → returns `retry_assemble` with the `ajv_error`; LLM re-dispatches the assemble-reviewer with the error appended. **Retry budget: 2.**

## Example workflows

### Scenario: First scan of a new repo

```
/understand-scan        # build graph (~5-15min, runs subagent pipeline)
/understand-explore --stats
/understand-explore --search "auth"
```

### Scenario: Stale graph after refactor

```
/understand-explore --stats     # reports scanned_at > 30d, 18% files changed
/understand-scan                # incremental rescan
/understand-impact              # confirm refactor's blast radius is sane
```

```
Mode: incremental (24 files changed since last scan)
Project scanner: 7 layers, 24 files classified (18 tier1/2, 6 tier3)
File analyzers: 18 dispatched, 18 succeeded
Architecture analyzer: 7 layers finalized
Assemble reviewer: graph valid (142 nodes, 318 edges)
Written: .understand/graph.json
Cumulative cost: $0.84 / $5.00 ceiling
```

## Notes & gotchas

- **`.understand/graph.json` is committed by default**; the rest of `.understand/` (lock, config, staging) is gitignored. To opt a repo out of committing the graph, add `/.understand/graph.json` to that repo's local `.gitignore`.
- **Cost ceiling** is enforced from `.understand/config.json` (`cost_ceiling_usd`, default `$5`). The LLM aborts if cumulative cost would exceed it — raise the ceiling and rerun rather than splitting the scan.
- **Single-writer lock** — concurrent `/understand-scan` invocations refuse to start; the second one exits immediately.
- **Auto-update**: `scripts/understand-auto-update.sh` (installed via `scripts/install-understand-cron.sh`) walks `~/.claude/understand-watchlist.txt` nightly and rescans repos that cross the staleness threshold; successful rescans POST the graph to the hosted viewer.
- **If it fails:** check the lock (`ls -l .understand/scan.lock`), then debug with `~/.claude/scripts/understand-scan.sh --raw --full`. Schema-validation failures (`retry_assemble`) typically mean the assemble-reviewer emitted malformed JSON — inspect `.understand/graph.staging.json` after two retries.
