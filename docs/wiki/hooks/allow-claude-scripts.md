# Hook: allow-claude-scripts

Auto-approves any Bash tool call whose command invokes a script under
`~/.claude/scripts/`, regardless of how Claude quotes the path.

- **Event:** `PreToolUse` matching `Bash`
- **Source:** [`hooks/allow-claude-scripts.sh`](https://github.com/et-nuvia/claude-commands/blob/main/hooks/allow-claude-scripts.sh)
- **Decision:** `allow` (returns the explicit `permissionDecision: allow`
  envelope) when the cleaned command matches; otherwise exit 0 with no
  output, falling through to your normal `permissions.allow` rules.

## Problem it solves

Claude's Bash tool prompt rules match on the literal command string.
When Claude wraps a path in quotes (`'~/.claude/scripts/foo.sh'` vs
`~/.claude/scripts/foo.sh`), or uses an absolute path
(`/Users/you/.claude/scripts/foo.sh`), the literal-prefix rules in
`settings.local.json` miss and you get a permission prompt for the
exact command you've already approved a dozen times.

This hook normalizes the command (strips quotes), checks for any
reference to `~/.claude/scripts/` or `/Users/<name>/.claude/scripts/`,
and auto-allows the call.

## When to enable it

Enable if **all** of the following are true:

- You use the commands from this repo regularly and the prompt churn
  is annoying.
- You trust every script under `~/.claude/scripts/` to run with your
  shell. (Reasonable since you installed them.)
- You're comfortable that any future script dropped into that
  directory will also be auto-approved without prompting.

Skip if you want a manual checkpoint before every script run.

## What gets matched

The hook strips single and double quotes from the command, then matches
either prefix at the start of the command or after a `;`, `&`, `|`, or
whitespace:

- `~/.claude/scripts/...`
- `/Users/<any-user>/.claude/scripts/...`

Pipelines and `&&` chains where the script is the first element of a
clause are covered. Calls embedded mid-string (e.g., a heredoc
containing the path as literal text) are not — and shouldn't be.

## Setup

1. Confirm the hook is symlinked:

   ```bash
   ls -la ~/.claude/hooks/allow-claude-scripts.sh
   ```

   If missing, run `./install.sh` from this repo.

2. Add the matcher to `~/.claude/settings.json`:

   ```json
   {
     "hooks": {
       "PreToolUse": [
         {
           "matcher": "Bash",
           "hooks": [
             {
               "type": "command",
               "command": "~/.claude/hooks/allow-claude-scripts.sh"
             }
           ]
         }
       ]
     }
   }
   ```

3. Restart Claude Code or start a new session. The hook is only loaded
   on session start.

## Verifying it works

Ask Claude to run any repo script (e.g., `~/.claude/scripts/get-version.sh`).
You should see the command run without a permission prompt. If you
still get prompted, check:

- `~/.claude/settings.json` syntax is valid JSON
- The hook file is executable (`chmod +x ~/.claude/hooks/allow-claude-scripts.sh`)
- Claude Code was restarted after the settings change

## Disabling

Remove the `PreToolUse` entry from `~/.claude/settings.json`. The
symlink can stay in place — without the matcher, the hook won't fire.

## Security notes

- The hook returns `permissionDecision: allow` for matches — this is
  Claude Code's explicit allow envelope, equivalent to clicking
  "Allow" on the prompt.
- It does not bypass any other safety mechanism. Non-Bash tools and
  non-script Bash commands fall through to your normal rules.
- Quote stripping is for matching only; the actual command Claude
  runs is the original, unmodified string.

## Cross-references

- Hooks landing page: [Hooks](09-hooks)
- Companion hook: [`notify`](hooks-notify)
- Claude Code hook reference:
  [docs.claude.com/.../hooks](https://docs.claude.com/en/docs/claude-code/hooks)
