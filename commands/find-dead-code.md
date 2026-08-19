---
name: find-dead-code
description: Search for, analyze, and safely remove dead code with mandatory E2E test verification.
user_invocable: true
---

> **Output format is auto-detected: TOON when an AI agent is the caller, JSON for tests/CI.** This is intentional — TOON carries the same fields in far fewer tokens. `--json` does NOT switch an LLM caller to JSON, and that is not a bug to work around. Read the TOON fields directly; never pipe script output through `jq`, a converter, or `head`/`tail`/`grep` to "fix" the format.



# Dead Code Analysis & Removal

I will search for dead code (unused functions, exports, or unreachable logic), verify functional integrity with E2E tests, and safely remove it.

**Template**: `~/.claude/templates/feature/dead-code-removal.md`
**Storage**: `docs/features/active/`
**Naming**: `[YYMMDDHHMM]-DEAD-[symbol-name].md`

---

## 0. Load Structural Context (if available)

Before scanning, check if `.understand/graph.json` exists in cwd. If yes, pull ranked context — use a task-scoped load when `.current-task` is set, otherwise a broad search over `$ARGUMENTS` (or skip if neither is available):

```bash
~/.claude/scripts/understand-explore.sh --json --for-task <TASK_ID>
# or:
~/.claude/scripts/understand-explore.sh --json --search "$ARGUMENTS"
```

Hold the top ~20 nodes as structural context for the discovery phase. Most useful query for dead-code hunting: **"no incoming edges" as a graph query** — nodes with zero reverse-edges are prime dead-code candidates, modulo entry points (CLI mains, route handlers, framework hooks) that are called from outside the graph. Use this list as the seed; verify each via the normal scan + E2E baseline before deleting. Skip silently if graph absent, no relevance source, script errors, or empty result.

---

## 1. Discovery Phase

I will scan the codebase for:
- **Unused Exports**: Exported symbols that are not imported anywhere else in the project.
- **Uncalled Methods**: Private or internal functions that have no call sites.
- **Unreachable Logic**: Code blocks following `return`, `throw`, or `break` statements that can never be executed.
- **Dangling Dependencies**: Files that are no longer imported by the entry point or other active files.

---

## 2. Context & Risk Analysis

For each candidate:
1. Determine the original purpose and feature relationship.
2. Identify existing **Playwright (UI)** or **Newman (Backend)** tests that cover the area this code was part of.

---

## 3. Mandatory Testing Workflow

Before deleting any code:
1. **Check Coverage**: If no Playwright or Newman tests cover the relevant functionality, I will **create them first**.
2. **Establish Baseline**: Run the tests to confirm the software works as expected with the code present.
3. **Execution**: Delete the code in a dedicated branch.
4. **Final Verification**: Run the tests again to confirm the software still works perfectly after the removal.

---

## 4. Report Generation

I will generate a dead-code-removal document to `docs/features/active/`.

---

## 5. Next Steps

After the analysis, I will ask:
- "Should I create the missing E2E tests now?"
- "Proceed with the removal on a new branch?"
- "Run a full suite to ensure no side effects?"

---

