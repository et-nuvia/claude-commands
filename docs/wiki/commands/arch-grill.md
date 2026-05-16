---
command: arch-grill
group: architecture
backing_script: ~/.claude/scripts/arch-grill.sh
mutates: [git, files]
runtime: ~15-45min
destructive: false
requires_project_yaml: none
project_yaml_fields: []
requires_project_knowledge: optional
project_knowledge_sections:
  - "## Domain Glossary"
---

# /arch-grill

Takes a deepening candidate from an ARC document and walks every design decision with you — seam placement, dependency category, adapter strategy, test posture, migration shape — one topic at a time. The result is a **Grilled Design** section filled into the ARC, which seeds a future task's DSN when `/feature-to-task` converts the candidate into a TSK. As a side effect, new domain terms are added to PROJECT-KNOWLEDGE.md and rejected candidates may produce ADR files.

> **Config:** PROJECT-KNOWLEDGE.md **optional** — reads `## Domain Glossary` for domain vocabulary when naming the deepened module; **writes** new terms back inline when a concept surfaces that has no name yet.

---

## When to use it

- You have an ARC document with at least one deepening candidate and want to commit to a design direction before implementing
- You want to surface the test-coverage gaps (🔴 / 🟡 / 🟢) that a refactor would put at risk, so the migration plan includes a test-prep phase
- You are about to reject a candidate for a load-bearing reason and want to record it as an ADR so future `/arch-explore` runs don't re-suggest it

## Usage

```bash
/arch-grill [ARC_DOC_PATH] [CANDIDATE_NUMBER]
```

**Common invocations:**

```bash
/arch-grill                              # uses newest active ARC, prompts for candidate
/arch-grill 3                            # candidate #3 from newest active ARC
/arch-grill docs/active/2026-05/AB12CD-...-ARC-foo.md 2   # explicit ARC + candidate
```

## Arguments

| Argument / Flag | Required | Description |
|---|---|---|
| `$ARGUMENTS` (ARC path) | No | Path to the ARC document. Defaults to the newest active ARC when omitted. |
| `$ARGUMENTS` (candidate #) | No | Candidate number from the ARC's Deepening Candidates section. Prompted interactively when omitted. |

## Dependencies

**External commands / packages** (must be on `PATH`):

| Dependency | Why it's needed | Install |
|---|---|---|
| `git` | Staging and committing the updated ARC, ADR files, and PROJECT-KNOWLEDGE.md | preinstalled |
| `jq` | Parse and write grilling state JSON | `brew install jq` / `apt install jq` |

**Project files consumed:**

- `PROJECT.yaml` (PY) — No
- `PROJECT-KNOWLEDGE.md` (PK) — Optional, read and written. Located at `docs/architecture/PROJECT-KNOWLEDGE.md`. New domain terms are added here inline during grilling.
- `docs/active/**/*-ARC-*.md` — Required. The ARC document produced by `/arch-explore`. Auto-detected (newest) when not specified.
- `docs/adr/` — Written when user rejects a candidate with a load-bearing reason.
- `.arch-grill-state.json` — Checkpoint file written by `--save-state`, read by `--load-state` to resume interrupted sessions.
- `~/.claude/templates/architecture/LANGUAGE.md` — Required. Vocabulary lock-in before grilling begins.
- `~/.claude/templates/architecture/DEEPENING.md` — Required. Dependency category definitions used in Topic 5.

## Backing script

**Script**: `~/.claude/scripts/arch-grill.sh`

**Inputs:** `--arc-doc <path>` (optional, defaults to newest active ARC), `--candidate <#>` (optional), `--decisions '<json>'` for save-state, `--slug <slug>` + `--reason '<reason>'` for ADR creation.

**Outputs (structured JSON):**

- `--full` → `next_action` ∈ {`run_grilling_loop`, `fix_error`}, plus `arc_doc`, `arc_filename`, `task_id`, `arc_body`, `knowledge_doc`, `knowledge_present`, `has_state`, `state_file`, `candidate`, `language_template`, `deepening_template`
- `--load-state` → `next_action` ∈ {`resume_grilling`, `run_grilling_loop`}, with prior decisions when resuming
- `--save-state` → confirmation JSON with `arc_doc`, `task_id`, `candidate`, `file`
- `--write-adr` → `next_action: "display_summary"`, `adr_path`, `number`, `slug`, `arc_doc`
- `--commit` → `next_action: "display_summary"`, `commit_hash`, `arc_doc`, `task_id`

**Invocation surface:**

```bash
~/.claude/scripts/arch-grill.sh --full [--arc-doc <path>] [--candidate <#>]
~/.claude/scripts/arch-grill.sh --json --load-state [--arc-doc <path>]
~/.claude/scripts/arch-grill.sh --json --save-state --arc-doc <path> --candidate <#> --decisions '<json>'
~/.claude/scripts/arch-grill.sh --json --write-adr --slug <slug> --reason '<reason>'
~/.claude/scripts/arch-grill.sh --json --commit
~/.claude/scripts/arch-grill.sh --raw --full [--arc-doc <path>]   # debug
```

## How it works

1. **Load language** — reads `LANGUAGE.md` and `DEEPENING.md` to enforce vocabulary throughout the session.
2. **Run script (`--full`)** — returns the ARC document body, candidate list, PROJECT-KNOWLEDGE.md path and content flag, and whether a checkpoint state file exists.
3. **Check for resumable state** — calls `--load-state`; if prior decisions are on file, summarizes them for the user and asks whether to continue or restart.
4. **Grilling loop** — ten topics addressed one at a time, waiting for user input before moving on: friction restatement → deepened module name → seam placement → what's behind the seam → dependency category → adapter strategy → test posture audit (spawns an `Explore` subagent to classify touched modules as 🟢/🟡/🔴) → tests that survive → tests that get deleted → migration shape.
5. **Checkpointing** — calls `--save-state` between topics to make the session resumable if interrupted.
6. **Side effects inline** — new domain terms are edited into PROJECT-KNOWLEDGE.md immediately when surfaced; ADR files are written via `--write-adr` when a candidate is rejected with a load-bearing reason.
7. **Fill Grilled Design** — when all topics resolve, edits the ARC document's **Grilled Design** section with every topic's decision.
8. **Commit** — calls `--commit` to stage the ARC, any ADR written, any PROJECT-KNOWLEDGE.md edits, and doc-index updates.

The Grilled Design is a **pre-task design artifact**. It seeds the TSK's DSN (Design) when `/feature-to-task` later spins up the task — resolved topics become DSN Resolved Decisions; deferred-with-trigger topics become Deferred Decisions and drive investigation subtasks in the PLN.

## Example workflows

### Scenario: Grill → interfaces → task

```
/arch-explore           # produces ARC doc with candidates
/arch-grill 1           # grill candidate #1
/arch-interfaces        # design interfaces for grilled candidate
/feature-to-task        # convert to TSK with pre-filled DSN
```

### Scenario: Resume an interrupted session

```
/arch-grill             # detects .arch-grill-state.json, offers to resume
```

The command summarizes decisions already recorded, asks whether to continue from the last checkpoint or restart.

### Scenario: Grilling in progress — test posture audit output

```
/arch-grill 2
```

```
Topic 7 — Test Posture Audit
────────────────────────────
Explored: src/intake/, src/parser/, src/validator/

  src/intake/index.ts         🔴 no coverage
  src/parser/order-parser.ts  🟡 tests exist but assert call args, not outcomes
  src/validator/schema.ts     🟢 safe — 14 interface-level tests

Consequence: migration MUST include a test-prep phase before refactor.
Phase 1 (test prep): write interface-level coverage for intake and parser.
Phase 2 (refactor): consolidate under deepened module.

Proceed to Topic 8 — Tests that survive?
```

## Notes & gotchas

- Runs on **model: opus** — the grilling loop is deliberate and conversation-heavy; Sonnet would underweight trade-offs.
- **One candidate per session.** If multiple candidates need grilling, run the command once per candidate.
- New domain terms are written to PROJECT-KNOWLEDGE.md **during the session**, not at the end. If you abort mid-session, terms already added remain — the checkpoint state lets you resume without re-discovering them.
- ADR creation is only offered when rejection has a **load-bearing reason** a future explorer would need. Ephemeral reasons ("not worth it right now") don't warrant an ADR.
- **Relationship to task system**: Grilled Design → ARC. DSN is created per-TSK by `/task-design` after `/feature-to-task`. Do not call `/task-design` or `/task-capture` from this command.
- **If it fails:** if the ARC doc can't be located, pass `--arc-doc <path>` explicitly. Debug with `~/.claude/scripts/arch-grill.sh --raw --full` to see unformatted script output.
