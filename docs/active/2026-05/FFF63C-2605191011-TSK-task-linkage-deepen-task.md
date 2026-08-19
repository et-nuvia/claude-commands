# Task: task-linkage-deepen-task-api

**Work Item**: FFF63C
**Folder**: /Users/eric.turner/projects/claude-commands/docs/active/2026-05
**Created**: 2026-05-19 10:11
**Status**: Active
**Type**: Task
**Priority**: Medium

---

## Summary

Deepen `scripts/lib/task-api.sh` with a **Task Linkage** module (`task_linkage` + `task_linkage_from_doc`) and migrate the three lifecycle scripts (`task-start.sh`, `task-resume.sh`, `task-continue.sh`) off their inline Asana-shaped state.

## Context

**Why is this needed?**

A real seam exists at `scripts/lib/task-api.sh` with four backend adapters behind it (asana, gitlab-tasks, github-tasks, none) — but the three task lifecycle scripts bypass it. They carry `ASANA_GID` / `SHOULD_SYNC_ASANA` state, branch on `tracker_backend == "asana"`, and read backend-specific yaml keys directly. **Locality** is broken: the bug fixed in PR #51 M1 (wrong tracker URL when explicit backend ≠ active backend) lived in caller code precisely because the seam couldn't enforce correctness when callers don't cross it. The deletion-test verdict (concentrates) confirms the deepening direction.

**Background**:

- Originated as candidate #1 of ARC `C0E2FD-2605190809-ARC-task-lifecycle-adapter-leak.md`.
- Grilled across all 10 topics; Migration shape is **test-prep → strangler** (five PRs).
- Interface chosen via `/arch-interfaces`: Design C + one A flag (`task_linkage [--refresh]` + escape hatch).
- Domain term **Task Linkage** added to `docs/architecture/PROJECT-KNOWLEDGE.md` (file created in this work).

**Source**:
- ARC: `docs/active/2026-05/C0E2FD-2605190809-ARC-task-lifecycle-adapter-leak.md` (candidate #1)
- Related prior work: PR #50 (initial migration of task lifecycle to adapter; left asana state behind), PR #51 (review finding M1 — the bug this deepening prevents structurally), PR #54 (recent `task-close` consolidation and `gitlab_api` seam fix; same pattern of work).

---

## External Tracking

**Backend**: None synced at capture time. Task is tracked locally only until `/task-start` runs (which will sync to whichever backend `PROJECT.yaml` resolves to). Eric's home env (this repo) defaults to GitLab via the profile; current PROJECT.yaml doesn't set `task_management.backend` explicitly, so a `task-start` sync would need that decision first.

**Notes**:
- `.current-task` will hold the backend + tracker_id once `task-start` runs.
- Per the design being implemented, the linkage will be loaded via `task_linkage` and not via inline parsing.

---

## Requirements

### Functional Requirements

- [ ] FR1: `scripts/lib/task-api.sh` exposes a public `task_linkage` function that takes zero arguments by default and an optional `--refresh` flag.
- [ ] FR2: `scripts/lib/task-api.sh` exposes a public `task_linkage_from_doc <tsk_doc_path> [backend_override]` for callers without an active `.current-task`.
- [ ] FR3: Both functions emit a normalized JSON record on stdout, with keys uniform across all backends.
- [ ] FR4: The three lifecycle scripts read tracker linkage through these functions only — no inline `ASANA_GID` extraction, no `tracker_backend == "asana"` branches.

### Technical Requirements

- [ ] TR1: TSK-doc parsing stays private to `task-api.sh` (internal seam; not exposed). Honors grill Topic 4.
- [ ] TR2: No new ports introduced. The four existing backend adapters are reused; each may grow contract methods if needed (decision deferred to Phase 2 — `task_get` / `task_url` may already suffice).
- [ ] TR3: Default (no `--refresh`) call performs no `task_get` HTTP/CLI round-trip. `task_url` may be called because it's deterministic string construction.
- [ ] TR4: All existing tests must remain green at every phase boundary.

### Acceptance Criteria

- [ ] **AC1**: `scripts/lib/task-api.sh` exposes `task_linkage` and `task_linkage_from_doc` with the schema documented in the Grilled Design.
- [ ] **AC2**: All four backend adapters (`asana.sh`, `gitlab-tasks.sh`, `github-tasks.sh`, `none.sh`) satisfy whatever contract method(s) the new linkage operation requires, and `test-task-api-contract.bats` enforces this.
- [ ] **AC3**: `test-task-api-normalize.bats` covers `task_linkage` for every backend across `--refresh` on/off (16 interface-level cases).
- [ ] **AC4**: New bats coverage exists for `task-start.sh`, `task-resume.sh`, `task-continue.sh` with **non-null `task_tracker`** fixtures per backend, asserting the current (pre-refactor) behavior. (Phase 1 test-prep deliverable.)
- [ ] **AC5**: `task-start.sh` no longer references `ASANA_GID`, `SHOULD_SYNC_ASANA`, or `tracker_backend == "asana"` outside comments. The corresponding paths route through `task_linkage`. All AC4 tests stay green.
- [ ] **AC6**: Same as AC5 for `task-resume.sh`.
- [ ] **AC7**: Same as AC5 for `task-continue.sh` (vestigial `ASANA_GID` removed).
- [ ] **AC8**: After AC5–AC7, `grep -nE 'ASANA_GID|SHOULD_SYNC_ASANA|tracker_backend.*==.*asana' scripts/task-{start,resume,continue}.sh` returns zero matches outside of comments.
- [ ] **AC9**: The bats suite passes with zero regressions vs the pre-PR baseline at every phase boundary.

---

## Technical Details

**Affected Components**:

- `scripts/lib/task-api.sh` (dispatcher — gains new public surface)
- `scripts/lib/task-backends/asana.sh`, `gitlab-tasks.sh`, `github-tasks.sh`, `none.sh` (may gain contract methods)
- `scripts/task-start.sh` (refactor target — Phase 3a)
- `scripts/task-resume.sh` (refactor target — Phase 3b)
- `scripts/task-continue.sh` (refactor target — Phase 3c)
- `scripts/tests/test-task-api-contract.bats` (extended in Phase 1)
- `scripts/tests/test-task-api-normalize.bats` (extended in Phase 1)
- New bats fixtures for non-null `task_tracker` lifecycle scenarios

**Dependencies**:

- Existing task-backends contract (`task_get`, `task_url`, `task_health`)
- `scripts/lib/output-framework.sh` (lifecycle scripts already use it)
- `scripts/lib/load-profile.sh`, `scripts/lib/yaml.sh`

**Files to Modify**: see Affected Components above.

**Database Changes**:
- [x] Schema changes required — no
- [x] Migration needed — no
- [x] Data backfill needed — no

---

## Implementation Approach

### Option 1: Test-prep → Strangler (Recommended)

Five PRs landing as PLN phases:

1. **Phase 1 — Test-prep** (one PR): write tests against current behavior for the lifecycle scripts with non-null `task_tracker` fixtures; extend contract/normalize tests with `task_linkage` cases. Tests for the new function go red (function not yet implemented).
2. **Phase 2 — Adapter extension** (one PR): implement `task_linkage` + `task_linkage_from_doc` in `task-api.sh`; implement contract method(s) per backend. Phase 1's red tests turn green. Lifecycle scripts untouched.
3. **Phase 3a** (one PR): migrate `task-start.sh`.
4. **Phase 3b** (one PR): migrate `task-resume.sh`.
5. **Phase 3c** (one PR): migrate `task-continue.sh` (vestigial removal).

**Pros**:
- Test safety net before any production code change (audit found two 🔴 modules).
- Strangler keeps each PR small and reviewable.
- Existing test suite passes at every boundary.

**Cons**:
- Five PRs is more overhead than a single PR.
- Phase 1 PR has red tests in it (against the not-yet-shipped function); reviewer must understand that's intentional.

**Complexity**: Medium

### Option 2: Big-bang single PR

All five phases land together.

**Pros**:
- One PR, one review cycle.

**Cons**:
- Audit found 🔴 modules — no safety net during the refactor.
- Larger blast radius if anything regresses.
- Review burden is high.

**Decision**: Option 1. Per the Grilled Design (Topic 10) and confirmed by the user during the grill, **test-prep → strangler** is non-negotiable because two of the three lifecycle scripts have zero current coverage of the asana-shaped paths being refactored.

---

## Testing Plan

### Unit Tests (Phase 1 deliverables)

- [ ] `test-task-api-contract.bats` — assert each adapter defines the new linkage contract method(s).
- [ ] `test-task-api-normalize.bats` — `task_linkage` per adapter × `--refresh` on/off = 16 cases.
- [ ] `test-task-start.bats` — non-null `task_tracker` fixtures per backend, asserting current (pre-refactor) output JSON.
- [ ] `test-task-lifecycle.bats` — same for `task-resume.sh`.
- [ ] `test-task-continue.bats` — non-null `task_tracker` fixture (currently uses null).

### Integration Tests

- [ ] Full task lifecycle (start → continue → resume) against each backend type. Bats-driven, uses `none` backend by default; `asana` and `gitlab-tasks` paths use existing mock-curl approach.

### Manual Testing

- [ ] Run `~/.claude/scripts/task-start.sh --json --identify` on an asana-configured PROJECT.yaml; verify the resulting `.current-task` has `task_tracker: {backend, id, url}`.
- [ ] Same on a github-tasks-configured project (using PROJECT.yaml override).

---

## Deployment Plan

**Deployment Type**: Standard (PR per phase to `main`; no production-environment ramp).

**Steps**:
1. Phase 1 PR → review → merge (tests for new function are red; reviewer aware).
2. Phase 2 PR → review → merge (tests go green).
3. Phase 3a → 3b → 3c PRs in order, each independently reviewable.

**Rollback Plan**:
- Each phase is independently revertible. Phase 3 PRs land one at a time so a regression in `task-start` doesn't block `task-resume`.

**Monitoring**:
- Bats suite must pass at every phase boundary (CI gate).
- Manual smoke test of `/task-start` on an active project after each Phase 3 PR.

---

## Timeline

**Estimated Effort**: 3–4 days (mostly because of the per-PR review cadence; actual coding is small per phase).
**Started**: TBD
**Target Completion**: TBD
**Completed**: [YYYY-MM-DD or empty]

---

## Progress Log

### 2026-05-19 10:11

- Captured from ARC `C0E2FD-2605190809-ARC-task-lifecycle-adapter-leak.md` via `/feature-to-task`.
- Grilled Design + Interface Alternatives + Recommendation already populated in ARC.
- Next step: `/task-design FFF63C` to materialize the DSN (most Resolved Decisions come from the Grilled Design; Deferred Decisions noted below).

---

## Resolved Decisions (seed for DSN)

> These come from the ARC's Grilled Design. `/task-design` should record them as Resolved on first DSN pass — do NOT re-litigate.

- **Module name**: Task Linkage (added to `docs/architecture/PROJECT-KNOWLEDGE.md`).
- **Seam placement**: inside `scripts/lib/task-api.sh` (deepen existing facade).
- **What sits behind the seam**: private TSK-doc parser + adapter dispatch + assembly. Parser stays private (single-adapter seam — DEEPENING.md "one adapter = hypothetical seam").
- **Dependency category**: in-process core + true-external tail.
- **Adapter strategy**: reuse existing four backend adapters; no new ports.
- **Interface**: `task_linkage [--refresh]` + escape hatch `task_linkage_from_doc <path> [backend]`. Common case is zero-args; `task_url` always called (deterministic), `task_get` opt-in via `--refresh`.
- **Tests that survive**: `test-task-api-normalize.bats`, `test-task-continue.bats`, `test-task-context.bats`, error-path tests in `test-task-start.bats` / `test-task-lifecycle.bats`.
- **Tests deleted**: none. Two existing tests extended (contract + normalize) in Phase 1.

## Deferred Decisions (seed for DSN)

- **Exact normalized JSON schema for the linkage record.** Grilled Design lists fields conceptually (`backend`, `tracker_id`, `tracker_url`, `sync_on_operations`, `status`, …). Final key names + null semantics get nailed during Phase 2 implementation, with backwards-compat hooks for the existing `task_tracker` shape in `.current-task`. **Trigger**: Phase 2 kickoff.
- **Whether `should_sync` is pre-computed** by `task_linkage` (Design C said yes, reading `$TASK_LIFECYCLE_OP`) or left for callers to evaluate. **Trigger**: after Phase 1 test fixtures show how the three lifecycle scripts actually consume `sync_on_operations` today.

---

## Related Documents

- ARC: `docs/active/2026-05/C0E2FD-2605190809-ARC-task-lifecycle-adapter-leak.md`
- PROJECT-KNOWLEDGE.md: `docs/architecture/PROJECT-KNOWLEDGE.md` (Task Linkage definition)
- PLN: [FFF63C-DATETIME-PLN-…] — to be created by `/task-plan`
- DSN: [FFF63C-DATETIME-DSN-…] — to be created by `/task-design`

---

## Outcome

**Result**: [Pending]

**What was delivered**: TBD on completion.

**What was deferred**: TBD on completion.

**Lessons Learned**: TBD on completion.

---

## Related Documents (Work Item FFF63C)

Find all related documents:
```bash
find docs -name "FFF63C-*"
```

Current documents:
```
docs/active/2026-05/FFF63C-2605191011-TSK-task-linkage-deepen-task.md
```
