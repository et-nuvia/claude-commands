---
command: security-audit
group: audit
backing_script: ~/.claude/scripts/security-scan.sh  # plus sibling scripts per type
mutates: []
runtime: ~2-10min (full); ~30-90s per type
destructive: false
requires_project_yaml: optional
project_yaml_fields:
  - components
  - docker.services
  - secrets.backend
  - ci.platform
requires_project_knowledge: none
project_knowledge_sections: []
---

# /security-audit

> Part of the [Auditing workflow](../08-workflows.md#auditing-scorecards).

Runs a comprehensive security review — vulnerability scanning, secrets
detection, compliance checks, IAM/access auditing, CVE patching guidance, and
CI/CD security hardening — producing an executive summary with a prioritized
remediation plan. Each sub-audit is backed by a dedicated script; the
`full` type runs all of them in sequence. Makes no changes; safe to run
repeatedly.

> **Config:** PROJECT.yaml **optional** — reads `components`, `docker.services`, `secrets.backend`, and `ci.platform` when present to tailor findings

---

## When to use it

- Before a production deployment or compliance review (SOC2, HIPAA, PCI, GDPR)
- When Trivy, gitleaks, or another scanner flags a new critical CVE
- Periodic security posture review on any service that handles user data

## Usage

```bash
/security-audit [type]
```

**Common invocations:**

```bash
/security-audit              # full audit (all types)
/security-audit scan         # vulnerability scanning, secrets detection, SAST
/security-audit compliance   # SOC2, HIPAA, PCI, GDPR, ISO27001 checks
/security-audit access       # IAM permissions + application user/role review
/security-audit secrets      # secrets configuration audit against standards
/security-audit patch        # CVE identification and remediation guidance
/security-audit pipeline     # CI/CD security scanning configuration
```

## Arguments

| Argument / Flag | Required | Description |
|---|---|---|
| `type` | No | One of `scan`, `compliance`, `access`, `secrets`, `patch`, `pipeline`, `full`. Defaults to `full`. |

## Dependencies

**External commands / packages** (must be on `PATH`; auto-detected and gracefully skipped when absent):

| Dependency | Why it's needed | Install |
|---|---|---|
| `trivy` | CVE scanning + misconfiguration detection | `brew install trivy` |
| `gitleaks` | Secrets detection in git history and working tree | `brew install gitleaks` |
| `trufflehog` | High-signal secrets scanning in commits | `brew install trufflehog` |
| `semgrep` | SAST pattern matching (OWASP rules) | `brew install semgrep` |
| `jq` | Build / consume result JSON | `brew install jq` |
| `gh` *(work)* | Query GitHub Actions workflow permissions | `brew install gh` |
| `aws` *(work)* | IAM policy analysis | AWS CLI install |

**Project files consumed:**

- `PROJECT.yaml` (PY) — Optional. Reads `components`, `docker.services`, `secrets.backend`, `ci.platform`.
- `PROJECT-KNOWLEDGE.md` (PK) — No
- Source code, `Dockerfile*`, `docker-compose*.yml` — artifacts scanned
- `.github/workflows/*.yml` or `.gitlab-ci.yml` — pipeline security checks
- `/tmp/security-audit-result.json` — written for the LLM phase (unified summary)
- `/tmp/security-scan-result.json`, `/tmp/security-compliance-result.json`, etc. — per-type detail files

## Backing script

**Scripts** (one per audit type):

| Type | Script |
|---|---|
| `scan` | `~/.claude/scripts/security-scan.sh --full` |
| `compliance` | `~/.claude/scripts/security-compliance.sh --full` |
| `access` | `~/.claude/scripts/security-access-review.sh --full` + `security-user-audit.sh --full` |
| `secrets` | `~/.claude/scripts/secrets-audit.sh --full` |
| `patch` | `~/.claude/scripts/security-patch.sh --full` |
| `pipeline` | `~/.claude/scripts/pipeline-security.sh --full` |

All scripts emit structured JSON to stdout and write to `/tmp/<script-name>-result.json`.
The LLM merges findings into a unified report.

**Outputs (per script):**

- `overall_score` (0-100) or severity summary
- `findings[]` — per-check `id`, `severity` (critical/high/medium/low), `evidence`, `category`
- `tool_results{}` — which tools ran and their raw finding counts
- `next_action` directive for LLM routing

**Invocation surface:**

```bash
~/.claude/scripts/security-scan.sh --full
~/.claude/scripts/security-compliance.sh --full
~/.claude/scripts/security-access-review.sh --full
~/.claude/scripts/security-user-audit.sh --full
~/.claude/scripts/secrets-audit.sh --full
~/.claude/scripts/security-patch.sh --full
~/.claude/scripts/pipeline-security.sh --full
```

**Scoring / severity model** (used in the unified report):

| Severity | Description | SLA |
|---|---|---|
| Critical | Exploitable CVE, secret committed, root IAM, plaintext creds | P0 — fix before deploy |
| High | High-severity CVE, missing encryption, excessive IAM permissions | P1 — fix before next release |
| Medium | Medium CVE, weak config, no MFA enforcement | P2 — fix when convenient |
| Low | Informational, best-practice gap, low-risk misconfiguration | P3 — nice to have |

## How it works

1. **Type selection** — LLM parses the argument (default: `full`) and selects
   the corresponding script(s) to run.
2. **Deterministic scan** — each selected script runs its toolchain (Trivy,
   gitleaks, semgrep, etc.), collects findings, and writes a per-type JSON to
   `/tmp/`.
3. **Read results** — LLM reads the per-type JSON files; no further source
   scanning needed.
4. **Tool insight analysis** — maps raw tool output (CVE IDs, rule IDs,
   secret patterns) to concrete fixes: upgrade paths, Dockerfile changes,
   IAM policy edits, secrets manager migration steps.
5. **Compliance mapping** (`compliance` type) — maps findings to SOC2 controls,
   HIPAA safeguards, PCI DSS requirements, GDPR articles, ISO27001 clauses.
6. **Unified report** (`full` type) — merges all per-type findings, deduplicates
   overlapping issues (e.g., a leaked secret caught by both gitleaks and Trivy),
   and presents a single executive summary with overall posture score.
7. **Action plan** — Critical (deploy-blocking) / High (before next release)
   / Medium (fix when convenient) / Low (nice-to-have), with effort estimates.
8. **Follow-up routing** — critical findings → block deployment, escalate;
   high findings → offer to create tracking tasks via `/task-capture`;
   clean scan → suggest `/pipeline-audit` for pipeline hardening.

## Example workflows

### Scenario: Pre-release security gate

```
/security-audit scan        # vulnerability + secrets check
/security-audit pipeline    # confirm CI security scanning configured
/deploy-risk                # cross-check deployment risk
/deploy-to-stage
```

### Scenario: Compliance review

```
/security-audit compliance
# review findings against SOC2 controls
/task-capture Security compliance gaps: <summary>
```

### Scenario: Scorecard output (scan type)

```
/security-audit scan
```

```
Security Audit — Vulnerability Scan
─────────────────────────────────────────
Project: nuvia-api      Date: 2026-05-16
Tools: trivy ✓  gitleaks ✓  trufflehog ✓  semgrep ✓

Security Posture: NEEDS WORK

Findings:
  Critical   2   (deploy-blocking)
  High       5
  Medium    11
  Low        8

Critical:
  • CVE-2024-21626 in node:20.11 (CVSS 9.8) — runc container escape
    Fix: upgrade to dhi.io/node:22 or node:20.15+
  • AWS_SECRET_ACCESS_KEY found in git history (commit a3f9c12)
    Fix: rotate immediately; run git filter-repo to purge

Top P1:
  • 3 HIGH CVEs in python:3.11-slim — upgrade to dhi.io/python:3.12
  • semgrep: SQL injection pattern in backend/app/routes/search.py:42

Run /security-audit patch for full CVE remediation guidance.
```

## Notes & gotchas

- Running `full` invokes all six scripts sequentially; on a large repo with
  many images this can take 10+ minutes. Use a specific type for faster
  targeted checks.
- `access` type requires cloud credentials (AWS CLI profile or IAM role) for
  IAM analysis; it runs the application user audit regardless.
- Secret findings in git history require `gitleaks` or `trufflehog` — the
  secrets audit script alone only checks working-tree configuration.
- Output format is auto-detected (human-readable for interactive sessions,
  JSON for CI/scripts); override with `--toon` or `--json` on the scripts.
- **If it fails:** run the specific backing script directly with `--full` to
  see raw output. If a tool (e.g., Trivy) times out, rerun with only built-in
  checks by removing that tool from `PATH` temporarily.
