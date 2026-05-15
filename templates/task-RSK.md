# Risk Analysis: [Environment] Deployment - [Version]

**Work Item**: [TASK_ID]
**Folder**: [FOLDER]
**Created**: [YYYY-MM-DD HH:MM]
**Type**: Risk Analysis
**Related To**: [TSK/FIX TASK_ID if associated]
**Environment**: [staging/production]
**Version**: [v1.2.3 or SHA]

---

## Executive Summary

**Overall Risk Score**: [X.X]/10 - [🔴 BLOCK / 🟡 CAUTION / 🟢 READY / ✅ SAFE]

**Recommendation**: [Deploy with confidence / Deploy with monitoring / Deploy after mitigations / Do not deploy]

**Critical Risks**: [N]
**High Risks**: [N]
**Medium Risks**: [N]

**Deployment Window**: [Day of week, YYYY-MM-DD HH:MM UTC] [✓/⚠️]

---

## Deployment Context

**Environment**: [staging/production]
**Version**: [v1.2.3 or git SHA]
**Deployment Date**: [YYYY-MM-DD]
**Day of Week**: [Monday/Tuesday/etc.]
**Time**: [HH:MM UTC]
**On-Call Status**: [Available/Limited/Unavailable]

**Analysis Model**: claude-opus-4-6
**Analysis Duration**: [X minutes]

---

## Historical Context

### Risk Score Trend

**Previous Deployments**:
| Date | Environment | Risk Score | Result | Notes |
|------|-------------|------------|--------|-------|
| [YYYY-MM-DD] | [env] | [X.X]/10 | [✓/✗] | [Brief outcome] |
| [YYYY-MM-DD] | [env] | [X.X]/10 | [✓/✗] | [Brief outcome] |
| [YYYY-MM-DD] | [env] | [X.X]/10 | [✓/✗] | [Brief outcome] |

**Average Risk Score**: [X.X]/10
**Trend**: [↑ Increasing / → Stable / ↓ Decreasing]

### Incident Correlation

**Related Incidents**:
- [Previous incident related to similar changes]
- [Patterns identified from history]

### Deployment Timing Assessment

- **Day of Week**: [Monday/etc.] [✓ Good / ⚠️ Risky]
- **Time of Day**: [HH:MM UTC] [✓ Good / ⚠️ Risky]
- **Special Period**: [None / Holiday / Sales Event / etc.]
- **On-Call Availability**: [✓ Available / ⚠️ Limited / 🔴 Unavailable]

**Timing Risk Adjustment**: [+/-X points]

---

## Risk Category Breakdown

| Category | Score | Weight | Weighted | Status | Key Concerns |
|----------|-------|--------|----------|--------|--------------|
| Security | [X]/10 | 30% | [X.X] | [✓/⚠️/🔴] | [Brief summary] |
| Data Integrity | [X]/10 | 25% | [X.X] | [✓/⚠️/🔴] | [Brief summary] |
| Breaking Changes | [X]/10 | 15% | [X.X] | [✓/⚠️/🔴] | [Brief summary] |
| Database Migrations | [X]/10 | 10% | [X.X] | [✓/⚠️/🔴] | [Brief summary] |
| Rollback Capability | [X]/10 | 10% | [X.X] | [✓/⚠️/🔴] | [Brief summary] |
| Code Changes | [X]/10 | 5% | [X.X] | [✓/⚠️/🔴] | [Brief summary] |
| Dependencies | [X]/10 | 2.5% | [X.X] | [✓/⚠️/🔴] | [Brief summary] |
| Configuration | [X]/10 | 2.5% | [X.X] | [✓/⚠️/🔴] | [Brief summary] |
| Performance | [X]/10 | Info | - | [✓/⚠️/⚠️] | [Brief summary] |
| Testing Coverage | [X]/10 | Info | - | [✓/⚠️/⚠️] | [Brief summary] |

**Weighted Risk Score**: [X.X]/10
**Overall Risk Score**: [X.X]/10 (max of weighted and critical individual risks)

---

## Detailed Risk Analysis

### 1. Code Changes - [X]/10

**Scope**:
- Files Changed: [N]
- Lines Added: [N]
- Lines Removed: [N]
- Complexity: [Low/Medium/High]

**Risk Factors**:
- [Risk factor 1 with explanation]
- [Risk factor 2 with explanation]

**Code Paths Affected**:
- [Critical path 1]
- [Critical path 2]

**Mitigation Options**:

1. **[Mitigation 1]** (Recommended)
   - **Approach**: [Description of mitigation]
   - **Effort**: [Low/Medium/High]
   - **Effectiveness**: [Eliminates/Reduces/Monitors]
   - **Implementation Steps**:
     1. [Step 1]
     2. [Step 2]

2. **[Mitigation 2]**
   - **Approach**: [Description]
   - **Effort**: [Low/Medium/High]
   - **Effectiveness**: [Eliminates/Reduces/Monitors]

---

### 2. Database Migrations - [X]/10

**Migrations Found**: [N]

**Migration Details**:

#### Migration 1: [Description]
- **File**: [path/to/migration]
- **Type**: [Schema/Data/Index]
- **Operations**: [ADD/DROP/ALTER/CREATE]
- **Risk Level**: [X]/10
- **Reversible**: [Yes/No]

**Specific Risks**:
- [Risk 1]
- [Risk 2]

**Down Migration**: [Yes/No - explanation]

**Mitigation Options**:
[2+ mitigation strategies]

---

### 3. Dependencies - [X]/10

**Dependency Changes**:

| Package | Old Version | New Version | Change Type | CVEs | Risk |
|---------|-------------|-------------|-------------|------|------|
| [pkg1] | [v1.0.0] | [v2.0.0] | Major | [N] | [X]/10 |
| [pkg2] | [v1.0.0] | [v1.1.0] | Minor | [0] | [X]/10 |

**Security Scan Results**:
```
[Trivy or security scan output]
```

**License Compliance**: [✓ Pass / ⚠️ Review Required / 🔴 Violation]

**Mitigation Options**:
[2+ mitigation strategies]

---

### 4. Configuration - [X]/10

**Configuration Changes**:
- [Change 1]
- [Change 2]

**Environment Variables**:
- New: [List new env vars]
- Modified: [List modified env vars]
- Removed: [List removed env vars]

**Documentation**: [✓ Complete / ⚠️ Incomplete / 🔴 Missing]

**Mitigation Options**:
[2+ mitigation strategies]

---

### 5. Breaking Changes - [X]/10

**API Changes**:

| Endpoint | Change Type | Impact | Risk |
|----------|-------------|--------|------|
| [/api/v1/foo] | [Removed/Modified/Added] | [Description] | [X]/10 |

**Schema Changes**:
- [GraphQL/gRPC/Message queue changes]

**Client Impact**: [High/Medium/Low]

**Mitigation Options**:
[2+ mitigation strategies including versioning, deprecation notices, etc.]

---

### 6. Rollback Capability - [X]/10

**Code Rollback**: [✓ Simple / ⚠️ Complex / 🔴 Difficult]
**Database Rollback**: [✓ Simple / ⚠️ Complex / 🔴 Difficult]
**Configuration Rollback**: [✓ Simple / ⚠️ Complex / 🔴 Difficult]

**Irreversible Operations**: [Yes/No]
- [List any operations that cannot be rolled back]

**Rollback Time Estimate**: [X minutes]

**Data Loss Risk**: [Yes/No] - [Explanation]

**Rollback Plan**:
1. [Step 1]
2. [Step 2]
3. [Step 3]

---

### 7. Testing Coverage - [X]/10

**Test Coverage**: [XX]%
**Baseline Coverage**: [XX]%
**Change**: [+/-X]%

**Test Types**:
- Unit Tests: [✓/⚠️/🔴]
- Integration Tests: [✓/⚠️/🔴]
- E2E Tests: [✓/⚠️/🔴]
- Smoke Tests: [✓/⚠️/🔴]

**Coverage Gaps**:
- [Gap 1]
- [Gap 2]

**Mitigation Options**:
[2+ mitigation strategies]

---

### 8. Security - [X]/10

**Security Scan Results**:
- Critical Vulnerabilities: [N]
- High Vulnerabilities: [N]
- Medium Vulnerabilities: [N]
- Low Vulnerabilities: [N]

**Specific Security Concerns**:

#### Concern 1: [Title]
- **Severity**: [Critical/High/Medium/Low]
- **Description**: [Details]
- **Location**: [File:line or component]
- **Impact**: [What could happen]
- **CVSS Score**: [X.X] (if applicable)

**Code Security Issues**:
- Hardcoded secrets: [✓ None / ⚠️ Review / 🔴 Found]
- SQL injection risks: [✓ None / ⚠️ Review / 🔴 Found]
- XSS vulnerabilities: [✓ None / ⚠️ Review / 🔴 Found]
- Authentication/Authorization: [✓ Secure / ⚠️ Review / 🔴 Issues]

**Mitigation Options**:
[2+ mitigation strategies for each issue]

---

### 9. Performance - [X]/10 (Informational)

**Performance Concerns**:

| Issue | Type | Impact | Severity |
|-------|------|--------|----------|
| [N+1 query] | Database | [Response time] | [High/Medium/Low] |
| [Algorithm complexity] | Code | [CPU/Memory] | [High/Medium/Low] |

**Load Testing**: [✓ Performed / ⚠️ Recommended / 🔴 Required]

**Mitigation Options**:
[2+ mitigation strategies]

---

### 10. Data Integrity - [X]/10

**Data Migration Risks**:
- Data transformation: [Yes/No]
- Constraint violations: [Possible/Unlikely/None]
- Data loss risk: [High/Medium/Low/None]

**Affected Records**: [Estimated N records]

**Validation Plan**:
- [Validation check 1]
- [Validation check 2]

**Backup Status**: [✓ Created / ⚠️ Recommended / 🔴 Required]

**Mitigation Options**:
[2+ mitigation strategies]

---

## Changes Being Deployed

### Commit History

**Commits** ([N] total):
```
[git log output showing commits being deployed]
```

### Files Changed

**Files** ([N] files):
```
[git diff --stat output]
```

### Summary of Changes

**Major Changes**:
1. [Change 1 - brief description]
2. [Change 2 - brief description]
3. [Change 3 - brief description]

**Minor Changes**:
- [Change 1]
- [Change 2]

---

## Deployment Readiness Assessment

### Recommendation: [🔴 BLOCK / 🟡 CAUTION / 🟢 READY / ✅ SAFE]

**Decision**: [Deploy with confidence / Deploy with monitoring / Deploy after mitigations / Do not deploy]

### Required Actions (Must Complete Before Deployment)

- [ ] [Action 1 - blocking issue]
- [ ] [Action 2 - blocking issue]

### Recommended Mitigations (Not Blocking)

- [ ] [Mitigation 1 - reduces risk]
- [ ] [Mitigation 2 - reduces risk]

### Optional Enhancements

- [ ] [Enhancement 1 - nice to have]
- [ ] [Enhancement 2 - nice to have]

---

## Pre-Deployment Checklist

**Code Quality**:
- [ ] All tests passing
- [ ] Coverage >= [XX]% (project minimum)
- [ ] No critical security vulnerabilities
- [ ] Code review completed and approved

**Database**:
- [ ] Database migrations reviewed and tested
- [ ] Down migrations exist and tested
- [ ] Database backup created (if data changes)
- [ ] Migration rollback plan documented

**Infrastructure**:
- [ ] Configuration changes documented
- [ ] Environment variables updated in secrets manager
- [ ] Infrastructure changes tested in staging
- [ ] Monitoring alerts configured

**People**:
- [ ] On-call engineer identified and available
- [ ] Domain expert available (for complex changes)
- [ ] Stakeholders notified of deployment
- [ ] Communication plan ready (if high-risk)

**Rollback**:
- [ ] Rollback plan documented and tested
- [ ] Rollback trigger conditions defined
- [ ] Rollback time estimate calculated
- [ ] Data restoration procedure ready (if needed)

**Mitigation**:
- [ ] All required mitigations implemented
- [ ] Mitigation effectiveness verified
- [ ] Recommended mitigations evaluated

---

## Rollback Plan

### Trigger Conditions

Initiate rollback if:
- [Condition 1 - e.g., error rate > 5%]
- [Condition 2 - e.g., response time > 2s]
- [Condition 3 - e.g., critical feature broken]

### Rollback Procedure

**Estimated Rollback Time**: [X minutes]

**Steps**:
1. [Step 1 - with command/procedure]
2. [Step 2 - with command/procedure]
3. [Step 3 - with command/procedure]

**Database Rollback** (if needed):
```bash
[Commands or procedure for rolling back database]
```

**Verification**:
- [ ] [Verify service is healthy]
- [ ] [Verify data integrity]
- [ ] [Verify functionality restored]

**Data Loss Risk**: [Yes/No]
**Data Loss Details**: [Explanation if yes]

---

## Monitoring Plan

### Key Metrics to Watch

**During Deployment**:
- [Metric 1] - Threshold: [value]
- [Metric 2] - Threshold: [value]

**Post-Deployment** (first 24 hours):
- [Metric 1] - Threshold: [value]
- [Metric 2] - Threshold: [value]

### Alert Configuration

- [ ] [Alert 1 configured]
- [ ] [Alert 2 configured]

### Dashboard

- Dashboard URL: [URL if available]
- Key panels: [List critical panels to watch]

---

## Communication Plan

### Stakeholders

**Must Notify**:
- [Stakeholder 1] - [Role/Reason]
- [Stakeholder 2] - [Role/Reason]

**Should Notify**:
- [Stakeholder 3] - [Role/Reason]

### Communication Channels

- Pre-deployment: [Channel/method]
- During deployment: [Channel/method]
- Post-deployment: [Channel/method]
- If issues arise: [Channel/method]

### Status Updates

- [ ] Pre-deployment notice sent
- [ ] Deployment start notification sent
- [ ] Deployment complete notification sent
- [ ] Post-deployment summary sent (if required)

---

## Related Risk Analyses

**Previous Analyses** (for historical comparison):
- [TASK_ID-DATETIME-RSK-{env}.md] - [Date] - Risk: [X.X]/10
- [TASK_ID-DATETIME-RSK-{env}.md] - [Date] - Risk: [X.X]/10

**Related Documents**:
- Associated Task: [TASK_ID-DATETIME-TSK-description.md]
- Code Review: [TASK_ID-DATETIME-CRV-description.md]
- Incident Reports: [TASK_ID-DATETIME-INC-description.md]

---

## Risk Score Legend

- **9-10**: 🔴 **BLOCK** - Critical risks present. Do not deploy until risks are mitigated.
- **7-8**: 🟡 **CAUTION** - High risks identified. Mitigate before deploying to production.
- **4-6**: 🟢 **READY** - Medium risks present. Deploy with monitoring, mitigations recommended.
- **0-3**: ✅ **SAFE** - Low risk deployment. Proceed with normal monitoring.

---

**Analyzed**: [YYYY-MM-DD HH:MM:SS]
**Documented**: [YYYY-MM-DD HH:MM:SS]
**Sequence**: [TASK_ID]
**Analyst**: Deployment Risk Analyzer (Claude Opus 4.6)
