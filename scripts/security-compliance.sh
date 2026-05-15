#!/usr/bin/env bash
# security-compliance.sh - Audit systems for compliance with security standards
#
# Usage:
#   security-compliance.sh --json --full [--framework FRAMEWORK]
#   security-compliance.sh --json --audit [--framework FRAMEWORK]
#   security-compliance.sh --json --report [--framework FRAMEWORK]
#   security-compliance.sh --raw --audit [--framework FRAMEWORK]
#
# Options:
#   --json              Output structured JSON
#   --raw               Output verbose text (for debugging)
#   --full              Run complete compliance audit workflow
#   --audit             Run compliance checks only
#   --report            Generate compliance report only
#   --framework FRAMEWORK  Specify framework (SOC2, HIPAA, PCI_DSS, GDPR, ISO27001, or custom)
#
# Sections:
#   validate: Check prerequisites
#   audit: Run framework-specific compliance checks
#   report: Generate compliance report document
#
# JSON Response Format:
#   {
#     "status": "success|error|blocked",
#     "section": "validate|audit|report",
#     "message": "Human-readable summary",
#     "timestamp": "ISO 8601 datetime",
#     "framework": "SOC2|HIPAA|PCI_DSS|GDPR|ISO27001|custom",
#     "compliance_score": 0-100,
#     "findings": {
#       "critical": [],
#       "high": [],
#       "medium": [],
#       "low": []
#     },
#     "report_path": "/path/to/report.md"
#   }

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/yaml.sh"

SECTION="security-compliance"
map_status_to_action() {
    case "$1" in
        success) echo "display_summary" ;;
        *) _default_map_status_to_action "$1" ;;
    esac
}
source "${SCRIPT_DIR}/lib/output-framework.sh"

# Defaults
OUTPUT_MODE="json"
SECTION=""
FRAMEWORK=""

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --json) OUTPUT_MODE="json"; shift ;;
            --toon) OUTPUT_MODE="json"; OUTPUT_FORMAT="toon"; shift ;;
    --raw) OUTPUT_MODE="raw"; shift ;;
    --full) SECTION="full"; shift ;;
    --validate) SECTION="validate"; shift ;;
    --audit) SECTION="audit"; shift ;;
    --report) SECTION="report"; shift ;;
    --framework)
      FRAMEWORK="$2"
      shift 2
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

# Default to full workflow
if [[ -z "$SECTION" ]]; then
  SECTION="full"
fi

# Timestamp for responses
TIMESTAMP=$(date -Iseconds)

# JSON response via output framework
json_response() {
  local status="$1"
  local section="$2"
  local message="$3"
  shift 3

  local extra_fields=""
  while [[ $# -gt 0 ]]; do
    extra_fields="${extra_fields}, $1"
    shift
  done

  log_json "$(cat <<EOF
{
  "status": "$status",
  "section": "$section",
  "message": "$message",
  "next_action": "$(map_status_to_action "$status")",
  "timestamp": "$TIMESTAMP"${extra_fields}
}
EOF
)"
}

# Section: Validate
validate_prerequisites() {
  if [[ "$OUTPUT_MODE" == "raw" ]]; then
    echo "=== Validation ==="
    echo ""
  fi

  # Check if framework is specified
  if [[ -z "$FRAMEWORK" ]]; then
    if [[ "$OUTPUT_MODE" == "json" ]]; then
      json_response "error" "validate" "No framework specified" \
        '"details": "Use --framework to specify: SOC2, HIPAA, PCI_DSS, GDPR, ISO27001, or custom framework name"'
      return 1
    else
      echo "❌ Error: No framework specified"
      echo ""
      echo "Available frameworks:"
      echo "  - SOC2 (SOC 2 Type II)"
      echo "  - HIPAA (Healthcare)"
      echo "  - PCI_DSS (Payment Card Industry)"
      echo "  - GDPR (Privacy)"
      echo "  - ISO27001 (Information Security)"
      echo "  - Custom framework name"
      echo ""
      echo "Usage: --framework SOC2"
      return 1
    fi
  fi

  if [[ "$OUTPUT_MODE" == "raw" ]]; then
    echo "✓ Framework: $FRAMEWORK"
    echo ""
  fi

  return 0
}

# Section: Audit
run_compliance_audit() {
  if [[ "$OUTPUT_MODE" == "raw" ]]; then
    echo "=== Compliance Audit: $FRAMEWORK ==="
    echo ""
  fi

  local findings_critical=()
  local findings_high=()
  local findings_medium=()
  local findings_low=()
  local checks_passed=0
  local checks_total=0

  # Common checks across all frameworks

  # 1. Access Controls
  if [[ "$OUTPUT_MODE" == "raw" ]]; then
    echo "Checking Access Controls..."
  fi

  ((checks_total++))
  if [[ -f "PROJECT.yaml" ]]; then
    MFA_REQUIRED=$(yaml_get '.security.mfa.required' PROJECT.yaml)
    if [[ "$MFA_REQUIRED" == "true" ]]; then
      ((checks_passed++))
      [[ "$OUTPUT_MODE" == "raw" ]] && echo "  ✓ MFA required in configuration"
    else
      findings_high+=("MFA not required in PROJECT.yaml")
      [[ "$OUTPUT_MODE" == "raw" ]] && echo "  ✗ MFA not required"
    fi
  else
    findings_medium+=("PROJECT.yaml not found - cannot verify MFA settings")
    [[ "$OUTPUT_MODE" == "raw" ]] && echo "  ⚠ PROJECT.yaml not found"
  fi

  # 2. System Monitoring
  if [[ "$OUTPUT_MODE" == "raw" ]]; then
    echo "Checking System Monitoring..."
  fi

  ((checks_total++))
  if [[ -d "infrastructure/monitoring" ]] || grep -q "prometheus\|grafana\|datadog" docker-compose.yml 2>/dev/null; then
    ((checks_passed++))
    [[ "$OUTPUT_MODE" == "raw" ]] && echo "  ✓ Monitoring configured"
  else
    findings_high+=("No monitoring infrastructure detected")
    [[ "$OUTPUT_MODE" == "raw" ]] && echo "  ✗ No monitoring detected"
  fi

  # 3. CI/CD and Change Management
  if [[ "$OUTPUT_MODE" == "raw" ]]; then
    echo "Checking Change Management..."
  fi

  ((checks_total++))
  if [[ -f ".github/workflows/ci-cd.yml" ]] || [[ -f ".gitlab-ci.yml" ]]; then
    ((checks_passed++))
    [[ "$OUTPUT_MODE" == "raw" ]] && echo "  ✓ CI/CD pipeline exists"
  else
    findings_medium+=("No CI/CD pipeline detected")
    [[ "$OUTPUT_MODE" == "raw" ]] && echo "  ✗ No CI/CD detected"
  fi

  # 4. Secrets Management
  if [[ "$OUTPUT_MODE" == "raw" ]]; then
    echo "Checking Secrets Management..."
  fi

  ((checks_total++))
  if grep -r "password\|secret\|api_key" .env* 2>/dev/null | grep -v ".example" | grep -q "="; then
    findings_critical+=("Secrets found in .env files - use secrets manager")
    [[ "$OUTPUT_MODE" == "raw" ]] && echo "  ✗ Secrets in .env files"
  elif [[ -f "PROJECT.yaml" ]] && yaml_get '.secrets' PROJECT.yaml | grep -q "backend"; then
    ((checks_passed++))
    [[ "$OUTPUT_MODE" == "raw" ]] && echo "  ✓ Secrets manager configured"
  else
    findings_medium+=("Secrets management not configured in PROJECT.yaml")
    [[ "$OUTPUT_MODE" == "raw" ]] && echo "  ⚠ Secrets manager not configured"
  fi

  # 5. Encryption in Transit
  if [[ "$OUTPUT_MODE" == "raw" ]]; then
    echo "Checking Encryption..."
  fi

  ((checks_total++))
  if grep -r "TLS_VERSION\|ssl_protocols" . 2>/dev/null | grep -q "TLSv1\.[23]"; then
    ((checks_passed++))
    [[ "$OUTPUT_MODE" == "raw" ]] && echo "  ✓ TLS 1.2+ configured"
  else
    findings_medium+=("TLS configuration not verified")
    [[ "$OUTPUT_MODE" == "raw" ]] && echo "  ⚠ TLS configuration not found"
  fi

  # 6. Docker Security
  if [[ "$OUTPUT_MODE" == "raw" ]]; then
    echo "Checking Docker Security..."
  fi

  ((checks_total++))
  if [[ -f "docker-compose.yml" ]]; then
    # Check for read_only filesystems
    if grep -q "read_only: true" docker-compose.yml; then
      ((checks_passed++))
      [[ "$OUTPUT_MODE" == "raw" ]] && echo "  ✓ Read-only filesystems configured"
    else
      findings_medium+=("Docker containers not using read-only filesystems")
      [[ "$OUTPUT_MODE" == "raw" ]] && echo "  ⚠ No read-only filesystems"
    fi

    # Check for non-root user
    ((checks_total++))
    if grep -q "user: " docker-compose.yml; then
      ((checks_passed++))
      [[ "$OUTPUT_MODE" == "raw" ]] && echo "  ✓ Non-root user configured"
    else
      findings_high+=("Docker containers may run as root")
      [[ "$OUTPUT_MODE" == "raw" ]] && echo "  ✗ Containers may run as root"
    fi
  fi

  # 7. Backup Procedures
  if [[ "$OUTPUT_MODE" == "raw" ]]; then
    echo "Checking Backup Procedures..."
  fi

  ((checks_total++))
  if [[ -f "scripts/backup.sh" ]] || grep -q "backup" Makefile 2>/dev/null; then
    ((checks_passed++))
    [[ "$OUTPUT_MODE" == "raw" ]] && echo "  ✓ Backup scripts found"
  else
    findings_medium+=("No backup procedures documented")
    [[ "$OUTPUT_MODE" == "raw" ]] && echo "  ⚠ No backup scripts found"
  fi

  # 8. Security Scanning
  if [[ "$OUTPUT_MODE" == "raw" ]]; then
    echo "Checking Security Scanning..."
  fi

  ((checks_total++))
  if grep -r "trivy\|snyk\|sonarqube" . 2>/dev/null | grep -q "scan"; then
    ((checks_passed++))
    [[ "$OUTPUT_MODE" == "raw" ]] && echo "  ✓ Security scanning configured"
  else
    findings_high+=("No security scanning in CI/CD pipeline")
    [[ "$OUTPUT_MODE" == "raw" ]] && echo "  ✗ No security scanning"
  fi

  # Calculate compliance score
  local compliance_score=0
  if [[ $checks_total -gt 0 ]]; then
    compliance_score=$((checks_passed * 100 / checks_total))
  fi

  if [[ "$OUTPUT_MODE" == "raw" ]]; then
    echo ""
    echo "=== Audit Summary ==="
    echo "Checks passed: $checks_passed/$checks_total"
    echo "Compliance score: $compliance_score%"
    echo ""
    echo "Critical findings: ${#findings_critical[@]}"
    echo "High findings: ${#findings_high[@]}"
    echo "Medium findings: ${#findings_medium[@]}"
    echo "Low findings: ${#findings_low[@]}"
    return 0
  fi

  # Build JSON findings array
  local critical_json=""
  for finding in "${findings_critical[@]}"; do
    [[ -n "$critical_json" ]] && critical_json="${critical_json}, "
    critical_json="${critical_json}\"$finding\""
  done

  local high_json=""
  for finding in "${findings_high[@]}"; do
    [[ -n "$high_json" ]] && high_json="${high_json}, "
    high_json="${high_json}\"$finding\""
  done

  local medium_json=""
  for finding in "${findings_medium[@]}"; do
    [[ -n "$medium_json" ]] && medium_json="${medium_json}, "
    medium_json="${medium_json}\"$finding\""
  done

  local low_json=""
  for finding in "${findings_low[@]}"; do
    [[ -n "$low_json" ]] && low_json="${low_json}, "
    low_json="${low_json}\"$finding\""
  done

  # Store findings for report generation
  echo "${findings_critical[@]}" > /tmp/compliance-findings-critical.txt 2>/dev/null || true
  echo "${findings_high[@]}" > /tmp/compliance-findings-high.txt 2>/dev/null || true
  echo "${findings_medium[@]}" > /tmp/compliance-findings-medium.txt 2>/dev/null || true
  echo "${findings_low[@]}" > /tmp/compliance-findings-low.txt 2>/dev/null || true
  echo "$compliance_score" > /tmp/compliance-score.txt
  echo "$checks_passed" > /tmp/compliance-checks-passed.txt
  echo "$checks_total" > /tmp/compliance-checks-total.txt

  # Return JSON with audit results
  cat <<EOF
{
  "status": "success",
  "section": "audit",
  "message": "Compliance audit completed",
  "next_action": "display_summary",
  "timestamp": "$TIMESTAMP",
  "framework": "$FRAMEWORK",
  "compliance_score": $compliance_score,
  "checks_passed": $checks_passed,
  "checks_total": $checks_total,
  "findings": {
    "critical": [$critical_json],
    "high": [$high_json],
    "medium": [$medium_json],
    "low": [$low_json]
  }
}
EOF
}

# Section: Report
generate_compliance_report() {
  if [[ "$OUTPUT_MODE" == "raw" ]]; then
    echo "=== Generating Compliance Report ==="
    echo ""
  fi

  # Create report directory
  mkdir -p docs/compliance

  local report_path="docs/compliance/$(date +%Y-%m-%d)-${FRAMEWORK}-audit.md"

  # Load audit results if available
  local compliance_score=0
  local checks_passed=0
  local checks_total=0
  local findings_critical=()
  local findings_high=()
  local findings_medium=()
  local findings_low=()

  if [[ -f /tmp/compliance-score.txt ]]; then
    compliance_score=$(cat /tmp/compliance-score.txt)
    checks_passed=$(cat /tmp/compliance-checks-passed.txt)
    checks_total=$(cat /tmp/compliance-checks-total.txt)

    # Read findings arrays
    if [[ -f /tmp/compliance-findings-critical.txt ]]; then
      mapfile -t findings_critical < /tmp/compliance-findings-critical.txt
    fi
    if [[ -f /tmp/compliance-findings-high.txt ]]; then
      mapfile -t findings_high < /tmp/compliance-findings-high.txt
    fi
    if [[ -f /tmp/compliance-findings-medium.txt ]]; then
      mapfile -t findings_medium < /tmp/compliance-findings-medium.txt
    fi
    if [[ -f /tmp/compliance-findings-low.txt ]]; then
      mapfile -t findings_low < /tmp/compliance-findings-low.txt
    fi
  fi

  # Generate report
  cat > "$report_path" <<EOF
# $FRAMEWORK Compliance Audit

**Date**: $(date -Iseconds)
**Framework**: $FRAMEWORK
**Auditor**: Automated + Manual Review Required

---

## Executive Summary

- **Compliance Score**: ${compliance_score}%
- **Checks**: ${checks_passed}/${checks_total} passed
- **Critical Findings**: ${#findings_critical[@]}
- **High Findings**: ${#findings_high[@]}
- **Medium Findings**: ${#findings_medium[@]}
- **Low Findings**: ${#findings_low[@]}

---

## Detailed Findings

### Critical Issues

EOF

  # Add critical findings
  if [[ ${#findings_critical[@]} -gt 0 ]]; then
    for finding in "${findings_critical[@]}"; do
      echo "- [ ] $finding" >> "$report_path"
    done
  else
    echo "No critical issues found." >> "$report_path"
  fi

  cat >> "$report_path" <<EOF

### High Priority Issues

EOF

  # Add high findings
  if [[ ${#findings_high[@]} -gt 0 ]]; then
    for finding in "${findings_high[@]}"; do
      echo "- [ ] $finding" >> "$report_path"
    done
  else
    echo "No high priority issues found." >> "$report_path"
  fi

  cat >> "$report_path" <<EOF

### Medium Priority Issues

EOF

  # Add medium findings
  if [[ ${#findings_medium[@]} -gt 0 ]]; then
    for finding in "${findings_medium[@]}"; do
      echo "- [ ] $finding" >> "$report_path"
    done
  else
    echo "No medium priority issues found." >> "$report_path"
  fi

  cat >> "$report_path" <<EOF

### Low Priority Issues

EOF

  # Add low findings
  if [[ ${#findings_low[@]} -gt 0 ]]; then
    for finding in "${findings_low[@]}"; do
      echo "- [ ] $finding" >> "$report_path"
    done
  else
    echo "No low priority issues found." >> "$report_path"
  fi

  cat >> "$report_path" <<EOF

---

## Compliance Checklist

### Access Controls
- [ ] Multi-factor authentication enabled
- [ ] Strong password policy enforced
- [ ] Regular access reviews conducted
- [ ] Least privilege access implemented
- [ ] Audit logging enabled and monitored

### Data Protection
- [ ] Encryption at rest configured
- [ ] Encryption in transit (TLS 1.2+)
- [ ] Data backup procedures documented
- [ ] Data retention policy defined
- [ ] Secure data disposal process

### System Monitoring
- [ ] Centralized logging implemented
- [ ] Security event monitoring active
- [ ] Alerting configured for critical events
- [ ] Incident response plan documented
- [ ] Regular log reviews conducted

### Change Management
- [ ] Code review process enforced
- [ ] Automated testing in CI/CD
- [ ] Deployment approvals required
- [ ] Rollback procedures documented
- [ ] Change documentation maintained

### Vulnerability Management
- [ ] Regular security scans scheduled
- [ ] Patch management process defined
- [ ] Vulnerability tracking system
- [ ] Remediation SLAs established
- [ ] Penetration testing conducted

### Docker Security (if applicable)
- [ ] Containers run as non-root user
- [ ] Read-only filesystems configured
- [ ] Capabilities dropped
- [ ] Resource limits set
- [ ] Security scanning in pipeline

---

## Recommendations

1. **Critical**: Address all critical findings immediately
2. **High**: Remediate high priority issues within 30 days
3. **Medium**: Plan remediation for medium priority issues
4. **Documentation**: Document all security procedures and policies
5. **Training**: Conduct team training on compliance requirements
6. **Regular Audits**: Schedule quarterly compliance audits
7. **Continuous Monitoring**: Implement automated compliance monitoring

---

## Next Steps

1. Review all findings with security team
2. Create remediation plan with timeline
3. Implement recommended controls
4. Update security documentation
5. Schedule follow-up audit

---

**Report Generated**: $(date -Iseconds)
**Framework**: $FRAMEWORK
**Automation**: security-compliance.sh
EOF

  if [[ "$OUTPUT_MODE" == "raw" ]]; then
    echo "✓ Report generated: $report_path"
    echo ""
    echo "Summary:"
    echo "  Compliance score: ${compliance_score}%"
    echo "  Critical findings: ${#findings_critical[@]}"
    echo "  High findings: ${#findings_high[@]}"
    echo "  Medium findings: ${#findings_medium[@]}"
    echo "  Low findings: ${#findings_low[@]}"
    return 0
  fi

  # Cleanup temp files
  rm -f /tmp/compliance-*.txt 2>/dev/null || true

  # Return JSON with report path
  json_response "success" "report" "Compliance report generated" \
    "\"framework\": \"$FRAMEWORK\"" \
    "\"compliance_score\": $compliance_score" \
    "\"report_path\": \"$report_path\"" \
    "\"findings_count\": {\"critical\": ${#findings_critical[@]}, \"high\": ${#findings_high[@]}, \"medium\": ${#findings_medium[@]}, \"low\": ${#findings_low[@]}}"
}

# Main execution flow
main() {
  case "$SECTION" in
    full)
      validate_prerequisites || exit 1
      run_compliance_audit || exit 1
      generate_compliance_report || exit 1
      ;;
    validate)
      validate_prerequisites || exit 1
      json_response "success" "validate" "Prerequisites validated" "\"framework\": \"$FRAMEWORK\""
      ;;
    audit)
      validate_prerequisites || exit 1
      run_compliance_audit || exit 1
      ;;
    report)
      generate_compliance_report || exit 1
      ;;
    *)
      echo "Unknown section: $SECTION" >&2
      exit 1
      ;;
  esac
}

main
