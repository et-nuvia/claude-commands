# Audit: [Brief Description]

**Work Item**: [TASK_ID]
**Folder**: [FOLDER]
**Created**: [YYYY-MM-DD HH:MM]
**Type**: Audit
**Related To**: [TSK TASK_ID]
**Auditor**: Claude Code
**Audit Status**: [In Progress/Complete]

---

## Purpose

[Brief context - e.g., "Progress audit before task completion", "Mid-task quality checkpoint", etc.]

---

## What Was Audited

**Scope**:
- **Task**: [Task title]
- **Branch**: [feature/branch-name]
- **Base Branch**: [main/staging]
- **Audit Date**: [YYYY-MM-DD]
- **Task Status**: [In Progress/Pending Completion]

**Changes Under Review**:
- **Commits**: [Number]
- **Files Changed**: [Number]
- **Lines Changed**: [+additions/-deletions]
- **Test Files**: [Number]

---

## Summary Assessment

| Category | Score | Status |
|----------|-------|--------|
| **Work Quality** | [0-100] | ✅ Good / ⚠️ Needs Work |
| **Test Coverage** | [0-100] | ✅ Good / ⚠️ Needs Work |
| **Impact Assessment** | [0-100] | ✅ Good / ⚠️ Needs Work |
| **Completion** | [0-100] | ✅ Good / ⚠️ Needs Work |
| **Overall** | [0-100] | ✅ Excellent / ✓ Good / ⚠️ Fair / ❌ Needs Work |

---

## Work Analysis

### Commit History

**Total Commits**: [Number]

**Recent Commits**:
```
1. [commit hash] [commit message]
2. [commit hash] [commit message]
3. [commit hash] [commit message]
...
```

### Files Changed

**Total Files**: [Number]

**Breakdown by Type**:
- Source code: [Number]
- Test files: [Number]
- Configuration: [Number]
- Documentation: [Number]

**Key Files Modified**:
- `[path/file.ext]` - [Status: Added/Modified/Deleted]
- `[path/file.ext]` - [Status: Added/Modified/Deleted]
- `[path/file.ext]` - [Status: Added/Modified/Deleted]

### Code Statistics

```
Total additions: +[Number] lines
Total deletions: -[Number] lines
Net change: [Number] lines
```

---

## Test Coverage Analysis

### Test Files

**Test Files Modified/Added**: [Number]

**Test Files List**:
- ✓ `[test/file.test.ts]` - [+additions/-deletions]
- ✓ `[test/file.spec.js]` - [+additions/-deletions]

**Test Lines Added**: +[Number]
**Test Lines Removed**: -[Number]
**Net Test Lines**: [Number]

### Test Execution

**Test Status**: ✅ All Passing / ❌ Some Failing / ⚠️ Not Run

**Coverage Metrics**:
- **Overall Project Coverage**: [XX%]
- **Minimum Required**: [YY%]
- **Status**: ✅ Met / ⚠️ Below Threshold

### Coverage for Changed Files

| File | Has Tests | Status |
|------|-----------|--------|
| `[file1.ts]` | ✓ Yes | ✅ Covered |
| `[file2.ts]` | ✗ No | ⚠️ Uncovered |
| `[file3.ts]` | ✓ Yes | ✅ Covered |

**Summary**:
- Files with tests: [X] / [Total]
- Files without tests: [Y] / [Total]
- Coverage ratio: [XX%]

**Uncovered Files** (Need Tests):
- ⚠️ `[path/file.ext]` - [Reason: New file without tests]
- ⚠️ `[path/file.ext]` - [Reason: Modified but no test update]

---

## Project-Wide Impact Assessment

### Changed Symbols

**Functions/Classes Modified**: [Number]

**Key Symbols**:
- `[functionName]` - [File: path/file.ext]
- `[ClassName]` - [File: path/file.ext]
- `[exportName]` - [File: path/file.ext]

### Reference Analysis

**References Found**: [Number total across all symbols]

**Symbol Usage**:
| Symbol | References | Files Affected |
|--------|------------|----------------|
| `[symbol1]` | [Number] | [Number files] |
| `[symbol2]` | [Number] | [Number files] |

**High-Impact Symbols** (>5 references):
- ⚠️ `[symbolName]` - [X references across Y files]
  - Consider reviewing all references for consistency

### Import/Export Analysis

**Export Changes Detected**: ✅ Yes / ✗ No

**Impact Assessment**:
- ✅ All imports verified consistent
- ⚠️ [X] potential broken imports detected (review TypeScript errors)

### Similar Patterns

**Similar Files Found**: [Number]

**Files with Similar Names/Patterns**:
- `[similar-file-1.ts]` - May need similar updates
- `[similar-file-2.ts]` - May need similar updates

**Recommendation**: Review similar files to ensure consistency

---

## Remaining Work Analysis

### Acceptance Criteria Status

**Total Criteria**: [Number]
**Completed**: [Number]
**Pending**: [Number]
**Progress**: [XX%]

**Criteria Checklist**:
- [x] [Completed criterion 1]
- [x] [Completed criterion 2]
- [ ] [Pending criterion 1]
- [ ] [Pending criterion 2]

### Plan Status

**Plan Document**: [TASK_ID-DATETIME-PLN-description.md]

**Plan Progress**:
- Total tasks: [Number]
- Completed tasks: [Number]
- Pending tasks: [Number]
- Progress: [XX%]

**Pending Plan Items**:
- [ ] [Pending task 1]
- [ ] [Pending task 2]

### Code Quality Issues

**TODOs Found**: [Number]

**TODO List**:
- ⚠️ [File:line] - TODO: [Description]
- ⚠️ [File:line] - FIXME: [Description]

**Incomplete Patterns Found**: [Number]

**Incomplete Work**:
- ⚠️ [File:line] - WIP: [Description]
- ⚠️ [File:line] - PLACEHOLDER: [Description]

---

## Key Findings

### Strengths

**What's Going Well**:
- ✅ [Finding 1 - e.g., "Comprehensive test coverage for core functionality"]
- ✅ [Finding 2 - e.g., "Clean commit history with descriptive messages"]
- ✅ [Finding 3 - e.g., "Proper error handling implemented"]

### Concerns

**Issues Identified**:
- ⚠️ [Concern 1 - e.g., "Test coverage below 80% threshold"]
  - **Impact**: [Description]
  - **Recommendation**: [Action to take]

- ⚠️ [Concern 2 - e.g., "3 files modified without corresponding tests"]
  - **Impact**: [Description]
  - **Recommendation**: [Action to take]

### Critical Issues

**Must Fix Before Completion**:
- ❌ [Critical issue 1 - e.g., "Tests failing on authentication module"]
  - **Severity**: Critical
  - **Action Required**: [Specific fix needed]

---

## Recommendations

### Immediate Actions (Before Proceeding)

**Priority 1 - Critical**:
1. [Action 1] - [Reason]
2. [Action 2] - [Reason]

**Priority 2 - Important**:
1. [Action 1] - [Reason]
2. [Action 2] - [Reason]

### Quality Improvements

**Code Quality**:
- [Recommendation 1]
- [Recommendation 2]

**Testing**:
- [Recommendation 1]
- [Recommendation 2]

**Documentation**:
- [Recommendation 1]
- [Recommendation 2]

### Next Steps

**To Complete Task**:
1. [Step 1]
2. [Step 2]
3. [Step 3]

**Before /task-close**:
- [ ] Resolve all test failures
- [ ] Achieve minimum test coverage
- [ ] Complete all acceptance criteria
- [ ] Address all TODOs
- [ ] Fix incomplete patterns
- [ ] Run `/task-audit` again to verify

---

## Audit Score Breakdown

**Scoring Methodology**:
- Work Quality: Based on commit quality, code patterns, file organization
- Test Coverage: Based on test files, coverage %, uncovered files
- Impact Assessment: Based on symbol analysis, reference verification
- Completion: Based on criteria met, TODOs, incomplete patterns

**Score Details**:

**Work Quality** ([Score]/100):
- Base score: 100
- Deductions: [List deductions if any]

**Test Coverage** ([Score]/100):
- Base score: 100
- Deductions:
  - [If tests failing]: -50 points
  - [If no test files]: -30 points
  - [Per uncovered file]: -[X] points

**Impact Assessment** ([Score]/100):
- Base score: 100
- Deductions: [List deductions if any]

**Completion** ([Score]/100):
- Base score: 100
- Deductions:
  - [Per TODO]: -5 points
  - [Per incomplete pattern]: -10 points
  - [Per pending criterion]: -10 points

**Overall Score**: [Average of all categories]/100

**Status Interpretation**:
- 90-100: ✅ Excellent - Ready for completion
- 70-89: ✓ Good - Minor items to address
- 50-69: ⚠️ Fair - Several issues to fix
- 0-49: ❌ Needs Work - Significant issues

---

## Related Documents

**Task Documents**:
- TSK: [TASK_ID-DATETIME-TSK-description.md] - Main task
- PLN: [TASK_ID-DATETIME-PLN-description.md] - Implementation plan
- FND: [TASK_ID-DATETIME-FND-description.md] - Findings (if any)

**Previous Audits**:
- AUD: [TASK_ID-DATETIME-AUD-description.md] - Previous audit (if any)

---

## Audit Metadata

**Audit Type**: [Progress Checkpoint / Pre-Completion / Quality Gate]
**Duration**: [X minutes]
**Automated Checks**: [List of automated checks run]
**Manual Review**: [Aspects manually reviewed]

**Audit History**:
- [YYYY-MM-DD]: Initial audit - Score: [XX/100]
- [YYYY-MM-DD]: Follow-up audit - Score: [YY/100]

**Reviewer Notes**:
[Any additional observations or context]

---

**Audit Completed**: [YYYY-MM-DD HH:MM]
**Status**: ✓ Audit Complete
