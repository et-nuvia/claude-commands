# Interface Design

Parallel sub-agent pattern for exploring alternative interfaces for a chosen deepening candidate. Based on Ousterhout's "Design It Twice" — first idea unlikely to be best. Vocabulary from [LANGUAGE.md](LANGUAGE.md).

## Process

### 1. Frame the problem space

Before spawning sub-agents, write a user-facing explanation:
- Constraints any new interface must satisfy
- Dependencies it relies on + their category (see [DEEPENING.md](DEEPENING.md))
- Rough illustrative code sketch — not a proposal, just makes constraints concrete

Show to user, then proceed to Step 2 immediately. User reads while sub-agents work in parallel.

### 2. Spawn sub-agents

3+ sub-agents in parallel via the Agent tool. Each produces a **radically different** interface for the deepened module.

Each brief includes: file paths, coupling details, dependency category, what sits behind the seam, both LANGUAGE.md and PROJECT-KNOWLEDGE.md vocabulary so names stay consistent.

Different design constraint per agent:
- Agent 1: "Minimize the interface — 1–3 entry points max. Maximize leverage per entry point."
- Agent 2: "Maximize flexibility — support many use cases and extension."
- Agent 3: "Optimize for the most common caller — make the default case trivial."
- Agent 4 (if applicable): "Design around ports & adapters for cross-seam dependencies."

Each sub-agent outputs:
1. Interface (types, methods, params + invariants, ordering, error modes)
2. Usage example showing caller code
3. What the implementation hides behind the seam
4. Dependency strategy and adapters (per DEEPENING.md)
5. Trade-offs — where leverage is high, where it's thin

### 3. Present and compare

Present designs sequentially so the user absorbs each. Then compare in prose — contrast by **depth** (leverage at interface), **locality** (where change concentrates), **seam placement**.

End with your own opinionated recommendation: strongest design + why. If elements combine well, propose a hybrid. The user wants a strong read, not a menu.

## Source

Adapted from `mattpocock/skills/skills/engineering/improve-codebase-architecture/INTERFACE-DESIGN.md`.
