---
command: todos-to-issues
group: outlier
backing_script: ~/.claude/scripts/todos-to-issues.sh
mutates: [github]
runtime: ~30-120s
destructive: false
requires_project_yaml: none
project_yaml_fields: []
requires_project_knowledge: none
project_knowledge_sections: []
---

# /todos-to-issues

Scans the codebase for `TODO`, `FIXME`, `HACK`, and `NOTE` comments, reads
each one in context, classifies it by type and priority, and creates
professional GitHub issues with descriptions, file locations, proposed
solutions, and acceptance criteria. Groups related TODOs into a single issue
when they share a concern. Never adds AI attribution to issues.

> ⚠️ **Mutates GitHub** — creates real issues in the remote repository. Run `/todos-to-issues --validate` first to verify setup without creating anything.

---

## When to use it

- You have accumulated TODO comments across a codebase and want them tracked in GitHub
- Before a release, to ensure no tech-debt markers are silently lost
- After a code review that surfaces TODO patterns worth formalizing as issues

## Usage

```bash
/todos-to-issues [--validate | --scan | --create]
```

**Common invocations:**

```bash
/todos-to-issues                   # full run: validate + scan + create issues
/todos-to-issues --validate        # check GitHub setup only, no issues created
/todos-to-issues --scan            # scan and list TODOs only, no issues created
/todos-to-issues --create          # use cached scan results to create issues
```

## Arguments

| Argument / Flag | Required | Description |
|---|---|---|
| `--validate` | No | Verify GitHub remote, `gh` auth, and pre-flight checks. No issues created. |
| `--scan` | No | Scan for TODOs and return the file list. Caches results for `--create`. |
| `--create` | No | Use cached scan results to create issues without re-scanning. |

If no flag is provided, all three phases run in sequence.

## Dependencies

**External commands / packages** (must be on `PATH`):

| Dependency | Why it's needed | Install |
|---|---|---|
| `gh` | Create GitHub issues via the CLI | `brew install gh` (then `gh auth login`) |
| `git` | Detect the GitHub remote and current branch | preinstalled |
| `grep` / `ripgrep` | Scan source files for TODO patterns | preinstalled (rg: `brew install ripgrep`) |
| `jq` | Parse script JSON output | `brew install jq` / `apt install jq` |

**Project files consumed:**

- `PROJECT.yaml` (PY) — No
- `PROJECT-KNOWLEDGE.md` (PK) — No
- `~/.config/gh/` — `gh` auth token (via `gh auth login`)
- `/tmp/todos-to-issues-scan.json` — cached scan output, read by `--create`

## Backing script

**Script**: `~/.claude/scripts/todos-to-issues.sh`

**Inputs:** `--full` (default), `--validate`, `--scan`, or `--create`. No other flags.

**Outputs (structured JSON on stdout):**

- `next_action` ∈ {`analyze_and_create_issues`, `fix_error`}
- On `analyze_and_create_issues`: `files[]` — paths of files containing TODO
  comments; `todo_count` — total count found
- On `fix_error`: `message` and `details` describing the failure (missing `gh`,
  auth failure, pre-flight check failure, no GitHub remote)

**Invocation surface:**

```bash
~/.claude/scripts/todos-to-issues.sh --full                  # main entry
~/.claude/scripts/todos-to-issues.sh --validate              # setup check only
~/.claude/scripts/todos-to-issues.sh --scan                  # scan only
~/.claude/scripts/todos-to-issues.sh --create                # create from cache
~/.claude/scripts/todos-to-issues.sh --raw --scan            # debug
```

## How it works

1. **Validate** — script checks for a GitHub remote, a valid `gh` auth session,
   and runs pre-flight checks (tests and linter must pass). Returns `fix_error`
   with a specific `details` message if any check fails.
2. **Scan** — script uses grep/ripgrep to locate `TODO`, `FIXME`, `HACK`, and
   `NOTE` comments across the codebase, returning `files[]` and `todo_count`.
   Results are cached to `/tmp/todos-to-issues-scan.json`.
3. **Read and classify** — the LLM reads each file in `files[]` to understand
   the surrounding context. It assigns each TODO a type (bug, feature, docs,
   performance, security, tech-debt, chore) and a priority (CRITICAL → high;
   FIXME → medium; TODO/NOTE → low). Related TODOs are grouped into a single
   issue.
4. **Create issues** — for each TODO (or group), the LLM calls `gh issue create`
   with a title matching project naming conventions, a description covering
   context, file:line location, proposed solution, and acceptance criteria.
   Labels are drawn from the project's existing taxonomy. No AI attribution,
   no emojis.
5. **Summary** — the LLM reports how many issues were created, which TODOs were
   grouped, and whether any were skipped (e.g., already have a linked issue).

## Example workflows

### Scenario: Pre-release cleanup

```
/todos-to-issues --validate         # confirm gh is authenticated
/todos-to-issues --scan             # preview what will be filed
/todos-to-issues --create           # create the issues
/task-fetch                         # see the new issues in your task list
```

### Scenario: Full run output

```
/todos-to-issues
```

```
Found 14 TODO comments across 8 files.

Creating issues:
  [1/5] feat: Add pagination to /users endpoint  →  #204
  [2/5] fix: Handle null session in auth middleware  →  #205
  [3/5] chore: Remove legacy XML parser  →  #206
  [4/5] perf: Cache role lookups in Redis (grouped 3 TODOs)  →  #207
  [5/5] docs: Document rate-limit headers  →  #208

5 issues created. 14 TODOs linked.
```

## Notes & gotchas

- Pre-flight checks (tests, linter) must pass before issues are created. Fix
  failing checks first; the command does not bypass them.
- Works only with GitHub remotes. GitLab support is not currently implemented
  — on a GitLab project this returns `fix_error` with "No GitHub remote".
- TODOs already linked to an open issue (detected by the `#NNN` pattern in the
  comment) are skipped silently.
- The command is not fully idempotent: re-running after a partial failure may
  create duplicate issues for TODOs already filed. Use `--scan` + `--create`
  staged invocations to reduce this risk.
- **If it fails:** `gh` not authenticated → `gh auth login` and retry.
  Pre-flight failure → fix the failing check, then rerun. Debug scan phase
  with `~/.claude/scripts/todos-to-issues.sh --raw --scan`.
