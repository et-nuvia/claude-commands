---
name: feature-refactor
description: Analyze a feature for refactoring opportunities to improve stability, scalability, and simplicity.
user_invocable: true
---

> **Output format is auto-detected: TOON when an AI agent is the caller, JSON for tests/CI.** This is intentional — TOON carries the same fields in far fewer tokens. `--json` does NOT switch an LLM caller to JSON, and that is not a bug to work around. Read the TOON fields directly; never pipe script output through `jq`, a converter, or `head`/`tail`/`grep` to "fix" the format.



# Feature Refactor Analysis

I will review a feature to identify opportunities where a refactor could optimize the code, make it more stable, scalable, or simpler.

**CRITICAL: Safety & Isolation Requirements**
1. **Branching**: All refactoring work MUST be performed in a dedicated feature branch. I will never refactor directly on the main development branch.
2. **Baseline Testing**: Before any code is modified, I will ensure comprehensive E2E tests are in place and passing:
   - **UI**: Playwright tests
   - **Backend**: Newman (Postman) tests
3. **Verification**: These tests will serve as the "gold standard" to ensure no behavioral regressions occur during the refactor.

**Template**: `~/.claude/templates/feature/feature-refactor.md`
**Storage**: `docs/features/active/`
**Naming**: `[YYMMDDHHMM]-RFA-[feature-name].md`

---

## 0. Load Project Knowledge (if available)

Check if `docs/architecture/PROJECT-KNOWLEDGE.md` exists. If it does, read it before analysis — it maps service dependencies, entity relationships, and integration flows that are critical for safe refactoring (e.g., knowing ClearanceService depends on DisqualificationService, or that patient status changes trigger Zoho outbound sync). Skip if it doesn't exist.

## 0b. Load Structural Context (if available)

After PROJECT-KNOWLEDGE.md, check if `.understand/graph.json` exists in cwd. If yes, derive a relevance source from the feature being refactored (file path, function name, or `$ARGUMENTS` keywords) and pull ranked context:

```bash
~/.claude/scripts/understand-explore.sh --json --search "<feature keywords or file path>"
```

Hold the top ~20 nodes as structural context. Most useful query for refactor analysis: **the connected subgraph of the feature** — callers (reverse-edges) define the migration risk surface, and callees (forward edges) show what must stay invariant. Use this to estimate refactor blast radius before proposing an Optimization/Stability/Scalability/Simplicity pillar change. Skip silently if graph absent, no relevance source, script errors, or empty result.

## 1. Feature Discovery & Setup

- Identify the core "feature-name" for the filename.
- **Branch Check**: Ensure we are on a dedicated feature branch. If not, I will offer to create one.
- **Test Baseline**: Identify or create Playwright (UI) and Newman (Backend) E2E tests.
- **Initial Run**: Run all E2E tests and confirm they pass before starting analysis.

---

## 2. Refactoring Assessment

Evaluate across four pillars:
- **Optimization**: Redundancy, inefficiency.
- **Stability**: Error handling, validation, type safety.
- **Scalability**: Bottlenecks, decoupling, async opportunities.
- **Simplicity**: Complexity reduction, design patterns.

---

## 3. Report Generation

I will generate the refactor analysis document directly to `docs/features/active/`.

**Naming Convention**:
1. Get current timestamp (YYMMDDHHMM).
2. Create filename: `docs/features/active/[YYMMDDHHMM]-RFA-[feature-name].md`.

---

## 4. Next Steps

After creating the file, I will ask if you would like to:
- Turn specific refactoring steps into tasks using `/feature-to-task`.
- Run a performance baseline using `/feature-performance`.
- **Execute**: Begin the refactor on this branch, starting with the baseline tests.

---

