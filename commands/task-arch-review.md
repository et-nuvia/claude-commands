---
name: task-arch-review
description: Task-scoped architecture review — apply deepening heuristics to a task's diff so shallow modules, leaky seams, and untestable surfaces are caught before the merge to dev.
user_invocable: true
---


> **Output format is auto-detected: TOON when an AI agent is the caller, JSON for tests/CI.** This is intentional — TOON carries the same fields in far fewer tokens. `--json` does NOT switch an LLM caller to JSON, and that is not a bug to work around. Read the TOON fields directly; never pipe script output through `jq`, a converter, or `head`/`tail`/`grep` to "fix" the format.


You are an architecture-review assistant working at **task scope**. Use **model: fable** (`claude-fable-5`) — this is deep, judgement-heavy work and one of the low-frequency, high-leverage commands where Fable's reasoning earns its premium. Omit any thinking-budget config (Fable's thinking is always on; steer depth with effort). If Fable is unavailable or returns a refusal (`stop_reason: "refusal"` — rare here, but architecture diffs can brush security-adjacent code), fall back to **opus** (`claude-opus-4-8`).

Unlike `/arch-explore` which sweeps the whole codebase, this command applies the same deepening heuristics to **only the files a single task has touched** (plus their 1-hop neighbors). The goal: catch shallow modules, leaky seams, and untestable interfaces *before* the task lands in `dev`, not in a quarterly cleanup pass.

The resulting ARC document is filed alongside the TSK (`docs/active/<task>/<TASK_ID>-<datetime>-ARC-*.md`) so it travels with the rest of the task's artifacts.

## Step 0: Load Architecture Language

Before any analysis, read `~/.claude/templates/architecture/LANGUAGE.md` in full. The vocabulary (**module / interface / implementation / depth / seam / adapter / leverage / locality / deletion test**) is mandatory in candidates. Do not substitute "component," "service," "API," or "boundary."

Also read `~/.claude/templates/architecture/DEEPENING.md` — you'll classify each candidate's dependencies by its categories.

## Step 1: Run the script

```bash
~/.claude/scripts/task-arch-review.sh --full
```

Read `RESULT` directly (it is TOON for you as an AI caller — no `jq`, no conversion). It includes task identity, diff stats, file list, commit log, and architecture context (PROJECT-KNOWLEDGE.md presence, ADR list).

## Response Handling

### `analyze_architecture` — Diff captured, do the review

1. **Read `docs/architecture/PROJECT-KNOWLEDGE.md`** if `architecture.knowledge_present == true`. Use its domain vocabulary in every candidate name (e.g. "Order intake module," not "FooBarHandler"). If absent, surface this to the user — task-level review of a diff in an undocumented domain produces vague candidates.

2. **Read every file in `architecture.adr_files`** (if non-empty). Don't re-litigate settled decisions. If a candidate contradicts an ADR, mark it clearly: _"Contradicts ADR-NNNN — worth reopening because…"_

3. **Read the diff** at `diff.file`. For diffs >500 lines or >10 files, dispatch the heuristic walk to an `Explore` subagent (opus) to keep the parent context clean.

4. **Walk the diff with the heuristics — scoped to changed files plus 1-hop neighbors:**
   - **Shallow new modules** — did this task add a module whose interface is nearly as complex as its implementation? Apply the **deletion test**: would deleting it concentrate complexity, or just move it?
   - **Pure-functions-without-locality** — were helpers extracted for testability while the real behaviour (and the real bugs) live in the callers?
   - **Leaky seams** — does the change leak implementation details across an existing boundary (e.g. new caller knows internal field names, ordering, error types)?
   - **Untestable through current interface** — do the new tests reach past the seam (touching private state, monkey-patching, asserting on internals)?
   - **Premature abstraction** — was a single-use abstraction introduced "for future flexibility"?
   - **Drift from neighbors** — does the change diverge from the pattern used by 1-hop callers/callees in the same domain?

   For each suspected finding, also inspect callers/callees of the changed symbols (use grep on the file_list neighborhood) — task-scoped review without 1-hop context misses most leaky-seam cases.

5. **Present a numbered list of deepening candidates to the user.** List **every** candidate that genuinely meets the heuristics — this is not a top-N, so never truncate to 3, 5, or any fixed count. (This does not override the anti-performative guard below: report all *real* candidates, don't invent marginal ones to lengthen the list.) For each candidate include:
   - **Severity**: `HIGH` (blocks merge — design will harden quickly if shipped) / `MEDIUM` (fix recommended this task) / `LOW` (defer to follow-up TSK)
   - **Files / modules**: paths (including 1-hop neighbors if relevant)
   - **Problem**: why the current shape causes friction. Apply the deletion test explicitly.
   - **Solution**: plain-English sketch of the deepened shape — no full interface design
   - **Dependency category**: per DEEPENING.md
   - **Benefits**: in terms of **leverage**, **locality**, and **tests**
   - **ADR conflicts**: only if applicable

   If the diff is clean — no shallow modules, no leaky seams — say so plainly. A short ARC with "No deepening candidates surfaced" is a valid outcome and prevents performative findings.

6. **Ask the user** for each candidate: fix in-place this task, or spawn a follow-up TSK via `/feature-to-task`? Do not proceed past the list without confirmation.

7. **Create the ARC document**:
   ```bash
   ~/.claude/scripts/task-arch-review.sh --json --create-doc
   ```

8. **Fill the template** at `arc_path` using the Write tool. Put every candidate (with severity) into the **Deepening Candidates** section. Leave the **Grilled Design**, **Interface Alternatives**, and **Recommendation** sections empty — those are filled later by `/arch-grill` and `/arch-interfaces` if the user decides to deepen a candidate before implementing.

9. **Commit**:
   ```bash
   ~/.claude/scripts/task-arch-review.sh --json --commit
   ```

### `display_summary` — ARC committed

- Show ARC filename and commit hash.
- If `HIGH` severity candidates were surfaced and the user chose "fix in-place": apply fixes, run tests, commit via `/git-commit` before proceeding to `/task-close`.
- If `HIGH` severity candidates were spawned as follow-up TSKs: list the new task IDs so the user can decide whether to block merge on them or not.
- Format per [Completion Format](docs/reference/ux/task-completion.md).

### `fix_error` — Review failed

- Common: no `.current-task` file, task document missing, template not found.
- Target a specific PR: `--pr-url <url>`
- Debug: `~/.claude/scripts/task-arch-review.sh --raw --full`
- Report per [Error Format](docs/reference/ux/error-blocker.md).

## When to invoke

- During `/task-continue` on a non-trivial task before tests are finalized (advisory).
- During `/task-close` after `/task-code-review`, before the merge to `dev` (blocking on `HIGH` severity findings is the recommended policy).
- Manually anytime: `/task-arch-review [--task-id <id>]`.

## Section Resumption

- `--get-pr` — skip task identification
- `--gather-info` — skip PR discovery, go straight to diff capture
- `--create-doc` — create the ARC skeleton (skips if ARC already exists for this task)
- `--commit` — commit existing ARC (does NOT create a new one)

## Debugging

```bash
~/.claude/scripts/task-arch-review.sh --raw --full
```

