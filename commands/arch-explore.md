---
name: arch-explore
description: Discover codebase-wide architectural deepening candidates — shallow modules to consolidate, leaky seams, untestable surfaces. Produces an ARC document.
user_invocable: true
---

## Tracking

> Output format is auto-detected (TOON for AI callers, JSON for CI/scripts). Use `--toon` or `--json` to override.

As your **first action**, before any other work, run:
```bash
~/.claude/scripts/track-command.sh --command "arch-explore" --event start
```

If the workflow encounters an unrecoverable error at any point, run:
```bash
~/.claude/scripts/track-command.sh --command "arch-explore" --event error \
  --model "MODEL_ID" \
  --error-msg "brief description of what failed"
```

You are an architecture-discovery assistant. Use **model: opus** — this is judgement-heavy work.

The aim is **deepening opportunities** — refactors that turn shallow modules into deep ones. Testability + AI-navigability are the downstream goals; you are looking for friction, not style issues.

## Relationship to the task system

The **ARC document is a discovery artifact**, not a task. It lives alongside the TSK/DSN/PLN system but is distinct from it:

- An ARC may surface 1, 5, or 20 deepening candidates.
- A candidate becomes a TSK only after the user runs `/feature-to-task` (one TSK per candidate is the default; closely-coupled candidates may be bundled).
- The Grilled Design from `/arch-grill` seeds the resulting TSK's DSN (Resolved/Deferred Decisions) when `/feature-to-task` spins it up.
- Do not call `/task-capture` from this command. ARC creation is upstream of the task system.

## Step 0: Load Architecture Language

Before any exploration, read `~/.claude/templates/architecture/LANGUAGE.md` in full. The vocabulary it defines (**module / interface / implementation / depth / seam / adapter / leverage / locality / deletion test**) is mandatory in every candidate you propose. Do not substitute "component," "service," "API," or "boundary."

Also read `~/.claude/templates/architecture/DEEPENING.md` — you'll classify each candidate's dependencies by its categories.

## Step 1: Run the script

```bash
~/.claude/scripts/arch-explore.sh --full
```

Parse `RESULT` as JSON. Read `next_action` and proceed.

## Response Handling

### `spawn_explore_subagent`

The script returned the context needed. Now:

1. **Read `docs/architecture/PROJECT-KNOWLEDGE.md`** if `knowledge_present == true`. This is the project's domain glossary (= `CONTEXT.md` in the source skill). Use its vocabulary for domain concepts (e.g. "Order intake module," not "FooBarHandler"). If the file does not exist, surface this — propose creating one before exploring, since unnamed domain concepts produce vague candidates.

2. **Read every file in `adr_files`** (if non-empty). These are decisions you must not re-litigate. If a candidate contradicts an ADR, only surface it when friction is real enough to warrant revisiting — mark clearly: _"Contradicts ADR-NNNN — worth reopening because…"_

3. **Spawn an `Explore` subagent** to walk the codebase with these heuristics (verbatim from the skill):

   - Where does understanding one concept require bouncing between many small modules?
   - Where are modules **shallow** — interface nearly as complex as the implementation?
   - Where have pure functions been extracted just for testability, but the real bugs hide in how they're called (no **locality**)?
   - Where do tightly-coupled modules leak across their seams?
   - Which parts of the codebase are untested, or hard to test through their current interface?

   Apply the **deletion test** to anything you suspect is shallow: would deleting it concentrate complexity, or just move it? A "yes, concentrates" is the signal.

   Tell the subagent to return a markdown list of friction sites with file paths, brief problem statements, and a deletion-test verdict for each.

4. **Present a numbered list of deepening candidates to the user.** For each:
   - **Files / modules**: paths
   - **Problem**: why current arch causes friction (apply deletion test explicitly)
   - **Solution**: plain-English description of the deepened shape — no full interface design yet
   - **Dependency category**: per `DEEPENING.md` (in-process / local-substitutable / remote-but-owned / true-external)
   - **Benefits**: in terms of **leverage**, **locality**, and how tests improve
   - **ADR conflicts**: only if applicable

   Use PROJECT-KNOWLEDGE.md vocabulary for domain terms; LANGUAGE.md vocabulary for architecture terms. **Do not propose interfaces** — that's `/arch-interfaces`'s job.

5. **Ask the user**: "Which of these would you like to explore via `/arch-grill`?" Do not proceed past the list without confirmation.

6. **Create the ARC document**:
   ```bash
   ~/.claude/scripts/arch-explore.sh --json --create-doc --description "<short-slug>"
   ```
   Pick a short kebab-case slug summarizing the dominant theme (e.g. `intake-pipeline`, `auth-leakage`).

7. **Fill the template** at `arc_path` using the Write tool. Put every candidate into the **Deepening Candidates** section. Leave **Grilled Design**, **Interface Alternatives**, and **Recommendation** sections empty — those get filled by `/arch-grill` and `/arch-interfaces`.

8. **Commit**:
   ```bash
   ~/.claude/scripts/arch-explore.sh --json --commit
   ```

### `fix_error`

Something went wrong. Debug with:
```bash
~/.claude/scripts/arch-explore.sh --raw --full
```

## Completion Tracking

When the workflow completes successfully, run:
```bash
~/.claude/scripts/track-command.sh --command "arch-explore" --event complete \
  --model "MODEL_ID" \
  --complexity 3 \
  --tokens TOKENS_ESTIMATED \
  --cost COST_ESTIMATED
```
