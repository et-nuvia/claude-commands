# Infrastructure Fortification Audit

**Purpose:** Identify and fix resource exhaustion vulnerabilities before they cause outages

**Based on:** INC-20260131-001 (Dashboard OOM Memory Exhaustion)

**Usage:** Run this audit against any infrastructure project to identify capacity planning, resource limit, and monitoring gaps

---

## Phase 1: Discovery & Assessment

### Infrastructure Inventory

**Question 1.1: What services run on this infrastructure?**
- [ ] List all services/applications
- [ ] Document purpose of each service
- [ ] Identify critical vs non-critical services
- [ ] Map service dependencies

**Question 1.2: What is the current resource allocation?**
- [ ] Total RAM per server
- [ ] Total CPU cores per server
- [ ] Disk space allocated
- [ ] Network bandwidth limits
- [ ] Document in a capacity inventory spreadsheet

**Question 1.3: When was this infrastructure last sized/reviewed?**
- [ ] Date of last capacity review
- [ ] Has workload changed since then?
- [ ] Have new services been added?
- [ ] Has dual/multi-version support been added (e.g., PHP 5.6 + 8.x)?

---

## Phase 2: Resource Limits Audit

### 2.1 Systemd Service Limits

For each systemd service, check:

**Question 2.1.1: Are memory limits configured?**
```bash
# Check current limits
systemctl show <service-name> | grep -E 'Memory|Tasks|CPU'
```

Required configuration:
- [ ] `MemoryMax` - Hard limit (kills process if exceeded)
- [ ] `MemoryHigh` - Soft limit (triggers throttling)
- [ ] `TasksMax` - Prevent fork bombs
- [ ] `CPUQuota` - Prevent CPU monopolization
- [ ] `OOMPolicy` - How to handle OOM (recommend: `stop`)
- [ ] `OOMScoreAdjust` - Prefer killing app services over system (recommend: 500)

**Guidelines:**
- Production services: MemoryMax = 512M - 1G (depending on service)
- Background workers: MemoryMax = 256M - 512M
- Set MemoryHigh to 80% of MemoryMax
- TasksMax: 100 (unless service needs more)
- CPUQuota: 80% (prevents single service from monopolizing CPU)

**Red Flags:**
- ❌ No memory limits set (unlimited)
- ❌ MemoryMax > 50% of total server RAM
- ❌ No TasksMax (fork bomb risk)
- ❌ OOMScoreAdjust=0 or negative (system services at risk)

---

### 2.2 Web Server Limits

**Question 2.2.1: What web server is used?**
- [ ] Apache (MPM: prefork, worker, event)
- [ ] Nginx
- [ ] Other: __________

**For Apache MPM Prefork (with mod_php):**

Check `/etc/apache2/mods-enabled/mpm_prefork.conf`:
```bash
MaxRequestWorkers = ?
MaxConnectionsPerChild = ?
```

**Sizing Formula:**
```
Available RAM = Total RAM - OS overhead (500-1000MB)
Worker Memory = Average process RSS (check with: ps aux --sort=-rss)
Safe MaxRequestWorkers = Available RAM / Worker Memory * 0.7
```

**Guidelines:**
- [ ] MaxRequestWorkers calculated based on available RAM
- [ ] MaxConnectionsPerChild set (1000-10000) to recycle workers and prevent leaks
- [ ] StartServers, MinSpareServers, MaxSpareServers configured appropriately

**Example calculations:**
- 4GB RAM - 500MB OS = 3500MB available
- PHP processes average 140MB each
- 3500MB / 140MB = 25 workers max
- Safe setting: 25 * 0.7 = **17-20 workers**

**Red Flags:**
- ❌ MaxRequestWorkers > (Available RAM / Worker Memory)
- ❌ MaxRequestWorkers set to default (150 or 256) without validation
- ❌ MaxConnectionsPerChild = 0 (never recycles, memory leak risk)

**For Nginx + PHP-FPM:**

Check `/etc/php/X.X/fpm/pool.d/*.conf`:
```ini
pm.max_children = ?
pm.start_servers = ?
pm.min_spare_servers = ?
pm.max_spare_servers = ?
```

Apply same sizing formula as Apache.

---

### 2.3 Cron Job Limits

**Question 2.3.1: What cron jobs are running?**
```bash
# Check root crontab
sudo crontab -l

# Check user crontabs
for user in $(cut -f1 -d: /etc/passwd); do
  echo "User: $user"
  sudo crontab -u $user -l 2>/dev/null
done

# Check system cron
ls -la /etc/cron.d/
ls -la /etc/cron.{hourly,daily,weekly,monthly}/
```

**Question 2.3.2: Are resource limits applied to cron jobs?**

Check each cron job:
- [ ] Memory limit (ulimit -v)
- [ ] CPU time limit (ulimit -t)
- [ ] Process limit (ulimit -u)
- [ ] Timeout/max runtime

**Solution: Cron Wrapper Script**

Create `/usr/local/bin/cron-wrapper`:
```bash
#!/bin/bash
set -euo pipefail

# Resource limits (override via environment)
MEMORY_LIMIT_MB=${CRON_MEMORY_LIMIT_MB:-256}
CPU_TIME_LIMIT_SEC=${CRON_CPU_LIMIT_SEC:-300}
MAX_PROCESSES=${CRON_MAX_PROCESSES:-10}

MEMORY_LIMIT_KB=$((MEMORY_LIMIT_MB * 1024))

ulimit -v $MEMORY_LIMIT_KB  # Virtual memory
ulimit -m $MEMORY_LIMIT_KB  # RSS limit
ulimit -t $CPU_TIME_LIMIT_SEC  # CPU time
ulimit -u $MAX_PROCESSES  # Max processes

exec "$@"
```

**Wrap cron jobs:**
```bash
# High-frequency jobs (every minute):
* * * * * /usr/local/bin/cron-wrapper /usr/bin/php script.php

# Long-running jobs (reconciliation, cleanup):
0 2 * * * CRON_MEMORY_LIMIT_MB=512 CRON_CPU_LIMIT_SEC=600 /usr/local/bin/cron-wrapper /usr/bin/php reconcile.php
```

**Guidelines:**
- High-frequency jobs: 256MB, 5min CPU
- Daily reconciliation: 512MB-1GB, 10-30min CPU
- Database operations: 1GB-2GB, 30-60min CPU

**Red Flags:**
- ❌ No resource limits on any cron jobs
- ❌ Jobs running every minute without limits
- ❌ Long-running jobs (>5min) without timeouts
- ❌ Database operations without memory limits

---

### 2.4 Database Limits

**Question 2.4.1: Are database resource limits configured?**

**MySQL/MariaDB** - Check `/etc/mysql/my.cnf`:
```ini
[mysqld]
max_connections = ?
innodb_buffer_pool_size = ?
key_buffer_size = ?
tmp_table_size = ?
max_heap_table_size = ?
```

**Guidelines:**
- `max_connections`: 150-300 (not unlimited)
- `innodb_buffer_pool_size`: 50-70% of total RAM for dedicated DB server
- Set connection limits at application level too

**PostgreSQL** - Check `/etc/postgresql/*/main/postgresql.conf`:
```ini
max_connections = ?
shared_buffers = ?
work_mem = ?
maintenance_work_mem = ?
```

**Redis** - Check `/etc/redis/redis.conf`:
```ini
maxmemory <bytes>
maxmemory-policy allkeys-lru
maxclients 10000
```

**Red Flags:**
- ❌ No max_connections limit
- ❌ Buffer pool > 80% of total RAM (on shared server)
- ❌ No maxmemory on Redis (unbounded growth)

---

## Phase 3: Monitoring & Alerting

### 3.1 Memory Monitoring

**Question 3.1.1: Are memory alerts configured?**

Required Prometheus alerts:
- [ ] **LowAvailableMemory** - Warning when < 20% available
- [ ] **CriticalAvailableMemory** - Critical when < 10% available
- [ ] **HighSwapUsage** - Warning when > 50% swap used
- [ ] **CriticalSwapUsage** - Critical when > 80% swap used
- [ ] **OOMKillDetected** - Immediate alert when OOM killer activates
- [ ] **HighMemoryUsage** - Warning when memory usage > 80%
- [ ] **CriticalMemoryUsage** - Critical when memory usage > 90%

**Example Prometheus rules:**
```yaml
groups:
  - name: memory
    rules:
      - alert: CriticalAvailableMemory
        expr: (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) < 0.10
        for: 2m
        labels:
          severity: critical
        annotations:
          summary: "Critical memory on {{ $labels.instance }}"
          description: "Available memory < 10%"

      - alert: OOMKillDetected
        expr: increase(node_vmstat_oom_kill[5m]) > 0
        labels:
          severity: critical
        annotations:
          summary: "OOM killer active on {{ $labels.instance }}"
          description: "{{ $value }} processes killed in last 5 minutes"
```

**Red Flags:**
- ❌ No memory monitoring at all
- ❌ Only monitoring memory percentage, not available memory
- ❌ No OOM kill detection
- ❌ No swap usage alerts

---

### 3.2 Disk Monitoring

**Question 3.2.1: Are disk alerts configured?**

Required alerts:
- [ ] **LowDiskSpace** - Warning when > 80% full
- [ ] **CriticalDiskSpace** - Critical when > 90% full
- [ ] **DiskWillFillIn24Hours** - Predictive alert based on growth rate
- [ ] **HighInodeUsage** - Warning when > 80% inodes used
- [ ] **HighDiskIOUtilization** - Warning when disk is saturated

**Red Flags:**
- ❌ No disk space monitoring
- ❌ No inode monitoring (can exhaust before disk fills)
- ❌ No predictive alerts (only alerted after disk full)

---

### 3.3 CPU Monitoring

**Question 3.3.1: Are CPU alerts configured?**

Required alerts:
- [ ] **HighCPUUsage** - Warning when > 80% for 5min
- [ ] **CriticalCPUUsage** - Critical when > 95% for 2min
- [ ] **HighCPUIOwait** - Warning when IOWait > 20% (disk bottleneck)
- [ ] **HighLoadAverage** - Warning when load > CPU count * 2

---

### 3.4 Service-Specific Monitoring

**Question 3.4.1: Are application-specific metrics monitored?**

For each service, monitor:
- [ ] Service uptime/health (heartbeat)
- [ ] Request/response times
- [ ] Error rates
- [ ] Queue depths
- [ ] Connection pool usage
- [ ] Cache hit rates

**Example: Apache monitoring**
```yaml
- alert: ApacheWorkersExhausted
  expr: apache_workers_busy / apache_workers_total > 0.9
  for: 5m
  labels:
    severity: warning
  annotations:
    summary: "Apache running out of workers"
```

---

## Phase 4: Capacity Planning

### 4.1 Historical Analysis

**Question 4.1.1: What is the resource usage trend?**

Analyze last 30/60/90 days:
- [ ] Peak memory usage
- [ ] Peak CPU usage
- [ ] Peak disk usage
- [ ] Growth rate (% per month)

**Tools:**
```bash
# Query Prometheus for memory trends
# 30-day peak memory usage
max_over_time(node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes[30d])

# Growth rate calculation
deriv(node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes[30d])
```

**Question 4.1.2: Have there been any OOM events in the past?**
```bash
# Check system logs for OOM
journalctl --since="30 days ago" | grep -i "out of memory"
journalctl --since="30 days ago" | grep -i "oom"
journalctl --since="30 days ago" | grep -i "killed process"
```

**Red Flags:**
- ❌ No historical data (can't predict future needs)
- ❌ Previous OOM events that weren't investigated
- ❌ Consistent memory growth without investigation (leak?)
- ❌ Regular spikes to >90% usage

---

### 4.2 Capacity Headroom

**Question 4.2.1: What is the current headroom?**

Calculate for each resource:
```
Headroom % = (Total - Peak Usage) / Total * 100
```

**Industry standards:**
- Memory: 15-25% headroom minimum
- CPU: 30-40% headroom minimum
- Disk: 20-30% headroom minimum

**Example:**
- 4GB total RAM
- 3.2GB peak usage
- Headroom = (4 - 3.2) / 4 = 20% ✅

**Red Flags:**
- ❌ < 10% memory headroom (danger zone)
- ❌ < 20% CPU headroom during normal operations
- ❌ < 15% disk headroom

---

### 4.3 Growth Forecasting

**Question 4.3.1: When will resources be exhausted at current growth rate?**

Formula:
```
Months until full = (Total - Current) / (Growth per month)
```

**Guidelines:**
- If < 6 months: Immediate scaling required
- If 6-12 months: Plan scaling within next quarter
- If > 12 months: Monitor and review quarterly

---

## Phase 5: Deployment & Change Management

### 5.1 Pre-Deployment Checklist

**Question 5.1.1: For each new deployment, have we validated:**
- [ ] Memory requirements of new code/service
- [ ] CPU requirements
- [ ] Disk space requirements
- [ ] Impact on existing services (shared resources)
- [ ] Resource limits configured in systemd unit
- [ ] Monitoring/alerts configured
- [ ] Capacity headroom still adequate after deployment

**Red Flags:**
- ❌ Deploying without capacity validation
- ❌ Adding new services without resource limits
- ❌ No rollback plan if resources exhausted

---

### 5.2 Deployment Safeguards

**Question 5.2.1: Are deployment safeguards in place?**
- [ ] Canary deployments (deploy to 1 server first)
- [ ] Automated rollback on health check failure
- [ ] Resource usage monitoring during deployment
- [ ] Smoke tests verify service health post-deployment

---

## Phase 6: Documentation & Process

### 6.1 Runbooks

**Question 6.1.1: Do runbooks exist for common issues?**
- [ ] High memory usage response
- [ ] OOM recovery procedure
- [ ] Disk space exhaustion
- [ ] Service restart procedures
- [ ] Emergency capacity expansion

**Question 6.1.2: Are runbooks tested?**
- [ ] Last test date: __________
- [ ] Test frequency: __________
- [ ] Updates after incidents: __________

---

### 6.2 Capacity Review Process

**Question 6.2.1: Is there a regular capacity review process?**
- [ ] Quarterly capacity review scheduled
- [ ] Owner assigned for capacity planning
- [ ] Review includes all infrastructure
- [ ] Forecasting performed
- [ ] Budget allocated for scaling

**Red Flags:**
- ❌ No regular capacity review
- ❌ No owner for capacity planning
- ❌ Reactive only (scale after problems)
- ❌ No budget planning for capacity expansion

---

## Phase 7: Quick Wins (Immediate Actions)

### Critical Quick Fixes

If any of these are true, fix immediately:

**Critical Issue #1: No memory limits on services**
```bash
# Add to all systemd service files
[Service]
MemoryMax=512M
MemoryHigh=400M
TasksMax=100
CPUQuota=80%
OOMPolicy=stop
OOMScoreAdjust=500
```

**Critical Issue #2: No cron job limits**
```bash
# Deploy cron wrapper (see section 2.3.2)
# Update all cron jobs to use wrapper
```

**Critical Issue #3: Web server oversized for RAM**
```bash
# Recalculate MaxRequestWorkers (see section 2.2.1)
# Deploy new configuration
# Restart web server
```

**Critical Issue #4: No memory alerts**
```bash
# Deploy Prometheus memory alerts (see section 3.1.1)
# Test alerts fire correctly
```

**Critical Issue #5: < 15% memory headroom**
```bash
# Immediate: Add RAM or reduce services
# Investigate: Memory leaks? Unnecessary services?
# Plan: Capacity expansion
```

---

## Phase 8: Validation & Testing

### 8.1 Load Testing

**Question 8.1.1: Has the infrastructure been load tested?**
- [ ] Last load test date: __________
- [ ] Test methodology: __________
- [ ] Peak capacity identified: __________
- [ ] Resource limits validated under load
- [ ] Failure modes documented

**Load test scenarios:**
1. Normal traffic (baseline)
2. 2x normal traffic (growth scenario)
3. 5x normal traffic (spike scenario)
4. Sustained load (memory leak detection)

---

### 8.2 Chaos Testing

**Question 8.2.1: Have failure scenarios been tested?**
- [ ] OOM scenario (service with unlimited memory)
- [ ] Disk full scenario
- [ ] CPU saturation scenario
- [ ] Network saturation scenario
- [ ] Verify alerts fire correctly
- [ ] Verify auto-recovery works

---

## Output: Fortification Report

### Summary Template

```markdown
# Infrastructure Fortification Report
**Project:** ___________
**Date:** ___________
**Auditor:** ___________

## Executive Summary
- Total servers audited: ___
- Critical issues found: ___
- High priority issues: ___
- Medium priority issues: ___

## Critical Issues (Fix Immediately)
1. [ ] Issue description
   - Impact: ___
   - Fix: ___
   - ETA: ___

## High Priority (Fix This Week)
1. [ ] Issue description
   - Impact: ___
   - Fix: ___
   - ETA: ___

## Medium Priority (Fix This Month)
1. [ ] Issue description
   - Impact: ___
   - Fix: ___
   - ETA: ___

## Capacity Status
- Memory headroom: ___% (Target: >15%)
- CPU headroom: ___% (Target: >30%)
- Disk headroom: ___% (Target: >20%)

## Monitoring Coverage
- Memory alerts: ✅/❌
- CPU alerts: ✅/❌
- Disk alerts: ✅/❌
- Service health: ✅/❌
- OOM detection: ✅/❌

## Resource Limits Coverage
- Systemd services: ___% with limits
- Cron jobs: ___% with limits
- Web server: Properly sized ✅/❌
- Database: Properly configured ✅/❌

## Next Steps
1. [ ] Fix critical issues
2. [ ] Deploy monitoring gaps
3. [ ] Implement capacity review process
4. [ ] Load test infrastructure
5. [ ] Update runbooks
```

---

## Checklist Summary

### Must-Have (Immediate)
- [ ] Memory limits on all systemd services
- [ ] Resource limits on all cron jobs
- [ ] Web server MaxRequestWorkers properly sized
- [ ] Basic memory/CPU/disk alerts configured
- [ ] OOM kill detection enabled
- [ ] At least 15% memory headroom

### Should-Have (This Week)
- [ ] Comprehensive monitoring (7 memory alerts)
- [ ] Database resource limits configured
- [ ] Service-specific health monitoring
- [ ] Swap usage alerts
- [ ] Disk inode monitoring

### Nice-to-Have (This Month)
- [ ] Load testing completed
- [ ] Capacity review process established
- [ ] Growth forecasting implemented
- [ ] Runbooks created and tested
- [ ] Chaos testing scenarios validated
- [ ] Historical trend analysis dashboard

---

## Reference: Common Pitfalls

### Pitfall #1: "It's been fine for years"
**Reality:** Workload grows, services are added, capacity isn't reviewed
**Fix:** Regular capacity reviews, even if "nothing has changed"

### Pitfall #2: "We'll add more RAM if needed"
**Reality:** You find out it's needed when the system is down
**Fix:** Proactive monitoring, maintain headroom

### Pitfall #3: "Default settings are fine"
**Reality:** Defaults are rarely optimal for your workload
**Fix:** Calculate and validate all resource limits

### Pitfall #4: "We monitor CPU and disk, that's enough"
**Reality:** Memory exhaustion is silent until OOM
**Fix:** Comprehensive memory monitoring and limits

### Pitfall #5: "Alerts fire too often, we'll ignore them"
**Reality:** Alert fatigue leads to missed critical events
**Fix:** Tune alerts properly, two-tier (warning/critical)

### Pitfall #6: "The developer said it only needs 512MB"
**Reality:** Estimates are often wrong, traffic varies
**Fix:** Measure actual usage, maintain headroom

### Pitfall #7: "We reboot servers monthly, that clears leaks"
**Reality:** Reboots mask problems, don't fix root cause
**Fix:** Fix memory leaks, use MaxConnectionsPerChild

### Pitfall #8: "We'll scale when we get an alert"
**Reality:** Scaling takes time, alert means problem is NOW
**Fix:** Scale before alerts, maintain headroom

---

## Action Plan Template

```markdown
# Infrastructure Fortification Action Plan
**Project:** ___________

## Phase 1: Assessment (Week 1)
- [ ] Run full audit using this checklist
- [ ] Generate fortification report
- [ ] Prioritize issues (Critical/High/Medium)
- [ ] Estimate effort for each fix

## Phase 2: Critical Fixes (Week 1-2)
- [ ] Deploy systemd resource limits
- [ ] Deploy cron job wrapper
- [ ] Fix web server worker limits
- [ ] Deploy basic memory alerts

## Phase 3: Monitoring (Week 2-3)
- [ ] Deploy comprehensive alert suite
- [ ] Configure alert routing
- [ ] Test alerts fire correctly
- [ ] Create monitoring dashboard

## Phase 4: Capacity Planning (Week 3-4)
- [ ] Analyze historical usage trends
- [ ] Calculate current headroom
- [ ] Forecast growth
- [ ] Plan scaling timeline

## Phase 5: Documentation (Week 4)
- [ ] Create/update runbooks
- [ ] Document all resource limits
- [ ] Document capacity planning process
- [ ] Train team on new procedures

## Phase 6: Validation (Week 5)
- [ ] Load test infrastructure
- [ ] Verify alerts fire under load
- [ ] Test auto-recovery scenarios
- [ ] Validate runbooks

## Phase 7: Continuous Improvement
- [ ] Schedule quarterly capacity reviews
- [ ] Establish on-call runbook review process
- [ ] Track incidents and update procedures
- [ ] Review and update limits as workload changes
```

---

**Last Updated:** Based on INC-20260131-001 (January 31, 2026)
**Lessons Learned:** Memory exhaustion from undersized infrastructure + missing resource limits
**Prevention:** Defense-in-depth (Infrastructure + App Limits + Monitoring)
