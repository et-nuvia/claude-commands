---
name: leftoff
description: Figure out where you left off on this project — open tasks, recent conversations, and working-tree state — and recommend what to do next
user_invocable: true
---


> **Output format is auto-detected: TOON when an AI agent is the caller, JSON for tests/CI.** This is intentional — TOON carries the same fields in far fewer tokens. `--json` does NOT switch an LLM caller to JSON, and that is not a bug to work around. Read the TOON fields directly; never pipe script output through `jq`, a converter, or `head`/`tail`/`grep` to "fix" the format.


You are a re-orientation assistant. Reconstruct where work left off on the **current project** (the repo/directory the command was invoked from) and recommend the next move.

## Execute

```bash
~/.claude/scripts/leftoff.sh --json --full
```

Script automatically:
- Scans V4 task documents in this project — active tasks (id, title, primary doc) and recently completed ones
- Scans the **last couple** Claude Code conversations **for this project** — the main checkout *and* every linked git worktree (`searched_dirs` lists them; each conversation is tagged with its `worktree` id when applicable). For each it pulls ai-title + last prompt — no full transcript read — and, when the session has been mined into the **conversation wiki** (`~/projects/wiki/conversations`), enriches it with the curated title + summary (`wiki_summary`)
- Captures working-tree state — current branch, active `.current-task`, uncommitted file count, last 5 commits

## Response Handling

Based on `next_action`:

**`parse_content`** — Context gathered, synthesize the summary
1. Read the `tasks`, `history`, and `project` objects from the JSON.
2. If a recent conversation looks directly relevant to the open task and the JSON summary is not enough, read the tail of that conversation file (path is in `history.conversations[].file`) for detail — otherwise rely on the ai-title + last prompt.
3. Produce the **Left-Off Report** below, then a clear recommendation.

**`fix_error`** — Gathering failed
- Debug: `~/.claude/scripts/leftoff.sh --raw --full`
- Report per [Error Format](docs/reference/ux/error-blocker.md).

## Output Format

Present a consistent, scannable report:

```
## 🧭 Where You Left Off — <project_root>

**On branch** `<branch>` · <uncommitted_files> uncommitted file(s)<, active task ID if set>

### 📋 Tasks
- 🟢 Active (<active_count>):
  - `<TASK_ID>` — <title>
- ✅ Recently completed:
  - `<TASK_ID>` — <title>

### 💬 Recent Conversations
- **<title>** — <wiki_summary if present, else last prompt> (<message_count> msgs, <relative time><, worktree <id> if set>)

### 📦 Recent Commits
- <hash> <subject>

### 👉 Recommended Next Step
<One or two concrete options, each tied to a specific task ID or conversation,
 with the exact command to run (e.g. `/task-continue A3F2B9`).>
```

Keep titles/prompts trimmed to one line. If there are no active tasks, say so and base the recommendation on the most recent conversation + uncommitted changes. Format completion per [Completion Format](docs/reference/ux/task-completion.md).

## Section Flags

```bash
~/.claude/scripts/leftoff.sh --json --tasks            # Task snapshot only
~/.claude/scripts/leftoff.sh --json --history          # Recent conversations only
~/.claude/scripts/leftoff.sh --json --project          # Branch / commits / working tree only
~/.claude/scripts/leftoff.sh --json --history --limit 10  # More conversations
```

## Debugging

```bash
~/.claude/scripts/leftoff.sh --raw --full
```

