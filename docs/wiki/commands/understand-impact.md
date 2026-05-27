---
command: understand-impact
group: knowledge-graph
backing_script: ~/.claude/scripts/understand-impact.sh
mutates: []
runtime: ~1-3s
destructive: false
requires_project_yaml: none
project_yaml_fields: []
requires_project_knowledge: none
project_knowledge_sections: []
---

# /understand-impact

Maps the current branch's `git diff` against `.understand/graph.json` and walks reverse edges to surface affected callers — a structural blast-radius read of "what does this PR touch, beyond the changed files." Read-only; never writes.

> **Config:** none. Requires that `/understand-scan` has been run at least once so `.understand/graph.json` exists.

---

## When to use it

- Before opening a PR: "what's the downstream blast radius of my changes?"
- During code review: "what should I re-test that isn't in the diff?"
- During design: "if I touch X, what else am I implicitly touching?"

## Usage

```bash
/understand-impact
```

**Common invocations:**

```bash
/understand-impact                          # diff vs auto-detected base, 2 hops
/understand-impact --base main              # override comparison base
/understand-impact --hops 3                 # walk deeper (more context, more noise)
/understand-impact --graph-file <path>      # point at a graph elsewhere
```

## Arguments

| Argument / Flag | Required | Description |
|---|---|---|
| `--base <ref>` | No | Comparison base. Default: first of `dev`, `develop`, `main`, `master` that exists. |
| `--hops <N>` | No | Reverse-edge walk depth. Default `2`. |
| `--graph-file <path>` | No | Override default `.understand/graph.json` location. |

## Dependencies

**External commands / packages** (must be on `PATH`):

| Dependency | Why it's needed | Install |
|---|---|---|
| `git` | Compute diff vs base | preinstalled |
| `jq` | Parse script JSON output | `brew install jq` / `apt install jq` |

**Project files consumed:**

- `.understand/graph.json` — Required. Produced by `/understand-scan`.

## Backing script

**Script**: `~/.claude/scripts/understand-impact.sh`

**Inputs:** `--full` (entrypoint), optional `--base`, `--hops`, `--graph-file`.

**Outputs (structured JSON):** always returns `status` ∈ {`success`, `error`}.

- success with hits → `changed_nodes[]`, `affected_nodes[]`, `layer_crossings`, `blast_radius_score`
- success, clean tree → empty arrays, `message: "no changes detected"`
- success, no overlap → empty arrays, `message: "no graph nodes match changed files"`
- error → `message`, `action`

**Score formula:** `blast_radius_score = len(affected_nodes) + 2 * layer_crossings`. The doubled weight reflects that cross-layer ripples cost more attention to verify than same-layer ones.

**Invocation surface:**

```bash
~/.claude/scripts/understand-impact.sh --json --full
~/.claude/scripts/understand-impact.sh --json --full --base main
~/.claude/scripts/understand-impact.sh --json --full --hops 3
~/.claude/scripts/understand-impact.sh --raw  --full        # debug
```

## How it works

1. **Resolve base** — picks `--base` or auto-detects (`dev`/`develop`/`main`/`master`).
2. **Compute diff** — `git diff --name-only <base>...HEAD` → changed file list.
3. **Match to graph** — collects every node whose file is in the diff (file nodes + all symbol nodes inside them) → `changed_nodes[]`.
4. **Reverse-edge walk** — BFS over incoming edges up to `--hops` deep → `affected_nodes[]`. Edge kind is ignored (calls, imports, references all count).
5. **Score** — counts distinct `(changed_layer → affected_layer)` pairs where the layer differs (`layer_crossings`), then computes `blast_radius_score`.
6. **Return** — LLM presents the score, sorts affected nodes by blast radius (highest first), and quotes node ids verbatim so the user can drill in with `/understand-explore --node <id>`.

## Example workflows

### Scenario: Pre-PR sanity check

```
/understand-impact
/understand-explore --node <top-affected-node>
/create-pr
```

```
Diff vs main: 7 files changed
Changed nodes: 12   Affected (2 hops): 38   Layer crossings: 3
Blast-radius score: 44

Top affected (cross-layer, re-test these):
  - src/api/router.py:dispatch_order
  - src/notify/email.py:send_order_confirmation
  - tests/integration/test_intake_flow.py
  …
```

### Scenario: Clean tree

```
/understand-impact
```

```
Working tree clean relative to dev. No graph impact to report.
```

## Notes & gotchas

- **Read-only** — safe to rerun. No lock, no writes.
- **Reverse edges include all kinds** (`calls`, `imports`, `references`). If you want only one kind, this command isn't it — use `/understand-explore --node` and read edges manually.
- **`--hops 3` adds noise** — at 3 hops in a typical graph you'll see a sizeable fraction of the codebase. Default `2` is the right starting point.
- **Stale graphs distort the score** — if files were added since the last scan, the diff will hit "no graph nodes match changed files" or undercount. Rerun `/understand-scan` when `--stats` shows the graph is stale.
- **If it fails:** "graph not found" → run `/understand-scan`. "base ref missing" → pass `--base <ref>` explicitly. Debug with `~/.claude/scripts/understand-impact.sh --raw --full`.
