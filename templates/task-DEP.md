# Deployment: [Brief Description]

**Work Item**: [TASK_ID]
**Folder**: [FOLDER]
**Created**: [YYYY-MM-DD HH:MM]
**Type**: Deployment
**Related To**: [TSK/FIX TASK_ID]
**Deployment Type**: [Standard/Hotfix/Staged/Blue-Green/Canary]

---

## Summary

[Brief description of what is being deployed]

---

## Deployment Details

**Version**: [Version number]
**Environment**: [Production/Staging/Development]
**Deployment Date**: [YYYY-MM-DD]
**Deployment Window**: [HH:MM - HH:MM]
**Expected Duration**: [Duration]
**Deployer**: [Name]

---

## What's Being Deployed

### Code Changes
- [Component 1] - [Brief description]
- [Component 2] - [Brief description]
- [Component 3] - [Brief description]

### Configuration Changes
- [Config 1] - [What's changing]
- [Config 2] - [What's changing]

### Infrastructure Changes
- [ ] Database schema changes
- [ ] New services/instances
- [ ] Resource scaling
- [ ] Network changes
- [ ] DNS changes

### Dependencies
- [Dependency 1] - Version [X.Y.Z]
- [Dependency 2] - Version [X.Y.Z]

---

## Pre-Deployment Checklist

### Code Readiness
- [ ] All tests passing (unit, integration, e2e)
- [ ] Code review completed and approved
- [ ] Security scan completed - no critical issues
- [ ] Performance testing completed
- [ ] Documentation updated

### Infrastructure Readiness
- [ ] Capacity verified (CPU, memory, disk)
- [ ] Database backup completed
- [ ] Monitoring dashboards prepared
- [ ] Alerts configured
- [ ] Rollback plan tested

### Team Readiness
- [ ] Deployment team notified
- [ ] On-call team briefed
- [ ] Support team briefed
- [ ] Stakeholders notified
- [ ] Communication plan ready

### Approvals
- [ ] Engineering Lead - [Name]
- [ ] Product Lead - [Name]
- [ ] Security Team - [Name]
- [ ] Operations Lead - [Name]

---

## Deployment Steps

### Phase 1: Pre-Deployment (HH:MM - HH:MM)
**Duration**: [Duration]

1. [ ] Announce deployment starting (Slack/email)
2. [ ] Enable maintenance mode (if needed)
3. [ ] Take final backup
4. [ ] Verify backup completion
5. [ ] Stop/drain traffic (if needed)

### Phase 2: Database Migration (HH:MM - HH:MM)
**Duration**: [Duration]

1. [ ] Run migration script
   ```bash
   [Command to run migration]
   ```
2. [ ] Verify migration success
3. [ ] Check database integrity
4. [ ] Run data validation queries

### Phase 3: Application Deployment (HH:MM - HH:MM)
**Duration**: [Duration]

1. [ ] Deploy to [environment/region 1]
   ```bash
   [Deployment command]
   ```
2. [ ] Verify health checks pass
3. [ ] Deploy to [environment/region 2]
4. [ ] Verify health checks pass
5. [ ] Enable traffic routing

### Phase 4: Verification (HH:MM - HH:MM)
**Duration**: [Duration]

1. [ ] Run smoke tests
2. [ ] Check critical user journeys
3. [ ] Verify metrics in acceptable range
4. [ ] Monitor error rates
5. [ ] Check performance baselines

### Phase 5: Post-Deployment (HH:MM - HH:MM)
**Duration**: [Duration]

1. [ ] Disable maintenance mode
2. [ ] Monitor for [duration]
3. [ ] Announce deployment complete
4. [ ] Update status page
5. [ ] Document any issues

---

## Rollback Plan

**Rollback Decision Criteria**:
- Error rate > [threshold]
- Response time > [threshold]
- Critical functionality broken
- Data corruption detected

**Rollback Steps**:

### Option 1: Application Rollback
1. [ ] Stop new version
2. [ ] Deploy previous version
   ```bash
   [Rollback command]
   ```
3. [ ] Verify health checks
4. [ ] Enable traffic

### Option 2: Database Rollback
1. [ ] Stop application
2. [ ] Restore database backup
   ```bash
   [Restore command]
   ```
3. [ ] Verify data integrity
4. [ ] Deploy previous app version
5. [ ] Resume traffic

**Rollback Tested**: [Yes/No]
**Rollback Time**: [Estimated duration]

---

## Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| [Risk 1] | High/Med/Low | High/Med/Low | [How mitigated] |
| [Risk 2] | High/Med/Low | High/Med/Low | [How mitigated] |
| [Risk 3] | High/Med/Low | High/Med/Low | [How mitigated] |

---

## Monitoring

**Dashboards**:
- [Dashboard URL 1] - [What to watch]
- [Dashboard URL 2] - [What to watch]

**Key Metrics to Monitor**:
- [Metric 1] - Baseline: [value] - Alert: [threshold]
- [Metric 2] - Baseline: [value] - Alert: [threshold]
- [Metric 3] - Baseline: [value] - Alert: [threshold]

**Monitoring Duration**: [Duration after deployment]

**Alert Channels**:
- Slack: #[channel]
- PagerDuty: [Service]
- Email: [Distribution list]

---

## Communication Plan

### Before Deployment
**Audience**: [Who]
**Channel**: [How]
**Timing**: [When]
**Message**:
```
[Deployment announcement message]
```

### During Deployment
**Updates Every**: [Frequency]
**Channel**: [Where to post updates]

### After Deployment
**Success Message**:
```
[Completion announcement]
```

**Failure Message** (if needed):
```
[Rollback/issue announcement]
```

---

## Success Criteria

Deployment is considered successful when:
- [ ] All health checks passing
- [ ] Error rate < [threshold]
- [ ] Response time < [threshold]
- [ ] Critical user journeys working
- [ ] No P0/P1 issues reported
- [ ] Monitoring shows healthy metrics
- [ ] [Duration] of stable operation

---

## Actual Deployment Log

### [HH:MM] - Pre-Deployment
[Notes on what actually happened]

### [HH:MM] - Database Migration
[Notes on what actually happened]

### [HH:MM] - Application Deployment
[Notes on what actually happened]

### [HH:MM] - Verification
[Notes on what actually happened]

### [HH:MM] - Completion
[Final notes]

---

## Issues Encountered

### Issue 1: [Description]
**Severity**: [Critical/High/Medium/Low]
**Impact**: [What was affected]
**Resolution**: [How it was resolved]
**Time to resolve**: [Duration]

### Issue 2: [Description]
[Same structure]

---

## Post-Deployment Review

**What Went Well**:
- [Success 1]
- [Success 2]

**What Could Be Improved**:
- [Improvement area 1]
- [Improvement area 2]

**Action Items**:
- [ ] [Action 1] - Owner: [Name] - Due: [Date]
- [ ] [Action 2] - Owner: [Name] - Due: [Date]

---

## Metrics

**Deployment Metrics**:
- Total time: [Actual vs estimated]
- Downtime: [Duration or "Zero downtime"]
- Rollbacks: [Count]
- Issues found: [Count by severity]

**System Metrics (Before vs After)**:
| Metric | Before | After | Change |
|--------|--------|-------|--------|
| Response time | [ms] | [ms] | [+/- %] |
| Error rate | [%] | [%] | [+/- %] |
| Throughput | [req/s] | [req/s] | [+/- %] |

---

## Related Documents

- TSK/FIX: [TASK_ID-DATETIME-TSK/FIX-description.md] - What's being deployed
- PLN: [TASK_ID-DATETIME-PLN-description.md] - Deployment plan
- FND: [TASK_ID-DATETIME-FND-description.md] - Pre-deployment findings

---

## Sign-off

**Deployment Completed by**: [Name] on [YYYY-MM-DD HH:MM]
**Verified by**: [Name] on [YYYY-MM-DD HH:MM]
**Approved for completion by**: [Name] on [YYYY-MM-DD HH:MM]
