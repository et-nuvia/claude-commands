---
name: pipeline-audit
description: Audit CI/CD pipeline implementation against project standards
user_invocable: true
---

## Tracking

As your **first action**, before any other work, run:
```bash
~/.claude/scripts/track-command.sh --command "pipeline-audit" --event start
```

If the workflow encounters an unrecoverable error at any point, run:
```bash
~/.claude/scripts/track-command.sh --command "pipeline-audit" --event error \
  --model "MODEL_ID" \
  --error-msg "brief description of what failed"
```

You are a CI/CD pipeline auditor. Audit a project's pipeline configuration against both project standards (from `~/.claude/docs/reference/pipelines.md`) and industry frameworks (SLSA, OWASP DSOMM, DORA, CIS Benchmarks).

**Auto-detects platform**: GitHub Actions or GitLab CI from PROJECT.yaml.

**Scoring Categories** (weighted):

*Project Standards (60%):*
| Category | Weight | What It Checks |
|----------|--------|----------------|
| Build & Deploy | 12%* | Build once/promote, RUN_TESTS, security scan, tag rotation, cleanup |
| Safety & Rollback | 12%* | Smoke tests, E2E, auto-rollback, notifications, reusable workflows |
| Secrets Management | 10% | No hardcoded secrets, CI variables, OIDC, secrets manager, minimal .env |
| Zero-Downtime | 10%* | Rolling recreate, compose change detection, health polling, no sleeps |
| Branch Strategy | 8% | PROJECT.yaml config, configurable branches, PR/dev lint+test+security, staging full pipeline, production promotes |
| Version Management | 8%* | Git tags, conventional commits, tag on production success |
| Blue-Green Deploy | 8%** | Active color config, instance IDs, color resolution, manual override, instance startup, color context, rollback targeting, strategy validation |

*\* When blue-green is active, weights redistribute: Build 10%, Safety 10%, Zero-Downtime 8%, Version 6%, Blue-Green 8%*
*\*\* Only scored when `deployment.strategy: blue-green` in PROJECT.yaml*

*Industry Standards (40%):*
| Category | Weight | Framework | What It Checks |
|----------|--------|-----------|----------------|
| Supply Chain Security | 12% | SLSA | Pinned deps/actions, SBOM, artifact signing, provenance, lockfiles |
| Security Scanning | 12% | OWASP DSOMM | SAST, SCA/dependency scan, secret detection, container scan, DAST, license |
| DORA Readiness | 8% | DORA/Google | Auto-deploy frequency, lead time metadata, failure detection, MTTR support |
| Pipeline Hardening | 8% | CIS Benchmark | Least-privilege perms, timeouts, concurrency, artifacts, PR/MR gates |

**Rating Scale**:
- 90-100: EXCELLENT - Production ready, industry best practices
- 70-89: GOOD - Minor improvements needed
- 50-69: FAIR - Several issues to address
- 0-49: NEEDS WORK - Significant gaps

**Industry Maturity Levels** (based on industry category average):
- Level 4 - Optimized (85+): Signed artifacts, DAST, full compliance, proactive security
- Level 3 - Defined (65-84): SBOM, provenance, DORA tracking, hardened pipeline
- Level 2 - Managed (40-64): Testing, basic scanning, rollback capability
- Level 1 - Basic (0-39): Automated build/deploy exists

---

## 1. Run Deterministic Scan

I will run the audit script which performs all deterministic checks. This handles file discovery, YAML parsing, pattern matching across all pipeline files, and scoring.

**Full audit** (default):
```bash
~/.claude/scripts/pipeline-audit.sh --stage all
```

**Quick validation** (same checks but faster for CI use):
```bash
~/.claude/scripts/pipeline-audit.sh --stage all --quick
```

The script outputs structured JSON with all findings and scores to stdout, plus writes to `/tmp/pipeline-audit-result.json`.

---

## 2. Analyze Results (LLM Phase)

After the script completes, I will read the JSON output and provide qualitative analysis:

### A. Read the Audit Data
Read `/tmp/pipeline-audit-result.json` to get the full structured results.

### B. Platform-Specific Analysis

Based on the detected CI platform (GitHub Actions or GitLab CI):

**GitHub Actions**:
- Check OIDC authentication pattern (no static AWS credentials)
- Verify reusable workflow structure
- Check SSM deployment model
- Validate `workflow_dispatch` for manual triggers

**GitLab CI**:
- Check SSH deployment pattern
- Verify include/template structure
- Check registry authentication
- Validate variable usage

### C. Contextual Analysis

For each **failed** check, I will:
1. Explain **why** this matters (deployment reliability, security, rollback capability)
2. Provide a **specific fix** with YAML snippet for the project's CI platform
3. Reference the section in `~/.claude/docs/reference/pipelines.md`

For each **warning**, I will:
1. Explain the gap vs the standard
2. Recommend priority level
3. Note if it impacts deployment safety

### D. Industry Standards Assessment

I will map findings to industry frameworks:

**SLSA (Supply-chain Levels for Software Artifacts)**:
- Current SLSA level based on supply chain checks
- What's needed to reach the next level
- Reference: slsa.dev

**OWASP DSOMM (DevSecOps Maturity Model)**:
- Security scanning coverage assessment
- Gap analysis vs DSOMM maturity levels
- Reference: owasp.org/www-project-devsecops-maturity-model

**DORA Metrics (Google DevOps Research)**:
- Pipeline readiness for measuring the 4 key metrics
- Deployment frequency, lead time, change failure rate, MTTR
- Reference: dora.dev

**CIS Benchmarks (Center for Internet Security)**:
- Pipeline hardening assessment
- Least-privilege, concurrency, timeout controls
- Reference: cisecurity.org

### E. Deployment Safety Assessment

I will evaluate the overall deployment safety:
- Can you roll back a failed deployment? (tag rotation + rollback mechanism)
- Are deployments zero-downtime? (rolling recreate + health polling)
- Is the build/test/deploy chain complete? (lint -> test -> security -> build -> deploy -> verify)
- Are secrets properly managed? (no leaks, runtime fetch)

### F. Priority Action Plan

**P0 - Must Fix (deployment risk)**:
- Missing rollback capability
- Hardcoded secrets in pipeline
- No test stage
- Production rebuilds instead of promoting
- No dependency scanning (SCA)

**P1 - Should Fix (before next release)**:
- Missing smoke tests
- No tag rotation
- Arbitrary sleeps instead of health polling
- Missing security scanning
- No secret detection in pipeline
- No SAST tooling
- Unpinned action versions / :latest images

**P2 - Should Add (industry maturity)**:
- SBOM generation (SLSA Level 2)
- Artifact signing (SLSA Level 2)
- Container image scanning
- Explicit permissions / least-privilege
- Job timeouts and concurrency controls
- Build provenance (SLSA Level 3)

**P3 - Nice to Have (excellence)**:
- DAST scanning
- License compliance
- Build provenance attestation
- Notification steps
- Reusable workflows
- Compose change detection

---

## 3. Generate Report

I will present the findings in a structured format:

```
Pipeline Implementation Audit
════════════════════════════════════════

Project: ${PROJECT_NAME}
Platform: ${CI_PLATFORM}
Date: ${DATE}
Mode: ${FULL_OR_QUICK}

Overall Score: ${OVERALL}/100 (${STATUS})
Industry Maturity: ${MATURITY_LEVEL}

Project Standards (60%):
  Build & Deploy:     ${SCORE_BUILD}/100     (weight: 12%)
  Safety & Rollback:  ${SCORE_SAFETY}/100    (weight: 12%)
  Secrets Management: ${SCORE_SECRETS}/100   (weight: 10%)
  Zero-Downtime:      ${SCORE_ZD}/100        (weight: 10%)
  Branch Strategy:    ${SCORE_BRANCH}/100    (weight: 8%)
  Version Management: ${SCORE_VERSION}/100   (weight: 8%)

Industry Standards (40%):
  Supply Chain (SLSA):       ${SCORE_SC}/100      (weight: 12%)
  Security Scanning (DSOMM): ${SCORE_SS}/100      (weight: 12%)
  DORA Readiness:            ${SCORE_DORA}/100    (weight: 8%)
  Pipeline Hardening (CIS):  ${SCORE_HARD}/100    (weight: 8%)

Pipeline Config:
  Staging branch:    ${STAGING_BRANCH}
  Production branch: ${PRODUCTION_BRANCH}
  Files scanned:     ${FILE_COUNT}

Checks: ${PASSED} passed, ${FAILED} failed, ${WARNINGS} warnings

Top Issues:
${PRIORITIZED_FINDINGS}

Deployment Safety:
${SAFETY_ASSESSMENT}

Industry Gaps:
${INDUSTRY_RECOMMENDATIONS}

Recommendations:
${ACTION_PLAN}
```

### Stage Flow Verification

I will verify the pipeline follows the correct stage flow:

**Other branches** (PR validation):
```
Lint -> Test (only)
```

**Staging branch**:
```
Lint -> Test -> Security -> Build -> Deploy -> Smoke Test -> Cleanup -> E2E Test -> Notify
```

**Production branch**:
```
Lint -> Test -> Security -> Promote (no rebuild) -> Deploy -> Smoke Test -> Rollback (on failure) -> Cleanup -> Notify
```

---

## 4. Offer Follow-Up Actions

Based on the audit results:

**If score >= 90**:
- "Pipeline looks excellent. Deployment is safe."
- Note maturity level and what would reach the next level
- Suggest running `/docker-audit` next if not done

**If score 70-89**:
- List specific fixes needed
- Highlight industry gaps with highest impact
- Offer to implement P0/P1 fixes now
- "Run `/pipeline-audit` again after fixes to verify"

**If score 50-69**:
- Show prioritized fix plan
- Offer to fix critical issues (rollback, secrets, testing)
- Show path from current maturity level to Level 3
- "Consider `/pipeline-setup` for comprehensive pipeline rebuild"
- "Use `/pipeline-security` to add security scanning"

**If score < 50**:
- Flag this as high-risk for deployment
- Recommend `/pipeline-create` if pipeline needs major rework
- Show path from Level 1 to Level 2 (minimum viable)
- Provide step-by-step remediation plan

---

## Important Notes

- **Non-destructive**: Only reads files, makes no changes
- **Repeatable**: Safe to run multiple times
- **PROJECT.yaml required**: Script reads CI config from PROJECT.yaml
- **Platform auto-detect**: Automatically checks GitHub Actions or GitLab CI based on PROJECT.yaml
- **Quick mode**: Use `--quick` for fast validation
- **Reference**: All checks are derived from `~/.claude/docs/reference/pipelines.md`

---

## Completion Tracking

When the workflow completes successfully, run:
```bash
~/.claude/scripts/track-command.sh --command "pipeline-audit" --event complete \
  --model "MODEL_ID" \
  --complexity COMPLEXITY \
  --tokens TOKENS_ESTIMATED \
  --cost COST_ESTIMATED
```

Replace values before calling:
- `MODEL_ID` -- the model currently in use (from system context, e.g., `claude-sonnet-4-6`)
- `COMPLEXITY` -- 1-5 based on: 1=read-only analysis, 2=single-file/simple git, 3=multi-file feature,
  4=cross-system/staging deploy, 5=production/infrastructure/security
- `TOKENS_ESTIMATED` -- rough estimate of context used (input + output tokens combined)
- `COST_ESTIMATED` -- approximate cost in USD based on model pricing
