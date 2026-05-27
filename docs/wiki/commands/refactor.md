---
command: refactor
group: code-quality
backing_script: ~/.claude/scripts/refactor.sh
mutates: [files]
runtime: ~2-10min
destructive: false
requires_project_yaml: optional
project_yaml_fields:
  - testing.command
requires_project_knowledge: optional
project_knowledge_sections:
  - "## Architecture Decisions"
---

# /refactor

Guides a systematic, session-managed refactoring from analysis through validation. Produces a plan document, executes incremental changes with checkpoints, and verifies the result by running the project's test suite. Use Opus for complex structural decisions.

> **Config:** PROJECT.yaml optional — reads `testing.command` to run validation tests. PROJECT-KNOWLEDGE.md optional — reads `## Architecture Decisions` for service dependencies and integration flows.

---

## When to use it

- Code works but is hard to read, over-coupled, or duplicated
- A feature needs structural improvement before it can be safely extended
- You want a written plan and committed checkpoints rather than ad-hoc edits

## Usage

```bash
/refactor [scope]
```

**Common invocations:**

```bash
/refactor                          # full project or current directory
/refactor src/auth                 # limit to a path
/refactor "simplify payment flow"  # free-form scope description
```

## Arguments

| Argument / Flag | Required | Description |
|---|---|---|
| `$ARGUMENTS` | No | Files, directories, or free-form scope description. Passed to `refactor.sh --full`. |

## Dependencies

**External commands / packages** (must be on `PATH`):

| Dependency | Why it's needed | Install |
|---|---|---|
| `git` | Committing checkpoints during execution | preinstalled |
| `make` | Running tests via `make test` | `apt install make` |

**Project files consumed:**

- `PROJECT.yaml` (PY) — Optional. `testing.command` used to run validation.
- `PROJECT-KNOWLEDGE.md` (PK) — Optional. Architecture decisions read during analysis.
- `.understand/graph.json` — Optional. When present, the command runs `understand-explore.sh --search "$ARGUMENTS"` (or `--for-task` when a task is active) before the analyze/plan phases to compute the structural blast radius (forward + reverse edges of the targeted symbols). Skipped silently if absent.
- `refactor/plan.md` — created during the session; tracks progress and checklist.
- `refactor/state.json` — session state for resuming interrupted refactors.

## Backing script

**Script**: `~/.claude/scripts/refactor.sh`

**Inputs:** `--full [scope]`, plus individual stage flags. Reads `PROJECT.yaml` for test command.

**Outputs:** structured JSON on stdout with:
- `next_action` ∈ {`analyze_codebase`, `create_refactor_plan`, `execute_refactoring`, `validate_refactoring`, `display_summary`, `fix_error`}
- `refactor_dir` — path to session files (`refactor/`)
- On resume: `state.json` and `plan.md` are read directly by the LLM

**Invocation surface:**

```bash
~/.claude/scripts/refactor.sh --full "$ARGUMENTS"   # full pipeline
~/.claude/scripts/refactor.sh --json --analyze "$ARGUMENTS"
~/.claude/scripts/refactor.sh --json --plan
~/.claude/scripts/refactor.sh --json --execute
~/.claude/scripts/refactor.sh --json --validate
~/.claude/scripts/refactor.sh --json --status
~/.claude/scripts/refactor.sh --raw --analyze "$ARGUMENTS"  # debug
```

## How it works

1. **Analyze** — script returns session state and scope. LLM reads source files, documents structure and dependencies in `refactor/plan.md`, then calls `--plan`.
2. **Plan** — LLM writes a step-by-step plan with risk levels and validation steps for each change. Calls `--execute` when ready.
3. **Execute** — LLM applies changes with the Edit tool one logical step at a time, updates the plan checklist, and commits at milestones. Calls `--validate` when done.
4. **Validate** — tests run via `make test`. Behavior-preservation check. Plan updated with pass/fail. Summary returned to the user.

For feature-scoped refactors (`$ARGUMENTS` is a specific feature path), the command additionally creates a dedicated branch, establishes an E2E test baseline before touching code, and writes an RFA document to `docs/features/active/`.

## Example workflows

### Scenario: Targeted path refactor

```
/refactor src/payments
/git-commit "split into clean commits"
/create-pr
```

Isolate a messy module, get a plan, execute with checkpoints, then open a PR.

### Scenario: Resuming an interrupted session

```
/refactor
```

```
Resuming refactor session from refactor/state.json
Last checkpoint: step 3 of 7 — "Extract PaymentService interface"
Remaining: 4 steps
Continuing from step 4…
```

## Notes & gotchas

- The `refactor/` directory is created in the project root; add it to `.gitignore` if you do not want session files committed.
- Feature-scoped mode requires a dedicated branch — the command will create `refactor/<feature-name>` if not already on one.
- **If it fails during execute:** run `~/.claude/scripts/refactor.sh --raw --validate` to see test output directly. If tests fail, read `refactor/plan.md` to find the last successful checkpoint and revert to it.
- **If it fails during analyze:** run `~/.claude/scripts/refactor.sh --raw --analyze "$ARGUMENTS"` to inspect script output.
