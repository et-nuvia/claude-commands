---
name: feature-review
description: Review a specific function for implementation quality, improvements, and optimizations.
user_invocable: true
---

> **Output format is auto-detected: TOON when an AI agent is the caller, JSON for tests/CI.** This is intentional — TOON carries the same fields in far fewer tokens. `--json` does NOT switch an LLM caller to JSON, and that is not a bug to work around. Read the TOON fields directly; never pipe script output through `jq`, a converter, or `head`/`tail`/`grep` to "fix" the format.



# Feature Review

I will review a specific function and determine if everything is properly implemented, or if there are opportunities to improve or optimize it.

**Template**: `~/.claude/templates/feature/feature-review.md`
**Storage**: `docs/features/active/`
**Naming**: `[YYMMDDHHMM]-REV-[feature-name].md`

---

## 0. Load Project Knowledge (if available)

Check if `docs/architecture/PROJECT-KNOWLEDGE.md` exists. If it does, read it before analysis — it provides domain workflows, entity relationships, service maps, and business rules that help you evaluate whether a feature is correctly implemented against the actual business logic (not just code quality). Skip if it doesn't exist.

## 0b. Load Structural Context (if available)

After PROJECT-KNOWLEDGE.md, check if `.understand/graph.json` exists in cwd. If yes, derive a relevance source from the feature being reviewed (the file path, function name, or `$ARGUMENTS` keywords) and pull ranked context:

```bash
~/.claude/scripts/understand-explore.sh --json --search "<feature keywords or file path>"
```

Hold the top ~20 nodes as structural context. Most useful query for feature-review: **the connected subgraph of the feature** — the function's neighbors (callers + callees, 1–2 hops) reveal whether "completeness" gaps actually exist or whether the missing logic lives in an adjacent module. Skip silently if graph absent, no relevance source available, script errors, or empty result.

## 1. Scope Identification

**Identify the function to review**:
- Determine the function or file to analyze.
- Extract a clean "feature-name" for the filename.

---

## 2. Technical Analysis

Perform a deep dive into the function's implementation:
- **Completeness**: Requirements, error handling, edge cases.
- **Improvements**: Readability, maintainability, clean code.
- **Optimizations**: Bottlenecks, memory usage, algorithmic efficiency.

---

## 3. Report Generation

I will generate the review document directly to `docs/features/active/`.

**Naming Convention**:
1. Get current timestamp (YYMMDDHHMM).
2. Create filename: `docs/features/active/[YYMMDDHHMM]-REV-[feature-name].md`.

---

## 4. Next Steps

After creating the file, I will ask if you would like to:
- Turn specific recommendations into tasks using `/feature-to-task`.
- Perform a performance analysis using `/feature-performance`.
- Implement a refactor using `/feature-refactor`.

---

