---
command: docker-audit
group: audit
backing_script: ~/.claude/scripts/docker-audit.py
mutates: []
runtime: ~30-120s (--with-image-scan: ~5-10min)
destructive: false
requires_project_yaml: required
project_yaml_fields:
  - components
  - docker.services
requires_project_knowledge: none
project_knowledge_sections: []
---

# /docker-audit

Audits a project's Docker setup — Dockerfiles, Compose files, and security
hardening — against project standards and CIS benchmarks, producing a weighted
0-100 score plus a P0–P3 action plan. Optionally runs image-layer scanning
(Trivy, Dockle, Dive) when built images are available. Makes no changes; safe
to run repeatedly.

> **Config:** PROJECT.yaml **required** — reads `components` (discovers services) and `docker.services` (optional, for per-service overrides)

---

## When to use it

- Before deploying a new service to staging or production
- After Dockerfile or Compose edits, to confirm the score moved the right direction
- Periodic security / CIS compliance review

## Usage

```bash
/docker-audit [--quick] [--with-image-scan] [--skip-external] [--compare]
```

**Common invocations:**

```bash
/docker-audit                        # full audit, auto-detects external tools
/docker-audit --quick                # fast validation, first Dockerfile only, no external tools
/docker-audit --with-image-scan      # add Trivy image + Dockle + Dive on built images
/docker-audit --skip-external        # built-in checks only, no Hadolint/Trivy/Dockle/Dive
/docker-audit --compare              # diff vs previous snapshot in docs/audits/docker/
```

## Arguments

| Argument / Flag | Required | Description |
|---|---|---|
| `--quick` | No | First Dockerfile only, no external tools, no Docker Hub staleness API calls |
| `--with-image-scan` | No | Run Trivy image scan + Dockle CIS + Dive layer analysis on locally built images |
| `--skip-external` | No | Suppress Hadolint, Trivy config, and all image scan tools |
| `--compare` | No | Show per-category deltas against the most recent snapshot |

## Dependencies

**External commands / packages** (must be on `PATH`; all auto-detected and gracefully skipped if absent):

| Dependency | Why it's needed | Install |
|---|---|---|
| `python3` | Runs the audit script | preinstalled |
| `hadolint` | Dockerfile static lint (DL-rule violations) | `brew install hadolint` |
| `trivy` | Config misconfiguration scan + optional CVE image scan | `brew install trivy` |
| `dockle` | CIS-DI benchmark scan on built images | `brew install goodwithtech/r/dockle` |
| `dive` | Layer efficiency analysis on built images | `brew install dive` |
| `jq` | Build / consume result JSON | `brew install jq` |

**Project files consumed:**

- `PROJECT.yaml` (PY) — Yes. Required: `components` (service list). Optional: `docker.services`.
- `PROJECT-KNOWLEDGE.md` (PK) — No
- `Dockerfile`, `Dockerfile.*`, `*/Dockerfile` — artifacts audited
- `docker-compose*.yml` — artifacts audited
- `~/.claude/docs/reference/docker.md` — source-of-truth for project standards
- `/tmp/docker-audit-result.json` — written for the LLM phase
- `/tmp/docker-audit-hadolint.json`, `/tmp/docker-audit-trivy-*.json`, `/tmp/docker-audit-dockle.json`, `/tmp/docker-audit-dive.txt` — per-tool detail files (when tools ran)
- `docs/audits/docker/<timestamp>-<commit>.json` — snapshot saved after every full run

## Backing script

**Script**: `~/.claude/scripts/docker-audit.py`

Heavy script / light LLM: the script does **all** deterministic scoring. The
LLM adds DHI compliance analysis, build-performance analysis, contextual
explanations, and per-finding remediation snippets on top of the JSON.

**Inputs:** CLI flags listed above. Reads `PROJECT.yaml` for component/service
discovery. Invokes optional external tools if present.

**Outputs (structured JSON schema v2, to stdout and `/tmp/docker-audit-result.json`):**

- `overall_score` (0-100), `status` (EXCELLENT / GOOD / FAIR / NEEDS WORK)
- `categories[]` — per-category score, weight, passed/failed/warning counts
- `service_scores[]` — per-Dockerfile/service breakdown
- `findings[]` — per-check `id`, `status`, `evidence`, `category`, `weight`
- `external_tools{}` — which tools were available and ran, with raw result paths

**Invocation surface:**

```bash
python3 ~/.claude/scripts/docker-audit.py --stage all
python3 ~/.claude/scripts/docker-audit.py --stage all --quick
python3 ~/.claude/scripts/docker-audit.py --stage all --with-image-scan
python3 ~/.claude/scripts/docker-audit.py --stage all --skip-external
python3 ~/.claude/scripts/docker-audit.py --stage all --compare
```

Consolidation helper (weekly/monthly rollups):

```bash
python3 ~/.claude/scripts/docker-audit-consolidate.py              # human-readable
python3 ~/.claude/scripts/docker-audit-consolidate.py --format json
```

**Scoring** (default weights, no image scan):

| Category | Weight | What It Checks |
|---|---|---|
| Security Hardening | 25% | read_only, no-new-privileges, cap_drop, resource limits, secrets management, init process, volume security, Trivy config, Dockle CIS (D6-D12, C1-C6) |
| Compose Structure | 15% | V2 syntax, base+override, env vars, naming, container name uniqueness, .env.example (C18-C22) |
| Base Image | 15% | DHI preferred (`dhi.io/*`), multi-stage, testing stage, non-root user, COPY --chown, Hadolint lint (D1-D5) |
| Operations | 15% | Health checks, depends_on, restart policy, stop_grace_period, logging (C11-C17) |
| Networking & CI | 10% | Network segmentation, port exposure, RUN_TESTS build-arg, .dockerignore (C23-C25, D14, D18) |
| Build Performance | 10% | Layer cache order, dep-file separation, layer consolidation, multi-stage copy, cache cleanup, dev deps excluded (D13-D20) — *LLM phase* |
| Version Pinning | 10% | All images pinned, no `:latest` tags, staleness vs Docker Hub (D3, C16) |

With `--with-image-scan`, weights redistribute: Vulnerability Scan adds 20%,
Image Efficiency adds 10%, and existing category weights shrink proportionally.

Bands: 90+ Excellent · 70-89 Good · 50-69 Fair · <50 Needs Work.

## How it works

1. **Deterministic scan** — script discovers all Dockerfiles and Compose files,
   runs every pattern matcher (D1-D23, C1-C25 checks), invokes available
   external tools (Hadolint, Trivy config, optionally Trivy image/Dockle/Dive),
   computes weighted per-category and overall scores, writes
   `/tmp/docker-audit-result.json` and a snapshot to `docs/audits/docker/`.
2. **Read results** — LLM reads the JSON and per-tool detail files; no further
   file scanning needed.
3. **DHI compliance analysis** — LLM phase: parses every `FROM` and `image:`
   line, checks against known DHI catalog (`dhi.io/*`), emits a DHI Compliance
   subsection with pass/warn/fail per image.
4. **Build performance analysis** — LLM phase: reads each Dockerfile for layer
   cache order, dep-file separation, multi-stage copy efficiency, dev dep
   exclusion, and package cache cleanup; scores each Dockerfile and averages.
5. **Contextual analysis** — for each failed check: explains why it matters,
   supplies a specific code-snippet fix referencing the project's actual files,
   estimates effort (trivial / small / medium).
6. **External tool insights** — maps Hadolint DL-rules, Trivy misconfig
   references, CVEs with upgrade paths, Dockle CIS-DI rules, and Dive wasteful
   layers to concrete fixes.
7. **Action plan** — P0 (deployment risk: critical CVEs, CIS failures, secret
   leaks) / P1 (before next release: high CVEs, Hadolint errors, missing health
   checks) / P2 (improvements: warnings, efficiency, logging) / P3 (nice-to-have).
8. **Follow-up routing** — < 50 → suggest `/dockerfile-build`; 50-89 → offer
   to implement P0/P1 fixes or run `/docker-hardening`; ≥ 90 → suggest
   `/pipeline-audit`.

## Example workflows

### Scenario: Pre-deployment readiness check

```
/docker-audit            # confirm score acceptable
/pipeline-audit          # cross-check CI/CD
/deploy-to-stage
```

### Scenario: Post-hardening verification

```
# manual: applied read_only and cap_drop to docker-compose.yml
/docker-audit            # confirm security score improved
/git-commit
```

### Scenario: Scorecard output

```
/docker-audit
```

```
Docker Implementation Audit
─────────────────────────────────────────
Project: nuvia-api      Mode: full (hadolint + trivy-config)
Overall: 74/100 (GOOD)

Category Breakdown:
  Security Hardening    68/100  (25%)
  Compose Structure     90/100  (15%)
  Base Image            80/100  (15%)
  Operations            75/100  (15%)
  Networking & CI       70/100  (10%)
  Build Performance     60/100  (10%)
  Version Pinning       85/100  (10%)

Per-Service Scores:
  backend  71/100 (GOOD)   — 14 pass, 3 warn, 3 fail
  worker   65/100 (FAIR)   — 11 pass, 2 warn, 5 fail

DHI Compliance:
  ✓ dhi.io/node:22 (backend Dockerfile)
  ⚠ mysql:8.4 → DHI available: dhi.io/mysql:8.4 (docker-compose.yml)

Top P0:
  • No read_only: true on worker service (Security Hardening)
  • Secrets exposed via environment: in compose (Security Hardening)

Run /docker-audit again after fixes to verify.
```

## Notes & gotchas

- Requires `PROJECT.yaml`. If missing, run `/project-config init` first.
- External tools are auto-detected; the audit works without them but scores
  improve with more data points.
- `--with-image-scan` requires images to be built locally first
  (`docker compose build`). Remote-only images are skipped.
- Version staleness check calls Docker Hub API in full mode; skipped for
  private registries and in `--quick` mode.
- Snapshots accumulate in `docs/audits/docker/` — commit them to track
  score trends over time.
- **If it fails:** rerun with
  `python3 ~/.claude/scripts/docker-audit.py --stage all --skip-external`
  to isolate built-in failures from tool errors. If the script can't find
  `PROJECT.yaml`, you're not at the repo root.
