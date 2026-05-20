# Hook: notify

Cross-platform desktop notification + sound when Claude needs your
attention or finishes a turn. Works on macOS, WSL with Windows
interop, and native Linux.

- **Events:** `Notification`, `Stop`
- **Source:** [`hooks/notify.sh`](https://github.com/et-nuvia/claude-commands/blob/main/hooks/notify.sh)
- **No decision:** the hook is informational — it emits a terminal
  bell, a system notification, and a sound, then exits 0.

## What it does, by event

| Event | When it fires | Title | Body | Sound (macOS / Windows) |
|---|---|---|---|---|
| `Notification` | Claude requests input (permission prompts, etc.) | `Claude Code: <project>` | The notification message (falls back to "Waiting for your input") | Glass / `Windows Notify System Generic.wav` |
| `Stop` — task completed | Claude finishes a turn with no pending background work | `Claude Code: <project>` | `Task completed` | Hero / `tada.wav` |
| `Stop` — parked | Claude's last assistant turn scheduled a wakeup or kicked off background work | `Claude Code: <project>` | `Waiting (scheduled wakeup)` or `Waiting (background work running)` | Tink / `Windows Notify.wav` |

`<project>` is the basename of the current working directory.

### The parked-vs-done distinction

The hook reads the JSONL transcript that Claude Code passes in, finds
the last assistant message, and looks for `ScheduleWakeup` or
`Bash`/`Agent` calls with `run_in_background: true`. If it finds
either, it labels the stop as **parked** and uses a softer sound —
because the conversation isn't really over.

This is useful when you've asked Claude to monitor a long-running
process: the gentle "tink" tells you it scheduled a check, the "hero"
fanfare tells you something is actually waiting on you.

## When to enable it

- You step away from the terminal and want a passive nudge when
  Claude needs you.
- You run Claude with background tasks (deploys, watching CI) and
  want to distinguish "done" from "still running, just paused."

Skip if you keep the terminal in the foreground or already have a
notification setup you like.

## Setup

1. Confirm the hook is symlinked:

   ```bash
   ls -la ~/.claude/hooks/notify.sh
   ```

   If missing, run `./install.sh` from this repo.

2. Add both event entries to `~/.claude/settings.json`. The hook
   takes the event type as its first argument so the same script
   handles both:

   ```json
   {
     "hooks": {
       "Notification": [
         {
           "hooks": [
             {
               "type": "command",
               "command": "~/.claude/hooks/notify.sh notification"
             }
           ]
         }
       ],
       "Stop": [
         {
           "hooks": [
             {
               "type": "command",
               "command": "~/.claude/hooks/notify.sh stop"
             }
           ]
         }
       ]
     }
   }
   ```

3. Restart Claude Code or start a new session.

## Platform notes

- **macOS:** uses `osascript` to call the native Notification Center.
  No extra dependencies. Sounds are the built-in system sounds (`Glass`,
  `Hero`, `Tink`).
- **WSL (Debian/Ubuntu):** detects WSL via `/proc/version`. Prefers
  `wsl-notify-send.exe` if installed; otherwise falls back to
  `powershell.exe` invoking BurntToast or a `MessageBox` shim. Sounds
  play via PowerShell's `SoundPlayer`.
- **Native Linux:** uses `notify-send` if installed (most desktops
  ship it via `libnotify-bin`). No sound on this path.
- **All platforms:** emits a `\a` (BEL) before anything else so
  terminal emulators that show a "bell" icon on the tab (e.g., VS Code)
  light up immediately.

## Optional dependencies

| Dependency | Used for | Required? |
|---|---|---|
| `jq` | Parsing the hook JSON envelope | Optional — falls back to `python3` |
| `python3` | Transcript parsing for parked-state detection | Required if you want the parked/done distinction |
| `wsl-notify-send.exe` | WSL → Windows notifications | Optional — `powershell.exe` is the fallback |
| `notify-send` | Native Linux notifications | Required for Linux notifications |

If `python3` is missing, every `Stop` is treated as "task completed" —
the parked-state detection just doesn't run.

## Verifying it works

Run any task that briefly waits for confirmation, or end a turn. You
should see:

- A system notification with the project name as the title
- A short sound matching the event
- The terminal tab/window indicator updating (VS Code shows a yellow
  bell)

If nothing fires, check:

- `~/.claude/settings.json` syntax is valid JSON
- The hook is executable: `chmod +x ~/.claude/hooks/notify.sh`
- The relevant binary is on PATH (`osascript`, `notify-send`,
  `powershell.exe`)

## Disabling

Remove the `Notification` and `Stop` entries from
`~/.claude/settings.json`. The symlink can stay in place.

## Cross-references

- Hooks landing page: [Hooks](09-hooks)
- Companion hook: [`allow-claude-scripts`](hooks-allow-claude-scripts)
- Claude Code hook reference:
  [docs.claude.com/.../hooks](https://docs.claude.com/en/docs/claude-code/hooks)
