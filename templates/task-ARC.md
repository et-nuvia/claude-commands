# Architecture Review: [Brief Description]

- **Work Item**: [TASK_ID]
- **Created**: [YYYY-MM-DD HH:MM]
- **Folder**: [FOLDER]
- **Type**: ARC (Architecture Review — Deepening Candidates)
- **Status**: Active

## Source

- `/arch-explore` discovery pass
- Domain context: `docs/architecture/PROJECT-KNOWLEDGE.md`
- ADRs consulted: `docs/adr/`

## Heuristics applied

From `~/.claude/templates/architecture/LANGUAGE.md`:
- **Deletion test** — would deleting the module concentrate or just move complexity?
- **Shallow modules** — interface ≈ implementation; little behaviour hidden behind the seam
- **Pure-functions-without-locality** — extracted for testability but the real bugs live in the callers
- **Leaky seams** — tightly-coupled modules leaking implementation details across interfaces
- **Untestable through current interface** — tests reach past the seam

## Deepening Candidates

> Each candidate uses PROJECT-KNOWLEDGE.md vocabulary for the domain and LANGUAGE.md vocabulary for the architecture.

### 1. [Candidate name — domain term, not "FooBarHandler"]

- **Files / modules**: `path/to/file.py`, `path/to/other.py`
- **Problem**: [Why current architecture causes friction. Apply the deletion test explicitly.]
- **Solution**: [Plain-English description of the deepened shape. What the new module's interface looks like at a sketch level — no full design yet.]
- **Dependency category**: [in-process / local-substitutable / remote-but-owned / true-external — see DEEPENING.md]
- **Benefits**:
  - *Leverage*: [what callers gain]
  - *Locality*: [where change/bugs concentrate after the refactor]
  - *Tests*: [how the test surface improves]
- **ADR conflicts**: [None, or: "Contradicts ADR-NNNN — worth reopening because…"]

### 2. [Next candidate]

[…repeat structure…]

---

## Grilled Design

> Populated by `/arch-grill <ARC-doc> <candidate#>`. One section per candidate the user chose to grill.

### Candidate [#]: [name]

- **Constraints surfaced during grilling**:
  - […]
- **Deepened module shape**: [name + concept it represents]
- **Seam placement**: [where the interface lives]
- **What sits behind the seam**: [internal structure hidden from callers]
- **Dependency strategy**: [from DEEPENING.md]
- **Adapters required**: [list — remember: one adapter = hypothetical seam]
- **Tests that survive**: [interface-level tests describing observable outcomes]
- **Tests that get deleted**: [old shallow-module unit tests rendered redundant]
- **Domain vocabulary added to PROJECT-KNOWLEDGE.md**: [terms added during grilling, or "None"]
- **ADRs written**: [ADR-NNNN if user rejected w/ load-bearing reason, or "None"]

---

## Interface Alternatives

> Populated by `/arch-interfaces <ARC-doc>`. Parallel sub-agent designs per `INTERFACE-DESIGN.md`.

### Design A: [name — e.g., "Minimal Interface"]

- **Interface**: [types/methods + invariants, ordering, error modes]
- **Usage example**: [caller-side code]
- **Hidden behind seam**: […]
- **Dependency strategy & adapters**: […]
- **Trade-offs**: [leverage strengths + thin spots]

### Design B: [name — e.g., "Maximally Flexible"]

[…]

### Design C: [name — e.g., "Common-Case-Optimized"]

[…]

---

## Recommendation

> Populated by `/arch-interfaces`. Opinionated pick or hybrid.

**Selected design**: [A / B / C / hybrid]

**Reasoning**: [Contrast by depth, locality, seam placement. Why this one wins.]

**Next step**: Run `/feature-to-task <this-doc>` to spawn implementation TSKs.

---

## Status Log

- `[YYYY-MM-DD HH:MM]` — Created by `/arch-explore`
