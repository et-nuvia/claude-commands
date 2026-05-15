# Fix: [Brief Description]

**Work Item**: [TASK_ID]
**Folder**: [FOLDER]
**Created**: [YYYY-MM-DD HH:MM]
**Type**: Fix
**Related To**: [INC/TSK TASK_ID]

---

## Summary

[Brief description of what was fixed and how]

---

## Problem Statement

**Issue**:
[What was broken]

**Impact**:
[Who/what was affected]

**Root Cause**:
[Why it was happening - reference FND document if available]

---

## Solution

**Approach**:
[High-level description of the fix]

**Why This Approach**:
[Rationale for chosen solution over alternatives]

**Alternatives Considered**:
1. [Alternative 1] - Rejected because [reason]
2. [Alternative 2] - Rejected because [reason]

---

## Implementation Details

### Code Changes

**Files Modified**:
- `path/to/file1.ext` - [What changed]
- `path/to/file2.ext` - [What changed]
- `path/to/file3.ext` - [What changed]

**Key Changes**:

```python
# Before
[Old code that had the issue]

# After
[New code with fix]
```

**Explanation**:
[Why this code change fixes the issue]

### Configuration Changes

**Modified Settings**:
```yaml
# Before
setting_name: old_value

# After
setting_name: new_value
```

**Reason**:
[Why this configuration change was needed]

### Database Changes

**Migration Required**: [Yes/No]

**Changes**:
- [Change 1 - e.g., added index, modified column, etc.]
- [Change 2]

**Migration Script**:
```sql
-- Migration up
[SQL for applying change]

-- Migration down (rollback)
[SQL for reverting change]
```

---

## Testing

### Unit Tests Added
```python
def test_fix_for_issue():
    """Test that verifies the fix works"""
    # Test code
    assert result == expected
```

### Manual Testing Performed
- [ ] [Test case 1] - Result: [Pass/Fail]
- [ ] [Test case 2] - Result: [Pass/Fail]
- [ ] [Test case 3] - Result: [Pass/Fail]

### Regression Testing
- [ ] Verified existing functionality still works
- [ ] No new errors introduced
- [ ] Performance not degraded

---

## Deployment

**Deployment Method**: [Standard/Hotfix/Staged/Canary]

**Steps Taken**:
1. [Step 1]
2. [Step 2]
3. [Step 3]

**Deployed To**:
- [ ] Development - [YYYY-MM-DD HH:MM]
- [ ] Staging - [YYYY-MM-DD HH:MM]
- [ ] Production - [YYYY-MM-DD HH:MM]

**Deployment Notes**:
[Any special considerations during deployment]

---

## Verification

**How Fix Was Verified**:
- [ ] [Verification step 1]
- [ ] [Verification step 2]
- [ ] [Verification step 3]

**Metrics After Fix**:
| Metric | Before | After | Improvement |
|--------|--------|-------|-------------|
| [Metric 1] | [Value] | [Value] | [+/- %] |
| [Metric 2] | [Value] | [Value] | [+/- %] |

**User Verification**:
[How users confirmed the fix works]

---

## Rollback Plan

**If Issues Arise**:
1. [Rollback step 1]
2. [Rollback step 2]
3. [Rollback step 3]

**Rollback Tested**: [Yes/No]

---

## Monitoring

**Metrics to Watch**:
- [Metric 1] - Expected: [value]
- [Metric 2] - Expected: [value]

**Alerts Updated**:
- [ ] [Alert 1] - [How modified]
- [ ] [Alert 2] - [How modified]

**Monitoring Period**: [Duration to monitor after deployment]

---

## Documentation Updates

- [ ] Runbook updated
- [ ] Architecture diagram updated
- [ ] API documentation updated
- [ ] User documentation updated
- [ ] Code comments added/updated

---

## Preventive Measures

**To Prevent Recurrence**:
1. [Preventive measure 1]
2. [Preventive measure 2]
3. [Preventive measure 3]

**Process Improvements**:
- [Improvement 1]
- [Improvement 2]

**Monitoring Improvements**:
- [New alert or dashboard]
- [Better detection method]

---

## Related Documents

- INC/TSK: [TASK_ID-DATETIME-INC/TSK-description.md] - Original issue
- PLN: [TASK_ID-DATETIME-PLN-description.md] - Implementation plan
- FND: [TASK_ID-DATETIME-FND-description.md] - Investigation findings
- RCA: [TASK_ID-DATETIME-RCA-description.md] - Post-mortem (if needed)

---

## Sign-off

**Implemented by**: [Name] on [YYYY-MM-DD]
**Reviewed by**: [Name] on [YYYY-MM-DD]
**Approved by**: [Name] on [YYYY-MM-DD]
**Verified by**: [Name] on [YYYY-MM-DD]
