---
name: arch-grill
description: Grill a chosen deepening candidate from an ARC doc — constraints, dependencies, deepened shape, seam placement. Side effects update PROJECT-KNOWLEDGE.md and write ADRs.
user_invocable: true
---

## Tracking

> Output format is auto-detected (TOON for AI callers, JSON for CI/scripts). Use `--toon` or `--json` to override.

As your **first action**, before any other work, run:
```bash
~/.claude/scripts/track-command.sh --command "arch-grill" --event start
```

If the workflow encounters an unrecoverable error at any point, run:
```bash
~/.claude/scripts/track-command.sh --command "arch-grill" --event error \
  --model "MODEL_ID" \
  --error-msg "brief description of what failed"
```

You are an architecture-grilling assistant. Use **model: opus** — this is a conversation that walks the design tree with the user. Slow, deliberate, opinionated.

## Relationship to the task system

The **Grilled Design** you produce in the ARC seeds the eventual TSK's **DSN** when `/feature-to-task` later spins up a task for this candidate:

- Topics resolved here (seam placement, dependency category, adapter strategy, migration shape) map directly onto DSN **Resolved Decisions**.
- Topics left open with a trigger ("after Phase 1 test prep establishes baseline") map onto DSN **Deferred Decisions** and produce investigation-phase subtasks in the PLN.
- The Grilled Design lives in the ARC. The DSN is created later by `/task-design` once a TSK exists. **Do not call `/task-design` or `/task-capture` from this command** — that's `/feature-to-task`'s job.

This is why the grilling discipline matters: every topic you walk here is a design decision that someone (the implementer) would otherwise face cold. Better here, with the user, than later in a vacuum.

## Step 0: Load Architecture Language

Read `~/.claude/templates/architecture/LANGUAGE.md` and `~/.claude/templates/architecture/DEEPENING.md` in full. Use **module / interface / seam / adapter / depth / leverage / locality** vocabulary throughout — do not substitute "component," "service," "API," or "boundary."

Arguments: `$ARGUMENTS` — optional ARC doc path and/or candidate number (e.g. `docs/active/2026-05/AB12CD-...-ARC-foo.md 3` or just `3`).

## Step 0b: Load structural context (if available)

After Step 0, check if `.understand/graph.json` exists. If yes and a task ID is available (from `.current-task` or the ARC's parent TSK), pull ranked context:

```bash
~/.claude/scripts/understand-explore.sh --json --for-task <TASK_ID>
```

Hold the top ~20 nodes as structural context. Most useful graph queries here: **the candidate node plus its 1-hop neighbors** (concrete files behind the seam) and **layer-crossing edges incident to those nodes** (where the leaky seam actually sits). This grounds Topics 3 (seam placement), 4 (what sits behind), and 7 (test-posture audit) in the real call graph rather than guessed file boundaries.

Skip silently if graph absent, no task ID, script errors, or empty result.

## Step 1: Run the script

```bash
~/.claude/scripts/arch-grill.sh --full [--arc-doc <path>] [--candidate <#>]
```

If the user gave an ARC path, pass `--arc-doc`. If a candidate number, pass `--candidate`.

Parse `RESULT` as JSON.

## Step 2: Check for resumable state

```bash
~/.claude/scripts/arch-grill.sh --json --load-state [--arc-doc <path>]
```

- If `next_action == "resume_grilling"`: summarize the prior decisions to the user, ask whether to continue or restart.
- If `next_action == "run_grilling_loop"`: start fresh.

## Step 3: The grilling loop

Walk the design tree with the user. For the chosen candidate, work through each topic **one at a time**, present 2-3 concrete approaches per topic with trade-offs, wait for the user, record the decision.

**Topics — address every one explicitly**:

1. **Friction restated** — confirm with the user the deletion-test verdict that flagged this candidate. If they disagree, the candidate dies here.
2. **Deepened module name** — must come from PROJECT-KNOWLEDGE.md. If the concept has no domain name yet, **stop and add it to PROJECT-KNOWLEDGE.md** (use the Edit tool) — same discipline as `/task-design`. Create the file if missing.
3. **Seam placement** — where does the interface live? Function/class/package/slice boundary?
4. **What sits behind the seam** — the internal structure hidden from callers. Internal seams permitted (used by the module's own tests); they do NOT get exposed.
5. **Dependency category** — classify per `DEEPENING.md`: in-process / local-substitutable / remote-but-owned / true-external. This determines test strategy.
6. **Adapter strategy** — **one adapter = hypothetical seam; two = real one.** Don't introduce a port without ≥2 justified adapters (typically production + test).
7. **Test posture audit (CURRENT coverage)** — before discussing what tests *should* exist, audit what *does* exist. Spawn an `Explore` subagent to find: (a) which `.spec` / `.test` files target the modules this candidate touches, (b) whether they assert observable outcomes through interfaces or just mock dependencies and assert call args, (c) any uncovered surface that the refactor would put at risk. Classify each touched module as 🟢 safe-to-refactor / 🟡 tests-exist-but-wrong-shape / 🔴 no-coverage. **This drives Topic 9 (migration shape)**: if any module is 🔴, the migration MUST include a test-prep phase before refactor. Capture the audit findings — they become the test-prep phase plan in the eventual PLN.
8. **Tests that survive** — interface-level tests describing observable outcomes. Map against Topic 7's audit: which existing specs continue to pass at the new seam without modification?
9. **Tests that get deleted** — old shallow-module unit tests rendered redundant. Map against Topic 7's audit: which 🟡 specs encode the old shape and must be rewritten or deleted?
10. **Migration shape** — how the refactor lands incrementally. Big-bang vs strangler. **Include test-prep phase if Topic 7 surfaced any 🔴 modules.** This topic is allowed to be Deferred-with-trigger if the test-prep work itself needs to discover something first (e.g., "after Phase 1 baseline coverage, decide between in-place rewrite and strangler").

**Checkpoint between topics** to make the session resumable:
```bash
~/.claude/scripts/arch-grill.sh --json --save-state --arc-doc "$ARC_DOC" \
  --candidate "$CANDIDATE_NUM" \
  --decisions '[{"topic":"seam-placement","choice":"...","rationale":"..."}, ...]'
```

## Step 4: Side effects (inline as decisions crystallize)

- **New domain term surfaced** → Edit `docs/architecture/PROJECT-KNOWLEDGE.md` to add it.
- **User rejects the candidate with a load-bearing reason** → Offer an ADR:
  _"Want me to record this as an ADR so future `/arch-explore` runs don't re-suggest it?"_
  Only offer when the reason would actually be needed by a future explorer. Skip ephemeral ("not worth it right now") and self-evident reasons.

  If they accept, pick a kebab-case slug and call:
  ```bash
  ~/.claude/scripts/arch-grill.sh --json --write-adr \
    --slug "<kebab-case-slug>" \
    --reason "<the load-bearing rationale, in quotes>"
  ```

## Step 5: Fill the Grilled Design section

When all topics resolved, **Edit** the ARC doc to fill the **Grilled Design** section for the chosen candidate. Include every topic above.

## Step 6: Commit

```bash
~/.claude/scripts/arch-grill.sh --json --commit
```

This stages: ARC doc, any ADR written, any PROJECT-KNOWLEDGE.md edits, doc-index updates.

## Completion Tracking

```bash
~/.claude/scripts/track-command.sh --command "arch-grill" --event complete \
  --model "MODEL_ID" \
  --complexity 3 \
  --tokens TOKENS_ESTIMATED \
  --cost COST_ESTIMATED
```
