---
name: understand-impact
description: Map the current branch's diff to affected graph nodes and downstream callers via reverse-edge walk on .understand/graph.json.
user_invocable: true
---

You are the executor for `/understand-impact`. The script is **read-only** — it inspects the git diff and the graph but never writes anything.

## Tracking

> Output format is auto-detected (TOON for AI callers, JSON for CI/scripts). Use `--toon` or `--json` to override.

As your **first action**, before any other work, run:
```bash
~/.claude/scripts/track-command.sh --command "understand-impact" --event start
```

If the workflow encounters an unrecoverable error at any point, run:
```bash
~/.claude/scripts/track-command.sh --command "understand-impact" --event error \
  --model "MODEL_ID" \
  --error-msg "brief description of what failed"
```

## Execute

```bash
# Default: diff current branch vs auto-detected base (dev/develop/main/master), 2 reverse-edge hops
RESULT=$(~/.claude/scripts/understand-impact.sh --json --full)

# Override the comparison base
RESULT=$(~/.claude/scripts/understand-impact.sh --json --full --base main)

# Walk deeper (more downstream context, more noise)
RESULT=$(~/.claude/scripts/understand-impact.sh --json --full --hops 3)

# Point at a graph elsewhere
RESULT=$(~/.claude/scripts/understand-impact.sh --json --full --graph-file /path/to/other/.understand/graph.json)
```

## Response Handling

The script returns one of three shapes:

**`status: success` with non-empty `changed_nodes[]`** — Diff intersects the graph.
- `changed_nodes[]` — graph nodes whose file is in the diff (changed file + all symbol nodes in it)
- `affected_nodes[]` — nodes reachable from changed via reverse-edges (incoming, any kind), within `--hops`
- `layer_crossings` — distinct (changed_layer → affected_layer) pairs where the layer differs; a proxy for "this PR touches things across architectural boundaries"
- `blast_radius_score` — `len(affected_nodes) + 2 * layer_crossings`; the doubled weight reflects that cross-layer ripples cost more attention to verify
- Present these as a summary, then list the highest-blast-radius affected nodes first. Quote node ids verbatim so the user can `/understand-explore --node <id>` to drill in.

**`status: success` with empty arrays + `message: "no changes detected"`** — Clean tree, no commits ahead. Tell the user the working tree is clean relative to the base.

**`status: success` with empty arrays + `message: "no graph nodes match changed files"`** — Diff exists but no changed file appears in the graph. Common causes: rescan is stale, or the changes are in files the scan deprioritized (vendored, generated, configs). Mention both possibilities.

**`status: error`** — Missing `.understand/graph.json`, unknown flag, or invalid `--hops`. Surface the `message` and the suggested `action` verbatim.

## When to use this

- Before opening a PR: "what's the downstream blast radius of my changes?"
- During code review: "what should I re-test that isn't in the diff?"
- During design: "if I touch X, what else am I implicitly touching?"

This pairs with `/understand-explore --node <id>` for drilling into any specific affected node.

## Debug

```bash
~/.claude/scripts/understand-impact.sh --raw --full
```

## Completion Tracking

When the workflow completes successfully, run:
```bash
~/.claude/scripts/track-command.sh --command "understand-impact" --event complete \
  --model "MODEL_ID" \
  --complexity COMPLEXITY \
  --tokens TOKENS_ESTIMATED \
  --cost COST_ESTIMATED
```

Replace values before calling:
- `MODEL_ID` — the model currently in use (from system context, e.g., `claude-sonnet-4-6`)
- `COMPLEXITY` — 1-5 based on: 1=read-only analysis, 2=single-file/simple git, 3=multi-file feature,
  4=cross-system/staging deploy, 5=production/infrastructure/security
- `TOKENS_ESTIMATED` — rough estimate of context used (input + output tokens combined)
- `COST_ESTIMATED` — approximate cost in USD based on model pricing
