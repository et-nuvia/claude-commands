# Hooks

Claude Code [hooks](https://docs.claude.com/en/docs/claude-code/hooks) are
small shell scripts that fire on lifecycle events — before a tool runs,
after a notification arrives, when Claude stops. This repo ships six
hooks. All are **opt-in**: the install script symlinks `hooks/` into
`~/.claude/hooks/`, but nothing is wired up until you add the matching
entry to `~/.claude/settings.json`.

> **Heads up.** Hooks run on your machine with your shell. Read the
> script before enabling and decide whether you trust what it does.

## The hooks at a glance

| Hook | Event | What it does | When to enable |
|---|---|---|---|
| [`allow-claude-scripts`](hooks-allow-claude-scripts) | `PreToolUse` (Bash) | Auto-approves any Bash command that calls a script under `~/.claude/scripts/`, regardless of quoting | You're tired of permission prompts for repo scripts and trust everything under `~/.claude/scripts/` |
| [`notify`](hooks-notify) | `Notification`, `Stop` | Cross-platform desktop notification + sound when Claude needs you or finishes a turn. Distinguishes "done" from "parked waiting on background work" | You step away from the terminal and want to know when Claude is back to you |
| `smart_approve` | `PreToolUse` (Bash) | Decomposes compound commands (`&&`, `\|\|`, `;`, `\|`, `$()`, newlines) into sub-commands and checks **each** against the allow/deny patterns in `settings.json` | A compound command whose every segment is individually allowed still prompts you, and you want that fixed properly rather than by widening a pattern |
| `context-guard` | `PostToolUse` (Read, Bash) | Warns on the 3rd read of the same file, and trims verbose *successful* Bash output | Long sessions where re-reads and tool output are quietly eating the context window |
| `scratchpad-hook` | `SessionStart` | Re-injects the one-line scratchpad manifest after compaction, so note *pointers* survive a context reset | You use the [scratchpad](11-skills-and-subagents) and want it to survive `/compact` |
| `track-command-hook` | command lifecycle | Records command invocations automatically, replacing the "call `track-command.sh` first and last" boilerplate every command doc used to carry | You want usage data for `/analyze-command-health` without paying two tool calls per command |

## Common setup

Every hook expects to live at `~/.claude/hooks/<name>.{sh,py}` — that's
where `install.sh` puts them by symlinking the repo's `hooks/` directory.
Verify:

```bash
ls -la ~/.claude/hooks/
# should show every shipped hook as a symlink into this repo
```

`smart_approve.py` is Python rather than shell; it takes the same kind of
`settings.json` entry, pointed at the `.py` file.

To wire a hook up, edit `~/.claude/settings.json` (user-level, applies
to every project) — see each hook's page for the exact entry to add.

## Disabling a hook

Remove its entry from `~/.claude/settings.json`. The script file can
stay symlinked — without a `hooks` entry pointing at it, Claude Code
won't invoke it.

## Cross-references

- Per-hook details: [`allow-claude-scripts`](hooks-allow-claude-scripts),
  [`notify`](hooks-notify). The four newer hooks
  (`smart_approve`, `context-guard`, `scratchpad-hook`,
  `track-command-hook`) don't have dedicated pages yet — read the header
  comment at the top of each script, which documents its dispatch and
  behaviour.
- Context-window habits the `context-guard` hook enforces:
  [Skills and Subagents](11-skills-and-subagents)
- Where they ship from:
  [`hooks/` in this repo](https://github.com/et-nuvia/claude-commands/tree/main/hooks)
- Claude Code hook reference:
  [docs.claude.com/.../hooks](https://docs.claude.com/en/docs/claude-code/hooks)
