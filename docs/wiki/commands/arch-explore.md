---
command: arch-explore
group: architecture
backing_script: ~/.claude/scripts/arch-explore.sh
mutates: [git, files]
runtime: ~5-20min
destructive: false
requires_project_yaml: none
project_yaml_fields: []
requires_project_knowledge: optional
project_knowledge_sections:
  - "## Domain Glossary"
  - "## Architecture Decisions"
---

# /arch-explore

> Part of the [Architecture Review workflow](../08-workflows.md#architecture-review).

Walks the codebase looking for architectural friction — shallow modules, leaky seams, untestable surfaces — and produces a numbered list of deepening candidates for the user to review. The output is an **ARC document** committed to `docs/active/`, which serves as the upstream artifact for `/arch-grill` and `/arch-interfaces`. Nothing changes in production code; this is a discovery-only pass.

> **Config:** PROJECT-KNOWLEDGE.md **optional** — reads `## Domain Glossary` for domain vocabulary used to name candidates; reads `## Architecture Decisions` (ADR files in `docs/adr/`) to avoid re-litigating settled choices.

---

## When to use it

- The codebase has grown organically and you suspect structural friction without being able to name it precisely
- Tests are brittle or hard to write and you want to find out where the seams are wrong
- Before a large feature or migration, to surface refactor candidates worth grilling before they become load-bearing

## Usage

```bash
/arch-explore
```

**Common invocations:**

```bash
/arch-explore                   # default: explore entire codebase, produce ARC doc
```

## Arguments

None — invoke with no input.

## Dependencies

**External commands / packages** (must be on `PATH`):

| Dependency | Why it's needed | Install |
|---|---|---|
| `git` | Repo state, staging, committing the ARC doc | preinstalled |
| `jq` | Parse script JSON output | `brew install jq` / `apt install jq` |

**Project files consumed:**

- `PROJECT.yaml` (PY) — No
- `PROJECT-KNOWLEDGE.md` (PK) — Optional. Read at `docs/architecture/PROJECT-KNOWLEDGE.md`. Provides domain vocabulary for naming candidates; its absence is surfaced to the user with a prompt to create it before exploring.
- `docs/adr/*.md` — Optional. Decisions the exploration must not re-litigate.
- `~/.claude/templates/architecture/LANGUAGE.md` — Required. Defines the mandatory vocabulary (module, interface, seam, adapter, leverage, locality, deletion test).
- `~/.claude/templates/architecture/DEEPENING.md` — Required. Defines dependency categories used to classify each candidate.

## Backing script

**Script**: `~/.claude/scripts/arch-explore.sh`

**Inputs:** No CLI args for the main call. `--description <slug>` for doc creation; `--json` / `--raw` for output mode override.

**Outputs (structured JSON):**

- `--full` → `next_action` ∈ {`spawn_explore_subagent`, `fix_error`}, plus `knowledge_doc`, `knowledge_present`, `adr_dir`, `adr_files[]`, `language_template`, `deepening_template`, `branch`
- `--create-doc` → `next_action: "write_arc_doc"`, `arc_path`, `arc_filename`, `task_id`, `template` (ARC skeleton text)
- `--commit` → `next_action: "display_summary"`, `commit_hash`, `arc_path`, `arc_filename`, `task_id`

**Invocation surface:**

```bash
~/.claude/scripts/arch-explore.sh --full               # main: repo context for exploration
~/.claude/scripts/arch-explore.sh --json --create-doc --description "<slug>"   # create ARC skeleton
~/.claude/scripts/arch-explore.sh --json --commit      # stage + commit the filled ARC
~/.claude/scripts/arch-explore.sh --raw --full         # debug: bypass formatting
```

## How it works

1. **Load language** — reads `LANGUAGE.md` and `DEEPENING.md` to lock in vocabulary before any analysis.
2. **Run script (`--full`)** — returns repo context: git branch, path to PROJECT-KNOWLEDGE.md (if it exists), list of existing ADR files, and the template file contents.
3. **Read context** — LLM reads PROJECT-KNOWLEDGE.md (if present) for domain glossary; reads all ADR files to note settled decisions.
4. **Explore** — an `Explore` subagent walks the codebase with five heuristics (shallow modules, concept scatter, testability friction, seam leakage, deletion-test suspects) and returns a list of friction sites with file paths and problem statements.
5. **Present candidates** — LLM presents a numbered list with files, problem statement, deletion-test verdict, dependency category, and leverage/locality benefits. ADR conflicts are flagged explicitly. The user chooses which candidate(s) to grill next.
6. **Create ARC doc** — calls `--create-doc --description <slug>` to get the ARC path and skeleton template, then fills the **Deepening Candidates** section using the Write tool. **Grilled Design**, **Interface Alternatives**, and **Recommendation** sections are left empty for `/arch-grill` and `/arch-interfaces`.
7. **Commit** — calls `--commit` to stage and commit the ARC doc.

The ARC is a **discovery artifact**, not a task. Candidates become TSKs only after the user runs `/feature-to-task`. Do not call `/task-capture` from this command.

## Example workflows

### Scenario: Full architecture discovery chain

```
/arch-explore           # discover candidates → ARC doc
/arch-grill             # grill chosen candidate → Grilled Design section
/arch-interfaces        # design interfaces → Recommendation section
/feature-to-task        # convert ARC candidate into TSK(s)
```

Standard flow for a refactor initiative — exploration to implementation planning in four commands.

### Scenario: Exploration output

```
/arch-explore
```

```
Reading PROJECT-KNOWLEDGE.md … 3 domain terms loaded.
Reading ADRs … 2 decisions on file (ADR-0001, ADR-0002).
Exploring codebase …

Deepening Candidates
────────────────────
1. Order Intake Pipeline (src/intake/, src/parser/, src/validator/)
   Problem: Understanding an order requires tracing through 4 shallow modules;
            each module's interface is nearly as complex as its body. Deletion
            test: consolidating → concentrates complexity ✓
   Category: in-process
   Benefits: high leverage at single seam; bugs localised to intake module

2. Notification Adapter (src/notify/email.ts, src/notify/sms.ts, src/notify/index.ts)
   Problem: Two nearly-identical adapters with no shared seam; callers
            import both and manually fan-out. Deletion test: shared port → real seam ✓
   Category: true-external
   Benefits: enables swap + test doubles at port

3. Auth Middleware (src/middleware/auth.ts — 380 lines, 0 interface-level tests)
   Problem: Logic embedded in Express middleware; only mockable via HTTP layer.
   Category: in-process
   …

Which candidates would you like to explore via /arch-grill?
```

## Notes & gotchas

- Runs on **model: opus** — this command is judgement-heavy and costs accordingly.
- If PROJECT-KNOWLEDGE.md is absent, the command surfaces this before exploring and recommends creating it first — unnamed domain concepts produce vague candidates.
- The ARC document is committed on a **feature branch** (whatever branch you're currently on). If you're on `main`, create a branch first.
- **Relationship to task system**: ARC → `/arch-grill` → `/arch-interfaces` → `/feature-to-task` → TSK. The ARC is upstream of the task system; `/task-capture` is never called from here.
- **If it fails:** check that you're inside a git repo. Debug with `~/.claude/scripts/arch-explore.sh --raw --full` to see unformatted output.
