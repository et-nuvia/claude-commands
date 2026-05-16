---
command: git-rebase
group: git
backing_script: ~/.claude/scripts/git-rebase.sh
mutates: [git]
runtime: ~10-30s
destructive: false
requires_project_yaml: none
project_yaml_fields: []
requires_project_knowledge: none
project_knowledge_sections: []
---

# /git-rebase

Rebases a branch onto another to produce a clean, linear history. Validates
the working tree, shows you the plan (including a force-push warning when
needed), asks for confirmation, resolves any conflicts interactively, then
pushes with `--force-with-lease`. Never touches protected branches.

---

## When to use it

- A feature branch has fallen behind its base and you want to replay commits
  on top of the latest work before opening a PR
- `/git-merge` returns `ask_rebase_strategy` and you choose "Rebase first"
- You want to eliminate an unnecessary merge commit and keep history linear

## Usage

```bash
/git-rebase [branch] [onto]
```

**Common invocations:**

```bash
/git-rebase                              # rebase current branch onto auto-detected base
/git-rebase feature/my-feature main     # explicit branch and base
/git-rebase feature/my-feature develop  # onto a non-default base
```

## Arguments

| Argument / Flag | Required | Description |
|---|---|---|
| `branch` | No | Branch to rebase. Defaults to current branch. |
| `onto` | No | Target base branch. Auto-detected from PROJECT.yaml or git remote HEAD if omitted. |

## Dependencies

**External commands / packages** (must be on `PATH`):

| Dependency | Why it's needed | Install |
|---|---|---|
| `git` | Rebase, conflict detection, force-with-lease push | preinstalled |
| `jq` | Parse script JSON output | `brew install jq` / `apt install jq` |

**Project files consumed:**

- `PROJECT.yaml` (PY) — No (consulted optionally to detect default base branch)
- `PROJECT-KNOWLEDGE.md` (PK) — No
- Repo `.git/` — required; must be inside a working tree

## Backing script

**Script**: `~/.claude/scripts/git-rebase.sh`

**Inputs:** `--branch <branch>`, `--onto <base>`, stage flags (`--full`,
`--validate`, `--analyze`, `--execute`, `--push`).

**Outputs:** structured JSON on stdout with:

- `next_action` ∈ {`confirm_action`, `display_summary`,
  `ask_uncommitted_strategy`, `resolve_conflicts`, `fix_error`}
- `status`, `branch`, `onto`, `commit_count`, `requires_force_push`,
  `conflict_files`, `changed_file_count`, `details`

**Invocation surface:**

```bash
~/.claude/scripts/git-rebase.sh --full --branch <branch> --onto <base>
~/.claude/scripts/git-rebase.sh --validate --branch <branch> --onto <base>
~/.claude/scripts/git-rebase.sh --analyze --branch <branch> --onto <base>
~/.claude/scripts/git-rebase.sh --execute --branch <branch> --onto <base>
~/.claude/scripts/git-rebase.sh --push --branch <branch>
~/.claude/scripts/git-rebase.sh --raw --full --branch <branch> --onto <base>   # debug
```

## How it works

1. **Validate** — script confirms the working tree is clean. If uncommitted
   changes exist, returns `ask_uncommitted_strategy` so the LLM can offer
   commit, stash, or cancel.
2. **Analyze** — computes the commit list and checks whether the remote will
   require a force push. Returns `confirm_action` with the plan; the LLM
   presents branch, base, commit count, potential conflict files, and
   force-push warning (if applicable), then waits for user confirmation before
   proceeding.
3. **Execute** — runs `git rebase`. If conflicts occur, returns
   `resolve_conflicts` with the affected file list. The LLM resolves markers
   via Read + Edit, stages fixed files, runs `git rebase --continue`, and
   repeats until the rebase completes. To bail out at any point: `git rebase
   --abort`.
4. **Push** — script pushes the rebased branch with `--force-with-lease` (not
   `--force`). Returns `display_summary` with the new base commit and push
   status.

## Example workflows

### Scenario: Sync a stale feature branch before PR

```
/git-rebase feature/search main   # bring feature up to date
/create-pr                        # open PR against clean base
```

Keeps the PR diff minimal and the history linear.

### Scenario: Rebase with force-push warning

```
/git-rebase feature/payments main
```

```
Rebase Plan
  Branch : feature/payments  (6 commits)
  Onto   : main              (HEAD: 9d2c41f)
  Conflicts possible in: src/billing/invoice.ts

  ⚠ Remote branch exists — a force push will be required after rebase.
  Collaborators with local copies of this branch will need to reset.

Proceed?  [Yes / Cancel]
```

## Notes & gotchas

- **Protected branches are blocked** — the script refuses to rebase `main`,
  `master`, `develop`, `production`, or `staging`. These branches are merge
  targets, not rebase sources.
- **Force-push risk** — rebasing a branch that others have checked out
  rewrites its remote history. Coordinate with teammates before rebasing
  shared branches. The script uses `--force-with-lease` (safer than
  `--force`), which aborts if the remote was updated since you last fetched.
- **Abort at any time** — if the rebase enters conflict mode and you want out:
  `git rebase --abort` returns the branch to its pre-rebase state with no
  changes made.
- **If conflicts won't resolve cleanly:** abort, merge instead with
  `/git-merge`, or ask for help before force-pushing anything.
- **If it fails:** run
  `~/.claude/scripts/git-rebase.sh --raw --full --branch <branch> --onto <base>`
  to see unformatted output and identify the broken stage.
- Work (macOS) auto-detects base from GitHub remote HEAD; home (WSL)
  auto-detects from GitLab remote HEAD. Override with explicit `--onto` when
  the default is wrong.
