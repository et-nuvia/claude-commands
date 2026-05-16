---
command: plan-progress
group: outlier
backing_script: ~/.claude/scripts/plan-progress.sh
mutates: [files]
runtime: ~5s
destructive: false
requires_project_yaml: none
project_yaml_fields: []
requires_project_knowledge: none
project_knowledge_sections: []
---

# /plan-progress

Reads the current PLN (planning) document on the active branch, reports how
many subtasks are complete versus remaining, identifies the next unchecked
item, and can mark items done by fuzzy-matching their text. The canonical way
to check where you are in a task plan without reading the full PLN file.
Called automatically by `/task-continue`.

---

## When to use it

- You want to see how far through a task plan you are before starting the next subtask
- After completing a subtask, you want to mark it done in the PLN document
- You want to confirm all plan items are checked before running `/task-close`

## Usage

```bash
/plan-progress [--mark-complete "<text>"]
```

**Common invocations:**

```bash
/plan-progress                                       # show progress
/plan-progress --mark-complete "Add unit tests"      # mark one item complete
```

## Arguments

| Argument / Flag | Required | Description |
|---|---|---|
| `--mark-complete "<text>"` | No | Fuzzy-match text against unchecked `- [ ]` items and flip the match to `- [x]`. Quote the text exactly as it appears in the plan. |

## Dependencies

**External commands / packages** (must be on `PATH`):

| Dependency | Why it's needed | Install |
|---|---|---|
| `jq` | Parse script JSON output | `brew install jq` / `apt install jq` |
| `git` | Locate the current branch to find the PLN file | preinstalled |

**Project files consumed:**

- `PROJECT.yaml` (PY) — No
- `PROJECT-KNOWLEDGE.md` (PK) — No
- PLN document (e.g., `docs/tasks/<TASK_ID>-*-PLN-*.md`) on the current branch — required; the script searches for it automatically

## Backing script

**Script**: `~/.claude/scripts/plan-progress.sh`

**Inputs:** No flags for status check. `--mark-complete "<text>"` to tick an item.

**Outputs (structured JSON on stdout):**

- `next_action` ∈ {`continue_implementation`, `display_summary`, `fix_error`}
- On `continue_implementation`: `done` count, `total` count, `percent`, `current_phase`, `next_items[]`
- On `display_summary`: all items complete; includes `done` and `total` counts
- On `fix_error`: PLN file not found; includes suggested recovery steps

**Invocation surface:**

```bash
~/.claude/scripts/plan-progress.sh                              # status check
~/.claude/scripts/plan-progress.sh --mark-complete "item text"  # mark done
```

There is no `--raw` debug flag; if the script errors, check that a PLN file
exists on the current branch.

## How it works

1. **Locate PLN** — script searches the working directory (and `docs/tasks/`)
   for a file matching the PLN naming pattern on the current branch. Returns
   `fix_error` if none is found.
2. **Parse checkboxes** — script counts `- [ ]` (open) and `- [x]` (done)
   items and identifies the current phase header and the next unchecked items.
3. **Mark complete** (optional) — if `--mark-complete` was supplied, the script
   fuzzy-matches the text against open items and rewrites the file with the
   match flipped to `- [x]`.
4. **Route** — if items remain, returns `continue_implementation` with progress
   stats and the next items list. If all items are checked, returns
   `display_summary` to signal the plan is fully done.
5. **LLM display** — the LLM formats the progress as a concise status block and
   surfaces the next item for the user to act on (or, on completion, suggests
   `/task-audit` or `/task-close`).

## Example workflows

### Scenario: Mid-task progress check

```
/plan-progress                            # see where you are
# work on next item
/plan-progress --mark-complete "Add unit tests for auth middleware"
/git-commit
/plan-progress                            # confirm item is checked
```

### Scenario: Progress output

```
/plan-progress
```

```
Plan Progress — Task 142: Add /me endpoint
  Done: 4 / 7  (57%)
  Phase: Implementation

  Next items:
    - Add unit tests for /me handler
    - Update OpenAPI schema
    - Update CHANGELOG

Continue with: Add unit tests for /me handler
```

## Notes & gotchas

- The script searches automatically — you do not need to pass the PLN file path.
  If multiple PLN files are found (rare), the most recent is used.
- `--mark-complete` uses fuzzy matching: passing a substring is usually
  sufficient, but the match must be unique. If two items share the same
  substring, the script will error rather than guess.
- The PLN file is modified in-place; the change is not committed automatically.
  Commit it with `/git-commit` when you commit the corresponding code change.
- **If it fails:** `fix_error` with "no PLN file found" — verify you are on
  the task branch (`git branch`), not on `main`. If the PLN file was never
  created, run `/task-plan` first.
