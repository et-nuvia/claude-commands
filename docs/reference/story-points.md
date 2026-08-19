# Story Point Scoring (Asana `Score`)

> **Authority: the wiki.** `~/projects/wiki/patterns/story-point-scoring.md` is the
> canonical version of this rubric, and
> `~/projects/wiki/patterns/sprint-planning.md` covers the sprint process around it.
> This file is the in-repo working copy for commands that need it inline — if the
> two disagree, the wiki wins, and changes belong there first.

The single definition of the `Score` field used by `/task-capture` (set at creation)
and `/sprint-plan` (used for sprint capacity). Both must score the same way or
capacity math drifts from reality.

**Score is relative effort, not elapsed time.**

## Scale

| Score | Name | Definition |
|---|---|---|
| **1** | Trivial | A very small, straightforward change with an obvious implementation. Usually under an hour, little investigation or testing. |
| **2** | Small | A simple change that may need some investigation, several small edits, or basic testing. The solution is well understood; little uncertainty. |
| **3** | Moderate | A well-defined task involving several steps or components. Needs development, testing, and possibly minor debugging, but the approach is understood. |
| **5** | Medium | A meaningful task involving multiple components, non-trivial logic, or integration. Implementation, testing, possibly debugging. Some uncertainty about the best approach. |
| **8** | Large | A substantial task needing significant development effort. Often multiple components, complex logic, integrations, database changes, or several edge cases. Investigation and debugging likely. |
| **15** | Very Large | Complex, with significant scope, uncertainty, or technical complexity. Likely touches several areas and needs substantial implementation and testing. **Should be considered for decomposition.** |
| **25** | Epic | Very large or hard to estimate confidently. Major features, architectural changes, multiple integrations, or significant unknowns. **Should generally be broken down before being worked on.** |

## The core rule

**Do not score on estimated hours alone.** Weigh complexity, uncertainty, number
of systems/components affected, testing requirements, and risk.

Both of these are a **5**:

- a straightforward feature that takes 6 hours
- a 2-hour change against an unfamiliar third-party API with significant uncertainty

And conversely: work that takes 8 hours only because someone is unfamiliar with
the codebase is **not** automatically an 8 — score the underlying work, which may
be simple.

**15 and 25 are decomposition signals, not just bigger time estimates.** Reaching
for one is the scale telling you the task is not understood well enough to plan.
Prefer splitting it into scoreable pieces. This is the main benefit of a
Fibonacci scale — treat the gaps as a feature.

## Calibration — the AI overestimates

Measured across the closed work in four real repositories (104 tasks whose PLN
carried per-subtask estimates):

| Signal | Value |
|---|---|
| Median summed PLN estimate per task | **18 h** |
| Median active days per task (distinct days with commits) | **1** (p90: 2) |
| Implied hours per active day, if the estimate were true | **13.3 h** (p75: 24.5) |
| Tasks in flight concurrently | median **2**, p75 **5** |

An estimate implying 13–25 working hours *per calendar day* is not a real
estimate. Two effects compound:

1. **Baseline inflation.** Hour estimates in plans run roughly **3–5× high**.
2. **Parallel worktrees compress wall-clock.** With 2–5 tasks progressing at
   once, elapsed time per task is far below the summed effort, so any estimate
   validated against "how long did that take?" is validated against the wrong
   number.

### Applying the correction

- **Anchor on the observed median, not on hours.** The *typical* task in these
  repos — the one an AI plan calls 18 hours — is a single active session. That
  is a **3**, not an 8.
- **Divide instinctive hour estimates by 3–5 before mapping to a point value**,
  then sanity-check against the scale definitions rather than the arithmetic.
- **Never justify a score with wall-clock from a parallelized run.** Reported
  elapsed time under parallelization understates effort; reported plan hours
  overstate it. Score the work's shape instead: components touched,
  uncertainty, testing burden, risk.
- **Reserve 8 for genuinely substantial work.** If most tasks in a sprint come
  out at 8+, the scoring is inflated — recheck against the median-is-a-3 anchor.

### Observed throughput (for sprint capacity)

Recent two-week windows, tasks closed:

| Board shape | Tasks / 2 weeks (median) | Implied points @3 |
|---|---|---|
| One active repo, one board | ~15 | ~45 |
| Several repos sharing one board | ~6 | ~20 |

Set `sprint.capacity_points` per project from the observed number, and correct it
after each sprint against what actually completed. The default is 20 when unset.

## See also

- `~/projects/wiki/patterns/story-point-scoring.md` — **authoritative** rubric
- `~/projects/wiki/patterns/sprint-planning.md` — the sprint process
- `~/projects/wiki/decisions/relevance-separate-from-effort-score.md` — why relevance is a separate 1-10 score and why the fill is a knapsack
- [Task Management Guidelines](../task-management.md)
- `/sprint-plan` — consumes `Score` as sprint capacity
- `/task-capture` — sets `Score` at task creation
