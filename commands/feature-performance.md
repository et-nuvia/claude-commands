---
name: feature-performance
description: Analyze a feature for performance bottlenecks, resource usage, and scalability.
user_invocable: true
---

## Tracking

As your **first action**, before any other work, run:
```bash
~/.claude/scripts/track-command.sh --command "feature-performance" --event start
```

If the workflow encounters an unrecoverable error at any point, run:
```bash
~/.claude/scripts/track-command.sh --command "feature-performance" --event error \\
  --model "MODEL_ID" \\
  --error-msg "brief description of what failed"
```
# Feature Performance Analysis

I will analyze a feature for performance bottlenecks, resource usage, and scalability opportunities.

**Template**: `~/.claude/templates/feature/feature-performance.md`
**Storage**: `docs/features/active/`
**Naming**: `[YYMMDDHHMM]-PERF-[feature-name].md`

---

## 0. Load Project Knowledge (if available)

Check if `docs/architecture/PROJECT-KNOWLEDGE.md` exists. If it does, read it before analysis — it documents data flows, integration patterns (queue throughput, API rate limits), entity relationships (for N+1 query identification), and the async processing architecture (Celery, BullMQ, Redis). Skip if it doesn't exist.

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

## Completion Tracking

When the workflow completes successfully, run:
```bash
~/.claude/scripts/track-command.sh --command "feature-performance" --event complete \
  --model "MODEL_ID" \
  --complexity COMPLEXITY \
  --tokens TOKENS_ESTIMATED \
  --cost COST_ESTIMATED
```

Replace values before calling:
- `MODEL_ID` — the model currently in use (from system context, e.g., `claude-sonnet-4-6`)
- `COMPLEXITY` — 1-5 based on: 1=read-only analysis, 2=single-file/simple git, 3=multi-file feature,
  4=cross-system/staging deploy, 5=production/infrastructure/security
- `TOKENS_ESTIMATED` — rough estimate of context used (input + output tokens combined)
- `COST_ESTIMATED` — approximate cost in USD based on model pricing