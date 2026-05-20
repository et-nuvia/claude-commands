# Hooks

Claude Code [hooks](https://docs.claude.com/en/docs/claude-code/hooks) are
small shell scripts that fire on lifecycle events — before a tool runs,
after a notification arrives, when Claude stops. This repo ships two
hooks. Both are **opt-in**: the install script symlinks `hooks/` into
`~/.claude/hooks/`, but nothing is wired up until you add the matching
entry to `~/.claude/settings.json`.

> **Heads up.** Hooks run on your machine with your shell. Read the
> script before enabling and decide whether you trust what it does.

## The hooks at a glance

| Hook | Event | What it does | When to enable |
|---|---|---|---|
| [`allow-claude-scripts`](hooks-allow-claude-scripts) | `PreToolUse` (Bash) | Auto-approves any Bash command that calls a script under `~/.claude/scripts/`, regardless of quoting | You're tired of permission prompts for repo scripts and trust everything under `~/.claude/scripts/` |
| [`notify`](hooks-notify) | `Notification`, `Stop` | Cross-platform desktop notification + sound when Claude needs you or finishes a turn. Distinguishes "done" from "parked waiting on background work" | You step away from the terminal and want to know when Claude is back to you |

## Common setup

Both hooks expect to live at `~/.claude/hooks/<name>.sh` — that's where
`install.sh` puts them by symlinking the repo's `hooks/` directory.
Verify:

```bash
ls -la ~/.claude/hooks/
# should show allow-claude-scripts.sh and notify.sh as symlinks into
# this repo
```

To wire a hook up, edit `~/.claude/settings.json` (user-level, applies
to every project) — see each hook's page for the exact entry to add.

## Disabling a hook

Remove its entry from `~/.claude/settings.json`. The script file can
stay symlinked — without a `hooks` entry pointing at it, Claude Code
won't invoke it.

## Cross-references

- Per-hook details: [`allow-claude-scripts`](hooks-allow-claude-scripts),
  [`notify`](hooks-notify)
- Where they ship from:
  [`hooks/` in this repo](https://github.com/et-nuvia/claude-commands/tree/main/hooks)
- Claude Code hook reference:
  [docs.claude.com/.../hooks](https://docs.claude.com/en/docs/claude-code/hooks)
