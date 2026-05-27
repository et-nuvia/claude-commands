---
command: task-code-review
group: task-lifecycle
backing_script: ~/.claude/scripts/task-code-review.sh
mutates: [files, git]
runtime: ~2-10min
destructive: false
requires_project_yaml: optional
project_yaml_fields:
  - task_management.backend
  - task_management.asana.workspace_id
  - task_management.gitlab.project_id
requires_project_knowledge: optional
project_knowledge_sections:
  - Architecture decisions
  - Service responsibility map
  - Business rules
---

# /task-code-review

> Part of the [Task Lifecycle workflow](../08-workflows.md#task-lifecycle).

Generates a CRV (code review) document for the current task: fetches the diff from the PR/MR or branch, analyzes it for quality, security, and performance issues, and writes a structured review document with confidence-scored findings. Produces a committed CRV file that can feed into `/task-audit` or `/task-close`.

> **Config:** PROJECT.yaml **optional** — used to locate PR/MR context. PROJECT-KNOWLEDGE.md **optional** — informs review of architectural patterns and business rules.

---

## When to use it

- Before `/task-close` when a formal written review artifact is required (security-sensitive changes, cross-team coordination)
- After implementation to get a second-pass analysis on quality, error handling, and test coverage
- When a senior reviewer needs a structured CRV document to approve before merge

## Usage

```bash
/task-code-review
```

**Common invocations:**

```bash
/task-code-review                            # default: auto-detect PR/MR from current branch
/task-code-review --pr-url https://...       # target a specific PR URL
```

## Arguments

| Argument / Flag | Required | Description |
|---|---|---|
| `--pr-url <url>` | No | Target a specific PR/MR URL instead of auto-detecting from the branch |
| `--task-id <id>` | No | Override `.current-task` lookup |

## Dependencies

**External commands / packages:**

| Dependency | Why it's needed | Install |
|---|---|---|
| `git` | Diff capture, branch introspection | preinstalled |
| `gh` (work) or `glab` (home) | Fetch PR/MR metadata and diff | `brew install gh` / install `glab` |
| `jq` | Parse script JSON output | `brew install jq` / `apt install jq` |

**Project files consumed:**

- `PROJECT.yaml` (PY) — Optional. Read for backend type to resolve PR/MR source.
- `PROJECT-KNOWLEDGE.md` (PK) — Optional. Informs architectural and business-rule checks in the review.
- `.understand/graph.json` — Optional. When present and a task ID is known, the command runs `understand-explore.sh --for-task` to surface affected nodes beyond the diff (callers/callees of changed symbols) — catches review hits the readability rubric alone would miss (e.g., stale callers of a renamed symbol). Skipped silently if absent.
- `.current-task` — read to identify the active task
- `docs/active/<task_id>/` — CRV document written here and committed

## Backing script

**Script**: `~/.claude/scripts/task-code-review.sh`

**Inputs:** `--full`, optional `--task-id`, `--pr-url`. Reads `.current-task` and discovers PR/MR from current branch.

**Outputs (structured JSON):** `next_action` ∈ {`analyze_code`, `display_summary`, `fix_error`}, plus `stats` (files_changed, additions, deletions), `diff.file` (path to full diff on disk), `diff_stats`, `file_list`, `commit_log`, `diff_source` (`pr`/`mr`/`branch`). On `--create-doc`: `template` (CRV skeleton with scope pre-filled) and `crv_path`.

**Invocation surface:**

```bash
~/.claude/scripts/task-code-review.sh --full                         # main
~/.claude/scripts/task-code-review.sh --json --get-pr                # skip task ID, go to PR discovery
~/.claude/scripts/task-code-review.sh --json --gather-info           # skip PR discovery, capture diff
~/.claude/scripts/task-code-review.sh --json --create-doc            # create CRV skeleton
~/.claude/scripts/task-code-review.sh --json --commit                # commit existing CRV
~/.claude/scripts/task-code-review.sh --save-notes --task-id TASK_ID --notes '{...}'  # checkpoint partial review
~/.claude/scripts/task-code-review.sh --load-notes --task-id TASK_ID                 # resume from checkpoint
~/.claude/scripts/task-code-review.sh --raw --full                   # debug: bypass formatting
```

## How it works

1. **Gather info** — script identifies the task from `.current-task`, discovers the PR/MR from the current branch (falls back to a branch diff if no open PR/MR exists), captures the full diff to a temp file, and returns stats.

2. **Read the diff** — the LLM reads the diff file directly using the Read tool (with `offset`/`limit` for large diffs). For diffs > 500 lines or > 10 files, the analysis is delegated to a subagent. Model selection: sonnet for standard work; opus for security-sensitive changes (auth, crypto, secrets), architectural changes, or cross-service coordination.

3. **Checkpoint large analyses** — for large diffs, the LLM saves partial findings after every 2-3 files via `--save-notes`. If the session is interrupted, `--load-notes` resumes from where it left off.

4. **Create CRV document** — the LLM calls `--create-doc` to get a pre-filled CRV skeleton with task scope, then fills all `[LLM to fill in]` sections with findings. Only findings with confidence ≥ 80 appear in the main document; low-confidence observations go in a separate Notes section. The completed document is written to `crv_path` using the Write tool.

5. **Commit** — the LLM calls `--commit`, which stages and commits the CRV file with a conventional commit message. Returns `display_summary` with the CRV filename and commit hash.

## Example workflows

### Scenario: Pre-close review for security change

```
/task-continue        # implement auth changes
/task-code-review     # generate CRV (auto-escalates to opus for auth diffs)
/task-audit           # confirm criteria complete
/task-close           # ship
```

### Scenario: Review against specific PR

```
/task-code-review --pr-url https://github.com/org/repo/pull/142
```

### Scenario: CRV committed output

```
/task-code-review
```

```
✓ Code review complete: "Add /me endpoint"
  Diff source:   PR #142 (github)
  Files changed: 6  (+183 / -12)
  Findings:      2 high, 1 medium (all confidence ≥ 80)

  CRV: docs/active/A3F2B9/A3F2B9-20260516-CRV-add-me-endpoint.md
  Committed: abc1234

  Blocking issues found — fix before /task-close
```

## Notes & gotchas

- Only findings with **confidence ≥ 80** appear in the main CRV. Uncertain observations go in a "Notes" section prefixed `(low confidence)`.
- Large diffs are checkpointed automatically; if the session ends mid-review, restart with `--load-notes` to avoid re-reading already-analyzed files.
- When the user asks to fix findings after the CRV is written, apply the fixes, run tests, then use `/git-commit` for code fixes before proceeding to `/task-audit` or `/task-close`.
- **If it fails:** no `.current-task` → pass `--task-id`. No open PR → script falls back to branch diff automatically. No diff found → check that you're on a feature branch with commits. Debug with `~/.claude/scripts/task-code-review.sh --raw --full`.
