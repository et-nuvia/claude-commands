---
command: arch-interfaces
group: architecture
backing_script: ~/.claude/scripts/arch-interfaces.sh
mutates: [git, files]
runtime: ~10-30min
destructive: false
requires_project_yaml: none
project_yaml_fields: []
requires_project_knowledge: optional
project_knowledge_sections:
  - "## Domain Glossary"
---

# /arch-interfaces

> Part of the [Architecture Review workflow](../08-workflows.md#architecture-review).

Applies Ousterhout's "Design It Twice" to a grilled deepening candidate by spawning 3–4 parallel sub-agents, each working under a different design constraint (minimal, flexible, common-case-optimized, ports-and-adapters). The results are compared, and an opinionated recommendation is written into the ARC document's **Interface Alternatives** and **Recommendation** sections. Must be run after `/arch-grill` — the grilled-candidate shape is the prerequisite.

> **Config:** PROJECT-KNOWLEDGE.md **optional** — reads `## Domain Glossary` so sub-agents use project vocabulary in their interface proposals.

---

## When to use it

- `/arch-grill` has filled the Grilled Design section of an ARC doc and you want concrete interface options before committing to an implementation
- The grilled candidate has a `true-external` or `remote-but-owned` dependency and you need a ports-and-adapters design evaluated alongside simpler alternatives
- You want a strong opinionated recommendation — not a menu — before creating the task via `/feature-to-task`

## Usage

```bash
/arch-interfaces [ARC_DOC_PATH]
```

**Common invocations:**

```bash
/arch-interfaces                                        # uses newest active ARC
/arch-interfaces docs/active/2026-05/AB12CD-...-ARC-foo.md   # explicit ARC path
```

## Arguments

| Argument / Flag | Required | Description |
|---|---|---|
| `$ARGUMENTS` (ARC path) | No | Path to the ARC document. Defaults to newest active ARC when omitted. |

## Dependencies

**External commands / packages** (must be on `PATH`):

| Dependency | Why it's needed | Install |
|---|---|---|
| `git` | Staging and committing updated ARC doc | preinstalled |
| `jq` | Parse script JSON output | `brew install jq` / `apt install jq` |

**Project files consumed:**

- `PROJECT.yaml` (PY) — No
- `PROJECT-KNOWLEDGE.md` (PK) — Optional. Located at `docs/architecture/PROJECT-KNOWLEDGE.md`. Read and passed to sub-agents for vocabulary. Not written by this command.
- `docs/active/**/*-ARC-*.md` — Required. Must have a filled **Grilled Design** section (verified by `has_grilled` flag). Auto-detected (newest) when not specified.
- `~/.claude/templates/architecture/LANGUAGE.md` — Required. Vocabulary lock-in.
- `~/.claude/templates/architecture/DEEPENING.md` — Required. Dependency category definitions passed to each sub-agent.
- `~/.claude/templates/architecture/INTERFACE-DESIGN.md` — Required. Interface design principles each sub-agent applies.

## Backing script

**Script**: `~/.claude/scripts/arch-interfaces.sh`

**Inputs:** `--arc-doc <path>` (optional, defaults to newest active ARC). `--json` / `--raw` for output mode override.

**Outputs (structured JSON):**

- `--full` → `next_action` ∈ {`spawn_subagents`, `fix_error`}, plus `arc_doc`, `arc_filename`, `task_id`, `arc_body`, `has_grilled` (boolean), `knowledge_doc`, `knowledge_present`, `language_template`, `deepening_template`, `interface_template`
- `--commit` → `next_action: "display_summary"`, `commit_hash`, `arc_doc`, `task_id`

**Invocation surface:**

```bash
~/.claude/scripts/arch-interfaces.sh --full [--arc-doc <path>]
~/.claude/scripts/arch-interfaces.sh --json --commit
~/.claude/scripts/arch-interfaces.sh --raw --full [--arc-doc <path>]   # debug
```

## How it works

1. **Load language** — reads `LANGUAGE.md`, `DEEPENING.md`, and `INTERFACE-DESIGN.md` to lock in vocabulary before spawning sub-agents.
2. **Run script (`--full`)** — returns the ARC body, `has_grilled` flag, PROJECT-KNOWLEDGE.md content flag, and all three template contents.
3. **Verify prerequisite** — if `has_grilled == false`, stop and tell the user to run `/arch-grill` first.
4. **Frame the problem space** — writes a short user-facing explanation of the constraints the interface must satisfy, the dependency category from the Grilled Design, and a rough illustrative code sketch (not a proposal). This is presented immediately; Step 5 runs while the user reads.
5. **Parallel sub-agents** — dispatched in a single message, each with the full technical brief (file paths, seam placement, dependency category, what sits behind the seam, all three templates, PROJECT-KNOWLEDGE.md vocabulary):
   - **Agent 1 — Minimal**: 1–3 entry points, maximum leverage per entry point
   - **Agent 2 — Flexible**: supports many use cases and extension points
   - **Agent 3 — Common-case-optimized**: default caller code is trivial; advanced callers pay more
   - **Agent 4 — Ports & adapters**: only when dependency category is `remote-but-owned` or `true-external`; requires ≥2 justified adapters
6. **Present + compare** — each design presented sequentially (interface, usage example, what's hidden behind seam, dependency strategy, trade-offs), then compared in prose by depth, locality, and seam placement.
7. **Opinionated recommendation** — a single strongest design (or justified hybrid) with explicit reasoning. Not a menu.
8. **Fill ARC doc** — edits the **Interface Alternatives** section (one block per design) and the **Recommendation** section.
9. **Commit** — calls `--commit` to stage and commit the updated ARC doc.

After commit, the command points the user at `/feature-to-task` to convert the ARC candidate into TSK(s). The Recommendation feeds the interface portion of the TSK's DSN.

## Example workflows

### Scenario: Complete ARC pipeline

```
/arch-explore           # produces ARC doc
/arch-grill 1           # fills Grilled Design section
/arch-interfaces        # fills Interface Alternatives + Recommendation
/feature-to-task        # converts ARC candidate to TSK with pre-filled DSN
```

### Scenario: Ports-and-adapters evaluation

```
/arch-grill 2           # grills a true-external dependency candidate
/arch-interfaces        # spawns 4 agents including ports-and-adapters agent
```

Four agents run in parallel; Agent 4 (ports-and-adapters) only appears when the dependency category warrants it.

### Scenario: Recommendation output

```
/arch-interfaces
```

```
Interface Alternatives — Order Intake Module
─────────────────────────────────────────────
Agent 1 (Minimal)
  intake(order: RawOrder): IntakeResult
  — single entry point; validation + parsing behind seam
  Trade-off: extension requires new params or overloads

Agent 2 (Flexible)
  IntakeBuilder.from(raw).withSchema(s).withTransforms(t).build()
  — highly composable; common case verbose
  Trade-off: caller must assemble pipeline; poor discoverability

Agent 3 (Common-case-optimized)
  intake(order: RawOrder, opts?: IntakeOptions): IntakeResult
  — simple default, opts escape hatch for advanced callers
  Trade-off: opts can become a dumping ground

Comparison by depth: Agent 1 and 3 have highest leverage per entry point.
Locality: all three concentrate mutation inside the module. Agent 2 leaks
assembly logic to callers.

Recommendation: Agent 3 — common-case-optimized. …
```

## Notes & gotchas

- Runs on **model: opus** — parallel sub-agents each do serious design work; Sonnet would produce shallower interfaces.
- **Prerequisite is hard-gated**: if the Grilled Design section is empty (`has_grilled == false`), the command stops immediately. Run `/arch-grill` first.
- The ports-and-adapters agent (Agent 4) is **only spawned** when the dependency category from the Grilled Design is `remote-but-owned` or `true-external`. In-process and local-substitutable candidates get three agents.
- Sub-agents are dispatched in **one parallel message** — wall-clock time is bounded by the slowest agent, not the sum.
- The Recommendation section in the ARC feeds the **interface portion** of the DSN that `/task-design` will create once `/feature-to-task` captures the work item. Do not call `/task-design` or `/task-capture` from this command.
- **If it fails:** verify the ARC doc has a filled Grilled Design section. Pass `--arc-doc <path>` explicitly if auto-detection picks the wrong file. Debug with `~/.claude/scripts/arch-interfaces.sh --raw --full`.
