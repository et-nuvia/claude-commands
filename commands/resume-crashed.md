---
description: List Claude Code sessions that died without a clean exit (forced reboot, crash) and restore the ones you want
allowed-tools: Bash(~/.claude/scripts/session-registry.sh:*), AskUserQuestion
---

# Resume Crashed Sessions

Recover Claude Code sessions killed by a forced reboot or crash. A session that
exits cleanly fires SessionEnd and removes its own record, so anything still in
the registry died involuntarily.

## Step 1 — find the orphans

```bash
~/.claude/scripts/session-registry.sh list --json
```

This sweeps first (reclassifying any dead active record), then returns the
orphan list. Each orphan carries `session_id`, `name`, `cwd`, `project_root`,
`git_branch`, `died_reason`, `last_activity`, and `last_prompt`.

If `count` is 0, tell the user everything exited cleanly and stop.

## Step 2 — present them

Show a compact numbered list, most recently active first. For each: the session
name, the directory, the branch, how long ago it was active, and the last prompt
in quotes — the last prompt is what actually reminds the user what that session
was doing.

Skip any session whose `session_id` matches the current one.

## Step 3 — let the user choose

Use **AskUserQuestion** (multiSelect: true) listing each orphan as an option,
labeled with its name/branch and described with its last prompt. The user picks
which to bring back — do not restore any session they did not select.

If the user says "all", skip the question and restore every orphan.

## Step 4 — restore each selection

One call per selected session, using the number or session id from step 1:

```bash
~/.claude/scripts/session-registry.sh restore <n|session_id>
```

This opens (or focuses) the VS Code window for that project folder, opens a new
integrated terminal, and runs `claude --resume <session_id>` in the right cwd.
Restore them one at a time and report each result — the AppleScript drives the
focused window, so overlapping calls would land in the wrong place.

If a restore reports missing Accessibility permission, relay the exact
`cd ... && claude --resume ...` line so the user can paste it, and offer
`restore <n> --print` for the rest.

## Step 5 — offer cleanup

For orphans the user did not want back, offer:

```bash
~/.claude/scripts/session-registry.sh clear <n|session_id>   # one session
~/.claude/scripts/session-registry.sh clear --all            # every non-running session
```

Cleanup is rarely urgent: orphans are scoped to the boot that found them and
clear themselves on the next reboot, so there is no backlog to prune.

Restored sessions are removed from the registry automatically — they re-register
themselves on SessionStart.
