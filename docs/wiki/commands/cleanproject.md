---
command: cleanproject
group: code-quality
backing_script: ~/.claude/scripts/cleanproject.sh
mutates: [files]
runtime: ~15-30s
destructive: false
requires_project_yaml: none
project_yaml_fields: []
requires_project_knowledge: none
project_knowledge_sections: []
---

# /cleanproject

Scans the project for development artifacts — logs, temp files, debug dumps, and backup files — then removes them safely. Creates a git checkpoint commit before deletion so any accidental removal can be recovered in one command.

---

## When to use it

- Before tagging a release or opening a PR, to remove noise from the diff
- After a long debugging session that left log files and scratch files behind
- Periodic housekeeping when `git status` is cluttered with artifacts

## Usage

```bash
/cleanproject
```

**Common invocations:**

```bash
/cleanproject                  # identify, analyze safety, then clean
```

## Arguments

None — invoke with no input.

## Dependencies

**External commands / packages** (must be on `PATH`):

| Dependency | Why it's needed | Install |
|---|---|---|
| `git` | Creating the pre-cleanup checkpoint commit | preinstalled |
| `lsof` | Diagnosing files that cannot be deleted (in use) | preinstalled on macOS/Linux |

**Project files consumed:**

- `PROJECT.yaml` (PY) — No
- `PROJECT-KNOWLEDGE.md` (PK) — No

## Backing script

**Script**: `~/.claude/scripts/cleanproject.sh`

**Inputs:** `--full`, `--identify`, `--analyze`, `--cleanup`. No PROJECT.yaml fields required.

**Outputs:** structured JSON on stdout with:
- `next_action` ∈ {`display_summary`, `fix_failed_files`, `fix_error`}
- On `display_summary`: count of deleted files, breakdown by type (temporary, debug, backup)
- On `fix_failed_files`: list of files that could not be deleted

**Invocation surface:**

```bash
~/.claude/scripts/cleanproject.sh --full       # identify + analyze + cleanup
~/.claude/scripts/cleanproject.sh --identify   # find candidates only (no deletion)
~/.claude/scripts/cleanproject.sh --analyze    # safety analysis only
~/.claude/scripts/cleanproject.sh --cleanup    # perform deletion only
~/.claude/scripts/cleanproject.sh --raw --identify  # debug
```

## How it works

1. **Identify** — script finds candidate artifact files: `*.log`, `*.tmp`, `*.bak`, debug dumps, editor swap files, and similar patterns. Working code is never targeted.
2. **Analyze** — safety check ensures no identified file is actually a source file or config mistakenly matching a pattern.
3. **Checkpoint** — git commits the current state with message `Pre-cleanup checkpoint` before any deletion.
4. **Cleanup** — identified files are deleted. On completion, `display_summary` reports counts by type. If any files could not be removed, `fix_failed_files` is returned with the blocking paths.

## Example workflows

### Scenario: Pre-PR cleanup

```
/cleanproject
/git-commit "chore: remove development artifacts"
/create-pr
```

Removes noise before reviewers see the diff.

### Scenario: Cleanup summary

```
/cleanproject
```

```
Pre-cleanup checkpoint committed: a3f1c2d
Deleted 14 files:
  temporary  8  (*.tmp, editor swap files)
  debug      4  (debug.log, dump_*.json)
  backup     2  (*.bak)
Project is clean.
```

## Notes & gotchas

- The git checkpoint is created before any deletion. To recover: `git log --oneline -5` to find the checkpoint SHA, then `git reset --hard <sha>`.
- If a file cannot be deleted (`fix_failed_files`), check if it is in use with `lsof <file>` or has wrong permissions with `ls -la <file>`. After resolving, re-run `~/.claude/scripts/cleanproject.sh --json --cleanup`.
- **If it fails:** run `~/.claude/scripts/cleanproject.sh --raw --identify` to see what the scan found before any deletion occurs.
- The command only removes files matching known artifact patterns — it does not touch source, config, or data files.
