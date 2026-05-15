---
name: docker-audit
description: Audit Docker implementation (Dockerfiles, compose, security hardening) against project standards
user_invocable: true
---

## Tracking

As your **first action**, before any other work, run:
```bash
~/.claude/scripts/track-command.sh --command "docker-audit" --event start
```

If the workflow encounters an unrecoverable error at any point, run:
```bash
~/.claude/scripts/track-command.sh --command "docker-audit" --event error \
  --model "MODEL_ID" \
  --error-msg "brief description of what failed"
```

You are a Docker implementation auditor. Audit a project's Docker setup against the standards defined in `~/.claude/docs/reference/docker.md` using both built-in checks and industry-standard tools.

## Scoring Categories

### Standard Checks (always run)

The full checklist items (D1-D23, C1-C25) are defined in `~/.claude/docs/reference/docker.md` under "Audit Requirements". The script phase and LLM phase together should verify all of them. The items map to these scoring categories:

| Category | Default Weight | With Image Scan | What It Checks |
|----------|---------------|-----------------|----------------|
| Security Hardening | 25% | 18% | D6-D12, C1-C6: read_only, no-new-privileges, cap_drop, resource limits, secrets management (secrets key, service mounts, .gitignore, SECRETS_PATH), init process, volume security, no secrets in compose, Trivy config, Dockle CIS |
| Compose Structure | 15% | 12% | C18-C22: V2 syntax, base+override, env vars, naming, container name uniqueness, .env.example |
| Base Image | 15% | 10% | D1-D5: **DHI preferred** (`dhi.io/*`), Debian slim fallback, multi-stage, testing stage, non-root user, COPY --chown, Hadolint lint |
| Build Performance | 10% | 8% | D13-D20: Layer cache order, dep file separation, layer consolidation, multi-stage copy, cache cleanup, dev deps excluded, unnecessary files |
| Operations | 15% | 10% | C11-C17: Health checks (with completeness: timeout/retries/start_period), depends_on (list+map), restart policy, stop_grace_period, logging |
| Version Pinning | 10% | 7% | D3, C16: All images pinned, no :latest tags, staleness vs Docker Hub |
| Networking & CI | 10% | 5% | C11-C11c, C23-C25, D14, D18: Network segmentation (public/private), port exposure, no external nets in base, RUN_TESTS, .dockerignore (exists + content validation), DHI CI/CD access |

### Image Scan Categories (with `--with-image-scan`)

| Category | Weight | Tool | What It Checks |
|----------|--------|------|----------------|
| Vulnerability Scan | 20% | Trivy image | CVEs in built images (HIGH/CRITICAL) |
| Image Efficiency | 10% | Dive | Layer efficiency, wasted space |

### External Tools Integration

| Tool | Category | Type | Install |
|------|----------|------|---------|
| **Hadolint** | Base Image | Static (Dockerfile lint) | `brew install hadolint` |
| **Trivy** (config) | Security | Static (misconfiguration scan) | `brew install trivy` |
| **Trivy** (image) | Vulnerability | Image scan (CVEs) | `brew install trivy` |
| **Dockle** | Security | Image scan (CIS benchmark) | `brew install goodwithtech/r/dockle` |
| **Dive** | Efficiency | Image scan (layer analysis) | `brew install dive` |

All tools are **auto-detected** and gracefully skipped if not installed. The audit works without any external tools but scores improve with more data points.

**Rating Scale**:
- 90-100: EXCELLENT - Production ready
- 70-89: GOOD - Minor improvements needed
- 50-69: FAIR - Several issues to address
- 0-49: NEEDS WORK - Significant gaps

---

## 1. Run Deterministic Scan

I will run the audit script which performs all deterministic checks and external tool scans. Arguments from the user invocation are passed through.

**Full audit** (default -- includes Hadolint + Trivy config if installed):
```bash
python3 ~/.claude/scripts/docker-audit.py --stage all
```

**Full audit with image scanning** (also runs Trivy image, Dockle, Dive on built images):
```bash
python3 ~/.claude/scripts/docker-audit.py --stage all --with-image-scan
```

**Quick validation** (fewer checks, first Dockerfile only, no external tools):
```bash
python3 ~/.claude/scripts/docker-audit.py --stage all --quick
```

**Skip external tools** (only built-in checks):
```bash
python3 ~/.claude/scripts/docker-audit.py --stage all --skip-external
```

**Compare with previous snapshot** (shows deltas per category):
```bash
python3 ~/.claude/scripts/docker-audit.py --stage all --compare
```

The script outputs structured JSON (schema v2) with all findings and scores to stdout, writes to `/tmp/docker-audit-result.json`, and saves a snapshot to `docs/audits/docker/<timestamp>-<commit>.json`.

**Consolidation** — run after audits to create weekly/monthly rollups:
```bash
python3 ~/.claude/scripts/docker-audit-consolidate.py              # Human-readable
python3 ~/.claude/scripts/docker-audit-consolidate.py --format json # JSON output
```

---

## 2. Analyze Results (LLM Phase)

After the script completes, I will read the JSON output and provide qualitative analysis.

### A. Read the Audit Data
Read `/tmp/docker-audit-result.json` to get the full structured results.

If external tools ran, also read their detailed output:
- `/tmp/docker-audit-hadolint.json` -- Hadolint findings per Dockerfile
- `/tmp/docker-audit-trivy-config.json` -- Trivy misconfiguration details
- `/tmp/docker-audit-trivy-image.json` -- Trivy CVE details per image
- `/tmp/docker-audit-dockle.json` -- Dockle CIS findings per image
- `/tmp/docker-audit-dive.txt` -- Dive efficiency analysis per image

### B. DHI (Docker Hardened Images) Check — LLM Phase

**This check is performed by the LLM, not the script.** After reading the audit JSON, parse every `FROM` line in every Dockerfile and every `image:` line in compose files. For each base image:

1. **Check if it uses DHI**: Does the image reference start with `dhi.io/`?
2. **Check if a DHI alternative exists**: Compare the image name against the known DHI catalog. Key images available as DHI:
   - **Runtimes**: node, python, golang, ruby, rust, php, bun, deno, dotnet, erlang, dart, java (temurin/corretto)
   - **Databases**: mysql, postgresql, redis, valkey, mongodb, elasticsearch, couchdb, influxdb, neo4j, opensearch, clickhouse
   - **Infrastructure**: nginx, traefik, haproxy, caddy, envoy, redis, memcached, rabbitmq, kafka, nats, mosquitto
   - **Monitoring**: prometheus, grafana, loki, tempo, alertmanager, uptime-kuma, opensearch-dashboards
   - **CI/CD**: jenkins, k6, sonarqube, flyway, liquibase
   - **Security**: vault, keycloak, trivy, gitleaks, trufflehog, clamav, dex
   - **Base**: alpine (as `dhi.io/alpine`), debian (as `dhi.io/debian`), busybox, static (distroless-like)
   - **Tools**: curl, bash, helm, kubectl, aws-cli, docker

3. **Scoring impact** (applied to Base Image category):
   - Using `dhi.io/*` → **pass** (full points)
   - Using Docker Official Image where DHI exists → **warn** ("DHI alternative available: `dhi.io/<name>`")
   - Using non-official image where DHI exists → **fail** ("Use DHI: `dhi.io/<name>` instead")
   - Using image with no DHI equivalent → **pass** (no penalty)
   - Using `nixos/nix` in any stage → **fail** ("NixOS eliminated from standard; use DHI `-dev` images for build stages") [D4]
   - Using Alpine for Node.js/Python runtime → **warn** ("Alpine has musl libc compatibility issues; use DHI Debian-based images") [D5]
   - Using `cgr.dev/*` (Chainguard) → **warn** ("Chainguard is paid; use DHI `dhi.io/<name>` instead")

4. **Report format** — add a "DHI Compliance" subsection to the report:
   ```
   DHI Compliance:
     ✓ dhi.io/node:22 (backend Dockerfile)
     ⚠ node:22-alpine → DHI available: dhi.io/node:22; Alpine has musl issues [D5] (frontend Dockerfile)
     ⚠ mysql:8.4 → DHI available: dhi.io/mysql:8.4 (docker-compose.yml)
     ✗ nixos/nix:2.34.0 → FAIL: NixOS eliminated; use dhi.io/<runtime>-dev [D4] (backend Dockerfile)
     ✓ custom-app:latest (no DHI equivalent)
   ```

**Registry**: `dhi.io/<image>` — free with Docker Hub account. Login strongly recommended for rate limits.
**Catalog**: https://hub.docker.com/hardened-images/catalog
**Never recommend Chainguard** (`cgr.dev`) — commercial/paid product.

### C. Build Performance Check — LLM Phase

**This check is performed by the LLM, not the script.** Read each Dockerfile and analyze instruction ordering, layer caching, and final image size optimization.

**Checks to perform** (for each Dockerfile):

1. **Layer cache optimization** — Are infrequently-changing instructions before frequently-changing ones?
   - **pass**: System deps (`apt-get`, `apk add`) → dependency files (`package.json`, `requirements.txt`) → dependency install (`npm ci`, `pip install`) → source code (`COPY . .`) → build
   - **fail**: Source code copied before dependency install (every code change invalidates the dep cache)
   - **fail**: `COPY . .` appears before `npm ci` / `pip install` / `go mod download`

2. **Dependency caching** — Are dependency files copied separately before full source?
   - **pass**: `COPY package.json package-lock.json ./` then `RUN npm ci` then `COPY . .`
   - **fail**: Single `COPY . .` before `npm ci` (no layer caching for deps)

3. **Layer consolidation** — Are sequential `RUN` commands combined where appropriate?
   - **warn**: Multiple `RUN apt-get` commands that could be one (each creates a layer)
   - **pass**: `RUN apt-get update && apt-get install -y ... && rm -rf /var/lib/apt/lists/*` in one line

4. **Multi-stage copy efficiency** — Does the final stage only copy what's needed?
   - **pass**: `COPY --from=build /app/dist ./dist` (specific paths)
   - **warn**: `COPY --from=build /app .` (copies everything including dev artifacts)

5. **Apt/package cache cleanup** — Are package manager caches cleaned in the same layer?
   - **pass**: `apt-get install ... && rm -rf /var/lib/apt/lists/*` in same `RUN`
   - **fail**: `rm -rf /var/lib/apt/lists/*` in a separate `RUN` (doesn't reduce layer size)

6. **Dev dependencies in production** — Are dev dependencies excluded from the final image?
   - **pass**: `npm ci --omit=dev` or separate build/production stages
   - **warn**: `npm install` without `--omit=dev` in the production stage

7. **Unnecessary files in final image** — Are tests, docs, source maps excluded?
   - **warn**: `.ts` source files present alongside compiled `.js` in final stage
   - **pass**: Only compiled output + `node_modules` (production) in final stage

**Scoring** — Weighted pass rate method. Each check has a weight reflecting its build-time/size impact. Score = `sum(weight × result) / total_weight × 100` where result = 1.0 (pass), 0.5 (warn), 0.0 (fail).

| # | Check | Weight | Why this weight |
|---|-------|--------|-----------------|
| 1 | Layer cache order | 25 | Biggest build time impact — wrong order invalidates cache on every change |
| 2 | Dep file separation | 20 | Enables dependency layer caching |
| 3 | Multi-stage copy efficiency | 15 | Dev artifacts in production image |
| 4 | Dev deps excluded | 15 | Attack surface + image size |
| 5 | Unnecessary files in final | 10 | Source/tests in production |
| 6 | Layer consolidation | 10 | Extra layers add marginal size |
| 7 | Package cache cleanup | 5 | Small size impact |
| **Total** | | **100** | |

**Per-service scoring**: Score each Dockerfile independently, then average across all services for the category score.

**Report format**:
```
Build Performance: 55/100 (FAIR)
  ✗ [25] Layer cache order — source copied before deps (backend/Dockerfile)
  ✗ [20] Dep file separation — single COPY before npm ci (backend/Dockerfile)
  ✓ [15] Multi-stage copy — only dist/ copied to final stage
  ✓ [15] Dev deps excluded — npm ci --omit=dev in production
  ⚠ [10] Unnecessary files — .ts source alongside .js in final (5/10)
  ✓ [10] Layer consolidation — RUN commands properly combined
  ✓ [ 5] Package cache — apt cleanup in same layer
```

This score feeds into the overall weighted score as the "Build Performance" category (10% default weight).

### D. Contextual Analysis

For each **failed** check, I will:
1. Explain **why** this matters (security risk, operational impact, deviation from standard)
2. Provide a **specific fix** with code snippet referencing the project's actual files
3. Estimate **effort** (trivial / small / medium)

For each **warning**, I will:
1. Explain the tradeoff
2. Recommend whether to fix now or defer
3. Note if it blocks deployment

### E. Per-Service Analysis

For each service in `service_scores`, I will:
1. Show the service's overall score and grade
2. Identify the service's weakest category
3. Highlight service-specific issues (e.g., one service missing read_only while others have it)
4. Flag services that drag down the overall score

### F. External Tool Insights

For tools that ran, I will provide specific remediation:
- **Hadolint**: Map each rule violation to a fix (e.g., DL3006 -> pin version, DL3008 -> clean apt cache)
- **Trivy config**: Explain each misconfiguration and its CIS/NIST reference
- **Trivy image**: List CVEs by severity with upgrade paths
- **Dockle**: Map CIS-DI rules to Docker best practices
- **Dive**: Identify wasteful layers and suggest multi-stage optimizations

### G. Cross-Category Insights

I will look for patterns across categories:
- Security gaps that compound (e.g., no read_only + no cap_drop = high risk)
- Missing operational patterns (e.g., health checks without depends_on)
- Compose structure issues that affect deployment reliability
- Image vulnerabilities that could be fixed by base image updates

### H. Priority Action Plan

I will generate a prioritized list of fixes:

**P0 - Must Fix (blocks deployment)**:
- Critical CVEs in images
- CIS benchmark failures (FATAL)
- Security hardening failures
- Secret leaks in compose/env

**P1 - Should Fix (before next release)**:
- High CVEs in images
- Hadolint errors
- Missing health checks
- Missing override file patterns

**P2 - Nice to Have (improvements)**:
- Hadolint warnings
- Image efficiency optimization
- Logging configuration
- Resource limit tuning

---

## 3. Generate Report

I will present the findings in a structured format:

```
Docker Implementation Audit
================================================================

Project: ${PROJECT_NAME}
Date: ${DATE}
Mode: ${FULL_OR_QUICK}

Overall Score: ${OVERALL}/100 (${STATUS})

Category Breakdown:
  Security Hardening:   ${SCORE}/100  (weight: ${W}%)
  Compose Structure:    ${SCORE}/100  (weight: ${W}%)
  Base Image:           ${SCORE}/100  (weight: ${W}%)
  Operations:           ${SCORE}/100  (weight: ${W}%)
  Version Pinning:      ${SCORE}/100  (weight: ${W}%)
  Networking & CI:      ${SCORE}/100  (weight: ${W}%)
  Vulnerability Scan:   ${SCORE}/100  (weight: ${W}%)  [if image scan]
  Image Efficiency:     ${SCORE}/100  (weight: ${W}%)  [if image scan]

Per-Service Scores:
  ${SERVICE_1}: ${SCORE}/100 (${GRADE}) - ${PASS} pass, ${WARN} warn, ${FAIL} fail
  ${SERVICE_2}: ${SCORE}/100 (${GRADE}) - ${PASS} pass, ${WARN} warn, ${FAIL} fail
  ...

External Tools:
  Hadolint:      ${AVAILABLE} / ${RAN}
  Trivy config:  ${AVAILABLE} / ${RAN}
  Trivy image:   ${AVAILABLE} / ${RAN}
  Dockle:        ${AVAILABLE} / ${RAN}
  Dive:          ${AVAILABLE} / ${RAN}

Checks: ${PASSED} passed, ${FAILED} failed, ${WARNINGS} warnings

Top Issues:
${PRIORITIZED_FINDINGS}

Recommendations:
${ACTION_PLAN}
```

### Reference Document

For any failed check, I will cite the specific section from `~/.claude/docs/reference/docker.md` that defines the standard.

---

## 4. Offer Follow-Up Actions

Based on the audit results:

**If score >= 90**:
- "Docker setup looks excellent. No critical issues."
- Suggest running `/pipeline-audit` next if not done
- If no image scan was done, suggest `--with-image-scan` for deeper analysis

**If score 70-89**:
- List the specific fixes needed
- Offer to implement P0 fixes now
- "Run `/docker-audit` again after fixes to verify"
- If external tools weren't installed, recommend installing them for better coverage

**If score 50-69**:
- Show prioritized fix plan
- Offer to fix critical issues (security hardening, compose structure)
- "Consider `/docker-hardening` for comprehensive security fixes"

**If score < 50**:
- Flag this as high-risk for deployment
- Recommend `/dockerfile-build` if Dockerfile needs major rework
- Provide step-by-step remediation plan

---

## 5. Document Results

After presenting the report and follow-up actions, **always** prompt the user using `AskUserQuestion` to ask how they want to document the audit results:

**Options**:
1. **Create as task** — Use `/task-capture` to create a TSK document with the findings as requirements and the priority action plan as acceptance criteria. Good when the fixes need tracking through the task workflow.
2. **Save as document** — Use `~/.claude/scripts/new-doc.sh --type AUD --description "docker-audit" --new --json` to get a template and filepath, fill it with the audit scores, findings, and recommendations, then write it. Good for record-keeping without a task workflow.
3. **Skip documentation** — Don't create any document. The audit results were shown in the conversation and the raw JSON is at `/tmp/docker-audit-result.json`.

**After the user answers**:

- **Task**: Ask a **second question** using `AskUserQuestion` to determine which severity levels to include:
  1. **Critical only (P0)** — Only must-fix items that block deployment (critical CVEs, CIS failures, security hardening failures, secret leaks)
  2. **Critical + Important (P0+P1)** (Recommended) — Adds should-fix items before next release (high CVEs, Hadolint errors, missing health checks, missing overrides)
  3. **All findings (P0+P1+P2)** — Includes nice-to-have improvements (Hadolint warnings, efficiency, logging, resource tuning)

  Then filter the findings to the selected level and run `/task-capture Docker audit findings: ${FILTERED_ISSUES_SUMMARY}` passing only the issues at or above the chosen severity. Include the overall score in the task description for context.

- **Document**: Get template via `new-doc.sh`, fill sections (scores table, per-service breakdown, findings, priority action plan, recommendations), write to the filepath, then commit. Always includes all findings regardless of severity.
- **Skip**: Proceed to completion tracking

---

## Important Notes

- **Non-destructive**: Only reads files and scans images, makes no changes
- **Repeatable**: Safe to run multiple times
- **PROJECT.yaml required**: Script reads Docker config from PROJECT.yaml
- **Quick mode**: Use `--quick` for fast validation (first Dockerfile only, no external tools, no staleness API calls)
- **External tools**: Auto-detected, gracefully skipped if not installed
- **Image scans**: Require `--with-image-scan` flag AND images built locally
- **Version staleness**: Full mode queries Docker Hub API (skipped for private registries)
- **Raw tool output**: Saved to `/tmp/docker-audit-*.json` for detailed LLM analysis
- **Reference**: All checks are derived from `~/.claude/docs/reference/docker.md`

---

## Completion Tracking

When the workflow completes successfully, run:
```bash
~/.claude/scripts/track-command.sh --command "docker-audit" --event complete \
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
