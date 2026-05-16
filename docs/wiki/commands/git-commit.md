---
command: git-commit
group: git
backing_script: ~/.claude/scripts/git-commit.sh
mutates: [git]
runtime: ~5-30s
destructive: false
requires_project_yaml: none
requires_project_knowledge: none
---

# /git-commit

Inspects the working tree, groups changes by purpose, drafts conventional
commits with explanatory bodies, gets your approval, then commits. Splits
unrelated changes into separate commits automatically. Never adds AI
attribution.

---

## When to use it

- You have a dirty working tree and want clean commits before pushing
- A single session produced unrelated changes (bug fix + tests + docs) that
  need to be split
- You want commit messages that match the repo's existing style without
  hand-writing them

## Usage

```bash
/git-commit [free-form instructions]
```

**Common invocations:**

```bash
/git-commit
/git-commit "split docs and code"
/git-commit "squash everything into one commit"
```

## Arguments

| Argument / Flag | Required | Description |
|---|---|---|
| `$ARGUMENTS` | No | Free-form hint passed to planning: grouping (`squash all`, `keep tests separate`), tone, BREAKING CHANGE flag. |

## Dependencies

**External commands:**

| Dependency | Why it's needed | Install |
|---|---|---|
| `git` | Inspect diffs, stage, commit | preinstalled |
| `jq` | Parse the plan JSON before execute | `brew install jq` / `apt install jq` |

**Project files consumed:**

- `PROJECT.yaml` (PY) — No
- `PROJECT-KNOWLEDGE.md` (PK) — No
- Repo `.git/` — required; must be inside a working tree
- `.pre-commit-config.yaml` or equivalent — optional; hooks may fail commits

## Backing script

**Script**: `~/.claude/scripts/git-commit.sh`

**Inputs:** `--analyze` (no args), `--analyze-diffs --page N`,
`--execute --plan-file <path>`. Reads the current `git status` / `git diff`.

**Outputs (structured JSON):**

- `--analyze` → `files`, `diff_stats`, `recent_commits`, `diff_pages`
- `--analyze-diffs` → `file_diffs` array (full diff text per file, unpaged)
- `--execute` → `next_action` ∈ {`display_summary`, `fix_failed_commits`,
  `fix_error`}, per-commit success/failure with hashes

**Invocation surface:**

```bash
~/.claude/scripts/git-commit.sh --analyze
~/.claude/scripts/git-commit.sh --analyze-diffs --page N
~/.claude/scripts/git-commit.sh --execute --plan-file /tmp/git-commit-plan.json
~/.claude/scripts/git-commit.sh --raw --<stage>           # debug
```

## How it works

1. **Analyze summary** — script returns the file list, diff stats, recent
   commits (for style matching), and total diff pages.
2. **Fetch diffs** — script pages through full diffs; LLM runs pages in
   parallel when there are several.
3. **Plan commits** — LLM groups changes by single purpose (not directory),
   drafts `type(scope): description` titles + bodies, presents a table with
   bodies underneath, and asks for approval via `AskUserQuestion`.
4. **Execute** — approved plan is written to `/tmp/git-commit-plan.json` and
   the script commits in order. On hook failure: a **new** commit is created
   for the fix (never an amend).

## Example workflows

### Scenario: End of an iteration

```
/task-continue          # implement + tests + plan update
/git-commit             # split into reviewable commits
/create-pr              # open the PR
```

Standard wrap-up. `/task-continue` leaves the tree dirty; `/git-commit`
turns it into a clean series.

### Scenario: Approving a plan

```
/git-commit
```

```
Commit Plan
  ┌───┬─────────────────────────────────────┬──────────────────────┬────────┐
  │ # │ Title                               │ Files                │  +/-   │
  ├───┼─────────────────────────────────────┼──────────────────────┼────────┤
  │ 1 │ fix(api): handle null user in /me   │ src/api/users.ts     │ +6/-2  │
  │ 2 │ test(api): cover null user case     │ test/users.test.ts   │ +24/-0 │
  └───┴─────────────────────────────────────┴──────────────────────┴────────┘
  1 ▎ Endpoint crashed on first-login users …
  2 ▎ Add regression coverage for the null path.

Proceed?  [Approve / Edit / Cancel]
```

## Notes & gotchas

- **Never amends.** Failed pre-commit hook → new commit, not `--amend`. This
  is intentional; amending after failure can destroy work.
- Grouping is by **purpose**, not by path. Two files in different directories
  may land in the same commit if they serve one change.
- Only files visible to `git status` are considered; untracked files are not
  auto-staged.
- "Co-Authored-By: Claude" is hard-blocked — arguments asking for AI
  attribution are ignored.
- **If it fails:** rerun with `~/.claude/scripts/git-commit.sh --raw --analyze`
  to see the unformatted script output and identify the broken stage.
