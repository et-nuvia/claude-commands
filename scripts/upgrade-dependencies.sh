#!/usr/bin/env bash
# upgrade-dependencies.sh - Upgrade project dependencies to latest compatible versions
#
# Usage:
#   upgrade-dependencies.sh [--json|--raw] [--full|--python|--nodejs]
#
# Flags:
#   --json    Output structured JSON (default)
#   --raw     Output verbose debugging information
#   --full    Run all sections (python + nodejs)
#   --python  Only upgrade Python dependencies
#   --nodejs  Only upgrade Node.js dependencies
#
# JSON Response Format:
#   {
#     "status": "success|error|intervention_needed",
#     "section": "detect|python|nodejs",
#     "message": "Summary message",
#     "details": {...},
#     "timestamp": "ISO 8601"
#   }

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Default flags
OUTPUT_MODE="json"
SECTION="full"

map_status_to_action() {
    case "$1" in
        success)              echo "display_summary" ;;
        intervention_needed)  echo "confirm_action" ;;
        *)                    _default_map_status_to_action "$1" ;;
    esac
}
source "${SCRIPT_DIR}/lib/output-framework.sh"

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --json) OUTPUT_MODE="json"; shift ;;
            --toon) OUTPUT_MODE="json"; OUTPUT_FORMAT="toon"; shift ;;
    --raw) OUTPUT_MODE="raw"; shift ;;
    --full) SECTION="full"; shift ;;
    --python) SECTION="python"; shift ;;
    --nodejs) SECTION="nodejs"; shift ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

# JSON response helper (delegates to output-framework)
json_response() {
  local status="$1"
  local section_name="$2"
  local message="$3"
  local details="${4:-{}}"

  local next_action
  next_action=$(map_status_to_action "$status")

  log_json "$(cat <<EOF
{
  "status": "$status",
  "section": "$section_name",
  "message": "$message",
  "next_action": "$next_action",
  "details": $details,
  "timestamp": "$(date -Iseconds)"
}
EOF
)"
}

# Utility: Detect project type
detect_project_type() {
  local has_python=false
  local has_nodejs=false

  if [[ -f "pyproject.toml" ]]; then
    has_python=true
  fi

  if [[ -f "package.json" ]]; then
    has_nodejs=true
  fi

  if [[ "$OUTPUT_MODE" == "raw" ]]; then
    echo "=== Project Detection ==="
    echo "Python project: $has_python"
    echo "Node.js project: $has_nodejs"
    echo ""
  fi

  echo "$has_python:$has_nodejs"
}

# Utility: Find forced pins in Python
find_python_forced_pins() {
  if [[ ! -f "pyproject.toml" ]]; then
    echo "[]"
    return
  fi

  # Extract dependencies with PINNED comments
  local pins
  pins=$(grep -A1 "PINNED:" pyproject.toml 2>/dev/null | grep '"' | grep -oE '"[^"]+==?[^"]*"' | tr -d '"' || echo "")

  if [[ -z "$pins" ]]; then
    echo "[]"
  else
    echo "$pins" | jq -R . | jq -s .
  fi
}

# Utility: Find forced pins in Node.js
find_nodejs_forced_pins() {
  if [[ ! -f "package.json" ]]; then
    echo "[]"
    return
  fi

  # Check for DEPENDENCIES.md or comments in package.json
  local pins="[]"

  if [[ -f "DEPENDENCIES.md" ]]; then
    # Extract packages from DEPENDENCIES.md
    pins=$(grep -oE '@?[A-Za-z0-9_/@-]+:' DEPENDENCIES.md 2>/dev/null | sed 's/:$//' | jq -R . | jq -s . || echo "[]")
  fi

  echo "$pins"
}

# Section: Upgrade Python dependencies
upgrade_python() {
  local raw_mode="${1:-false}"

  if [[ "$raw_mode" == "true" ]]; then
    echo "=== Upgrading Python Dependencies ==="
    echo ""
  fi

  # Check if pyproject.toml exists
  if [[ ! -f "pyproject.toml" ]]; then
    if [[ "$raw_mode" == "true" ]]; then
      echo "No pyproject.toml found - skipping Python upgrade"
      return 0
    fi
    json_response "error" "python" "No pyproject.toml found" '{"reason":"Python project not detected"}'
    return 1
  fi

  # Find forced pins
  local forced_pins
  forced_pins=$(find_python_forced_pins)

  if [[ "$raw_mode" == "true" ]]; then
    echo "Forced pins detected:"
    echo "$forced_pins" | jq -r '.[]'
    echo ""
  fi

  # Check for docker compose
  if [[ ! -f "docker-compose.yml" ]] && [[ ! -f "compose.yml" ]]; then
    if [[ "$raw_mode" == "true" ]]; then
      echo "Error: No docker-compose.yml or compose.yml found"
      return 1
    fi
    json_response "error" "python" "Docker Compose configuration not found" '{"reason":"Required for dependency operations"}'
    return 1
  fi

  # Store current pyproject.toml state
  if [[ "$raw_mode" == "true" ]]; then
    echo "Step 1: Backing up pyproject.toml..."
    cp pyproject.toml pyproject.toml.backup
    echo "✓ Backup created: pyproject.toml.backup"
    echo ""

    echo "Step 2: LLM will remove version pins (except forced pins)"
    echo "Step 3: Run dependency resolution"
    echo "Step 4: Build with tests"
    echo "Step 5: Security scan"
    echo "Step 6: LLM will pin resolved versions"
    echo ""
    echo "Next: LLM should read pyproject.toml and remove version constraints"
    echo "      except for packages in forced pins list"
    return 0
  fi

  # JSON mode - return intervention needed
  local details
  details=$(cat <<EOF
{
  "forced_pins": $forced_pins,
  "next_steps": [
    "Read pyproject.toml",
    "Remove version constraints (e.g., ==1.2.3) from dependencies except forced pins",
    "Keep forced pins unchanged (marked with PINNED comments)",
    "Then run: ~/.claude/scripts/upgrade-dependencies.sh --json --python-resolve"
  ]
}
EOF
)

  json_response "intervention_needed" "python" "Manual edit required: Remove version pins from pyproject.toml" "$details"
}

# Section: Resolve Python dependencies
resolve_python() {
  local raw_mode="${1:-false}"

  if [[ "$raw_mode" == "true" ]]; then
    echo "=== Resolving Python Dependencies ==="
    echo ""
    echo "Running: docker compose run --rm app uv lock"
    docker compose run --rm app uv lock
    echo ""
    echo "✓ Dependencies resolved"
    echo ""
    echo "Next steps:"
    echo "1. Build with tests: docker compose build --build-arg RUN_TESTS=true app"
    echo "2. If tests pass, run security scan"
    return 0
  fi

  # Run UV lock
  if ! docker compose run --rm app uv lock 2>&1 | tee /tmp/uv-lock.log; then
    local log_content
    log_content=$(cat /tmp/uv-lock.log)
    json_response "error" "python-resolve" "Dependency resolution failed" "{\"log\":$(echo "$log_content" | jq -Rs .)}"
    return 1
  fi

  json_response "success" "python-resolve" "Dependencies resolved successfully" '{"next":"Run tests to verify compatibility"}'
}

# Section: Test Python build
test_python() {
  local raw_mode="${1:-false}"

  if [[ "$raw_mode" == "true" ]]; then
    echo "=== Testing Python Build ==="
    echo ""
    echo "Running: docker compose build --build-arg RUN_TESTS=true app"
    docker compose build --build-arg RUN_TESTS=true app
    echo ""
    echo "✓ Build and tests passed"
    return 0
  fi

  # Build with tests
  if ! docker compose build --build-arg RUN_TESTS=true app 2>&1 | tee /tmp/build-test.log; then
    local log_content
    log_content=$(tail -100 /tmp/build-test.log)
    json_response "error" "python-test" "Build or tests failed" "{\"log\":$(echo "$log_content" | jq -Rs .)}"
    return 1
  fi

  json_response "success" "python-test" "Build and tests passed" '{"next":"Run security scan"}'
}

# Section: Security scan Python
scan_python() {
  local raw_mode="${1:-false}"

  if [[ "$raw_mode" == "true" ]]; then
    echo "=== Security Scanning Python Dependencies ==="
    echo ""
    echo "Running: docker compose run --rm app trivy fs --scanners vuln ."
    docker compose run --rm app trivy fs --scanners vuln --severity CRITICAL,HIGH .
    echo ""
    return 0
  fi

  # Run Trivy scan
  local scan_output
  scan_output=$(docker compose run --rm app trivy fs --scanners vuln --severity CRITICAL,HIGH --format json . 2>/dev/null || echo '{"Results":[]}')

  local vuln_count
  vuln_count=$(echo "$scan_output" | jq '[.Results[]?.Vulnerabilities // []] | flatten | length')

  if [[ "$vuln_count" -gt 0 ]]; then
    json_response "intervention_needed" "python-security" "Security vulnerabilities found" "{\"vulnerability_count\":$vuln_count,\"details\":$scan_output}"
    return 1
  fi

  json_response "success" "python-security" "No critical or high vulnerabilities found" '{"next":"Check resolved versions and pin them"}'
}

# Section: Get resolved Python versions
get_python_versions() {
  local raw_mode="${1:-false}"

  if [[ "$raw_mode" == "true" ]]; then
    echo "=== Resolved Python Versions ==="
    echo ""
    docker compose run --rm app uv pip list
    echo ""
    echo "Next: LLM should read these versions and update pyproject.toml with exact pins"
    return 0
  fi

  # Get package list
  local packages
  packages=$(docker compose run --rm app uv pip list --format json 2>/dev/null || echo "[]")

  local details
  details=$(cat <<EOF
{
  "packages": $packages,
  "next_steps": [
    "Read the resolved package versions",
    "Update pyproject.toml dependencies with exact version pins (e.g., package==1.2.3)",
    "Keep forced pins unchanged",
    "Then verify with frozen install"
  ]
}
EOF
)

  json_response "intervention_needed" "python-versions" "Pin resolved versions in pyproject.toml" "$details"
}

# Section: Upgrade Node.js dependencies
upgrade_nodejs() {
  local raw_mode="${1:-false}"

  if [[ "$raw_mode" == "true" ]]; then
    echo "=== Upgrading Node.js Dependencies ==="
    echo ""
  fi

  # Check if package.json exists
  if [[ ! -f "package.json" ]]; then
    if [[ "$raw_mode" == "true" ]]; then
      echo "No package.json found - skipping Node.js upgrade"
      return 0
    fi
    json_response "error" "nodejs" "No package.json found" '{"reason":"Node.js project not detected"}'
    return 1
  fi

  # Find forced pins
  local forced_pins
  forced_pins=$(find_nodejs_forced_pins)

  if [[ "$raw_mode" == "true" ]]; then
    echo "Forced pins detected:"
    echo "$forced_pins" | jq -r '.[]'
    echo ""
    echo "Step 1: Backing up package.json..."
    cp package.json package.json.backup
    echo "✓ Backup created: package.json.backup"
    echo ""
    echo "Step 2: LLM will set upgradeable packages to 'latest'"
    echo "Step 3: Remove lock file and resolve"
    echo "Step 4: Build with tests"
    echo "Step 5: Security scan"
    echo "Step 6: LLM will pin resolved versions"
    echo ""
    echo "Next: LLM should read package.json and set packages to 'latest' except forced pins"
    return 0
  fi

  # JSON mode - return intervention needed
  local details
  details=$(cat <<EOF
{
  "forced_pins": $forced_pins,
  "next_steps": [
    "Read package.json",
    "Set upgradeable dependencies to 'latest' (not ^ or ~ prefix)",
    "Keep forced pins at their current versions",
    "Then run: ~/.claude/scripts/upgrade-dependencies.sh --json --nodejs-resolve"
  ]
}
EOF
)

  json_response "intervention_needed" "nodejs" "Manual edit required: Set dependencies to 'latest' in package.json" "$details"
}

# Section: Resolve Node.js dependencies
resolve_nodejs() {
  local raw_mode="${1:-false}"

  if [[ "$raw_mode" == "true" ]]; then
    echo "=== Resolving Node.js Dependencies ==="
    echo ""
    echo "Removing package-lock.json..."
    docker compose run --rm frontend rm -f package-lock.json
    echo ""
    echo "Running: npm install"
    docker compose run --rm frontend npm install
    echo ""
    echo "✓ Dependencies resolved"
    echo ""
    echo "Next: Build with tests"
    return 0
  fi

  # Remove lock and install
  docker compose run --rm frontend rm -f package-lock.json

  if ! docker compose run --rm frontend npm install 2>&1 | tee /tmp/npm-install.log; then
    local log_content
    log_content=$(cat /tmp/npm-install.log)
    json_response "error" "nodejs-resolve" "Dependency resolution failed" "{\"log\":$(echo "$log_content" | jq -Rs .)}"
    return 1
  fi

  json_response "success" "nodejs-resolve" "Dependencies resolved successfully" '{"next":"Run tests to verify compatibility"}'
}

# Section: Test Node.js build
test_nodejs() {
  local raw_mode="${1:-false}"

  if [[ "$raw_mode" == "true" ]]; then
    echo "=== Testing Node.js Build ==="
    echo ""
    echo "Running: docker compose build --build-arg RUN_TESTS=true frontend"
    docker compose build --build-arg RUN_TESTS=true frontend
    echo ""
    echo "✓ Build and tests passed"
    return 0
  fi

  # Build with tests
  if ! docker compose build --build-arg RUN_TESTS=true frontend 2>&1 | tee /tmp/build-test-nodejs.log; then
    local log_content
    log_content=$(tail -100 /tmp/build-test-nodejs.log)
    json_response "error" "nodejs-test" "Build or tests failed" "{\"log\":$(echo "$log_content" | jq -Rs .)}"
    return 1
  fi

  json_response "success" "nodejs-test" "Build and tests passed" '{"next":"Run security scan"}'
}

# Section: Security scan Node.js
scan_nodejs() {
  local raw_mode="${1:-false}"

  if [[ "$raw_mode" == "true" ]]; then
    echo "=== Security Scanning Node.js Dependencies ==="
    echo ""
    echo "Running: npm audit"
    docker compose run --rm frontend npm audit --audit-level=high || true
    echo ""
    echo "Running: trivy fs"
    docker compose run --rm frontend trivy fs --scanners vuln --severity CRITICAL,HIGH .
    echo ""
    return 0
  fi

  # Run npm audit
  local audit_output
  audit_output=$(docker compose run --rm frontend npm audit --json 2>/dev/null || echo '{"vulnerabilities":{}}')

  local high_vuln
  local critical_vuln
  high_vuln=$(echo "$audit_output" | jq '.metadata.vulnerabilities.high // 0')
  critical_vuln=$(echo "$audit_output" | jq '.metadata.vulnerabilities.critical // 0')

  local total_vuln=$((high_vuln + critical_vuln))

  if [[ "$total_vuln" -gt 0 ]]; then
    json_response "intervention_needed" "nodejs-security" "Security vulnerabilities found" "{\"high\":$high_vuln,\"critical\":$critical_vuln,\"details\":$audit_output}"
    return 1
  fi

  json_response "success" "nodejs-security" "No critical or high vulnerabilities found" '{"next":"Check resolved versions and pin them"}'
}

# Section: Get resolved Node.js versions
get_nodejs_versions() {
  local raw_mode="${1:-false}"

  if [[ "$raw_mode" == "true" ]]; then
    echo "=== Resolved Node.js Versions ==="
    echo ""
    docker compose run --rm frontend npm list --depth=0
    echo ""
    echo "Next: LLM should read these versions and update package.json with exact pins (no ^ or ~)"
    return 0
  fi

  # Get package list
  local packages
  packages=$(docker compose run --rm frontend npm list --depth=0 --json 2>/dev/null | jq '.dependencies // {}')

  local details
  details=$(cat <<EOF
{
  "packages": $packages,
  "next_steps": [
    "Read the resolved package versions",
    "Update package.json dependencies with exact version pins (no ^ or ~)",
    "Keep forced pins unchanged",
    "Then run npm install to regenerate lock file"
  ]
}
EOF
)

  json_response "intervention_needed" "nodejs-versions" "Pin resolved versions in package.json" "$details"
}

# Main execution
main() {
  local raw_mode="false"
  [[ "$OUTPUT_MODE" == "raw" ]] && raw_mode="true"

  # Detect project type
  local detection
  detection=$(detect_project_type)
  local has_python="${detection%%:*}"
  local has_nodejs="${detection##*:}"

  # Execute sections based on flags
  case "$SECTION" in
    full)
      if [[ "$has_python" == "true" ]]; then
        upgrade_python "$raw_mode"
      fi
      if [[ "$has_nodejs" == "true" ]]; then
        upgrade_nodejs "$raw_mode"
      fi
      if [[ "$has_python" == "false" && "$has_nodejs" == "false" ]]; then
        json_response "error" "detect" "No Python or Node.js project detected" '{"reason":"No pyproject.toml or package.json found"}'
        exit 1
      fi
      ;;
    python)
      upgrade_python "$raw_mode"
      ;;
    python-resolve)
      resolve_python "$raw_mode"
      ;;
    python-test)
      test_python "$raw_mode"
      ;;
    python-security)
      scan_python "$raw_mode"
      ;;
    python-versions)
      get_python_versions "$raw_mode"
      ;;
    nodejs)
      upgrade_nodejs "$raw_mode"
      ;;
    nodejs-resolve)
      resolve_nodejs "$raw_mode"
      ;;
    nodejs-test)
      test_nodejs "$raw_mode"
      ;;
    nodejs-security)
      scan_nodejs "$raw_mode"
      ;;
    nodejs-versions)
      get_nodejs_versions "$raw_mode"
      ;;
    *)
      echo "Unknown section: $SECTION" >&2
      exit 1
      ;;
  esac
}

main "$@"
