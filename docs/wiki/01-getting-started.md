# Getting Started

## Prerequisites

- [Claude Code](https://claude.com/claude-code) installed
- `git`, `bash` 4+, `jq`, `yq`
- Optional but recommended: `gh` (for GitHub), `glab` (for GitLab), `uv` (Python), Docker
- A `~/.claude/` directory (created by Claude Code on first run)

## Install

```bash
git clone git@github.com:et-nuvia/claude-commands.git ~/projects/claude-commands
cd ~/projects/claude-commands
./install.sh
```

Verify symlinks were created:

```bash
ls -la ~/.claude/ | grep -- '->'
```

You should see `commands`, `scripts`, `skills`, `templates`, `docs`,
`profiles` all pointing into the repo.

## Create your profile

```bash
cp ~/.claude/profiles/default.yaml.example ~/.claude/profiles/active.yaml
$EDITOR ~/.claude/profiles/active.yaml
```

Fill in your identity, then configure at least one environment. See
[Customization](06-customization.md) for what each field does.

`active.yaml` is gitignored — your personal values never get committed.

## Verify

In Claude Code, type `/` and look for the commands from this repo (there are
~100). Try a low-risk one like `/project-context` in any project directory.

## Uninstall

```bash
cd ~/projects/claude-commands
./uninstall.sh
```

Removes only the symlinks. Your personal data in `~/.claude/` is preserved.
