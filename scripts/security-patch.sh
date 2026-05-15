#!/usr/bin/env bash
set -euo pipefail

# security-patch.sh - Identify and remediate security vulnerabilities (CVEs) across services
#
# STANDARD SCRIPT PATTERN: Section flags with --json/--raw output modes
#
# Usage:
#   ~/.claude/scripts/security-patch.sh [--json|--raw] [--full|--section] [--scan-type TYPE]
#
# Output Modes:
#   --json: Structured JSON output for LLM (default)
#   --raw:  Verbose debugging output when LLM needs more details
#
# Section Flags (run specific section only):
#   --scan:           Scan for vulnerabilities only
#   --aggregate:      Aggregate and prioritize vulnerabilities only (requires --scan first)
#   --generate:       Generate remediation scripts only (requires --scan first)
#   --full:           Run all sections end-to-end (default)
#
# Scan Type Flags (what to scan):
#   --containers:     Scan containers with Trivy
#   --dependencies:   Scan dependencies (npm, pip, go)
#   --code:           Scan code with Semgrep
#   --all:            Scan everything (default)
#
# Workflow:
#   1. LLM calls: security-patch.sh --json --full --all
#   2. Script scans, aggregates, and generates report
#   3. Returns JSON with vulnerability counts and remediation details
#   4. If needed: security-patch.sh --raw --scan --containers (for debugging)
#
# Features:
#   - Scans containers (Trivy), dependencies (npm/pip/go), and code (Semgrep)
#   - Aggregates findings by severity
#   - Generates remediation plan and automation scripts
#   - Auto-flow when successful (no user prompts)
#   - --raw mode for verbose output

# Global variables
OUTPUT_MODE="json"  # json or raw
SECTION="full"      # full, scan, aggregate, generate

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/output-framework.sh"

# Scan types
SCAN_CONTAINERS=false
SCAN_DEPENDENCIES=false
SCAN_CODE=false

# Vulnerability counts
CRITICAL_COUNT=0
HIGH_COUNT=0
MEDIUM_COUNT=0
NPM_CRITICAL=0
NPM_HIGH=0
PIP_VULNS=0
SEMGREP_ERRORS=0
SEMGREP_WARNINGS=0

# File paths
RESULTS_DIR="/tmp/security-scan-$(date +%s)"
REPORT_FILE=""
SCRIPTS_DIR=""

#------------------------------------------------------------------------------
# Section Functions
#------------------------------------------------------------------------------

# Section 1: Scan for vulnerabilities
section_scan() {
    log "${BLUE}Scanning for Vulnerabilities${NC}"

    mkdir -p "$RESULTS_DIR/trivy-results"
    mkdir -p "$RESULTS_DIR/dependency-scans"
    mkdir -p "$RESULTS_DIR/semgrep-results"

    # Scan containers
    if [[ "$SCAN_CONTAINERS" == "true" ]]; then
        log "${CYAN}Scanning containers with Trivy...${NC}"
        scan_containers
    fi

    # Scan dependencies
    if [[ "$SCAN_DEPENDENCIES" == "true" ]]; then
        log "${CYAN}Scanning dependencies...${NC}"
        scan_dependencies
    fi

    # Scan code
    if [[ "$SCAN_CODE" == "true" ]]; then
        log "${CYAN}Scanning code with Semgrep...${NC}"
        scan_code
    fi

    if [[ "$SECTION" == "scan" ]]; then
        # Return scan results
        local json=$(cat <<EOF
{
  "status": "success",
  "section": "scan",
  "message": "Vulnerability scan complete",
  "scan_types": {
    "containers": $SCAN_CONTAINERS,
    "dependencies": $SCAN_DEPENDENCIES,
    "code": $SCAN_CODE
  },
  "vulnerabilities": {
    "container_critical": $CRITICAL_COUNT,
    "container_high": $HIGH_COUNT,
    "npm_critical": $NPM_CRITICAL,
    "npm_high": $NPM_HIGH,
    "python_vulns": $PIP_VULNS,
    "code_errors": $SEMGREP_ERRORS,
    "code_warnings": $SEMGREP_WARNINGS
  },
  "total_critical": $((CRITICAL_COUNT + NPM_CRITICAL)),
  "total_high": $((HIGH_COUNT + NPM_HIGH)),
  "results_dir": "$RESULTS_DIR",
  "next_action": "display_summary",
  "timestamp": "$(date -Iseconds)"
}
EOF
)
        log_json "$json"
        exit 0
    fi

    log "${GREEN}✓${NC} Scan complete"
}

scan_containers() {
    # Find Dockerfiles
    local dockerfiles
    dockerfiles=$(find . -name "Dockerfile" -o -name "Dockerfile.*" 2>/dev/null || true)

    if [[ -n "$dockerfiles" ]]; then
        log "Found Dockerfiles:"
        echo "$dockerfiles" | nl >&2

        for dockerfile in $dockerfiles; do
            log "Scanning: $dockerfile"

            # JSON output for parsing
            trivy config --severity HIGH,CRITICAL "$dockerfile" \
              --format json \
              --output "$RESULTS_DIR/trivy-results/$(basename $dockerfile).json" 2>/dev/null || true

            # Human-readable output
            if [[ "$OUTPUT_MODE" == "raw" ]]; then
                trivy config --severity HIGH,CRITICAL "$dockerfile" | tee "$RESULTS_DIR/trivy-results/$(basename $dockerfile).txt"
            else
                trivy config --severity HIGH,CRITICAL "$dockerfile" > "$RESULTS_DIR/trivy-results/$(basename $dockerfile).txt" 2>/dev/null || true
            fi
        done
    fi

    # Scan running images
    local images
    images=$(docker ps --format '{{.Image}}' 2>/dev/null | sort -u || true)

    if [[ -n "$images" ]]; then
        log "Found running images:"
        echo "$images" | nl >&2

        for image in $images; do
            log "Scanning image: $image"

            # JSON output
            trivy image --severity HIGH,CRITICAL "$image" \
              --format json \
              --output "$RESULTS_DIR/trivy-results/$(echo $image | tr '/:' '_').json" 2>/dev/null || true

            # Human-readable output
            if [[ "$OUTPUT_MODE" == "raw" ]]; then
                trivy image --severity HIGH,CRITICAL "$image" | tee "$RESULTS_DIR/trivy-results/$(echo $image | tr '/:' '_').txt"
            else
                trivy image --severity HIGH,CRITICAL "$image" > "$RESULTS_DIR/trivy-results/$(echo $image | tr '/:' '_').txt" 2>/dev/null || true
            fi
        done
    fi

    # Count vulnerabilities
    CRITICAL_COUNT=$(find "$RESULTS_DIR/trivy-results" -name "*.json" -exec jq '[.Results[]?.Vulnerabilities[]? | select(.Severity == "CRITICAL")] | length' {} + 2>/dev/null | awk '{sum+=$1} END {print sum}' || echo "0")
    HIGH_COUNT=$(find "$RESULTS_DIR/trivy-results" -name "*.json" -exec jq '[.Results[]?.Vulnerabilities[]? | select(.Severity == "HIGH")] | length' {} + 2>/dev/null | awk '{sum+=$1} END {print sum}' || echo "0")

    log "${GREEN}Container scan complete:${NC} CRITICAL: ${CRITICAL_COUNT:-0}, HIGH: ${HIGH_COUNT:-0}"
}

scan_dependencies() {
    # Node.js / npm
    if [[ -f "package.json" ]]; then
        log "Scanning npm dependencies..."
        npm audit --json > "$RESULTS_DIR/dependency-scans/npm-audit.json" 2>&1 || true

        if [[ "$OUTPUT_MODE" == "raw" ]]; then
            npm audit | tee "$RESULTS_DIR/dependency-scans/npm-audit.txt"
        else
            npm audit > "$RESULTS_DIR/dependency-scans/npm-audit.txt" 2>&1 || true
        fi

        NPM_CRITICAL=$(jq '.metadata.vulnerabilities.critical' "$RESULTS_DIR/dependency-scans/npm-audit.json" 2>/dev/null || echo "0")
        NPM_HIGH=$(jq '.metadata.vulnerabilities.high' "$RESULTS_DIR/dependency-scans/npm-audit.json" 2>/dev/null || echo "0")

        log "${GREEN}npm scan:${NC} CRITICAL: $NPM_CRITICAL, HIGH: $NPM_HIGH"
    fi

    # Python / pip
    if [[ -f "requirements.txt" ]] || [[ -f "pyproject.toml" ]]; then
        log "Scanning Python dependencies..."

        # Check if pip-audit is available
        if ! command -v pip-audit &> /dev/null; then
            log "${YELLOW}pip-audit not installed, skipping Python scan${NC}"
        else
            pip-audit --format json > "$RESULTS_DIR/dependency-scans/pip-audit.json" 2>&1 || true

            if [[ "$OUTPUT_MODE" == "raw" ]]; then
                pip-audit | tee "$RESULTS_DIR/dependency-scans/pip-audit.txt"
            else
                pip-audit > "$RESULTS_DIR/dependency-scans/pip-audit.txt" 2>&1 || true
            fi

            PIP_VULNS=$(jq 'length' "$RESULTS_DIR/dependency-scans/pip-audit.json" 2>/dev/null || echo "0")
            log "${GREEN}pip scan:${NC} Vulnerabilities: $PIP_VULNS"
        fi
    fi

    # Go modules
    if [[ -f "go.mod" ]]; then
        log "Scanning Go dependencies..."

        if command -v govulncheck &> /dev/null; then
            govulncheck ./... > "$RESULTS_DIR/dependency-scans/go-vulns.txt" 2>&1 || true

            if [[ "$OUTPUT_MODE" == "raw" ]]; then
                cat "$RESULTS_DIR/dependency-scans/go-vulns.txt"
            fi
        else
            log "${YELLOW}govulncheck not installed, skipping Go scan${NC}"
        fi
    fi
}

scan_code() {
    # Check if semgrep is available
    if ! command -v semgrep &> /dev/null; then
        log "${YELLOW}semgrep not installed, skipping code scan${NC}"
        return
    fi

    log "Running Semgrep security scan..."

    # JSON output
    semgrep --config=auto \
      --severity ERROR \
      --severity WARNING \
      --json \
      --output "$RESULTS_DIR/semgrep-results/semgrep.json" \
      . 2>/dev/null || true

    # Human-readable output
    if [[ "$OUTPUT_MODE" == "raw" ]]; then
        semgrep --config=auto --severity ERROR --severity WARNING . | tee "$RESULTS_DIR/semgrep-results/semgrep.txt"
    else
        semgrep --config=auto --severity ERROR --severity WARNING . > "$RESULTS_DIR/semgrep-results/semgrep.txt" 2>/dev/null || true
    fi

    SEMGREP_ERRORS=$(jq '[.results[]? | select(.extra.severity == "ERROR")] | length' "$RESULTS_DIR/semgrep-results/semgrep.json" 2>/dev/null || echo "0")
    SEMGREP_WARNINGS=$(jq '[.results[]? | select(.extra.severity == "WARNING")] | length' "$RESULTS_DIR/semgrep-results/semgrep.json" 2>/dev/null || echo "0")

    log "${GREEN}Code scan complete:${NC} ERRORS: $SEMGREP_ERRORS, WARNINGS: $SEMGREP_WARNINGS"
}

# Section 2: Aggregate and prioritize vulnerabilities
section_aggregate() {
    log "${BLUE}Aggregating Vulnerabilities${NC}"

    # Ensure scan results exist
    if [[ ! -d "$RESULTS_DIR" ]]; then
        exit_with_json "error" "No scan results found" "Run --scan first"
    fi

    REPORT_FILE="docs/security/$(date +%Y-%m-%d)-vulnerability-report.md"
    mkdir -p docs/security

    # Generate comprehensive report
    generate_report

    if [[ "$SECTION" == "aggregate" ]]; then
        local json=$(cat <<EOF
{
  "status": "success",
  "section": "aggregate",
  "message": "Vulnerability aggregation complete",
  "report_file": "$REPORT_FILE",
  "total_critical": $((CRITICAL_COUNT + NPM_CRITICAL)),
  "total_high": $((HIGH_COUNT + NPM_HIGH)),
  "total_medium": $MEDIUM_COUNT,
  "next_action": "display_summary",
  "timestamp": "$(date -Iseconds)"
}
EOF
)
        log_json "$json"
        exit 0
    fi

    log "${GREEN}✓${NC} Aggregation complete"
}

generate_report() {
    cat > "$REPORT_FILE" << EOF
# Vulnerability Report

**Date**: $(date -Iseconds)
**Scan Types**: $(if [[ "$SCAN_CONTAINERS" == "true" ]]; then echo "Containers"; fi) $(if [[ "$SCAN_DEPENDENCIES" == "true" ]]; then echo "Dependencies"; fi) $(if [[ "$SCAN_CODE" == "true" ]]; then echo "Code"; fi)

---

## Executive Summary

### Critical Vulnerabilities
- Container images: ${CRITICAL_COUNT}
- npm dependencies: ${NPM_CRITICAL}
- Python dependencies: $(jq '[.[]? | select(.aliases[]? | contains("CVE"))] | length' "$RESULTS_DIR/dependency-scans/pip-audit.json" 2>/dev/null || echo "0")

### High Severity Vulnerabilities
- Container images: ${HIGH_COUNT}
- npm dependencies: ${NPM_HIGH}
- Code issues: ${SEMGREP_ERRORS}

**Total Critical/High**: $((CRITICAL_COUNT + NPM_CRITICAL + HIGH_COUNT + NPM_HIGH + SEMGREP_ERRORS))

---

## Container Vulnerabilities

$(if [[ "$SCAN_CONTAINERS" == "true" ]]; then
  for result in "$RESULTS_DIR/trivy-results"/*.txt 2>/dev/null; do
    if [[ -f "$result" ]]; then
      echo "### $(basename $result .txt)"
      echo ""
      echo "\`\`\`"
      head -100 "$result"
      echo "\`\`\`"
      echo ""
    fi
  done
else
  echo "Not scanned"
fi)

---

## Dependency Vulnerabilities

### npm Dependencies

$(if [[ -f "$RESULTS_DIR/dependency-scans/npm-audit.txt" ]]; then
  echo "\`\`\`"
  head -50 "$RESULTS_DIR/dependency-scans/npm-audit.txt"
  echo "\`\`\`"
else
  echo "No npm dependencies"
fi)

### Python Dependencies

$(if [[ -f "$RESULTS_DIR/dependency-scans/pip-audit.txt" ]]; then
  echo "\`\`\`"
  head -50 "$RESULTS_DIR/dependency-scans/pip-audit.txt"
  echo "\`\`\`"
else
  echo "No Python dependencies"
fi)

---

## Code Vulnerabilities

$(if [[ "$SCAN_CODE" == "true" ]]; then
  echo "\`\`\`"
  head -100 "$RESULTS_DIR/semgrep-results/semgrep.txt" 2>/dev/null || echo "No code issues found"
  echo "\`\`\`"
else
  echo "Not scanned"
fi)

---

## Remediation Plan

### Priority 1: Critical Vulnerabilities (Fix Immediately)

$(if [[ $((CRITICAL_COUNT + NPM_CRITICAL)) -gt 0 ]]; then
  cat << 'CRITICAL'
#### Container Base Images

- Update base images to latest patched versions
- Rebuild and redeploy affected containers

\`\`\`bash
# Update Dockerfile
FROM python:3.14-slim  # Use latest patch version

# Rebuild
docker build --no-cache -t myapp:latest .
\`\`\`

#### npm Dependencies

\`\`\`bash
# Attempt automatic fix
npm audit fix --force

# Or update specific packages
npm update <package-name>

# Verify fix
npm audit
\`\`\`

#### Python Dependencies

\`\`\`bash
# Update vulnerable packages
pip install --upgrade <package-name>

# Or update all packages
pip-review --auto

# Update requirements.txt
pip freeze > requirements.txt
\`\`\`
CRITICAL
fi)

### Priority 2: High Severity (Fix This Week)

- Review all HIGH severity findings
- Test updates in staging
- Plan deployment window
- Monitor for regressions

### Priority 3: Medium Severity (Fix This Month)

- Schedule remediation during regular maintenance
- Bundle multiple updates together
- Document workarounds if patches unavailable

---

## Testing Plan

### Before Patching

1. **Backup current state**
   - Create git branch for patches
   - Tag current container images
   - Snapshot databases if schema changes

2. **Document current behavior**
   - Run full test suite
   - Capture baseline performance metrics
   - Document known issues

### During Patching

3. **Apply patches incrementally**
   - One service at a time
   - Test after each patch
   - Monitor for breaking changes

4. **Verify fixes**
   - Re-run vulnerability scans
   - Confirm CVEs resolved
   - Check for new vulnerabilities

### After Patching

5. **Comprehensive testing**
   - Unit tests pass
   - Integration tests pass
   - E2E tests pass
   - Performance benchmarks

6. **Deploy to staging**
   - Full regression testing
   - User acceptance testing
   - Load testing

---

## Deployment Strategy

### Staging Deployment

1. Deploy patched versions to staging
2. Run smoke tests
3. Monitor for 24 hours
4. Address any issues

### Production Deployment

1. Schedule maintenance window (if needed)
2. Deploy during low-traffic period
3. Gradual rollout (canary/blue-green)
4. Monitor error rates
5. Rollback plan ready

---

## Rollback Plan

If issues occur after patching:

1. **Immediate rollback**
   \`\`\`bash
   # Containers
   docker service update --rollback <service>

   # Dependencies
   git revert <commit>
   npm install  # or pip install -r requirements.txt
   \`\`\`

2. **Investigate issue**
   - Check error logs
   - Compare with pre-patch state
   - Identify conflicting changes

3. **Plan alternative fix**
   - Research workarounds
   - Consider vendoring patches
   - Contact maintainers

---

## Prevention

### Automated Scanning

Add to CI/CD pipeline:

\`\`\`yaml
# .github/workflows/security.yml or .gitlab-ci.yml
security-scan:
  runs-on: ubuntu-latest
  steps:
    - uses: actions/checkout@v4

    - name: Run Trivy
      uses: aquasecurity/trivy-action@master
      with:
        severity: 'CRITICAL,HIGH'

    - name: npm audit
      run: npm audit --audit-level=high

    - name: Semgrep
      uses: returntocorp/semgrep-action@v1
\`\`\`

### Dependency Management

- Use Dependabot/Renovate for automated updates
- Pin dependency versions
- Regular dependency audits
- Monitor security advisories

### Container Security

- Use minimal base images (alpine, distroless)
- Multi-stage builds (don't include build tools in final image)
- Regular base image updates
- Sign and verify images

---

## Compliance Tracking

- [ ] All CRITICAL vulnerabilities patched
- [ ] All HIGH vulnerabilities patched or exception documented
- [ ] Patches tested in staging
- [ ] Production deployment scheduled
- [ ] Post-deployment verification complete
- [ ] Security team notified
- [ ] Audit log updated

---

## Next Steps

1. Review this report with security team
2. Prioritize critical vulnerabilities
3. Create remediation tickets
4. Test patches in staging
5. Schedule production deployment
6. Re-scan after patching

**Next scan**: $(date -d "+7 days" +%Y-%m-%d 2>/dev/null || date -v+7d +%Y-%m-%d 2>/dev/null || echo "In 7 days")

EOF

    log "Generated report: $REPORT_FILE"
}

# Section 3: Generate remediation scripts
section_generate() {
    log "${BLUE}Generating Remediation Scripts${NC}"

    # Ensure scan results exist
    if [[ ! -d "$RESULTS_DIR" ]]; then
        exit_with_json "error" "No scan results found" "Run --scan first"
    fi

    SCRIPTS_DIR="scripts/vulnerability-remediation"
    mkdir -p "$SCRIPTS_DIR"

    local scripts_created=0

    # npm fix script
    if [[ ${NPM_CRITICAL:-0} -gt 0 ]] || [[ ${NPM_HIGH:-0} -gt 0 ]]; then
        generate_npm_fix_script
        ((scripts_created++))
    fi

    # Python fix script
    if [[ -f "$RESULTS_DIR/dependency-scans/pip-audit.json" ]]; then
        generate_python_fix_script
        ((scripts_created++))
    fi

    if [[ "$SECTION" == "generate" ]]; then
        local json=$(cat <<EOF
{
  "status": "success",
  "section": "generate",
  "message": "Remediation scripts generated",
  "scripts_dir": "$SCRIPTS_DIR",
  "scripts_created": $scripts_created,
  "next_action": "display_summary",
  "timestamp": "$(date -Iseconds)"
}
EOF
)
        log_json "$json"
        exit 0
    fi

    log "${GREEN}✓${NC} Script generation complete"
}

generate_npm_fix_script() {
    cat > "$SCRIPTS_DIR/fix-npm-vulnerabilities.sh" << 'EOF'
#!/bin/bash
set -euo pipefail

echo "Fixing npm vulnerabilities..."

# Backup package-lock.json
cp package-lock.json package-lock.json.backup

# Try automatic fix
npm audit fix

# If critical vulnerabilities remain, try force fix
if npm audit --audit-level=critical | grep -q "critical"; then
  echo "Critical vulnerabilities remain. Attempting force fix..."
  npm audit fix --force

  echo ""
  echo "⚠️  Force fix applied - test thoroughly!"
fi

# Show remaining vulnerabilities
npm audit

echo ""
echo "✓ Remediation complete"
echo "Backup: package-lock.json.backup"
EOF

    chmod +x "$SCRIPTS_DIR/fix-npm-vulnerabilities.sh"
    log "Created: $SCRIPTS_DIR/fix-npm-vulnerabilities.sh"
}

generate_python_fix_script() {
    cat > "$SCRIPTS_DIR/fix-python-vulnerabilities.sh" << 'EOF'
#!/bin/bash
set -euo pipefail

echo "Fixing Python vulnerabilities..."

# Backup requirements.txt
cp requirements.txt requirements.txt.backup

# Get list of vulnerable packages
pip-audit --format json > /tmp/pip-vulns.json

# Extract package names and upgrade
jq -r '.[].name' /tmp/pip-vulns.json | while read -r pkg; do
  echo "Upgrading $pkg..."
  pip install --upgrade "$pkg"
done

# Update requirements.txt
pip freeze > requirements.txt

# Verify
pip-audit

echo ""
echo "✓ Remediation complete"
echo "Backup: requirements.txt.backup"
EOF

    chmod +x "$SCRIPTS_DIR/fix-python-vulnerabilities.sh"
    log "Created: $SCRIPTS_DIR/fix-python-vulnerabilities.sh"
}

#------------------------------------------------------------------------------
# Main Workflow
#------------------------------------------------------------------------------

main() {
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json) OUTPUT_MODE="json" ;;
            --raw) OUTPUT_MODE="raw" ;;
            --full) SECTION="full" ;;
            --scan) SECTION="scan" ;;
            --aggregate) SECTION="aggregate" ;;
            --generate) SECTION="generate" ;;
            --containers) SCAN_CONTAINERS=true ;;
            --dependencies) SCAN_DEPENDENCIES=true ;;
            --code) SCAN_CODE=true ;;
            --all)
                SCAN_CONTAINERS=true
                SCAN_DEPENDENCIES=true
                SCAN_CODE=true
                ;;
            *)
                log "${RED}Unknown argument: $1${NC}"
                exit_with_json "error" "Unknown argument: $1" "Use --json|--raw and --full|--scan|--aggregate|--generate"
                ;;
        esac
        shift
    done

    # Default to --all if no scan type specified
    if [[ "$SCAN_CONTAINERS" == "false" ]] && [[ "$SCAN_DEPENDENCIES" == "false" ]] && [[ "$SCAN_CODE" == "false" ]]; then
        SCAN_CONTAINERS=true
        SCAN_DEPENDENCIES=true
        SCAN_CODE=true
    fi

    log "${CYAN}═══════════════════════════════════════${NC}"
    log "${CYAN}Security Vulnerability Scanner${NC}"
    log "${CYAN}═══════════════════════════════════════${NC}"

    # Execute sections based on flag
    case "$SECTION" in
        scan)
            section_scan
            ;;
        aggregate)
            section_aggregate
            ;;
        generate)
            section_generate
            ;;
        full)
            section_scan
            section_aggregate
            section_generate

            # Return final success JSON
            local json=$(cat <<EOF
{
  "status": "success",
  "message": "Security scan and remediation planning complete",
  "section": "full",
  "vulnerabilities": {
    "critical": $((CRITICAL_COUNT + NPM_CRITICAL)),
    "high": $((HIGH_COUNT + NPM_HIGH)),
    "medium": $MEDIUM_COUNT,
    "code_errors": $SEMGREP_ERRORS,
    "code_warnings": $SEMGREP_WARNINGS
  },
  "total_critical_high": $((CRITICAL_COUNT + NPM_CRITICAL + HIGH_COUNT + NPM_HIGH)),
  "report_file": "$REPORT_FILE",
  "scripts_dir": "$SCRIPTS_DIR",
  "results_dir": "$RESULTS_DIR",
  "next_steps": [
    "Review vulnerability report: $REPORT_FILE",
    "Patch critical vulnerabilities immediately",
    "Test patches in staging",
    "Deploy to production",
    "Re-scan to verify fixes"
  ],
  "next_action": "display_summary",
  "timestamp": "$(date -Iseconds)"
}
EOF
)
            log_json "$json"
            ;;
    esac
}

# Run main
main "$@"
