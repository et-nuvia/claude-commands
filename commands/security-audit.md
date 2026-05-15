---
name: security-audit
description: Comprehensive security audit - vulnerabilities, compliance, secrets, access, and CI/CD security
user_invocable: true
---

## Tracking

> Output format is auto-detected (TOON for AI callers, JSON for CI/scripts). Use `--toon` or `--json` to override.

As your **first action**, before any other work, run:
```bash
~/.claude/scripts/track-command.sh --command "security-audit" --event start
```

If the workflow encounters an unrecoverable error at any point, run:
```bash
~/.claude/scripts/track-command.sh --command "security-audit" --event error \
  --model "MODEL_ID" \
  --error-msg "brief description of what failed"
```

## Usage

```
/security-audit [type]
```

**Types** (default: `full`):
- `scan` — Vulnerability scanning, secrets detection, license compliance, SAST
- `compliance` — SOC2, HIPAA, PCI, GDPR, ISO27001 checks
- `access` — IAM permissions and application user/role audit
- `secrets` — Secrets configuration audit against standards
- `patch` — CVE identification and remediation guidance
- `pipeline` — CI/CD security scanning configuration
- `full` — Run all audit types

## Execute

Based on the requested type, run the appropriate backing scripts:

### scan
```bash
~/.claude/scripts/security-scan.sh --full
```

### compliance
```bash
~/.claude/scripts/security-compliance.sh --full
```

### access
Combine IAM and application user audits:
```bash
~/.claude/scripts/security-access-review.sh --full
~/.claude/scripts/security-user-audit.sh --full
```

### secrets
```bash
~/.claude/scripts/secrets-audit.sh --full
```

### patch
```bash
~/.claude/scripts/security-patch.sh --full
```

### pipeline
```bash
~/.claude/scripts/pipeline-security.sh --full
```

### full
Run all of the above in sequence. Collect results and present a unified summary with:
- Critical findings (must fix)
- High findings (should fix soon)
- Medium/Low findings (fix when convenient)
- Recommendations prioritized by risk

## Output

Present findings in a structured report:
1. **Executive Summary** — Overall security posture score
2. **Critical Issues** — Immediate action required
3. **Findings by Category** — Grouped by audit type
4. **Remediation Plan** — Prioritized fixes with effort estimates

## Completion Tracking

When the workflow completes successfully, run:
```bash
~/.claude/scripts/track-command.sh --command "security-audit" --event complete \
  --model "MODEL_ID" \
  --complexity COMPLEXITY \
  --tokens TOKENS_ESTIMATED \
  --cost COST_ESTIMATED
```
