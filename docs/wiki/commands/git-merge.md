---
command: git-merge
group: git
backing_script: ~/.claude/scripts/git-merge.sh
mutates: [git]
runtime: ~10-30s
destructive: false
requires_project_yaml: none
project_yaml_fields: []
requires_project_knowledge: none
project_knowledge_sections: []
---

# /git-merge

Merges one branch into another — regular or squash — with conflict resolution
support, rebase-first guidance when history has diverged, and automatic
cleanup. You get a clean merge commit (or squashed commit) without touching
protected branches by hand.

---

## When to use it

- You want to merge a feature branch into main (or any target) and need
  conflict handling or a diverged-history decision made safely
- You want a squash merge to keep the target's history linear
- `/deploy-to-stage` or `/deploy-to-prod` delegates a merge step to this
  command internally

## Usage

```bash
/git-merge [source-branch] [target-branch]
```

**Common invocations:**

```bash
/git-merge feature/my-feature main          # regular merge
/git-merge feature/my-feature main --squash # squash merge
/git-merge                                  # prompted for branches
```

## Arguments

| Argument / Flag | Required | Description |
|---|---|---|
| `source-branch` | No | Branch to merge from. Prompted if omitted. |
| `target-branch` | No | Branch to merge into. Prompted if omitted. |
| `--squash` | No | Perform a squash merge instead of a regular merge commit. |
| `--message "msg"` | No | Custom commit message for the merge or squash commit. |

## Dependencies

**External commands / packages** (must be on `PATH`):

| Dependency | Why it's needed | Install |
|---|---|---|
| `git` | Branch operations, merge, conflict detection | preinstalled |
| `jq` | Parse script JSON output | `brew install jq` / `apt install jq` |

**Project files consumed:**

- `PROJECT.yaml` (PY) — No
- `PROJECT-KNOWLEDGE.md` (PK) — No
- Repo `.git/` — required; must be inside a working tree

## Backing script

**Script**: `~/.claude/scripts/git-merge.sh`

**Inputs:** `--source <branch>`, `--target <branch>`, stage flags (`--full`,
`--validate`, `--analyze`, `--merge`, `--cleanup`), `--squash`,
`--message "msg"`.

**Outputs:** structured JSON on stdout with:

- `next_action` ∈ {`display_summary`, `ask_rebase_strategy`,
  `resolve_conflicts`, `fix_error`}
- `status`, `merge_type`, `commit_count`, `merge_hash`, `conflict_files`,
  `target_ahead_count`, `source_ahead_count`, `recommendation`

**Invocation surface:**

```bash
~/.claude/scripts/git-merge.sh --source <src> --target <tgt> --full
~/.claude/scripts/git-merge.sh --source <src> --target <tgt> --validate
~/.claude/scripts/git-merge.sh --source <src> --target <tgt> --analyze
~/.claude/scripts/git-merge.sh --source <src> --target <tgt> --merge
~/.claude/scripts/git-merge.sh --source <src> --target <tgt> --cleanup
~/.claude/scripts/git-merge.sh --source <src> --target <tgt> --raw --full   # debug
```

## How it works

1. **Validate** — script checks both branches exist, working tree is clean,
   and neither branch is in a conflicted state. Returns `fix_error` on
   failure.
2. **Analyze** — compares branch tips to detect divergence. If target has
   commits not in source, returns `ask_rebase_strategy` so the LLM can ask
   the user whether to rebase first, merge anyway, or cancel.
3. **Merge** — performs the merge (regular or squash). If conflicts are
   detected, returns `resolve_conflicts` with the list of affected files. The
   LLM reads each file, resolves all `<<<<<<<`/`=======`/`>>>>>>>` markers via
   Edit, stages the resolved files, then resumes from `--cleanup`.

   **Lockfile regeneration is fail-fast.** If the merge regenerates a
   lockfile (root or subdir) and the resulting `git commit --amend` is
   rejected by a hook (missing GPG key, signing config, pre-commit), the
   script unstages the lockfile, restores it, aborts the merge, and exits
   with a JSON error — instead of silently leaving the un-amended merge SHA
   in place and pushing the merge commit *without* the lockfile fix. The
   subdir loop also skips directories with their own `.git` and gitignored
   paths so `npm install` doesn't run inside `node_modules/` or vendored
   repos.

4. **Cleanup** — pushes the target branch to remote and reports the merge
   hash, commit count, and version impact in a `display_summary` response.

## Example workflows

### Scenario: Standard feature merge

```
/git-commit                    # clean up working tree first
/git-merge feature/auth main   # merge
/create-pr                     # or open a PR if not yet merged
```

Typical end-of-task wrap-up when merging directly rather than via PR.

### Scenario: Merge with diverged history

```
/git-merge feature/payments main
```

```
Target branch has 3 commits not in source.

Options:
  1. Rebase first — rebase feature/payments onto main, then merge (linear history)
  2. Merge anyway — create a merge commit (preserves diverged history)
  3. Cancel

Choice: 1

Rebasing feature/payments onto main…
Merge complete. Hash: a3f91bc  Commits: 4  Type: regular
```

## Notes & gotchas

- **Protected branches** — the script will not force-push or rewrite history
  on branches named `main`, `master`, `develop`, `production`, or `staging`.
  If you target one of these, only a standard merge commit is written.
- **Squash merges do not delete the source branch automatically** — delete it
  yourself after confirming the squash landed correctly.
- History rewrite risk: this command writes a new merge commit on the target
  branch. If the target has already been pushed and others have based work on
  it, coordinate before merging.
- **If it fails (conflict):** resolve markers manually, `git add <files>`,
  then resume with
  `~/.claude/scripts/git-merge.sh --source <src> --target <tgt> --cleanup`.
- **If it fails (other):** run
  `~/.claude/scripts/git-merge.sh --source <src> --target <tgt> --raw --full`
  to see unformatted output and identify the broken stage.
- **If you need to abort a mid-merge state:** `git merge --abort` resets the
  tree to pre-merge HEAD.
