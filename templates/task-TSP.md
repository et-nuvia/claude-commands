# Test Plan: [Brief Description]

**Work Item**: [TASK_ID]
**Folder**: [FOLDER]
**Created**: [YYYY-MM-DD HH:MM]
**Type**: Test Plan
**Related To**: [TSK TASK_ID]

---

## Purpose

[What is being tested and why? What gaps do unit tests leave that this plan addresses?]

## Scope

**In Scope**:
- [Feature/integration being tested]
- [Layers covered: UI, API, DB, storage]

**Out of Scope**:
- [What is NOT covered by this test plan]

---

## Test Environment

| Component | Details |
|-----------|---------|
| **Runtime** | [e.g., Docker Compose development profile] |
| **Database** | [Host, port, credentials] |
| **Storage** | [S3/MinIO endpoint] |
| **Application** | [URL, port] |
| **Browser** | [Playwright/Cypress, headed/headless] |

## Prerequisites

- [ ] [Services running / containers up]
- [ ] [Seed data loaded]
- [ ] [Migrations applied]
- [ ] [Dependencies installed]

---

## Test Phases

### Phase 1: [Phase Name]

**Objective**: [What this phase validates]

**Steps**:
1. [Step description]
2. [Step description]
3. [Step description]

**Assertions**:
- [ ] [Expected behavior 1]
- [ ] [Expected behavior 2]

**DB Verifications**:
- [ ] [Table/column check]

**Storage Verifications**:
- [ ] [S3/file check]

---

### Phase 2: [Phase Name]

**Objective**: [What this phase validates]

**Steps**:
1. [Step description]
2. [Step description]

**Assertions**:
- [ ] [Expected behavior 1]
- [ ] [Expected behavior 2]

**DB Verifications**:
- [ ] [Table/column check]

---

## Success Criteria

**All phases must pass for the test plan to be considered successful.**

| Criteria | Threshold |
|----------|-----------|
| All phases pass | 100% |
| DB state consistent | All verifications pass |
| No data leaks | No plaintext PHI in logs/DB |
| Cleanup complete | Test data removed |

---

## Risk Factors

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| [Risk description] | High/Med/Low | High/Med/Low | [How to handle] |

---

## Test Script

**Location**: [path/to/test-script]

**Usage**:
```bash
[Command to run all phases]
[Command to run single phase]
[Command for headed mode]
```

---

## Related Documents

- TSK: [TASK_ID-DATETIME-TSK-description.md] - Parent task
- PLN: [TASK_ID-DATETIME-PLN-description.md] - Implementation plan
- TSR: [TASK_ID-DATETIME-TSR-description.md] - Test results (created after execution)
