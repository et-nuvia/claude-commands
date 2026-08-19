#!/usr/bin/env bash
set -euo pipefail

# Security Scan Script
# Runs all security checks and reports findings
# Copy to project: cp ~/.claude/scripts/security-scan.sh ./scripts/
#
# Usage:
#   security-scan.sh [--json|--raw]
#
# Output Modes:
#   --json: Structured output for LLM, default (TOON when the caller is an AI agent, JSON otherwise)
#   --raw:  Verbose text output for debugging

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Custom next_action mapping (must be defined before sourcing output-framework)
map_status_to_action() {
    case "$1" in
        success) echo "display_summary" ;;
        warning) echo "review_warnings" ;;
        *)       echo "fix_error" ;;
    esac
}

# Source shared library
source "${SCRIPT_DIR}/lib/output-framework.sh"

OUTPUT_MODE="raw"
SECTION="full"
[[ "${1:-}" == "--json" ]] && OUTPUT_MODE="json"

FAILURES=0
WARNINGS=0
declare -a FAILED_CHECKS=()
declare -a WARNED_CHECKS=()

log_header() { [[ "$OUTPUT_MODE" == "raw" ]] && echo -e "\n${BLUE}════════════════════════════════════════${NC}\n  $1\n${BLUE}════════════════════════════════════════${NC}\n"; }
log_success() { [[ "$OUTPUT_MODE" == "raw" ]] && echo -e "${GREEN}✓${NC} $1"; }
log_warning() { [[ "$OUTPUT_MODE" == "raw" ]] && echo -e "${YELLOW}⚠${NC} $1"; ((WARNINGS++)); WARNED_CHECKS+=("$1"); }
log_error()   { [[ "$OUTPUT_MODE" == "raw" ]] && echo -e "${RED}✗${NC} $1"; ((FAILURES++)); FAILED_CHECKS+=("$1"); }

_security_exit_with_json() {
  local status="$1"
  local message="$2"

  # Build JSON arrays
  local failed_json="[]"
  if [[ ${#FAILED_CHECKS[@]} -gt 0 ]]; then
    failed_json="[$(printf '"%s",' "${FAILED_CHECKS[@]}" | sed 's/,$//')]"
  fi
  local warned_json="[]"
  if [[ ${#WARNED_CHECKS[@]} -gt 0 ]]; then
    warned_json="[$(printf '"%s",' "${WARNED_CHECKS[@]}" | sed 's/,$//')]"
  fi

  exit_with_json "$status" "$message" "" \
    "\"failures\": $FAILURES," \
    "\"warnings\": $WARNINGS," \
    "\"failed_checks\": $failed_json," \
    "\"warned_checks\": $warned_json," \
    "\"project_root\": \"$PROJECT_ROOT\""
}

# ─────────────────────────────────────────
# Dependency Vulnerability Scan
# ─────────────────────────────────────────
log_header "Dependency Vulnerability Scan"

if command -v trivy &> /dev/null; then
  if trivy fs --scanners vuln --severity CRITICAL,HIGH --exit-code 1 "${PROJECT_ROOT}" 2>/dev/null; then
    log_success "No CRITICAL/HIGH vulnerabilities in dependencies"
  else
    log_error "CRITICAL/HIGH vulnerabilities found in dependencies"
  fi
else
  log_warning "Trivy not installed, skipping dependency scan"
fi

# ─────────────────────────────────────────
# Secrets Detection
# ─────────────────────────────────────────
log_header "Secrets Detection (Gitleaks — full repo history)"

# Scan the ENTIRE git history, not just the working tree. The audit's job is to
# surface any secret ever committed (even if later removed from HEAD). Per-PR
# review (/review-pr) deliberately scopes gitleaks to the PR's commit range; the
# whole-history sweep lives here.
if command -v gitleaks &> /dev/null; then
  if gitleaks detect --source "${PROJECT_ROOT}" 2>/dev/null; then
    log_success "No secrets detected in repo history"
  else
    log_error "Potential secrets found in repo history"
  fi
elif command -v docker &> /dev/null; then
  if docker run --rm -v "${PROJECT_ROOT}":/repo zricethezav/gitleaks:latest detect \
      --source /repo 2>/dev/null; then
    log_success "No secrets detected in repo history"
  else
    log_error "Potential secrets found in repo history"
  fi
else
  log_warning "Gitleaks not available, skipping secrets scan"
fi

# ─────────────────────────────────────────
# License Compliance
# ─────────────────────────────────────────
log_header "License Compliance"

if command -v trivy &> /dev/null; then
  if trivy fs --scanners license --severity CRITICAL,HIGH --exit-code 1 "${PROJECT_ROOT}" 2>/dev/null; then
    log_success "No forbidden licenses detected"
  else
    log_error "Forbidden licenses (copyleft) detected"
  fi
else
  log_warning "Trivy not installed, skipping license scan"
fi

# ─────────────────────────────────────────
# Static Analysis (SAST)
# ─────────────────────────────────────────
log_header "Static Analysis (Semgrep)"

if command -v semgrep &> /dev/null; then
  if semgrep scan --config=p/security-audit --error "${PROJECT_ROOT}" 2>/dev/null; then
    log_success "No security issues found in static analysis"
  else
    log_error "Security issues found in static analysis"
  fi
elif command -v docker &> /dev/null; then
  if docker run --rm -v "${PROJECT_ROOT}":/src returntocorp/semgrep:latest \
      semgrep scan --config=p/security-audit --error /src 2>/dev/null; then
    log_success "No security issues found in static analysis"
  else
    log_error "Security issues found in static analysis"
  fi
else
  log_warning "Semgrep not available, skipping SAST"
fi

# ─────────────────────────────────────────
# Summary
# ─────────────────────────────────────────
log_header "Summary"

if [[ "$OUTPUT_MODE" == "json" ]]; then
  if [[ ${FAILURES} -eq 0 ]] && [[ ${WARNINGS} -eq 0 ]]; then
    _security_exit_with_json "success" "All security checks passed"
  elif [[ ${FAILURES} -eq 0 ]]; then
    _security_exit_with_json "warning" "${WARNINGS} check(s) skipped due to missing tools"
  else
    _security_exit_with_json "error" "${FAILURES} security check(s) failed"
  fi
else
  if [[ ${FAILURES} -eq 0 ]]; then
    echo -e "${GREEN}All security checks passed!${NC}"
    exit 0
  else
    echo -e "${RED}${FAILURES} security check(s) failed${NC}"
    exit 1
  fi
fi
