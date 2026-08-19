# Research Decision Matrix: [Brief Description]

**Work Item**: [TASK_ID]
**Folder**: [FOLDER]
**Created**: [YYYY-MM-DD HH:MM]
**Type**: Research Decision Matrix
**Related To**: [TSK TASK_ID]
**Researcher**: [Researcher Name/Team]
**Status**: [Phase 0: Current State / Phase 1: Goal / Phase 2: Criteria & Scope / Phase 3: Research / Phase 4: Debate & Matrix / Complete]

---

## Executive Summary

> Fill this LAST, once the matrix and debate are done. One screen a decision-maker can act on.

**Recommended Outcome**: [The single recommended option/pattern/product]

**Why (tied to the end goal)**: [1-3 sentences linking the recommendation directly back to the stated end goal and constraints]

**Confidence**: [High / Medium / Low] — [one-line justification]

**Key Trade-off Accepted**: [What the recommendation gives up, and why that's acceptable]

**Decision Needed By**: [Date] · **Decision Maker**: [Name/Role]

---

## Phase 0 — Current State (Ground Truth)

> Establish **where we are** with REAL evidence BEFORE setting the goal or researching options. Every criterion, candidate score, and constraint below must be grounded in facts captured here — not assumptions. If a fact can't be confirmed, record it as an open question to verify (see Open Questions), never as a guess.

**How current state was captured** (tools/commands actually run — codebase and, where the decision touches live infra/data, the running system):
- [e.g. `project-context.sh --json --full`; `/understand-explore`; PROJECT.yaml]
- [e.g. live infra: `aws sts get-caller-identity`, `aws iam ... `, `kubectl get ...`, DB queries — name the exact commands so this is reproducible]

**Verified facts (where we are today)**:
| Fact | Value (observed) | Source / command | Date |
|------|------------------|------------------|------|
| [e.g. Account / environment] | [observed value] | [command run] | [YYYY-MM-DD] |
| [e.g. Current inventory / counts] | [observed value] | [command run] | [YYYY-MM-DD] |
| [e.g. Existing capability/config] | [observed value] | [command run] | [YYYY-MM-DD] |

**Current pain / gap** (what about this state is driving the decision): [1-3 sentences grounded in the facts above]

**Unknowns to verify** (could NOT be confirmed — carried to Open Questions, never guessed): [list, or "none"]

---

## Phase 1 — End Goal

> The anchor for everything below. The recommendation is judged ONLY by how well it serves this goal under the constraints. If this is vague, the matrix is meaningless — nail it down before proceeding.

**Goal Statement**: [One clear sentence: what outcome does making this decision produce?]

**Success looks like**:
- [Observable/measurable outcome 1]
- [Observable/measurable outcome 2]

**Explicitly NOT a goal** (anti-goals / out of scope):
- [What we are deliberately not optimizing for]

**Decision being made**: [e.g., "which message queue to adopt", "monorepo vs polyrepo", "build vs buy for auth"]

**Constraints** (hard limits the recommendation must respect):
| Constraint | Type | Detail |
|-----------|------|--------|
| [e.g. Budget] | Hard/Soft | [$X/mo ceiling] |
| [e.g. Timeline] | Hard/Soft | [must ship by DATE] |
| [e.g. Team skills] | Hard/Soft | [Python-only shop] |
| [e.g. Compliance] | Hard/Soft | [must be self-hostable] |
| [e.g. Licensing] | Hard | [no copyleft: GPL/LGPL/AGPL] |

---

## Phase 2 — Criteria & Scope

> Defines what goes in the matrix and how wide we cast the net. Locked in with the user BEFORE research begins so research is targeted, not open-ended.

### Research Breadth

**Unit of comparison**: [Products / Libraries / Architectural patterns / Vendors / Approaches — pick one and state it]

**Breadth vs depth decision**: [Broad survey of many candidates | Narrow deep-dive on a shortlist] — [why]

**Candidate set** (what will be researched in Phase 3):
- [Candidate 1]
- [Candidate 2]
- [Candidate 3]
- [...]

**Inclusion/exclusion rules**: [How a candidate qualifies for the matrix — e.g. "must be actively maintained (commit in last 6mo)", "must support self-hosting"]

### Evaluation Criteria (the matrix columns)

> Each criterion gets a weight. Weights sum to 100%. These come from the end goal + constraints, confirmed with the user.

| # | Criterion | Weight | What "good" means | Why it matters (→ which goal/constraint) |
|---|-----------|-------:|-------------------|------------------------------------------|
| 1 | [e.g. Performance] | 30% | [p95 < 50ms at target load] | [→ success outcome 1] |
| 2 | [e.g. Operational cost] | 20% | [< $X/mo all-in] | [→ budget constraint] |
| 3 | [e.g. Maturity/risk] | 20% | [stable release, large adopters] | [→ reliability goal] |
| 4 | [e.g. Team fit] | 15% | [matches existing stack] | [→ team-skills constraint] |
| 5 | [e.g. Extensibility] | 15% | [clean plugin/adapter seam] | [→ future goal] |
| | **Total** | **100%** | | |

**Scoring scale**: [e.g. 1-10, where 10 = fully meets "good", 1 = fails] — applied uniformly across all candidates.

---

## Phase 3 — Research Findings

> Extensive, evidence-backed research per candidate. This is the raw material the Phase 4 debate argues over. Every non-obvious claim carries a source. Prefer clean-extracted sources (see References). Multiple research agents may contribute; consolidate here.

### Candidate: [Candidate 1 Name]

**Snapshot**: [Provider/source] · **Version/Recency**: [latest version + date] · **License**: [type] · **Maturity**: [Stable/Beta/Experimental]

**Findings against each criterion**:
- **[Criterion 1]**: [Finding + evidence] `[source]`
- **[Criterion 2]**: [Finding + evidence] `[source]`
- **[Criterion 3]**: [Finding + evidence] `[source]`

**Notable facts / recency notes**: [Anything time-sensitive — recent releases, deprecations, funding/maintenance changes]

**Open unknowns**: [What couldn't be confirmed and why]

### Candidate: [Candidate 2 Name]

[Repeat structure]

### Candidate: [Candidate 3 Name]

[Repeat structure]

---

## Phase 4 — Adversarial Debate & Matrix

> Two adversarial reviewers argue the evidence from Phase 3: **Pro** builds the strongest case FOR the leading option(s); **Con** attacks it and champions alternatives. The debate surfaces hidden assumptions and stress-tests scores before they're locked into the matrix. Capture the exchange, then record where it landed.

### Debate Log

**Round 1 — [Topic / leading candidate]**
- 🟢 **Pro**: [Strongest argument in favor]
- 🔴 **Con**: [Strongest rebuttal / risk / alternative]
- ⚖️ **Resolution**: [Where it landed, and which criterion score(s) it affected]

**Round 2 — [Topic]**
- 🟢 **Pro**: [...]
- 🔴 **Con**: [...]
- ⚖️ **Resolution**: [...]

**Round 3 — [Topic]**
- 🟢 **Pro**: [...]
- 🔴 **Con**: [...]
- ⚖️ **Resolution**: [...]

**Points of consensus**: [What both sides agreed on]
**Unresolved disagreements**: [What remains contested → feeds Open Questions / Confidence]

### Decision Matrix (weighted)

> Scores reflect the debate outcome, not first-pass impressions. Weighted score = raw score × weight.

| Criterion (weight) | [Candidate 1] | [Candidate 2] | [Candidate 3] |
|--------------------|:-------------:|:-------------:|:-------------:|
| [Criterion 1] (30%) | [8] → 2.40 | [6] → 1.80 | [9] → 2.70 |
| [Criterion 2] (20%) | [6] → 1.20 | [9] → 1.80 | [4] → 0.80 |
| [Criterion 3] (20%) | [9] → 1.80 | [7] → 1.40 | [5] → 1.00 |
| [Criterion 4] (15%) | [8] → 1.20 | [6] → 0.90 | [7] → 1.05 |
| [Criterion 5] (15%) | [7] → 1.05 | [8] → 1.20 | [6] → 0.90 |
| **Weighted Total** | **7.65** | **7.10** | **6.45** |
| **Hard-constraint pass?** | ✅/❌ | ✅/❌ | ✅/❌ |

> Any candidate that fails a HARD constraint is disqualified regardless of score — note it and exclude it from the recommendation.

### Sensitivity Check

[Would the winner change if the top-weighted criterion were re-weighted? Is the lead robust or fragile? State it — a 0.1 gap is a coin flip, a 1.5 gap is decisive.]

---

## Recommendation

**Recommended**: [Option Name] — weighted score [X], all hard constraints [pass].

**Rationale (traced to the end goal)**:
1. [Reason tied to goal/criterion]
2. [Reason tied to goal/criterion]
3. [Reason tied to goal/criterion]

**Runner-up & when to prefer it**: [Option] — [the condition under which it would win, e.g. "if budget ceiling drops" or "if team adds Go expertise"]

**Rejected & why**: [Option] — [disqualifying reason]

**When to revisit this decision**: [Trigger condition that would invalidate the recommendation]

---

## Open Questions & Assumptions

**Unresolved** (from the debate):
1. ❓ [Question still open]

**Assumptions to validate before committing**:
1. [Assumption the recommendation rests on]

**Follow-up research needed**:
1. [Deeper investigation warranted, if any]

---

## References

> Cited inline above as `[source]`. Prefer clean-extracted markdown (trafilatura/crawl4ai), never raw HTML dumps.

- [Source 1]: [Title — URL — date accessed]
- [Source 2]: [Title — URL — date accessed]

---

## Related Documents

**For This Work Item** ([TASK_ID]):
- TSK: [TASK_ID-DATETIME-TSK-description.md] — Original task
- DSN: [TASK_ID-DATETIME-DSN-description.md] — Design decisions (if the recommendation feeds a design)
- PLN: [TASK_ID-DATETIME-PLN-description.md] — Implementation plan

[EXTERNAL_TRACKING_BLOCK]

---

**Research Completed**: [YYYY-MM-DD HH:MM]
**Status**: ✓ Research Decision Matrix Complete
