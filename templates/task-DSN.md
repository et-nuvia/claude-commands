# Design: [Brief Description]

**Work Item**: [TASK_ID]
**Folder**: [FOLDER]
**Created**: [YYYY-MM-DD HH:MM]
**Type**: Design
**Related To**: [INC/TSK TASK_ID]

---

## Purpose

[What design decisions need to be made and why this document exists.]

## Context

**Related Issue**:
[Link to parent INC or TSK document]

**Background**:
[Relevant background from the TSK document — problem being solved, current state, and goals.]

**Constraints**:
- [Technical constraint 1]
- [Business constraint 1]
- [Time/scope constraint 1]

---

## Design Decisions

### Decision 1: [Title]

**Chosen Approach**: [What was decided]

**Rationale**: [Why this approach was selected — key factors that drove the decision]

### Decision 2: [Title]

**Chosen Approach**: [What was decided]

**Rationale**: [Why this approach was selected]

---

## Approaches Considered

### For Decision 1: [Title]

**Option A: [Name]**
- Description: [What this option entails]
- Pros: [Benefits]
- Cons: [Drawbacks]

**Option B: [Name]**
- Description: [What this option entails]
- Pros: [Benefits]
- Cons: [Drawbacks]

**Selected**: Option [A/B] — [One-sentence reason]

### For Decision 2: [Title]

**Option A: [Name]**
- Description: [What this option entails]
- Pros: [Benefits]
- Cons: [Drawbacks]

**Option B: [Name]**
- Description: [What this option entails]
- Pros: [Benefits]
- Cons: [Drawbacks]

**Selected**: Option [A/B] — [One-sentence reason]

---

## Deferred Decisions

> Decisions intentionally postponed. Each item MUST have a trigger — the investigation, measurement, or external event that unblocks it. Items without a trigger are unresolved questions and belong in the main Design Decisions section.
>
> Leave this section empty if every decision was resolved during the design session. The PLN generator reads this section: each deferred decision becomes an investigation subtask + a "revisit DSN" subtask in Phase 1.

### Deferred 1: [Title]

**Question**: [What decision is being deferred]

**Why deferred**: [e.g., "Need to measure current throughput before choosing cache strategy"]

**Trigger to resolve**: [What must happen before we can decide — e.g., "After Phase 1 investigation produces load profile data"]

**Candidates under consideration**: [Short list of options we're choosing between, if known]

### Deferred 2: [Title]

**Question**: [What decision is being deferred]

**Why deferred**: [Reason]

**Trigger to resolve**: [What unblocks this]

**Candidates under consideration**: [Options]

---

## Related Documents

```bash
find . -name "[TASK_ID]-*" | sort
```

- TSK: [TASK_ID-DATETIME-TSK-description.md] - Parent task
- PLN: [TASK_ID-DATETIME-PLN-description.md] - Implementation plan (will be created)
