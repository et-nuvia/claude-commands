#!/usr/bin/env bash
set -euo pipefail

# Security Gate Script
# For CI pipelines - exits non-zero on CRITICAL/HIGH findings
# Copy to project: cp ~/.claude/scripts/security-gate.sh ./scripts/

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "Running security gate checks..."

# Dependency vulnerabilities (CRITICAL/HIGH = fail)
echo "Checking dependencies..."
trivy fs \
    --scanners vuln \
    --severity CRITICAL,HIGH \
    --exit-code 1 \
    --format table \
    "${PROJECT_ROOT}"

# License compliance (no copyleft)
echo "Checking licenses..."
trivy fs \
    --scanners license \
    --severity CRITICAL,HIGH \
    --exit-code 1 \
    "${PROJECT_ROOT}"

# Secrets detection
echo "Checking for secrets..."
if command -v gitleaks &> /dev/null; then
    gitleaks detect --source "${PROJECT_ROOT}" --no-git --exit-code 1
else
    docker run --rm -v "${PROJECT_ROOT}":/repo zricethezav/gitleaks:latest \
        detect --source /repo --no-git --exit-code 1
fi

echo "Security gate passed!"
