# Contributing

## How edits flow

Your `~/.claude/` symlinks point into this repo, so editing locally *is*
editing the repo. To share a change:

```bash
cd ~/projects/claude-commands
git checkout -b feat/my-change
# (edit files in ~/.claude/ as usual — they're the same files)
git add -p
git commit -m "feat(commands): add /foo"
git push -u origin feat/my-change
gh pr create
```

## Authoring rules (short version)

- **Commands** (`commands/*.md`): ≤150 lines, ≤3 bash blocks, no `jq`/`case`
  logic. Describe a workflow; let the script do the work.
- **Scripts** (`scripts/*.sh`): `set -euo pipefail`, JSON output with a
  `next_action` directive, idempotent where possible.
- **No personal/org identifiers** — read them from the profile.

Full guides:
- `docs/reference/authoring/command-guide.md`
- `docs/reference/authoring/script-guide.md`

## What goes where

| Change | Location |
|---|---|
| New slash command | `commands/` + `scripts/` |
| New scaffold | `templates/<type>/` |
| New task doc type | `templates/task-XYZ.md` + update doc-types list |
| New environment field | `profiles/default.yaml.example` + `scripts/lib/` |
| Tweak output format | `docs/reference/ux/` |

## Commit conventions

Conventional Commits: `type(scope): description`. No `Co-Authored-By:`
trailers.

## Reviews

Small PRs (< 400 lines). One purpose per commit. If your change touches a
command *and* its script *and* its template, that can be one PR — that's a
single coherent change.
