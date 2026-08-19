---
name: understand-graph-ops
description: Operational detail for the Understand-Anything knowledge graph — .understand/graph.json commit policy, the watchlist, nightly auto-update cron, which commands auto-load the graph, and the hosted viewer. Load when configuring, troubleshooting, or opting a repo out of the understand graph or its viewer.
---

# Understand-Anything Graph — operations

`/understand-scan` writes a per-project knowledge graph to `<repo>/.understand/graph.json`.

## Commit policy

**`graph.json` is committed by default** (teammates reuse it, skipping the multi-minute paid scan); everything else under `.understand/` stays gitignored — enforced by global `~/.claude/.gitignore` (`.understand/*` + `!.understand/graph.json`).

Opt out per repo (e.g. proprietary code): add `/.understand/graph.json` to that repo's local `.gitignore`.

Which repos POST their graph to the hosted viewer is controlled by the watchlist `~/.claude/understand-watchlist.txt`, **not** any in-repo sentinel.

## Commands

- `/understand-scan` — build/refresh
- `/understand-explore` — read-only: `--search`, `--node`, `--tour`, `--for-task`, `--stats`
- `/understand-impact` — branch diff → affected nodes + downstream callers

## Auto-update

`scripts/understand-auto-update.sh` walks the watchlist nightly at 3am (installed via `scripts/install-understand-cron.sh`). It rescans on:

- schema_version mismatch
- missing `scanned_at`
- age > 30d
- > 20 commits
- > 10% files changed

Successful rescans POST to the viewer.

## Integration

12 commands auto-load the graph after their PK read — `task-design`, `task-plan`, `arch-explore`, `arch-grill`, `arch-interfaces`, `feature-review`, `feature-refactor`, `feature-performance`, `task-code-review`, `predict-issues`, `refactor`, `find-dead-code`. They skip silently when no graph is present.

## Viewer

`graph.json` is plain JSON and can be browsed with any graph viewer. If your team self-hosts one, put its URL in your profile rather than hardcoding it in commands.

**See**: [Understand Graph Schema](docs/reference/understand-graph-schema.md)
