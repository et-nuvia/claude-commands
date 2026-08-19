---
name: feature-performance
description: Analyze a feature for performance bottlenecks, resource usage, and scalability.
user_invocable: true
---

> **Output format is auto-detected: TOON when an AI agent is the caller, JSON for tests/CI.** This is intentional — TOON carries the same fields in far fewer tokens. `--json` does NOT switch an LLM caller to JSON, and that is not a bug to work around. Read the TOON fields directly; never pipe script output through `jq`, a converter, or `head`/`tail`/`grep` to "fix" the format.



# Feature Performance Analysis

I will analyze a feature for performance bottlenecks, resource usage, and scalability opportunities.

**Template**: `~/.claude/templates/feature/feature-performance.md`
**Storage**: `docs/features/active/`
**Naming**: `[YYMMDDHHMM]-PERF-[feature-name].md`

---

## 0. Load Project Knowledge (if available)

Check if `docs/architecture/PROJECT-KNOWLEDGE.md` exists. If it does, read it before analysis — it documents data flows, integration patterns (queue throughput, API rate limits), entity relationships (for N+1 query identification), and the async processing architecture (Celery, BullMQ, Redis). Skip if it doesn't exist.

## 0b. Load Structural Context (if available)

After PROJECT-KNOWLEDGE.md, check if `.understand/graph.json` exists in cwd. If yes, derive a relevance source from the feature being analyzed (file path, function name, or `$ARGUMENTS` keywords) and pull ranked context:

```bash
~/.claude/scripts/understand-explore.sh --json --search "<feature keywords or file path>"
```

Hold the top ~20 nodes as structural context. Most useful query for performance analysis: **the connected subgraph of the feature** — the call chain depth (forward edges from the entry point) is where latency accumulates, and high fan-in (reverse edges) marks hotspots called from many places. Use this to focus the bottleneck hunt on real hot paths rather than speculative ones. Skip silently if graph absent, no relevance source, script errors, or empty result.

## 1. Performance Discovery

- Identify the function or feature to analyze.
- Determine if benchmarks or performance tests exist in the project.

---

## 2. Analysis Phase

Perform deep analysis on:
- **Bottlenecks**: High-latency operations or CPU hotspots.
- **Resource Usage**: Memory allocations, DB I/O, Network overhead.
- **Scalability**: How the feature behaves under increased load.

---

## 3. Report Generation

I will generate the performance analysis document directly to `docs/features/active/`.

**Naming Convention**:
1. Get current timestamp (YYMMDDHHMM).
2. Create filename: `docs/features/active/[YYMMDDHHMM]-PERF-[feature-name].md`.

---

## 4. Next Steps

After creating the file, I will ask if you would like to:
- Convert optimization recommendations into tasks using `/feature-to-task`.
- Review the implementation details using `/feature-review`.

---

