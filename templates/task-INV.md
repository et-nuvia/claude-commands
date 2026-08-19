# Investigation: [Brief Description]

**Work Item**: [TASK_ID]
**Folder**: [FOLDER]
**Created**: [YYYY-MM-DD HH:MM]
**Type**: Investigation Report
**Related To**: [TSK/INC TASK_ID]

---

## Verdict

**Outcome**: [ROOT CAUSE CONFIRMED / LEADING THEORY (UNPROVEN) / NO DEFECT FOUND]

[1-2 sentence bottom line. If a cause is confirmed, name it. If only a theory, say so and name what evidence is still missing. If no defect was found, say so plainly — this is a valid outcome, not a failure to investigate.]

---

## Problem Statement

**Reported symptom**:
[What was reported, by whom, and how it manifests]

**Scope investigated**:
- [Area / code path / system 1]
- [Area / code path / system 2]

---

## What Was Checked

**Code paths traced**:
- `path/to/file.ext:line` — [what it does and what the trace showed]

**Production checks** (only if performed — read-only, PHI-safe):
- [Endpoint / SSM command / read-only query] → [result observed]
- [If production was NOT checked, state why: not needed / not accessible / no documented access]

**Methods used**:
- [e.g., call-chain trace, log review, read-only DB query, health endpoint]

---

## Findings

> Every finding MUST be classified. **CONFIRMED** = backed by direct code, data, or
> production evidence (cite it). **THEORY** = plausible but unproven (state what
> evidence is still missing and how to get it). Do not blur the two.

### Finding 1: [Title]
**Classification**: [CONFIRMED / THEORY]
**Evidence**: [`file:line`, query output, endpoint response — the concrete proof, or for a THEORY, the gap]
**Description**: [What was found and why it matters]

### Finding 2: [Title]
**Classification**: [CONFIRMED / THEORY]
**Evidence**: [...]
**Description**: [...]

---

## Ruled Out

Causes considered and eliminated, with the evidence that eliminated them:

- **[Candidate cause]** — ruled out because [evidence].
- **[Candidate cause]** — ruled out because [evidence].

---

## Leading Hypothesis Disposition

The pre-investigation hypothesis (from the TSK) was:
> [Restate the leading hypothesis]

**Disposition**: [CONFIRMED / REFUTED / STILL OPEN] — [why, with evidence]

---

## Recommended Direction

> Direction only — do NOT implement here. This feeds `/task-design` (to turn a
> confirmed cause into a remediation decision) or `/task-continue` (if the fix is
> already clear). If NO DEFECT was found, recommend closing or the next diagnostic step.

- [Recommended remediation direction, or "No fix required — close task", or "Further evidence needed: ..."]

---

## Open Questions

- [Anything still unresolved and what it would take to resolve it]

**Confidence Level**: [High / Medium / Low]
