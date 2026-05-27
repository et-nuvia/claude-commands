# claude-commands

A layered system of slash commands, helper scripts, templates, and reference
docs for [Claude Code](https://claude.com/claude-code). Drop-in install into
`~/.claude/` via symlinks — edit locally, `git pull` to get updates, PR to
contribute.

## Recent improvements

- **Per-project knowledge graph.** A new family of `/understand-*` commands builds and queries a structural map of the codebase (`.understand/graph.json`) — search nodes, inspect a file's incoming/outgoing edges, get a dependency-ordered tour, or compute a branch's structural blast radius. Twelve existing commands (architecture, refactor, code review, planning, design) now auto-load the graph when present so their output cites real file paths and module boundaries instead of plausible-sounding guesses.
- **More consistent command surface.** Standardized tracking/completion blocks, output-format auto-detection (TOON for AI callers, JSON for CI), and a normalized authoring pattern across every command page — easier to skim, easier to extend.
- **Sharper code review.** The task-code-review flow now applies an explicit readability rubric (nesting depth, merged conditionals, extracted predicates, naming) alongside the existing correctness/security/perf/testing checks.
- **Safer task close.** External-merge claims are now verified by patch-id before downstream cleanup runs, and `--status` overrides behave consistently across every dispatch path.
- **Hardened review-pr & task-start.** Fewer false-positive secret hits, correctly URL-encoded GitLab project IDs, and a fix that prevents `origin/dev` from diverging when TSK/PLN commits land directly on the default branch.
- **Wiki coverage.** Every command — including the new `/understand-*` family — has a dedicated wiki page with frontmatter (`mutates`, `destructive`, `runtime`, required config) and a "Project files consumed" section so pre-flight questions are answerable without opening the script.

> ⚠️ **Cost note on `/understand-*`.** `/understand-scan` runs a 4-stage subagent pipeline (project scan → per-file analysis → architecture synthesis → assemble + validate) and can cost several dollars on a medium codebase — file-analyzer dispatches scale linearly with tier-1/2 file count. The cost ceiling is configurable in `.understand/config.json` (`cost_ceiling_usd`, default `$5`) and the run aborts before exceeding it. `/understand-explore` and `/understand-impact` are read-only and effectively free. `/understand` is the lightweight ad-hoc alternative when you don't want to commit a graph file.

## What's in here

| Tier | Directory | What it is |
|------|-----------|------------|
| 1. Commands | `commands/` | Slash command definitions (`.md`) — thin workflow descriptions |
| 1. Scripts | `scripts/` | Helper scripts the commands invoke — the actual logic |
| 1. Skills | `skills/` | Anthropic-format skill bundles |
| 2. Templates | `templates/` | `PROJECT.yaml`, `PROJECT-KNOWLEDGE.md`, task document templates, project scaffolds |
| 3. Docs | `docs/reference/` | Reference docs that commands link to at runtime (output standards, authoring guides, etc.) |
| 4. Profiles | `profiles/` | Environment-specific config (gitignored; you create your own) |

**This is a layered system, not 100 standalone commands.** Commands depend on
scripts, which depend on templates and profiles. Adopt the whole stack or
cherry-pick a coherent slice (e.g., the entire task lifecycle).

## Quickstart

```bash
git clone git@github.com:et-nuvia/claude-commands.git ~/projects/claude-commands
cd ~/projects/claude-commands
./install.sh

# Create your local profile
cp profiles/default.yaml.example profiles/active.yaml
$EDITOR profiles/active.yaml
```

`install.sh` symlinks `commands/`, `scripts/`, `skills/`, `templates/`,
`docs/`, and `profiles/` into `~/.claude/`. Your personal state in
`~/.claude/` (`projects/`, `memory/`, `settings.local.json`,
`.credentials.json`) is never touched.

## Updating

```bash
cd ~/projects/claude-commands
git pull
```

Symlinks mean updates take effect immediately — no re-install needed.

## Contributing

Edit files in this repo directly (your `~/.claude/` is symlinked to it).
Commit and PR against `main`.

See [`docs/wiki/07-contributing.md`](docs/wiki/07-contributing.md) for the
command/script authoring guides.

## Documentation

- [Getting started](docs/wiki/01-getting-started.md)
- [Mental model — commands, scripts, templates, docs](docs/wiki/02-mental-model.md)
- [PROJECT.yaml — the per-project contract](docs/wiki/03-project-yaml.md)
- [Command catalog](docs/wiki/04-command-catalog.md)
- [Customization — profiles and forks](docs/wiki/06-customization.md)
