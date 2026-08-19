---
name: scratchpad
description: Offload conversation detail to a durable, session-local scratchpad so it survives context compaction without staying resident. Use when you discover a fact/decision/error/path worth keeping but not worth spending tokens on every turn (e.g. "a file location found earlier", "an approach we rejected and why", "an exact error string"), or when the user says "jot this down", "note this for later", "remember this for this session", "scratchpad this". Also use to recall a note by id, list what's been noted, promote a note to the wiki, or prune old scratchpads.
---

# Scratchpad — Tiered Agent Memory

Session-local durable memory that sits between the live conversation and the wiki.
Implements `~/projects/wiki/decisions/wiki-backed-agent-memory.md`. Backed by
`~/.claude/scripts/scratchpad.sh` (JSON output). Notes live under
`~/.claude/scratchpad/<session-id>/`; a `SessionStart` hook re-injects the manifest of
one-line summaries after any compaction, so pointers survive and full bodies are recalled
on demand.

## When to use

Write a note the moment a detail is worth keeping but NOT worth carrying resident every turn:
- A file/symbol location discovered during exploration (`src/mw/compliance.ts:42`)
- An approach tried and rejected, with the reason
- An exact error string, config value, or command that worked
- Intermediate findings a later step will need but the summary would blur

Do **not** use it for durable cross-project facts (those go to `memory/`) or reusable
patterns (those graduate to the wiki via `promote`). Scratchpad = session-local working detail.

## Commands

Run bare and read the JSON. Session is auto-resolved (the SessionStart hook records it).

```bash
# Offload a detail — returns an id + the pointer to carry
~/.claude/scripts/scratchpad.sh write --summary "<one line>" [--tags "a,b"] [--body "<text>"]
~/.claude/scripts/scratchpad.sh write --summary "<one line>" --file <path>   # body from a file

~/.claude/scripts/scratchpad.sh list                 # manifest of {id, summary}
~/.claude/scripts/scratchpad.sh recall --id <id>     # pull one note's full body back
~/.claude/scripts/scratchpad.sh promote --id <id>    # graduate to wiki staging/
~/.claude/scripts/scratchpad.sh prune --dry-run      # see what cleanup would remove
```

## Workflow

1. **Offload:** when a detail qualifies, `write` it. Keep the returned one-line `summary` in
   your reply/working set; drop the verbose detail from resident context.
2. **Survive compaction:** nothing to do — the hook re-injects the manifest automatically.
3. **Recall:** when you need the detail again, `recall --id <id>`.
4. **Graduate:** if a note turns out to be a reusable cross-project truth, `promote` it to
   the wiki `staging/` (then review/promote via `scripts/wiki-staging.py`).

## Cleanup

Growth is bounded: 7-day TTL per session dir, 200 notes/session (LRU eviction), 50 session
dirs global cap. `prune` runs daily via cron; graduated/promoted notes have already left the
scratchpad, so cleanup never loses anything you chose to keep.
