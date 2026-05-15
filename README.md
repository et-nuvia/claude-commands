# claude-commands

A layered system of slash commands, helper scripts, templates, and reference
docs for [Claude Code](https://claude.com/claude-code). Drop-in install into
`~/.claude/` via symlinks — edit locally, `git pull` to get updates, PR to
contribute.

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
