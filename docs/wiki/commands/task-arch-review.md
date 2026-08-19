---
command: task-arch-review
group: architecture
backing_script: ~/.claude/scripts/task-arch-review.sh
mutates: [files, git]
runtime: ~5s script, 5-20min of LLM analysis
destructive: false
requires_project_yaml: optional
project_yaml_fields:
  - task_management.backend
requires_project_knowledge: optional
project_knowledge_sections:
  - Architecture Decisions
---

# /task-arch-review

Applies the deepening heuristics to the files a single task touched (plus
their one-hop neighbours), so shallow modules, leaky seams, and untestable
interfaces get caught before the task lands in `dev` — not in a quarterly
cleanup pass. The result is an **ARC** document filed alongside the task's
other artifacts.

> **Config:** PROJECT.yaml optional — resolves the task.
> PROJECT-KNOWLEDGE.md optional — its presence and the ADR list are reported
> as architecture context.

---

## When to use it

- Before merging a task that added or reshaped a module boundary
- As part of [`/task-post-work`](task-post-work.md), where it runs automatically
- When a diff "works" but you suspect it made the seam worse

## Usage

```bash
/task-arch-review
```

## Arguments

| Argument / Flag | Required | Description |
|---|---|---|
| `$ARGUMENTS` | No | A Task ID. Falls back to `.current-task`. |

## Dependencies

**Project files consumed:**

- `~/.claude/templates/architecture/LANGUAGE.md` — **required reading before
  analysis.** The vocabulary (module / interface / implementation / depth /
  seam / adapter / leverage / locality / deletion test) is mandatory in
  candidates. "Component", "service", "API", and "boundary" are not
  substitutes — they're the vague words the vocabulary exists to replace.
- `~/.claude/templates/architecture/DEEPENING.md` — the categories each
  candidate's dependencies are classified against
- `PROJECT-KNOWLEDGE.md`, ADRs — optional context

## Backing script

**Script**: `~/.claude/scripts/task-arch-review.sh`

**Outputs:** task identity, diff stats, the changed-file list, the commit
log, and architecture context (PROJECT-KNOWLEDGE presence, ADR list), plus
`next_action: analyze_architecture`.

**Invocation surface:**

```bash
~/.claude/scripts/task-arch-review.sh --full
~/.claude/scripts/task-arch-review.sh --raw --full     # debug
```

## How it works

1. **Load the architecture language** — LANGUAGE.md in full, then
   DEEPENING.md. Skipping this produces a review written in generic
   architecture-speak, which is indistinguishable from no review.
2. **Script pass** — captures the diff, file list, commits, and context.
3. **Analyze** — each candidate is classified by depth, seam placement, and
   the deletion test, scoped to the task's files and their one-hop
   neighbours.
4. **Decide per candidate** — fix in place now, or spin out a follow-up TSK.
5. **Write the ARC** to `docs/active/<task>/<TASK_ID>-<datetime>-ARC-*.md`
   so it travels with the task's other documents.

## Example workflows

### Scenario: standalone review before a merge

```
/task-continue          # work lands
/task-arch-review       # ARC: candidates, depth, seams
/task-post-work
```

### Scenario: inside the pipeline

When run by [`/task-post-work`](task-post-work.md), the per-candidate
"fix now or defer?" question is **not** asked. Every in-scope candidate is
fixed in place this pass; candidates below the current severity threshold
can become follow-up TSKs via `/feature-to-task` after the pipeline
finishes. Pausing to ask would break the loop's determinism.

## Notes & gotchas

- **Scope is the point.** [`/arch-explore`](arch-explore.md) sweeps the
  whole codebase; this reviews one task's blast radius. Reaching for
  arch-explore here buries the task's own regressions in a codebase-wide
  backlog.
- Section resumption is supported — a long review can be picked up rather
  than restarted.
- **If it fails:** `--raw --full` shows the unformatted script output,
  which is where a bad task resolution or an empty diff shows up.
