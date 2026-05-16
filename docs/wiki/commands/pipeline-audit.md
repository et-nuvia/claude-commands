---
command: pipeline-audit
group: audit
backing_script: ~/.claude/scripts/pipeline-audit.sh
mutates: []
runtime: ~30-120s (--quick: ~10s)
destructive: false
requires_project_yaml: required
project_yaml_fields:
  - ci.platform
  - ci.staging_branch
  - ci.production_branch
  - deployment.strategy
requires_project_knowledge: none
project_knowledge_sections: []
---

# /pipeline-audit

Audits a project's CI/CD pipeline against project standards and industry
frameworks (SLSA, OWASP DSOMM, DORA, CIS), producing a weighted 0-100 score
plus a P0–P3 action plan. Auto-detects GitHub Actions vs GitLab CI from
PROJECT.yaml. Makes no changes; safe to run repeatedly.

> **Config:** PROJECT.yaml **required** — reads `ci.platform`, `ci.staging_branch`, `ci.production_branch`; `deployment.strategy` optional (enables Blue-Green scoring)

---

## When to use it

- Before deploying a new project to staging or production
- After pipeline edits, to confirm the score moved the right direction
- Periodic security / compliance review

## Usage

```bash
/pipeline-audit [--quick]
```

**Common invocations:**

```bash
/pipeline-audit                # full audit
/pipeline-audit --quick        # CI-speed mode, same checks
```

## Arguments

| Argument / Flag | Required | Description |
|---|---|---|
| `--quick` | No | Skip non-essential LLM analysis; suitable for CI gates |

## Dependencies

**External commands:**

| Dependency | Why it's needed | Install |
|---|---|---|
| `yq` | Parse YAML pipeline files | `brew install yq` |
| `jq` | Build / consume the result JSON | `brew install jq` |
| `git` | Discover repo + branch state | preinstalled |
| `gh` *(optional)* | Validate reusable workflow refs (GitHub) | `brew install gh` |
| `glab` *(optional)* | Validate include refs (GitLab) | install per platform |

**Project files consumed:**

- `PROJECT.yaml` (PY) — Yes. Required: `ci.platform`, `ci.staging_branch`,
  `ci.production_branch`. Optional: `deployment.strategy` (enables Blue-Green scoring).
- `PROJECT-KNOWLEDGE.md` (PK) — No
- `.github/workflows/*.yml` or `.gitlab-ci.yml` (+ includes) — the artifacts audited
- `~/.claude/docs/reference/pipelines.md` — source-of-truth for project standards
- `/tmp/pipeline-audit-result.json` — written for the LLM phase

## Backing script

**Script**: `~/.claude/scripts/pipeline-audit.sh`

Heavy script / light LLM: the script does **all** scoring. The LLM only
explains and prioritizes on top of the JSON.

**Inputs:** `--stage all`, optional `--quick`. Reads `PROJECT.yaml` for
platform + branch config.

**Outputs (structured JSON, to stdout and `/tmp/pipeline-audit-result.json`):**

- `overall_score` (0-100), `maturity_level` (1-4)
- `categories[]` — per-category score, weight, passed/failed/warning counts
- `findings[]` — per-check `id`, `status`, `evidence`, `category`, `weight`
- `platform` (`github-actions` | `gitlab-ci`), `staging_branch`,
  `production_branch`, `blue_green_active`

**Invocation surface:**

```bash
~/.claude/scripts/pipeline-audit.sh --stage all
~/.claude/scripts/pipeline-audit.sh --stage all --quick
~/.claude/scripts/pipeline-audit.sh --raw --stage all       # debug
```

**Scoring**: Project Standards 60% (Build & Deploy, Safety, Secrets,
Zero-Downtime, Branch Strategy, Version Mgmt, optional Blue-Green) +
Industry Standards 40% (SLSA, DSOMM, DORA, CIS). Weights redistribute when
blue-green is active. Bands: 90+ Excellent · 70-89 Good · 50-69 Fair · <50
Needs Work.

## How it works

1. **Deterministic scan** — script discovers pipeline files, parses YAML,
   runs every pattern matcher, computes weighted scores, writes
   `/tmp/pipeline-audit-result.json`.
2. **Read results** — LLM reads the JSON; no further file scanning needed.
3. **Platform-specific analysis** — separate playbooks for GitHub Actions
   (OIDC, reusable workflows, SSM deploys) vs GitLab CI (SSH deploy,
   include/templates, registry auth).
4. **Contextual analysis** — for each failed check: explain *why* it
   matters, supply a platform-specific YAML fix, link to the relevant
   section of `pipelines.md`.
5. **Industry mapping** — assign SLSA level, DSOMM maturity, DORA readiness,
   CIS hardening status; note the path to the next level.
6. **Action plan** — render P0 (deployment risk) / P1 (before next release)
   / P2 (industry maturity) / P3 (nice-to-have).
7. **Follow-up routing** — < 50 → suggest `/pipeline-create`; 50-89 → offer
   to implement P0/P1 fixes; ≥ 90 → suggest `/docker-audit`.

## Example workflows

### Scenario: Pre-deployment readiness check

```
/pipeline-audit         # confirm score acceptable
/deploy-risk            # cross-check
/deploy-to-stage
```

### Scenario: Post-edit verification

```
# manual: edited .github/workflows/deploy.yml
/pipeline-audit         # confirm fix raised the score
/git-commit
```

### Scenario: Scorecard output

```
/pipeline-audit
```

```
Pipeline Implementation Audit
─────────────────────────────────────────
Project: nuvia-api      Platform: github-actions
Overall: 78/100 (GOOD)  Industry Maturity: Level 3 — Defined

Project Standards (60%):           Industry Standards (40%):
  Build & Deploy      82/100         Supply Chain (SLSA)  65/100
  Safety & Rollback   90/100         Security Scanning    72/100
  Secrets Management  88/100         DORA Readiness       80/100
  Zero-Downtime       70/100         Pipeline Hardening   75/100
  …                                  …

Top P0:
  • No automatic rollback on smoke-test failure (Safety)
  • Production rebuilds image instead of promoting (Build & Deploy)

Run /pipeline-audit again after fixes to verify.
```

## Notes & gotchas

- Requires `PROJECT.yaml`. If missing, run `/project-config init` first.
- Auto-detects platform; no flag needed.
- Weights shift when blue-green is active — don't compare scores across
  projects with different deployment strategies blindly.
- **If it fails:** rerun with `~/.claude/scripts/pipeline-audit.sh --raw
  --stage all` to see the unformatted script output. If the script can't
  find `PROJECT.yaml`, you're not at the repo root.
