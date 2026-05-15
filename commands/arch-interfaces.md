---
name: arch-interfaces
description: Explore alternative interfaces for a deepening candidate via parallel sub-agents — minimal, flexible, common-case-optimized, ports-and-adapters. Produces an opinionated recommendation.
user_invocable: true
---

## Tracking

> Output format is auto-detected (TOON for AI callers, JSON for CI/scripts). Use `--toon` or `--json` to override.

As your **first action**, before any other work, run:
```bash
~/.claude/scripts/track-command.sh --command "arch-interfaces" --event start
```

If the workflow encounters an unrecoverable error at any point, run:
```bash
~/.claude/scripts/track-command.sh --command "arch-interfaces" --event error \
  --model "MODEL_ID" \
  --error-msg "brief description of what failed"
```

You are an interface-design assistant applying Ousterhout's "Design It Twice." Use **model: opus**. The first idea is unlikely to be best — that's the point of the parallel fan-out.

## Relationship to the task system

The **Recommendation** you produce in the ARC seeds the interface portion of the eventual TSK's **DSN** when `/feature-to-task` later spins up a task for this candidate. Like `/arch-grill`, this command writes to the ARC document, NOT to a DSN — DSNs are created per-TSK by `/task-design` after `/feature-to-task` captures the work item.

Arguments: `$ARGUMENTS` — optional ARC doc path.

## Step 0: Load Architecture Language

Read `~/.claude/templates/architecture/LANGUAGE.md`, `~/.claude/templates/architecture/DEEPENING.md`, and `~/.claude/templates/architecture/INTERFACE-DESIGN.md` in full. Vocabulary discipline is the entire point: **module / interface / seam / adapter / depth / leverage / locality** in every output.

## Step 1: Run the script

```bash
~/.claude/scripts/arch-interfaces.sh --full [--arc-doc <path>]
```

Parse `RESULT` as JSON.

## Step 2: Verify prerequisites

- If `has_grilled == false`: stop. Tell the user to run `/arch-grill` first — interface design only makes sense after the deepened-module shape is grilled.
- Read `arc_body` to extract the grilled candidate's: name, files, seam placement, dependency category, what sits behind the seam.
- Read `docs/architecture/PROJECT-KNOWLEDGE.md` if `knowledge_present == true`. Sub-agents need its vocabulary.

## Step 3: Frame the problem space

Before spawning sub-agents, write a short user-facing explanation:
- Constraints the new interface must satisfy
- Dependency category (from `DEEPENING.md`)
- A rough illustrative code sketch to make constraints concrete — *not* a proposal

Show it to the user. Immediately proceed to Step 4 — the user reads while sub-agents work.

## Step 4: Spawn 3+ parallel sub-agents

Single message, multiple `Agent` tool uses (`subagent_type=general-purpose`). Each gets a **separate technical brief** w/ file paths, coupling details, dependency category, what sits behind the seam, LANGUAGE.md vocabulary, PROJECT-KNOWLEDGE.md vocabulary.

Different design constraint per agent:
- **Agent 1 — Minimal**: "Aim for 1–3 entry points max. Maximize leverage per entry point."
- **Agent 2 — Flexible**: "Support many use cases and extension."
- **Agent 3 — Common-case-optimized**: "Make the default caller's code trivial; advanced callers can pay more."
- **Agent 4 — Ports & adapters** (only if dependency category is *remote-but-owned* or *true-external*): "Design around ports & adapters for cross-seam dependencies. One adapter for production, one for testing — no port unless ≥2 adapters justified."

Each sub-agent must return:
1. Interface (types, methods, params + invariants, ordering, error modes)
2. Usage example showing caller code
3. What the implementation hides behind the seam
4. Dependency strategy and adapters (per DEEPENING.md)
5. Trade-offs — where leverage is high, where it's thin

## Step 5: Present + compare

Present each design **sequentially** so the user absorbs each. Then compare in prose by **depth** (leverage at interface), **locality** (where change concentrates), **seam placement**.

End with your **opinionated recommendation**: strongest design + why. If elements combine well, propose a hybrid. Be opinionated — the user wants a strong read, not a menu.

## Step 6: Fill the ARC doc

Use the Edit tool to fill the **Interface Alternatives** section (one block per design) and the **Recommendation** section.

## Step 7: Commit

```bash
~/.claude/scripts/arch-interfaces.sh --json --commit
```

After commit, point the user at `/feature-to-task` to spin up the TSK(s) from the recommendation — typically **one TSK per candidate** (closely-coupled candidates may be bundled). Each TSK's PLN will hold the phase structure (test prep, refactor, cutover, cleanup) as subtasks; do not propose creating multiple TSKs per candidate for those phases.

## Completion Tracking

```bash
~/.claude/scripts/track-command.sh --command "arch-interfaces" --event complete \
  --model "MODEL_ID" \
  --complexity 4 \
  --tokens TOKENS_ESTIMATED \
  --cost COST_ESTIMATED
```
